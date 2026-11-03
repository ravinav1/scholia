import test from 'node:test';
import assert from 'node:assert/strict';
import { createPdfOcrReader, MAX_OCR_PAGES, mergePdfOcrText, sparsePdfText } from '../apps/chrome/src/pdf-ocr.js';
import { createOcrQueue } from '../apps/chrome/src/ocr-runtime.js';
import { forwardOcrRequest } from '../apps/chrome/src/ocr-broker.js';

function fixture(options = {}) {
  const calls = [], canvases = [];
  const reader = createPdfOcrReader({
    imageOperations: [42], totalPages: 15,
    canvasFactory: () => {
      const canvas = { width: 0, height: 0, getContext: () => ({}), toDataURL: () => 'data:image/png;base64,AAAA' };
      canvases.push(canvas);
      return canvas;
    },
    recognize: async (image) => { calls.push(image); return { text: 'Scanned article evidence is readable.', confidence: 90 }; },
    ...options
  });
  const page = (number = 1, image = true) => ({
    pageNumber: number,
    getOperatorList: async () => ({ fnArray: image ? [42] : [] }),
    getViewport: ({ scale }) => ({ width: 612 * scale, height: 792 * scale }),
    render: () => ({ promise: Promise.resolve(), cancel() {} })
  });
  return { reader, page, calls, canvases };
}

test('scanned and mixed pages recover text; native text and duplicate lines are preserved correctly', async () => {
  const { reader, page, calls, canvases } = fixture();
  const scanned = await reader.readPage(page(1), '');
  const mixed = await reader.readPage(page(2), 'Original heading');
  assert.match(scanned, /local OCR.*\nScanned article/s);
  assert.match(mixed, /Original heading\nScanned article/);
  assert.equal(calls.length, 2);
  assert.ok(canvases.every((canvas) => canvas.width === 0 && canvas.height === 0));
  assert.equal(reader.summary().ocrPageCount, 2);
  assert.equal(mergePdfOcrText('Heading', 'Heading\nNew evidence'), 'Heading\nNew evidence');
  assert.equal(mergePdfOcrText('Original heading\nCaption', 'Caption\nNew evidence'), 'Original heading\nCaption\nNew evidence');
});

test('readable pages and short native headings without images bypass OCR', async () => {
  const { reader, page, calls } = fixture();
  const native = 'Fully selectable evidence. '.repeat(30);
  assert.equal(sparsePdfText(native), false);
  assert.equal(await reader.readPage(page(1), native), native);
  assert.equal(await reader.readPage(page(2, false), 'Short heading'), 'Short heading');
  assert.equal(calls.length, 0);
});

test('all 15 scanned article pages are recognized and repeated concurrent page requests share work', async () => {
  const { reader, page, calls } = fixture();
  await Promise.all(Array.from({ length: 15 }, (_, index) => reader.readPage(page(index + 1), '')));
  await Promise.all([reader.readPage(page(8), ''), reader.readPage(page(8), '')]);
  assert.equal(calls.length, 15);
  assert.equal(reader.summary().ocrPageCount, 15);
});

test('OCR failures and low-confidence text retain existing selectable text', async () => {
  for (const recognize of [async () => { throw new Error('Worker failed'); }, async () => ({ text: 'uncertain', confidence: 12 })]) {
    const { reader, page } = fixture({ recognize });
    assert.equal(await reader.readPage(page(), 'Native caption'), 'Native caption');
    assert.match(reader.summary().ocrNotice, /could not recover reliable text/);
    assert.equal(reader.summary().ocrPageCount, 0);
  }
});

test('OCR cancellation propagates instead of publishing a partial page result', async () => {
  const controller = new AbortController();
  const { reader, page } = fixture({ signal: controller.signal, recognize: async () => {
    controller.abort(); return { text: 'Late result', confidence: 99 };
  } });
  await assert.rejects(reader.readPage(page(), ''), { name: 'AbortError' });
  assert.equal(reader.summary().ocrPageCount, 0);
});

test('large scans keep OCR work bounded and disclose skipped pages', async () => {
  const { reader, page, calls } = fixture();
  for (let number = 1; number <= MAX_OCR_PAGES + 1; number++) await reader.readPage(page(number), '');
  assert.equal(calls.length, MAX_OCR_PAGES);
  assert.match(reader.summary().ocrNotice, /1 sparse pages were skipped/);
});

test('OCR worker jobs time out and can recover with a fresh worker', async () => {
  const previous = globalThis.chrome;
  globalThis.chrome = { runtime: { getURL: (path) => path } };
  let workers = 0, terminated = 0;
  const queue = createOcrQueue({ timeoutMs: 10, workerFactory: async () => {
    const first = ++workers === 1;
    return { setParameters: async () => {}, terminate: async () => { terminated++; },
      recognize: () => first ? new Promise(() => {}) : Promise.resolve({ data: { text: 'Recovered', confidence: 90 } }) };
  } });
  try {
    await assert.rejects(queue.recognize('image'), /time limit/);
    assert.deepEqual(await queue.recognize('image'), { text: 'Recovered', confidence: 90 });
    assert.equal(workers, 2);
    assert.equal(terminated, 1);
  } finally { queue.release(); globalThis.chrome = previous; }
});

test('cancelling an active OCR job terminates its worker and skips cancelled queued jobs', async () => {
  const previous = globalThis.chrome;
  globalThis.chrome = { runtime: { getURL: (path) => path } };
  let terminated = 0, start;
  const started = new Promise((resolve) => { start = resolve; });
  const queue = createOcrQueue({ workerFactory: async () => ({
    setParameters: async () => {}, terminate: async () => { terminated++; },
    recognize: () => { start(); return new Promise(() => {}); }
  }) });
  const active = new AbortController(), queued = new AbortController();
  try {
    const first = assert.rejects(queue.recognize('image', { signal: active.signal }), { name: 'AbortError' });
    const second = assert.rejects(queue.recognize('image', { signal: queued.signal }), { name: 'AbortError' });
    await started;
    queued.abort(); active.abort();
    await Promise.all([first, second]);
    assert.equal(terminated, 1);
  } finally { queue.release(); globalThis.chrome = previous; }
});

test('cancelling while the OCR document starts prevents a late recognition request', async () => {
  const previous = globalThis.chrome;
  let complete, started, created = false;
  const starting = new Promise((resolve) => { started = resolve; });
  const sent = [];
  globalThis.chrome = {
    runtime: { id: 'scholia', getURL: (path) => path, getContexts: async () => created ? [{}] : [],
      sendMessage: async (message) => { sent.push(message); return { ok: true }; } },
    offscreen: { createDocument: () => { started(); return new Promise((resolve) => { complete = () => { created = true; resolve(); }; }); } }
  };
  const sender = { id: 'scholia', documentId: 'document-1' };
  try {
    const result = assert.rejects(forwardOcrRequest({ type: 'SCHOLIA_OCR_RECOGNIZE', requestId: 'test', image: 'data:image/png;base64,AAAA' }, sender), /cancelled/);
    await starting;
    const cancel = forwardOcrRequest({ type: 'SCHOLIA_OCR_CANCEL', requestId: 'test' }, sender);
    complete();
    await Promise.all([result, cancel]);
    assert.ok(sent.every((message) => message.type === 'SCHOLIA_OCR_CANCEL'));
  } finally { globalThis.chrome = previous; }
});
