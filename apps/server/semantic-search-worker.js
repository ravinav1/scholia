import { parentPort, workerData } from 'node:worker_threads';
import { SemanticIndex } from './semantic-index.js';
import { LocalSemanticEmbedder } from './semantic-embedding.js';

const embedder = new LocalSemanticEmbedder();
let current;
let chain = Promise.resolve();
let pending = 0;
let idle;
let waitingForIndex;
function scheduleIdle() {
  clearTimeout(idle);
  if (pending) return;
  // Indexing can continue after returning a progress response. Start the idle
  // deadline only after both interactive work and background work have ended.
  const indexing = current?.index.indexing;
  if (indexing) {
    if (waitingForIndex !== indexing) {
      waitingForIndex = indexing;
      void indexing.finally(() => {
        if (waitingForIndex === indexing) {
          waitingForIndex = null;
          scheduleIdle();
        }
      });
    }
    return;
  }
  idle = setTimeout(() => parentPort.postMessage({ type: 'idle' }), workerData?.idleTimeoutMs ?? 300_000);
  idle.unref();
}
scheduleIdle();
// One model, one hot account, ordered account switches. Background index jobs
// finish/cancel before their database is closed; vectors never cross accounts.
parentPort.on('message', job => {
  clearTimeout(idle);
  pending++;
  chain = chain.then(async () => {
    const { id, path, files, query, options, cancellation } = job;
    const flag = cancellation && new Int32Array(cancellation);
    const checkCancelled = () => {
      if (flag && Atomics.load(flag, 0)) throw Object.assign(new Error('Search cancelled.'), { name: 'AbortError' });
    };
    try {
      checkCancelled();
      if (current?.path !== path) {
        const previous = current; current = null;
        if (previous) await previous.index.close();
        current = { path, index: new SemanticIndex(path, { embedder }) };
      }
      const result = await current.index.search(files, query, { ...options, checkCancelled });
      checkCancelled();
      parentPort.postMessage({ id, result });
    } catch (error) { parentPort.postMessage({ id, error: error.message, errorName: error.name }); }
  }).finally(() => { pending--; scheduleIdle(); });
});
