import { Worker } from 'node:worker_threads';
import { mkdir, writeFile, readFile, rename, rm } from 'node:fs/promises';
import { join, basename, extname } from 'node:path';
import { randomUUID } from 'node:crypto';
import { hash } from './store.js';
import { textIndexVersion } from './document-formats.js';
const mime = {
  pdf: 'application/pdf',
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  gif: 'image/gif',
  webp: 'image/webp',
  ipynb: 'application/json',
};
export const documentMime = (doc) =>
  mime[extname(doc.fileName).slice(1).toLowerCase()] || 'application/octet-stream';
export class Documents {
  constructor(root, { maxIndexBytes = 32_000_000, maxIndexEntries = 32 } = {}) {
    this.root = root;
    this.active = 0;
    this.waiters = [];
    this.indexCache = new Map();
    this.indexReads = new Map();
    this.indexBytes = 0;
    this.maxIndexBytes = maxIndexBytes;
    this.maxIndexEntries = maxIndexEntries;
  }
  directory(user, id) {
    if (![user, id].every((v) => /^[\da-f-]{36}$/i.test(v)))
      throw new Error('Invalid document identifier.');
    return join(this.root, 'files', user, id);
  }
  async import(
    user,
    name,
    data,
    { id = randomUUID(), allowEmpty = false, preserveOriginal = false, signal } = {}
  ) {
    signal?.throwIfAborted();
    if ((!data.length && !allowEmpty) || data.length > 100_000_000)
      throw new Error('Choose a file between 1 byte and 100 MB.');
    name = basename(String(name).replaceAll('\\', '/')).slice(0, 240) || 'document.txt';
    if (this.waiters.length >= 12) throw new Error('The import queue is full. Try again shortly.');
    if (this.active >= 2)
      await new Promise((resolve, reject) => {
        const resume = () => {
          signal?.removeEventListener('abort', abort);
          resolve();
        };
        const abort = () => {
          const position = this.waiters.indexOf(resume);
          if (position >= 0) this.waiters.splice(position, 1);
          reject(signal.reason);
        };
        this.waiters.push(resume);
        signal?.addEventListener('abort', abort, { once: true });
      });
    this.active++;
    let result;
    try {
      signal?.throwIfAborted();
      result = await new Promise((resolve, reject) => {
        const worker = new Worker(new URL('./document-worker.js', import.meta.url), {
          workerData: { name, data },
          resourceLimits: { maxOldGenerationSizeMb: 256 },
        });
        const children = new Set();
        let settled = false,
          terminationTimer;
        const finish = (error, value) => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          signal?.removeEventListener('abort', abort);
          for (const pid of children) {
            try {
              process.kill(pid, 'SIGKILL');
            } catch {
              /* Child already exited. */
            }
          }
          // Give the worker a moment to reap killed OCR children before tearing
          // down its libuv handles. Force termination if shutdown itself hangs.
          if (children.size) terminationTimer = setTimeout(() => worker.terminate(), 1000);
          else worker.terminate();
          error ? reject(error) : resolve(value);
        };
        const timer = setTimeout(
          () => finish(new Error('This document took too long to index.')),
          90000
        );
        const abort = () => finish(signal.reason);
        signal?.addEventListener('abort', abort, { once: true });
        worker.on('message', (value) => {
          if (value.type === 'ocrChild') {
            if (value.event === 'start' && settled) {
              try {
                process.kill(value.pid, 'SIGKILL');
              } catch {
                /* Already exited. */
              }
            } else if (value.event === 'start') children.add(value.pid);
            else {
              children.delete(value.pid);
              if (settled && !children.size) {
                clearTimeout(terminationTimer);
                worker.terminate();
              }
            }
            return;
          }
          finish(value.error ? new Error(value.error) : null, value);
        });
        worker.once('error', (error) => finish(error));
        worker.once('exit', () => finish(new Error('The document indexer stopped.')));
      });
    } finally {
      this.active--;
      this.waiters.shift()?.();
    }
    signal?.throwIfAborted();
    const path = this.directory(user, id);
    await mkdir(path, { recursive: true, mode: 0o700 });
    if (!preserveOriginal) await writeFile(join(path, 'original'), data, { mode: 0o600 });
    const temporaryIndex = join(path, `index-${randomUUID()}.tmp`);
    try {
      await writeFile(temporaryIndex, JSON.stringify({ pages: result.pages }), { mode: 0o600 });
      signal?.throwIfAborted();
      await rename(temporaryIndex, join(path, 'index.json'));
    } finally {
      await rm(temporaryIndex, { force: true });
    }
    this.invalidateIndex(user, id);
    for (const [name, encoded] of Object.entries(result.images))
      await writeFile(join(path, name), Buffer.from(encoded, 'base64'), { mode: 0o600 });
    return {
      id,
      title: name.slice(0, name.length - extname(name).length) || name,
      fileName: name,
      originalFileName: name,
      kind: result.kind,
      pageCount: result.pages.length,
      unreadablePages: result.unreadablePages || 0,
      indexVersion: textIndexVersion,
      lastPage: 1,
      addedAt: Date.now() / 1000,
      contentHash: hash(data),
      contentNotice: result.notice || undefined,
      materialAnalysis: result.materialAnalysis,
    };
  }
  async reindex(user, doc, { signal } = {}) {
    return this.import(user, doc.fileName, await this.data(user, doc), {
      id: doc.storageID || doc.id,
      allowEmpty: true,
      preserveOriginal: true,
      signal,
    });
  }
  async index(user, doc) {
    const path = this.directory(user, doc.storageID || doc.id);
    const cached = this.indexCache.get(path);
    if (cached) {
      this.indexCache.delete(path);
      this.indexCache.set(path, cached);
      return cached.value;
    }
    if (this.indexReads.has(path)) return this.indexReads.get(path);
    const reading = readFile(join(path, 'index.json'), 'utf8')
      .then((text) => {
        const value = JSON.parse(text),
          bytes = Buffer.byteLength(text);
        // Import can invalidate a read that was in flight for an older revision.
        if (
          this.indexReads.get(path) === reading &&
          bytes <= this.maxIndexBytes &&
          this.maxIndexEntries > 0
        ) {
          while (
            this.indexCache.size &&
            (this.indexBytes + bytes > this.maxIndexBytes ||
              this.indexCache.size >= this.maxIndexEntries)
          ) {
            const key = this.indexCache.keys().next().value;
            this.indexBytes -= this.indexCache.get(key).bytes;
            this.indexCache.delete(key);
          }
          this.indexCache.set(path, { value, bytes });
          this.indexBytes += bytes;
        }
        return value;
      })
      .finally(() => {
        if (this.indexReads.get(path) === reading) this.indexReads.delete(path);
      });
    this.indexReads.set(path, reading);
    return reading;
  }
  invalidateIndex(user, id) {
    const path = this.directory(user, id),
      cached = this.indexCache.get(path);
    if (cached) this.indexBytes -= cached.bytes;
    this.indexCache.delete(path);
    this.indexReads.delete(path);
  }
  async data(user, doc) {
    return readFile(this.originalPath(user, doc));
  }
  originalPath(user, doc) {
    return join(this.directory(user, doc.storageID || doc.id), 'original');
  }
  async image(user, doc, name) {
    const index = await this.index(user, doc);
    if (name !== basename(name) || !index.pages.some((page) => page.images?.includes(name)))
      throw new Error('Image not found.');
    return readFile(join(this.directory(user, doc.storageID || doc.id), name));
  }
}
