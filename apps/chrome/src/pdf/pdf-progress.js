function finiteBytes(value) {
  const bytes = Number(value);
  return Number.isFinite(bytes) && bytes >= 0 ? bytes : 0;
}

export function nativePdfViewportProgress(value) {
  if (value === null || value === undefined || value === '') return null;
  const progress = Number(value);
  return Number.isFinite(progress) && progress >= 0 && progress <= 1
    ? progress
    : null;
}

export function nativePdfPageFromProgress(progress, pageCount) {
  const normalized = nativePdfViewportProgress(progress);
  const total = Math.max(0, Number.parseInt(pageCount, 10) || 0);
  if (normalized === null || !total) return 0;
  return Math.min(total, Math.floor(normalized * total) + 1);
}

export function nativePdfProgressFromScriptResults(results = []) {
  for (const entry of Array.isArray(results) ? results : []) {
    const result = entry?.result;
    if (!result?.nativePdfViewer) continue;
    const progress = nativePdfViewportProgress(result.progress);
    if (progress !== null) return progress;
  }
  return null;
}

/**
 * Returns the toolbar state for byte-level PDF work while the document is
 * opening. Once the first page is interactive, rendering and indexing own the
 * toolbar; lazy PDF.js range reads must not put a ready document back into a
 * loading state.
 */
export function pdfByteProgressView(progress = {}, { interactive = false } = {}) {
  if (interactive || (progress.phase !== 'download' && progress.phase !== 'load')) return null;
  const loadedBytes = finiteBytes(progress.loaded);
  const totalBytes = finiteBytes(progress.total);
  const loaded = `${(loadedBytes / 1024 / 1024).toFixed(1)} MB`;
  const total = totalBytes > 0 ? ` of ${(totalBytes / 1024 / 1024).toFixed(1)} MB` : '';
  return {
    detail: `${progress.phase === 'download' ? 'Downloading' : 'Reading'} ${loaded}${total} locally…`,
    current: loadedBytes,
    total: totalBytes
  };
}
