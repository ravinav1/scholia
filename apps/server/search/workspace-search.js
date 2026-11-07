import { Worker } from 'node:worker_threads';
import { join } from 'node:path';
import { availableParallelism } from 'node:os';
import { searchTerms } from './needle.js';
import { FileNameSearch } from '../file-search.js';

// A small, lazy worker pool keeps indexing and scans off the HTTP loop.
// Each account has its own persistent, disposable index and ownership snapshot.
export class WorkspaceSearch {
  constructor(documents, {
    workerCount = Math.min(2, availableParallelism()), maxTextBytes,
    idleTimeoutMs = 120_000, semanticIdleTimeoutMs = 300_000,
  } = {}) {
    this.documents = documents;
    this.fileNames = new FileNameSearch();
    this.pending = new Map();
    this.sequence = 0;
    this.idleTimeoutMs = idleTimeoutMs;
    this.semanticIdleTimeoutMs = semanticIdleTimeoutMs;
    workerCount = Math.max(1, Math.min(2, Math.floor(workerCount) || 1));
    this.maxTextBytes =
      maxTextBytes ??
      Math.min(
        64 * 1024 * 1024,
        Math.max(
          4 * 1024 * 1024,
          Math.floor((process.availableMemory?.() || 1024 ** 3) / 32 / workerCount)
        )
      );
    this.slots = Array.from({ length: workerCount }, () => ({
      queue: [],
      active: null,
      worker: null,
    }));
    this.semanticSlot = { queue: [], active: null, worker: null, semantic: true };
  }
  search(account, query, options = {}) {
    if (this.closing) throw new Error('Search stopped.');
    const { signal, ...searchOptions } = options;
    signal?.throwIfAborted();
    if (options.mode === 'semantic') {
      if (typeof query !== 'string' || query.length > 512 || query.includes('\0'))
        throw new Error('Use a search of at most 512 characters.');
    } else searchTerms(query);
    if (options.mode && !['all', 'files', 'content', 'semantic'].includes(options.mode))
      throw new Error('Unknown search mode.');
    if (
      options.courseID &&
      !account.library.courses.some((course) => course.id === options.courseID)
    )
      throw Object.assign(new Error('Workspace not found.'), { status: 404 });
    if (this.pending.size >= 16) throw new Error('Search is busy. Try again shortly.');
    const files = account.library.courses.flatMap((course) => {
      const base = {
        courseID: course.id,
        courseName: course.code ? `${course.code} · ${course.name}` : course.name,
      };
      const saved = new Set(course.documents.map((doc) => doc.sourceKey));
      return [
        ...course.documents.map((doc) => ({
          ...base,
          id: doc.id,
          documentID: doc.id,
          title: doc.title,
          fileName: doc.originalFileName || doc.fileName,
          kind: doc.kind,
          indexPath: options.mode === 'files' ? undefined : join(
            this.documents.directory(account.id, doc.storageID || doc.id),
            'index.json'
          ),
        })),
        ...(course.canvasMaterials || [])
          .filter((ref) => !saved.has(ref.id))
          .map((ref) => ({
            ...base,
            id: `${course.id}:${ref.id}`,
            materialID: ref.id,
            title: ref.title,
            fileName: ref.fileName || '',
            kind: ref.kind,
          })),
      ];
    });
    if (options.mode === 'files') return Promise.resolve(this.fileNames.search(files, query, options));
    let hash = 0;
    for (const char of account.id) hash = (Math.imul(hash, 31) + char.charCodeAt(0)) | 0;
    const slot = options.mode === 'semantic' ? this.semanticSlot : this.slots[(hash >>> 0) % this.slots.length];
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const cancellation = new SharedArrayBuffer(4);
      const abort = () => {
        Atomics.store(new Int32Array(cancellation), 0, 1);
        slot.queue = slot.queue.filter((job) => job.id !== id);
        this.finish(
          id,
          undefined,
          Object.assign(new Error('Search cancelled.'), { name: 'AbortError' })
        );
      };
      this.pending.set(id, {
        resolve,
        reject,
        cleanup: () => signal?.removeEventListener('abort', abort),
      });
      signal?.addEventListener('abort', abort, { once: true });
      slot.queue.push({
        id,
        files,
        query,
        options: searchOptions,
        cancellation,
        path: join(this.documents.directory(account.id, account.id), options.mode === 'semantic' ? 'semantic-v1.sqlite' : 'needle-v1.sqlite'),
      });
      this.pump(slot);
    });
  }
  finish(id, result, error) {
    const pending = this.pending.get(id);
    if (!pending) return;
    this.pending.delete(id);
    pending.cleanup();
    error ? pending.reject(error) : pending.resolve(result);
  }
  pump(slot) {
    if (slot.active || this.closing) return;
    const job = slot.queue.shift();
    if (!job) {
      slot.worker?.unref();
      return;
    }
    if (!slot.worker) {
      const worker = (slot.worker = new Worker(
        new URL(slot.semantic ? '../semantic-search-worker.js' : './workspace-search-worker.js', import.meta.url),
        {
          workerData: {
            maxTextBytes: this.maxTextBytes,
            idleTimeoutMs: slot.semantic ? this.semanticIdleTimeoutMs : this.idleTimeoutMs,
          },
        }
      ));
      worker.on('message', ({ id, result, error, errorName, type }) => {
        if (slot.worker !== worker) return;
        if (type === 'idle') {
          // A request can be posted while the worker's idle message is in
          // transit. Only its owner knows whether it is still safe to retire.
          if (!slot.active && !slot.queue.length) {
            slot.worker = null;
            void worker.terminate();
          }
          return;
        }
        if (slot.worker !== worker || slot.active?.id !== id) return;
        slot.active = null;
        this.finish(
          id,
          result,
          error && Object.assign(new Error(error), { name: errorName || 'Error' })
        );
        this.pump(slot);
      });
      worker.on('error', (error) => this.failed(slot, worker, error));
      worker.on('exit', () => this.failed(slot, worker, new Error('Search stopped. Try again.')));
    }
    slot.active = job;
    slot.worker.ref();
    slot.worker.postMessage(job);
  }
  failed(slot, worker, error) {
    if (slot.worker !== worker) return;
    slot.worker = null;
    for (const job of [slot.active, ...slot.queue]) if (job) this.finish(job.id, undefined, error);
    slot.active = null;
    slot.queue = [];
  }
  async close() {
    this.closing = true;
    await Promise.all(
      [...this.slots, this.semanticSlot].map(async (slot) => {
        const worker = slot.worker;
        if (worker) {
          this.failed(slot, worker, new Error('Search stopped.'));
          await worker.terminate();
        }
      })
    );
  }
}
