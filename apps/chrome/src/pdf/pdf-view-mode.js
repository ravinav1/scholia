export const PDF_PAGE_LAYOUTS = ['continuous', 'page', 'spread'];
export const PDF_ZOOM_MODES = ['auto', 'page', 'width'];

const PAGE_LAYOUT_LABELS = {
  continuous: 'Continuous',
  page: 'Single page',
  spread: 'Two-page spread'
};

const ZOOM_MODE_LABELS = {
  auto: 'Automatic',
  page: 'Fit page',
  width: 'Fit width'
};

export function normalizePdfPageLayout(value) {
  return PDF_PAGE_LAYOUTS.includes(value) ? value : 'continuous';
}

export function normalizePdfZoomMode(value, fallback = 'custom') {
  return PDF_ZOOM_MODES.includes(value) ? value : fallback;
}

export function pdfPageLayoutLabel(value) {
  return PAGE_LAYOUT_LABELS[normalizePdfPageLayout(value)];
}

export function pdfZoomModeLabel(value) {
  return ZOOM_MODE_LABELS[value] || '';
}

export function normalizePdfPageInput(value, pageCount, currentPage = 1) {
  const total = Math.max(0, Math.trunc(Number(pageCount) || 0));
  if (!total) return 0;
  const current = Math.min(total, Math.max(1, Math.trunc(Number(currentPage) || 1)));
  const source = String(value ?? '').trim();
  if (!source) return current;
  const requested = Number(source);
  if (!Number.isFinite(requested)) return current;
  return Math.min(total, Math.max(1, Math.trunc(requested)));
}

export function pdfSpreadIndex(pageNumber) {
  const page = Math.max(1, Math.trunc(Number(pageNumber) || 1));
  return Math.floor((page - 1) / 2);
}

export function pdfPageNavigationTarget(currentPage, pageCount, direction, layout = 'continuous') {
  const total = Math.max(0, Number.parseInt(pageCount, 10) || 0);
  if (!total) return 0;
  const current = Math.min(total, Math.max(1, Number.parseInt(currentPage, 10) || 1));
  const movement = Math.sign(Number(direction) || 0);
  if (!movement) return current;

  if (normalizePdfPageLayout(layout) === 'spread') {
    const spreadStart = pdfSpreadIndex(current) * 2 + 1;
    const lastSpreadStart = pdfSpreadIndex(total) * 2 + 1;
    const target = spreadStart + movement * 2;
    return target >= 1 && target <= lastSpreadStart ? target : current;
  }

  return Math.min(total, Math.max(1, current + movement));
}
