import { sendRuntimeMessage } from '../runtime-message.js';

export const MAX_OCR_PAGES = 50;
const MAX_OCR_PIXELS = 4_000_000;
const aborted = () => new DOMException('PDF OCR was cancelled.', 'AbortError');

export function sparsePdfText(text) {
  return (String(text || '').match(/\p{L}/gu) || []).length < 200;
}

export function mergePdfOcrText(nativeText, recognizedText) {
  const text = String(nativeText || '').trim();
  const recognized = String(recognizedText || '').trim();
  const normalize = (value) => value.toLowerCase().replace(/\s+/g, ' ').trim();
  if (!text || normalize(recognized).includes(normalize(text))) return recognized;
  const existing = normalize(text);
  const novel = recognized.split('\n').filter((line) => line.trim() && !existing.includes(normalize(line)));
  return [text, ...novel].join('\n');
}

async function recognizeLocalImage(image, { signal } = {}) {
  if (signal?.aborted) throw aborted();
  const requestId = crypto.randomUUID();
  let cancel;
  const interrupted = new Promise((_, reject) => {
    cancel = () => {
      sendRuntimeMessage({ type: 'SCHOLIA_OCR_CANCEL', requestId }).catch(() => {});
      reject(aborted());
    };
    signal?.addEventListener('abort', cancel, { once: true });
  });
  try {
    return await Promise.race([
      sendRuntimeMessage({ type: 'SCHOLIA_OCR_RECOGNIZE', requestId, image }), interrupted
    ]);
  } finally { signal?.removeEventListener('abort', cancel); }
}

/** OCR only sparse pages, retaining native text and sharing concurrent page reads. */
export function createPdfOcrReader({
  signal, onProgress = () => {}, imageOperations = [], totalPages = 0,
  recognize = recognizeLocalImage, canvasFactory = () => document.createElement('canvas')
} = {}) {
  const reads = new Map();
  let attempted = 0, recovered = 0, failed = 0, skipped = 0;
  return {
    async readPage(page, text, pageNumber = page.pageNumber) {
      if (signal?.aborted) throw aborted();
      if (!sparsePdfText(text)) return text;
      if (reads.has(pageNumber)) return reads.get(pageNumber);
      const task = (async () => {
        // Short native headings/captions without a raster layer need no OCR.
        if (String(text || '').trim()) {
          const operations = await page.getOperatorList();
          if (!operations.fnArray.some((operation) => imageOperations.includes(operation))) return text;
        }
        if (attempted >= MAX_OCR_PAGES) { skipped += 1; return text; }
        attempted += 1;
        if (signal?.aborted) throw aborted();
        onProgress({ phase: 'ocr', page: pageNumber, total: totalPages });
        const canvas = canvasFactory();
        try {
          const size = page.getViewport({ scale: 1 });
          const scale = Math.min(2.5, Math.sqrt(MAX_OCR_PIXELS / Math.max(1, size.width * size.height)));
          const viewport = page.getViewport({ scale });
          canvas.width = Math.max(1, Math.floor(viewport.width));
          canvas.height = Math.max(1, Math.floor(viewport.height));
          const rendering = page.render({ canvasContext: canvas.getContext('2d', { alpha: false }), viewport, background: 'white' });
          const cancel = () => rendering.cancel();
          signal?.addEventListener('abort', cancel, { once: true });
          try { await rendering.promise; } finally { signal?.removeEventListener('abort', cancel); }
          if (signal?.aborted) throw aborted();
          const result = await recognize(canvas.toDataURL('image/png'), { signal });
          if (signal?.aborted) throw aborted();
          if (!(Number(result?.confidence) >= 55) || !String(result?.text || '').trim()) { failed += 1; return text; }
          const merged = mergePdfOcrText(text, result.text);
          if (merged === String(text || '').trim()) return text;
          recovered += 1;
          return `[Text recognized with local OCR]\n${merged}`;
        } finally { canvas.width = 0; canvas.height = 0; }
      })().catch((error) => {
        if (signal?.aborted || error?.name === 'AbortError') throw aborted();
        failed += 1;
        return text;
      });
      reads.set(pageNumber, task);
      return task;
    },
    summary() {
      return {
        ocrPageCount: recovered,
        ocrNotice: [
          recovered ? `Local OCR recovered text on ${recovered} page${recovered === 1 ? '' : 's'}.` : '',
          failed ? `OCR could not recover reliable text on ${failed} page${failed === 1 ? '' : 's'}.` : '',
          skipped ? `OCR reached its ${MAX_OCR_PAGES}-page limit; ${skipped} sparse pages were skipped.` : ''
        ].filter(Boolean).join(' ')
      };
    }
  };
}
