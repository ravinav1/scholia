import { copyCodeBlock, copyText } from './clipboard.js';
import { mountResponseLanguage, renderResponseLanguage } from './response-language.js';
import { ENTIRE_PDF_QUESTION } from '../../../packages/core/src/entire-pdf.js';
import { canvasCourseFromUrl } from './canvas-course.js';
import { getCanvasCourseContext, loadCanvasCourseIndex } from './canvas-index.js';
import { getBrowserResearchContext } from './browser-research.js';
import { researchUrl } from './research-links.js';
import { mountFileComposer, appendFileChips } from './file-composer.js';
import {
  COMPACT_PACKED_CONTEXT_CHARS,
  packPageContext
} from '../../../packages/core/src/context.js';
import {
  CONTEXT_MODE_COMPACT,
  CONTEXT_MODE_FULL,
  CONTEXT_MODE_NONE,
  contextCharacterLimit,
  defaultContextMode
} from './context-mode.js';
import {
  SETTINGS_KEY,
  providerById,
  providerSupportsFastMode,
  providerSupportsWebSearch
} from '../../../packages/core/src/providers.js';
import { CHAT_HISTORY_KEY, clearChats, deleteChat, getChat, listChats, saveChat } from './chat/chat-history.js';
import {
  canExplainImageDirectly,
  createUserTurn,
  DEFAULT_IMAGE_EXPLANATION,
  normalizeSelectionAttachment,
  requestConversation
} from './chat/chat-turn.js';
import { assertPdfSize, extractPdfContext, fetchPdfBlob } from './pdf/pdf-context.js';
import { clipboardImageFile, normalizeImageFile } from './image-input.js';
import { currentSelectionCapture } from './page-capture.js';
import { renderMarkdown, renderReasoning, renderActivity, addActivity, bindActivityDisclosure } from './render.js';
import { buildResponseLayerContext } from './chat/response-layers.js';
import { prepareEditedResend, replaceConversationPrefix } from './chat/chat-edit.js';
import {
  MAX_CHAT_SEARCH_RESULTS,
  matchingMessageIndexes,
  movedSearchIndex,
  searchRanges
} from './chat/chat-search.js';
import { dedicatedChatId, dedicatedChatUrl } from './chat/chat-page.js';
import { sendRuntimeMessage as sendPanelMessage } from './runtime-message.js';
import { parseModelChoice, populateModelSelect } from './model-select.js';
import { populateReasoningSelect } from './reasoning-select.js';
import { RECENT_MODELS_KEY } from '../../../packages/core/src/recent-models.js';
import {
  pageSelectionStorageKey,
  PANEL_NAVIGATION_KEY,
  PANEL_REQUEST_KEY
} from './tab-context.js';
import { fullPageCanvasSize } from './deep-page.js';
import { DEFAULT_MAIL_REPLY_QUESTION } from './mail-context.js';
import { documentLanguageLabel } from './document-language.js';
import { isQuickChatShortcut } from './ui-primitives.js';
import { responseSelectionInteractionProtected } from './ui-primitives.js';
import { bridgeLaunchDecision } from './bridge-launch.js';

// Each reader owns an independent controller; standalone panels use the same UI.
export function mountChatPanel({ root = globalThis.document, embeddedPdf = false, initialChatId = '', close = () => {} } = {}) {
const ownerDocument = root.ownerDocument || root;
const document = root === ownerDocument ? ownerDocument : {
  body: root.querySelector('.panel-document'),
  documentElement: root.host,
  get activeElement() { return root.activeElement; },
  getElementById: (id) => root.getElementById(id),
  createElement: (...args) => ownerDocument.createElement(...args),
  createTextNode: (...args) => ownerDocument.createTextNode(...args),
  createTreeWalker: (...args) => ownerDocument.createTreeWalker(...args),
  createDocumentFragment: () => ownerDocument.createDocumentFragment(),
  addEventListener: (type, listener, options) => (type === 'selectionchange' ? ownerDocument : root)
    .addEventListener(type, listener, options)
};
const panelSelection = () => root.getSelection?.() || window.getSelection();
const panelWindow = chrome.windows?.getCurrent ? chrome.windows.getCurrent().then((value) => value.id).catch(() => null) : Promise.resolve(null);
const message = async (payload) => sendPanelMessage({ ...payload, windowId: await panelWindow, ...(embeddedPdf ? { pdfReaderPanel: true } : {}) });
const dedicatedChatPage = !embeddedPdf && (document.documentElement.hasAttribute('data-scholia-dedicated-chat')
  || document.body.classList.contains('dedicated-chat'));
const embeddedPdfPanel = embeddedPdf || new URLSearchParams(location.search).get('surface') === 'pdf-overlay';
const PDF_LEARNING_MODE_KEY = 'scholia.pdf-learning-mode.v1';
const elements = Object.fromEntries([
  'bridge-bar', 'bridge-status', 'bridge-start', 'bridge-copy',
  'reasoning-select', 'chat-reasoning-select', 'context-mode-summary', 'chat-options-summary', 'composer-settings-status',
  'home-brand', 'back-home', 'expand-chat', 'chat-search-toggle', 'new-chat', 'settings', 'model-settings', 'model-select',
  'fast-mode', 'fast-mode-state', 'web-search', 'web-search-state', 'learning-mode', 'learning-mode-state', 'model-hint',
  'context-mode', 'context-full', 'context-none', 'chat-context-mode', 'chat-context-full', 'chat-context-none', 'chat-model-select', 'chat-fast-mode', 'chat-web-search', 'chat-learning-mode',
  'clear-chats', 'chat-history-list',
  'chat-history-empty', 'home-view', 'chat-view', 'source-badge',
  'current-title', 'current-url', 'context-form', 'context-question', 'context-hint', 'site-scope-row', 'site-scope',
  'deep-page-row', 'deep-page',
  'chat-follow-links', 'chat-research-yolo', 'research-review', 'research-review-question', 'research-review-sites',
  'research-approve', 'research-skip', 'research-review-yolo', 'research-sources', 'research-source-list',
  'pdf-viewer-actions', 'open-pdf-viewer', 'pdf-viewer-state',
  'course-index', 'course-index-status', 'course-index-refresh', 'course-index-clear', 'chat-course-refresh', 'capture', 'paste-card', 'paste-selection', 'paste-question', 'paste-cancel',
  'paste-start', 'choose-image', 'site', 'site-toggle', 'explain', 'status', 'tab-changed',
  'chat-current-tab', 'chat-source-badge', 'context-state', 'chat-source-title',
  'chat-source-detail', 'chat-selection', 'chat-source-image', 'loading-card',
  'loading-title', 'loading-detail', 'pdf-fallback', 'pdf-fallback-message',
  'choose-pdf', 'use-visible', 'messages', 'composer-form',
  'chat-search', 'chat-search-input', 'chat-search-count', 'chat-search-previous',
  'chat-search-next', 'chat-search-close',
  'composer-selection', 'composer-selection-label', 'composer-selection-text', 'composer-selection-clear',
  'composer-image', 'composer-image-preview', 'composer-image-label', 'composer-image-clear',
  'attach-files', 'composer-files', 'response-window-files', 'response-window-attach', 'choose-files', 'attach-region', 'composer', 'explain-capture', 'send', 'pdf-file', 'image-file',
  'response-explain', 'response-explain-preview', 'response-explain-question',
  'response-explain-send', 'response-explain-cancel', 'response-explain-chatgpt',
  'response-explain-chatgpt-toggle', 'response-explain-web-search', 'response-explain-web-search-toggle',
  'response-window-backdrop', 'response-window-close', 'response-window-move', 'response-window-status', 'response-window-depth', 'response-window-source',
  'response-window-web-search', 'response-window-messages', 'response-window-form', 'response-window-composer', 'response-window-send'
].map((id) => [id, document.getElementById(id)]));

let settings = null;
let modelSaving = false;
let modelSave = Promise.resolve();
let webSearchEnabled = false;
let learningModeEnabled = false;
let contextEnabled = true;
let compactContextEnabled = true;
let contextPreferenceInitialized = false;
let activeSource = null;
let sourceRefreshId = 0;
let activeSite = null;
let capture = null;
let courseController = null;
let courseRetrieving = false;
let researchReview = null;
let messages = [];
let streaming = false;
let requestId = '';
let port = null;
let renderFrame = null;
let operationController = null;
let pendingPdf = null;
let pendingPasteSource = null;
let captureSession = null;
let tabRefreshTimer = null;
let imageQuestionDraft = '';
let composerSelection = null;
let composerImage = null;
let pendingResponseSelection = null;
let responseSelectionTimer = null;
let responseExplainPointerInteraction = false;
let editingMessageIndex = -1;
let chatSearchResultIndexes = [];
let activeChatSearchIndex = -1;
let lastSyncedSelectionId = '';
let selectionPreparationId = 0;
const responseWindows = [];
let lastRenderedMessageCount = 0;
let currentChatId = '';
let chatCreatedAt = 0;
let currentChatUpdatedAt = 0;
const chatRevisions = new Map();
let historyWrite = Promise.resolve();
const handledPanelRequests = new Set();
const handledNavigationRequests = new Set();
const pdfCache = new Map();
let bridgeStatus = null;
let bridgeWatchTimer = null;
let bridgeStatusRequest = 0;
let bridgeLaunchState = null;
let bridgeLaunchPendingUntil = 0;

function paintBridgeStatus() {
  const provider = providerById(settings?.provider);
  elements['bridge-bar'].hidden = !provider.localBridge;
  if (!provider.localBridge) return;
  const status = bridgeStatus;
  const starting = bridgeLaunchPendingUntil > Date.now();
  elements['bridge-status'].textContent = status?.up
    ? `${provider.localBridge.label} connected`
    : starting ? `Starting ${provider.localBridge.label}…`
      : status?.up === false ? `${provider.localBridge.label} offline — start it to continue this chat.`
        : `Checking ${provider.localBridge.label}…`;
  elements['bridge-start'].textContent = status?.up ? 'Check again' : starting ? 'Starting…' : 'Start bridge';
  elements['bridge-start'].disabled = starting || !status?.startUrl;
  elements['bridge-copy'].hidden = status?.up || !status?.command;
}

async function refreshBridgeStatus() {
  clearTimeout(bridgeWatchTimer);
  const request = ++bridgeStatusRequest;
  const provider = providerById(settings?.provider);
  if (bridgeStatus?.provider !== provider.id) {
    bridgeStatus = null;
    bridgeLaunchPendingUntil = 0;
  }
  paintBridgeStatus();
  if (!provider.localBridge) return;
  try {
    const status = await message({ type: 'SCHOLIA_BRIDGE_STATUS', provider: provider.id, timeoutMs: 1000 });
    if (request !== bridgeStatusRequest) return;
    bridgeStatus = status;
    if (status.up) bridgeLaunchPendingUntil = 0;
  } catch (error) {
    if (request !== bridgeStatusRequest) return;
    bridgeStatus = { ...bridgeStatus, provider: provider.id, up: false, error: error.message };
  }
  paintBridgeStatus();
  bridgeWatchTimer = setTimeout(refreshBridgeStatus, bridgeStatus.up ? 10_000 : 1_500);
}

function startBridge() {
  if (bridgeStatus?.up || !bridgeStatus?.startUrl) {
    refreshBridgeStatus();
    return;
  }
  const decision = bridgeLaunchDecision(bridgeLaunchState, bridgeStatus.startUrl);
  bridgeLaunchState = decision.state;
  if (decision.allowed) {
    const frame = document.createElement('iframe');
    frame.hidden = true;
    frame.src = bridgeStatus.startUrl;
    document.body.append(frame);
    setTimeout(() => frame.remove(), 1_500);
  }
  bridgeLaunchPendingUntil = Date.now() + (decision.retryAfterMs || 30_000);
  refreshBridgeStatus();
}

function showStatus(text, error = false) {
  elements.status.textContent = text;
  elements.status.classList.toggle('error', error);
}

function shortSourceUrl(value) {
  if (!value) return '';
  if (value === 'file://') return 'Local file';
  try {
    const url = new URL(value);
    return `${url.hostname}${url.pathname}`;
  } catch {
    return value;
  }
}

function countLabel(value) {
  const count = Number(value) || 0;
  return count >= 1_000_000
    ? `${(count / 1_000_000).toFixed(1)}m`
    : count >= 1_000 ? `${Math.round(count / 1_000)}k` : String(count);
}

function sourceTitle(source) {
  return source?.pageTitle || (source?.sourceKind === 'pdf' ? 'PDF document' : 'Current page');
}

function isPdfSource(source) {
  return source?.sourceKind === 'pdf' || Boolean(source?.pdfUrl);
}

function learningModeAvailable() {
  return isPdfSource(capture) || isPdfSource(activeSource);
}

function renderLearningModeControls() {
  const available = learningModeAvailable();
  const active = available && learningModeEnabled;
  elements['learning-mode'].hidden = !available;
  elements['chat-learning-mode'].hidden = !available;
  elements['learning-mode'].setAttribute('aria-pressed', String(active));
  elements['chat-learning-mode'].setAttribute('aria-pressed', String(active));
  elements['learning-mode-state'].textContent = active ? 'On' : 'Off';
  elements['chat-learning-mode'].textContent = active ? '◇ Learning on' : '◇ Learn';
  renderChatOptionsSummary();
}

function toggleLearningMode() {
  if (!learningModeAvailable() || streaming) return;
  learningModeEnabled = !learningModeEnabled;
  renderLearningModeControls();
  chrome.storage.local.set({ [PDF_LEARNING_MODE_KEY]: learningModeEnabled }).catch(() => {});
  showStatus(learningModeEnabled
    ? 'Guided learning is on: Scholia will use questions and small hints instead of completed answers.'
    : 'Guided learning is off.');
}

async function restoreLearningMode() {
  const stored = await chrome.storage.local.get(PDF_LEARNING_MODE_KEY);
  learningModeEnabled = stored[PDF_LEARNING_MODE_KEY] === true;
  renderLearningModeControls();
}

function supportsSiteContext(source) {
  if (!source || isPdfSource(source)) return false;
  try { return ['http:', 'https:'].includes(new URL(source.url).protocol); } catch { return false; }
}

function renderContextHint() {
  if (!contextEnabled) {
    elements['context-hint'].textContent = 'No context mode sends only your question, conversation, and text or images you explicitly attach.';
    return;
  }
  const modeLabel = compactContextEnabled ? 'Compact mode' : 'Full mode';
  const pdf = isPdfSource(activeSource);
  elements['context-hint'].textContent = elements['site-scope'].checked
    ? `${modeLabel} searches Canvas and follows relevant links across approved sites. You review new sites; Stop cancels research.`
    : elements['deep-page'].checked
      ? `${modeLabel} loads the complete live page and ${compactContextEnabled ? 'ranks relevant text' : 'uses the larger full-context budget'} plus a full-page visual when supported.`
    : pdf
      ? compactContextEnabled
        ? 'The PDF is read locally, ranked for this question, and compressed to about 6,000 source characters.'
        : 'Full mode includes the entire extracted text of articles and short PDFs, up to about 120,000 characters. Larger PDFs use relevant excerpts.'
      : compactContextEnabled
        ? 'Compact mode reads this page and sends about 6,000 question-relevant source characters.'
        : 'Full mode includes entire articles and pages, up to about 120,000 characters. Larger pages use relevant excerpts.';
}

async function refreshSettings() {
  settings = await message({ type: 'SCHOLIA_GET_PUBLIC_SETTINGS' });
  renderResponseLanguage(settings, root);
  if (!contextPreferenceInitialized) {
    compactContextEnabled = defaultContextMode(settings) === CONTEXT_MODE_COMPACT;
    contextEnabled = true;
    contextPreferenceInitialized = true;
  }
  renderModelControls();
  renderContextControls();
}

function renderContextControls() {
  const mode = currentContextMode();
  const label = mode === CONTEXT_MODE_NONE ? 'No page context' : mode === CONTEXT_MODE_FULL ? 'Full context' : 'Compact context';
  elements['context-mode-summary'].textContent = label;
  const enabled = mode !== CONTEXT_MODE_NONE;
  elements['context-mode'].checked = mode === CONTEXT_MODE_COMPACT;
  elements['context-full'].checked = mode === CONTEXT_MODE_FULL;
  elements['context-none'].checked = mode === CONTEXT_MODE_NONE;
  elements['chat-context-mode'].setAttribute('aria-pressed', String(mode === CONTEXT_MODE_COMPACT));
  elements['chat-context-full'].setAttribute('aria-pressed', String(mode === CONTEXT_MODE_FULL));
  elements['chat-context-none'].setAttribute('aria-pressed', String(mode === CONTEXT_MODE_NONE));
  const sourceSupportsScopes = supportsSiteContext(activeSource);
  elements['site-scope'].disabled = !enabled || !sourceSupportsScopes;
  elements['deep-page'].disabled = !enabled || !sourceSupportsScopes;
  if (!enabled) {
    elements['site-scope'].checked = false;
    elements['deep-page'].checked = false;
  }
  renderContextHint();
  renderResearchControls();
}

function renderResearchControls() {
  const available = contextEnabled && supportsSiteContext(capture);
  const following = Boolean(capture?.followLinks);
  elements['chat-follow-links'].disabled = !available || streaming || courseRetrieving;
  elements['chat-follow-links'].setAttribute('aria-pressed', String(available && following));
  elements['chat-research-yolo'].hidden = !following;
  elements['chat-research-yolo'].disabled = !available || streaming || courseRetrieving;
  elements['chat-research-yolo'].setAttribute('aria-pressed', String(Boolean(capture?.researchYolo)));
  renderChatOptionsSummary();
}

function renderChatOptionsSummary() {
  const mode = currentContextMode();
  const summary = [
    mode === CONTEXT_MODE_NONE ? 'No page context' : mode === CONTEXT_MODE_FULL ? 'Full context' : 'Compact context',
    settings?.fastMode && providerSupportsFastMode(settings?.provider) ? 'Fast' : '',
    webSearchEnabled ? 'Web' : '',
    contextEnabled && capture?.followLinks ? 'Follow links' : '',
    learningModeAvailable() && learningModeEnabled ? 'Guided' : '',
    settings?.language === 'en' ? 'English' : settings?.language === 'no' ? 'Norsk' : ''
  ].filter(Boolean).join(' · ');
  elements['chat-options-summary'].textContent = summary;
  elements['chat-options-summary'].title = summary;
}

function reviewResearchSites(sites, question, controller) {
  controller.signal.throwIfAborted();
  elements['research-review-question'].textContent = `For: ${question}`;
  elements['research-review-sites'].replaceChildren();
  elements['research-review-yolo'].checked = false;
  for (const site of sites) {
    const label = document.createElement('label'); label.className = 'scope-toggle';
    const checkbox = document.createElement('input'); checkbox.type = 'checkbox'; checkbox.checked = true; checkbox.value = site.origin;
    const text = document.createElement('span');
    const title = document.createElement('strong'); title.textContent = site.origin;
    const detail = document.createElement('small'); detail.textContent = site.title || site.url;
    text.append(title, detail); label.append(checkbox, text);
    elements['research-review-sites'].append(label);
  }
  elements['research-review'].hidden = false;
  showLoading('Waiting for your site choices…', 'Read selected sites, skip them, or press Stop.');
  return new Promise((resolve, reject) => {
    const finish = (value, error) => {
      controller.signal.removeEventListener('abort', abort);
      if (researchReview?.finish === finish) { researchReview = null; elements['research-review'].hidden = true; }
      error ? reject(error) : resolve(value);
    };
    const abort = () => finish(null, controller.signal.reason || new DOMException('Research stopped.', 'AbortError'));
    researchReview = { finish, controller };
    controller.signal.addEventListener('abort', abort, { once: true });
  });
}

function currentContextMode() {
  if (!contextEnabled) return CONTEXT_MODE_NONE;
  return compactContextEnabled ? CONTEXT_MODE_COMPACT : CONTEXT_MODE_FULL;
}

async function setContextMode(mode) {
  if (streaming || courseRetrieving) return;
  const nextEnabled = mode !== CONTEXT_MODE_NONE;
  const nextCompact = mode === CONTEXT_MODE_NONE
    ? compactContextEnabled
    : mode === CONTEXT_MODE_COMPACT;
  if (elements['chat-view'].hidden) {
    contextEnabled = nextEnabled;
    compactContextEnabled = nextCompact;
    renderContextControls();
    return;
  }
  const changedPacking = nextEnabled
    && compactContextEnabled !== nextCompact;
  const needsSourceReload = nextEnabled
    && capture
    && (!capture.context || changedPacking);
  if (!needsSourceReload) {
    contextEnabled = nextEnabled;
    compactContextEnabled = nextCompact;
    if (capture) {
      capture = { ...capture, contextEnabled, compactContextEnabled };
      renderCaptureSource(capture);
      persistCurrentChat().catch(() => {});
    }
    renderContextControls();
    return;
  }

  if (!sameSource(capture, activeSource)) {
    if (nextCompact && capture?.context) {
      const question = elements.composer.value.trim()
        || messages.findLast((entry) => entry.role === 'user')?.content
        || '';
      contextEnabled = true;
      compactContextEnabled = true;
      capture = {
        ...capture,
        context: packPageContext(capture.context, {
          selection: capture.selection,
          question,
          maxChars: COMPACT_PACKED_CONTEXT_CHARS
        }),
        contextEnabled: true,
        compactContextEnabled: true,
        contextState: 'Compact context · locally repacked',
        entirePDF: false
      };
      renderCaptureSource(capture);
      renderContextControls();
      persistCurrentChat().catch(() => {});
      return;
    }
    showStatus('Return to this chat’s source tab to reload its context in this mode.', true);
    renderContextControls();
    return;
  }

  contextEnabled = nextEnabled;
  compactContextEnabled = nextCompact;
  renderContextControls();
  showLoading(
    nextCompact ? 'Loading compact source context…' : 'Loading full source context…',
    nextCompact ? 'Reading relevant text from the source page.' : 'Restoring the larger source-context budget.'
  );
  operationController = new AbortController();
  const previousCapture = capture;
  try {
    const question = elements.composer.value.trim()
      || messages.findLast((entry) => entry.role === 'user')?.content
      || '';
    const descriptor = await contextDescriptor(
      activeSource,
      question,
      previousCapture.selection,
      false,
      false,
      false
    );
    const prepared = isPdfSource(descriptor)
      ? await pdfCapture(descriptor, {
        question,
        selection: previousCapture.selection,
        imageDataUrl: previousCapture.imageDataUrl
      })
      : pageCapture(descriptor, {
        selection: previousCapture.selection,
        imageDataUrl: previousCapture.imageDataUrl
      });
    capture = {
      ...prepared,
      kind: previousCapture.kind,
      selection: previousCapture.selection || prepared.selection,
      imageDataUrl: previousCapture.imageDataUrl || prepared.imageDataUrl,
      contextEnabled: true,
      compactContextEnabled: nextCompact
    };
    renderCaptureSource(capture);
    persistCurrentChat().catch(() => {});
    showStatus(`${nextCompact ? 'Compact' : 'Full'} context is on for this chat.`);
  } catch (error) {
    contextEnabled = previousCapture.contextEnabled !== false;
    compactContextEnabled = previousCapture.compactContextEnabled !== false;
    capture = { ...previousCapture };
    renderCaptureSource(capture);
    showStatus(error?.message || 'Compact context could not be loaded.', true);
  } finally {
    operationController = null;
    hideLoading();
    renderContextControls();
  }
}

function clearPageSelection(source = capture || activeSource) {
  const storageKey = pageSelectionStorageKey(source?.tabId);
  if (storageKey) chrome.storage.session.remove(storageKey).catch(() => {});
}

function renderModelControls() {
  elements['model-select'].disabled = modelSaving;
  elements['chat-model-select'].disabled = modelSaving;
  populateModelSelect(elements['model-select'], settings);
  populateModelSelect(elements['chat-model-select'], settings);
  populateReasoningSelect(elements['reasoning-select'], settings, { disabled: modelSaving });
  populateReasoningSelect(elements['chat-reasoning-select'], settings, { disabled: modelSaving });
  const provider = providerById(settings?.provider);
  const configured = settings?.configuredProviders?.includes(provider.id);
  const supportsFastMode = providerSupportsFastMode(provider);
  elements['fast-mode'].hidden = !supportsFastMode;
  elements['chat-fast-mode'].hidden = !supportsFastMode;
  elements['fast-mode'].disabled = modelSaving || !supportsFastMode;
  elements['chat-fast-mode'].disabled = modelSaving || !supportsFastMode;
  elements['fast-mode'].title = supportsFastMode
    ? `Toggle Fast mode for ${provider.name} (uses more credits)`
    : 'Fast mode is available with Codex CLI and Claude Code';
  elements['chat-fast-mode'].title = elements['fast-mode'].title;
  elements['fast-mode'].setAttribute('aria-pressed', String(supportsFastMode && Boolean(settings?.fastMode)));
  elements['chat-fast-mode'].setAttribute('aria-pressed', String(supportsFastMode && Boolean(settings?.fastMode)));
  elements['fast-mode-state'].textContent = supportsFastMode ? settings?.fastMode ? 'On' : 'Off' : 'Unavailable';
  elements['model-hint'].textContent = configured || !provider.keyRequired
    ? supportsFastMode
      ? 'Changes apply to your next message. Fast uses more credits.'
      : 'Changes apply to your next message.'
    : `${provider.name} still needs an API key in Settings.`;
  renderWebSearchControls();
  refreshBridgeStatus();
}

function renderWebSearchControls() {
  const provider = providerById(settings?.provider);
  const available = providerSupportsWebSearch(provider);
  elements['web-search'].hidden = !available;
  elements['chat-web-search'].hidden = !available;
  if (!available) webSearchEnabled = false;
  elements['web-search'].disabled = !available;
  elements['chat-web-search'].disabled = !available;
  elements['web-search'].setAttribute('aria-pressed', String(available && webSearchEnabled));
  elements['chat-web-search'].setAttribute('aria-pressed', String(available && webSearchEnabled));
  elements['web-search-state'].textContent = available ? webSearchEnabled ? 'On' : 'Off' : 'Unavailable';
  const title = available
    ? `${webSearchEnabled ? 'Disable' : 'Enable'} web search for the next question with ${provider.name}`
    : `Web search is unavailable through ${provider.name}`;
  elements['web-search'].title = title;
  elements['chat-web-search'].title = title;

  const response = currentResponseWindow();
  const responseAvailable = Boolean(response && available);
  if (response && !available) response.webSearchEnabled = false;
  elements['response-window-web-search'].hidden = !responseAvailable;
  elements['response-window-web-search'].setAttribute('aria-pressed', String(
    responseAvailable && response.webSearchEnabled
  ));
  elements['response-window-web-search'].title = responseAvailable
    ? `${response.webSearchEnabled ? 'Disable' : 'Enable'} web search for the next explanation question`
    : title;
  renderChatOptionsSummary();
}

function toggleWebSearch() {
  if (!providerSupportsWebSearch(settings?.provider)) return;
  webSearchEnabled = !webSearchEnabled;
  renderWebSearchControls();
}

function siteStatusText({ enabled, mode }) {
  if (mode === 'allowlist') return enabled ? 'This website is now whitelisted.' : 'This website was removed from the whitelist.';
  return enabled ? 'Scholia is enabled here.' : 'Scholia will stay hidden on this website.';
}

function renderSite() {
  if (!activeSite) return;
  elements.site.textContent = activeSite.site;
  elements['site-toggle'].hidden = false;
  elements['site-toggle'].textContent = activeSite.mode === 'allowlist'
    ? activeSite.enabled ? 'Remove from whitelist' : 'Whitelist this website'
    : activeSite.enabled ? 'Disable Scholia on this site' : 'Enable Scholia on this site';
}

async function refreshSite() {
  try {
    activeSite = await message({ type: 'SCHOLIA_GET_ACTIVE_SITE' });
    renderSite();
  } catch (error) {
    activeSite = null;
    elements.site.textContent = 'Not configurable';
    elements['site-toggle'].hidden = true;
    if (!activeSource) showStatus(error.message, true);
  }
}

function renderActiveSource() {
  if (!activeSource) return;
  const pdf = isPdfSource(activeSource);
  elements['source-badge'].textContent = pdf ? 'Current PDF' : 'Current page';
  elements['current-title'].textContent = sourceTitle(activeSource);
  elements['current-url'].textContent = shortSourceUrl(activeSource.url);
  elements['context-question'].placeholder = pdf
    ? 'Ask anything about this PDF…'
    : 'Ask anything about this page…';
  const siteContextAvailable = supportsSiteContext(activeSource);
  elements['site-scope-row'].hidden = !siteContextAvailable;
  elements['site-scope'].disabled = !siteContextAvailable || !contextEnabled;
  elements['deep-page-row'].hidden = !siteContextAvailable;
  elements['deep-page'].disabled = !siteContextAvailable || !contextEnabled;
  if (!siteContextAvailable) elements['site-scope'].checked = false;
  if (!siteContextAvailable) elements['deep-page'].checked = false;
  renderContextControls();
  const readerActive = Boolean(activeSource.viewerSourceId || activeSource.pdfReaderActive);
  elements['pdf-viewer-actions'].hidden = !pdf;
  elements['open-pdf-viewer'].hidden = !pdf || readerActive;
  elements['pdf-viewer-state'].textContent = readerActive
    ? 'Selection Explain popup is active in this PDF.'
    : 'Open Scholia PDF view to select text and get the same Explain popup as a website.';
  renderLearningModeControls();
}

async function refreshActiveSource() {
  const refreshId = ++sourceRefreshId;
  const source = await message({ type: 'SCHOLIA_GET_ACTIVE_SOURCE' });
  if (refreshId !== sourceRefreshId) return;
  activeSource = source;
  elements['course-index'].hidden = !canvasCourseFromUrl(source.url);
  elements['course-index-status'].textContent = 'Index course pages and readable files for faster, course-wide answers. Changes are checked after 15 minutes.';
  renderActiveSource();
  await refreshSite();
  if (capture?.tabId != null) {
    elements['tab-changed'].hidden = capture.tabId === activeSource.tabId && capture.url === activeSource.url;
  }
}

function showHome() {
  closeChatSearch({ clearQuery: true, restoreFocus: false });
  document.body.classList.remove('is-chat-open');
  elements['home-view'].hidden = false;
  elements['chat-view'].hidden = true;
  elements['home-brand'].hidden = false;
  elements['back-home'].hidden = true;
  elements['expand-chat'].hidden = true;
  elements['chat-search-toggle'].hidden = true;
  elements['new-chat'].hidden = true;
  refreshChatHistory().catch(() => {});
}

function showChat() {
  document.body.classList.add('is-chat-open');
  elements['home-view'].hidden = !dedicatedChatPage;
  elements['chat-view'].hidden = false;
  elements['home-brand'].hidden = true;
  elements['back-home'].hidden = false;
  elements['expand-chat'].hidden = dedicatedChatPage;
  elements['chat-search-toggle'].hidden = false;
  elements['new-chat'].hidden = false;
}

function showLoading(title, detail = '') {
  elements['loading-title'].textContent = title;
  elements['loading-detail'].textContent = detail;
  elements['loading-card'].hidden = false;
}

function hideLoading() {
  elements['loading-card'].hidden = true;
}

function setPreparationMode(preparing) {
  elements.messages.hidden = preparing;
  elements['composer-form'].hidden = preparing;
  elements['chat-context-mode'].disabled = preparing || streaming;
  elements['chat-context-full'].disabled = preparing || streaming;
  elements['chat-context-none'].disabled = preparing || streaming;
  elements['chat-learning-mode'].disabled = preparing || streaming;
}

function cancelRequest() {
  courseController?.abort();
  try { port?.postMessage({ type: 'cancel', requestId }); } catch {}
  const assistant = messages.at(-1);
  if (assistant?.role === 'assistant' && assistant.streaming) assistant.streaming = false;
  streaming = false;
  port?.disconnect();
  port = null;
  renderMessages();
  persistCurrentChat().catch(() => {});
}

function resetConversation() {
  selectionPreparationId += 1;
  courseController?.abort();
  courseController = null;
  courseRetrieving = false;
  elements['research-review'].hidden = true;
  if (streaming) cancelRequest();
  closeResponseWindow({ restoreFocus: false, all: true });
  operationController?.abort();
  operationController = null;
  capture = null;
  messages = [];
  pendingPdf = null;
  pendingPasteSource = null;
  captureSession = null;
  elements['pdf-fallback'].hidden = true;
  elements['paste-card'].hidden = true;
  elements['tab-changed'].hidden = true;
  hideLoading();
  setPreparationMode(false);
  elements.composer.value = '';
  elements.composer.placeholder = 'Ask a follow-up…';
  imageQuestionDraft = '';
  composerSelection = null;
  composerImage = null;
  fileComposer.set();
  pendingResponseSelection = null;
  editingMessageIndex = -1;
  closeChatSearch({ clearQuery: true, restoreFocus: false });
  currentChatId = '';
  chatCreatedAt = 0;
  currentChatUpdatedAt = 0;
  hideResponseExplain();
  renderComposerSelection();
  renderComposerImage();
  renderMessages();
}

function startNewChat() {
  resetConversation();
  compactContextEnabled = defaultContextMode(settings) === CONTEXT_MODE_COMPACT;
  contextEnabled = true;
  clearPageSelection(activeSource);
  renderContextControls();
  showHome();
  refreshActiveSource().catch((error) => showStatus(error.message, true));
  elements['context-question'].focus();
}

function returnHome() {
  cancelRequest();
  operationController?.abort();
  closeResponseWindow({ restoreFocus: false, all: true });
  persistCurrentChat().catch(() => {});
  showHome();
  refreshActiveSource().catch((error) => showStatus(error.message, true));
  elements['context-question'].focus();
}

function relativeTime(value) {
  const elapsed = Math.max(0, Date.now() - Number(value || 0));
  if (elapsed < 60_000) return 'now';
  if (elapsed < 60 * 60_000) return `${Math.floor(elapsed / 60_000)}m ago`;
  if (elapsed < 24 * 60 * 60_000) return `${Math.floor(elapsed / (60 * 60_000))}h ago`;
  if (elapsed < 7 * 24 * 60 * 60_000) return `${Math.floor(elapsed / (24 * 60 * 60_000))}d ago`;
  return new Date(value).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

function historyRow(chat) {
  const row = document.createElement('div');
  row.className = 'history-row';
  row.classList.toggle('is-current', chat.id === currentChatId);
  const open = document.createElement('button');
  open.type = 'button';
  open.className = 'history-open';
  open.dataset.openChat = chat.id;
  if (chat.id === currentChatId) open.setAttribute('aria-current', 'page');
  const title = document.createElement('span');
  title.className = 'history-title';
  title.textContent = chat.title;
  const meta = document.createElement('span');
  meta.className = 'history-meta';
  meta.textContent = [chat.sourceTitle || chat.sourceUrl || 'Saved chat', relativeTime(chat.updatedAt)].filter(Boolean).join(' · ');
  open.append(title, meta);
  const remove = document.createElement('button');
  remove.type = 'button';
  remove.className = 'history-delete';
  remove.dataset.deleteChat = chat.id;
  remove.title = `Delete ${chat.title}`;
  remove.setAttribute('aria-label', `Delete ${chat.title}`);
  remove.textContent = '×';
  row.append(open, remove);
  return row;
}

async function refreshChatHistory() {
  const chats = await listChats();
  elements['chat-history-list'].textContent = '';
  for (const chat of chats.slice(0, dedicatedChatPage ? 24 : 8)) {
    elements['chat-history-list'].append(historyRow(chat));
  }
  elements['chat-history-empty'].hidden = chats.length > 0;
  elements['clear-chats'].hidden = chats.length === 0;
}

function updateDedicatedChatLocation(chatId, title = '') {
  if (!dedicatedChatPage) return;
  const url = dedicatedChatUrl((path) => chrome.runtime.getURL(path), chatId);
  if (url && url !== location.href) history.replaceState(null, '', url);
  document.title = title ? `${title} — Scholia Chat` : 'Scholia Chat';
}

function persistCurrentChat() {
  if (!capture || !messages.some((entry) => entry.role === 'user')) return Promise.resolve(null);
  currentChatId ||= crypto.randomUUID();
  chatCreatedAt ||= Date.now();
  const chosen = selectedProviderModel();
  const updatedAt = Date.now();
  const snapshot = {
    id: currentChatId,
    title: messages.find((entry) => entry.role === 'user')?.content || sourceTitle(capture),
    sourceTitle: sourceTitle(capture),
    sourceUrl: capture.url || '',
    sourceKind: capture.sourceKind || 'page',
    provider: chosen.provider,
    model: chosen.model,
    createdAt: chatCreatedAt,
    updatedAt,
    capture: { ...capture },
    messages: messages.map((entry) => ({
      role: entry.role,
      content: entry.content,
      ...(entry.reasoning ? { reasoning: entry.reasoning } : {}),
      ...(entry.activity?.length ? { activity: entry.activity } : {}),
      ...(entry.meta ? { meta: entry.meta } : {}),
      ...(entry.error ? { error: true } : {}),
      ...(entry.attachment ? { attachment: { ...entry.attachment } } : {}),
      ...(entry.files?.length ? { files: entry.files.map((file) => ({ ...file })) } : {}),
      ...(entry.imageDataUrl ? { imageDataUrl: entry.imageDataUrl } : {}),
      ...(entry.imageUnavailable ? { imageUnavailable: true } : {})
    }))
  };
  currentChatUpdatedAt = updatedAt;
  updateDedicatedChatLocation(currentChatId, snapshot.title);
  const write = historyWrite.catch(() => {}).then(async () => {
    const saved = await saveChat({ ...snapshot, revision: chatRevisions.get(snapshot.id) || 0 });
    if (saved) chatRevisions.set(saved.id, saved.revision);
    return saved;
  });
  historyWrite = write;
  write.then(() => refreshChatHistory()).catch((error) => showStatus(`Chat could not be saved: ${error.message}. Keep this tab open to retain its attachments.`, true));
  return write;
}

async function expandCurrentChat() {
  if (dedicatedChatPage || streaming) return;
  elements['expand-chat'].disabled = true;
  try {
    const chat = await persistCurrentChat();
    const url = dedicatedChatUrl((path) => chrome.runtime.getURL(path), chat?.id);
    if (!url) throw new Error('Send a message before expanding this chat.');
    await chrome.tabs.create({ url });
  } catch (error) {
    showStatus(error?.message || 'The full-page chat could not be opened.', true);
  } finally {
    elements['expand-chat'].disabled = streaming
      || !capture
      || !messages.some((entry) => entry.role === 'user');
  }
}

async function restoreSavedChat(chatId) {
  const chat = await getChat(chatId);
  if (!chat) {
    showStatus('That saved chat is no longer available.', true);
    await refreshChatHistory();
    return;
  }
  resetConversation();
  currentChatId = chat.id;
  chatCreatedAt = chat.createdAt;
  currentChatUpdatedAt = chat.updatedAt;
  chatRevisions.set(chat.id, chat.revision || 0);
  capture = { ...chat.capture };
  contextEnabled = typeof capture.contextEnabled === 'boolean'
    ? capture.contextEnabled
    : true;
  compactContextEnabled = typeof capture.compactContextEnabled === 'boolean'
    ? capture.compactContextEnabled
    : defaultContextMode(settings) === CONTEXT_MODE_COMPACT;
  capture.contextEnabled = contextEnabled;
  capture.compactContextEnabled = compactContextEnabled;
  if (typeof capture.webSearch === 'boolean') webSearchEnabled = capture.webSearch;
  if (capture.imageUnavailable && !capture.imageDataUrl) {
    capture.contextNotice = 'The transcript was restored. Its original image was too large to retain; choose the image again for image-grounded follow-ups.';
    capture.contextState = 'Image not retained';
  }
  messages = chat.messages.map((entry) => ({ ...entry, streaming: false }));
  renderCaptureSource(capture);
  renderContextControls();
  renderMessages();
  setPreparationMode(false);
  showChat();
  renderWebSearchControls();
  elements.composer.value = chat.draft || '';
  resizeComposer();
  updateDedicatedChatLocation(chat.id, chat.title);
  refreshChatHistory().catch(() => {});
  elements.composer.focus();
}

async function syncCurrentChatFromHistory() {
  if (!currentChatId || streaming || courseRetrieving || editingMessageIndex >= 0) return;
  const chat = await getChat(currentChatId);
  if (!chat || chat.updatedAt <= currentChatUpdatedAt) return;
  const draft = elements.composer.value;
  await restoreSavedChat(chat.id);
  elements.composer.value = draft;
  resizeComposer();
}

async function removeSavedChat(chatId) {
  if (chatId === currentChatId) resetConversation();
  await deleteChat(chatId);
  await refreshChatHistory();
  showStatus('Chat deleted.');
}

async function clearSavedChats() {
  if (!confirm('Delete every saved Scholia chat from this device?')) return;
  if (currentChatId) resetConversation();
  await clearChats();
  await refreshChatHistory();
  showStatus('Saved chats cleared.');
}

function renderCaptureSource(nextCapture) {
  renderResearchControls();
  const sources = nextCapture.researchSources || [];
  elements['research-sources'].hidden = !sources.length;
  elements['research-source-list'].replaceChildren();
  for (const source of sources) {
    const url = researchUrl(source.url); if (!url) continue;
    const item = document.createElement('li'), link = document.createElement('a');
    link.href = url; link.target = '_blank'; link.rel = 'noopener noreferrer'; link.textContent = source.title || url;
    item.append(link); elements['research-source-list'].append(item);
  }
  elements['chat-course-refresh'].hidden = !nextCapture?.canvasCourse;
  const pdf = nextCapture.sourceKind === 'pdf';
  const site = nextCapture.sourceKind === 'site';
  const selected = Boolean(nextCapture.selection);
  const selectedImage = nextCapture.sourceKind === 'selected-image';
  const pastedImage = nextCapture.sourceKind === 'pasted-image';
  elements['chat-source-badge'].textContent = nextCapture.imageDataUrl
    ? selected ? 'Selection + image' : pastedImage ? 'Pasted image' : selectedImage ? 'Selected image' : 'Captured region'
    : site ? 'Site context'
      : pdf ? selected ? 'PDF selection' : 'PDF context'
      : nextCapture.kind === 'mail' ? 'Email thread + selection'
      : selected ? 'Selected text' : 'Page context';
  elements['chat-source-title'].textContent = sourceTitle(nextCapture);
  elements['chat-source-detail'].textContent = nextCapture.contextNotice
    || shortSourceUrl(nextCapture.url)
    || 'Context ready';
  const showLanguage = !selectedImage && !pastedImage;
  const language = showLanguage ? documentLanguageLabel(nextCapture.pageLanguage) : '';
  elements['context-state'].textContent = [
    language ? `Language: ${language}` : '',
    nextCapture.contextEnabled === false
      ? 'No context'
      : [nextCapture.compactContextEnabled === false ? 'Full' : 'Compact', nextCapture.contextState]
        .filter(Boolean).join(' · ')
  ].filter(Boolean).join(' · ');
  elements['chat-selection'].hidden = !selected;
  elements['chat-selection'].textContent = nextCapture.selection || '';
  elements['chat-source-image'].hidden = !nextCapture.imageDataUrl;
  if (nextCapture.imageDataUrl) elements['chat-source-image'].src = nextCapture.imageDataUrl;
  else elements['chat-source-image'].removeAttribute('src');
  renderLearningModeControls();
}

function composerPlaceholder() {
  if (composerSelection) return 'Ask about the selected text…';
  if (fileComposer.files.length) return 'Ask about these files…';
  if (composerImage) return 'Ask about the attached image…';
  if (capture?.kind === 'mail') return 'Refine the reply or ask for another tone…';
  return capture?.kind === 'image' ? 'Ask about this image…' : 'Ask a follow-up…';
}

function canExplainCaptureDirectly() {
  return canExplainImageDirectly({
    kind: capture?.kind,
    imageDataUrl: capture?.imageDataUrl,
    question: elements.composer.value,
    messageCount: messages.length,
    hasAttachments: Boolean(composerSelection || composerImage || fileComposer.files.length)
  });
}

function renderComposerSubmitAction() {
  const explainDirectly = !streaming && !courseRetrieving && canExplainCaptureDirectly();
  elements['explain-capture'].hidden = !explainDirectly;
  elements.send.hidden = explainDirectly;
}

function renderComposerSelection() {
  const selected = normalizeSelectionAttachment(composerSelection);
  composerSelection = selected;
  elements['composer-selection'].hidden = !selected;
  elements['composer-selection-label'].textContent = selected?.label || '';
  elements['composer-selection-text'].textContent = selected?.text || '';
  elements.composer.placeholder = composerPlaceholder();
  renderComposerSubmitAction();
}

function setComposerSelection(attachment) {
  composerSelection = normalizeSelectionAttachment(attachment);
  renderComposerSelection();
}

function clearComposerSelection({ removeEmbeddedSource = false } = {}) {
  const selected = composerSelection;
  composerSelection = null;
  if (removeEmbeddedSource && selected?.embedded && capture?.selection === selected.text && !messages.length) {
    capture = { ...capture, selection: '' };
    renderCaptureSource(capture);
  }
  renderComposerSelection();
}

function renderComposerImage() {
  elements['composer-image'].hidden = !composerImage;
  elements['composer-image-label'].textContent = composerImage?.label || '';
  if (composerImage?.imageDataUrl) elements['composer-image-preview'].src = composerImage.imageDataUrl;
  else elements['composer-image-preview'].removeAttribute('src');
  elements.composer.placeholder = composerPlaceholder();
  renderComposerSubmitAction();
}

function setComposerImage(imageDataUrl, label = 'Selected image') {
  if (imageDataUrl) fileComposer.set(fileComposer.files.filter((file) => !file.imageDataUrl));
  composerImage = imageDataUrl ? { imageDataUrl, label: String(label || 'Selected image') } : null;
  renderComposerImage();
}

function clearComposerImage() {
  composerImage = null;
  renderComposerImage();
}

function hideResponseExplain() {
  clearTimeout(responseSelectionTimer);
  elements['response-explain'].hidden = true;
  pendingResponseSelection = null;
  globalThis.CSS?.highlights?.delete('scholia-response-selection');
}

function paintResponseSelection(range) {
  if (!range || !globalThis.CSS?.highlights || typeof globalThis.Highlight !== 'function') return;
  try {
    globalThis.CSS.highlights.set('scholia-response-selection', new globalThis.Highlight(range.cloneRange()));
  } catch {}
}

function selectionNodeElement(node) {
  return node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
}

function assistantBubbleForNode(node) {
  return selectionNodeElement(node)?.closest?.(
    '.message--assistant .bubble, .response-window-message--assistant .bubble'
  ) || null;
}

function showResponseExplain(rect) {
  const selected = pendingResponseSelection;
  if (!selected) return;
  const popup = elements['response-explain'];
  elements['response-explain-preview'].textContent = selected.text.replace(/\s+/g, ' ').slice(0, 180);
  elements['response-explain-question'].value = '';
  const imported = settings?.chatgptWebContext;
  const parentWindow = selected.parentWindowId ? currentResponseWindow() : null;
  const pdf = isPdfSource(parentWindow?.capture || capture);
  elements['response-explain-chatgpt'].hidden = pdf || !contextEnabled || !imported?.available;
  elements['response-explain-chatgpt-toggle'].checked = Boolean(
    parentWindow ? parentWindow.useChatGptWebContext : imported?.enabled
  );
  elements['response-explain-chatgpt'].querySelector('span').textContent = imported?.projectName
    ? `Include ChatGPT memory · ${imported.projectName}`
    : 'Include imported ChatGPT memory/project context';
  const webSearchAvailable = providerSupportsWebSearch(settings?.provider);
  elements['response-explain-web-search'].hidden = !webSearchAvailable;
  elements['response-explain-web-search-toggle'].checked = webSearchAvailable && Boolean(
    parentWindow ? parentWindow.webSearchEnabled : webSearchEnabled
  );
  popup.hidden = false;

  const padding = 8;
  const gap = 7;
  const width = popup.offsetWidth;
  const height = popup.offsetHeight;
  const bounds = embeddedPdf ? document.body.getBoundingClientRect() : { left: 0, top: 0, width: innerWidth, height: innerHeight };
  const anchor = rect || { left: bounds.left + bounds.width / 2, top: bounds.top + bounds.height / 2, bottom: bounds.top + bounds.height / 2, width: 0 };
  const center = anchor.left - bounds.left + (anchor.width || 0) / 2;
  const left = Math.max(padding, Math.min(bounds.width - width - padding, center - width / 2));
  const above = anchor.top - bounds.top - height - gap;
  const top = above >= padding
    ? above
    : Math.max(padding, Math.min(bounds.height - height - padding, anchor.bottom - bounds.top + gap));
  popup.style.left = `${left}px`;
  popup.style.top = `${top}px`;
}

function inspectResponseSelection() {
  if (editingMessageIndex >= 0
    || currentResponseWindow()?.editingMessageIndex >= 0) return;
  if (responseSelectionInteractionProtected({
    pointerInteraction: responseExplainPointerInteraction,
    focusInside: elements['response-explain'].contains(document.activeElement)
  })) return;
  const selection = panelSelection();
  if (!selection || selection.isCollapsed || !selection.rangeCount) {
    hideResponseExplain();
    return;
  }
  const startBubble = assistantBubbleForNode(selection.anchorNode);
  const endBubble = assistantBubbleForNode(selection.focusNode);
  if (!startBubble || startBubble !== endBubble) {
    hideResponseExplain();
    return;
  }
  const responseRow = startBubble.closest('.response-window-message');
  const row = responseRow || startBubble.closest('.message');
  const messageIndex = Number(row?.dataset.messageIndex);
  const parentWindow = responseRow ? currentResponseWindow() : null;
  const sourceMessages = parentWindow?.messages || messages;
  const entry = Number.isInteger(messageIndex) ? sourceMessages[messageIndex] : null;
  const captured = currentSelectionCapture('', selection);
  const attachment = normalizeSelectionAttachment({
    origin: 'response',
    text: captured?.selection,
    label: 'Selected from a response',
    messageIndex
  });
  if (!entry || entry.role !== 'assistant' || entry.error || entry.streaming
      || (parentWindow ? parentWindow.streaming : streaming) || !attachment) {
    hideResponseExplain();
    return;
  }
  pendingResponseSelection = {
    ...attachment,
    parentWindowId: parentWindow?.id || ''
  };
  paintResponseSelection(selection.getRangeAt(0));
  showResponseExplain(captured?.rect);
}

function scheduleResponseSelectionInspection() {
  clearTimeout(responseSelectionTimer);
  responseSelectionTimer = setTimeout(inspectResponseSelection, 35);
}

function currentResponseWindow() {
  return responseWindows.at(-1) || null;
}

function renderResponseWindowMessages({ restoreScroll = false, forceBottom = false } = {}) {
  const state = currentResponseWindow();
  const list = elements['response-window-messages'];
  const previousTop = list.scrollTop;
  const wasNearBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 48;
  list.textContent = '';
  if (!state?.messages.length) {
    const empty = document.createElement('div');
    empty.className = 'empty-chat';
    empty.textContent = 'Preparing the explanation…';
    list.append(empty);
  }
  for (const [index, entry] of (state?.messages || []).entries()) {
    const row = document.createElement('article');
    row.className = `response-window-message response-window-message--${entry.role}${entry.error ? ' response-window-message--error' : ''}`;
    row.dataset.messageIndex = String(index);
    const bubble = document.createElement('div');
    bubble.className = 'bubble';
    if (entry.role === 'user') appendFileChips(bubble, entry.files);
    if (entry.role === 'assistant' && !entry.error) {
      bubble.innerHTML = renderActivity(entry.activity) + renderReasoning(entry.reasoning, { streaming: entry.streaming })
        + renderMarkdown(entry.content)
        + (entry.streaming ? '<span class="caret" aria-label="Writing"></span>' : '');
      bindActivityDisclosure(bubble, entry);
    } else if (entry.role === 'user' && state?.editingMessageIndex === index) {
      appendTurnImage(bubble, entry);
      row.classList.add('is-editing');
      const editor = document.createElement('div');
      editor.className = 'query-editor';
      const textarea = document.createElement('textarea');
      textarea.value = entry.content;
      textarea.dataset.queryEditor = String(index);
      textarea.setAttribute('aria-label', 'Edit message');
      const actions = document.createElement('div');
      actions.className = 'query-editor-actions';
      const cancel = document.createElement('button');
      cancel.type = 'button';
      cancel.className = 'cancel';
      cancel.dataset.cancelQueryEdit = String(index);
      cancel.textContent = 'Cancel';
      const resend = document.createElement('button');
      resend.type = 'button';
      resend.className = 'save';
      resend.dataset.saveQueryEdit = String(index);
      resend.textContent = 'Resend';
      actions.append(cancel, resend);
      editor.append(textarea, actions);
      bubble.append(editor);
    } else if (entry.role === 'user') {
      if (list === elements['response-window-messages']) appendTurnImage(bubble, entry);
      const copy = document.createElement('div');
      copy.className = 'query-copy';
      copy.textContent = entry.content;
      const edit = document.createElement('button');
      edit.type = 'button';
      edit.className = 'query-edit';
      edit.dataset.editQuery = String(index);
      edit.disabled = Boolean(state?.streaming || state?.moving);
      edit.title = 'Edit this message and regenerate from here';
      edit.setAttribute('aria-label', 'Edit message');
      edit.textContent = 'Edit';
      bubble.append(copy, edit);
    } else {
      bubble.textContent = entry.content;
    }
    if (entry.meta) {
      const meta = document.createElement('div');
      meta.className = 'meta';
      meta.textContent = entry.meta;
      bubble.append(meta);
    }
    row.append(bubble);
    list.append(row);
  }
  if (state) {
    if (state.editingMessageIndex >= 0) {
      requestAnimationFrame(() => {
        const textarea = list.querySelector(`[data-query-editor="${state.editingMessageIndex}"]`);
        textarea?.focus();
        textarea?.setSelectionRange(textarea.value.length, textarea.value.length);
        textarea?.scrollIntoView({ block: 'nearest' });
      });
    } else if (restoreScroll) list.scrollTop = Math.min(state.scrollTop || 0, list.scrollHeight);
    else if (forceBottom || wasNearBottom) list.scrollTop = list.scrollHeight;
    else list.scrollTop = Math.min(previousTop, list.scrollHeight);
    state.scrollTop = list.scrollTop;
  }
  elements['response-window-send'].textContent = state?.streaming ? '■' : '↑';
  elements['response-window-send'].classList.toggle('is-stop', Boolean(state?.streaming));
  elements['response-window-send'].setAttribute('aria-label', state?.streaming ? 'Stop response' : 'Send');
  elements['response-window-send'].disabled = Boolean(state?.moving);
  elements['response-window-composer'].readOnly = Boolean(state?.moving);
  elements['response-window-status'].hidden = !state?.moveError;
  elements['response-window-status'].textContent = state?.moveError || '';
  elements['response-window-move'].disabled = !state || state.streaming || state.moving
    || state.editingMessageIndex >= 0 || !state.messages.some((entry) => entry.role === 'user');
  elements['response-window-move'].title = state?.streaming
    ? 'Wait for the response to finish, or stop it before moving to chat'
    : embeddedPdfPanel ? 'Move this explanation to this PDF’s sidebar chat' : 'Move this explanation to a full-page chat';
}

async function moveResponseWindowToChat() {
  const state = currentResponseWindow();
  if (!state || elements['response-window-move'].disabled) return;
  state.moving = true;
  state.moveError = '';
  const draft = elements['response-window-composer'].value;
  renderResponseWindowMessages();
  try {
    await historyWrite.catch(() => {});
    const moved = await message({
      type: 'SCHOLIA_MOVE_EXPLANATION_TO_CHAT',
      explanation: {
        id: state.id,
        ...selectedProviderModel(),
        capture: {
          ...state.capture,
          kind: /\$[^$]+\$/.test(state.attachment.text) ? 'latex' : 'text',
          selection: state.attachment.text,
          parentContext: state.parentContext,
          contextEnabled,
          compactContextEnabled,
          useChatGptWebContext: state.useChatGptWebContext,
          webSearch: state.webSearchEnabled
        },
        messages: state.messages,
        draft
      }
    });
    if (state === currentResponseWindow()) closeResponseWindow();
    if (embeddedPdfPanel && moved?.surface === 'pdf-sidebar') await restoreSavedChat(moved.chatId);
    await refreshChatHistory();
  } catch (error) {
    state.moveError = error.message || 'The explanation could not be moved to chat.';
  } finally {
    state.moving = false;
    if (state === currentResponseWindow()) renderResponseWindowMessages();
  }
}

function scheduleResponseWindowRender(state) {
  if (state !== currentResponseWindow() || state.renderFrame) return;
  state.renderFrame = requestAnimationFrame(() => {
    state.renderFrame = null;
    if (state === currentResponseWindow()) renderResponseWindowMessages();
  });
}

function cancelResponseWindowRequest({ render = true, state = currentResponseWindow() } = {}) {
  if (!state) return;
  try { state.port?.postMessage({ type: 'cancel', requestId: state.requestId }); } catch {}
  const assistant = state.messages.at(-1);
  if (assistant?.role === 'assistant' && assistant.streaming) {
    assistant.streaming = false;
    if (!assistant.content) state.messages.pop();
  }
  state.streaming = false;
  state.port?.disconnect();
  state.port = null;
  if (render && state === currentResponseWindow()) renderResponseWindowMessages();
}

function renderResponseWindowLayer({ restoreScroll = false, forceBottom = false } = {}) {
  const state = currentResponseWindow();
  if (!state) return;
  const depth = responseWindows.length;
  elements['response-window-depth'].textContent = depth === 1 ? 'Response explanation' : `Explanation layer ${depth}`;
  elements['response-window-close'].title = depth === 1
    ? 'Back to sidebar chat'
    : 'Back to previous explanation';
  elements['response-window-close'].setAttribute('aria-label', elements['response-window-close'].title);
  elements['response-window-source'].textContent = state.attachment.text;
  elements['response-window-backdrop'].dataset.depth = String(depth);
  elements['response-window-backdrop'].hidden = false;
  responseFiles.set(state.files || []);
  elements['response-window-composer'].value = state.draft || '';
  renderWebSearchControls();
  resizeResponseWindowComposer();
  renderResponseWindowMessages({ restoreScroll, forceBottom });
}

function closeResponseWindow({ restoreFocus = true, all = false } = {}) {
  const hadWindow = responseWindows.length > 0;
  const state = currentResponseWindow();
  responseFiles.set();
  if (state?.streaming) cancelResponseWindowRequest({ render: false, state });
  if (state?.renderFrame) cancelAnimationFrame(state.renderFrame);
  if (all) responseWindows.splice(0);
  else responseWindows.pop();
  hideResponseExplain();
  try { panelSelection()?.removeAllRanges(); } catch {}

  if (currentResponseWindow()) {
    renderResponseWindowLayer({ restoreScroll: true });
    requestAnimationFrame(() => elements['response-window-close'].focus());
    return;
  }
  elements['response-window-backdrop'].hidden = true;
  delete elements['response-window-backdrop'].dataset.depth;
  elements['response-window-source'].textContent = '';
  elements['response-window-messages'].textContent = '';
  elements['response-window-composer'].value = '';
  if (hadWindow && restoreFocus) {
    requestAnimationFrame(() => {
      if (elements['response-window-backdrop'].hidden && !elements['chat-view'].hidden) elements.composer.focus();
    });
  }
}

function resizeResponseWindowComposer() {
  const textarea = elements['response-window-composer'];
  textarea.style.height = 'auto';
  textarea.style.height = `${Math.min(textarea.scrollHeight, 120)}px`;
}

function askResponseWindow(question, options = responseFiles.options) {
  const state = currentResponseWindow();
  const cleanQuestion = String(question || '').trim();
  if (!state || !cleanQuestion || state.streaming || state.moving) return;
  if (state.messages.at(-1)?.error) {
    state.messages.pop();
    if (state.messages.at(-1)?.role === 'user') state.messages.pop();
  }
  const user = createUserTurn(cleanQuestion, null, options);
  if (!user) return;
  state.messages.push(user);
  responseFiles.set();
  state.files = [];
  const assistant = { role: 'assistant', content: '', streaming: true, meta: '' };
  state.messages.push(assistant);
  state.streaming = true;
  state.editingMessageIndex = -1;
  renderResponseWindowMessages({ forceBottom: true });

  const conversation = requestConversation(state.messages);
  conversation.pop();
  const chosen = selectedProviderModel();
  const webSearch = Boolean(state.webSearchEnabled && providerSupportsWebSearch(chosen.provider));
  state.requestId = crypto.randomUUID();
  const currentRequestId = state.requestId;
  const chatPort = chrome.runtime.connect({ name: 'scholia-chat' });
  state.port = chatPort;

  chatPort.onMessage.addListener((event) => {
    if (state !== currentResponseWindow() || event.requestId !== currentRequestId) return;
    if (event.type === 'token') {
      assistant.content += event.token || '';
      scheduleResponseWindowRender(state);
    } else if (event.type === 'activity') {
      addActivity(assistant, event.activity);
      scheduleResponseWindowRender(state);
    } else if (event.type === 'reasoning') {
      assistant.reasoning = `${assistant.reasoning || ''}${event.token || ''}`;
      scheduleResponseWindowRender(state);
    } else if (event.type === 'done') {
      assistant.streaming = false;
      assistant.reasoning = event.reasoning || '';
      assistant.meta = `${providerById(event.provider).name} · ${event.model}${event.webSearchUsed ? ' · web search' : webSearch ? ' · web enabled' : ''}`;
      state.streaming = false;
      renderResponseWindowMessages();
      chatPort.disconnect();
      if (state.port === chatPort) state.port = null;
    } else if (event.type === 'error') {
      assistant.streaming = false;
      assistant.error = true;
      assistant.content = event.error || 'The provider request failed.';
      state.streaming = false;
      renderResponseWindowMessages();
      chatPort.disconnect();
      if (state.port === chatPort) state.port = null;
    } else if (event.type === 'cancelled') {
      assistant.streaming = false;
      const index = state.messages.indexOf(assistant);
      if (!assistant.content && index >= 0) state.messages.splice(index, 1);
      state.streaming = false;
      renderResponseWindowMessages();
    }
  });
  chatPort.onDisconnect.addListener(() => {
    if (state !== currentResponseWindow() || !state.streaming || state.requestId !== currentRequestId) return;
    assistant.streaming = false;
    assistant.error = true;
    const detail = chrome.runtime.lastError?.message;
    assistant.content ||= detail
      ? `The Scholia service worker disconnected: ${detail}`
      : 'The connection closed before the provider replied. Try again.';
    state.streaming = false;
    if (state.port === chatPort) state.port = null;
    renderResponseWindowMessages();
  });

  chatPort.postMessage({
    type: 'start',
    requestId: currentRequestId,
    payload: {
      ...chosen,
      webSearch,
      messages: conversation,
      kind: /\$[^$]+\$/.test(state.attachment.text) ? 'latex' : 'text',
      selection: state.attachment.text,
      context: state.capture?.context || '',
      includeContext: contextEnabled,
      compactContext: compactContextEnabled,
      parentContext: state.parentContext,
      pageTitle: state.capture?.pageTitle || '',
      pageLanguage: state.capture?.pageLanguage || navigator.language,
      url: state.capture?.url || '',
      imageDataUrl: state.capture?.imageDataUrl || '',
      useChatGptWebContext: contextEnabled
        && !isPdfSource(state.capture)
        && state.useChatGptWebContext,
      learningMode: learningModeEnabled && isPdfSource(state.capture)
    }
  });
}

function openResponseWindow(attachment, question) {
  const requestedParentId = String(attachment?.parentWindowId || '');
  const parentWindow = requestedParentId && currentResponseWindow()?.id === requestedParentId
    ? currentResponseWindow()
    : null;
  if (requestedParentId && !parentWindow) return;
  if (parentWindow) parentWindow.scrollTop = elements['response-window-messages'].scrollTop;
  else closeResponseWindow({ restoreFocus: false, all: true });

  const context = buildResponseLayerContext({
    attachment,
    capture: parentWindow?.capture || capture,
    messages: parentWindow?.messages || messages,
    ancestorContext: parentWindow?.parentContext || ''
  });
  if (!context) return;
  responseWindows.push({
    id: crypto.randomUUID(),
    ...context,
    messages: [],
    streaming: false,
    requestId: '',
    port: null,
    renderFrame: null,
    scrollTop: 0,
    draft: '',
    editingMessageIndex: -1,
    useChatGptWebContext: Boolean(attachment.useChatGptWebContext),
    webSearchEnabled: Boolean(attachment.webSearch && providerSupportsWebSearch(settings?.provider))
  });
  renderResponseWindowLayer({ forceBottom: true });
  requestAnimationFrame(() => elements['response-window-close'].focus());
  askResponseWindow(question || 'Explain this.');
}

function baseCapture(source, { selection = '', imageDataUrl = '', context = '', contextNotice = '', contextState = '' } = {}) {
  return {
    ...(source.canvasCourse ? { canvasCourse: source.canvasCourse } : {}),
    ...(source.pdfIndexStage ? { pdfIndexStage: source.pdfIndexStage } : {}),
    kind: source.kind === 'mail'
      ? 'mail'
      : imageDataUrl && !selection ? 'image' : /\$[^$]+\$/.test(selection) ? 'latex' : 'text',
    selection,
    context,
    contextEnabled,
    compactContextEnabled,
    followLinks: source.followLinks === true,
    researchYolo: source.researchYolo === true,
    researchUrl: researchUrl(source.researchUrl || source.tabUrl || source.url),
    pageTitle: source.kind === 'mail' && source.mailSubject ? source.mailSubject : source.pageTitle || '',
    pageLanguage: source.pageLanguage || navigator.language,
    url: source.url || '',
    imageDataUrl,
    sourceKind: source.sourceKind || 'page',
    pdfUrl: source.pdfUrl || '',
    viewerSourceId: source.viewerSourceId || '',
    tabId: source.tabId,
    contextNotice,
    contextState,
    mailSubject: source.kind === 'mail' ? String(source.mailSubject || '') : '',
    mailMessageCount: source.kind === 'mail' ? Number(source.mailMessageCount) || 0 : 0,
    defaultQuestion: source.kind === 'mail' ? String(source.defaultQuestion || DEFAULT_MAIL_REPLY_QUESTION) : '',
    useChatGptWebContext: source.useChatGptWebContext === true
  };
}

async function contextDescriptor(
  source,
  question,
  selection,
  siteWide = false,
  deepPage = false,
  includeVisual = true
) {
  let detected = await message({
    type: siteWide
      ? 'SCHOLIA_GET_ACTIVE_SITE_CONTEXT'
      : deepPage ? 'SCHOLIA_GET_ACTIVE_DEEP_CONTEXT' : 'SCHOLIA_GET_ACTIVE_CONTEXT',
    expectedTabId: source?.tabId,
    expectedUrl: source?.tabUrl || undefined,
    expectedFrameId: source?.frameId,
    question,
    selection,
    includeVisual,
    includeContext: contextEnabled,
    correlateTabs: false,
    maxChars: contextCharacterLimit(currentContextMode())
  });
  if (contextEnabled && detected.canvasCourse && !source?.followLinks) {
    const course = await getCanvasCourseContext(detected.url || source.url, {
      question, selection, maxChars: contextCharacterLimit(currentContextMode()),
      signal: operationController?.signal,
      onProgress: (detail) => showLoading('Reading Canvas course…', detail)
    });
    detected = { ...detected, ...course };
  }
  if (isPdfSource(source) && (source.pdfUrl || source.fileHandleId) && detected.sourceKind !== 'pdf') {
    return { ...detected, ...source, pageLanguage: detected.pageLanguage || source.pageLanguage, sourceKind: 'pdf' };
  }
  return { ...detected, followLinks: source?.followLinks === true, researchYolo: source?.researchYolo === true,
    researchUrl: researchUrl(source?.researchUrl || source?.tabUrl || detected.url) };
}

function updatePdfProgress(progress) {
  if (progress.phase === 'ocr') {
    showLoading('Reading scanned text locally…', `OCR page ${progress.page} of ${progress.total}`);
  } else if (progress.phase === 'download' || progress.phase === 'load') {
    const loaded = `${(progress.loaded / 1024 / 1024).toFixed(1)} MB`;
    const total = progress.total ? ` of ${(progress.total / 1024 / 1024).toFixed(1)} MB` : '';
    showLoading(progress.phase === 'download' ? 'Downloading PDF locally…' : 'Reading PDF data locally…', `${loaded}${total}`);
  } else {
    showLoading('Reading PDF text locally…', `Page ${progress.page} of ${progress.total}`);
  }
}

async function cachedPdfContext(url, signal) {
  if (pdfCache.has(url)) {
    showLoading('Using locally extracted PDF text…');
    return pdfCache.get(url);
  }
  const task = (async () => {
    const blob = await fetchPdfBlob(url, { signal, onProgress: updatePdfProgress });
    return extractPdfContext(blob, { signal, onProgress: updatePdfProgress });
  })();
  pdfCache.set(url, task);
  try {
    return await task;
  } catch (error) {
    pdfCache.delete(url);
    throw error;
  }
}

async function pdfCapture(source, { question, selection, imageDataUrl, pdfInput } = {}) {
  if (!contextEnabled) {
    return baseCapture(source, {
      selection,
      imageDataUrl,
      contextNotice: 'No automatic document context will be sent for this chat.',
      contextState: 'No context'
    });
  }

  const preparedViewerContext = Boolean(source.pdfContextReady && typeof source.context === 'string');
  const extracted = preparedViewerContext
    ? {
      context: source.context,
      outline: '',
      title: source.pageTitle,
      ocrNotice: source.ocrNotice,
      pageCount: Math.max(0, Number(source.pageCount) || 0),
      extractedCharacters: Math.max(0, Number(source.extractedCharacters) || Number(source.rawContextCharacters) || 0),
      truncated: Number(source.extractedPageCount) > 0 && Number(source.extractedPageCount) < Number(source.pageCount)
    }
    : pdfInput
      ? await extractPdfContext(pdfInput, { signal: operationController.signal, onProgress: updatePdfProgress })
      : await cachedPdfContext(source.pdfUrl, operationController.signal);
  const title = extracted.title || source.pageTitle;
  let visual = imageDataUrl || '';
  let notice = '';
  if (!extracted.extractedCharacters && !visual && source.tabId != null) {
    const screenshot = await message({ type: 'SCHOLIA_CAPTURE_ACTIVE_VISIBLE', expectedTabId: source.tabId });
    visual = screenshot.imageDataUrl;
    notice = 'This PDF has no embedded text. Scholia is using the visible PDF page as image context.';
  }
  const packed = extracted.extractedCharacters
    ? preparedViewerContext ? extracted.context : packPageContext(extracted.context, {
      outline: extracted.outline,
      selection,
      question,
      maxChars: contextCharacterLimit(currentContextMode())
    })
    : '';
  const state = extracted.extractedCharacters
    ? `${extracted.pageCount} pages · ${countLabel(extracted.extractedCharacters)} chars${source.pdfIndexStage === 'basic' ? ' · indexing' : extracted.truncated ? ' · capped' : ''}`
    : 'Scanned PDF · visual context';
  return baseCapture({
    ...source,
    pageTitle: title,
    pageLanguage: extracted.pageLanguage || source.pageLanguage,
    sourceKind: 'pdf'
  }, {
    selection,
    imageDataUrl: visual,
    context: packed,
    contextNotice: [notice || (source.fileHandleId ? 'Local PDF file' : shortSourceUrl(source.url)), extracted.ocrNotice].filter(Boolean).join(' · '),
    contextState: state
  });
}

function pageCapture(source, { selection, imageDataUrl } = {}) {
  const visual = imageDataUrl || source.imageDataUrl || '';
  const raw = Number(source.rawContextCharacters) || String(source.context || '').length;
  const packed = Number(source.packedContextCharacters) || String(source.context || '').length;
  let state = '';
  if (source.canvasCourse) state = 'Canvas course context';
  else if (source.sourceKind === 'site') {
    const read = Number(source.sitePageCount) || 0;
    const discovered = Math.max(read, Number(source.siteDiscoveredPages) || 0);
    state = `${read}${discovered > read ? `/${discovered}` : ''} pages · ${countLabel(raw)} chars${source.siteTruncated ? ' · capped' : ''}`;
  } else if (source.deepPage) {
    const tiles = Number(source.deepPageTiles?.length) || 0;
    const frames = Number(source.deepPageFrameCount) || 0;
    state = [
      'Complete page',
      raw > packed ? `${countLabel(raw)} chars · ${countLabel(packed)} packed` : `${countLabel(raw)} chars`,
      frames ? `${frames} embedded frame${frames === 1 ? '' : 's'}` : '',
      visual ? `${tiles || 1} visual view${tiles === 1 ? '' : 's'}` : source.deepPageVisualRequested ? 'visual unavailable' : 'text-only model',
      source.deepPageLayout?.complete === false ? 'visual sampled' : ''
    ].filter(Boolean).join(' · ');
  } else if (source.sourceKind === 'visible-image') state = 'Visible tab · image context';
  else if (!source.context && !contextEnabled) state = 'No context';
  else if (source.relatedTabCount) {
    state = `${countLabel(raw)} chars · ${countLabel(packed)} packed · ${source.relatedTabCount} related tab${source.relatedTabCount === 1 ? '' : 's'}`;
  }
  else if (raw) state = raw > packed ? `${countLabel(raw)} chars · ${countLabel(packed)} packed` : `${countLabel(raw)} chars`;
  return baseCapture(source, {
    selection,
    imageDataUrl: visual,
    context: source.context || '',
    contextNotice: [
      source.contextNotice || shortSourceUrl(source.url),
      source.deepPageVisualError ? `Full-page visual: ${source.deepPageVisualError}` : ''
    ].filter(Boolean).join(' · '),
    contextState: state
  });
}

function showPdfFallback(error, request) {
  pendingPdf = request;
  hideLoading();
  setPreparationMode(true);
  elements['pdf-fallback-message'].textContent = error?.message || 'Chrome would not let Scholia read this PDF URL.';
  elements['pdf-fallback'].hidden = false;
}

function preparationError(error, source) {
  hideLoading();
  setPreparationMode(false);
  capture = baseCapture(source || {}, { contextNotice: error?.message || 'Context could not be loaded.' });
  renderCaptureSource(capture);
  messages = [{ role: 'assistant', content: error?.message || 'Scholia could not load this source.', error: true }];
  renderMessages();
}

async function captureWithQuickChatChatGptContext(nextCapture, chatGptRefreshTask = null) {
  if (isPdfSource(nextCapture)) {
    nextCapture.useChatGptWebContext = false;
    return nextCapture;
  }
  if (nextCapture.contextEnabled === false) return nextCapture;
  const imported = settings?.chatgptWebContext;
  if (!imported || imported.quickChatRefreshInterval === 'off') return nextCapture;
  const refreshTask = chatGptRefreshTask || refreshQuickChatChatGptContext();
  const immediate = await Promise.race([
    refreshTask.then((value) => ({ ready: true, value })),
    Promise.resolve({ ready: false, value: null })
  ]);
  const chatGpt = immediate.ready
    ? immediate.value
    : { available: Boolean(imported.available), refreshed: false, error: '' };
  if (chatGpt.available) {
    nextCapture.useChatGptWebContext = true;
    nextCapture.contextState = [
      nextCapture.contextState,
      chatGpt.refreshed ? 'ChatGPT refreshed' : 'ChatGPT cached'
    ].filter(Boolean).join(' · ');
  }
  if (chatGpt.error) {
    nextCapture.contextNotice = [nextCapture.contextNotice, chatGpt.error]
      .filter(Boolean).join(' · ');
  }
  if (!immediate.ready) {
    refreshTask
      .then((result) => {
        if (result?.error) showStatus(result.error, true);
      })
      .catch((error) => showStatus(error?.message || 'ChatGPT context refresh failed.', true));
  }
  return nextCapture;
}

function showPreparedQuestionDraft(question = '') {
  renderMessages();
  elements.composer.value = String(question || '');
  renderComposerSelection();
  renderComposerImage();
  resizeComposer();
  elements.composer.focus();
}

async function finalizePreparedChat(
  nextCapture,
  question,
  chatGptRefreshTask = null,
  { waitForQuestion = false } = {}
) {
  nextCapture = await captureWithQuickChatChatGptContext(nextCapture, chatGptRefreshTask);
  capture = nextCapture;
  pendingPdf = null;
  elements['pdf-fallback'].hidden = true;
  hideLoading();
  setPreparationMode(false);
  renderCaptureSource(capture);
  if (waitForQuestion) showPreparedQuestionDraft(question);
  else ask(question || (capture.imageDataUrl ? DEFAULT_IMAGE_EXPLANATION : 'Explain this.'));
}

async function selectedModelCanReceiveImages() {
  const provider = providerById(settings?.provider);
  if (provider.supportsImages) return true;
  if (provider.imageCapability !== 'bridge-health') return false;
  try {
    const status = await message({ type: 'SCHOLIA_BRIDGE_STATUS', provider: provider.id });
    return Boolean(status?.up && status?.supportsImages);
  } catch {
    return false;
  }
}

async function startContextChat({
  source = activeSource,
  question,
  selection = '',
  imageDataUrl = '',
  siteWide = false,
  deepPage = false,
  waitForQuestion = false
} = {}) {
  if (!source) return;
  await (settings ? Promise.resolve() : refreshSettings());
  const useDeepPage = Boolean(deepPage && !siteWide && !isPdfSource(source));
  const includeDeepVisual = useDeepPage && !imageDataUrl
    ? await selectedModelCanReceiveImages()
    : false;
  resetConversation();
  showChat();
  if (!contextEnabled) {
    capture = baseCapture(source, {
      selection,
      imageDataUrl,
      contextNotice: 'No automatic source context will be sent for this chat.',
      contextState: 'No context'
    });
    renderCaptureSource(capture);
    if (waitForQuestion) showPreparedQuestionDraft(question);
    else ask(question || (capture.imageDataUrl ? DEFAULT_IMAGE_EXPLANATION : 'Explain this.'));
    return;
  }
  if (source.followLinks && supportsSiteContext(source)) {
    capture = baseCapture(source, { selection, imageDataUrl, contextNotice: 'Review sites to begin research.' });
    renderCaptureSource(capture);
    if (waitForQuestion) showPreparedQuestionDraft(question);
    else ask(question || 'Explain this.');
    return;
  }
  setPreparationMode(true);
  renderCaptureSource(baseCapture(source, { selection, imageDataUrl, contextNotice: 'Preparing source context…' }));
  showLoading(
    siteWide
      ? 'Reading the entire site locally…'
      : useDeepPage ? 'Loading the complete live page…' : isPdfSource(source) ? 'Opening PDF…' : 'Reading page context…',
    siteWide
      ? 'Following same-site links and building a question-relevant index…'
      : useDeepPage
        ? includeDeepVisual
          ? 'Triggering lazy content and capturing the full visual layout; your scroll position will be restored.'
          : 'Triggering lazy content and collecting all readable live text; your scroll position will be restored.'
        : ''
  );
  const preparationController = new AbortController();
  operationController = preparationController;
  const chatGptRefreshTask = isPdfSource(source) ? null : refreshQuickChatChatGptContext();

  let descriptor;
  try {
    descriptor = await contextDescriptor(
      source,
      question,
      selection,
      siteWide,
      useDeepPage,
      includeDeepVisual
    );
    if (preparationController.signal.aborted || operationController !== preparationController) return;
    if (isPdfSource(descriptor)) {
      try {
        const nextCapture = await pdfCapture(descriptor, { question, selection, imageDataUrl });
        await finalizePreparedChat(nextCapture, question, chatGptRefreshTask, { waitForQuestion });
      } catch (error) {
        if (preparationController.signal.aborted) return;
        if (imageDataUrl) {
          await finalizePreparedChat(baseCapture(descriptor, {
            selection,
            imageDataUrl,
            contextNotice: `Full PDF text was unavailable; using the selected image region. ${error.message}`,
            contextState: 'Region context only'
          }), question, chatGptRefreshTask, { waitForQuestion });
        } else {
          showPdfFallback(error, {
            source: descriptor,
            question,
            selection,
            imageDataUrl,
            chatGptRefreshTask
          });
        }
      }
      return;
    }
    let visual = imageDataUrl;
    if (!visual && useDeepPage && descriptor.deepPageTiles?.length) {
      showLoading('Assembling the complete-page visual…', 'Combining captured views without changing the page scale.');
      try {
        visual = await stitchDeepPageVisual(descriptor.deepPageTiles, descriptor.deepPageLayout);
        descriptor.deepPageVisualAttached = Boolean(visual);
      } catch (error) {
        descriptor.deepPageVisualError = descriptor.deepPageVisualError || error?.message || 'The visual could not be assembled.';
      }
    }
    if (preparationController.signal.aborted || operationController !== preparationController) return;
    await finalizePreparedChat(
      pageCapture(descriptor, { selection, imageDataUrl: visual }),
      question,
      chatGptRefreshTask,
      { waitForQuestion }
    );
  } catch (error) {
    if (!preparationController.signal.aborted && operationController === preparationController) preparationError(error, descriptor || source);
  }
}

async function finishSelectionDraft(
  nextCapture,
  attachment,
  preparationId,
  questionDraft = '',
  chatGptRefreshTask = null
) {
  if (preparationId !== selectionPreparationId) return;
  nextCapture = await captureWithQuickChatChatGptContext(nextCapture, chatGptRefreshTask);
  if (preparationId !== selectionPreparationId) return;
  capture = nextCapture;
  pendingPdf = null;
  elements['pdf-fallback'].hidden = true;
  hideLoading();
  setPreparationMode(false);
  renderCaptureSource(capture);
  setComposerSelection({ ...attachment, embedded: true });
  elements.composer.value = String(questionDraft || '');
  resizeComposer();
  renderMessages();
}

async function prepareSyncedPageSelection(draft, attachment, questionDraft = '') {
  await (settings ? Promise.resolve() : refreshSettings());
  resetConversation();
  elements['context-question'].value = '';
  const preparationId = ++selectionPreparationId;
  showChat();
  if (!contextEnabled) {
    capture = baseCapture(draft, {
      selection: attachment.text,
      contextNotice: 'Using only the selected text because this chat is in no-context mode.',
      contextState: 'No context'
    });
    setComposerSelection({ ...attachment, embedded: true });
    elements.composer.value = String(questionDraft || '');
    resizeComposer();
    renderCaptureSource(capture);
    renderMessages();
    return;
  }
  setPreparationMode(true);
  renderCaptureSource(baseCapture(draft, {
    selection: attachment.text,
    contextNotice: 'Preparing the selected page context…'
  }));
  showLoading(isPdfSource(draft) ? 'Opening PDF…' : 'Reading page context…');
  const controller = new AbortController();
  operationController = controller;
  const chatGptRefreshTask = refreshQuickChatChatGptContext();

  if (draft.kind === 'mail' && String(draft.mailContext || '').trim()) {
    const rawContext = String(draft.mailContext).trim();
    const mailQuestion = String(questionDraft || '').trim() || draft.defaultQuestion || DEFAULT_MAIL_REPLY_QUESTION;
    const context = !contextEnabled
      ? ''
      : packPageContext(rawContext, {
        selection: attachment.text,
        question: mailQuestion,
        maxChars: contextCharacterLimit(currentContextMode()),
        scopeDescription: 'the selected private email thread'
      });
    const nextCapture = baseCapture({ ...draft, kind: 'mail' }, {
      selection: attachment.text,
      context,
      contextNotice: draft.mailSubject ? `Mail thread · ${draft.mailSubject}` : 'Selected mail thread',
      contextState: `${Number(draft.mailMessageCount) || 1} message${Number(draft.mailMessageCount) === 1 ? '' : 's'} · ${countLabel(rawContext.length)} chars`
    });
    await finishSelectionDraft(
      nextCapture,
      attachment,
      preparationId,
      mailQuestion,
      chatGptRefreshTask
    );
    return;
  }

  let descriptor;
  try {
    descriptor = await contextDescriptor(draft, '', attachment.text, false);
    if (preparationId !== selectionPreparationId || controller.signal.aborted) return;
    if (isPdfSource(descriptor)) {
      try {
        const nextCapture = await pdfCapture(descriptor, { question: '', selection: attachment.text });
        await finishSelectionDraft(
          nextCapture,
          attachment,
          preparationId,
          questionDraft,
          chatGptRefreshTask
        );
      } catch (error) {
        if (controller.signal.aborted) return;
        await finishSelectionDraft(baseCapture(descriptor, {
          selection: attachment.text,
          contextNotice: `Using the selected PDF text without full document context. ${error.message}`,
          contextState: 'Selection context'
        }), attachment, preparationId, questionDraft, chatGptRefreshTask);
      }
      return;
    }
    await finishSelectionDraft(
      pageCapture(descriptor, { selection: attachment.text }),
      attachment,
      preparationId,
      questionDraft,
      chatGptRefreshTask
    );
  } catch (error) {
    if (!controller.signal.aborted && preparationId === selectionPreparationId) {
      await finishSelectionDraft(baseCapture(descriptor || draft, {
        selection: attachment.text,
        contextNotice: `Using the selected text without additional page context. ${error.message}`,
        contextState: 'Selection context'
      }), attachment, preparationId, questionDraft, chatGptRefreshTask);
    }
  }
}

function sameSource(left, right) {
  if (!left || !right) return false;
  if (Number.isInteger(left.tabId) && Number.isInteger(right.tabId) && left.tabId !== right.tabId) return false;
  return String(left.url || left.pdfUrl || '') === String(right.url || right.pdfUrl || '');
}

async function consumeSyncedPageSelection(draft) {
  if (!draft?.id || draft.id === lastSyncedSelectionId || !draft.selection) return;
  if (Date.now() - Number(draft.createdAt || 0) > 10 * 60_000) return;
  if (!activeSource) await refreshActiveSource();
  if (Number.isInteger(activeSource?.tabId) && draft.tabId !== activeSource.tabId) return;

  lastSyncedSelectionId = draft.id;
  const attachment = normalizeSelectionAttachment({
    origin: 'page',
    text: draft.selection,
    label: draft.kind === 'mail'
      ? 'Selected from an email thread'
      : draft.kind === 'latex' ? 'Selected mathematics from the page' : 'Selected from the page'
  });
  if (!attachment) return;

  if (draft.kind !== 'mail' && !elements['chat-view'].hidden && messages.length && sameSource(capture, draft)) {
    setComposerSelection(attachment);
    return;
  }
  const questionDraft = elements['chat-view'].hidden
    ? elements['context-question'].value
    : elements.composer.value;
  await prepareSyncedPageSelection(
    draft,
    attachment,
    String(questionDraft || '').trim() || (draft.kind === 'mail' ? draft.defaultQuestion || DEFAULT_MAIL_REPLY_QUESTION : '')
  );
}

async function refreshActiveSelection() {
  const draft = await message({ type: 'SCHOLIA_GET_ACTIVE_SELECTION' });
  if (draft) await consumeSyncedPageSelection(draft);
}

function selectedProviderModel() {
  const provider = settings?.provider || 'openai';
  return {
    provider,
    model: settings?.models?.[provider] || providerById(provider).defaultModel,
    reasoningEffort: settings?.reasoningEfforts?.[provider],
    fastMode: Boolean(settings?.fastMode)
  };
}

async function refreshQuickChatChatGptContext() {
  const imported = settings?.chatgptWebContext;
  if (!imported || imported.quickChatRefreshInterval === 'off') {
    return { available: false, refreshed: false, error: '' };
  }
  const cachedAvailable = Boolean(imported.available);
  try {
    const result = await message({ type: 'SCHOLIA_REFRESH_CHATGPT_CONTEXT_FOR_QUICK_CHAT' });
    if (result?.context) settings.chatgptWebContext = result.context;
    return {
      available: Boolean(result?.context?.available),
      refreshed: Boolean(result?.refreshed),
      error: ''
    };
  } catch (error) {
    return {
      available: cachedAvailable,
      refreshed: false,
      error: cachedAvailable
        ? `ChatGPT refresh failed; using the saved snapshot. ${error.message}`
        : `ChatGPT context was unavailable. ${error.message}`
    };
  }
}

function saveInlineModel({ select = elements['model-select'], fastMode = settings?.fastMode, reasoningEffort } = {}) {
  if (modelSaving) return modelSave;
  const chosen = parseModelChoice(select.value);
  modelSaving = true;
  elements['composer-settings-status'].hidden = true;
  for (const id of ['model-select', 'chat-model-select', 'reasoning-select', 'chat-reasoning-select', 'fast-mode', 'chat-fast-mode']) {
    elements[id].disabled = true;
  }
  modelSave = (async () => {
    try {
      settings = await message({ type: 'SCHOLIA_SAVE_MODEL', ...chosen, fastMode, reasoningEffort });
      showStatus('Preferences saved for your next message.');
    } catch (error) {
      showStatus(error.message, true);
      elements['composer-settings-status'].textContent = error.message;
      elements['composer-settings-status'].hidden = false;
    } finally {
      modelSaving = false;
      renderModelControls();
    }
  })();
  return modelSave;
}

async function ask(
  question,
  { attachment = composerSelection, imageDataUrl = composerImage?.imageDataUrl || fileComposer.options.imageDataUrl, files = fileComposer.options.files } = {}
) {
  await modelSave;
  const cleanQuestion = String(question || '').trim();
  if (!cleanQuestion || streaming || courseRetrieving || !capture) return;
  if (contextEnabled && !capture.entirePDF && (capture.followLinks || capture.canvasCourse || (embeddedPdfPanel && capture.pdfIndexStage === 'basic'))) {
    const source = capture;
    const controller = new AbortController();
    courseController = controller;
    courseRetrieving = true;
    renderMessages();
    try {
      let context;
      if (source.followLinks) {
        context = await getBrowserResearchContext(source, {
          question: cleanQuestion, selection: attachment?.text || source.selection,
          maxChars: contextCharacterLimit(currentContextMode()), settings, signal: controller.signal,
          // Read the flag for each newly discovered site so enabling YOLO in a
          // pending review takes effect in this run, but never overrides Stop.
          review: (sites) => source.researchYolo ? Promise.resolve(sites.map((site) => site.origin))
            : reviewResearchSites(sites, cleanQuestion, controller),
          readLivePage: () => message({ type: 'SCHOLIA_GET_RESEARCH_PAGE', tabId: source.tabId, url: source.researchUrl || source.url }),
          onProgress: (detail) => showLoading('Following relevant links…', detail)
        });
        if (source.researchYolo) context.contextNotice = context.contextNotice.replace('approved sites', 'YOLO');
      } else if (source.canvasCourse) {
        context = await getCanvasCourseContext(source.url, {
          question: cleanQuestion, selection: attachment?.text || source.selection,
          maxChars: contextCharacterLimit(currentContextMode()), signal: controller.signal,
          onProgress: (detail) => showLoading('Reading Canvas course…', detail)
        });
      } else {
        // A conversation started with the quick index adopts newly recognized
        // pages on its next turn without resetting messages or context mode.
        const descriptor = await contextDescriptor(source, cleanQuestion, source.selection, false, false, false);
        if (capture !== source || controller.signal.aborted) return;
        context = descriptor.pdfContextReady ? await pdfCapture(descriptor, {
          question: cleanQuestion, selection: source.selection, imageDataUrl: source.imageDataUrl
        }) : source;
      }
      if (capture !== source || controller.signal.aborted) return;
      Object.assign(capture, context);
      renderCaptureSource(capture);
    } catch (error) {
      if (capture === source && !controller.signal.aborted) {
        elements.composer.value = cleanQuestion;
        resizeComposer();
        capture.contextNotice = error.message;
        renderCaptureSource(capture);
        showStatus(error.message, true);
      } else if (capture === source) {
        elements.composer.value = cleanQuestion;
        resizeComposer();
        capture.contextNotice = 'Research stopped. Your question is ready to edit or resend.';
        renderCaptureSource(capture);
        showStatus('Research stopped. Your question is ready to edit or resend.');
      }
      return;
    } finally {
      if (courseController === controller) {
        courseController = null; courseRetrieving = false; hideLoading(); renderMessages();
      }
    }
  }
  if (messages.at(-1)?.error) {
    messages.pop();
    if (messages.at(-1)?.role === 'user') messages.pop();
  }
  const user = createUserTurn(cleanQuestion, attachment, { imageDataUrl, files });
  if (!user) return;
  if (user.attachment?.origin === 'page') clearPageSelection(capture);
  messages.push(user);
  const assistant = { role: 'assistant', content: '', streaming: true, meta: '' };
  messages.push(assistant);
  streaming = true;
  clearComposerSelection();
  clearComposerImage();
  fileComposer.set();
  editingMessageIndex = -1;
  renderMessages();
  persistCurrentChat().catch(() => {});

  const conversation = requestConversation(messages);
  conversation.pop();
  const chosen = selectedProviderModel();
  const webSearch = webSearchEnabled && providerSupportsWebSearch(chosen.provider);
  requestId = crypto.randomUUID();
  const currentRequestId = requestId;
  const chatPort = chrome.runtime.connect({ name: 'scholia-chat' });
  port = chatPort;

  chatPort.onMessage.addListener((event) => {
    if (event.requestId !== currentRequestId) return;
    if (event.type === 'token') {
      assistant.content += event.token || '';
      scheduleRender();
    } else if (event.type === 'activity') {
      addActivity(assistant, event.activity);
      scheduleRender();
    } else if (event.type === 'reasoning') {
      assistant.reasoning = `${assistant.reasoning || ''}${event.token || ''}`;
      scheduleRender();
    } else if (event.type === 'done') {
      assistant.streaming = false;
      assistant.reasoning = event.reasoning || '';
      assistant.meta = `${providerById(event.provider).name} · ${event.model}${event.webSearchUsed ? ' · web search' : webSearch ? ' · web enabled' : ''}`;
      streaming = false;
      renderMessages();
      persistCurrentChat().catch(() => {});
      chatPort.disconnect();
      if (port === chatPort) port = null;
    } else if (event.type === 'error') {
      assistant.streaming = false;
      assistant.error = true;
      assistant.content = event.error || 'The provider request failed.';
      streaming = false;
      renderMessages();
      persistCurrentChat().catch(() => {});
      chatPort.disconnect();
      if (port === chatPort) port = null;
    } else if (event.type === 'cancelled') {
      assistant.streaming = false;
      const index = messages.indexOf(assistant);
      if (!assistant.content && index >= 0) messages.splice(index, 1);
      streaming = false;
      renderMessages();
      persistCurrentChat().catch(() => {});
    }
  });
  chatPort.onDisconnect.addListener(() => {
    if (!streaming || requestId !== currentRequestId) return;
    assistant.streaming = false;
    assistant.error = true;
    const detail = chrome.runtime.lastError?.message;
    assistant.content ||= detail
      ? `The Scholia service worker disconnected: ${detail}`
      : 'The connection closed before the provider replied. Try again.';
    streaming = false;
    if (port === chatPort) port = null;
    renderMessages();
    persistCurrentChat().catch(() => {});
  });

  chatPort.postMessage({
    type: 'start',
    requestId: currentRequestId,
    payload: {
      ...chosen,
      webSearch,
      messages: conversation,
      kind: capture.kind,
      selection: capture.selection,
      context: capture.context,
      entirePDF: capture.entirePDF === true,
      includeContext: contextEnabled,
      compactContext: compactContextEnabled,
      parentContext: capture.parentContext || '',
      pageTitle: capture.pageTitle,
      pageLanguage: capture.pageLanguage,
      url: capture.url,
      imageDataUrl: capture.imageDataUrl,
      useChatGptWebContext: contextEnabled
        && !isPdfSource(capture)
        && Boolean(capture.useChatGptWebContext),
      learningMode: learningModeEnabled && isPdfSource(capture)
    }
  });
}

function scheduleRender() {
  if (renderFrame) return;
  renderFrame = requestAnimationFrame(() => {
    renderFrame = null;
    renderMessages();
  });
}

function clearChatSearchHighlights() {
  const parents = new Set();
  for (const mark of elements.messages.querySelectorAll('[data-chat-search-match]')) {
    const parent = mark.parentNode;
    parents.add(parent);
    mark.replaceWith(document.createTextNode(mark.textContent || ''));
  }
  for (const parent of parents) parent?.normalize();
  for (const row of elements.messages.querySelectorAll('.message.is-search-result')) {
    row.classList.remove('is-search-result', 'is-current-search-result');
    row.removeAttribute('aria-current');
  }
}

function visibleSearchTextNodes(row) {
  const nodes = [];
  const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (!node.data || !node.data.trim()) return NodeFilter.FILTER_REJECT;
      const parent = node.parentElement;
      if (!parent || parent.closest('button,textarea,.meta,.katex,.scholia-code__bar,[data-chat-search-match]')) {
        return NodeFilter.FILTER_REJECT;
      }
      return NodeFilter.FILTER_ACCEPT;
    }
  });
  let node;
  while ((node = walker.nextNode())) nodes.push(node);
  return nodes;
}

function highlightSearchTextNode(node, ranges, current) {
  if (!ranges.length) return;
  const fragment = document.createDocumentFragment();
  let cursor = 0;
  for (const range of ranges) {
    if (range.start > cursor) fragment.append(document.createTextNode(node.data.slice(cursor, range.start)));
    const mark = document.createElement('mark');
    mark.className = `chat-search-match${current ? ' is-current' : ''}`;
    mark.dataset.chatSearchMatch = '';
    mark.textContent = node.data.slice(range.start, range.end);
    fragment.append(mark);
    cursor = range.end;
  }
  if (cursor < node.data.length) fragment.append(document.createTextNode(node.data.slice(cursor)));
  node.replaceWith(fragment);
}

function updateChatSearch({ resetActive = false, reveal = false } = {}) {
  clearChatSearchHighlights();
  if (elements['chat-search'].hidden) return;

  const query = elements['chat-search-input'].value.trim();
  const previousMessageIndex = chatSearchResultIndexes[activeChatSearchIndex];
  const nextIndexes = matchingMessageIndexes(messages, query);
  chatSearchResultIndexes = nextIndexes;
  if (!nextIndexes.length) activeChatSearchIndex = -1;
  else if (resetActive) activeChatSearchIndex = 0;
  else {
    const preservedIndex = nextIndexes.indexOf(previousMessageIndex);
    activeChatSearchIndex = preservedIndex >= 0
      ? preservedIndex
      : Math.min(Math.max(activeChatSearchIndex, 0), nextIndexes.length - 1);
  }

  const currentMessageIndex = nextIndexes[activeChatSearchIndex];
  let highlightBudget = MAX_CHAT_SEARCH_RESULTS;
  for (const messageIndex of nextIndexes) {
    const row = elements.messages.querySelector(`[data-message-index="${messageIndex}"]`);
    if (!row) continue;
    const current = messageIndex === currentMessageIndex;
    row.classList.add('is-search-result');
    row.classList.toggle('is-current-search-result', current);
    if (current) row.setAttribute('aria-current', 'true');
    for (const node of visibleSearchTextNodes(row)) {
      if (highlightBudget <= 0) break;
      const ranges = searchRanges(node.data, query, highlightBudget);
      highlightBudget -= ranges.length;
      highlightSearchTextNode(node, ranges, current);
    }
  }

  const hasResults = nextIndexes.length > 0;
  elements['chat-search-count'].textContent = !query
    ? '0 / 0'
    : hasResults ? `${activeChatSearchIndex + 1} / ${nextIndexes.length}` : 'No results';
  elements['chat-search-previous'].disabled = !hasResults;
  elements['chat-search-next'].disabled = !hasResults;

  if (reveal && hasResults) {
    elements.messages.querySelector(`[data-message-index="${currentMessageIndex}"]`)
      ?.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'smooth' });
  }
}

function openChatSearch() {
  if (elements['chat-view'].hidden || !elements['response-window-backdrop'].hidden) return;
  hideResponseExplain();
  elements['chat-search'].hidden = false;
  elements['chat-search-toggle'].setAttribute('aria-expanded', 'true');
  updateChatSearch({ reveal: true });
  requestAnimationFrame(() => {
    elements['chat-search-input'].focus();
    elements['chat-search-input'].select();
  });
}

function closeChatSearch({ clearQuery = false, restoreFocus = true } = {}) {
  const wasOpen = !elements['chat-search'].hidden;
  clearChatSearchHighlights();
  elements['chat-search'].hidden = true;
  elements['chat-search-toggle'].setAttribute('aria-expanded', 'false');
  if (clearQuery) elements['chat-search-input'].value = '';
  elements['chat-search-count'].textContent = '0 / 0';
  elements['chat-search-previous'].disabled = true;
  elements['chat-search-next'].disabled = true;
  chatSearchResultIndexes = [];
  activeChatSearchIndex = -1;
  if (wasOpen && restoreFocus && !elements['chat-view'].hidden) elements.composer.focus();
}

function moveChatSearch(direction) {
  activeChatSearchIndex = movedSearchIndex(
    activeChatSearchIndex,
    chatSearchResultIndexes.length,
    direction
  );
  updateChatSearch({ reveal: true });
}

function appendSelectionQuote(bubble, attachment) {
  const selected = normalizeSelectionAttachment(attachment);
  if (!selected) return;
  const quote = document.createElement('blockquote');
  quote.className = 'query-selection';
  quote.textContent = selected.text;
  quote.title = selected.label;
  bubble.append(quote);
}

function appendTurnImage(bubble, entry) {
  if (entry?.imageDataUrl) {
    const image = document.createElement('img');
    image.className = 'query-image';
    image.src = entry.imageDataUrl;
    image.alt = 'Image attached to this message';
    bubble.append(image);
  } else if (entry?.imageUnavailable) {
    const unavailable = document.createElement('div');
    unavailable.className = 'query-image-unavailable';
    unavailable.textContent = 'Attached image was not retained';
    bubble.append(unavailable);
  }
}

function renderMessages() {
  const previousTop = elements.messages.scrollTop;
  const wasNearBottom = elements.messages.scrollHeight
    - elements.messages.scrollTop - elements.messages.clientHeight < 48;
  const messageCountChanged = messages.length !== lastRenderedMessageCount;
  elements.messages.textContent = '';
  if (!messages.length) {
    const empty = document.createElement('div');
    empty.className = 'empty-chat';
    empty.textContent = 'Your contextual conversation will appear here.';
    elements.messages.append(empty);
  }
  for (const [index, entry] of messages.entries()) {
    const row = document.createElement('article');
    row.className = `message message--${entry.role}${entry.error ? ' message--error' : ''}`;
    row.dataset.messageIndex = String(index);
    const bubble = document.createElement('div');
    bubble.className = 'bubble';
    if (entry.role === 'user') appendFileChips(bubble, entry.files);
    if (entry.role === 'assistant' && !entry.error) {
      bubble.innerHTML = renderActivity(entry.activity) + renderReasoning(entry.reasoning, { streaming: entry.streaming })
        + renderMarkdown(entry.content)
        + (entry.streaming ? '<span class="caret" aria-label="Writing"></span>' : '');
      bindActivityDisclosure(bubble, entry);
    } else if (entry.role === 'user' && editingMessageIndex === index) {
      row.classList.add('is-editing');
      appendTurnImage(bubble, entry);
      appendSelectionQuote(bubble, entry.attachment);
      const editor = document.createElement('div');
      editor.className = 'query-editor';
      const textarea = document.createElement('textarea');
      textarea.value = entry.content;
      textarea.dataset.queryEditor = String(index);
      textarea.setAttribute('aria-label', 'Edit query');
      const actions = document.createElement('div');
      actions.className = 'query-editor-actions';
      const cancel = document.createElement('button');
      cancel.type = 'button';
      cancel.className = 'cancel';
      cancel.dataset.cancelQueryEdit = String(index);
      cancel.textContent = 'Cancel';
      const save = document.createElement('button');
      save.type = 'button';
      save.className = 'save';
      save.dataset.saveQueryEdit = String(index);
      save.textContent = 'Resend';
      actions.append(cancel, save);
      editor.append(textarea, actions);
      bubble.append(editor);
    } else if (entry.role === 'user') {
      appendTurnImage(bubble, entry);
      appendSelectionQuote(bubble, entry.attachment);
      const copy = document.createElement('div');
      copy.className = 'query-copy';
      copy.textContent = entry.content;
      const edit = document.createElement('button');
      edit.type = 'button';
      edit.className = 'query-edit';
      edit.dataset.editQuery = String(index);
      edit.disabled = streaming;
      edit.title = 'Edit this query and regenerate from here';
      edit.setAttribute('aria-label', 'Edit query');
      edit.textContent = 'Edit';
      bubble.append(copy, edit);
    } else {
      bubble.textContent = entry.content;
    }
    if (entry.meta) {
      const meta = document.createElement('div');
      meta.className = 'meta';
      meta.textContent = entry.meta;
      bubble.append(meta);
    }
    row.append(bubble);
    elements.messages.append(row);
  }
  updateChatSearch();
  if (editingMessageIndex >= 0) {
    requestAnimationFrame(() => {
      const textarea = elements.messages.querySelector(`[data-query-editor="${editingMessageIndex}"]`);
      textarea?.focus();
      textarea?.setSelectionRange(textarea.value.length, textarea.value.length);
      textarea?.scrollIntoView({ block: 'nearest' });
    });
  } else if (messageCountChanged || wasNearBottom) {
    elements.messages.scrollTop = elements.messages.scrollHeight;
  } else {
    elements.messages.scrollTop = Math.min(previousTop, elements.messages.scrollHeight);
  }
  lastRenderedMessageCount = messages.length;
  elements.send.textContent = streaming || courseRetrieving ? '■' : '↑';
  elements.send.classList.toggle('is-stop', streaming || courseRetrieving);
  elements.send.setAttribute('aria-label', courseRetrieving ? 'Stop research' : streaming ? 'Stop response' : 'Send');
  renderComposerSubmitAction();
  elements.send.disabled = fileComposer.busy && !courseRetrieving;
  elements['chat-course-refresh'].hidden = !capture?.canvasCourse;
  elements['chat-course-refresh'].disabled = streaming || courseRetrieving;
  elements['expand-chat'].disabled = streaming
    || !capture
    || !messages.some((entry) => entry.role === 'user');
  elements['attach-files'].disabled = streaming;
  elements['attach-region'].disabled = streaming;
  elements['chat-context-mode'].disabled = streaming || courseRetrieving;
  elements['chat-context-full'].disabled = streaming || courseRetrieving;
  elements['chat-context-none'].disabled = streaming || courseRetrieving;
  elements['chat-learning-mode'].disabled = streaming;
  renderResearchControls();
}

function beginQueryEdit(index) {
  if (streaming || messages[index]?.role !== 'user') return;
  hideResponseExplain();
  editingMessageIndex = index;
  renderMessages();
}

function cancelQueryEdit() {
  editingMessageIndex = -1;
  renderMessages();
}

function saveQueryEdit(index) {
  const textarea = elements.messages.querySelector(`[data-query-editor="${index}"]`);
  const prepared = prepareEditedResend(messages, index, textarea?.value);
  if (!prepared || streaming) {
    textarea?.focus();
    return;
  }
  replaceConversationPrefix(messages, prepared);
  editingMessageIndex = -1;
  ask(prepared.question, { attachment: prepared.attachment, imageDataUrl: prepared.imageDataUrl, files: prepared.files || [] });
}

function beginResponseQueryEdit(index) {
  const state = currentResponseWindow();
  if (!state || state.streaming || state.moving || state.messages[index]?.role !== 'user') return;
  hideResponseExplain();
  state.editingMessageIndex = index;
  renderResponseWindowMessages();
}

function cancelResponseQueryEdit() {
  const state = currentResponseWindow();
  if (!state) return;
  state.editingMessageIndex = -1;
  renderResponseWindowMessages();
}

function saveResponseQueryEdit(index) {
  const state = currentResponseWindow();
  const textarea = elements['response-window-messages']
    .querySelector(`[data-query-editor="${index}"]`);
  const prepared = prepareEditedResend(state?.messages, index, textarea?.value);
  if (!state || !prepared || state.streaming) {
    textarea?.focus();
    return;
  }
  replaceConversationPrefix(state.messages, prepared);
  state.editingMessageIndex = -1;
  askResponseWindow(prepared.question, { imageDataUrl: prepared.imageDataUrl, files: prepared.files || [] });
}

function explainResponseSelection() {
  const attachment = pendingResponseSelection;
  if (!attachment) return;
  const parentWindow = attachment.parentWindowId ? currentResponseWindow() : null;
  if (parentWindow?.streaming || (!attachment.parentWindowId && streaming)) return;
  const question = elements['response-explain-question'].value.trim() || 'Explain this.';
  attachment.useChatGptWebContext = !elements['response-explain-chatgpt'].hidden
    && elements['response-explain-chatgpt-toggle'].checked;
  attachment.webSearch = !elements['response-explain-web-search'].hidden
    && elements['response-explain-web-search-toggle'].checked;
  hideResponseExplain();
  try { panelSelection()?.removeAllRanges(); } catch {}
  openResponseWindow(attachment, question);
}

function resizeComposer() {
  elements.composer.style.height = 'auto';
  elements.composer.style.height = `${Math.min(elements.composer.scrollHeight, 120)}px`;
}

function showImageInputError(error) {
  const text = error?.message || 'Scholia could not read that image.';
  if (elements['chat-view'].hidden) {
    showStatus(text, true);
    return;
  }
  messages.push({ role: 'assistant', content: text, error: true });
  renderMessages();
}

function openImagePicker(question = '') {
  imageQuestionDraft = String(question || '');
  elements['image-file'].click();
}

async function useImageFile(file, { question = '', pasted = false } = {}) {
  if (!file) return;
  const imageDataUrl = await normalizeImageFile(file);
  const appendToConversation = !elements['chat-view'].hidden
    && Boolean(capture)
    && messages.some((entry) => entry.role === 'user');
  if (appendToConversation) {
    if (streaming) throw new Error('Wait for the current response before attaching an image.');
    setComposerImage(imageDataUrl, pasted ? 'Pasted image' : String(file.name || 'Selected image'));
    elements.composer.value = String(question || '');
    resizeComposer();
    elements.composer.focus();
    return;
  }
  const pageTitle = pasted ? 'Pasted image' : String(file.name || 'Selected image');
  const sourceKind = pasted ? 'pasted-image' : 'selected-image';
  resetConversation();
  showChat();
  capture = baseCapture({ pageTitle, pageLanguage: navigator.language, sourceKind }, {
    imageDataUrl,
    contextNotice: pasted ? 'Image pasted from the clipboard.' : 'Image selected from this device.',
    contextState: 'Image only'
  });
  if (settings?.chatgptWebContext?.quickChatRefreshInterval !== 'off') {
    setPreparationMode(true);
    showLoading('Refreshing ChatGPT context…', 'The image stays on this device while the saved context is updated.');
    capture = await captureWithQuickChatChatGptContext(capture);
    hideLoading();
    setPreparationMode(false);
  }
  renderCaptureSource(capture);
  renderMessages();
  elements.composer.value = String(question || '');
  elements.composer.placeholder = 'Ask about this image…';
  resizeComposer();
  renderComposerSubmitAction();
  elements.composer.focus();
}

function handleImagePaste(event) {
  const file = clipboardImageFile(event.clipboardData);
  if (!file) return;
  event.preventDefault();
  const target = event.currentTarget;
  const question = target === elements['paste-selection']
    ? elements['paste-question'].value
    : target?.value || '';
  useImageFile(file, { question, pasted: true }).catch(showImageInputError);
}

async function copyCode(event) {
  return copyCodeBlock(event, (error) => showStatus(error.message, true));
}

function showPaste(source = activeSource) {
  resetConversation();
  pendingPasteSource = source;
  showHome();
  elements['paste-card'].hidden = false;
  elements['paste-selection'].value = source?.selection || '';
  elements['paste-question'].value = source?.question || '';
  elements['paste-selection'].focus();
}

async function explainPastedSelection() {
  const selection = elements['paste-selection'].value.trim();
  if (!selection) {
    showStatus('Paste the PDF selection first.', true);
    elements['paste-selection'].focus();
    return;
  }
  const question = elements['paste-question'].value.trim() || 'Explain this.';
  elements['paste-card'].hidden = true;
  await startContextChat({ source: pendingPasteSource || activeSource, question, selection });
}

async function useChosenPdf(file) {
  if (!pendingPdf || !file) return;
  try {
    assertPdfSize(file.size);
  } catch (error) {
    elements['pdf-fallback-message'].textContent = error.message;
    return;
  }
  elements['pdf-fallback'].hidden = true;
  showLoading('Opening selected PDF…', file.name);
  operationController = new AbortController();
  try {
    const source = { ...pendingPdf.source, pageTitle: file.name, sourceKind: 'pdf' };
    const nextCapture = await pdfCapture(source, { ...pendingPdf, pdfInput: file });
    await finalizePreparedChat(
      nextCapture,
      pendingPdf.question,
      pendingPdf.chatGptRefreshTask
    );
  } catch (error) {
    if (!operationController.signal.aborted) showPdfFallback(error, pendingPdf);
  }
}

async function useVisiblePdfPage() {
  if (!pendingPdf) return;
  const request = pendingPdf;
  elements['pdf-fallback'].hidden = true;
  showLoading('Capturing the visible PDF page…');
  try {
    const screenshot = request.imageDataUrl
      ? { imageDataUrl: request.imageDataUrl, ...request.source }
      : await message({ type: 'SCHOLIA_CAPTURE_ACTIVE_VISIBLE', expectedTabId: request.source.tabId });
    await finalizePreparedChat(baseCapture({ ...request.source, ...screenshot, sourceKind: 'pdf' }, {
      selection: request.selection,
      imageDataUrl: screenshot.imageDataUrl,
      contextNotice: 'Full PDF text was unavailable; using the visible PDF page as image context.',
      contextState: 'Visible page only'
    }), request.question, request.chatGptRefreshTask);
  } catch (error) {
    preparationError(error, request.source);
  }
}

function loadImage(dataUrl) {
  return new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error('Chrome returned an unreadable screenshot.'));
    image.src = dataUrl;
  });
}

function encodedCanvasWithinLimit(canvas, maxDataUrlCharacters = 7_600_000) {
  for (const quality of [0.78, 0.68, 0.56, 0.44]) {
    const encoded = canvas.toDataURL('image/jpeg', quality);
    if (encoded.length <= maxDataUrlCharacters) return encoded;
  }
  return '';
}

async function stitchDeepPageVisual(rawTiles, layout = {}) {
  const tiles = Array.from(rawTiles || [])
    .filter((tile) => /^data:image\//i.test(String(tile?.dataUrl || '')))
    .sort((left, right) => Number(left.scrollY) - Number(right.scrollY));
  if (!tiles.length) return '';
  const images = await Promise.all(tiles.map((tile) => loadImage(tile.dataUrl)));
  const first = images[0];
  const size = fullPageCanvasSize({
    ...layout,
    imageWidth: first.naturalWidth,
    imageHeight: first.naturalHeight
  });
  const canvas = document.createElement('canvas');
  canvas.width = size.width;
  canvas.height = size.height;
  const context = canvas.getContext('2d');
  if (!context) throw new Error('Full-page visual assembly is unavailable.');
  context.fillStyle = '#f2f3f0';
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = 'high';

  const viewportWidth = Math.max(1, Number(layout.viewportWidth) || first.naturalWidth);
  const cssScale = canvas.width / viewportWidth;
  for (const [index, tile] of tiles.entries()) {
    const image = images[index];
    const destinationY = Math.max(0, Math.round((Number(tile.scrollY) || 0) * cssScale));
    const destinationHeight = Math.max(1, Math.round(image.naturalHeight * canvas.width / image.naturalWidth));
    if (destinationY >= canvas.height) continue;
    const visibleHeight = Math.min(destinationHeight, canvas.height - destinationY);
    const sourceHeight = Math.max(1, Math.round(image.naturalHeight * visibleHeight / destinationHeight));
    context.drawImage(
      image,
      0,
      0,
      image.naturalWidth,
      sourceHeight,
      0,
      destinationY,
      canvas.width,
      visibleHeight
    );
  }

  let encoded = encodedCanvasWithinLimit(canvas);
  if (encoded) return encoded;
  const reduced = document.createElement('canvas');
  const reduction = Math.min(0.82, Math.sqrt(10_000_000 / Math.max(1, canvas.width * canvas.height)));
  reduced.width = Math.max(1, Math.floor(canvas.width * reduction));
  reduced.height = Math.max(1, Math.floor(canvas.height * reduction));
  const reducedContext = reduced.getContext('2d');
  if (!reducedContext) throw new Error('Full-page visual compression is unavailable.');
  reducedContext.imageSmoothingEnabled = true;
  reducedContext.imageSmoothingQuality = 'high';
  reducedContext.drawImage(canvas, 0, 0, reduced.width, reduced.height);
  encoded = encodedCanvasWithinLimit(reduced);
  if (!encoded) throw new Error('The complete-page visual is too large to attach safely.');
  return encoded;
}

function restoreAfterConversationCapture() {
  const session = captureSession;
  captureSession = null;
  hideLoading();
  setPreparationMode(false);
  if (!session?.appendToConversation) return false;
  renderCaptureSource(capture);
  renderMessages();
  elements.composer.value = session.questionDraft;
  resizeComposer();
  elements.composer.focus();
  return true;
}

function capturePreparationError(error, source) {
  if (captureSession?.appendToConversation) {
    restoreAfterConversationCapture();
    showImageInputError(error);
    persistCurrentChat().catch(() => {});
    return;
  }
  captureSession = null;
  preparationError(error, source);
}

function cancelRegionCapture() {
  if (restoreAfterConversationCapture()) return;
  startNewChat();
}

async function beginCapture(source = activeSource, { appendToConversation = false } = {}) {
  if (!source || captureSession) return;
  const append = Boolean(
    appendToConversation
    && capture
    && messages.some((entry) => entry.role === 'user')
  );
  if (append && streaming) return;
  const questionDraft = appendToConversation ? elements.composer.value : elements['context-question'].value;
  if (!append) resetConversation();
  const session = { appendToConversation: append, questionDraft };
  captureSession = session;
  showChat();
  setPreparationMode(true);
  if (!append) renderCaptureSource(baseCapture(source, { contextNotice: 'Select a region on the page.' }));
  showLoading('Drag over the page to select a region', 'Press Escape on the page to cancel.');
  try {
    const result = await message({ type: 'SCHOLIA_CAPTURE_ACTIVE_REGION', expectedTabId: source.tabId });
    if (captureSession !== session) return;
    if (!result) { cancelRegionCapture(); return; }
    if (append) {
      captureSession = null;
      hideLoading();
      setPreparationMode(false);
      renderCaptureSource(capture);
      setComposerImage(result.imageDataUrl, 'Captured screen region');
      elements.composer.value = questionDraft;
      resizeComposer();
      elements.composer.focus();
      return;
    }
    await startContextChat({
      source: { ...source, ...result },
      question: questionDraft,
      imageDataUrl: result.imageDataUrl,
      waitForQuestion: true
    });
  } catch (error) {
    if (captureSession !== session) return;
    capturePreparationError(error, source);
  }
}

async function consumePanelRequest(request) {
  if (embeddedPdfPanel) return;
  if (!request?.id || handledPanelRequests.has(request.id)) return;
  handledPanelRequests.add(request.id);
  await chrome.storage.session.remove(PANEL_REQUEST_KEY);
  if (Date.now() - Number(request.createdAt || 0) > 5 * 60_000) return;
  const source = {
    tabId: request.tabId,
    windowId: request.windowId,
    frameId: request.frameId,
    pageTitle: request.pageTitle,
    url: request.url,
    pdfUrl: request.pdfUrl,
    viewerSourceId: request.viewerSourceId || '',
    sourceKind: request.sourceKind || (request.pdfUrl ? 'pdf' : 'page')
  };
  if (request.mode === 'selection' && request.selection) {
    await startContextChat({ source, selection: request.selection, question: request.question || 'Explain this.' });
  } else if (request.mode === 'capture') {
    await beginCapture(source);
  } else {
    showPaste({ ...source, question: request.question || '' });
  }
}

async function consumePanelNavigation(navigation) {
  if (embeddedPdfPanel) return;
  if (!navigation?.id || handledNavigationRequests.has(navigation.id)) return;
  handledNavigationRequests.add(navigation.id);
  await chrome.storage.session.remove(PANEL_NAVIGATION_KEY);
  if (Date.now() - Number(navigation.createdAt || 0) > 5 * 60_000) return;
  if (navigation.view === 'chat' && navigation.chatId) {
    await restoreSavedChat(navigation.chatId);
  } else if (navigation.view === 'new') {
    startNewChat();
  } else {
    returnHome();
  }
}

elements['context-form'].addEventListener('submit', (event) => {
  event.preventDefault();
  const question = elements['context-question'].value.trim();
  if (!question) return;
  elements['context-question'].value = '';
  const siteWide = elements['site-scope'].checked;
  const deepPage = elements['deep-page'].checked && !siteWide;
  startContextChat({ source: { ...activeSource, followLinks: siteWide }, question, deepPage })
    .catch((error) => preparationError(error, activeSource));
});
elements['site-scope'].addEventListener('change', () => {
  if (elements['site-scope'].checked) elements['deep-page'].checked = false;
  renderContextHint();
});
elements['chat-follow-links'].addEventListener('click', () => {
  if (!capture || streaming || courseRetrieving || !contextEnabled) return;
  capture.followLinks = !capture.followLinks;
  renderResearchControls();
  persistCurrentChat().catch(() => {});
});
elements['chat-research-yolo'].addEventListener('click', () => {
  if (!capture || streaming || courseRetrieving) return;
  capture.researchYolo = !capture.researchYolo;
  renderResearchControls();
  persistCurrentChat().catch(() => {});
});
elements['research-approve'].addEventListener('click', () => {
  if (!researchReview) return;
  if (capture && elements['research-review-yolo'].checked) capture.researchYolo = true;
  researchReview.finish([...elements['research-review-sites'].querySelectorAll('input:checked')].map((input) => input.value));
});
elements['research-skip'].addEventListener('click', () => researchReview?.finish([]));
elements['deep-page'].addEventListener('change', () => {
  if (elements['deep-page'].checked) elements['site-scope'].checked = false;
  renderContextHint();
});
elements['context-question'].addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    elements['context-form'].requestSubmit();
  }
});
elements.capture.addEventListener('click', () => beginCapture(activeSource));
elements['choose-image'].addEventListener('click', () => openImagePicker(elements['context-question'].value));
elements['open-pdf-viewer'].addEventListener('click', async () => {
  elements['open-pdf-viewer'].disabled = true;
  showStatus('Opening selectable Scholia PDF view…');
  try {
    await message({ type: 'SCHOLIA_OPEN_PDF_VIEWER' });
    showStatus('Select text in the PDF to open Explain.');
  } catch (error) {
    showStatus(error.message, true);
    elements['open-pdf-viewer'].disabled = false;
  }
});
async function updateCourseIndex({ clear = false, chat = false } = {}) {
  const source = chat ? capture : activeSource;
  if (!source || courseRetrieving) return;
  const controller = new AbortController();
  courseController = controller;
  courseRetrieving = true;
  elements['course-index-refresh'].disabled = true;
  elements['course-index-clear'].disabled = true;
  elements['chat-course-refresh'].disabled = true;
  const status = elements['course-index-status'];
  status.textContent = clear ? 'Removing local course index…' : 'Checking Canvas course…';
  try {
    const index = await loadCanvasCourseIndex(source.url, {
      force: true, clear, signal: controller.signal,
      onProgress: (detail) => { status.textContent = detail; if (chat) showLoading('Updating Canvas course…', detail); }
    });
    status.textContent = clear ? 'Local course index removed.'
      : `${index.title} · ${index.documents.length} sources indexed · ${index.reused} unchanged${index.partial ? ' · Some sources unavailable or outside the index limit' : ''}${index.storageUnavailable ? ' · Could not save locally' : ''}`;
    showStatus(status.textContent);
  } catch (error) {
    if (!controller.signal.aborted) { status.textContent = error.message; showStatus(error.message, true); }
  } finally {
    if (courseController === controller) { courseController = null; courseRetrieving = false; hideLoading(); }
    elements['course-index-refresh'].disabled = false;
    elements['course-index-clear'].disabled = false;
    elements['chat-course-refresh'].disabled = false;
  }
}
elements['course-index-refresh'].addEventListener('click', () => updateCourseIndex());
elements['course-index-clear'].addEventListener('click', () => updateCourseIndex({ clear: true }));
elements['chat-course-refresh'].addEventListener('click', () => updateCourseIndex({ chat: true }));
let fileComposer;
fileComposer = mountFileComposer({
  button: elements['attach-files'], container: elements['composer-files'],
  dropTarget: document.body, pasteTarget: elements.composer,
  disabled: () => streaming || courseRetrieving || Boolean(operationController && elements['composer-form'].hidden),
  onChange: () => {
    if (!fileComposer) return;
    if (fileComposer.files.length && elements['chat-view'].hidden) {
      const files = fileComposer.files;
      const question = elements['context-question'].value;
      resetConversation();
      capture = baseCapture({ pageTitle: 'Attached files', sourceKind: 'files', url: '' }, { contextNotice: 'Files attached to this conversation.' });
      showChat();
      fileComposer.set(files);
      renderCaptureSource(capture);
      elements.composer.value = question;
    }
    if (fileComposer.options.imageDataUrl && composerImage) clearComposerImage();
    elements.composer.placeholder = composerPlaceholder();
    elements.send.disabled = fileComposer.busy && !courseRetrieving;
    renderComposerSubmitAction();
  }
});
let responseFiles;
responseFiles = mountFileComposer({
  button: elements['response-window-attach'], container: elements['response-window-files'],
  dropTarget: elements['response-window-backdrop'], pasteTarget: elements['response-window-composer'],
  disabled: () => !currentResponseWindow() || currentResponseWindow().streaming || currentResponseWindow().moving,
  onChange: () => { const state = currentResponseWindow(); if (state && responseFiles) state.files = responseFiles.files; }
});
elements['choose-files'].addEventListener('click', () => {
  const question = elements['context-question'].value;
  resetConversation();
  capture = baseCapture({ pageTitle: 'Attached files', sourceKind: 'files', url: '' }, { contextNotice: 'Files attached to this conversation.' });
  renderCaptureSource(capture);
  showChat();
  elements.composer.value = question;
  elements['attach-files'].click();
});
elements['attach-region'].addEventListener('click', () => beginCapture(activeSource, { appendToConversation: true }));

elements['back-home'].addEventListener('click', returnHome);
elements['expand-chat'].addEventListener('click', expandCurrentChat);
elements['chat-search-toggle'].addEventListener('click', () => {
  if (elements['chat-search'].hidden) openChatSearch();
  else closeChatSearch();
});
elements['chat-search-input'].addEventListener('input', () => {
  updateChatSearch({ resetActive: true, reveal: true });
});
elements['chat-search-input'].addEventListener('keydown', (event) => {
  if (event.key === 'Escape') {
    event.preventDefault();
    closeChatSearch();
  } else if (event.key === 'Enter' && !event.isComposing) {
    event.preventDefault();
    moveChatSearch(event.shiftKey ? -1 : 1);
  }
});
elements['chat-search-previous'].addEventListener('click', () => moveChatSearch(-1));
elements['chat-search-next'].addEventListener('click', () => moveChatSearch(1));
elements['chat-search-close'].addEventListener('click', () => closeChatSearch());
elements['new-chat'].addEventListener('click', startNewChat);
elements['chat-current-tab'].addEventListener('click', startNewChat);
elements['bridge-start'].addEventListener('click', startBridge);
elements['bridge-copy'].addEventListener('click', () => {
  if (!bridgeStatus?.command) return;
  copyText(bridgeStatus.command, { root })
    .then(() => { elements['bridge-status'].textContent = 'Start command copied. Waiting for the bridge…'; })
    .catch((error) => { elements['bridge-status'].textContent = error.message; });
});
window.addEventListener('focus', refreshBridgeStatus);
window.addEventListener('pagehide', () => {
  cancelRequest();
  operationController?.abort();
  closeResponseWindow({ restoreFocus: false, all: true });
  clearTimeout(bridgeWatchTimer);
  bridgeStatusRequest += 1;
});
document.addEventListener('visibilitychange', () => {
  if (!dedicatedChatPage && ownerDocument.hidden) { cancelRequest(); operationController?.abort(); }
});
elements.settings.addEventListener('click', () => chrome.runtime.openOptionsPage());
elements['model-settings'].addEventListener('click', () => chrome.runtime.openOptionsPage());
for (const select of [elements['model-select'], elements['chat-model-select']]) {
  select.addEventListener('scholia-model-picker-open', () => {
    for (const provider of ['codex', 'opencode']) {
      void message({ type: 'SCHOLIA_BRIDGE_STATUS', provider, timeoutMs: 1000 }).catch(() => {});
    }
  });
}
elements['model-select'].addEventListener('change', () => saveInlineModel());
elements['reasoning-select'].addEventListener('change', () => saveInlineModel({ reasoningEffort: elements['reasoning-select'].value }));
elements['chat-reasoning-select'].addEventListener('change', () => saveInlineModel({
  select: elements['chat-model-select'], reasoningEffort: elements['chat-reasoning-select'].value
}));
elements['context-mode'].addEventListener('change', () => {
  if (elements['context-mode'].checked) setContextMode(CONTEXT_MODE_COMPACT);
});
elements['context-full'].addEventListener('change', () => {
  if (elements['context-full'].checked) setContextMode(CONTEXT_MODE_FULL);
});
elements['context-none'].addEventListener('change', () => {
  if (elements['context-none'].checked) setContextMode(CONTEXT_MODE_NONE);
});
elements['fast-mode'].addEventListener('click', () => saveInlineModel({ fastMode: !settings?.fastMode }));
elements['web-search'].addEventListener('click', toggleWebSearch);
elements['learning-mode'].addEventListener('click', toggleLearningMode);
elements['chat-model-select'].addEventListener('change', () => saveInlineModel({ select: elements['chat-model-select'] }));
elements['chat-context-mode'].addEventListener('click', () => setContextMode(CONTEXT_MODE_COMPACT));
elements['chat-context-full'].addEventListener('click', () => setContextMode(CONTEXT_MODE_FULL));
elements['chat-context-none'].addEventListener('click', () => setContextMode(CONTEXT_MODE_NONE));
elements['chat-fast-mode'].addEventListener('click', () => saveInlineModel({
  select: elements['chat-model-select'], fastMode: !settings?.fastMode
}));
elements['chat-web-search'].addEventListener('click', toggleWebSearch);
elements['chat-learning-mode'].addEventListener('click', toggleLearningMode);
elements['chat-history-list'].addEventListener('click', (event) => {
  const remove = event.target.closest?.('[data-delete-chat]');
  if (remove) {
    removeSavedChat(remove.dataset.deleteChat).catch((error) => showStatus(error.message, true));
    return;
  }
  const open = event.target.closest?.('[data-open-chat]');
  if (open) restoreSavedChat(open.dataset.openChat).catch((error) => showStatus(error.message, true));
});
elements['clear-chats'].addEventListener('click', () => clearSavedChats().catch((error) => showStatus(error.message, true)));
elements.explain.addEventListener('click', async () => {
  showStatus('Opening the current selection…');
  try {
    const result = await message({ type: 'SCHOLIA_PANEL_COMMAND', command: 'SCHOLIA_EXPLAIN_CURRENT' });
    if (result.surface === 'page') showStatus('The explanation opened next to the selection.');
  } catch (error) { showStatus(error.message, true); }
});
elements['site-toggle'].addEventListener('click', async () => {
  if (!activeSite) return;
  elements['site-toggle'].disabled = true;
  try {
    activeSite = await message({ type: 'SCHOLIA_SET_ACTIVE_SITE_ENABLED', enabled: !activeSite.enabled });
    renderSite();
    showStatus(siteStatusText(activeSite));
  } catch (error) { showStatus(error.message, true); }
  finally { elements['site-toggle'].disabled = false; }
});
elements['paste-start'].addEventListener('click', explainPastedSelection);
elements['paste-cancel'].addEventListener('click', () => { elements['paste-card'].hidden = true; });
elements['choose-pdf'].addEventListener('click', () => elements['pdf-file'].click());
elements['pdf-file'].addEventListener('change', () => {
  const [file] = elements['pdf-file'].files || [];
  useChosenPdf(file).finally(() => { elements['pdf-file'].value = ''; });
});
elements['image-file'].addEventListener('change', () => {
  const [file] = elements['image-file'].files || [];
  const question = imageQuestionDraft;
  useImageFile(file, { question }).catch(showImageInputError).finally(() => {
    elements['image-file'].value = '';
    imageQuestionDraft = '';
  });
});
elements['use-visible'].addEventListener('click', useVisiblePdfPage);
elements.messages.addEventListener('click', (event) => {
  const edit = event.target.closest?.('[data-edit-query]');
  if (edit) { beginQueryEdit(Number(edit.dataset.editQuery)); return; }
  const save = event.target.closest?.('[data-save-query-edit]');
  if (save) { saveQueryEdit(Number(save.dataset.saveQueryEdit)); return; }
  const cancel = event.target.closest?.('[data-cancel-query-edit]');
  if (cancel) { cancelQueryEdit(); return; }
  copyCode(event);
});
elements.messages.addEventListener('keydown', (event) => {
  const editor = event.target.closest?.('[data-query-editor]');
  if (!editor) return;
  if (event.key === 'Escape') {
    event.preventDefault();
    cancelQueryEdit();
  } else if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    saveQueryEdit(Number(editor.dataset.queryEditor));
  }
});
elements.messages.addEventListener('pointerup', scheduleResponseSelectionInspection);
elements.messages.addEventListener('scroll', hideResponseExplain, { passive: true });
window.addEventListener('resize', hideResponseExplain);
document.addEventListener('selectionchange', scheduleResponseSelectionInspection);
document.addEventListener('pointerdown', (event) => {
  if (!elements['response-explain'].hidden && !elements['response-explain'].contains(event.target)) hideResponseExplain();
}, true);
elements['response-explain'].addEventListener('pointerdown', (event) => {
  responseExplainPointerInteraction = true;
  event.stopPropagation();
});
const finishResponseExplainPointerInteraction = () => {
  setTimeout(() => { responseExplainPointerInteraction = false; }, 50);
};
elements['response-explain'].addEventListener('pointerup', finishResponseExplainPointerInteraction);
elements['response-explain'].addEventListener('pointercancel', finishResponseExplainPointerInteraction);
elements['response-explain-send'].addEventListener('click', explainResponseSelection);
elements['response-explain-cancel'].addEventListener('click', hideResponseExplain);
elements['response-explain-question'].addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    explainResponseSelection();
  } else if (event.key === 'Escape') {
    event.preventDefault();
    hideResponseExplain();
  }
});
elements['response-window-close'].addEventListener('click', () => closeResponseWindow());
elements['response-window-move'].addEventListener('click', moveResponseWindowToChat);
elements['response-window-web-search'].addEventListener('click', () => {
  const state = currentResponseWindow();
  if (!state || !providerSupportsWebSearch(settings?.provider)) return;
  state.webSearchEnabled = !state.webSearchEnabled;
  renderWebSearchControls();
});
elements['response-window-backdrop'].addEventListener('pointerdown', (event) => {
  if (event.target === elements['response-window-backdrop']) closeResponseWindow();
});
elements['response-window-messages'].addEventListener('click', (event) => {
  const edit = event.target.closest?.('[data-edit-query]');
  if (edit) { beginResponseQueryEdit(Number(edit.dataset.editQuery)); return; }
  const save = event.target.closest?.('[data-save-query-edit]');
  if (save) { saveResponseQueryEdit(Number(save.dataset.saveQueryEdit)); return; }
  const cancel = event.target.closest?.('[data-cancel-query-edit]');
  if (cancel) { cancelResponseQueryEdit(); return; }
  copyCode(event);
});
elements['response-window-messages'].addEventListener('keydown', (event) => {
  const editor = event.target.closest?.('[data-query-editor]');
  if (!editor) return;
  if (event.key === 'Escape') {
    event.preventDefault();
    cancelResponseQueryEdit();
  } else if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    saveResponseQueryEdit(Number(editor.dataset.queryEditor));
  }
});
elements['response-window-messages'].addEventListener('pointerup', scheduleResponseSelectionInspection);
elements['response-window-messages'].addEventListener('scroll', () => {
  const state = currentResponseWindow();
  if (state) state.scrollTop = elements['response-window-messages'].scrollTop;
  hideResponseExplain();
}, { passive: true });
elements['response-window-composer'].addEventListener('input', () => {
  const state = currentResponseWindow();
  if (state) state.draft = elements['response-window-composer'].value;
  resizeResponseWindowComposer();
});
elements['response-window-composer'].addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    elements['response-window-form'].requestSubmit();
  }
});
elements['response-window-form'].addEventListener('submit', (event) => {
  event.preventDefault();
  if (currentResponseWindow()?.moving || responseFiles.busy) return;
  if (currentResponseWindow()?.streaming) { cancelResponseWindowRequest(); return; }
  const question = elements['response-window-composer'].value.trim() || (responseFiles.files.length ? 'Explain the attached files.' : '');
  if (!question) return;
  elements['response-window-composer'].value = '';
  currentResponseWindow().draft = '';
  resizeResponseWindowComposer();
  askResponseWindow(question);
});
document.addEventListener('keydown', (event) => {
  if (event.defaultPrevented) return;
  if (isQuickChatShortcut(event)) {
    event.preventDefault();
    if (dedicatedChatPage || embeddedPdfPanel) {
      startNewChat();
    } else {
      window.close();
    }
  } else if ((event.metaKey || event.ctrlKey)
      && !event.altKey
      && event.key.toLowerCase() === 'f'
      && !elements['chat-view'].hidden
      && elements['response-window-backdrop'].hidden) {
    event.preventDefault();
    openChatSearch();
  } else if (event.key === 'Escape' && !elements['response-window-backdrop'].hidden) {
    event.preventDefault();
    closeResponseWindow();
  } else if (event.key === 'Escape' && embeddedPdfPanel && elements['chat-search'].hidden) {
    event.preventDefault();
    cancelRequest();
    operationController?.abort();
    close();
  } else if (event.key === 'Escape' && !elements['chat-search'].hidden) {
    event.preventDefault();
    closeChatSearch();
  }
});

chrome.runtime.onMessage.addListener((request, _sender, sendResponse) => {
  if (dedicatedChatPage || embeddedPdfPanel) return false;
  if (request?.type === 'SCHOLIA_PROBE_QUICK_CHAT_PANEL') {
    sendResponse({ open: true });
    return false;
  }
  if (request?.type !== 'SCHOLIA_CLOSE_QUICK_CHAT_PANEL') return false;
  cancelRequest();
  operationController?.abort();
  sendResponse({ closed: true });
  queueMicrotask(() => window.close());
  return false;
});
elements['composer-selection-clear'].addEventListener('click', () => {
  clearComposerSelection({ removeEmbeddedSource: true });
  clearPageSelection(capture);
});
elements['composer-image-clear'].addEventListener('click', () => {
  clearComposerImage();
  elements.composer.focus();
});
elements.composer.addEventListener('input', () => {
  resizeComposer();
  renderComposerSubmitAction();
});
[elements['context-question'], elements['paste-selection'], elements['paste-question']]
  .forEach((element) => element.addEventListener('paste', handleImagePaste));
elements.composer.addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    elements['composer-form'].requestSubmit();
  }
});
elements['composer-form'].addEventListener('submit', (event) => {
  event.preventDefault();
  if (streaming || courseRetrieving) { cancelRequest(); return; }
  if (fileComposer.busy || courseRetrieving) return;
  const question = elements.composer.value.trim()
    || (fileComposer.files.length ? 'Explain the attached files.' : canExplainCaptureDirectly() ? DEFAULT_IMAGE_EXPLANATION : '');
  if (!question) return;
  elements.composer.value = '';
  resizeComposer();
  ask(question);
});

mountResponseLanguage({ root, message, onSettings: (value) => { settings = value; renderChatOptionsSummary(); }, onError: (error) => showStatus(error.message, true) });

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && (changes[SETTINGS_KEY] || changes[RECENT_MODELS_KEY])) refreshSettings().catch(() => {});
  if (area === 'local' && changes[CHAT_HISTORY_KEY]) {
    refreshChatHistory().catch(() => {});
    syncCurrentChatFromHistory().catch(() => {});
  }
  if (area === 'session' && changes[PANEL_REQUEST_KEY]?.newValue) {
    consumePanelRequest(changes[PANEL_REQUEST_KEY].newValue).catch((error) => preparationError(error, activeSource));
  }
  const activeSelectionKey = area === 'session'
    ? pageSelectionStorageKey(activeSource?.tabId)
    : '';
  if (activeSelectionKey && changes[activeSelectionKey]?.newValue) {
    consumeSyncedPageSelection(changes[activeSelectionKey].newValue).catch((error) => showStatus(error.message, true));
  }
  if (area === 'session' && changes[PANEL_NAVIGATION_KEY]?.newValue) {
    consumePanelNavigation(changes[PANEL_NAVIGATION_KEY].newValue).catch((error) => showStatus(error.message, true));
  }
});

function scheduleTabRefresh() {
  clearTimeout(tabRefreshTimer);
  tabRefreshTimer = setTimeout(() => {
    refreshActiveSource().then(refreshActiveSelection).catch(() => {});
  }, 120);
}
chrome.tabs.onActivated.addListener(() => {
  if (!embeddedPdfPanel) scheduleTabRefresh();
});
chrome.tabs.onUpdated.addListener((tabId, changeInfo) => {
  if (tabId === activeSource?.tabId && (changeInfo.status === 'complete' || changeInfo.url)) scheduleTabRefresh();
});

async function boot() {
  renderMessages();
  renderComposerSelection();
  try {
    await Promise.all([refreshSettings(), refreshActiveSource(), refreshChatHistory(), restoreLearningMode()]);
  } catch (error) {
    showStatus(error.message, true);
  }
  if (dedicatedChatPage || embeddedPdfPanel) {
    const chatId = initialChatId || dedicatedChatId(location.href);
    if (chatId) {
      await restoreSavedChat(chatId);
      return;
    }
    if (dedicatedChatPage) {
      showHome();
      return;
    }
    // PDF panels belong to their containing tab, not the browser-wide request queue.
    await refreshActiveSelection();
    return;
  }
  const pending = await chrome.storage.session.get([PANEL_REQUEST_KEY, PANEL_NAVIGATION_KEY]);
  if (pending[PANEL_REQUEST_KEY]) await consumePanelRequest(pending[PANEL_REQUEST_KEY]);
  else if (pending[PANEL_NAVIGATION_KEY]) await consumePanelNavigation(pending[PANEL_NAVIGATION_KEY]);
  else await refreshActiveSelection();
}

const ready = boot().catch((error) => showStatus(error.message, true));
return {
  ready,
  async sendEntirePDF(source) {
    await ready;
    if (streaming || courseRetrieving) throw new Error('Wait for the current answer to finish before sending the entire PDF.');
    const question = elements.composer.value.trim() || elements['context-question'].value.trim() || ENTIRE_PDF_QUESTION;
    if (capture && !sameSource(capture, source)) resetConversation();
    contextEnabled = true;
    compactContextEnabled = false;
    capture = { ...baseCapture(source, { context: source.context, contextState: source.summary,
      contextNotice: 'Every page’s extracted text is included. Images and diagrams are included only when attached.' }),
      entirePDF: true, pdfIndexStage: 'complete' };
    renderCaptureSource(capture);
    renderContextControls();
    setPreparationMode(false);
    showChat();
    elements.composer.value = '';
    elements['context-question'].value = '';
    resizeComposer();
    await ask(question);
  },
  stop() { cancelRequest(); operationController?.abort(); closeResponseWindow({ restoreFocus: false, all: true }); },
  async openChat(chatId) { await ready; await historyWrite.catch(() => {}); await restoreSavedChat(chatId); },
  async resetSource() { await ready; await historyWrite.catch(() => {}); resetConversation(); await refreshActiveSource(); showHome(); }
};
}

if (globalThis.document?.querySelector('.shell') && !globalThis.document?.getElementById('pdf-chat')) {
  mountChatPanel();
}
