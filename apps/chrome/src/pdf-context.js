import { detectDocumentLanguage } from './document-language.js';
import { createPdfOcrReader } from './pdf-ocr.js';

export const MAX_PDF_BYTES = 1024 * 1024 * 1024;
export const PDF_RANGE_CHUNK_BYTES = 1024 * 1024;
export const MAX_EXTRACTED_CHARACTERS = 8_000_000;
export const MAX_EXTRACTED_PAGES = 5_000;

const MAX_PDF_WRAPPER_BYTES = 2 * 1024 * 1024;
const MAX_PDF_RESOLUTION_HOPS = 4;

export const PDF_SIZE_LIMIT_MESSAGE = 'This PDF is larger than Scholia\'s 1 GB local-processing limit.';

export function assertPdfSize(size) {
  const bytes = Number(size);
  if (!Number.isFinite(bytes) || bytes < 0) throw new Error('Scholia could not determine this PDF\'s size.');
  if (bytes > MAX_PDF_BYTES) throw new Error(PDF_SIZE_LIMIT_MESSAGE);
  if (bytes === 0) throw new Error('The selected PDF is empty.');
  return bytes;
}

function compactLine(value) {
  return String(value || '').replace(/[\t\f\v ]+/g, ' ').trim();
}

function needsSpace(left, right, gap, fontSize) {
  if (!left || !right || /\s$/.test(left) || /^\s/.test(right)) return false;
  if (/^[,.;:!?%)\]}]/.test(right) || /[(\[{/]$/.test(left)) return false;
  if (Number.isFinite(gap)) return gap > Math.max(0.8, fontSize * 0.08);
  return true;
}

export function textContentToString(items = []) {
  const lines = [];
  let line = '';
  let previous = null;

  const flush = () => {
    const clean = compactLine(line);
    if (clean) lines.push(clean);
    line = '';
    previous = null;
  };

  for (const item of items) {
    if (!item || typeof item.str !== 'string') continue;
    const text = item.str.replace(/\s+/g, ' ');
    const transform = Array.isArray(item.transform) ? item.transform : [];
    const x = Number(transform[4]);
    const y = Number(transform[5]);
    const fontSize = Math.max(1, Math.abs(Number(transform[3])) || Number(item.height) || 10);
    const changedLine = previous
      && Number.isFinite(y)
      && Number.isFinite(previous.y)
      && Math.abs(y - previous.y) > Math.max(fontSize, previous.fontSize) * 0.45;
    if (changedLine) flush();

    const gap = previous && Number.isFinite(x) && Number.isFinite(previous.endX)
      ? x - previous.endX
      : Number.NaN;
    if (needsSpace(line, text, gap, fontSize)) line += ' ';
    line += text;

    previous = {
      y,
      fontSize,
      endX: Number.isFinite(x) ? x + (Number(item.width) || 0) : Number.NaN
    };
    if (item.hasEOL) flush();
  }
  flush();
  return lines.join('\n');
}

function pageSummary(text) {
  const first = String(text || '').split('\n').map(compactLine).find(Boolean) || 'No extractable text';
  return first.length <= 160 ? first : `${first.slice(0, 157).trimEnd()}…`;
}

export function formatPdfContext(pages = [], totalPages = pages.length, { indexing = false } = {}) {
  const total = Math.max(pages.length, Number(totalPages) || 0);
  const normalizedPages = pages.map((page) => String(page || '').trim());
  const omitted = total > normalizedPages.length
    ? indexing
      ? `\n\n[PDF text indexing is still in progress. Pages after ${normalizedPages.length} of ${total} are not included yet.]`
      : `\n\n[PDF extraction stopped after page ${normalizedPages.length} of ${total} at Scholia's local safety limit.]`
    : '';
  return {
    context: normalizedPages
      .map((text, index) => `[PDF page ${index + 1} of ${total}]\n${text || '(No extractable text on this page.)'}`)
      .join('\n\n') + omitted,
    outline: normalizedPages
      .map((text, index) => `- PDF page ${index + 1}: ${pageSummary(text)}`)
      .concat(total > normalizedPages.length ? [`- PDF pages ${normalizedPages.length + 1}–${total}: ${indexing ? 'not indexed yet' : 'omitted at local safety limit'}`] : [])
      .join('\n'),
    pageCount: total,
    extractedPageCount: normalizedPages.length,
    extractedCharacters: normalizedPages.reduce((sum, text) => sum + text.length, 0)
  };
}

export async function readPdfBlobResponse(response, onProgress = () => {}) {
  if (!response.ok) throw new Error(`The PDF could not be downloaded (HTTP ${response.status}).`);
  const declaredLength = Number(response.headers.get('content-length'));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_PDF_BYTES) {
    try { await response.body?.cancel?.(); } catch {}
    throw new Error(PDF_SIZE_LIMIT_MESSAGE);
  }

  let received = 0;
  let body = response.body;
  if (body?.pipeThrough && typeof TransformStream === 'function') {
    body = body.pipeThrough(new TransformStream({
      transform(chunk, controller) {
        received += chunk?.byteLength || 0;
        if (received > MAX_PDF_BYTES) throw new Error(PDF_SIZE_LIMIT_MESSAGE);
        onProgress({ phase: 'download', loaded: received, total: declaredLength || 0 });
        controller.enqueue(chunk);
      }
    }));
  }

  const type = response.headers.get('content-type') || 'application/pdf';
  const blob = body
    ? await new Response(body, { headers: { 'content-type': type } }).blob()
    : await response.blob();
  assertPdfSize(blob.size);
  if (!received) {
    received = blob.size;
    onProgress({ phase: 'download', loaded: received, total: declaredLength || blob.size });
  }
  return blob;
}

export async function readPdfResponse(response, onProgress = () => {}) {
  const blob = await readPdfBlobResponse(response, onProgress);
  return new Uint8Array(await blob.arrayBuffer());
}

function looksLikePdf(bytes) {
  const prefix = new TextDecoder('latin1').decode(bytes.subarray(0, Math.min(1024, bytes.length)));
  return prefix.includes('%PDF-');
}

function parsedHttpUrl(value, base) {
  try {
    const url = new URL(String(value || ''), base);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return null;
    url.username = '';
    url.password = '';
    return url;
  } catch {
    return null;
  }
}

function parsedFetchUrl(value) {
  try {
    const url = new URL(String(value || ''));
    return new Set(['http:', 'https:', 'file:', 'data:', 'blob:']).has(url.protocol) ? url : null;
  } catch {
    return null;
  }
}

function decodedPathname(url) {
  try { return decodeURIComponent(url.pathname); } catch { return url.pathname; }
}

function isPdfPath(url) {
  return /\.pdf$/i.test(decodedPathname(url));
}

/**
 * Converts well-known repository preview URLs to download endpoints while
 * leaving the original page URL available to the viewer as a fallback.
 */
export function pdfWrapperDownloadUrl(value) {
  const url = parsedHttpUrl(value);
  if (!url || !isPdfPath(url)) return '';
  const hostname = url.hostname.toLowerCase();

  if ((hostname === 'github.com' || hostname.endsWith('.github.com'))
      && /\/blob\//i.test(url.pathname)) {
    url.search = '?raw=1';
    url.hash = '';
    return url.href;
  }
  if ((hostname === 'gitlab.com' || hostname.endsWith('.gitlab.com'))
      && /\/-\/blob\//i.test(url.pathname)) {
    url.pathname = url.pathname.replace(/\/-\/blob\//i, '/-/raw/');
    url.search = '';
    url.hash = '';
    return url.href;
  }
  if ((hostname === 'bitbucket.org' || hostname.endsWith('.bitbucket.org'))
      && /\/src\//i.test(url.pathname)) {
    url.pathname = url.pathname.replace(/\/src\//i, '/raw/');
    url.search = '';
    url.hash = '';
    return url.href;
  }
  return '';
}

function decodeHtmlAttribute(value) {
  return String(value || '')
    .replace(/&amp;/gi, '&')
    .replace(/&quot;/gi, '"')
    .replace(/&#(?:x27|39);/gi, "'")
    .replace(/&#x([0-9a-f]+);/gi, (_, digits) => String.fromCodePoint(Number.parseInt(digits, 16)))
    .replace(/&#([0-9]+);/g, (_, digits) => String.fromCodePoint(Number.parseInt(digits, 10)));
}

function htmlAttribute(tag, name) {
  const escapedName = String(name).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = String(tag || '').match(new RegExp(
    `\\b${escapedName}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'=<>\u0060]+))`,
    'i'
  ));
  return decodeHtmlAttribute(match?.[1] ?? match?.[2] ?? match?.[3] ?? '');
}

function likelyDownloadCandidate(value, base, { embedded = false, download = false } = {}) {
  const raw = String(value || '').trim();
  if (!raw) return '';
  const url = parsedHttpUrl(raw, base);
  if (!url) return '';
  const path = decodedPathname(url);
  const knownWrapper = pdfWrapperDownloadUrl(url.href);
  const rawHost = url.hostname.toLowerCase() === 'raw.githubusercontent.com';
  const likelyPath = /\.pdf$/i.test(path)
    || /\/(?:raw|download|downloads)(?:\/|$)/i.test(path)
    || /(?:^|[?&])download(?:=|&|$)/i.test(url.search);
  if (!embedded && !download && !knownWrapper && !rawHost && !likelyPath) return '';
  url.hash = '';
  return knownWrapper || url.href;
}

/**
 * Finds the actual document behind a bounded HTML PDF-preview response.
 * Candidates are deliberately limited to embedded resources and links that
 * look like downloads, avoiding arbitrary navigation from untrusted markup.
 */
export function pdfDownloadUrlFromHtml(html, baseUrl) {
  const source = String(html || '');
  const base = parsedHttpUrl(baseUrl)?.href;
  if (!source || !base) return '';

  for (const match of source.matchAll(/<(?:embed|iframe)\b[^>]*>/gi)) {
    const candidate = likelyDownloadCandidate(htmlAttribute(match[0], 'src'), base, { embedded: true });
    if (candidate) return candidate;
  }
  for (const match of source.matchAll(/<object\b[^>]*>/gi)) {
    const candidate = likelyDownloadCandidate(htmlAttribute(match[0], 'data'), base, { embedded: true });
    if (candidate) return candidate;
  }
  for (const match of source.matchAll(/<meta\b[^>]*>/gi)) {
    const tag = match[0];
    if (!/^refresh$/i.test(htmlAttribute(tag, 'http-equiv'))) continue;
    const refresh = htmlAttribute(tag, 'content').match(/(?:^|;)\s*url\s*=\s*(.+)$/i)?.[1]
      ?.trim().replace(/^(?:"([\s\S]*)"|'([\s\S]*)')$/, '$1$2');
    const candidate = likelyDownloadCandidate(refresh, base, { embedded: true });
    if (candidate) return candidate;
  }

  const anchors = [...source.matchAll(/<a\b[^>]*>/gi)].map((match) => match[0]);
  for (const tag of anchors) {
    const explicitDownload = /\bdownload(?:\s|=|>)/i.test(tag)
      || /(?:download-raw|raw-file|download-file)/i.test(tag);
    if (!explicitDownload) continue;
    const candidate = likelyDownloadCandidate(htmlAttribute(tag, 'href'), base, { download: true });
    if (candidate) return candidate;
  }
  for (const tag of anchors) {
    const candidate = likelyDownloadCandidate(htmlAttribute(tag, 'href'), base);
    if (candidate) return candidate;
  }
  return '';
}

function responseDownloadUrl(response, baseUrl) {
  for (const name of ['x-raw-download', 'x-pdf-url']) {
    const candidate = likelyDownloadCandidate(response.headers.get(name), response.url || baseUrl, {
      download: true
    });
    if (candidate) return candidate;
  }
  return '';
}

async function boundedResponseText(response) {
  const declaredLength = Number(response.headers.get('content-length'));
  if (Number.isFinite(declaredLength) && declaredLength > MAX_PDF_WRAPPER_BYTES) {
    try { await response.body?.cancel?.(); } catch {}
    return '';
  }
  if (!response.body?.getReader) {
    const text = await response.text();
    return new TextEncoder().encode(text).byteLength <= MAX_PDF_WRAPPER_BYTES ? text : '';
  }

  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let received = 0;
  let text = '';
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      received += value?.byteLength || 0;
      if (received > MAX_PDF_WRAPPER_BYTES) {
        await reader.cancel();
        return '';
      }
      text += decoder.decode(value, { stream: true });
    }
    return text + decoder.decode();
  } finally {
    reader.releaseLock();
  }
}

function withOriginalFragment(value, originalUrl) {
  const url = parsedFetchUrl(value);
  const original = parsedFetchUrl(originalUrl);
  if (!url) return String(value || '');
  if (!url.hash && original?.hash) url.hash = original.hash;
  return url.href;
}

function nonPdfMessage() {
  return 'The document address returned a web page instead of PDF data, and Scholia could not find its download. Open the original page or choose the PDF file from the side panel.';
}

/** Fetches a PDF while resolving common HTML preview and repository wrapper URLs. */
export async function fetchPdfDocument(url, { signal, onProgress = () => {} } = {}) {
  const original = String(url || '').trim();
  const direct = pdfWrapperDownloadUrl(original);
  const candidates = direct && direct !== original ? [direct, original] : [original];
  const seen = new Set();
  let lastError = null;

  while (candidates.length && seen.size < MAX_PDF_RESOLUTION_HOPS) {
    const candidate = candidates.shift();
    const parsedCandidate = parsedFetchUrl(candidate);
    if (!parsedCandidate || seen.has(parsedCandidate.href)) continue;
    seen.add(parsedCandidate.href);

    let response;
    try {
      response = await fetch(parsedCandidate.href, {
        credentials: 'include', cache: 'force-cache', signal
      });
    } catch (error) {
      if (error?.name === 'AbortError') throw error;
      lastError = new Error('Scholia could not read this PDF URL. If it is local or access-controlled, choose the PDF file from the side panel.');
      continue;
    }

    if (!response.ok) {
      try { await response.body?.cancel?.(); } catch {}
      lastError = new Error(`The PDF could not be downloaded (HTTP ${response.status}).`);
      continue;
    }

    const hintedUrl = responseDownloadUrl(response, parsedCandidate.href);
    if (hintedUrl && !seen.has(hintedUrl)) {
      try { await response.body?.cancel?.(); } catch {}
      candidates.unshift(hintedUrl);
      continue;
    }

    const contentType = String(response.headers.get('content-type') || '').toLowerCase();
    if (contentType.includes('text/html') || contentType.includes('application/xhtml+xml')) {
      const wrapperUrl = pdfDownloadUrlFromHtml(
        await boundedResponseText(response),
        response.url || parsedCandidate.href
      );
      if (wrapperUrl && !seen.has(wrapperUrl)) candidates.unshift(wrapperUrl);
      else lastError = new Error(nonPdfMessage());
      continue;
    }

    const blob = await readPdfBlobResponse(response, onProgress);
    const prefix = new Uint8Array(await blob.slice(0, Math.min(1024, blob.size)).arrayBuffer());
    if (looksLikePdf(prefix)) {
      return {
        blob,
        url: withOriginalFragment(response.url || parsedCandidate.href, original)
      };
    }

    const wrapperUrl = blob.size <= MAX_PDF_WRAPPER_BYTES
      ? pdfDownloadUrlFromHtml(await blob.text(), response.url || parsedCandidate.href)
      : '';
    if (wrapperUrl && !seen.has(wrapperUrl)) candidates.unshift(wrapperUrl);
    else lastError = new Error(nonPdfMessage());
  }

  throw lastError || new Error(nonPdfMessage());
}

export async function fetchPdfBlob(url, options = {}) {
  return (await fetchPdfDocument(url, options)).blob;
}

export async function fetchPdfBytes(url, options = {}) {
  const blob = await fetchPdfBlob(url, options);
  return new Uint8Array(await blob.arrayBuffer());
}

function addCoveredRange(ranges, begin, end) {
  let start = begin;
  let finish = end;
  let added = Math.max(0, end - begin);
  for (let index = ranges.length - 1; index >= 0; index -= 1) {
    const range = ranges[index];
    if (range.end < start || range.begin > finish) continue;
    const overlap = Math.max(0, Math.min(finish, range.end) - Math.max(start, range.begin));
    added -= overlap;
    start = Math.min(start, range.begin);
    finish = Math.max(finish, range.end);
    ranges.splice(index, 1);
  }
  ranges.push({ begin: start, end: finish });
  ranges.sort((left, right) => left.begin - right.begin);
  return Math.max(0, added);
}

function isBlobSource(value) {
  return typeof Blob !== 'undefined' && value instanceof Blob;
}

export async function pdfInputOptions(pdfjs, input, {
  signal,
  onProgress = () => {},
  fileName = input?.name || ''
} = {}) {
  if (!isBlobSource(input)) {
    const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
    assertPdfSize(bytes.byteLength);
    if (!looksLikePdf(bytes)) throw new Error('The selected file is not a readable PDF.');
    return { data: bytes };
  }

  const size = assertPdfSize(input.size);
  const initialLength = Math.min(PDF_RANGE_CHUNK_BYTES, size);
  const initialData = new Uint8Array(await input.slice(0, initialLength).arrayBuffer());
  if (!looksLikePdf(initialData)) throw new Error('The selected file is not a readable PDF.');

  const coveredRanges = [{ begin: 0, end: initialData.byteLength }];
  let loaded = initialData.byteLength;
  let aborted = Boolean(signal?.aborted);
  const transport = new class extends pdfjs.PDFDataRangeTransport {
    constructor() {
      super(size, initialData, false, String(fileName || 'document.pdf'));
    }

    requestDataRange(begin, end) {
      if (aborted) return;
      const safeBegin = Math.max(0, Math.min(size, Number(begin) || 0));
      const safeEnd = Math.max(safeBegin, Math.min(size, Number(end) || 0));
      input.slice(safeBegin, safeEnd).arrayBuffer().then((buffer) => {
        if (aborted) return;
        const chunk = new Uint8Array(buffer);
        loaded += addCoveredRange(coveredRanges, safeBegin, safeBegin + chunk.byteLength);
        onProgress({ phase: 'load', loaded, total: size });
        this.onDataProgress(loaded, size);
        this.onDataRange(safeBegin, chunk);
      }).catch(() => {
        if (!aborted) this.onDataRange(safeBegin, new Uint8Array());
      });
    }

    abort() {
      aborted = true;
    }
  }();

  onProgress({ phase: 'load', loaded, total: size });
  return {
    range: transport,
    length: size,
    rangeChunkSize: PDF_RANGE_CHUNK_BYTES,
    disableStream: true,
    disableAutoFetch: true
  };
}

export async function extractPdfContext(input, { onProgress = () => {}, signal, password = '', maxCharacters = MAX_EXTRACTED_CHARACTERS } = {}) {
  const characterLimit = Math.max(1, Math.min(50_000_000, maxCharacters));
  const pdfjs = await import(chrome.runtime.getURL('vendor/pdfjs/pdf.min.mjs'));
  // Content-script dialogs cannot create an extension worker from a page origin.
  if (globalThis.location?.protocol !== 'chrome-extension:' && !globalThis.pdfjsWorker) {
    globalThis.pdfjsWorker = await import(chrome.runtime.getURL('vendor/pdfjs/pdf.worker.min.mjs'));
  }
  pdfjs.GlobalWorkerOptions.workerSrc = chrome.runtime.getURL('vendor/pdfjs/pdf.worker.min.mjs');
  const assetRoot = chrome.runtime.getURL('vendor/pdfjs/');
  const inputOptions = await pdfInputOptions(pdfjs, input, { signal, onProgress });
  if (signal?.aborted) throw new DOMException('PDF extraction was cancelled.', 'AbortError');
  const loadingTask = pdfjs.getDocument({
    ...inputOptions,
    password: password || undefined,
    cMapUrl: `${assetRoot}cmaps/`,
    cMapPacked: true,
    standardFontDataUrl: `${assetRoot}standard_fonts/`,
    enableXfa: true,
    isEvalSupported: false,
    stopAtErrors: false,
    useSystemFonts: true
  });

  const abort = () => loadingTask.destroy();
  signal?.addEventListener('abort', abort, { once: true });
  try {
    const pdf = await loadingTask.promise;
    const ocr = createPdfOcrReader({
      signal, onProgress, totalPages: pdf.numPages,
      imageOperations: [pdfjs.OPS.paintImageXObject, pdfjs.OPS.paintInlineImageXObject, pdfjs.OPS.paintImageMaskXObject]
    });
    const pages = [];
    let extractedCharacters = 0;
    const pagesToRead = Math.min(pdf.numPages, MAX_EXTRACTED_PAGES);
    for (let pageNumber = 1; pageNumber <= pagesToRead; pageNumber += 1) {
      if (signal?.aborted) throw new DOMException('PDF extraction was cancelled.', 'AbortError');
      if (extractedCharacters >= characterLimit) break;
      const page = await pdf.getPage(pageNumber);
      const nativeText = textContentToString((await page.getTextContent()).items);
      const text = await ocr.readPage(page, nativeText, pageNumber);
      const room = characterLimit - extractedCharacters;
      pages.push(room > 0 ? text.slice(0, room) : '');
      extractedCharacters += Math.min(text.length, Math.max(0, room));
      page.cleanup();
      onProgress({ phase: 'extract', page: pageNumber, total: pdf.numPages });
    }
    let metadata = {};
    let metadataLanguage = '';
    try {
      const details = await pdf.getMetadata();
      metadata = details.info || {};
      metadataLanguage = details.metadata?.get?.('dc:language') || metadata.Language || '';
    } catch {}
    const formatted = formatPdfContext(pages, pdf.numPages);
    return {
      ...formatted,
      ...ocr.summary(),
      title: compactLine(metadata.Title || '').slice(0, 500),
      pageLanguage: await detectDocumentLanguage({
        context: formatted.context,
        fallback: metadataLanguage
      }),
      truncated: formatted.extractedPageCount < formatted.pageCount
        || formatted.extractedCharacters >= characterLimit
    };
  } catch (error) {
    if (signal?.aborted) throw new DOMException('PDF extraction was cancelled.', 'AbortError');
    if (error?.name === 'PasswordException') {
      throw new Error('This PDF is password-protected. Unlock it first, then choose an unlocked copy from the side panel.');
    }
    throw error;
  } finally {
    signal?.removeEventListener('abort', abort);
    await loadingTask.destroy().catch(() => {});
  }
}
