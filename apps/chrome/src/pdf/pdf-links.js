const SAFE_PDF_LINK_PROTOCOLS = new Set(['http:', 'https:', 'ftp:', 'mailto:', 'tel:']);

function cleanLinkValue(value) {
  const clean = String(value || '').trim();
  return /[\u0000-\u001f\u007f]/.test(clean) ? '' : clean;
}

function doiUrl(value) {
  const clean = cleanLinkValue(value);
  const match = /^(?:doi:\s*)?(10\.\d{4,9}\/\S+)$/i.exec(clean);
  return match ? `https://doi.org/${match[1]}` : '';
}

function schemelessWebUrl(value) {
  const clean = cleanLinkValue(value);
  if (clean.startsWith('//')) return `https:${clean}`;
  return /^(?:www\.)?(?:[a-z0-9](?:[a-z0-9-]{0,62})\.)+[a-z]{2,63}(?::\d+)?(?:[/?#]|$)/i.test(clean)
    ? `https://${clean}`
    : '';
}

export function pdfDocumentBaseUrl(value) {
  try {
    const url = new URL(cleanLinkValue(value));
    if (!['http:', 'https:', 'ftp:'].includes(url.protocol)) return '';
    url.hash = '';
    return url.href;
  } catch {
    return '';
  }
}

export function pdfExternalLinkUrl(value, baseUrl = '') {
  const raw = cleanLinkValue(value);
  if (!raw) return '';
  const base = pdfDocumentBaseUrl(baseUrl);
  const canAssumeWebHost = !base || raw.startsWith('//') || /^www\./i.test(raw);
  const candidate = doiUrl(raw)
    || (canAssumeWebHost && !/^[a-z][a-z\d+.-]*:/i.test(raw) ? schemelessWebUrl(raw) : '')
    || raw;
  try {
    const url = base ? new URL(candidate, base) : new URL(candidate);
    return SAFE_PDF_LINK_PROTOCOLS.has(url.protocol) ? url.href : '';
  } catch {
    return '';
  }
}

export function recoverPdfAnnotationLinks(annotations, baseUrl = '') {
  if (!Array.isArray(annotations)) return [];
  return annotations.map((annotation) => {
    if (!annotation || typeof annotation !== 'object') return annotation;
    const url = pdfExternalLinkUrl(annotation.url || annotation.unsafeUrl, baseUrl);
    return url && url !== annotation.url ? { ...annotation, url } : annotation;
  });
}

export function samePdfDocumentUrl(left, right) {
  try {
    const leftUrl = new URL(left);
    const rightUrl = new URL(right);
    leftUrl.hash = '';
    rightUrl.hash = '';
    return leftUrl.href === rightUrl.href;
  } catch {
    return false;
  }
}

export function pdfSourceFragment(value) {
  try {
    return new URL(String(value || '')).hash.slice(1);
  } catch {
    return '';
  }
}
