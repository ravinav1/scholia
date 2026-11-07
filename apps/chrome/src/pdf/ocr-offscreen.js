import { createOcrQueue } from './ocr-runtime.js';

const engine = createOcrQueue();
const jobs = new Map();
chrome.runtime.onMessage.addListener((message, sender, respond) => {
  if (sender.id !== chrome.runtime.id || message?.target !== 'scholia-ocr') return;
  if (message.type === 'SCHOLIA_OCR_CANCEL') {
    jobs.get(message.requestId)?.abort();
    respond({ ok: true });
    return;
  }
  if (message.type !== 'SCHOLIA_OCR_RECOGNIZE') return;
  const controller = new AbortController();
  jobs.set(message.requestId, controller);
  engine.recognize(message.image, { signal: controller.signal })
    .then((value) => respond({ ok: true, value }), (error) => respond({ ok: false, error: error.message }))
    .finally(() => jobs.delete(message.requestId));
  return true;
});
