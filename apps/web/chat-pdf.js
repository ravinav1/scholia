import * as pdfjs from 'pdfjs-dist/build/pdf.mjs';
import { textContentToString } from '../chrome/src/pdf-context.js';

// The web workspace has its own same-origin PDF worker; extension OCR is not available here.
export async function extractChatPDF(file, { signal, maxCharacters }) {
  pdfjs.GlobalWorkerOptions.workerSrc = '/pdf.worker.mjs';
  const task = pdfjs.getDocument({ data: new Uint8Array(await file.arrayBuffer()), isEvalSupported: false, cMapUrl: '/cmaps/', cMapPacked: true, standardFontDataUrl: '/standard_fonts/' });
  const abort = () => task.destroy();
  signal?.addEventListener('abort', abort, { once: true });
  try {
    signal?.throwIfAborted();
    const pdf = await task.promise;
    let context = '', extractedCharacters = 0, readPages = 0;
    for (let number = 1; number <= pdf.numPages && context.length < maxCharacters; number++) {
      signal?.throwIfAborted();
      const page = await pdf.getPage(number);
      const text = textContentToString((await page.getTextContent()).items);
      context += `\n\n[Page ${number}]\n${text.trim() || '[No readable text. Attach a page image or an OCR export for this page.]'}`;
      extractedCharacters += text.length;
      readPages = number;
      page.cleanup();
    }
    return { context, extractedCharacters, truncated: context.length > maxCharacters || readPages < pdf.numPages };
  } finally { signal?.removeEventListener('abort', abort); await task.destroy(); }
}
