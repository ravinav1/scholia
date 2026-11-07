// The entry point also imports a legacy global shim with a Function fallback;
// Chromium has native async support, so use the pinned worker module directly.
import createWorker from 'tesseract.js/src/createWorker.js';

const aborted = () => new DOMException('OCR was cancelled.', 'AbortError');

/** One local worker, serialized jobs, and no retained page images while idle. */
export function createOcrQueue({ workerFactory = createWorker, timeoutMs = 30_000, idleMs = 30_000 } = {}) {
  let workerPromise = null;
  let queue = Promise.resolve();
  let idleTimer;
  const release = () => {
    clearTimeout(idleTimer);
    const previous = workerPromise;
    workerPromise = null;
    previous?.then((worker) => worker.terminate()).catch(() => {});
  };
  const worker = () => workerPromise ||= workerFactory('eng+nor', 1, {
    workerPath: chrome.runtime.getURL('vendor/ocr/worker.min.js'),
    corePath: chrome.runtime.getURL('vendor/ocr'),
    langPath: chrome.runtime.getURL('vendor/ocr/lang'),
    workerBlobURL: false,
    cacheMethod: 'none',
    errorHandler: () => {}
  }).then(async (value) => {
    await value.setParameters({ tessedit_pageseg_mode: '3' });
    return value;
  });

  return {
    recognize(image, { signal } = {}) {
      const task = queue.catch(() => {}).then(async () => {
        if (signal?.aborted) throw aborted();
        clearTimeout(idleTimer);
        let timer;
        let cancel;
        const interrupted = new Promise((_, reject) => {
          cancel = () => { release(); reject(aborted()); };
          signal?.addEventListener('abort', cancel, { once: true });
          timer = setTimeout(() => {
            release();
            reject(new Error('Local OCR reached its page time limit.'));
          }, timeoutMs);
        });
        try {
          const result = await Promise.race([
            worker().then((value) => value.recognize(image)), interrupted
          ]);
          return { text: String(result.data?.text || '').slice(0, 100_000), confidence: Number(result.data?.confidence) || 0 };
        } catch (error) {
          release();
          throw error;
        } finally {
          clearTimeout(timer);
          signal?.removeEventListener('abort', cancel);
          idleTimer = setTimeout(release, idleMs);
        }
      });
      queue = task;
      return task;
    },
    release
  };
}
