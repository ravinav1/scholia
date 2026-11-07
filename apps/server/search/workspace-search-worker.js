import { parentPort, workerData } from 'node:worker_threads';
import { mkdirSync, chmodSync, readFileSync, statSync } from 'node:fs';
import { dirname } from 'node:path';
import { NeedleIndex } from './needle.js';

// One hot account per worker: connections, statements and text caches are reused
// without retaining an unbounded number of private libraries in memory.
let current;
let idle;
parentPort.on('message', ({ id, path, files, query, options, cancellation }) => {
  clearTimeout(idle);
  const start = performance.now();
  const flag = cancellation && new Int32Array(cancellation);
  const checkCancelled = () => {
    if (flag && Atomics.load(flag, 0))
      throw Object.assign(new Error('Search cancelled.'), { name: 'AbortError' });
  };
  try {
    checkCancelled();
    if (current?.path !== path) {
      current?.index.close();
      current = null;
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      const index = new NeedleIndex(path, { maxTextBytes: workerData?.maxTextBytes });
      chmodSync(path, 0o600);
      current = { path, index };
    }
    const { index } = current;
    const revisions = index.revisions(),
      active = new Set(files.map((file) => file.id));
    const removed = [...revisions.keys()].filter((key) => !active.has(key));
    if (removed.length)
      index.batch(() => {
        for (const key of removed) index.remove(key);
      });
    let updatedFiles = 0;
    let changes = [];
    const flush = () => {
      if (!changes.length) return;
      index.batch(() => {
        for (const { indexPath, file, revision } of changes) {
          checkCancelled();
          let pages = [],
            coverage = indexPath ? 'unavailable' : 'remote';
          if (indexPath) {
            try {
              pages =
                file.kind === 'preview' ? [] : JSON.parse(readFileSync(indexPath, 'utf8')).pages;
              coverage = pages.some((page) => page.text?.trim()) ? 'ready' : 'unavailable';
            } catch {
              pages = [];
            }
          }
          index.put(file, pages, revision, coverage, checkCancelled);
        }
      });
      updatedFiles += changes.length;
      changes = [];
    };
    for (const { indexPath, ...file } of files) {
      checkCancelled();
      if (options?.courseID && file.courseID !== options.courseID) continue;
      let stamp = 'missing';
      if (indexPath) {
        try {
          const stat = statSync(indexPath);
          stamp = `${stat.mtimeMs}:${stat.ctimeMs}:${stat.size}`;
        } catch {}
      }
      const revision = JSON.stringify(['names-v2', file, indexPath, stamp]);
      if (revisions.get(file.id) === revision) continue;
      changes.push({ indexPath, file, revision });
      if (changes.length === 64) flush();
    }
    flush();
    checkCancelled();
    const prepared = performance.now();
    const result = index.search(query, { ...options, checkCancelled });
    parentPort.postMessage({
      id,
      result: {
        ...result,
        updatedFiles,
        refreshMs: prepared - start,
        totalMs: performance.now() - start,
      },
    });
  } catch (error) {
    parentPort.postMessage({ id, error: error.message, errorName: error.name });
  } finally {
    idle = setTimeout(() => {
      current?.index.close();
      current = null;
      // Closing SQLite alone leaves the V8 isolate and its allocated heap
      // resident. The owner retires the worker unless new work is in flight.
      parentPort.postMessage({ type: 'idle' });
    }, workerData?.idleTimeoutMs ?? 120_000);
    idle.unref();
  }
});
