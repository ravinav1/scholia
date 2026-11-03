import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as wait } from 'node:timers/promises';
import { SemanticIndex } from '../apps/server/semantic-index.js';
import { LocalSemanticEmbedder } from '../apps/server/semantic-embedding.js';
import { Worker } from 'node:worker_threads';
import { once } from 'node:events';

class FixtureEmbedding {
  dimensions = 3;
  signature = 'test-meaning-v1';
  status = 'ready';
  passages = 0;
  queries = 0;
  async ready() {}
  chunks(text) { return [text.trim()].filter(Boolean); }
  async embed(texts, kind) {
    await wait(1);
    if (kind === 'query') this.queries += texts.length; else this.passages += texts.length;
    return texts.map(text => {
      const vector = /motor|feedback|regulator|stability/i.test(text) ? [1, 0, 0]
        : /bread|flour|cooking|baking/i.test(text) ? [0, 1, 0]
        : /ethic|genetic|dna|consent/i.test(text) ? [0, 0, 1] : [0.577, 0.577, 0.577];
      return Float32Array.from(vector);
    });
  }
}

test('semantic idle retirement is negotiated with the owner and a new request revives the deadline', async t => {
  const worker = new Worker(new URL('../apps/server/semantic-search-worker.js', import.meta.url), {
    workerData: { idleTimeoutMs: 30 },
  });
  t.after(() => worker.terminate());
  // An already cancelled job exercises worker lifecycle without loading a model.
  const cancellation = new SharedArrayBuffer(4);
  Atomics.store(new Int32Array(cancellation), 0, 1);
  for (const id of [1, 2]) {
    const reply = once(worker, 'message');
    worker.postMessage({ id, cancellation });
    assert.equal((await reply)[0].id, id);
    const [idle] = await once(worker, 'message');
    assert.equal(idle.type, 'idle');
    assert.notEqual(worker.threadId, -1, 'The owner must check for in-flight requests before termination');
  }
});
async function fixture(t, options = {}) {
  const root = await mkdtemp(join(tmpdir(), 'scholia-semantic-'));
  const embedder = options.embedder || new FixtureEmbedding();
  const path = join(root, 'semantic.sqlite');
  let index = new SemanticIndex(path, { ...options, embedder });
  const files = [];
  t.after(async () => { await index.close(); await rm(root, { recursive: true, force: true }); });
  return {
    root, embedder, files,
    get index() { return index; },
    async reopen() { await index.close(); index = new SemanticIndex(path, { ...options, embedder }); },
    async add(id, text, courseID = 'a', extra = {}) {
      const indexPath = join(root, `${id}.json`);
      await writeFile(indexPath, JSON.stringify({ pages: [{ number: 3, text }] }));
      files.push({ id, documentID: id, courseID, courseName: courseID, title: `Lecture ${id}`, kind: 'text', indexPath, ...extra });
    },
    async ready(query = 'stability', courseID = '') {
      const deadline = Date.now() + 20_000;
      while (true) {
        const result = await index.search(files, query, { courseID });
        assert.notEqual(result.semantic.state, 'error', result.semantic.message);
        if (result.semantic.state === 'ready') return result;
        assert.ok(Date.now() < deadline, 'Indexing must finish');
        await wait(20);
      }
    },
  };
}

test('semantic results retrieve page evidence, deduplicate embeddings, reuse queries, and survive reopening', async t => {
  const f = await fixture(t);
  await f.add('motor', 'Negative feedback corrects the error in a regulator.');
  await f.add('duplicate', 'Negative feedback corrects the error in a regulator.', 'b');
  await f.add('bread', 'Flour is the base ingredient in bread.');
  const result = await f.ready('stability');
  assert.equal(result.results[0].page, 3);
  assert.ok(['motor', 'duplicate'].includes(result.results[0].id));
  assert.equal(result.semantic.indexedFiles, 3);
  assert.equal(f.embedder.passages, 5, 'Three distinct titles plus two distinct passages');
  const queryCalls = f.embedder.queries;
  await f.index.indexing;
  const snapshotStamp = (await stat(`${f.index.path}.usearch`)).mtimeMs;
  await f.ready('stability');
  assert.equal(f.embedder.queries, queryCalls, 'Polling reuses the query vector');
  const reordered = f.files.map(file => Object.fromEntries(Object.entries(file).reverse()));
  const stable = await f.index.search(reordered, 'stability');
  assert.equal(stable.updatedFiles, 0, 'IPC object-key order is not a document revision');
  assert.equal(stable.semantic.state, 'ready');
  await f.index.indexing;
  assert.equal((await stat(`${f.index.path}.usearch`)).mtimeMs, snapshotStamp, 'Stable queries do not rewrite the graph');
  await f.reopen();
  const reopened = await f.ready('stability');
  assert.equal(reopened.results[0].page, 3);
  assert.equal(f.embedder.passages, 5, 'Persisted passages must not be embedded again');
  await f.index.indexing;
  await writeFile(`${f.index.path}.usearch`, 'damaged derived graph');
  await f.reopen();
  assert.equal((await f.ready('stability')).results[0].page, 3);
  assert.equal(f.embedder.passages, 5, 'A damaged graph rebuilds from saved vectors');
});

test('scoped search ranks inside the workspace, including bounded-cache fallback', async t => {
  const f = await fixture(t, { scopeCacheBytes: 1 });
  for (let i = 0; i < 20; i++) await f.add(`other${i}`, `Motor feedback example ${i}`, 'other');
  await f.add('mine', 'A feedback regulator responds to error.', 'mine');
  await f.ready();
  const result = await f.ready('stability', 'mine');
  assert.equal(result.results[0].id, 'mine');
  assert.ok(result.results.every(hit => hit.courseID === 'mine'));
  assert.equal(f.index.scopeCache, null, 'An oversized exact-search matrix is not retained');
});

test('edits remove stale evidence immediately, unchanged passages reuse vectors, and deletions do not leak', async t => {
  const f = await fixture(t);
  await f.add('one', 'Motor feedback.');
  await f.add('two', 'Flour and bread.');
  await f.ready();
  await writeFile(f.files[0].indexPath, JSON.stringify({ pages: [{ number: 7, text: 'Genetic consent and ethics.' }] }));
  const interim = await f.index.search(f.files, 'stability');
  assert.ok(interim.results.every(hit => !hit.snippet.includes('Motor feedback.')));
  const edited = await f.ready('DNA');
  assert.equal(edited.results[0].id, 'one');
  assert.equal(edited.results[0].page, 7);
  assert.equal(f.embedder.passages, 5, 'Only the changed passage is newly embedded');
  f.files.shift();
  const deleted = await f.ready('DNA');
  assert.ok(deleted.results.every(hit => hit.id !== 'one'));
});

test('scoped preparation skips unrelated files and preview placeholders; cancellation is honored', async t => {
  const f = await fixture(t);
  await f.add('one', 'Motor feedback.', 'a');
  await f.add('two', 'Flour and bread.', 'b');
  await f.add('preview', 'Fictitious motor feedback text.', 'a', { kind: 'preview' });
  const result = await f.ready('stability', 'a');
  assert.equal(result.coverage.files, 2);
  assert.equal(result.coverage.unavailableFiles, 1);
  assert.equal(f.embedder.passages, 3);
  assert.ok(result.results.filter(hit => hit.id === 'preview').every(hit => hit.page === 0));
  await assert.rejects(f.index.search(f.files, 'stability', {
    checkCancelled() { throw Object.assign(new Error('Cancelled'), { name: 'AbortError' }); },
  }), { name: 'AbortError' });
});

test('interrupted preparation resumes committed vectors without re-embedding them', async t => {
  const embedder = new FixtureEmbedding();
  const original = embedder.embed.bind(embedder);
  let batches = 0, release;
  const paused = new Promise(resolve => { release = resolve; });
  embedder.embed = async (texts, kind) => {
    if (kind !== 'query' && ++batches === 2) await paused;
    return original(texts, kind);
  };
  const f = await fixture(t, { embedder });
  for (let i = 0; i < 8; i++) await f.add(`file${i}`, `Motor feedback example ${i}`);
  await f.index.search(f.files, '');
  const deadline = Date.now() + 5000;
  while (batches < 2) { assert.ok(Date.now() < deadline); await wait(5); }
  const saved = f.index.statement('SELECT count(*) AS n FROM vectors WHERE embedding IS NOT NULL').get().n;
  assert.equal(saved, 4);
  const interrupted = f.index.indexing;
  await f.reopen();
  release(); await interrupted;
  const beforeResume = embedder.passages;
  const result = await f.ready('stability');
  assert.equal(result.semantic.indexedFiles, 8);
  assert.equal(embedder.passages - beforeResume, 16 - saved);
});

test('real local model finds English and Norwegian concepts without shared query words', {
  skip: process.env.SCHOLIA_TEST_EMBEDDINGS !== '1', timeout: 180_000,
}, async t => {
  const f = await fixture(t, { embedder: new LocalSemanticEmbedder() });
  await f.add('control', 'A PID regulator compares measurements with a reference. Negative feedback corrects errors and stabilizes a closed loop system.');
  await f.add('bread', 'Bread is baked using yeast, flour and water.');
  await f.add('ethics', 'Editing the DNA of embryos raises ethical concerns about consent and inherited disorders.');
  for (const [query, expected] of [['How can I keep a motor stable?', 'control'], ['Is it right to change a baby’s genes?', 'ethics'], ['Hvordan kan jeg holde en motor stabil?', 'control']]) {
    const result = await f.ready(query);
    assert.equal(result.results[0].id, expected, query);
    assert.equal(result.results[0].page, 3);
    console.log(`Semantic query ${JSON.stringify(query)}: ${result.totalMs.toFixed(1)} ms`);
  }
  await f.embedder.pipeline.dispose();
  const fetch = globalThis.fetch, offline = new LocalSemanticEmbedder();
  globalThis.fetch = async () => { throw new Error('Network disabled by verification'); };
  try {
    const [vector] = await offline.embed(['Keep the motor steady'], 'query');
    assert.equal(vector.length, 384);
    assert.ok(vector.every(Number.isFinite));
  } finally { globalThis.fetch = fetch; await offline.pipeline?.dispose(); }
});
