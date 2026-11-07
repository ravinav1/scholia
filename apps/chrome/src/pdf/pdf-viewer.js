import {
  assertPdfSize,
  fetchPdfDocument,
  formatPdfContext,
  MAX_EXTRACTED_CHARACTERS,
  MAX_EXTRACTED_PAGES,
  pdfInputOptions,
  readPdfBlobResponse,
  textContentToString
} from './pdf-context.js';
import {
  addPdfSemanticPage,
  createPdfSemanticIndex,
  finalizePdfSemanticIndex,
  findPdfMatchesAsync,
  findPdfSemanticMatches,
  pdfMatchItemSegments,
  pdfSearchTextContent
} from './pdf-search.js';
import {
  pdfIndexCacheKey,
  readPdfIndexCache,
  writePdfIndexCache
} from './pdf-index-cache.js';
import {
  activePdfOutlineEntry,
  pdfOutlineItemCount
} from './pdf-outline.js';
import { isPdfKeyboardControl, pdfKeyboardAction } from './pdf-keyboard.js';
import { mountPdfChat } from './pdf-chat.js';
import { readEntirePdf } from '../../../../packages/core/src/entire-pdf.js';
import { normalizedChatId } from '../chat/chat-page.js';
import {
  normalizePdfPageInput,
  normalizePdfPageLayout,
  normalizePdfZoomMode,
  pdfPageNavigationTarget,
  pdfPageLayoutLabel,
  pdfSpreadIndex,
  pdfZoomModeLabel
} from './pdf-view-mode.js';
import {
  pdfDocumentBaseUrl,
  pdfExternalLinkUrl,
  pdfSourceFragment,
  recoverPdfAnnotationLinks,
  samePdfDocumentUrl
} from './pdf-links.js';
import { nativePdfPageFromProgress, pdfByteProgressView } from './pdf-progress.js';
import { preparePdfPrint } from './pdf-print.js';
import {
  loadLocalPdfFileRecord,
  localPdfFileSource,
  storeLocalPdfFileHandle
} from './pdf-local-file-store.js';
import {
  activePdfMimeStreamInfo,
  pdfMimeHandlerEnabled,
  pdfMimeNavigationTarget,
  pdfMimeSource
} from './pdf-mime-handler.js';
import { sendRuntimeMessage as message } from '../runtime-message.js';
import { pdfSourceStorageKey, pdfViewerSourceId } from '../tab-context.js';
import { pdfSelectionMetadata, pdfSelectionPages } from './pdf-selection-context.js';
import { createPdfOcrReader, sparsePdfText } from './pdf-ocr.js';
import { PDFDetailRenderer, pdfCanvasScale } from '../pdf-render-quality.js';
import { readPdfPosition, writePdfPosition } from '../pdf-reading-position.js';
import { copyText } from '../clipboard.js';

const BASE_SCALE = 1.2;
const PDF_CSS_UNITS = 96 / 72;
const MIN_ZOOM = 0.5;
const MAX_ZOOM = 2.5;
const ZOOM_STEP = 0.15;
const MAX_CANVAS_PIXELS = 16_000_000;
const MAX_RENDERED_PAGES = 8;
const MAX_RETAINED_CANVAS_PIXELS = 32_000_000;
const PAGE_PLACEHOLDER_BATCH = 300;
const PAGE_INDEX_CONCURRENCY = 2;
const PAGE_RENDER_MARGIN = 800;
const PDF_THEME_KEY = 'scholia.pdf-theme.v1';
const PDF_PAGE_LAYOUT_KEY = 'scholia.pdf-page-layout.v1';
const PDF_ZOOM_MODE_KEY = 'scholia.pdf-zoom-mode.v1';
const PDF_SEARCH_MODE_KEY = 'scholia.pdf-search-mode.v1';
const PDF_LEARNING_MODE_KEY = 'scholia.pdf-learning-mode.v1';
const PDF_SPREAD_GAP = 8;

async function automaticPdfMimeHandlingEnabled() {
  return pdfMimeHandlerEnabled();
}
const PDF_ZOOM_PRESETS = [0.5, 0.75, 1, 1.25, 1.5, 2];
const elements = Object.fromEntries([
  'document-title', 'source-actions', 'source-url', 'copy-source-url', 'document-activity', 'document-status', 'document-progress', 'page-count', 'page-number', 'page-total',
  'zoom-out', 'zoom-label', 'zoom-custom',
  'zoom-in', 'theme-toggle', 'view-toggle', 'pdf-view-menu', 'pdf-view-control', 'outline-toggle', 'pdf-outline', 'outline-status', 'outline-close',
  'outline-tree', 'reader-layout', 'search-toggle', 'pdf-search', 'search-input', 'search-count',
  'search-mode', 'search-previous', 'search-next', 'search-close', 'choose-file', 'download-pdf', 'print-pdf', 'open-native', 'open-chat', 'learning-toggle', 'pdf-chat', 'pdf-chat-close',
  'send-entire-pdf',
  'pdf-chat-content', 'viewer', 'loading',
  'loading-detail', 'error', 'error-title', 'error-message', 'manual-pdf-form', 'pdf-address', 'open-address',
  'error-open-original', 'error-choose-file', 'pages', 'pdf-file', 'print-pages'
].map((id) => [id, document.getElementById(id)]));

let source = null;
let copySourceUrlTimer = null;
let pdfjs = null;
let pdf = null;
let pdfDownloadFilename = 'document.pdf';
let loadingTask = null;
let zoom = 1;
let pdfZoomMode = 'custom';
let pdfPageLayout = 'continuous';
let zoomBeforeSpread = null;
let spreadAutoZoom = null;
let pageStates = [];
let renderedPageStates = new Set();
let spreadRows = [];
let renderObserver = null;
let pageVisibilityObserver = null;
let visiblePageStates = new Set();
let pageStateByShell = new WeakMap();
let currentPageState = null;
let pdfNavigationSequence = 0;
let restoreReadingPosition = true;

function savedPdfPageNumber(documentProxy) {
  const saved = readPdfPosition({ mimeHandled: !!activeMimeStreamInfo });
  if (!documentProxy.fingerprints?.[0] || saved?.fingerprint !== documentProxy.fingerprints[0]) return 0;
  const page = saved.pageNumber;
  return Number.isInteger(page) && page >= 1 && page <= documentProxy.numPages ? page : 0;
}

function savePdfReadingPosition() {
  if (restoreReadingPosition || !currentPageState || !pdf?.fingerprints?.[0]) return;
  const position = { fingerprint: pdf.fingerprints[0], pageNumber: currentPageState.pageNumber };
  const saved = readPdfPosition({ mimeHandled: !!activeMimeStreamInfo });
  if (saved?.fingerprint === position.fingerprint && saved.pageNumber === position.pageNumber) return;
  writePdfPosition(position, { mimeHandled: !!activeMimeStreamInfo });
}
let scrollFrame = null;
let spreadResizeTimer = null;
let pdfViewAnchorFrame = null;
let pdfViewAnchorSequence = 0;
let pendingPdfViewAnchor = null;
let loadGeneration = 0;
let renderSequence = 0;
let indexingTask = null;
let documentInteractive = false;
let activePageRenders = 0;
let pdfLinkService = null;
let optionalContentConfigPromise = null;
let fieldObjectsPromise = Promise.resolve(null);
let pdfSearchReady = false;
let pdfBasicIndexReady = false;
let pdfComprehensiveIndexReady = false;
let pdfSemanticIndex = null;
let semanticIndexingTask = null;
let pdfReadyStatus = '';
let pdfBackgroundStatus = null;
let pdfSearchResults = [];
let pdfSearchTruncated = false;
let activePdfSearchIndex = -1;
let pdfSearchTimer = null;
let pdfSearchAction = 0;
let pdfSearchController = null;
let pdfSearchTask = null;
let activePdfSearchHighlights = [];
let pdfOutlineEntries = [];
let activePdfOutline = null;
let pdfOutlineTask = null;
let toolbarResizeObserver = null;
let toolbarResizeFrame = null;
let printController = null;
let activePrint = null;
let pendingLocalFileRecord = null;
let activeMimeStreamInfo = null;
let metadataPromise;
let resolveMetadata;
let readyMetadata = null;
let pdfOcrReader = null;
let pdfOcrController = null;
window.addEventListener('pagehide', () => pdfOcrController?.abort());

const detailRenderer = new PDFDetailRenderer({
  container: elements.viewer,
  getVisibleBounds: () => ({
    left: elements.viewer.getBoundingClientRect().left,
    right: elements.viewer.getBoundingClientRect().right,
    top: document.querySelector('.toolbar').getBoundingClientRect().bottom,
    bottom: innerHeight
  }),
  getPages: () => !documentInteractive ? [] : [...new Set([...visiblePageStates, currentPageState].filter(Boolean))]
    .filter((state) => state.renderedZoom === zoom)
    .map((state) => ({
      key: state.pageNumber, page: state.page, viewport: pageViewport(state),
      canvas: state.surface.querySelector('canvas:not(.pdf-detail-canvas)'), host: state.surface,
      renderOptions: { annotationMode: pdfjs.AnnotationMode.ENABLE_FORMS, optionalContentConfigPromise }
    }))
});
window.addEventListener('pagehide', () => detailRenderer.destroy(), { once: true });

function resetMetadata() {
  readyMetadata = null;
  metadataPromise = new Promise((resolve) => {
    resolveMetadata = (metadata) => { readyMetadata = metadata; resolve(metadata); };
  });
  metadataPromise.catch(() => {});
}

globalThis.__scholiaGetPageMetadata = async (options = {}) => {
  if (!options.forSelection || !pdf) return readyMetadata || metadataPromise;
  const documentProxy = pdf;
  const ocrReader = pdfOcrReader;
  const generation = loadGeneration;
  let fallbackPage = currentPageState?.pageNumber || 1;
  if (options.rect) {
    const y = (options.rect.top + options.rect.bottom) / 2;
    const x = (options.rect.left + options.rect.right) / 2;
    const state = pageStates.find(({ shell }) => {
      const bounds = shell.getBoundingClientRect();
      return x >= bounds.left && x <= bounds.right && y >= bounds.top && y <= bounds.bottom;
    });
    if (state) fallbackPage = state.pageNumber;
  }
  const result = await pdfSelectionMetadata({
    metadata: readyMetadata,
    pageCount: documentProxy.numPages,
    selectedPages: pdfSelectionPages(options.range, fallbackPage),
    selection: options.selection,
    fullContext: options.fullContext === true,
    pageTitle: document.title,
    url: source?.url || '',
    pageLanguage: readyMetadata?.pageLanguage || navigator.language,
    imageDataUrl: '',
    readPage: async (pageNumber) => {
      const state = pageStates[pageNumber - 1];
      const page = await documentProxy.getPage(pageNumber);
      const text = state?.contextText ?? textContentToString((state
        ? await pageTextContent(state, page) : await page.getTextContent()).items);
      // Explanations use the text available now; OCR continues independently.
      return text;
    }
  });
  if (generation !== loadGeneration) throw new Error('The PDF changed while preparing the explanation. Select the passage again.');
  return result === readyMetadata ? result : { ...result, ...ocrReader?.summary() };
};
resetMetadata();

function setStatus(value, { state = 'idle', current, total, owner = 'document' } = {}) {
  if (owner === 'background') pdfBackgroundStatus = { value, state, current, total };
  if (printController && owner !== 'print') return;
  elements['document-status'].textContent = value;
  elements['document-activity'].dataset.state = state;
  const progress = elements['document-progress'];
  progress.hidden = state !== 'working';
  if (progress.hidden) {
    progress.removeAttribute('value');
    progress.removeAttribute('aria-valuetext');
    return;
  }
  const determinate = Number.isFinite(current) && Number.isFinite(total) && total > 0;
  if (!determinate) {
    progress.removeAttribute('value');
    progress.setAttribute('aria-valuetext', value);
    return;
  }
  progress.max = total;
  progress.value = Math.max(0, Math.min(total, current));
  progress.setAttribute('aria-valuetext', `${Math.round(progress.value)} of ${Math.round(total)}`);
}

function updatePageCounter(pageNumber, pageCount = pdf?.numPages || pageStates.length, { force = false } = {}) {
  const total = Math.max(0, Number.parseInt(pageCount, 10) || 0);
  const current = normalizePdfPageInput(pageNumber, total, currentPageState?.pageNumber || 1);
  const input = elements['page-number'];
  const totalLabel = elements['page-total'];
  totalLabel.textContent = total ? String(total) : '–';
  input.disabled = !total;
  input.max = String(Math.max(1, total));
  input.style.setProperty('--page-number-digits', String(Math.max(1, String(total || 1).length)));
  input.setAttribute('aria-label', total
    ? `Page number. Enter a number from 1 to ${total}.`
    : 'Page number');
  elements['page-count'].title = total ? `Page ${current} of ${total} · enter a page number to jump` : '';
  if (force || document.activeElement !== input) input.value = current ? String(current) : '';
}

function commitPageNumber() {
  const total = pdf?.numPages || pageStates.length;
  if (!total) return;
  const current = currentPageState?.pageNumber || 1;
  const target = normalizePdfPageInput(elements['page-number'].value, total, current);
  updatePageCounter(target, total, { force: true });
  navigateToPdfDestination(target).catch((error) => {
    updatePageCounter(current, total, { force: true });
    setStatus(error?.message || String(error), { state: 'warning' });
  });
}

let pdfChatController = null;

async function setPdfChatOpen(open, { restoreFocus = false, chatId = '' } = {}) {
  const shouldOpen = Boolean(open);
  const chat = elements['pdf-chat'];
  const savedChatId = normalizedChatId(chatId);
  chat.hidden = !shouldOpen;
  if (!shouldOpen) pdfChatController?.then((controller) => controller.stop?.()).catch(() => {});
  document.body.classList.toggle('is-pdf-chat-open', shouldOpen);
  elements['open-chat'].setAttribute('aria-expanded', String(shouldOpen));
  elements['open-chat'].textContent = shouldOpen ? 'Hide PDF chat' : 'Chat with PDF';
  requestAnimationFrame(() => {
    if (pdfZoomMode !== 'custom') applyPdfZoomMode();
    else if (pdfPageLayout === 'spread') fitPdfSpread();
    scheduleCurrentPage();
  });
  if (shouldOpen) elements['pdf-chat-close'].focus();
  else if (restoreFocus) elements['open-chat'].focus();
  if (shouldOpen) {
    try {
      pdfChatController ||= mountPdfChat(elements['pdf-chat-content'], {
        close: () => setPdfChatOpen(false, { restoreFocus: true })
      }).catch((error) => { pdfChatController = null; throw error; });
      const controller = await pdfChatController;
      if (savedChatId) await controller.openChat(savedChatId);
      else await controller.ready;
    } catch (error) {
      setStatus(error.message, { state: 'warning' });
    }
  }
}

function openPdfChat() {
  setPdfChatOpen(elements['pdf-chat'].hidden);
}

async function sendEntirePDF() {
  if (!pdf || elements['send-entire-pdf'].disabled) return;
  const documentProxy = pdf, generation = loadGeneration, ocr = pdfOcrReader;
  const sourceSnapshot = { ...source };
  elements['send-entire-pdf'].disabled = true;
  try {
    const full = await readEntirePdf({
      title: document.title, pageCount: documentProxy.numPages, signal: pdfOcrController?.signal,
      readPage: async (number) => {
        if (generation !== loadGeneration) throw new Error('The PDF changed. Send the current PDF again.');
        const page = await documentProxy.getPage(number);
        const text = textContentToString((await page.getTextContent()).items);
        return ocr ? ocr.readPage(page, text, number) : text;
      },
      onProgress: (page, total) => setStatus(`Reading entire PDF · ${page} of ${total} pages…`)
    });
    if (generation !== loadGeneration) return;
    await setPdfChatOpen(true);
    const controller = await pdfChatController;
    await controller.sendEntirePDF({ ...sourceSnapshot, ...full,
      viewerSourceId: sourceSnapshot.id || sourceSnapshot.viewerSourceId,
      pageTitle: document.title, pageLanguage: readyMetadata?.pageLanguage, sourceKind: 'pdf' });
    setStatus(full.summary);
  } catch (error) {
    if (generation === loadGeneration) setStatus(error.message, { state: 'warning' });
  } finally {
    if (generation === loadGeneration) elements['send-entire-pdf'].disabled = !documentInteractive;
  }
}

function applyTheme(theme) {
  const dark = theme === 'dark';
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  elements['theme-toggle'].setAttribute('aria-pressed', String(dark));
  elements['theme-toggle'].title = dark ? 'Use light reader interface' : 'Use dark reader interface';
  elements['theme-toggle'].setAttribute('aria-label', elements['theme-toggle'].title);
}

async function restoreTheme() {
  const stored = await chrome.storage.local.get(PDF_THEME_KEY).catch(() => ({}));
  const preferred = stored[PDF_THEME_KEY];
  applyTheme(preferred === 'dark' || preferred === 'light'
    ? preferred
    : matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light');
}

function semanticPdfSearchActive() {
  return elements['search-mode'].value === 'semantic';
}

function updatePdfSearchModeUi() {
  const semantic = semanticPdfSearchActive();
  elements['search-input'].placeholder = semantic
    ? 'Find a concept or ask a question…'
    : 'Find exact words or phrases…';
  elements['search-input'].setAttribute('aria-label', semantic
    ? 'Semantically search this PDF'
    : 'Search this PDF for exact words or phrases');
  updatePdfSearchControls();
}

async function restorePdfSearchMode() {
  const stored = await chrome.storage.local.get(PDF_SEARCH_MODE_KEY).catch(() => ({}));
  elements['search-mode'].value = stored[PDF_SEARCH_MODE_KEY] === 'semantic' ? 'semantic' : 'exact';
  updatePdfSearchModeUi();
}

function renderPdfLearningMode(enabled) {
  const active = enabled === true;
  elements['learning-toggle'].setAttribute('aria-pressed', String(active));
  elements['learning-toggle'].textContent = active ? '◇ Guided learning on' : '◇ Guided learning';
  elements['learning-toggle'].title = active
    ? 'Guided learning is on: graduated hints; request a worked solution at any time'
    : 'Guide with graduated hints, or request a worked solution';
}

async function restorePdfLearningMode() {
  const stored = await chrome.storage.local.get(PDF_LEARNING_MODE_KEY);
  renderPdfLearningMode(stored[PDF_LEARNING_MODE_KEY]);
}

async function togglePdfLearningMode() {
  const enabled = elements['learning-toggle'].getAttribute('aria-pressed') !== 'true';
  renderPdfLearningMode(enabled);
  await chrome.storage.local.set({ [PDF_LEARNING_MODE_KEY]: enabled });
  setStatus(enabled
    ? 'Guided learning on · Scholia will ask questions and offer small hints'
    : 'Guided learning off', { state: 'ready' });
}

function toggleTheme() {
  const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  applyTheme(next);
  chrome.storage.local.set({ [PDF_THEME_KEY]: next }).catch(() => {});
}

function updatePdfViewMenuControl() {
  for (const option of elements['pdf-view-menu'].querySelectorAll('[data-pdf-layout]')) {
    option.setAttribute('aria-checked', String(option.dataset.pdfLayout === pdfPageLayout));
  }
  for (const option of elements['pdf-view-menu'].querySelectorAll('[data-pdf-zoom]')) {
    option.setAttribute('aria-checked', String(option.dataset.pdfZoom === pdfZoomMode));
  }
  const layoutLabel = pdfPageLayoutLabel(pdfPageLayout);
  const zoomLabel = pdfZoomModeLabel(pdfZoomMode);
  const label = `PDF view: ${layoutLabel}${zoomLabel ? `, ${zoomLabel}` : ''}`;
  elements['view-toggle'].title = label;
  elements['view-toggle'].setAttribute('aria-label', label);
}

function setPdfViewMenuOpen(open, { restoreFocus = false } = {}) {
  const shouldOpen = Boolean(open);
  elements['pdf-view-menu'].hidden = !shouldOpen;
  elements['view-toggle'].setAttribute('aria-expanded', String(shouldOpen));
  if (shouldOpen) {
    elements['pdf-view-menu'].querySelector('[aria-checked="true"]')?.focus();
  } else if (restoreFocus) {
    elements['view-toggle'].focus();
  }
}

function updatePdfPageLayoutControl() {
  elements.pages.classList.toggle('is-spread-view', pdfPageLayout === 'spread');
  elements.pages.classList.toggle('is-single-page', pdfPageLayout === 'page');
  setCurrentPdfPageState(currentPageState || pageStates[0]);
  updatePdfViewMenuControl();
}

function pdfReadingLine() {
  const toolbarBottom = document.querySelector('.toolbar')?.getBoundingClientRect().bottom || 0;
  return Math.min(Math.max(toolbarBottom + 18, 0), Math.max(0, innerHeight - 18));
}

function capturePdfViewAnchor(state = currentPageState) {
  if (!state?.surface?.isConnected) return null;
  const rect = state.surface.getBoundingClientRect();
  if (!rect.height) return null;
  const readingLine = pdfReadingLine();
  const viewportY = Math.max(rect.top, Math.min(rect.bottom, readingLine));
  return {
    pageNumber: state.pageNumber,
    ratio: Math.max(0, Math.min(1, (viewportY - rect.top) / rect.height)),
    viewportY
  };
}

function cancelPdfViewAnchorRestore() {
  pdfViewAnchorSequence += 1;
  pendingPdfViewAnchor = null;
  if (pdfViewAnchorFrame) cancelAnimationFrame(pdfViewAnchorFrame);
  pdfViewAnchorFrame = null;
}

function restorePdfViewAnchor(anchor) {
  if (!anchor) {
    updateCurrentPage();
    return;
  }
  const sequence = ++pdfViewAnchorSequence;
  pendingPdfViewAnchor = anchor;
  if (pdfViewAnchorFrame) cancelAnimationFrame(pdfViewAnchorFrame);
  pdfViewAnchorFrame = requestAnimationFrame(() => {
    pdfViewAnchorFrame = requestAnimationFrame(() => {
      pdfViewAnchorFrame = null;
      if (sequence !== pdfViewAnchorSequence) return;
      const state = pageStates[anchor.pageNumber - 1];
      if (!state?.surface?.isConnected) {
        pendingPdfViewAnchor = null;
        updateCurrentPage();
        return;
      }
      setCurrentPdfPageState(state);
      const rect = state.surface.getBoundingClientRect();
      const anchoredY = rect.top + rect.height * anchor.ratio;
      const nextTop = Math.max(0, window.scrollY + anchoredY - anchor.viewportY);
      window.scrollTo({ top: nextTop, left: window.scrollX, behavior: 'auto' });
      setCurrentPdfPageState(state);
      updatePageCounter(state.pageNumber);
      updateActivePdfOutline(state.pageNumber);
      pendingPdfViewAnchor = null;
    });
  });
}

function setPdfPageLayout(layout, { fit = false, persist = false } = {}) {
  const viewAnchor = capturePdfViewAnchor();
  const viewAnchorRequest = pdfViewAnchorSequence;
  const nextLayout = normalizePdfPageLayout(layout);
  const leavingSpread = pdfPageLayout === 'spread' && nextLayout !== 'spread';
  const restoreZoom = leavingSpread
    && spreadAutoZoom !== null
    && Math.abs(zoom - spreadAutoZoom) < 0.001
    ? zoomBeforeSpread
    : null;

  if (pdfPageLayout !== 'spread' && nextLayout === 'spread') zoomBeforeSpread = zoom;
  pdfPageLayout = nextLayout;
  updatePdfPageLayoutControl();
  if (persist) {
    chrome.storage.local.set({ [PDF_PAGE_LAYOUT_KEY]: nextLayout }).catch(() => {});
  }

  requestAnimationFrame(() => {
    if (viewAnchorRequest !== pdfViewAnchorSequence) return;
    if (pdfPageLayout === 'page') setCurrentPdfPageState(currentPageState || pageStates[0]);
    if (pdfZoomMode !== 'custom') applyPdfZoomMode(undefined, { anchor: viewAnchor });
    else if (pdfPageLayout === 'spread' && fit) fitPdfSpread({ anchor: viewAnchor });
    else if (Number.isFinite(restoreZoom)) updateZoom(restoreZoom, { anchor: viewAnchor });
    else restorePdfViewAnchor(viewAnchor);
  });
  if (leavingSpread) {
    zoomBeforeSpread = null;
    spreadAutoZoom = null;
  }
}

async function restorePdfPageLayout() {
  const stored = await chrome.storage.local.get(PDF_PAGE_LAYOUT_KEY).catch(() => ({}));
  setPdfPageLayout(normalizePdfPageLayout(stored[PDF_PAGE_LAYOUT_KEY]));
}

async function restorePdfZoomMode() {
  const stored = await chrome.storage.local.get(PDF_ZOOM_MODE_KEY).catch(() => ({}));
  pdfZoomMode = normalizePdfZoomMode(stored[PDF_ZOOM_MODE_KEY]);
  updatePdfZoomControl();
}

function observeToolbarHeight() {
  const toolbar = document.querySelector('.toolbar');
  const update = () => {
    toolbarResizeFrame = null;
    const height = `${Math.ceil(toolbar.getBoundingClientRect().height)}px`;
    const style = document.documentElement.style;
    if (style.getPropertyValue('--toolbar-height') !== height) {
      style.setProperty('--toolbar-height', height);
    }
  };
  toolbarResizeObserver?.disconnect();
  if (toolbarResizeFrame !== null) cancelAnimationFrame(toolbarResizeFrame);
  update();
  toolbarResizeObserver = new ResizeObserver(() => {
    // This property changes the reader layout and can resize the toolbar again.
    // Write in the next frame, outside ResizeObserver's layout-delivery loop.
    if (toolbarResizeFrame === null) toolbarResizeFrame = requestAnimationFrame(update);
  });
  toolbarResizeObserver.observe(toolbar, { box: 'border-box' });
}

function setPdfOutlineOpen(open, { restoreFocus = false } = {}) {
  const viewAnchor = capturePdfViewAnchor();
  const viewAnchorRequest = pdfViewAnchorSequence;
  const shouldOpen = Boolean(open && !elements['outline-toggle'].disabled);
  elements['pdf-outline'].hidden = !shouldOpen;
  elements['reader-layout'].classList.toggle('is-outline-open', shouldOpen);
  elements['outline-toggle'].setAttribute('aria-expanded', String(shouldOpen));
  elements['outline-toggle'].setAttribute('aria-label', shouldOpen
    ? 'Hide table of contents'
    : 'Show table of contents');
  if (restoreFocus) elements['outline-toggle'].focus();
  requestAnimationFrame(() => {
    if (viewAnchorRequest !== pdfViewAnchorSequence) return;
    if (pdfZoomMode !== 'custom') applyPdfZoomMode(undefined, { anchor: viewAnchor });
    else if (pdfPageLayout === 'spread') fitPdfSpread({ anchor: viewAnchor });
    else restorePdfViewAnchor(viewAnchor);
    if (shouldOpen) revealActivePdfOutlineEntry();
  });
}

function resetPdfOutlineForDocument() {
  pdfOutlineTask = null;
  pdfOutlineEntries = [];
  activePdfOutline = null;
  elements['outline-tree'].replaceChildren();
  elements['outline-status'].textContent = 'Loading document outline…';
  elements['outline-toggle'].disabled = true;
  elements['outline-toggle'].title = 'Loading table of contents';
  setPdfOutlineOpen(false);
}

function setCurrentPdfPageState(state) {
  if (!state) return;
  if (currentPageState !== state) currentPageState?.shell.classList.remove('is-current-page');
  currentPageState = state;
  state.shell.classList.add('is-current-page');
  savePdfReadingPosition();
}

function handleReaderKeyboard(event) {
  const action = pdfKeyboardAction(event, {
    viewportHeight: window.innerHeight,
    toolbarHeight: document.querySelector('.toolbar')?.getBoundingClientRect().height || 0
  });
  if (!action || (action.type !== 'zoom' && isPdfKeyboardControl(event.target, event.key))) return false;

  event.preventDefault();
  if (action.type === 'zoom') {
    updateZoom(action.direction === 0 ? 1 : zoom + action.direction * ZOOM_STEP, { persist: true });
  } else if (action.type === 'page') {
    const pageCount = pdf?.numPages || pageStates.length;
    if (!pageCount) return true;
    const currentPage = currentPageState?.pageNumber || 1;
    const pageNumber = pdfPageNavigationTarget(
      currentPage,
      pageCount,
      action.direction,
      pdfPageLayout
    );
    if (pageNumber !== currentPage) {
      const state = pageStates[pageNumber - 1];
      if (state) setCurrentPdfPageState(state);
      updatePageCounter(pageNumber, pageCount);
      navigateToPdfDestination(pageNumber).catch(() => {});
    }
  } else if (action.type === 'edge') {
    if (pdfPageLayout === 'page' || pdfPageLayout === 'spread') {
      const pageCount = pdf?.numPages || pageStates.length;
      const pageNumber = action.edge === 'start'
        ? 1
        : pdfPageLayout === 'spread'
          ? Math.floor((pageCount - 1) / 2) * 2 + 1
          : pageCount;
      const state = pageStates[pageNumber - 1];
      if (state) setCurrentPdfPageState(state);
      navigateToPdfDestination(pageNumber).catch(() => {});
      return true;
    }
    window.scrollTo({
      top: action.edge === 'start' ? 0 : document.documentElement.scrollHeight,
      left: window.scrollX,
      behavior: 'auto'
    });
  } else {
    window.scrollBy({ top: action.top, left: action.left, behavior: 'auto' });
  }
  scheduleCurrentPage();
  return true;
}

function showSourceUrl(value) {
  const url = String(value || '').trim();
  const copyUrl = pdfMimeNavigationTarget(source?.pdfUrl);
  clearTimeout(copySourceUrlTimer);
  resetCopySourceUrl();
  elements['source-actions'].hidden = !url && !copyUrl;
  elements['copy-source-url'].hidden = !copyUrl;
  elements['source-url'].hidden = !url;
  elements['error-open-original'].hidden = !url;
  elements['source-url'].textContent = url;
  elements['source-url'].title = url ? `Open original address: ${url}` : '';
  elements['source-url'].setAttribute('aria-label', url ? `Open original address at ${url}` : 'Open original address');
}

function resetCopySourceUrl() {
  const button = elements['copy-source-url'];
  button.disabled = false;
  button.textContent = 'Copy URL';
  button.title = 'Copy original PDF URL';
  button.setAttribute('aria-label', button.title);
}

async function copySourceUrl() {
  const currentSource = source;
  const url = pdfMimeNavigationTarget(currentSource?.pdfUrl);
  const button = elements['copy-source-url'];
  if (!url || button.disabled) return;
  clearTimeout(copySourceUrlTimer);
  button.disabled = true;
  let copied = false;
  try {
    // Copy the original address, including signed query parameters and fragments.
    // The visible source label is intentionally sanitized for display/context.
    await copyText(url);
    copied = true;
  } catch {}
  if (source !== currentSource) return;
  button.disabled = false;
  button.textContent = copied ? 'Copied!' : 'Copy failed';
  button.title = copied ? 'Original PDF URL copied' : 'Could not copy the PDF URL. Try again.';
  button.setAttribute('aria-label', button.title);
  copySourceUrlTimer = setTimeout(resetCopySourceUrl, 2000);
}

function showLoading(value, statusOptions = { state: 'working' }) {
  elements['loading-detail'].textContent = value;
  elements.loading.hidden = false;
  elements.error.hidden = true;
  elements['open-chat'].disabled = true;
  elements['send-entire-pdf'].disabled = true;
  setStatus(value, statusOptions);
}

function resetLocalFileRestoreAction() {
  pendingLocalFileRecord = null;
  elements['error-choose-file'].textContent = 'Choose a PDF file';
}

function showError(error) {
  resetLocalFileRestoreAction();
  documentInteractive = false;
  pdfSearchReady = false;
  clearPdfSearchResults();
  resetPdfOutlineForDocument();
  elements['download-pdf'].disabled = true;
  elements['print-pdf'].disabled = true;
  elements.loading.hidden = true;
  elements.error.hidden = false;
  elements['error-title'].textContent = 'Scholia could not open this PDF address';
  elements['error-message'].textContent = error?.message || String(error);
  elements['open-native'].hidden = !source?.pdfUrl;
  elements['open-chat'].disabled = true;
  elements['send-entire-pdf'].disabled = true;
  setStatus('Paste the PDF address again or choose the file', { state: 'error' });
}

function showLocalFilePermission(record) {
  pendingLocalFileRecord = record;
  documentInteractive = false;
  pdfSearchReady = false;
  clearPdfSearchResults();
  resetPdfOutlineForDocument();
  elements['download-pdf'].disabled = true;
  elements['print-pdf'].disabled = true;
  elements.loading.hidden = true;
  elements.error.hidden = false;
  elements['error-title'].textContent = `Reopen ${record.name}`;
  elements['error-message'].textContent = 'Chromium needs permission to read this file from its current location again.';
  elements['error-choose-file'].textContent = 'Reopen file';
  elements['open-native'].hidden = true;
  elements['open-chat'].disabled = true;
  elements['send-entire-pdf'].disabled = true;
  setStatus('Allow access to reopen the PDF from this computer', { state: 'warning' });
}

function showManualOpen() {
  resetLocalFileRestoreAction();
  source = null;
  document.documentElement.dataset.scholiaSourceUrl = '';
  documentInteractive = false;
  elements.loading.hidden = true;
  elements.error.hidden = false;
  elements['error-title'].textContent = 'Open a PDF in Scholia';
  elements['error-message'].textContent = 'Paste a PDF address below or choose a file from this device.';
  elements['open-native'].hidden = true;
  elements['open-chat'].disabled = true;
  elements['send-entire-pdf'].disabled = true;
  elements['document-title'].textContent = 'Open a PDF';
  showSourceUrl('');
  setStatus('Ready for a PDF address or file', { state: 'idle' });
  requestAnimationFrame(() => elements['pdf-address'].focus());
}

function cancelPdfPrint() {
  printController?.abort();
  printController = null;
  activePrint?.destroy();
  activePrint = null;
  document.body.removeAttribute('data-pdf-printing');
}

async function printPdf() {
  if (!pdf || elements['print-pdf'].disabled) return;
  cancelPdfPrint();
  const generation = loadGeneration;
  const documentProxy = pdf;
  const controller = printController = new AbortController();
  elements['print-pdf'].disabled = true;
  elements['print-pdf'].setAttribute('aria-busy', 'true');
  let printFailed = false;
  try {
    const prepared = await preparePdfPrint({
      pdfDocument: documentProxy,
      pdfjs,
      printContainer: elements['print-pages'],
      signal: controller.signal,
      onProgress(current, total) {
        setStatus(`Preparing page ${Math.min(current + 1, total)} of ${total} for print…`, {
          state: 'working', current, total, owner: 'print'
        });
      }
    });
    if (generation !== loadGeneration || documentProxy !== pdf) {
      prepared.destroy();
      throw new DOMException('PDF changed.', 'AbortError');
    }
    activePrint = prepared;
    setStatus('Opening Chrome print preview…', {
      state: 'working', current: documentProxy.numPages, total: documentProxy.numPages, owner: 'print'
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    window.print();
    await new Promise((resolve) => setTimeout(resolve, 20));
  } catch (error) {
    if (generation === loadGeneration && !controller.signal.aborted && error?.name !== 'AbortError') {
      printFailed = true;
      setStatus(`Could not print this PDF: ${error?.message || error}`, { state: 'warning', owner: 'print' });
    }
  } finally {
    const stillCurrent = generation === loadGeneration && documentProxy === pdf;
    if (printController === controller) cancelPdfPrint();
    if (stillCurrent) {
      elements['print-pdf'].removeAttribute('aria-busy');
      elements['print-pdf'].disabled = false;
    }
    if (stillCurrent && !printFailed) {
      if (pdfBackgroundStatus) setStatus(pdfBackgroundStatus.value, pdfBackgroundStatus);
      else setStatus(pdfReadyStatus || `${documentProxy.numPages} page${documentProxy.numPages === 1 ? '' : 's'} · ready`, { state: 'ready' });
    }
  }
}

function updateDownloadProgress(progress) {
  const view = pdfByteProgressView(progress, { interactive: documentInteractive });
  if (!view) return;
  showLoading(view.detail, {
    state: 'working',
    current: view.current,
    total: view.total
  });
}

function sourceId() {
  const nativeId = pdfViewerSourceId(location.href);
  if (nativeId) return nativeId;
  try {
    const current = new URL(location.href);
    const ownedViewer = new URL(chrome.runtime.getURL('pdf-viewer.html'));
    const candidate = String(current.searchParams.get('source') || '');
    return current.origin === ownedViewer.origin
      && current.pathname === ownedViewer.pathname
      && pdfSourceStorageKey(candidate)
      ? candidate
      : '';
  } catch {
    return '';
  }
}

function installScholia() {
  return new Promise((resolve, reject) => {
    if (document.getElementById('scholia-extension-root')) { resolve(); return; }
    const script = document.createElement('script');
    script.src = chrome.runtime.getURL('content.js');
    script.onload = resolve;
    script.onerror = () => reject(new Error('Scholia selection controls could not be loaded.'));
    document.head.append(script);
  });
}

async function loadPdfJs() {
  if (pdfjs) return pdfjs;
  pdfjs = await import(chrome.runtime.getURL('vendor/pdfjs/pdf.min.mjs'));
  pdfjs.GlobalWorkerOptions.workerSrc = chrome.runtime.getURL('vendor/pdfjs/pdf.worker.min.mjs');
  return pdfjs;
}

function pdfOptions(inputOptions, documentUrl = '') {
  const assetRoot = chrome.runtime.getURL('vendor/pdfjs/');
  return {
    ...inputOptions,
    docBaseUrl: pdfDocumentBaseUrl(documentUrl) || undefined,
    cMapUrl: `${assetRoot}cmaps/`,
    cMapPacked: true,
    standardFontDataUrl: `${assetRoot}standard_fonts/`,
    enableXfa: true,
    isEvalSupported: false,
    stopAtErrors: false,
    useSystemFonts: true
  };
}

function downloadPdfAttachment(data, filename, contentType = 'application/octet-stream') {
  const blobUrl = URL.createObjectURL(new Blob([data], { type: contentType }));
  const link = document.createElement('a');
  link.href = blobUrl;
  link.download = String(filename || 'attachment').replace(/[\\/:*?"<>|]+/g, '-');
  link.rel = 'noopener';
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(blobUrl), 60_000);
}

async function downloadPdf() {
  if (!pdf || elements['download-pdf'].disabled) return;
  const documentProxy = pdf;
  const generation = loadGeneration;
  const filename = pdfDownloadFilename;
  const button = elements['download-pdf'];
  button.disabled = true;
  button.setAttribute('aria-busy', 'true');
  try {
    const data = await documentProxy.getData();
    if (generation !== loadGeneration || documentProxy !== pdf || !documentInteractive) return;
    downloadPdfAttachment(data, filename, 'application/pdf');
    setStatus('PDF download started', { state: 'ready' });
  } catch (error) {
    if (generation === loadGeneration && documentProxy === pdf) {
      setStatus(`Could not download this PDF: ${error?.message || error}`, { state: 'warning' });
    }
  } finally {
    if (generation === loadGeneration && documentProxy === pdf) {
      button.removeAttribute('aria-busy');
      button.disabled = !documentInteractive;
    }
  }
}

const pdfDownloadManager = {
  downloadData(data, filename, contentType) {
    downloadPdfAttachment(data, filename, contentType);
  },

  openOrDownloadData(data, filename) {
    downloadPdfAttachment(data, filename, /\.pdf$/i.test(filename) ? 'application/pdf' : undefined);
    return false;
  },

  download(data, url, filename) {
    if (data) {
      downloadPdfAttachment(data, filename, 'application/pdf');
      return;
    }
    const safeUrl = pdfExternalLinkUrl(url);
    if (!safeUrl) return;
    const link = document.createElement('a');
    link.href = safeUrl;
    link.download = String(filename || 'document.pdf');
    link.rel = 'noopener noreferrer';
    link.click();
  }
};

async function resolvePdfDestination(documentProxy, destination) {
  if (!documentProxy) return null;
  const explicitDestination = typeof destination === 'string'
    ? await documentProxy.getDestination(destination)
    : await destination;
  if (!Array.isArray(explicitDestination)) return null;

  const [pageReference] = explicitDestination;
  let pageNumber = 0;
  if (Number.isInteger(pageReference)) {
    pageNumber = pageReference + 1;
  } else if (pageReference && typeof pageReference === 'object') {
    pageNumber = documentProxy.cachedPageNumber?.(pageReference) || 0;
    if (!pageNumber) {
      try { pageNumber = (await documentProxy.getPageIndex(pageReference)) + 1; } catch {}
    }
  }
  return pageNumber >= 1 && pageNumber <= documentProxy.numPages
    ? { explicitDestination, pageNumber }
    : null;
}

class ScholiaPdfLinkService {
  constructor(documentProxy, documentUrl = '') {
    this.pdfDocument = documentProxy;
    this.baseUrl = pdfDocumentBaseUrl(documentUrl);
    this.externalLinkEnabled = true;
    this.eventBus = { dispatch() {} };
  }

  get pagesCount() {
    return this.pdfDocument?.numPages || 0;
  }

  get page() {
    return currentPageState?.pageNumber || 1;
  }

  set page(value) {
    this.goToPage(value);
  }

  get rotation() {
    return 0;
  }

  set rotation(_value) {}

  get isInPresentationMode() {
    return false;
  }

  addLinkAttributes(link, rawUrl) {
    const url = this.externalLinkEnabled ? pdfExternalLinkUrl(rawUrl, this.baseUrl) : '';
    if (!url) {
      link.href = '';
      link.title = rawUrl ? `Blocked unsafe PDF link: ${rawUrl}` : 'Unavailable PDF link';
      link.onclick = () => false;
      return;
    }

    const parsed = new URL(url);
    if (parsed.hash && this.baseUrl && samePdfDocumentUrl(url, this.baseUrl)) {
      link.href = this.getAnchorUrl(parsed.hash);
      link.title = url;
      link.onclick = () => {
        this.setHash(parsed.hash.slice(1));
        return false;
      };
      return;
    }

    link.href = link.title = url;
    link.target = '_blank';
    link.rel = 'noopener noreferrer';
    link.referrerPolicy = 'no-referrer';
  }

  async goToDestination(destination) {
    const resolved = await resolvePdfDestination(this.pdfDocument, destination);
    if (resolved) await navigateToPdfDestination(resolved.pageNumber, resolved.explicitDestination);
  }

  goToPage(value) {
    const pageNumber = Number.parseInt(value, 10);
    if (pageNumber >= 1 && pageNumber <= this.pagesCount) {
      navigateToPdfDestination(pageNumber).catch(() => {});
    }
  }

  getDestinationHash(destination) {
    try {
      const key = typeof destination === 'string' ? 'nameddest' : 'dest';
      const value = typeof destination === 'string' ? destination : JSON.stringify(destination);
      return this.getAnchorUrl(`#${key}=${encodeURIComponent(value)}`);
    } catch {
      return this.getAnchorUrl('');
    }
  }

  getAnchorUrl(anchor) {
    return `${location.href.split('#', 1)[0]}${anchor || ''}`;
  }

  async setHash(hash) {
    const rawHash = String(hash || '').replace(/^#/, '');
    if (!rawHash) return;
    if (!rawHash.includes('=')) {
      let destination = rawHash;
      try { destination = decodeURIComponent(rawHash); } catch {}
      await this.goToDestination(destination);
      return;
    }

    const parameters = new URLSearchParams(rawHash);
    if (parameters.has('dest')) {
      try { await this.goToDestination(JSON.parse(parameters.get('dest'))); } catch {}
      return;
    }
    if (parameters.has('nameddest')) {
      await this.goToDestination(parameters.get('nameddest'));
      return;
    }

    const pageNumber = Number.parseInt(parameters.get('page'), 10);
    const zoomValue = Number.parseFloat(String(parameters.get('zoom') || '').split(',', 1)[0]);
    if (Number.isFinite(zoomValue) && zoomValue > 0) {
      updateZoom((zoomValue / 100) * PDF_CSS_UNITS / BASE_SCALE);
    }
    if (pageNumber >= 1 && pageNumber <= this.pagesCount) {
      await navigateToPdfDestination(pageNumber);
    }
    if (parameters.has('search')) {
      elements['search-input'].value = parameters.get('search').replaceAll('"', '');
      openPdfSearch();
      runPdfSearch({ resetActive: true, reveal: true });
    }
  }

  executeNamedAction(action) {
    if (action === 'NextPage') this.goToPage(Math.min(this.pagesCount, this.page + 1));
    else if (action === 'PrevPage') this.goToPage(Math.max(1, this.page - 1));
    else if (action === 'FirstPage') this.goToPage(1);
    else if (action === 'LastPage') this.goToPage(this.pagesCount);
    else if (action === 'GoBack') history.back();
    else if (action === 'GoForward') history.forward();
  }

  async executeSetOCGState(action) {
    const configuration = await optionalContentConfigPromise;
    if (!configuration || !pdf) return;
    configuration.setOCGState(action);
    optionalContentConfigPromise = Promise.resolve(configuration);
    resetRenderedPages();
  }
}

function pdfOutlineTitle(item, order) {
  return String(item?.title || '')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 1_000) || `Untitled section ${order + 1}`;
}

function setPdfOutlineBranchExpanded(disclosure, list, expanded) {
  disclosure.setAttribute('aria-expanded', String(expanded));
  disclosure.setAttribute('aria-label', `${expanded ? 'Collapse' : 'Expand'} ${disclosure.dataset.title}`);
  list.hidden = !expanded;
}

function pdfOutlineControl(item, title, children, order) {
  const hasDestination = item.dest !== null && item.dest !== undefined;
  const rawUrl = String(item.url || item.unsafeUrl || '');
  const safeUrl = pdfExternalLinkUrl(rawUrl, pdfLinkService?.baseUrl);
  let control;

  if (hasDestination) {
    control = document.createElement('button');
    control.type = 'button';
  } else if (safeUrl) {
    control = document.createElement('a');
    pdfLinkService?.addLinkAttributes(control, rawUrl);
  } else if (children.length) {
    control = document.createElement('button');
    control.type = 'button';
  } else {
    control = document.createElement('span');
  }

  control.className = control instanceof HTMLSpanElement ? 'pdf-outline-label' : 'pdf-outline-link';
  if (item.bold) control.classList.add('is-bold');
  if (item.italic) control.classList.add('is-italic');
  const titleElement = document.createElement('span');
  titleElement.className = 'pdf-outline-title';
  titleElement.textContent = title;
  const pageLabel = document.createElement('span');
  pageLabel.className = safeUrl && !hasDestination ? 'pdf-outline-external' : 'pdf-outline-page';
  pageLabel.textContent = safeUrl && !hasDestination ? '↗' : '';
  pageLabel.setAttribute('aria-hidden', 'true');
  control.append(titleElement, pageLabel);

  return { control, hasDestination, pageLabel, safeUrl, order };
}

function appendPdfOutlineItems(items, parent, depth, orderState) {
  const list = document.createElement('ol');
  list.className = 'pdf-outline-list';
  parent.append(list);

  for (const item of items) {
    if (!item || typeof item !== 'object') continue;
    const order = orderState.value++;
    const title = pdfOutlineTitle(item, order);
    const children = Array.isArray(item.items)
      ? item.items.filter((child) => child && typeof child === 'object')
      : [];
    const listItem = document.createElement('li');
    listItem.className = 'pdf-outline-item';
    const row = document.createElement('div');
    row.className = 'pdf-outline-row';
    let disclosure = null;
    let childList = null;

    if (children.length) {
      disclosure = document.createElement('button');
      disclosure.type = 'button';
      disclosure.className = 'pdf-outline-disclosure';
      disclosure.dataset.title = title;
      row.append(disclosure);
    } else {
      const spacer = document.createElement('span');
      spacer.className = 'pdf-outline-disclosure-spacer';
      spacer.setAttribute('aria-hidden', 'true');
      row.append(spacer);
    }

    const controlParts = pdfOutlineControl(item, title, children, order);
    const { control, hasDestination, pageLabel, safeUrl } = controlParts;
    control.dataset.outlineOrder = String(order);
    row.append(control);
    listItem.append(row);
    list.append(listItem);

    if (children.length) {
      childList = appendPdfOutlineItems(children, listItem, depth + 1, orderState);
      const expanded = !(Number.isFinite(item.count) && item.count < 0);
      setPdfOutlineBranchExpanded(disclosure, childList, expanded);
      disclosure.addEventListener('click', () => {
        setPdfOutlineBranchExpanded(disclosure, childList, disclosure.getAttribute('aria-expanded') !== 'true');
      });
      if (!hasDestination && !safeUrl && control instanceof HTMLButtonElement) {
        control.addEventListener('click', () => disclosure.click());
      }
    }

    if (hasDestination) {
      const entry = {
        control,
        depth,
        destination: item.dest,
        order,
        pageLabel,
        pageNumber: null,
        title
      };
      pdfOutlineEntries.push(entry);
      control.addEventListener('click', () => {
        if (matchMedia('(max-width: 760px)').matches) setPdfOutlineOpen(false);
        pdfLinkService?.goToDestination(item.dest).catch((error) => {
          setStatus(error.message, { state: 'warning' });
        });
      });
    } else if (safeUrl) {
      control.addEventListener('click', () => {
        if (matchMedia('(max-width: 760px)').matches) setPdfOutlineOpen(false);
      });
    }
  }
  return list;
}

function revealActivePdfOutlineEntry() {
  if (!activePdfOutline || elements['pdf-outline'].hidden) return;
  const control = activePdfOutline.control;
  const tree = elements['outline-tree'];
  const controlRect = control.getBoundingClientRect();
  const treeRect = tree.getBoundingClientRect();
  if (!controlRect.height) return;
  if (controlRect.top < treeRect.top + 8) {
    tree.scrollTop -= treeRect.top + 8 - controlRect.top;
  } else if (controlRect.bottom > treeRect.bottom - 8) {
    tree.scrollTop += controlRect.bottom - treeRect.bottom + 8;
  }
}

function updateActivePdfOutline(pageNumber) {
  const next = activePdfOutlineEntry(pdfOutlineEntries, pageNumber);
  if (next === activePdfOutline) return;
  activePdfOutline?.control.removeAttribute('aria-current');
  activePdfOutline = next;
  activePdfOutline?.control.setAttribute('aria-current', 'location');
  revealActivePdfOutlineEntry();
}

async function resolvePdfOutlinePageNumbers(documentProxy, generation) {
  let nextIndex = 0;
  const worker = async () => {
    while (nextIndex < pdfOutlineEntries.length) {
      const entry = pdfOutlineEntries[nextIndex++];
      let resolved = null;
      try { resolved = await resolvePdfDestination(documentProxy, entry.destination); } catch {}
      if (generation !== loadGeneration || documentProxy !== pdf) return;
      if (!resolved) continue;
      entry.pageNumber = resolved.pageNumber;
      entry.pageLabel.textContent = String(resolved.pageNumber);
      entry.control.setAttribute('aria-label', `${entry.title}, page ${resolved.pageNumber}`);
      updateActivePdfOutline(currentPageState?.pageNumber || 1);
    }
  };
  await Promise.all(Array.from(
    { length: Math.min(4, Math.max(1, pdfOutlineEntries.length)) },
    worker
  ));
}

function showPdfOutlineEmpty(message) {
  const empty = document.createElement('p');
  empty.className = 'pdf-outline-empty';
  empty.textContent = message;
  elements['outline-tree'].replaceChildren(empty);
  elements['outline-toggle'].disabled = false;
}

async function preparePdfOutline(documentProxy, generation) {
  let items;
  try {
    items = await documentProxy.getOutline();
  } catch (error) {
    if (generation !== loadGeneration || documentProxy !== pdf) return;
    elements['outline-status'].textContent = 'Outline unavailable';
    elements['outline-toggle'].title = 'Table of contents unavailable';
    showPdfOutlineEmpty(`The document outline could not be read: ${error?.message || error}`);
    return;
  }
  if (generation !== loadGeneration || documentProxy !== pdf) return;

  const count = pdfOutlineItemCount(items);
  if (!count) {
    elements['outline-status'].textContent = 'No embedded outline';
    elements['outline-toggle'].title = 'Table of contents';
    showPdfOutlineEmpty('This PDF does not include an embedded table of contents.');
    return;
  }

  pdfOutlineEntries = [];
  const fragment = document.createDocumentFragment();
  appendPdfOutlineItems(items, fragment, 0, { value: 0 });
  elements['outline-tree'].replaceChildren(fragment);
  elements['outline-status'].textContent = `${count.toLocaleString()} section${count === 1 ? '' : 's'}`;
  elements['outline-toggle'].disabled = false;
  elements['outline-toggle'].title = 'Table of contents';
  await resolvePdfOutlinePageNumbers(documentProxy, generation);
  updateActivePdfOutline(currentPageState?.pageNumber || 1);
}

function pageViewport(state) {
  if (state.page) return state.page.getViewport({ scale: BASE_SCALE * zoom });
  return {
    width: state.baseWidth * zoom,
    height: state.baseHeight * zoom,
    scale: BASE_SCALE * zoom
  };
}

function sizePage(state) {
  const viewport = pageViewport(state);
  const width = Math.ceil(viewport.width);
  const height = Math.ceil(viewport.height);
  state.shell.style.width = `${width}px`;
  state.surface.style.width = `${width}px`;
  state.surface.style.height = `${height}px`;
  state.surface.style.setProperty('--scale-factor', String(viewport.scale));
}

function updatePageDimensions(state, page) {
  const viewport = page.getViewport({ scale: BASE_SCALE });
  state.baseWidth = viewport.width;
  state.baseHeight = viewport.height;
  if (!state.rendering && !state.renderedZoom) sizePage(state);
}

function nextReaderTurn() {
  return new Promise((resolve) => {
    let settled = false;
    let idleId = null;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (idleId !== null && 'cancelIdleCallback' in window) cancelIdleCallback(idleId);
      resolve();
    };
    const timer = setTimeout(finish, 80);
    requestAnimationFrame(() => {
      if ('requestIdleCallback' in window) {
        idleId = requestIdleCallback(finish, { timeout: 40 });
      } else {
        setTimeout(finish, 0);
      }
    });
  });
}

async function yieldToVisiblePages(generation = loadGeneration) {
  await nextReaderTurn();
  for (let attempts = 0; generation === loadGeneration && !document.hidden
      && (printController || (activePageRenders > 0 && attempts < 6)); attempts += 1) {
    await nextReaderTurn();
  }
  // Timers still fire in background tabs. Stop between batches instead of
  // competing with the website the user has switched to (including OCR).
  const signal = pdfOcrController?.signal;
  while (document.hidden && generation === loadGeneration && !signal?.aborted) {
    await new Promise((resolve) => {
      const finish = () => {
        document.removeEventListener('visibilitychange', finish);
        signal?.removeEventListener('abort', finish);
        resolve();
      };
      document.addEventListener('visibilitychange', finish, { once: true });
      signal?.addEventListener('abort', finish, { once: true });
    });
  }
}

function createPageState(pageNumber, total, defaultViewport, page = null) {
  const shell = document.createElement('section');
  shell.className = 'pdf-page';
  shell.dataset.pageNumber = String(pageNumber);
  shell.setAttribute('aria-label', `PDF page ${pageNumber} of ${total}`);
  const surface = document.createElement('div');
  surface.className = 'pdf-page__surface is-loading';
  const label = document.createElement('span');
  label.className = 'page-label';
  label.textContent = `Page ${pageNumber} of ${total}`;
  shell.append(surface, label);
  const state = {
    page,
    baseWidth: defaultViewport.width,
    baseHeight: defaultViewport.height,
    pageNumber,
    shell,
    surface,
    renderTask: null,
    textLayer: null,
    annotationLayer: null,
    xfaLayer: null,
    annotationCanvasMap: null,
    rendering: null,
    renderError: null,
    renderedZoom: 0,
    displayedZoom: 0,
    nearViewport: false,
    lastRenderedAt: 0,
    indexing: false,
    textIndexed: false,
    contextIndexed: false,
    contextText: null,
    textContentPromise: null,
    version: 0,
    searchText: '',
    searchResults: []
  };
  sizePage(state);
  pageStateByShell.set(shell, state);
  return state;
}

function spreadRowForPage(pageNumber) {
  const index = pdfSpreadIndex(pageNumber);
  let row = spreadRows[index];
  if (row) return row;

  row = document.createElement('div');
  row.className = 'pdf-spread';
  row.dataset.spreadIndex = String(index);
  row.setAttribute('role', 'presentation');

  // Placeholders are appended in page order. Keep direct references instead
  // of repeatedly scanning every existing row while opening a long book.
  spreadRows[index] = row;
  elements.pages.append(row);
  return row;
}

function appendPageStates(states) {
  for (const state of states) spreadRowForPage(state.pageNumber).append(state.shell);
  for (const state of states) {
    renderObserver.observe(state.shell);
    pageVisibilityObserver.observe(state.shell);
  }
}

function cancelled(error) {
  return error?.name === 'RenderingCancelledException' || /cancel/i.test(String(error?.message || ''));
}

function selectionTouchesPage(state) {
  const selection = window.getSelection?.();
  if (!selection || selection.isCollapsed) return false;
  for (let index = 0; index < selection.rangeCount; index += 1) {
    if (selection.getRangeAt(index).intersectsNode(state.surface)) return true;
  }
  return false;
}

function releaseRenderedPage(state) {
  if (!state?.displayedZoom || state.rendering || state.indexing || selectionTouchesPage(state)) return false;
  resetPageSearchHighlights(state);
  detailRenderer.forget(state.pageNumber);
  try { state.renderTask?.cancel(); } catch {}
  try { state.textLayer?.cancel(); } catch {}
  state.page?.cleanup?.();
  state.page = null;
  state.renderTask = null;
  state.textLayer = null;
  state.annotationLayer = null;
  state.xfaLayer = null;
  state.annotationCanvasMap = null;
  state.renderedZoom = 0;
  state.displayedZoom = 0;
  renderedPageStates.delete(state);
  for (const canvas of state.surface.querySelectorAll('canvas')) canvas.width = canvas.height = 0;
  state.surface.replaceChildren();
  state.surface.classList.add('is-loading');
  sizePage(state);
  return true;
}

function trimRenderedPages() {
  const rendered = [...renderedPageStates].filter((state) => !state.rendering);
  const pixels = (state) => [...state.surface.querySelectorAll('canvas')]
    .reduce((total, canvas) => total + canvas.width * canvas.height, 0);
  let retainedPixels = rendered.reduce((total, state) => total + pixels(state), 0);
  if (rendered.length <= MAX_RENDERED_PAGES && retainedPixels <= MAX_RETAINED_CANVAS_PIXELS) return;
  const candidates = rendered
    .filter((state) => !visiblePageStates.has(state) && state !== currentPageState)
    .sort((left, right) => left.lastRenderedAt - right.lastRenderedAt);
  let remaining = rendered.length;
  for (const state of candidates) {
    if (remaining <= MAX_RENDERED_PAGES && retainedPixels <= MAX_RETAINED_CANVAS_PIXELS) break;
    const pagePixels = pixels(state);
    if (releaseRenderedPage(state)) { remaining -= 1; retainedPixels -= pagePixels; }
  }
}

function pageTextContent(state, page) {
  if (state.textContentPromise) return state.textContentPromise;
  const pending = page.getTextContent({
    includeMarkedContent: true,
    disableNormalization: true
  });
  state.textContentPromise = pending;
  pending.finally(() => {
    if (state.textContentPromise === pending) state.textContentPromise = null;
  }).catch(() => {});
  return pending;
}

async function indexPageText(state, page, { includeContext = true } = {}) {
  if (state.textIndexed && (!includeContext || state.contextIndexed || state.contextText !== null)) {
    return state.contextText;
  }
  const textContent = await pageTextContent(state, page);
  if (!state.textIndexed) {
    state.searchText = pdfSearchTextContent(textContent.items).text;
    state.textIndexed = true;
  }
  if (includeContext && !state.contextIndexed && state.contextText === null) {
    state.contextText = textContentToString(textContent.items);
  }
  return state.contextText;
}

async function renderPdfAnnotationLayer(state, page, viewport, version, annotationsPromise) {
  const annotations = recoverPdfAnnotationLinks(await annotationsPromise, pdfLinkService?.baseUrl);
  if (version !== state.version || !annotations.length) return;
  const container = document.createElement('div');
  container.className = 'annotationLayer';
  state.surface.append(container);
  const annotationLayer = new pdfjs.AnnotationLayer({
    div: container,
    page,
    viewport,
    annotationCanvasMap: state.annotationCanvasMap
  });
  state.annotationLayer = annotationLayer;
  await annotationLayer.render({
    annotations,
    annotationCanvasMap: state.annotationCanvasMap,
    annotationStorage: pdf.annotationStorage,
    div: container,
    downloadManager: pdfDownloadManager,
    enableScripting: false,
    fieldObjects: await fieldObjectsPromise.catch(() => null),
    hasJSActions: false,
    imageResourcesPath: chrome.runtime.getURL('vendor/pdfjs/images/'),
    linkService: pdfLinkService,
    page,
    renderForms: true,
    viewport
  });
  if (version !== state.version) return;
  for (const link of container.querySelectorAll('a')) {
    if (link.textContent.trim() || link.hasAttribute('aria-label')) continue;
    link.setAttribute('aria-label', link.title || (link.closest('[data-internal-link]')
      ? 'Go to linked location in this PDF'
      : 'Open PDF link'));
  }
}

function showPageRenderError(state, error) {
  const notice = document.createElement('div');
  notice.className = 'page-render-error';
  const title = document.createElement('strong');
  title.textContent = `Page ${state.pageNumber} could not be drawn`;
  const detail = document.createElement('span');
  detail.textContent = 'The PDF is still open. Retry this page or use the browser PDF view.';
  const actions = document.createElement('div');
  actions.className = 'page-render-error__actions';
  const retry = document.createElement('button');
  retry.type = 'button';
  retry.textContent = 'Retry page';
  retry.addEventListener('click', () => {
    state.renderError = null;
    state.renderedZoom = 0;
    renderPage(state).catch(() => {});
  });
  const native = document.createElement('button');
  native.type = 'button';
  native.textContent = 'Browser view';
  native.addEventListener('click', () => openNativePdf());
  actions.append(retry, native);
  notice.append(title, detail, actions);
  state.surface.replaceChildren(notice);
  state.surface.classList.remove('is-loading');
  state.surface.title = error?.message || 'This page could not be rendered.';
}

async function renderPage(state) {
  if (!pdf || state.renderedZoom === zoom) return;
  if (state.rendering) return state.rendering;
  const version = ++state.version;
  const generation = loadGeneration;
  const renderZoom = zoom;
  let pendingCanvas;
  activePageRenders += 1;
  state.rendering = (async () => {
    const page = state.page || await pdf.getPage(state.pageNumber);
    if (version !== state.version || generation !== loadGeneration) return;
    state.page = page;
    state.renderError = null;
    updatePageDimensions(state, page);
    const viewport = pageViewport(state);
    const pixelRatio = pdfCanvasScale(viewport.width, viewport.height, window.devicePixelRatio, MAX_CANVAS_PIXELS);
    if (!state.displayedZoom) state.surface.classList.add('is-loading');
    sizePage(state);

    const canvas = document.createElement('canvas');
    pendingCanvas = canvas;
    canvas.width = Math.max(1, Math.floor(viewport.width * pixelRatio));
    canvas.height = Math.max(1, Math.floor(viewport.height * pixelRatio));
    canvas.style.width = `${viewport.width}px`;
    canvas.style.height = `${viewport.height}px`;
    const context = canvas.getContext('2d', { alpha: false });
    if (!context) throw new Error(`Page ${state.pageNumber} could not create a canvas.`);

    const textLayerElement = document.createElement('div');
    textLayerElement.className = 'textLayer';
    state.surface.title = '';
    state.annotationCanvasMap = new Map();
    const annotationsPromise = page.getAnnotations({ intent: 'display' }).catch(() => []);
    state.renderTask = page.render({
      annotationCanvasMap: state.annotationCanvasMap,
      annotationMode: pdfjs.AnnotationMode.ENABLE_FORMS,
      canvasContext: context,
      optionalContentConfigPromise,
      transform: [canvas.width / viewport.width, 0, 0, canvas.height / viewport.height, 0, 0],
      viewport
    });
    const renderTask = state.renderTask;
    renderTask.onContinue = (continueRender) => {
      if (document.hidden || (!state.nearViewport && state !== currentPageState)) renderTask.cancel();
      else continueRender();
    };
    await state.renderTask.promise;
    if (version !== state.version || generation !== loadGeneration) return;
    const previousCanvases = [...state.surface.querySelectorAll('canvas')];
    detailRenderer.forget(state.pageNumber);
    state.surface.replaceChildren(canvas, textLayerElement);
    pendingCanvas = null;
    for (const previous of previousCanvases) previous.width = previous.height = 0;
    state.renderedZoom = renderZoom;
    state.displayedZoom = renderZoom;
    renderedPageStates.add(state);
    state.lastRenderedAt = ++renderSequence;
    if (page.isPureXfa) {
      const xfaHtml = await page.getXfa();
      if (version !== state.version) return;
      if (xfaHtml) {
        const xfaLayer = document.createElement('div');
        pdfjs.XfaLayer.render({
          viewport: viewport.clone({ dontFlip: true }),
          div: xfaLayer,
          xfaHtml,
          annotationStorage: pdf.annotationStorage,
          linkService: pdfLinkService,
          intent: 'display'
        });
        state.xfaLayer = xfaLayer;
        state.surface.append(xfaLayer);
      }
    }
    state.surface.classList.remove('is-loading');
    detailRenderer.schedule();
    trimRenderedPages();
    const annotationRenderPromise = renderPdfAnnotationLayer(
      state,
      page,
      viewport,
      version,
      annotationsPromise
    ).catch((error) => {
      if (!cancelled(error)) console.warn(`Page ${state.pageNumber} annotations could not be rendered.`, error);
    });

    const textContent = await pageTextContent(state, page);
    if (version !== state.version) return;
    const searchContent = pdfSearchTextContent(textContent.items);
    state.searchItemStarts = searchContent.itemStarts;
    if (!state.textIndexed) {
      state.searchText = searchContent.text;
      state.textIndexed = true;
    }
    if (!state.contextIndexed && state.contextText === null) {
      state.contextText = textContentToString(textContent.items);
    }
    state.textLayer = new pdfjs.TextLayer({
      textContentSource: textContent,
      container: textLayerElement,
      viewport
    });
    await state.textLayer.render();
    if (version !== state.version) return;
    const end = document.createElement('div');
    end.className = 'endOfContent';
    textLayerElement.append(end);
    applyPdfSearchHighlights(state);
    await annotationRenderPromise;
  })().catch((error) => {
    if (version === state.version && !cancelled(error)) {
      state.renderError = error;
      showPageRenderError(state, error);
    }
  }).finally(() => {
    if (pendingCanvas) pendingCanvas.width = pendingCanvas.height = 0;
    activePageRenders = Math.max(0, activePageRenders - 1);
    if (version === state.version) state.rendering = null;
    trimRenderedPages();
  });
  return state.rendering;
}

function resetRenderedPages() {
  detailRenderer.invalidate();
  for (const state of pageStates) {
    resetPageSearchHighlights(state);
    state.version += 1;
    try { state.renderTask?.cancel(); } catch {}
    try { state.textLayer?.cancel(); } catch {}
    state.renderTask = null;
    state.textLayer = null;
    state.annotationLayer = null;
    state.xfaLayer = null;
    state.annotationCanvasMap = null;
    state.rendering = null;
    state.renderError = null;
    state.renderedZoom = 0;
    const previous = state.surface.querySelector('canvas:not(.pdf-detail-canvas)');
    // Scale the last complete page immediately; replace it only after the next
    // render finishes. Text/annotations are rebuilt at the new scale.
    state.surface.replaceChildren(...(previous ? [previous] : []));
    state.surface.classList.toggle('is-loading', !previous);
    if (previous) {
      const viewport = pageViewport(state);
      previous.style.width = `${viewport.width}px`;
      previous.style.height = `${viewport.height}px`;
    }
    sizePage(state);
    renderObserver.unobserve(state.shell);
    renderObserver.observe(state.shell);
  }
}

function pdfViewerContentWidth() {
  const styles = getComputedStyle(elements.viewer);
  const horizontalPadding = Number.parseFloat(styles.paddingLeft || '0')
    + Number.parseFloat(styles.paddingRight || '0');
  return Math.max(1, elements.viewer.clientWidth - horizontalPadding);
}

function pdfViewerContentHeight() {
  const toolbarHeight = document.querySelector('.toolbar')?.getBoundingClientRect().height || 0;
  return Math.max(1, window.innerHeight - toolbarHeight - 48);
}

function pdfSpreadDimensions(pageNumber, fallbackWidth = 0) {
  const total = pdf?.numPages || pageStates.length;
  const firstIndex = pdfSpreadIndex(pageNumber) * 2;
  const firstWidth = pageStates[firstIndex]?.baseWidth || fallbackWidth || pageStates[0]?.baseWidth || 0;
  const hasSecondPage = firstIndex + 1 < total;
  const secondWidth = hasSecondPage
    ? pageStates[firstIndex + 1]?.baseWidth || firstWidth
    : 0;
  const firstHeight = pageStates[firstIndex]?.baseHeight || currentPageState?.baseHeight || 0;
  const secondHeight = hasSecondPage
    ? pageStates[firstIndex + 1]?.baseHeight || firstHeight
    : 0;
  return {
    baseWidth: firstWidth + secondWidth,
    baseHeight: Math.max(firstHeight, secondHeight),
    gap: hasSecondPage ? PDF_SPREAD_GAP : 0
  };
}

function pdfWidthFitZoom(state, availableWidth = pdfViewerContentWidth()) {
  if (pdfPageLayout !== 'spread') return availableWidth / state.baseWidth;
  const spread = pdfSpreadDimensions(state.pageNumber, state.baseWidth);
  return spread.baseWidth > 0 ? (availableWidth - spread.gap) / spread.baseWidth : zoom;
}

function updatePdfZoomControl() {
  if (pdfZoomMode !== 'custom') {
    elements['zoom-label'].value = pdfZoomMode;
  } else {
    const preset = PDF_ZOOM_PRESETS.find((value) => Math.abs(value - zoom) < 0.001);
    if (preset !== undefined) {
      elements['zoom-custom'].value = '1';
      elements['zoom-custom'].textContent = '100%';
      elements['zoom-label'].value = String(preset);
    } else {
      elements['zoom-custom'].value = 'custom';
      elements['zoom-custom'].textContent = `${Math.round(zoom * 100)}%`;
      elements['zoom-label'].value = 'custom';
    }
  }
  updatePdfViewMenuControl();
}

function pdfZoomForMode(mode, state) {
  const widthZoom = pdfWidthFitZoom(state);
  if (mode === 'width') return widthZoom;
  if (mode === 'page') {
    const height = pdfPageLayout === 'spread'
      ? pdfSpreadDimensions(state.pageNumber, state.baseWidth).baseHeight
      : state.baseHeight;
    return Math.min(widthZoom, pdfViewerContentHeight() / Math.max(1, height));
  }
  return Math.min(1, widthZoom);
}

function applyPdfZoomMode(state = currentPageState || pageStates[0], { anchor } = {}) {
  if (pdfZoomMode === 'custom' || !state) {
    updatePdfZoomControl();
    if (anchor) restorePdfViewAnchor(anchor);
    return;
  }
  updateZoom(pdfZoomForMode(pdfZoomMode, state), { preserveMode: true, anchor });
}

function selectPdfZoomMode() {
  const value = elements['zoom-label'].value;
  if (['auto', 'page', 'width'].includes(value)) {
    pdfZoomMode = value;
    spreadAutoZoom = null;
    zoomBeforeSpread = null;
    chrome.storage.local.set({ [PDF_ZOOM_MODE_KEY]: pdfZoomMode }).catch(() => {});
    applyPdfZoomMode();
    return;
  }
  const selectedZoom = Number.parseFloat(value);
  if (Number.isFinite(selectedZoom)) updateZoom(selectedZoom, { persist: true });
  else updatePdfZoomControl();
}

function fitPdfSpread({ anchor } = {}) {
  if (pdfPageLayout !== 'spread' || !pageStates.length) return;
  const state = currentPageState || pageStates[0];
  const next = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, pdfWidthFitZoom(state)));
  if (!Number.isFinite(next) || next >= zoom - 0.005) {
    if (anchor) restorePdfViewAnchor(anchor);
    return;
  }
  if (spreadAutoZoom === null || Math.abs(zoom - spreadAutoZoom) >= 0.001) {
    zoomBeforeSpread = zoom;
  }
  updateZoom(next, { preserveMode: true, anchor });
  spreadAutoZoom = zoom;
}

function updateZoom(next, { preserveMode = false, persist = false, anchor } = {}) {
  const viewAnchor = anchor === undefined ? capturePdfViewAnchor() : anchor;
  if (!preserveMode) {
    pdfZoomMode = 'custom';
    spreadAutoZoom = null;
    zoomBeforeSpread = null;
    if (persist) chrome.storage.local.set({ [PDF_ZOOM_MODE_KEY]: 'custom' }).catch(() => {});
  }
  const rounded = Math.round(Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, next)) * 100) / 100;
  if (rounded === zoom) {
    updatePdfZoomControl();
    if (viewAnchor) restorePdfViewAnchor(viewAnchor);
    return;
  }
  zoom = rounded;
  updatePdfZoomControl();
  elements['zoom-out'].disabled = zoom <= MIN_ZOOM;
  elements['zoom-in'].disabled = zoom >= MAX_ZOOM;
  resetRenderedPages();
  restorePdfViewAnchor(viewAnchor);
}

async function waitForPdfPageState(pageNumber) {
  const generation = loadGeneration;
  for (let attempts = 0; attempts < 500; attempts += 1) {
    if (generation !== loadGeneration || !pdf) return null;
    if (pageStates[pageNumber - 1]) return pageStates[pageNumber - 1];
    await nextReaderTurn();
  }
  return null;
}

function applyPdfDestinationZoom(state, destination) {
  const mode = destination?.[1]?.name;
  const toolbarHeight = document.querySelector('.toolbar')?.getBoundingClientRect().height || 0;
  const availableWidth = pdfViewerContentWidth();
  const availableHeight = Math.max(1, window.innerHeight - toolbarHeight - 36);
  const widthFitZoom = pdfWidthFitZoom(state, availableWidth);
  let nextZoom = null;

  if (mode === 'XYZ' && Number.isFinite(destination[4]) && destination[4] > 0) {
    nextZoom = destination[4] * PDF_CSS_UNITS / BASE_SCALE;
  } else if (mode === 'Fit' || mode === 'FitB') {
    nextZoom = Math.min(widthFitZoom, availableHeight / state.baseHeight);
  } else if (['FitH', 'FitBH'].includes(mode)) {
    nextZoom = widthFitZoom;
  } else if (['FitV', 'FitBV'].includes(mode)) {
    nextZoom = availableHeight / state.baseHeight;
  } else if (mode === 'FitR' && state.page) {
    const rectangle = state.page.getViewport({ scale: BASE_SCALE }).convertToViewportRectangle(destination.slice(2, 6));
    const width = Math.abs(rectangle[2] - rectangle[0]);
    const height = Math.abs(rectangle[3] - rectangle[1]);
    if (width && height) nextZoom = Math.min(availableWidth / width, availableHeight / height);
  }
  if (Number.isFinite(nextZoom) && nextZoom > 0) updateZoom(nextZoom);
}

async function navigateToPdfDestination(pageNumber, destination = null) {
  const navigation = ++pdfNavigationSequence;
  cancelPdfViewAnchorRestore();
  const state = await waitForPdfPageState(pageNumber);
  if (!state || navigation !== pdfNavigationSequence) return;
  setCurrentPdfPageState(state);
  if (!state.page) state.page = await pdf.getPage(pageNumber);
  if (navigation !== pdfNavigationSequence) return;
  updatePageDimensions(state, state.page);
  if (pdfZoomMode === 'custom') applyPdfDestinationZoom(state, destination);
  else applyPdfZoomMode(state);
  cancelPdfViewAnchorRestore();
  state.shell.scrollIntoView({ block: 'start', inline: 'nearest', behavior: 'auto' });
  setCurrentPdfPageState(state);
  await renderPage(state);
  if (navigation !== pdfNavigationSequence) return;

  const mode = destination?.[1]?.name;
  let pdfX = null;
  let pdfY = null;
  if (mode === 'XYZ') {
    [pdfX, pdfY] = [destination[2], destination[3]];
  } else if (mode === 'FitH' || mode === 'FitBH') {
    pdfY = destination[2];
  } else if (mode === 'FitV' || mode === 'FitBV') {
    pdfX = destination[2];
  } else if (mode === 'FitR') {
    pdfX = destination[2];
    pdfY = destination[5];
  }

  const toolbarHeight = document.querySelector('.toolbar')?.getBoundingClientRect().height || 0;
  const surfaceRect = state.surface.getBoundingClientRect();
  let top = window.scrollY + surfaceRect.top - toolbarHeight - 12;
  let left = window.scrollX;
  if (Number.isFinite(pdfX) || Number.isFinite(pdfY)) {
    const view = state.page.view;
    const [viewportX, viewportY] = pageViewport(state).convertToViewportPoint(
      Number.isFinite(pdfX) ? pdfX : view[0],
      Number.isFinite(pdfY) ? pdfY : view[3]
    );
    if (Number.isFinite(pdfX)) left = window.scrollX + surfaceRect.left + viewportX - 18;
    if (Number.isFinite(pdfY)) top = window.scrollY + surfaceRect.top + viewportY - toolbarHeight - 12;
  }
  window.scrollTo({ top: Math.max(0, top), left: Math.max(0, left), behavior: 'auto' });
  updatePageCounter(state.pageNumber, undefined, { force: true });
  updateActivePdfOutline(state.pageNumber);
}

function updateCurrentPage() {
  scrollFrame = null;
  if (!pageStates.length) return;
  if (pendingPdfViewAnchor) {
    const state = pageStates[pendingPdfViewAnchor.pageNumber - 1] || currentPageState;
    if (state) {
      setCurrentPdfPageState(state);
      updatePageCounter(state.pageNumber);
      updateActivePdfOutline(state.pageNumber);
    }
    return;
  }
  if (pdfPageLayout === 'page') {
    const state = currentPageState || pageStates[0];
    setCurrentPdfPageState(state);
    updatePageCounter(state.pageNumber);
    updateActivePdfOutline(state.pageNumber);
    return;
  }
  const toolbarBottom = document.querySelector('.toolbar').getBoundingClientRect().bottom;
  const candidates = visiblePageStates.size
    ? [...new Set([...visiblePageStates, currentPageState].filter(Boolean))]
    : currentPageState ? [currentPageState] : [pageStates[0]];
  let best = candidates.includes(currentPageState) ? currentPageState : candidates[0];
  const bestRect = best?.shell.getBoundingClientRect();
  let bestDistance = bestRect
    ? Math.abs(bestRect.top - toolbarBottom - 18)
    : Number.POSITIVE_INFINITY;
  for (const state of candidates) {
    const rect = state.shell.getBoundingClientRect();
    if (rect.bottom < toolbarBottom || rect.top > innerHeight) continue;
    const distance = Math.abs(rect.top - toolbarBottom - 18);
    if (distance < bestDistance - 0.5) { best = state; bestDistance = distance; }
  }
  setCurrentPdfPageState(best);
  updatePageCounter(best.pageNumber);
  updateActivePdfOutline(best.pageNumber);
}

function scheduleCurrentPage() {
  if (scrollFrame) return;
  scrollFrame = requestAnimationFrame(updateCurrentPage);
}

function initializeObservers() {
  renderObserver?.disconnect();
  pageVisibilityObserver?.disconnect();
  visiblePageStates = new Set();
  pageStateByShell = new WeakMap();
  renderObserver = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      const state = pageStateByShell.get(entry.target);
      if (!state) continue;
      state.nearViewport = entry.isIntersecting;
      if (entry.isIntersecting && !document.hidden) renderPage(state);
    }
    trimRenderedPages();
  }, { rootMargin: `${PAGE_RENDER_MARGIN}px 0px` });
  pageVisibilityObserver = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      const state = pageStateByShell.get(entry.target);
      if (!state) continue;
      if (entry.isIntersecting) {
        visiblePageStates.add(state);
        if (!document.hidden) renderPage(state);
      }
      else visiblePageStates.delete(state);
    }
    scheduleCurrentPage();
    detailRenderer.schedule();
  });
}

function resetPageSearchHighlights(state) {
  for (const [div, text] of state?.highlightedDivs || []) {
    if (div.isConnected) div.textContent = text;
  }
  state.highlightedDivs = null;
  state.highlightedLayer = null;
  state.highlightedResults = null;
  state.highlightNodes = null;
}

function clearPdfSearchHighlights({ preserveSelection = false } = {}) {
  for (const state of pageStates) {
    if (!preserveSelection || !selectionTouchesPage(state)) resetPageSearchHighlights(state);
  }
}

function appendSearchRanges(state, div, text, ranges) {
  const fragment = document.createDocumentFragment();
  let cursor = 0;
  for (const range of ranges) {
    if (range.start > cursor) fragment.append(document.createTextNode(text.slice(cursor, range.start)));
    const highlight = document.createElement('span');
    highlight.className = `pdf-search-highlight${range.resultIndex === activePdfSearchIndex ? ' is-current' : ''}`;
    highlight.dataset.pdfSearchResult = String(range.resultIndex);
    highlight.textContent = text.slice(range.start, range.end);
    const nodes = state.highlightNodes.get(range.resultIndex) || [];
    nodes.push(highlight);
    state.highlightNodes.set(range.resultIndex, nodes);
    if (range.resultIndex === activePdfSearchIndex) activePdfSearchHighlights.push(highlight);
    fragment.append(highlight);
    cursor = range.end;
  }
  if (cursor < text.length) fragment.append(document.createTextNode(text.slice(cursor)));
  div.replaceChildren(fragment);
}

function applyPdfSearchHighlights(state) {
  if (state.highlightedLayer === state.textLayer && state.highlightedResults === state.searchResults) return;
  resetPageSearchHighlights(state);
  if (elements['pdf-search'].hidden || !state?.searchResults?.length || !state.textLayer) return;
  state.highlightedLayer = state.textLayer;
  state.highlightedResults = state.searchResults;
  state.highlightedDivs = new Map();
  state.highlightNodes = new Map();

  const items = state.textLayer.textContentItemsStr || [];
  const divs = state.textLayer.textDivs || [];
  const rangesByItem = new Map();
  for (const result of state.searchResults) {
    for (const segment of pdfMatchItemSegments(items, result.start, result.length, state.searchItemStarts)) {
      const ranges = rangesByItem.get(segment.itemIndex) || [];
      ranges.push({ ...segment, resultIndex: result.resultIndex });
      rangesByItem.set(segment.itemIndex, ranges);
    }
  }
  for (const [itemIndex, ranges] of rangesByItem) {
    const div = divs[itemIndex];
    if (!div) continue;
    ranges.sort((left, right) => left.start - right.start);
    state.highlightedDivs.set(div, items[itemIndex] || '');
    appendSearchRanges(state, div, items[itemIndex] || '', ranges);
  }
}

function updateActivePdfSearchHighlight() {
  for (const node of activePdfSearchHighlights) node.classList.remove('is-current');
  const result = pdfSearchResults[activePdfSearchIndex];
  activePdfSearchHighlights = pageStates[result?.pageIndex]?.highlightNodes?.get(activePdfSearchIndex) || [];
  for (const node of activePdfSearchHighlights) node.classList.add('is-current');
}

function updatePdfSearchControls() {
  const query = elements['search-input'].value.trim();
  const hasResults = pdfSearchResults.length > 0;
  const semantic = semanticPdfSearchActive();
  const searchReady = pdfSearchReady && (!semantic || pdfSemanticIndex?.finalized);
  if (!query) elements['search-count'].textContent = '0 / 0';
  else if (!searchReady) elements['search-count'].textContent = semantic ? 'Indexing concepts…' : 'Indexing…';
  else if (!hasResults) elements['search-count'].textContent = pdfComprehensiveIndexReady
    ? 'No results' : 'No results yet · indexing…';
  else {
    const total = `${pdfSearchResults.length.toLocaleString()}${pdfSearchTruncated ? '+' : ''}`;
    const progress = !pdfBasicIndexReady ? ' · indexing…'
      : !pdfComprehensiveIndexReady ? ' · recognizing scans…' : '';
    elements['search-count'].textContent = `${(activePdfSearchIndex + 1).toLocaleString()} / ${total}${semantic ? ' pages' : ''}${progress}`;
  }
  elements['search-previous'].disabled = !hasResults;
  elements['search-next'].disabled = !hasResults;
}

function clearPdfSearchResults({ preserveSelection = false } = {}) {
  pdfSearchController?.abort();
  clearPdfSearchHighlights({ preserveSelection });
  for (const state of pageStates) state.searchResults = [];
  pdfSearchResults = [];
  pdfSearchTruncated = false;
  activePdfSearchIndex = -1;
  activePdfSearchHighlights = [];
  pdfSearchAction += 1;
  updatePdfSearchControls();
}

async function runPdfSearch({ resetActive = true, reveal = true } = {}) {
  const previousResult = !resetActive && pdfSearchResults[activePdfSearchIndex];
  clearTimeout(pdfSearchTimer);
  pdfSearchTimer = null;
  clearPdfSearchResults({ preserveSelection: !resetActive });
  const query = elements['search-input'].value;
  const semantic = semanticPdfSearchActive();
  if (!query.trim() || !pdfSearchReady || elements['pdf-search'].hidden) return;
  if (semantic && !pdfSemanticIndex?.finalized) {
    startPdfSemanticIndex();
    return;
  }

  const pageTexts = pageStates.map((state) => state.searchText);
  const controller = pdfSearchController = new AbortController();
  const found = semantic
    ? findPdfSemanticMatches(pageTexts, query, pdfSemanticIndex)
    : await findPdfMatchesAsync(pageTexts, query, { signal: controller.signal }).catch((error) => {
      if (error.name !== 'AbortError') throw error;
    });
  if (!found || controller.signal.aborted) return;
  pdfSearchTruncated = found.truncated;
  pdfSearchResults = found.matches.map((result, resultIndex) => ({ ...result, resultIndex }));
  for (const state of pageStates) state.searchResults = [];
  for (const result of pdfSearchResults) {
    pageStates[result.pageIndex]?.searchResults.push(result);
  }
  const previousIndex = previousResult ? pdfSearchResults.findIndex((result) =>
    result.pageIndex === previousResult.pageIndex && result.start === previousResult.start) : -1;
  activePdfSearchIndex = previousIndex >= 0 ? previousIndex : reveal && pdfSearchResults.length ? 0 : -1;
  for (const state of pageStates) {
    if (resetActive || !selectionTouchesPage(state)) applyPdfSearchHighlights(state);
  }
  updatePdfSearchControls();
  if (reveal && activePdfSearchIndex >= 0) {
    navigateToActivePdfSearchResult().catch(() => {});
  }
}

function schedulePdfSearch() {
  pdfSearchController?.abort();
  pdfSearchAction += 1;
  clearTimeout(pdfSearchTimer);
  pdfSearchTimer = setTimeout(() => {
    pdfSearchTask = runPdfSearch({ resetActive: true, reveal: true });
  }, 180);
}

async function navigateToActivePdfSearchResult({ behavior = 'auto' } = {}) {
  const result = pdfSearchResults[activePdfSearchIndex];
  const state = result && pageStates[result.pageIndex];
  if (!state) return;
  const action = ++pdfSearchAction;
  setCurrentPdfPageState(state);
  if (!state.textLayer) state.shell.scrollIntoView({ block: 'center', inline: 'nearest', behavior });
  await renderPage(state);
  if (action !== pdfSearchAction || result !== pdfSearchResults[activePdfSearchIndex]) return;
  applyPdfSearchHighlights(state);
  updateActivePdfSearchHighlight();
  const highlight = state.surface.querySelector(`[data-pdf-search-result="${activePdfSearchIndex}"]`);
  (highlight || state.shell).scrollIntoView({ block: 'center', inline: 'nearest', behavior });
  updatePageCounter(state.pageNumber);
  updateActivePdfOutline(state.pageNumber);
}

async function movePdfSearch(direction) {
  if (pdfSearchTimer) pdfSearchTask = runPdfSearch({ resetActive: true, reveal: false });
  if (pdfSearchTask) { await pdfSearchTask; pdfSearchTask = null; }
  if (!pdfSearchResults.length) return;
  activePdfSearchIndex = activePdfSearchIndex < 0
    ? (direction < 0 ? pdfSearchResults.length - 1 : 0)
    : (activePdfSearchIndex + (direction < 0 ? -1 : 1) + pdfSearchResults.length) % pdfSearchResults.length;
  updateActivePdfSearchHighlight();
  updatePdfSearchControls();
  navigateToActivePdfSearchResult().catch(() => {});
}

function openPdfSearch() {
  elements['pdf-search'].hidden = false;
  elements['search-toggle'].setAttribute('aria-expanded', 'true');
  // Keep the saved query available without leaving the user's reading position.
  runPdfSearch({ resetActive: true, reveal: false });
  requestAnimationFrame(() => {
    elements['search-input'].focus();
    elements['search-input'].select();
  });
}

function closePdfSearch({ clearQuery = false, restoreFocus = true } = {}) {
  const wasOpen = !elements['pdf-search'].hidden;
  clearTimeout(pdfSearchTimer);
  pdfSearchTimer = null;
  pdfSearchTask = null;
  clearPdfSearchResults();
  elements['pdf-search'].hidden = true;
  elements['search-toggle'].setAttribute('aria-expanded', 'false');
  if (clearQuery) elements['search-input'].value = '';
  updatePdfSearchControls();
  if (wasOpen && restoreFocus) elements['search-toggle'].focus();
}

function preparePdfSearchForDocument() {
  closePdfSearch({ clearQuery: true, restoreFocus: false });
  pdfSearchReady = false;
  pdfBasicIndexReady = false;
  pdfComprehensiveIndexReady = false;
  pdfSemanticIndex = null;
  semanticIndexingTask = null;
  pdfReadyStatus = '';
  pdfBackgroundStatus = null;
  updatePdfSearchControls();
}

async function documentTitle(documentProxy) {
  try {
    const info = (await documentProxy.getMetadata()).info || {};
    return String(info.Title || '').replace(/\s+/g, ' ').trim().slice(0, 500);
  } catch {
    return '';
  }
}

function updateDocumentTitle(title) {
  document.title = `${title} — Scholia PDF`;
  elements['document-title'].textContent = title;
}

async function indexPdfPage(documentProxy, state, { includeContext, ocrReader = null, nativeText } = {}) {
  state.indexing = true;
  let page = state.page;
  try {
    page ||= await documentProxy.getPage(state.pageNumber);
    nativeText ??= await indexPageText(state, page, { includeContext });
    const contextText = includeContext && ocrReader
      ? await ocrReader.readPage(page, nativeText || '', state.pageNumber) : nativeText;
    if (contextText && contextText !== nativeText) state.searchText += `\n${contextText}`;
    return { state, contextText: contextText || '' };
  } catch (error) {
    // A failed OCR pass must leave the basic search index intact.
    return { state, contextText: nativeText || state.contextText || '', error };
  } finally {
    state.indexing = false;
    if (page && state.page !== page && !state.rendering && !state.renderedZoom) page.cleanup();
  }
}

function semanticPageSample(value, maxCharacters) {
  const text = String(value || '');
  if (text.length <= maxCharacters) return text;
  const part = Math.max(1, Math.floor(maxCharacters / 3));
  const middle = Math.max(part, Math.floor((text.length - part) / 2));
  return `${text.slice(0, part)}\n${text.slice(middle, middle + part)}\n${text.slice(-part)}`;
}

function startPdfSemanticIndex() {
  if (!pdfComprehensiveIndexReady || pdfSemanticIndex?.finalized) return Promise.resolve(pdfSemanticIndex);
  if (semanticIndexingTask) return semanticIndexingTask;
  const generation = loadGeneration;
  const task = (async () => {
    const index = createPdfSemanticIndex();
    const perPageCharacters = Math.max(
      1_600,
      Math.floor(MAX_EXTRACTED_CHARACTERS / Math.max(1, pageStates.length))
    );
    setStatus(`${pdfReadyStatus || 'PDF ready'} · indexing semantic search`, {
      state: 'working',
      current: 0,
      total: pageStates.length, owner: 'background'
    });
    updatePdfSearchControls();
    await yieldToVisiblePages(generation);
    for (const [pageIndex, state] of pageStates.entries()) {
      if (generation !== loadGeneration) return;
      addPdfSemanticPage(index, semanticPageSample(state.searchText, perPageCharacters), pageIndex);
      if ((pageIndex + 1) % 12 === 0 || pageIndex + 1 === pageStates.length) {
        setStatus(`PDF ready · indexing semantic search ${pageIndex + 1} of ${pageStates.length}`, {
          state: 'working',
          current: pageIndex + 1,
          total: pageStates.length, owner: 'background'
        });
        await yieldToVisiblePages(generation);
      }
    }
    if (generation !== loadGeneration) return;
    pdfSemanticIndex = finalizePdfSemanticIndex(index);
    if (semanticPdfSearchActive()) runPdfSearch({ resetActive: false, reveal: false });
    else updatePdfSearchControls();
    setStatus(`${pdfReadyStatus || 'PDF ready'} · semantic search ready`, { state: 'ready', owner: 'background' });
  })();
  semanticIndexingTask = task;
  task.catch((error) => {
    if (generation !== loadGeneration) return;
    pdfSemanticIndex = null;
    updatePdfSearchControls();
    setStatus(`${pdfReadyStatus || 'PDF ready'} · semantic search unavailable: ${error?.message || error}`, {
      state: 'warning', owner: 'background'
    });
  }).finally(() => {
    if (generation === loadGeneration && semanticIndexingTask === task) semanticIndexingTask = null;
  });
  return task;
}

async function preparePdfPages({
  generation,
  documentProxy,
  defaultViewport,
  titlePromise,
  metadataResolver,
  sourceUrl
}) {
  const contextPages = [];
  const pagesToIndex = Math.min(documentProxy.numPages, MAX_EXTRACTED_PAGES);
  const cacheKey = pdfIndexCacheKey(documentProxy);
  const cachedIndexPromise = readPdfIndexCache(cacheKey, {
    pageCount: documentProxy.numPages,
    indexedPageCount: pagesToIndex
  });
  let appendedThrough = 1;
  let nextPageToIndex = 1;
  let extractedCharacters = 0;
  let title = elements['document-title'].textContent;
  let restoredOcr = null;
  let indexErrors = 0;
  const ocrReader = pdfOcrReader;

  const publishMetadata = (stage = 'basic', pages = contextPages) => {
    if (generation !== loadGeneration) return;
    const formatted = formatPdfContext(pages, documentProxy.numPages, {
      indexing: stage === 'basic' && !pdfBasicIndexReady
    });
    const pending = stage === 'basic'
      ? 'Basic PDF text is available. Text recognition for scanned pages is still in progress.' : '';
    metadataResolver({
      ...formatted,
      ...(restoredOcr || ocrReader?.summary()),
      context: pending ? `[${pending}]\n\n${formatted.context}` : formatted.context,
      pdfIndexStage: stage,
      truncated: pages.length < documentProxy.numPages || extractedCharacters >= MAX_EXTRACTED_CHARACTERS,
      pageTitle: title,
      url: sourceUrl,
      pageLanguage: navigator.language,
      imageDataUrl: ''
    });
  };
  titlePromise.then((value) => {
    title = value;
    if (generation === loadGeneration && readyMetadata) metadataResolver({ ...readyMetadata, pageTitle: title });
  }).catch(() => {});

  // The first rendered page already has native text. Make it usable before
  // page-frame creation, cache access, or recognition of any scanned pages.
  pdfSearchReady = true;
  publishMetadata('basic', [pageStates[0]?.contextText || '']);
  runPdfSearch({ resetActive: false, reveal: false });

  try {
    while (appendedThrough < documentProxy.numPages) {
      if (generation !== loadGeneration) return;
      const end = Math.min(documentProxy.numPages, appendedThrough + PAGE_PLACEHOLDER_BATCH);
      const states = [];
      for (let pageNumber = appendedThrough + 1; pageNumber <= end; pageNumber += 1) {
        states.push(createPageState(pageNumber, documentProxy.numPages, defaultViewport));
      }
      pageStates.push(...states);
      appendPageStates(states);
      appendedThrough = end;
      setStatus(`Page 1 visible · preparing page frames ${end} of ${documentProxy.numPages}`, {
        state: 'working',
        current: end,
        total: documentProxy.numPages, owner: 'background'
      });
      await nextReaderTurn();
    }

    const cachedIndex = await cachedIndexPromise;
    if (generation !== loadGeneration) return;
    if (cachedIndex) {
      restoredOcr = { ocrNotice: cachedIndex.ocrNotice, ocrPageCount: cachedIndex.ocrPageCount };
      for (let pageIndex = 0; pageIndex < cachedIndex.searchTexts.length; pageIndex += 1) {
        const state = pageStates[pageIndex];
        state.searchText = cachedIndex.searchTexts[pageIndex];
        state.textIndexed = true;
        state.contextIndexed = true;
        state.contextText = cachedIndex.contextPages[pageIndex] ?? null;
      }
      contextPages.push(...cachedIndex.contextPages);
      extractedCharacters = cachedIndex.contextPages.reduce((total, text) => total + text.length, 0);
      pdfBasicIndexReady = true;
      pdfComprehensiveIndexReady = true;
      publishMetadata('complete');
      runPdfSearch({ resetActive: false, reveal: false });
      const indexed = pagesToIndex < documentProxy.numPages
        ? ` · search indexed through page ${pagesToIndex}`
        : '';
      const readyStatus = `${documentProxy.numPages} page${documentProxy.numPages === 1 ? '' : 's'} · index restored from cache${indexed}${cachedIndex.ocrNotice ? ` · ${cachedIndex.ocrNotice}` : ''}`;
      pdfReadyStatus = readyStatus;
      setStatus(readyStatus, { state: 'ready', owner: 'background' });
      updateCurrentPage();
      startPdfSemanticIndex().catch(() => {});
      return;
    }

    // Stage one only reads the PDF text layer. OCR must never hold up native
    // search results on later pages, basic chat context, or reader controls.
    while (nextPageToIndex <= pagesToIndex) {
      await yieldToVisiblePages(generation);
      if (generation !== loadGeneration) return;
      const end = Math.min(pagesToIndex, nextPageToIndex + PAGE_INDEX_CONCURRENCY - 1);
      const includeContext = extractedCharacters < MAX_EXTRACTED_CHARACTERS;
      const batch = [];
      for (let pageNumber = nextPageToIndex; pageNumber <= end; pageNumber += 1) {
        batch.push(indexPdfPage(documentProxy, pageStates[pageNumber - 1], { includeContext }));
      }
      const results = await Promise.all(batch);
      if (generation !== loadGeneration) return;
      for (const result of results) {
        if (result.error) indexErrors += 1;
        let excerpt = null;
        if (extractedCharacters < MAX_EXTRACTED_CHARACTERS) {
          const room = MAX_EXTRACTED_CHARACTERS - extractedCharacters;
          excerpt = result.contextText.slice(0, Math.max(0, room));
          contextPages.push(excerpt);
          extractedCharacters += excerpt.length;
        }
        result.state.contextIndexed = true;
        result.state.contextText = excerpt;
      }
      nextPageToIndex = end + 1;
      pdfBasicIndexReady = end === pagesToIndex;
      if (end === pagesToIndex || nextPageToIndex <= PAGE_INDEX_CONCURRENCY + 1 || end % 12 < PAGE_INDEX_CONCURRENCY) {
        publishMetadata();
        runPdfSearch({ resetActive: false, reveal: false });
        setStatus(`PDF ready · basic text index ${end} of ${pagesToIndex} pages`, {
          state: 'working', current: end, total: pagesToIndex, owner: 'background'
        });
      }
    }

    // Stage two enriches the existing index in place. Keep the basic text even
    // if recognition fails, and preserve the user's current result and page.
    pdfReadyStatus = 'Basic text ready · recognizing scanned text in the background';
    setStatus(pdfReadyStatus, { state: 'working', owner: 'background' });
    for (let pageIndex = 0; pageIndex < contextPages.length; pageIndex += 1) {
      const nativeText = contextPages[pageIndex];
      if (!sparsePdfText(nativeText)) continue;
      await yieldToVisiblePages(generation);
      if (generation !== loadGeneration) return;
      const result = await indexPdfPage(documentProxy, pageStates[pageIndex], {
        includeContext: true, ocrReader, nativeText
      });
      if (generation !== loadGeneration) return;
      if (result.error) indexErrors += 1;
      const room = MAX_EXTRACTED_CHARACTERS - extractedCharacters + nativeText.length;
      const text = result.contextText.slice(0, Math.max(0, room));
      contextPages[pageIndex] = text;
      result.state.contextText = text;
      extractedCharacters += text.length - nativeText.length;
      if (text !== nativeText) {
        publishMetadata();
        runPdfSearch({ resetActive: false, reveal: false });
      }
    }

    if (generation !== loadGeneration) return;
    pdfComprehensiveIndexReady = true;
    publishMetadata('complete');
    runPdfSearch({ resetActive: false, reveal: false });
    const indexed = pagesToIndex < documentProxy.numPages
      ? ` · search indexed through page ${pagesToIndex}`
      : '';
    const ocrSummary = ocrReader?.summary() || {};
    const readyStatus = `${documentProxy.numPages} page${documentProxy.numPages === 1 ? '' : 's'} · context ready${indexed}${ocrSummary.ocrNotice ? ` · ${ocrSummary.ocrNotice}` : ' · selectable text'}${indexErrors ? ` · text unavailable on ${indexErrors} page(s)` : ''}`;
    pdfReadyStatus = readyStatus;
    setStatus(readyStatus, { state: indexErrors ? 'warning' : 'ready', owner: 'background' });
    updateCurrentPage();
    startPdfSemanticIndex().catch(() => {});
    if (indexErrors) return;

    const cacheValue = {
      key: cacheKey,
      pageCount: documentProxy.numPages,
      indexedPageCount: pagesToIndex,
      searchTexts: pageStates.slice(0, pagesToIndex).map((state) => state.searchText),
      contextPages,
      title,
      ...ocrSummary
    };
    nextReaderTurn().then(async () => {
      if (generation !== loadGeneration) return;
      if (!semanticIndexingTask) setStatus(`${readyStatus} · caching search index locally`, { state: 'working', owner: 'background' });
      const cacheSaved = await writePdfIndexCache(cacheValue);
      if (generation !== loadGeneration) return;
      if (!cacheSaved) {
        if (!semanticIndexingTask) setStatus(pdfSemanticIndex?.finalized ? `${readyStatus} · semantic search ready` : readyStatus, { state: 'ready', owner: 'background' });
        return;
      }
      pdfReadyStatus = `${readyStatus} · index cached`;
      if (pdfSemanticIndex?.finalized) setStatus(`${pdfReadyStatus} · semantic search ready`, { state: 'ready', owner: 'background' });
      else if (!semanticIndexingTask) setStatus(pdfReadyStatus, { state: 'ready', owner: 'background' });
    }).catch(() => {});
  } catch (error) {
    if (generation !== loadGeneration) return;
    pdfBasicIndexReady = true;
    pdfComprehensiveIndexReady = true;
    publishMetadata('partial');
    runPdfSearch({ resetActive: false, reveal: false });
    const readyStatus = `PDF ready · background indexing stopped: ${error?.message || error}`;
    pdfReadyStatus = readyStatus;
    setStatus(readyStatus, { state: 'warning', owner: 'background' });
  }
}

async function openPdfInput(input, fallbackTitle = '', documentUrl = '') {
  detailRenderer.invalidate();
  savePdfReadingPosition();
  pdfNavigationSequence += 1;
  restoreReadingPosition = true;
  history.scrollRestoration = 'manual';
  const generation = ++loadGeneration;
  pdfOcrController?.abort();
  pdfOcrController = new AbortController();
  pdfOcrReader = null;
  elements['download-pdf'].disabled = true;
  elements['download-pdf'].removeAttribute('aria-busy');
  document.dispatchEvent(new CustomEvent('scholia:document-instance-changed'));
  await message({ type: 'SCHOLIA_CLEAR_PAGE_SELECTION' }).catch(() => {});
  cancelPdfPrint();
  elements['print-pdf'].disabled = true;
  documentInteractive = false;
  elements['open-chat'].disabled = true;
  elements['send-entire-pdf'].disabled = true;
  indexingTask = null;
  preparePdfSearchForDocument();
  resetPdfOutlineForDocument();
  resetMetadata();
  updatePageCounter(0, 0, { force: true });
  const metadataResolver = resolveMetadata;
  await loadPdfJs();
  await loadingTask?.destroy().catch(() => {});
  await pdf?.destroy().catch(() => {});
  pdf = null;
  pdfLinkService = null;
  optionalContentConfigPromise = null;
  fieldObjectsPromise = Promise.resolve(null);
  const inputOptions = await pdfInputOptions(pdfjs, input, {
    onProgress: updateDownloadProgress,
    fileName: fallbackTitle
  });
  loadingTask = pdfjs.getDocument(pdfOptions(inputOptions, documentUrl));
  showLoading('Parsing the PDF locally…');
  const nextPdf = await loadingTask.promise;
  if (generation !== loadGeneration) { await nextPdf.destroy(); return; }
  pdf = nextPdf;
  pdfOcrReader = createPdfOcrReader({
    signal: pdfOcrController.signal,
    totalPages: pdf.numPages,
    imageOperations: [pdfjs.OPS.paintImageXObject, pdfjs.OPS.paintInlineImageXObject, pdfjs.OPS.paintImageMaskXObject],
    onProgress: ({ page, total }) => {
      if (generation === loadGeneration) setStatus(`Basic text ready · recognizing scanned text ${page} of ${total}`, {
        state: 'working', current: page, total, owner: 'background'
      });
    }
  });
  const downloadName = input?.name || pdfjs.getPdfFilenameFromUrl(documentUrl, '')
    || fallbackTitle || source?.pageTitle || 'document';
  pdfDownloadFilename = /\.pdf$/i.test(downloadName) ? downloadName : `${downloadName}.pdf`;
  const savedPage = savedPdfPageNumber(pdf);
  pdfLinkService = new ScholiaPdfLinkService(pdf, documentUrl);
  optionalContentConfigPromise = pdf.getOptionalContentConfig({ intent: 'display' });
  fieldObjectsPromise = pdf.getFieldObjects().catch(() => null);
  elements.pages.replaceChildren();
  pageStates = [];
  renderedPageStates = new Set();
  spreadRows = [];
  currentPageState = null;
  initializeObservers();

  const fallback = fallbackTitle || source?.pageTitle || 'PDF document';
  updateDocumentTitle(fallback);
  updatePageCounter(1, pdf.numPages, { force: true });
  showLoading(`Preparing page 1 of ${pdf.numPages}…`);

  const firstPage = await pdf.getPage(1);
  if (generation !== loadGeneration) return;
  const defaultViewport = firstPage.getViewport({ scale: BASE_SCALE });
  const firstState = createPageState(1, pdf.numPages, defaultViewport, firstPage);
  pageStates.push(firstState);
  setCurrentPdfPageState(firstState);
  appendPageStates([firstState]);
  if (pdfZoomMode !== 'custom') applyPdfZoomMode(firstState);
  else if (pdfPageLayout === 'spread') fitPdfSpread();
  documentInteractive = true;
  elements['download-pdf'].disabled = false;
  elements['print-pdf'].disabled = false;
  elements['open-chat'].disabled = false;
  elements['send-entire-pdf'].disabled = false;
  elements.loading.hidden = true;
  setStatus(`Rendering page 1 of ${pdf.numPages}…`, {
    state: 'working',
    current: 0,
    total: 1
  });
  await renderPage(firstState);
  if (generation !== loadGeneration) return;
  if (firstState.renderError) {
    setStatus('The PDF is open, but page 1 needs a rendering retry', { state: 'warning' });
  } else {
    setStatus(`Page 1 visible · preparing ${pdf.numPages} page${pdf.numPages === 1 ? '' : 's'} in the background`, {
      state: 'working',
      current: 1,
      total: pdf.numPages
    });
  }

  pdfOutlineTask = preparePdfOutline(pdf, generation);
  pdfOutlineTask.catch(() => {});

  const titlePromise = documentTitle(pdf).then((metadataTitle) => {
    const title = metadataTitle || fallback;
    if (generation === loadGeneration) updateDocumentTitle(title);
    return title;
  });
  updateCurrentPage();
  indexingTask = preparePdfPages({
    generation,
    documentProxy: pdf,
    defaultViewport,
    titlePromise,
    metadataResolver,
    sourceUrl: source?.url || ''
  });
  indexingTask.catch(() => {});
  const initialFragment = pdfSourceFragment(documentUrl);
  try {
    if (savedPage) {
      await navigateToPdfDestination(savedPage);
    } else if (initialFragment) {
      await pdfLinkService.setHash(initialFragment);
    } else {
      const nativePage = nativePdfPageFromProgress(source?.nativeViewportProgress, pdf.numPages);
      if (nativePage > 1) await pdfLinkService.setHash(`page=${nativePage}`);
    }
  } finally {
    if (generation === loadGeneration) {
      restoreReadingPosition = false;
      savePdfReadingPosition();
    }
  }
}

async function chooseFile(file) {
  if (!file) return;
  assertPdfSize(file.size);
  resetLocalFileRestoreAction();
  source = null;
  document.documentElement.dataset.scholiaSourceUrl = '';
  showSourceUrl('');
  elements['open-native'].hidden = true;
  showLoading(`Opening ${file.name} locally…`);
  await openPdfInput(file, file.name.replace(/\.pdf$/i, ''));
}

async function localFilePermission(handle, { request = false } = {}) {
  if (typeof handle?.queryPermission !== 'function') return true;
  try {
    let permission = await handle.queryPermission({ mode: 'read' });
    if (permission !== 'granted' && request && typeof handle.requestPermission === 'function') {
      permission = await handle.requestPermission({ mode: 'read' });
    }
    return permission === 'granted';
  } catch {
    return false;
  }
}

async function openLocalPdfFileRecord(record, { requestPermission = false, file = null } = {}) {
  if (!record) throw new Error('Scholia no longer has access to this local PDF file. Choose it again.');
  if (!file && !await localFilePermission(record.handle, { request: requestPermission })) {
    showLocalFilePermission(record);
    return false;
  }

  let selectedFile = file;
  try {
    selectedFile ||= await record.handle.getFile();
  } catch (error) {
    if (error?.name === 'NotAllowedError' || error?.name === 'SecurityError') {
      showLocalFilePermission(record);
      return false;
    }
    throw error;
  }
  assertPdfSize(selectedFile.size);
  resetLocalFileRestoreAction();
  source = localPdfFileSource({ ...record, name: selectedFile.name || record.name });
  document.documentElement.dataset.scholiaSourceUrl = source.url;
  elements['document-title'].textContent = source.pageTitle;
  showSourceUrl('');
  elements['open-native'].hidden = true;
  showLoading(`Opening ${selectedFile.name} from this computer…`);
  await openPdfInput(selectedFile, selectedFile.name.replace(/\.pdf$/i, ''));
  return true;
}

async function chooseLocalPdfFile() {
  if (typeof globalThis.showOpenFilePicker !== 'function') {
    elements['pdf-file'].click();
    return;
  }

  let handle;
  try {
    [handle] = await globalThis.showOpenFilePicker({
      id: 'scholia-open-pdf',
      multiple: false,
      types: [{
        description: 'PDF documents',
        accept: { 'application/pdf': ['.pdf'] }
      }]
    });
  } catch (error) {
    if (error?.name === 'AbortError') return;
    elements['pdf-file'].click();
    return;
  }
  if (!handle) return;

  const file = await handle.getFile();
  assertPdfSize(file.size);
  let record;
  try {
    record = await storeLocalPdfFileHandle(handle, { file });
  } catch (error) {
    await chooseFile(file);
    setStatus(`The PDF is open, but this tab cannot restore it automatically: ${error?.message || error}`, { state: 'warning' });
    return;
  }

  const viewerUrl = chrome.runtime.getURL(`pdf-viewer.html?source=${encodeURIComponent(record.id)}`);
  if (activeMimeStreamInfo) {
    await navigateReader(viewerUrl);
    return;
  }
  history.replaceState(null, '', viewerUrl);
  await openLocalPdfFileRecord(record, { file });
}

function manualOpenRequested() {
  try {
    const current = new URL(location.href);
    const viewer = new URL(chrome.runtime.getURL('pdf-viewer.html'));
    return current.origin === viewer.origin
      && current.pathname === viewer.pathname
      && current.searchParams.get('open') === '1';
  } catch {
    return false;
  }
}

async function navigateReader(url) {
  if (activeMimeStreamInfo) {
    // Navigating just the handler iframe would leave the old PDF's address in
    // the address bar. An embedded reader must also preserve its containing site.
    if (activeMimeStreamInfo.embedded) await chrome.tabs.create({ url });
    else await chrome.tabs.update(activeMimeStreamInfo.tabId, { url });
  } else location.replace(url);
}

async function openPdfAddress() {
  const url = elements['pdf-address'].value.trim();
  if (!url) {
    elements['pdf-address'].focus();
    throw new Error('Paste a PDF address first.');
  }
  elements['open-address'].disabled = true;
  showLoading('Preparing the PDF address…');
  try {
    const prepared = await message({ type: 'SCHOLIA_CREATE_PDF_VIEWER_SOURCE', url });
    const mimeTarget = pdfMimeNavigationTarget(prepared.pdfUrl);
    await navigateReader(mimeTarget && await automaticPdfMimeHandlingEnabled()
      ? mimeTarget
      : prepared.viewerUrl);
  } catch (error) {
    showError(error);
    elements['pdf-address'].focus();
    throw error;
  } finally {
    elements['open-address'].disabled = false;
  }
}

async function openMimeHandledPdf(streamInfo) {
  activeMimeStreamInfo = streamInfo;
  source = pdfMimeSource(streamInfo);
  if (!source) throw new Error('Chromium returned an invalid PDF stream.');
  await message({ type: 'SCHOLIA_REGISTER_MIME_PDF_HANDLER' }).catch(() => {});
  document.documentElement.dataset.scholiaSourceUrl = source.url;
  elements['document-title'].textContent = source.pageTitle;
  showSourceUrl(source.url);
  elements['open-native'].hidden = false;
  elements['choose-file'].textContent = 'Open another PDF';
  elements['choose-file'].title = 'Open a PDF file or address in a new tab';
  showLoading(`Opening ${source.pageTitle} from its original address…`);
  const response = await fetch(streamInfo.streamUrl);
  const blob = await readPdfBlobResponse(response, updateDownloadProgress);
  await openPdfInput(blob, source.pageTitle, streamInfo.originalUrl);
}

async function fallBackToNativeMimeHandler() {
  if (!activeMimeStreamInfo || typeof chrome.mimeHandler?.abortAndFallbackToNativeHandler !== 'function') return false;
  await message({ type: 'SCHOLIA_PREPARE_NATIVE_PDF_FALLBACK' }).catch(() => {});
  await chrome.mimeHandler.abortAndFallbackToNativeHandler();
  return true;
}

async function boot() {
  try {
    const preferences = Promise.allSettled([
      restoreTheme(),
      restorePdfPageLayout(),
      restorePdfZoomMode(),
      restorePdfSearchMode(),
      restorePdfLearningMode()
    ]);
    const mimeStream = await activePdfMimeStreamInfo();
    await preferences;
    installScholia().catch((error) => setStatus(error.message, { state: 'warning' }));
    if (mimeStream) {
      await openMimeHandledPdf(mimeStream);
      return;
    }
    const id = sourceId();
    if (!id) {
      if (manualOpenRequested()) showManualOpen();
      else showError(new Error('This Scholia PDF link is incomplete. Paste the PDF address again or choose the file.'));
      return;
    }
    source = await message({ type: 'SCHOLIA_GET_PDF_VIEWER_SOURCE', sourceId: id });
    document.documentElement.dataset.scholiaSourceUrl = source.url || '';
    elements['document-title'].textContent = source.pageTitle || 'PDF document';
    if (source.fileHandleId) {
      showSourceUrl('');
      elements['open-native'].hidden = true;
      const localFile = await loadLocalPdfFileRecord(source.fileHandleId);
      await openLocalPdfFileRecord(localFile);
      return;
    }
    const mimeTarget = pdfMimeNavigationTarget(source.pdfUrl);
    if (mimeTarget && await automaticPdfMimeHandlingEnabled()) {
      location.replace(mimeTarget);
      return;
    }
    showSourceUrl(source.url);
    elements['open-native'].hidden = !source.pdfUrl;
    const pdfDocument = await fetchPdfDocument(source.pdfUrl, { onProgress: updateDownloadProgress });
    await openPdfInput(pdfDocument.blob, source.pageTitle, pdfDocument.url);
  } catch (error) {
    if (activeMimeStreamInfo) {
      try {
        if (await fallBackToNativeMimeHandler()) return;
      } catch {}
    }
    showError(error);
  }
}

elements['zoom-out'].addEventListener('click', () => updateZoom(zoom - ZOOM_STEP, { persist: true }));
elements['zoom-in'].addEventListener('click', () => updateZoom(zoom + ZOOM_STEP, { persist: true }));
elements['zoom-label'].addEventListener('change', selectPdfZoomMode);
elements['page-count'].addEventListener('submit', (event) => {
  event.preventDefault();
  commitPageNumber();
  elements['page-number'].select();
});
elements['page-number'].addEventListener('change', commitPageNumber);
elements['page-number'].addEventListener('focus', () => elements['page-number'].select());
elements['page-number'].addEventListener('keydown', (event) => {
  if (event.key !== 'Escape') return;
  event.preventDefault();
  event.stopPropagation();
  updatePageCounter(currentPageState?.pageNumber || 1, undefined, { force: true });
  elements['page-number'].select();
});
elements['theme-toggle'].addEventListener('click', toggleTheme);
elements['view-toggle'].addEventListener('click', () => {
  setPdfViewMenuOpen(elements['pdf-view-menu'].hidden);
});
elements['pdf-view-menu'].addEventListener('click', (event) => {
  const option = event.target.closest('button');
  if (!option) return;
  if (option.dataset.pdfLayout) {
    setPdfPageLayout(option.dataset.pdfLayout, {
      fit: option.dataset.pdfLayout === 'spread',
      persist: true
    });
  } else if (option.dataset.pdfZoom) {
    pdfZoomMode = option.dataset.pdfZoom;
    spreadAutoZoom = null;
    zoomBeforeSpread = null;
    chrome.storage.local.set({ [PDF_ZOOM_MODE_KEY]: pdfZoomMode }).catch(() => {});
    applyPdfZoomMode();
  }
  setPdfViewMenuOpen(false, { restoreFocus: true });
});
elements['pdf-view-menu'].addEventListener('keydown', (event) => {
  const options = [...elements['pdf-view-menu'].querySelectorAll('button')];
  const index = options.indexOf(document.activeElement);
  let nextIndex = null;
  if (event.key === 'ArrowDown') nextIndex = (Math.max(index, -1) + 1) % options.length;
  else if (event.key === 'ArrowUp') nextIndex = (index <= 0 ? options.length : index) - 1;
  else if (event.key === 'Home') nextIndex = 0;
  else if (event.key === 'End') nextIndex = options.length - 1;
  else if (event.key === 'Escape') {
    event.preventDefault();
    event.stopPropagation();
    setPdfViewMenuOpen(false, { restoreFocus: true });
    return;
  }
  if (nextIndex === null) return;
  event.preventDefault();
  event.stopPropagation();
  options[nextIndex]?.focus();
});
elements['outline-toggle'].addEventListener('click', () => {
  setPdfOutlineOpen(elements['pdf-outline'].hidden);
});
elements['outline-close'].addEventListener('click', () => {
  setPdfOutlineOpen(false, { restoreFocus: true });
});
elements['search-toggle'].addEventListener('click', () => {
  if (elements['pdf-search'].hidden) openPdfSearch();
  else closePdfSearch();
});
elements['search-mode'].addEventListener('change', () => {
  clearPdfSearchResults();
  updatePdfSearchModeUi();
  chrome.storage.local.set({
    [PDF_SEARCH_MODE_KEY]: semanticPdfSearchActive() ? 'semantic' : 'exact'
  }).catch(() => {});
  if (elements['search-input'].value.trim()) runPdfSearch({ resetActive: true, reveal: false });
  elements['search-input'].focus();
});
elements['search-input'].addEventListener('input', schedulePdfSearch);
elements['search-input'].addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    event.preventDefault();
    closePdfSearch();
  } else if (event.key === 'Enter' && !event.isComposing) {
    event.preventDefault();
    movePdfSearch(event.shiftKey ? -1 : 1);
  }
});
elements['search-previous'].addEventListener('click', () => movePdfSearch(-1));
elements['search-next'].addEventListener('click', () => movePdfSearch(1));
elements['search-close'].addEventListener('click', () => closePdfSearch());
elements['open-chat'].addEventListener('click', openPdfChat);
elements['send-entire-pdf'].addEventListener('click', sendEntirePDF);
document.addEventListener('scholia:open-pdf-chat', (event) => {
  const chatId = normalizedChatId(event.detail?.chatId);
  if (chatId) setPdfChatOpen(true, { chatId });
});
document.addEventListener('scholia:document-instance-changed', () => {
  pdfChatController?.then((controller) => controller.resetSource()).catch((error) => {
    setStatus(error.message, { state: 'warning' });
  });
});
elements['learning-toggle'].addEventListener('click', () => {
  togglePdfLearningMode().catch((error) => setStatus(error.message, { state: 'warning' }));
});
elements['pdf-chat-close'].addEventListener('click', () => {
  setPdfChatOpen(false, { restoreFocus: true });
});
const openNativePdf = () => {
  if (activeMimeStreamInfo) {
    fallBackToNativeMimeHandler().catch((error) => {
      setStatus(error.message, { state: 'warning' });
    });
    return;
  }
  message({ type: 'SCHOLIA_OPEN_NATIVE_PDF' }).catch((error) => {
    setStatus(error.message, { state: 'warning' });
  });
};
elements['open-native'].addEventListener('click', openNativePdf);
elements['download-pdf'].addEventListener('click', downloadPdf);
elements['print-pdf'].addEventListener('click', printPdf);
elements['source-url'].addEventListener('click', openNativePdf);
elements['copy-source-url'].addEventListener('click', copySourceUrl);
elements['error-open-original'].addEventListener('click', openNativePdf);
const openFileChooser = () => {
  // File System Access pickers cannot run inside a cross-origin MIME frame.
  // Start the file/address chooser in its own tab, with the correct address.
  if (activeMimeStreamInfo) {
    chrome.tabs.create({ url: chrome.runtime.getURL('pdf-viewer.html?open=1') }).catch(showError);
    return;
  }
  if (pendingLocalFileRecord) {
    const record = pendingLocalFileRecord;
    showLoading(`Reopening ${record.name} from this computer…`);
    openLocalPdfFileRecord(record, { requestPermission: true }).catch(showError);
    return;
  }
  chooseLocalPdfFile().catch(showError);
};
elements['choose-file'].addEventListener('click', openFileChooser);
elements['error-choose-file'].addEventListener('click', openFileChooser);
elements['manual-pdf-form'].addEventListener('submit', (event) => {
  event.preventDefault();
  openPdfAddress().catch(() => {});
});
elements['pdf-file'].addEventListener('change', () => {
  const [file] = elements['pdf-file'].files || [];
  chooseFile(file).catch(showError).finally(() => { elements['pdf-file'].value = ''; });
});
window.addEventListener('scroll', scheduleCurrentPage, { passive: true });
document.addEventListener('visibilitychange', () => {
  if (document.hidden || !documentInteractive) return;
  for (const state of visiblePageStates) renderPage(state);
  if (currentPageState) renderPage(currentPageState);
});
window.addEventListener('blur', () => setPdfViewMenuOpen(false));
document.addEventListener('pointerdown', (event) => {
  if (!elements['pdf-view-menu'].hidden && !elements['pdf-view-control'].contains(event.target)) {
    setPdfViewMenuOpen(false);
  }
});
window.addEventListener('resize', () => {
  scheduleCurrentPage();
  clearTimeout(spreadResizeTimer);
  if (pdfZoomMode !== 'custom') spreadResizeTimer = setTimeout(applyPdfZoomMode, 120);
  else if (pdfPageLayout === 'spread') spreadResizeTimer = setTimeout(fitPdfSpread, 120);
}, { passive: true });
document.addEventListener('keydown', (event) => {
  if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === 'p') {
    event.preventDefault();
    event.stopImmediatePropagation();
    printPdf();
    return;
  }
  if (handleReaderKeyboard(event)) return;
  if ((event.metaKey || event.ctrlKey) && !event.altKey && event.key.toLowerCase() === 'f') {
    event.preventDefault();
    openPdfSearch();
  } else if (event.key === 'Escape' && !elements['pdf-chat'].hidden) {
    event.preventDefault();
    setPdfChatOpen(false, { restoreFocus: true });
  } else if (event.key === 'Escape' && !elements['pdf-view-menu'].hidden) {
    event.preventDefault();
    setPdfViewMenuOpen(false, { restoreFocus: true });
  } else if (event.key === 'Escape' && !elements['pdf-search'].hidden) {
    event.preventDefault();
    closePdfSearch();
  } else if (event.key === 'Escape' && !elements['pdf-outline'].hidden) {
    event.preventDefault();
    setPdfOutlineOpen(false, { restoreFocus: true });
  }
});
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes[PDF_LEARNING_MODE_KEY]) {
    renderPdfLearningMode(changes[PDF_LEARNING_MODE_KEY].newValue);
  }
});

observeToolbarHeight();
boot().catch(showError);
