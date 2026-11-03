import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { mkdir, stat, open, rename, rm } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createHash } from 'node:crypto';

export const SEMANTIC_MODEL = 'Xenova/multilingual-e5-small';
export const SEMANTIC_REVISION = '761b726dd34fb83930e26aab4e9ac3899aa1fa78';
const ASSETS = [
  ['config.json', 658, 'cb99455288675345e1a4f411438d5d0adbba5fbd3a67ea4fb03c015433b996c1'],
  ['tokenizer.json', 17082730, '0b44a9d7b51c3c62626640cda0e2c2f70fdacdc25bbbd68038369d14ebdf4c39'],
  ['tokenizer_config.json', 443, 'a1d6bc8734a6f635dc158508bef000f8e2e5a759c7d92f984b2c86e5ff53425b'],
  ['onnx/model_quantized.onnx', 118308185, 'f80102d3f2a1229f387d3c81909990d8945513e347b0eab049f7de3c6f98c193'],
];

async function assetValid(path, size, sha256) {
  if ((await stat(path).catch(() => null))?.size !== size) return false;
  const hash = createHash('sha256');
  for await (const bytes of createReadStream(path)) hash.update(bytes);
  return hash.digest('hex') === sha256;
}

// Resume interrupted model downloads, verify the pinned weights, then publish
// atomically. An incomplete download must never become a cached ONNX model.
async function prepareAsset(directory, [name, size, sha256], onProgress) {
  const path = join(directory, name);
  if (await assetValid(path, size, sha256)) { onProgress(size); return; }
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  await rm(path, { force: true });
  const partial = `${path}.partial`;
  const file = await open(partial, 'a+', 0o600);
  try {
    let offset = (await file.stat()).size;
    if (offset > size) { await file.truncate(0); offset = 0; }
    while (offset < size) {
      const end = Math.min(offset + 8 * 1024 * 1024, size) - 1;
      let failure;
      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          const response = await fetch(`https://huggingface.co/${SEMANTIC_MODEL}/resolve/${SEMANTIC_REVISION}/${name}?download=true`, {
            headers: { Range: `bytes=${offset}-${end}` }, signal: AbortSignal.timeout(60_000),
          });
          if (!response.ok) throw new Error(`Model download returned HTTP ${response.status}.`);
          const bytes = new Uint8Array(await response.arrayBuffer());
          const ranged = response.status === 206 && response.headers.get('content-range')?.startsWith(`bytes ${offset}-`);
          const whole = response.status === 200 && offset === 0 && bytes.length === size;
          if ((!ranged && !whole) || bytes.length !== end - offset + 1)
            throw new Error('The model download was incomplete.');
          await file.writeFile(bytes); offset += bytes.length; onProgress(offset);
          failure = null; break;
        } catch (error) { failure = error; }
      }
      if (failure) throw failure;
    }
  } finally { await file.close(); }
  if (!await assetValid(partial, size, sha256)) { await rm(partial, { force: true }); throw new Error('The search model checksum did not match. Try again.'); }
  await rename(partial, path);
}

// A single warm model serves interactive queries before the next indexing batch.
// Only model assets are downloaded. Text is passed to the local ONNX session.
export class LocalSemanticEmbedder {
  dimensions = 384;
  signature = `${SEMANTIC_MODEL}@${SEMANTIC_REVISION}:q8:mean:192-32:v1`;
  status = 'idle';
  progress = 0;
  queue = [];
  running = false;
  async ready() {
    if (!this.loading) {
      this.status = 'loading_model';
      this.loading = (async () => {
        const { pipeline, env } = await import('@huggingface/transformers');
        env.cacheDir = process.env.SCHOLIA_MODEL_CACHE || join(homedir(), '.cache', 'scholia', 'models');
        const directory = join(env.cacheDir, SEMANTIC_MODEL, SEMANTIC_REVISION);
        const totalBytes = ASSETS.reduce((sum, asset) => sum + asset[1], 0);
        let completedBytes = 0;
        for (const asset of ASSETS) {
          await prepareAsset(directory, asset, bytes => { this.progress = 100 * (completedBytes + bytes) / totalBytes; });
          completedBytes += asset[1];
        }
        // Transformers' pipeline metadata probes can ignore the revision/cache
        // options. A verified local directory avoids both mutable-main probes
        // and any network dependency after the assets have been cached.
        env.allowRemoteModels = false;
        this.pipeline = await pipeline('feature-extraction', directory, {
          local_files_only: true, dtype: 'q8', device: 'cpu',
          session_options: { intraOpNumThreads: 2, interOpNumThreads: 1 },
        });
        this.status = 'ready';
      })().catch(error => {
        this.status = 'error'; this.loading = null;
        throw new Error(`Could not prepare the local search model: ${error.message}`);
      });
    }
    return this.loading;
  }
  chunks(text) {
    text = String(text || '').replace(/\s+/gu, ' ').trim();
    if (!text) return [];
    const tokenizer = this.pipeline.tokenizer;
    const tokens = tokenizer.encode(text, { add_special_tokens: false });
    const chunks = [];
    for (let start = 0; start < tokens.length; start += 160) {
      chunks.push(tokenizer.decode(tokens.slice(start, start + 192), { skip_special_tokens: true }).trim());
      if (start + 192 >= tokens.length) break;
    }
    return chunks.filter(Boolean);
  }
  embed(texts, kind = 'passage') {
    return new Promise((resolve, reject) => {
      const job = { texts, kind, resolve, reject };
      if (kind === 'query') this.queue.unshift(job); else this.queue.push(job);
      void this.pump();
    });
  }
  async pump() {
    if (this.running) return;
    this.running = true;
    try {
      while (this.queue.length) {
        const { texts, kind, resolve, reject } = this.queue.shift();
        try {
          await this.ready();
          const output = await this.pipeline(texts.map(text => `${kind}: ${text}`), {
            pooling: 'mean', normalize: true, truncation: true,
            max_length: kind === 'query' ? 128 : 256,
          });
          resolve(texts.map((_, index) => Float32Array.from(output.data.subarray(
            index * this.dimensions, (index + 1) * this.dimensions))));
        } catch (error) { reject(error); }
      }
    } finally { this.running = false; }
  }
}
