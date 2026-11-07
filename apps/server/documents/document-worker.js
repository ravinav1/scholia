import { parentPort, workerData } from 'node:worker_threads';
import { extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { safePlainText, unreadablePageCount } from './document-formats.js';
import { DOMParser } from 'linkedom';
import { htmlReadingText } from '../../../packages/core/src/course-documents.js';
import { extractOfficeText } from '../../chrome/src/office-text.js';
import { analyzeMaterial } from './material-analysis.js';
import { recognizeImage, sparseText } from './document-ocr.js';
globalThis.DOMParser = DOMParser;
const { name, data } = workerData,
  bytes = new Uint8Array(data),
  ext = extname(name).slice(1).toLowerCase();
try {
  let kind = 'text',
    notice = '',
    pages = [],
    images = {};
  const textPages = (text) =>
    Array.from({ length: Math.max(1, Math.ceil(text.length / 14000)) }, (_, i) => ({
      number: i + 1,
      text: text.slice(i * 14000, (i + 1) * 14000),
    }));
  if (ext === 'pdf') {
    kind = 'pdf';
    const canvas = await import('@napi-rs/canvas');
    globalThis.DOMMatrix = canvas.DOMMatrix;
    globalThis.Path2D = canvas.Path2D;
    globalThis.ImageData = canvas.ImageData;
    const { getDocument, OPS } = await import('pdfjs-dist/legacy/build/pdf.mjs');
    // PDF.js normally zeroes canvas dimensions when releasing image buffers.
    // Replace the backing allocation instead: resizing to zero crashes some
    // native canvas versions. Worker lifetime still bounds retained bitmaps.
    class OCRCanvasFactory {
      create(width, height) {
        const bitmap = canvas.createCanvas(Math.ceil(width), Math.ceil(height));
        return { canvas: bitmap, context: bitmap.getContext('2d') };
      }
      reset(target, width, height) {
        Object.assign(target, this.create(width, height));
      }
      destroy(target) {
        target.canvas = null;
        target.context = null;
      }
    }
    const loading = getDocument({
      data: bytes,
      useSystemFonts: true,
      isEvalSupported: false,
      disableFontFace: true,
      CanvasFactory: OCRCanvasFactory,
      standardFontDataUrl: fileURLToPath(
        new URL('standard_fonts/', import.meta.resolve('pdfjs-dist/package.json'))
      ),
    });
    const pdf = await loading.promise;
    if (pdf.numPages > 2000)
      throw new Error('This PDF exceeds 2,000 pages. Split it into smaller documents.');
    let count = 0;
    for (let number = 1; number <= pdf.numPages; number++) {
      const page = await pdf.getPage(number),
        content = await page.getTextContent();
      const text = content.items.map((item) => item.str + (item.hasEOL ? '\n' : ' ')).join('');
      count += text.length;
      if (count > 8_000_000)
        throw new Error('The extracted document text exceeds the index limit.');
      pages.push({ number, text, extractionMethod: text.trim() ? 'text' : 'none' });
      page.cleanup();
    }
    const candidates = pages.filter((page) => sparseText(page.text));
    const positions = [
      ...new Set([
        0,
        1,
        2,
        Math.floor(candidates.length / 3),
        Math.floor((candidates.length * 2) / 3),
        candidates.length - 1,
      ]),
    ];
    const deadline = Date.now() + 24_000;
    let attempted = 0,
      recognized = 0,
      unavailable = false;
    for (const position of positions) {
      if (!candidates[position] || Date.now() >= deadline) continue;
      const indexed = candidates[position],
        page = await pdf.getPage(indexed.number);
      try {
        if (indexed.text.trim()) {
          const operations = await page.getOperatorList();
          if (
            !operations.fnArray.some((operation) =>
              [
                OPS.paintImageXObject,
                OPS.paintInlineImageXObject,
                OPS.paintImageMaskXObject,
              ].includes(operation)
            )
          )
            continue;
        }
        const size = page.getViewport({ scale: 1 });
        const scale = Math.min(2.2, Math.sqrt(4_000_000 / (size.width * size.height)));
        const viewport = page.getViewport({ scale });
        const bitmap = canvas.createCanvas(Math.ceil(viewport.width), Math.ceil(viewport.height));
        await page.render({ canvasContext: bitmap.getContext('2d'), viewport }).promise;
        const result = await recognizeImage(bitmap.toBuffer('image/png'), {
          timeout: Math.min(6000, Math.max(1, deadline - Date.now())),
        });
        attempted++;
        if (result.status === 'unavailable' || result.status === 'disabled') {
          unavailable = true;
          break;
        }
        if (result.text && result.text.length > indexed.text.trim().length * 1.2) {
          const existing = indexed.text.trim();
          indexed.text =
            existing && !result.text.toLowerCase().includes(existing.toLowerCase())
              ? `${existing}\n${result.text}`
              : result.text;
          indexed.extractionMethod = existing ? 'mixed' : 'ocr';
          indexed.ocrConfidence = result.confidence;
          recognized++;
        }
      } catch {
        // OCR is optional. A damaged visual layer must not discard readable PDF text.
      } finally {
        page.cleanup();
      }
    }
    const remaining = unreadablePageCount(pages);
    if (attempted || unavailable || remaining) {
      notice = [
        recognized ? `Local OCR recovered text on ${recognized} pages.` : '',
        unavailable ? 'Local OCR is unavailable or disabled on this server.' : '',
        candidates.length > attempted && !unavailable
          ? `OCR sampled ${attempted} of ${candidates.length} pages with little selectable text.`
          : '',
        remaining
          ? `${remaining} pages have no readable text. Their original visuals remain available.`
          : '',
        'Handwriting and mathematical notation may not be recognized accurately.',
      ]
        .filter(Boolean)
        .join(' ');
    }
    await pdf.destroy();
  } else if (['png', 'jpg', 'jpeg', 'webp', 'gif'].includes(ext)) {
    kind = 'image';
    const result =
      bytes.length <= 20_000_000
        ? await recognizeImage(bytes)
        : { text: '', confidence: 0, status: 'limit' };
    pages = [
      {
        number: 1,
        text: result.text,
        extractionMethod: result.text ? 'ocr' : 'none',
        ocrConfidence: result.confidence,
      },
    ];
    notice = result.text
      ? 'Text recognized with local OCR. Handwriting and mathematical notation may contain errors.'
      : result.status === 'unavailable' || result.status === 'disabled'
        ? 'Local OCR is unavailable or disabled on this server. The original image is saved.'
        : 'Local OCR found no reliable text or reached its processing limit. The original image is saved.';
  } else if (['docx', 'pptx', 'xlsx'].includes(ext)) {
    kind = 'office';
    const extracted = await extractOfficeText(new Blob([bytes]), 8_000_000);
    pages = textPages(extracted.text);
    if (extracted.truncated) notice = 'Only the first 8 million characters were indexed.';
  } else if (ext === 'ipynb') {
    kind = 'notebook';
    const notebook = JSON.parse(Buffer.from(bytes).toString('utf8'));
    if (!Array.isArray(notebook.cells) || notebook.cells.length > 10000)
      throw new Error('Invalid or oversized notebook.');
    let textLength = 0,
      imageBytes = 0;
    pages = notebook.cells.map((cell, i) => {
      const source = Array.isArray(cell.source) ? cell.source.join('') : String(cell.source || '');
      let text = cell.cell_type === 'code' ? `\`\`\`\n${source}\n\`\`\`` : source;
      const names = [];
      for (const [j, output] of (cell.outputs || []).entries()) {
        const plain = output.text || output.data?.['text/plain'];
        if (plain) text += '\n\n' + (Array.isArray(plain) ? plain.join('') : plain);
        const image = output.data?.['image/png'];
        if (image) {
          const encoded = Array.isArray(image) ? image.join('') : String(image);
          imageBytes += encoded.length;
          if (encoded.length > 14_000_000 || imageBytes > 40_000_000)
            throw new Error(
              'The notebook contains too much image output. Clear large outputs before importing.'
            );
          const name = `cell-${i}-${j}.png`;
          images[name] = encoded;
          names.push(name);
        }
      }
      textLength += text.length;
      if (textLength > 8_000_000) throw new Error('The notebook text exceeds the index limit.');
      return { number: i + 1, text, images: names };
    });
    if (!pages.length) pages = [{ number: 1, text: '' }];
  } else if (['html', 'htm'].includes(ext)) {
    const html = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    if (html.length > 8_000_000) throw new Error('The text exceeds the index limit.');
    pages = textPages(htmlReadingText(new DOMParser().parseFromString(html, 'text/html')));
  } else if (
    [
      'md',
      'txt',
      'csv',
      'tsv',
      'json',
      'xml',
      'html',
      'py',
      'r',
      'jl',
      'js',
      'ts',
      'java',
      'c',
      'cpp',
      'h',
      'm',
      'sh',
      'sql',
      'yaml',
      'yml',
      'tex',
      'log',
    ].includes(ext)
  ) {
    kind = ['md', 'txt'].includes(ext) ? 'text' : 'code';
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    if (text.length > 8_000_000) throw new Error('The text exceeds the index limit.');
    pages = textPages(text).map((page) => ({
      ...page,
      text: kind === 'code' ? `\`\`\`\n${page.text}\n\`\`\`` : page.text,
    }));
  } else {
    // Scientific inputs often have project-specific extensions, such as .nanowire or .eam.
    // Decode the complete bounded file; a printable prefix alone cannot identify binary data.
    const text = safePlainText(bytes, ext);
    if (text !== null) {
      kind = 'code';
      pages = textPages(text).map((page) => ({ ...page, text: `\`\`\`\n${page.text}\n\`\`\`` }));
    } else {
      kind = 'preview';
      pages = [{ number: 1, text: '' }];
      notice =
        'The original is saved, but no readable text was indexed. Download it to open in a compatible application.';
    }
  }
  const unreadablePages = unreadablePageCount(pages);
  const materialAnalysis = analyzeMaterial({ name, kind, pages });
  parentPort.postMessage({ kind, notice, pages, images, unreadablePages, materialAnalysis });
} catch (error) {
  parentPort.postMessage({ error: error.message });
}
