import { safeSourceUrl } from '../tab-context.js';

export const PDF_MIME_TYPE = 'application/pdf';

const NAVIGABLE_PDF_PROTOCOLS = new Set(['http:', 'https:', 'file:']);
const ORIGINAL_PDF_PROTOCOLS = new Set([...NAVIGABLE_PDF_PROTOCOLS, 'blob:', 'data:']);

function parsedUrl(value) {
  try {
    return new URL(String(value || ''));
  } catch {
    return null;
  }
}

export function pdfMimeHandlerAvailable(chromeApi = globalThis.chrome) {
  const handler = chromeApi?.runtime?.getManifest?.()?.mime_types_handler?.[PDF_MIME_TYPE];
  return handler?.handler_url === 'pdf-viewer.html'
    && typeof chromeApi?.mimeHandler?.getStreamInfo === 'function';
}

export async function pdfMimeHandlerEnabled(chromeApi = globalThis.chrome) {
  if (!pdfMimeHandlerAvailable(chromeApi)
      || typeof chromeApi.mimeHandler.getMimeHandlerOptions !== 'function') return false;
  try {
    const options = await chromeApi.mimeHandler.getMimeHandlerOptions(PDF_MIME_TYPE);
    return options?.enabled !== false;
  } catch {
    return false;
  }
}

export function pdfMimeNavigationTarget(value) {
  const url = parsedUrl(value);
  return url && NAVIGABLE_PDF_PROTOCOLS.has(url.protocol) ? url.href : '';
}

export function pdfMimeHandlerFrameId(contexts, handlerUrl) {
  const handler = parsedUrl(handlerUrl);
  if (!handler || handler.protocol !== 'chrome-extension:') return null;
  for (const context of Array.isArray(contexts) ? contexts : []) {
    const documentUrl = parsedUrl(context?.documentUrl);
    const frameId = Number(context?.frameId);
    if (documentUrl?.origin === handler.origin
        && documentUrl.pathname === handler.pathname
        && Number.isInteger(frameId)
        && frameId >= 0) return frameId;
  }
  return null;
}

export function normalizePdfMimeStreamInfo(value) {
  const originalUrl = parsedUrl(value?.originalUrl);
  const streamUrl = String(value?.streamUrl || '').trim();
  const mimeType = String(value?.mimeType || PDF_MIME_TYPE).toLowerCase();
  if (!originalUrl || !ORIGINAL_PDF_PROTOCOLS.has(originalUrl.protocol)
      || !streamUrl || mimeType !== PDF_MIME_TYPE) return null;
  return {
    embedded: value?.embedded === true,
    mimeType: PDF_MIME_TYPE,
    originalUrl: originalUrl.href,
    responseHeaders: value?.responseHeaders && typeof value.responseHeaders === 'object'
      ? value.responseHeaders
      : {},
    streamUrl,
    tabId: Number.isInteger(value?.tabId) ? value.tabId : null
  };
}

export async function activePdfMimeStreamInfo(chromeApi = globalThis.chrome) {
  if (!pdfMimeHandlerAvailable(chromeApi)) return null;
  try {
    return normalizePdfMimeStreamInfo(await chromeApi.mimeHandler.getStreamInfo());
  } catch {
    return null;
  }
}

function pdfTitleFromUrl(value) {
  const url = parsedUrl(value);
  if (!url) return 'PDF document';
  const encodedName = url.pathname.split('/').filter(Boolean).at(-1) || '';
  let name = encodedName;
  try { name = decodeURIComponent(encodedName); } catch {}
  return name.trim().slice(0, 500) || url.hostname || 'PDF document';
}

export function pdfMimeSource(value) {
  const stream = normalizePdfMimeStreamInfo(value);
  if (!stream) return null;
  return {
    pageTitle: pdfTitleFromUrl(stream.originalUrl),
    pdfUrl: stream.originalUrl,
    url: safeSourceUrl(stream.originalUrl),
    sourceKind: 'pdf',
    mimeHandler: true
  };
}
