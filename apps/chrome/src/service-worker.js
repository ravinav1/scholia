import { ownChatHistoryMutations, mutateChatHistory } from './chat-history.js';
ownChatHistoryMutations();

import { panelSourceTab } from './panel-source.js';
import {
  DEFAULT_SETTINGS,
  SETTINGS_KEY,
  mergeSettings,
  normalizeSiteKey,
  providerById,
  publicSettings,
  resolveModelId,
  siteIsEnabled
} from '../../../packages/core/src/providers.js';
import { checkBridgeStatus, discoverCodexModels, discoverOpencodeModels, runCompletion } from './provider-runtime.js';
import { RECENT_MODELS_KEY, recordRecentModel } from '../../../packages/core/src/recent-models.js';
import { openExplanationChat } from './explanation-chat.js';
import { pdfWrapperDownloadUrl } from './pdf-context.js';
import { forwardOcrRequest } from './ocr-broker.js';
import { pdfMimeHandlerEnabled, pdfMimeHandlerFrameId } from './pdf-mime-handler.js';
import {
  loadPdfSourceRecord,
  prunePdfSourceRecords,
  storePdfSourceRecord
} from './pdf-source-store.js';
import {
  loadLocalPdfFileRecord,
  localPdfFileSource,
  pruneLocalPdfFileHandles
} from './pdf-local-file-store.js';
import { restoredPdfTabTarget } from './pdf-tab-restore.js';
import {
  chatGptMemoryLooksLikePersonalizationPage,
  isChatGptWebUrl
} from '../../../packages/core/src/chatgpt-context.js';
import {
  chatGptMemoryTextIsUsable,
  chatGptPersonalizationUrl,
  chatGptProjectIdentity,
  requestChatGptWebStateWithInjection
} from './chatgpt-web.js';
import {
  chatGptContextAfterMemoryRefresh,
  chatGptQuickChatRefreshDecision
} from './chatgpt-refresh.js';
import {
  CHATGPT_CONTEXT_REFRESH_ALARM,
  chatGptContextRefreshAlarmSchedule
} from './chatgpt-refresh-schedule.js';
import {
  contentFrameTarget,
  isCompletedPdfNavigation,
  isLikelyPdfTab,
  isPdfUrl,
  manualPdfSourceUrl,
  PAGE_SELECTION_KEY,
  pageSelectionStorageKey,
  PANEL_NAVIGATION_KEY,
  PANEL_REQUEST_KEY,
  pdfSourceStorageKey,
  pdfViewerSourceId,
  pdfViewerTabSourceId,
  preferredContentFrameId,
  safeSourceUrl,
  sendContentFrameMessage,
  tabSource
} from './tab-context.js';
import {
  COMPACT_PACKED_CONTEXT_CHARS,
  MAX_PACKED_CONTEXT_CHARS,
  packPageContext
} from '../../../packages/core/src/context.js';
import {
  packCompactBrowserWorkspace,
  rankRelatedTabs
} from './browser-workspace-context.js';
import { embeddedFrameContext, MAX_DEEP_PAGE_TILES } from './deep-page.js';
import { MAX_MAIL_THREAD_CONTEXT_CHARACTERS } from './mail-context.js';
import { researchUrl } from './research-links.js';
import { configurePdfMimeHandling } from './browser-compat.js';
import { nativePdfProgressFromScriptResults } from './pdf-progress.js';
import {
  closeQuickChatFromSignal,
  toggleQuickChatFromCommandTab
} from './browser-commands.js';

const MENU_EXPLAIN = 'scholia-explain-selection';
const MENU_CAPTURE = 'scholia-capture-region';
const MAX_MENU_SELECTION_LENGTH = 12_000;
const PAGE_SELECTION_MAX_AGE = 10 * 60_000;
const PDF_NATIVE_HANDOFF_DELAY = 300;
const pdfRoutingTabs = new Set();
const nativePdfBypass = new Map();
const pendingPdfHandoffs = new Map();
const stagedPdfSources = new Map();
const newlyCreatedTabs = new Set();
const mimePdfTabs = new Map();
let automaticChatGptRefreshTask = null;
const modelDiscoveryTasks = new Map();
let modelCatalogWrite = Promise.resolve();
const MODEL_CATALOG_TTL = 2 * 60_000;
const DEEP_PAGE_CAPTURE_INTERVAL_MS = 540;

configurePdfMimeHandling().catch(() => {});

async function loadSettings() {
  const stored = await chrome.storage.local.get([SETTINGS_KEY, RECENT_MODELS_KEY]);
  const source = stored[SETTINGS_KEY] || DEFAULT_SETTINGS;
  const merged = mergeSettings({ ...source, recentModels: stored[RECENT_MODELS_KEY] || source.recentModels });
  // Prompt-time normalization already fails closed. Persist this migration as
  // well so an old Personalization-page scrape cannot reappear after another
  // extension surface edits otherwise unrelated settings.
  if (chatGptMemoryLooksLikePersonalizationPage(source?.chatgptWebContext?.memory)) {
    await chrome.storage.local.set({ [SETTINGS_KEY]: merged }).catch(() => {});
  }
  return merged;
}

// A separate key and queue keep concurrent chat completions from losing history
// or overwriting credentials/settings saved while a response was in flight.
let recentModelWrite = Promise.resolve();
function rememberModelUse(provider, model) {
  recentModelWrite = recentModelWrite.catch(() => {}).then(async () => {
    const stored = await chrome.storage.local.get(RECENT_MODELS_KEY);
    await chrome.storage.local.set({ [RECENT_MODELS_KEY]: recordRecentModel(stored[RECENT_MODELS_KEY], provider, model) });
  });
  return recentModelWrite;
}

async function saveSettings(settings) {
  const merged = mergeSettings(settings);
  await chrome.storage.local.set({ [SETTINGS_KEY]: merged });
  await syncChatGptContextRefreshAlarm(merged);
  return merged;
}

async function syncChatGptContextRefreshAlarm(settings = null) {
  if (!chrome.alarms) return;
  const resolvedSettings = settings || await loadSettings();
  const schedule = chatGptContextRefreshAlarmSchedule(
    resolvedSettings.chatgptWebContext
  );
  await chrome.alarms.clear(CHATGPT_CONTEXT_REFRESH_ALARM);
  if (schedule) chrome.alarms.create(CHATGPT_CONTEXT_REFRESH_ALARM, schedule);
}

async function refreshModelCatalog(providerId, settings, { force = false, timeoutMs } = {}) {
  const checkedAt = Number(settings.modelCatalogCheckedAt?.[providerId] || 0);
  const cachedModels = settings.discoveredModels?.[providerId] || [];
  const hasLegacyTruncatedCatalog = providerId === 'opencode' && cachedModels.length >= 2_000;
  if (!force && !hasLegacyTruncatedCatalog && Date.now() - checkedAt < MODEL_CATALOG_TTL) return settings;
  if (modelDiscoveryTasks.has(providerId)) return modelDiscoveryTasks.get(providerId);
  const task = (async () => {
    const attemptedAt = Date.now();
    let discovered = null;
    try {
      discovered = providerId === 'codex'
        ? await discoverCodexModels(settings, { timeoutMs: 15_000 })
        : await discoverOpencodeModels(settings, { timeoutMs: timeoutMs || 1_800 });
    } catch {}
    modelCatalogWrite = modelCatalogWrite.catch(() => {}).then(async () => {
      const current = await loadSettings();
      if (current.endpoints[providerId] !== settings.endpoints[providerId]) return current;
      current.modelCatalogCheckedAt[providerId] = attemptedAt;
      if (discovered?.models?.length) current.discoveredModels[providerId] = discovered.models;
      else if (hasLegacyTruncatedCatalog) delete current.discoveredModels[providerId];
      return saveSettings(current);
    });
    return modelCatalogWrite;
  })();
  modelDiscoveryTasks.set(providerId, task);
  try { return await task; }
  finally { if (modelDiscoveryTasks.get(providerId) === task) modelDiscoveryTasks.delete(providerId); }
}

async function bridgeStatusWithModelCatalog(providerId, settings, options) {
  const status = await checkBridgeStatus(providerId, settings, options);
  if (!status.up || !['codex', 'opencode'].includes(providerId)) return status;
  // Discovery is independent of the fast health check. Storage events update
  // an open picker when a new catalog arrives, without delaying chat startup.
  void refreshModelCatalog(providerId, settings, {
    force: options?.refreshModels === true, timeoutMs: options?.timeoutMs
  }).catch(() => {});
  return { ...status, models: settings.discoveredModels[providerId] || [] };
}

async function installMenus() {
  await chrome.contextMenus.removeAll();
  chrome.contextMenus.create({ id: MENU_EXPLAIN, title: 'Explain with Scholia', contexts: ['selection'] });
  chrome.contextMenus.create({ id: MENU_CAPTURE, title: 'Ask Scholia about a screen region', contexts: ['page', 'selection', 'image'] });
}

chrome.runtime.onInstalled.addListener(() => {
  Promise.all([
    configurePdfMimeHandling(),
    installMenus(),
    maintainPdfSourceStorage(),
    restoreOpenPdfViewerTabs(),
    syncChatGptContextRefreshAlarm()
  ]).catch(console.error);
});

chrome.runtime.onStartup.addListener(() => {
  Promise.all([
    configurePdfMimeHandling(),
    maintainPdfSourceStorage(),
    restoreOpenPdfViewerTabs(),
    syncChatGptContextRefreshAlarm()
  ]).catch(() => {});
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name !== CHATGPT_CONTEXT_REFRESH_ALARM) return;
  refreshChatGptContextForQuickChat().catch(() => {});
});

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id) throw new Error('No active page is available.');
  return tab;
}

async function storedPdfSource(sourceId) {
  const stored = await loadPdfSourceRecord({
    session: chrome.storage.session,
    local: chrome.storage.local
  }, sourceId);
  if (stored) return stored;
  const localFile = await loadLocalPdfFileRecord(sourceId);
  return localFile ? localPdfFileSource(localFile) : null;
}

async function maintainPdfSourceStorage() {
  const tabs = await chrome.tabs.query({});
  const protectedSourceIds = tabs.map(pdfViewerTabSourceId).filter(Boolean);
  const [sourceRecords, localHandles] = await Promise.all([
    prunePdfSourceRecords(chrome.storage, protectedSourceIds),
    pruneLocalPdfFileHandles()
  ]);
  return sourceRecords + localHandles;
}

function pdfTitleFromAddress(value) {
  try {
    const url = new URL(value);
    const encodedName = url.pathname.split('/').filter(Boolean).at(-1) || '';
    let name = encodedName;
    try { name = decodeURIComponent(encodedName); } catch {}
    return name.replace(/\.pdf$/i, '').trim().slice(0, 500) || url.hostname || 'PDF document';
  } catch {
    return 'PDF document';
  }
}

async function createPdfViewerSource({ pdfUrl, url = '', pageTitle = '', nativeViewportProgress = null }) {
  const id = crypto.randomUUID();
  const record = await storePdfSourceRecord({
    session: chrome.storage.session,
    local: chrome.storage.local
  }, {
    id,
    createdAt: Date.now(),
    accessedAt: Date.now(),
    pdfUrl,
    url: url || safeSourceUrl(pdfUrl),
    pageTitle: pageTitle || pdfTitleFromAddress(pdfUrl),
    nativeViewportProgress
  });
  maintainPdfSourceStorage().catch(() => {});
  return {
    ...record,
    viewerUrl: chrome.runtime.getURL(`pdf-viewer.html?source=${encodeURIComponent(id)}`)
  };
}

async function currentNativePdfViewportProgress(tabId) {
  if (!Number.isInteger(tabId) || !chrome.scripting?.executeScript) return null;
  try {
    const results = await chrome.scripting.executeScript({
      target: { tabId, allFrames: true },
      func: () => {
        const plugin = document.querySelector('embed[type="application/x-google-chrome-pdf"]');
        if (!plugin) return null;
        const root = document.documentElement;
        const body = document.body;
        const height = Math.max(
          root?.scrollHeight || 0,
          body?.scrollHeight || 0,
          document.querySelector('#sizer')?.getBoundingClientRect().height || 0
        );
        if (!Number.isFinite(height) || height <= 0) return null;
        const center = Math.max(0, Math.min(height, window.scrollY + window.innerHeight / 2));
        return { nativePdfViewer: true, progress: center / height };
      }
    });
    return nativePdfProgressFromScriptResults(results);
  } catch {
    return null;
  }
}

async function createManualPdfViewerSource(value) {
  const pdfUrl = manualPdfSourceUrl(value);
  if (!pdfUrl) {
    throw new Error('Enter an HTTP, HTTPS, or file PDF address without embedded credentials.');
  }
  const site = siteKey(pdfUrl);
  if (site) {
    const settings = await loadSettings();
    if (!siteIsEnabled(settings, site)) {
      throw new Error(settings.siteAccessMode === 'allowlist'
        ? 'This PDF site is not whitelisted in Scholia settings.'
        : 'Scholia is disabled on this PDF site.');
    }
  }
  return createPdfViewerSource({ pdfUrl });
}

async function resolvedTabSource(tab = {}, info = {}) {
  const source = tabSource(tab, info);
  if (!source.viewerSourceId) return source;
  const stored = await storedPdfSource(source.viewerSourceId);
  if (!stored) return source;
  return {
    ...source,
    pageTitle: stored.pageTitle || source.pageTitle,
    url: stored.url || safeSourceUrl(stored.pdfUrl),
    pdfUrl: stored.pdfUrl || '',
    sourceKind: 'pdf',
    viewerSourceId: source.viewerSourceId,
    fileHandleId: stored.fileHandleId || ''
  };
}

async function ensureTabIsEnabled(tab, info = {}) {
  const source = await resolvedTabSource(tab, info);
  const site = siteKey(source.pdfUrl || source.url || tab.url || '');
  if (!site) return source;
  const settings = await loadSettings();
  if (!siteIsEnabled(settings, site)) {
    throw new Error(settings.siteAccessMode === 'allowlist'
      ? 'This site is not whitelisted. Add it from the side panel first.'
      : 'Scholia is disabled on this site. Re-enable it from the side panel first.');
  }
  return source;
}

async function openPdfViewer(tab) {
  if (!tab?.id) throw new Error('No PDF tab is available.');
  cancelPendingPdfHandoff(tab.id);
  const source = await ensureTabIsEnabled(tab);
  if (source.viewerSourceId) return source;
  if (source.sourceKind !== 'pdf' || !source.pdfUrl) throw new Error('The current tab is not a readable PDF.');

  if (await pdfMimeHandlerEnabled()) {
    const frameId = await activeMimePdfFrameId(tab.id);
    if (Number.isInteger(frameId)) return activeMimePdfSource(source, tab, frameId);
    await chrome.tabs.update(tab.id, { url: source.pdfUrl });
    return source;
  }

  const stagedCandidate = stagedPdfSources.get(tab.id);
  const stagedSource = stagedCandidate && Date.now() - stagedCandidate.createdAt <= 30_000
    ? stagedCandidate
    : null;
  if (!stagedSource) stagedPdfSources.delete(tab.id);
  const nativeViewportProgress = await currentNativePdfViewportProgress(tab.id);
  const record = await createPdfViewerSource({
    pdfUrl: source.pdfUrl,
    url: stagedSource?.url || source.url || safeSourceUrl(source.pdfUrl),
    pageTitle: stagedSource?.pageTitle || source.pageTitle || 'PDF document',
    nativeViewportProgress
  });
  const viewerUrl = record.viewerUrl;
  pdfRoutingTabs.add(tab.id);
  try {
    await chrome.tabs.update(tab.id, { url: viewerUrl });
  } catch (error) {
    const key = pdfSourceStorageKey(record.id);
    await Promise.all([
      chrome.storage.session.remove(key).catch(() => {}),
      chrome.storage.local.remove(key).catch(() => {})
    ]);
    throw error;
  } finally {
    pdfRoutingTabs.delete(tab.id);
    stagedPdfSources.delete(tab.id);
  }
  return { ...source, url: record.url, pageTitle: record.pageTitle, viewerSourceId: record.id, viewerUrl };
}

async function openNativePdf(tab) {
  const source = await resolvedTabSource(tab);
  if (!source.viewerSourceId || !source.pdfUrl) throw new Error('The original PDF address is no longer available.');
  nativePdfBypass.set(tab.id, { url: source.pdfUrl, expiresAt: Date.now() + 15_000 });
  await chrome.tabs.update(tab.id, { url: source.pdfUrl });
  return { url: source.url };
}

async function restorePdfViewerTab(tab) {
  // Keep standalone readers (and their saved page) in place. Returning them to
  // the original URL is only useful when a registered MIME handler owns it.
  if (!await pdfMimeHandlerEnabled()) return false;
  const target = await restoredPdfTabTarget(tab, storedPdfSource);
  if (!target) return false;

  cancelPendingPdfHandoff(tab.id);
  nativePdfBypass.set(tab.id, { url: target.url, expiresAt: Date.now() + 60_000 });
  pdfRoutingTabs.add(tab.id);
  try {
    await chrome.tabs.update(tab.id, { url: target.url });
  } finally {
    pdfRoutingTabs.delete(tab.id);
  }
  return true;
}

async function restoreOpenPdfViewerTabs() {
  const tabs = await chrome.tabs.query({});
  const viewerTabs = tabs.filter((tab) => pdfViewerTabSourceId(tab));
  const results = await Promise.allSettled(viewerTabs.map(restorePdfViewerTab));
  return results.filter((result) => result.status === 'fulfilled' && result.value).length;
}

function bypassesPdfViewer(tabId) {
  const bypass = nativePdfBypass.get(tabId);
  if (!bypass) return false;
  if (bypass.expiresAt < Date.now()) {
    nativePdfBypass.delete(tabId);
    return false;
  }
  return true;
}

function cancelPendingPdfHandoff(tabId) {
  const timer = pendingPdfHandoffs.get(tabId);
  if (timer) clearTimeout(timer);
  pendingPdfHandoffs.delete(tabId);
}

async function activeMimePdfFrameId(tabId) {
  const cached = mimePdfTabs.get(tabId);
  if (Number.isInteger(cached)) return cached;
  if (!Number.isInteger(tabId) || typeof chrome.runtime.getContexts !== 'function') return null;
  try {
    const contexts = await chrome.runtime.getContexts({ tabIds: [tabId] });
    const frameId = pdfMimeHandlerFrameId(contexts, chrome.runtime.getURL('pdf-viewer.html'));
    if (Number.isInteger(frameId)) mimePdfTabs.set(tabId, frameId);
    return frameId;
  } catch {
    return null;
  }
}

function activeMimePdfSource(source, tab, frameId) {
  if (!Number.isInteger(frameId)) return source;
  const pdfUrl = source.pdfUrl || manualPdfSourceUrl(tab?.url);
  return {
    ...source,
    frameId,
    pdfReaderActive: true,
    sourceKind: 'pdf',
    pdfUrl,
    url: source.url || safeSourceUrl(pdfUrl)
  };
}

async function tabHasPdfDocument(tabId, expectedUrl) {
  try {
    const results = await chrome.scripting.executeScript({
      target: { tabId, frameIds: [0] },
      func: () => ({ url: location.href, contentType: document.contentType })
    });
    const result = results.find(({ frameId }) => frameId === 0)?.result;
    if (!result) return null;
    return result.url === expectedUrl && result.contentType === 'application/pdf';
  } catch {
    // Some native PDF viewers (and local files without file access) cannot be
    // inspected. Keep this distinct from a document confirmed to be HTML.
    return null;
  }
}

async function completePdfHandoff(tabId, expectedUrl) {
  const [tab, mimeFrameId] = await Promise.all([
    chrome.tabs.get(tabId),
    activeMimePdfFrameId(tabId)
  ]);
  const currentUrl = String(tab?.url || '');
  if (!tab?.id
      || currentUrl !== expectedUrl
      || (tab.status && tab.status !== 'complete')
      || pdfRoutingTabs.has(tabId)
      || Number.isInteger(mimeFrameId)
      || pdfViewerSourceId(currentUrl)
      || bypassesPdfViewer(tabId)
      || !isLikelyPdfTab(tab)) return;

  const repositoryDownload = pdfWrapperDownloadUrl(currentUrl);
  if (repositoryDownload && repositoryDownload !== currentUrl) {
    const source = await ensureTabIsEnabled(tab);
    stagedPdfSources.set(tabId, {
      createdAt: Date.now(),
      url: source.url || safeSourceUrl(source.pdfUrl),
      pageTitle: source.pageTitle || 'PDF document'
    });
    pdfRoutingTabs.add(tabId);
    try {
      await chrome.tabs.update(tabId, { url: repositoryDownload });
    } finally {
      pdfRoutingTabs.delete(tabId);
    }
    return;
  }

  // A submitted prompt can put its trailing PDF link in the chat's title or
  // URL path. Even a .pdf suffix must never override a confirmed HTML page.
  // Only inaccessible native viewers may fall back to the URL hint.
  const documentIsPdf = await tabHasPdfDocument(tabId, currentUrl);
  if (documentIsPdf !== true && !(documentIsPdf === null && isPdfUrl(currentUrl))) return;

  // The MIME frame can still be starting after a reload. Its registration and
  // runtime context may not be visible yet; do not race it with a redirect.
  if (!await pdfMimeHandlerEnabled()) await openPdfViewer(tab);
}

function schedulePdfHandoff(tabId, tab) {
  cancelPendingPdfHandoff(tabId);
  const expectedUrl = String(tab?.url || '');
  const timer = setTimeout(() => {
    pendingPdfHandoffs.delete(tabId);
    completePdfHandoff(tabId, expectedUrl).catch(() => {});
  }, PDF_NATIVE_HANDOFF_DELAY);
  pendingPdfHandoffs.set(tabId, timer);
}

async function queuePanelRequest(tab, request, { info = {}, open = true, assumePdf = false } = {}) {
  const openRequest = open && tab.windowId != null
    ? chrome.sidePanel.open({ windowId: tab.windowId })
    : Promise.resolve();
  const [source] = await Promise.all([ensureTabIsEnabled(tab, info), openRequest]);
  if (assumePdf && !source.pdfUrl) {
    const candidate = String(info.frameUrl || info.pageUrl || tab.url || '');
    try {
      const parsed = new URL(candidate);
      if (['http:', 'https:', 'file:', 'data:', 'blob:'].includes(parsed.protocol)) {
        source.pdfUrl = parsed.href;
        source.sourceKind = 'pdf';
      }
    } catch {}
  }
  const registeredFrameId = await activeMimePdfFrameId(tab.id);
  const resolvedSource = activeMimePdfSource(source, tab, registeredFrameId);
  const value = {
    id: crypto.randomUUID(),
    createdAt: Date.now(),
    mode: request.mode,
    question: String(request.question || ''),
    selection: String(request.selection || '').slice(0, MAX_MENU_SELECTION_LENGTH),
    ...resolvedSource,
    frameId: preferredContentFrameId(info.frameId, registeredFrameId)
  };
  await chrome.storage.session.set({ [PANEL_REQUEST_KEY]: value });
  return { surface: 'panel', mode: value.mode };
}

async function routeTabCommand(command, { openPanel = true } = {}) {
  const tab = await activeTab();
  const capture = command === 'SCHOLIA_START_CAPTURE';
  if (isLikelyPdfTab(tab)) {
    return queuePanelRequest(tab, { mode: capture ? 'capture' : 'paste' }, { open: openPanel });
  }
  try {
    await chrome.tabs.sendMessage(tab.id, { type: command }, capture ? { frameId: 0 } : {});
    return { surface: 'page', mode: capture ? 'capture' : 'selection' };
  } catch {
    return queuePanelRequest(tab, { mode: capture ? 'capture' : 'paste' }, {
      open: openPanel,
      assumePdf: true
    });
  }
}

function queueQuickChatNavigation() {
  const navigation = {
    id: crypto.randomUUID(),
    createdAt: Date.now(),
    view: 'new',
    chatId: ''
  };
  return chrome.storage.session.set({ [PANEL_NAVIGATION_KEY]: navigation });
}

function openQuickChatForWindow(windowId) {
  if (!Number.isInteger(windowId)) throw new Error('No active browser window is available.');
  const opening = chrome.sidePanel.open({ windowId });
  return Promise.all([
    queueQuickChatNavigation(),
    opening
  ]).then(() => ({ surface: 'panel', mode: 'quick-chat' }));
}

function signalQuickChatPanelClose() {
  return chrome.runtime.sendMessage({ type: 'SCHOLIA_CLOSE_QUICK_CHAT_PANEL' });
}

function probeQuickChatPanel() {
  return chrome.runtime.sendMessage({ type: 'SCHOLIA_PROBE_QUICK_CHAT_PANEL' });
}

function toggleQuickChatForTab(tab) {
  return toggleQuickChatFromCommandTab(tab, {
    probePanel: probeQuickChatPanel,
    signalClose: signalQuickChatPanelClose,
    // This call is intentionally made synchronously by the helper.
    openForWindow: (windowId) => chrome.sidePanel.open({ windowId }),
    prepareOpen: queueQuickChatNavigation
  });
}

function siteKey(rawUrl) {
  return normalizeSiteKey(rawUrl);
}

async function activeSite(sourceTab = null) {
  const tab = sourceTab || await activeTab();
  const source = await resolvedTabSource(tab || {});
  const site = siteKey(source.pdfUrl || source.url || tab?.url || '');
  if (!site) throw new Error('This page cannot be configured per site.');
  const settings = await loadSettings();
  return { site, enabled: siteIsEnabled(settings, site), mode: settings.siteAccessMode };
}

async function activeSource(sourceTab = null) {
  const tab = sourceTab || await activeTab();
  const source = await resolvedTabSource(tab);
  const frameId = await activeMimePdfFrameId(tab.id);
  return { ...activeMimePdfSource(source, tab, frameId), tabUrl: tab.url };
}

async function chatGptTabs() {
  const tabs = await chrome.tabs.query({
    url: ['https://chatgpt.com/*', 'https://chat.openai.com/*']
  });
  return tabs
    .filter((tab) => tab.id && isChatGptWebUrl(tab.url))
    .sort((left, right) => Number(right.lastAccessed || 0) - Number(left.lastAccessed || 0));
}

async function requestChatGptWebState(tab) {
  const request = () => chrome.tabs.sendMessage(tab.id, { type: 'SCHOLIA_GET_CHATGPT_WEB_STATE' });
  return requestChatGptWebStateWithInjection({
    request,
    // Declarative content scripts do not appear retroactively in tabs that were
    // open when an unpacked extension was installed or reloaded. Inject only the
    // small ChatGPT probe, then retry without reloading the user's conversation.
    inject: () => chrome.scripting.executeScript({
      target: { tabId: tab.id },
      files: ['chatgpt-probe.js']
    })
  });
}

async function chatGptWebState() {
  const tabs = await chatGptTabs();
  if (!tabs.length) return { open: false, loggedIn: false };
  let connectionError = '';
  for (const tab of tabs) {
    try {
      const response = await requestChatGptWebState(tab);
      if (!response?.ok || !response.value?.supported) continue;
      return { open: true, tabId: tab.id, windowId: tab.windowId, ...response.value };
    } catch (error) {
      connectionError = error?.message || String(error);
    }
  }
  return {
    open: true,
    loggedIn: false,
    connectionError: true,
    error: connectionError
      ? `Scholia found ChatGPT but could not connect to the page: ${connectionError}`
      : 'Scholia found ChatGPT but could not read the page. Check the extension site-access permission for chatgpt.com.'
  };
}

async function openChatGptWeb() {
  const [tab] = await chatGptTabs();
  if (tab) {
    const state = await chatGptWebState();
    await chrome.tabs.update(tab.id, { active: true });
    if (tab.windowId != null) await chrome.windows.update(tab.windowId, { focused: true });
    if (state?.supported) {
      await chrome.tabs.sendMessage(tab.id, { type: 'SCHOLIA_SHOW_CHATGPT_IMPORT_GUIDE' }).catch(() => {});
    }
    return { tabId: tab.id, reused: true, state };
  }
  const created = await chrome.tabs.create({ url: 'https://chatgpt.com/', active: true });
  return { tabId: created.id, reused: false, state: { open: true, loggedIn: false, loading: true } };
}

async function waitForTabComplete(tabId, timeout = 20_000) {
  const current = await chrome.tabs.get(tabId);
  if (current.status === 'complete') return current;
  return new Promise((resolve, reject) => {
    const finish = (tab) => {
      clearTimeout(timer);
      chrome.tabs.onUpdated.removeListener(listener);
      resolve(tab);
    };
    const timer = setTimeout(() => {
      chrome.tabs.onUpdated.removeListener(listener);
      reject(new Error('ChatGPT took too long to load Personalization settings.'));
    }, timeout);
    const listener = (updatedTabId, changeInfo, tab) => {
      if (updatedTabId !== tabId || changeInfo.status !== 'complete') return;
      finish(tab);
    };
    chrome.tabs.onUpdated.addListener(listener);
    chrome.tabs.get(tabId).then((tab) => {
      if (tab.status === 'complete') finish(tab);
    }).catch((error) => {
      clearTimeout(timer);
      chrome.tabs.onUpdated.removeListener(listener);
      reject(error);
    });
  });
}

async function focusTab(tab) {
  await chrome.tabs.update(tab.id, { active: true });
  if (tab.windowId != null) await chrome.windows.update(tab.windowId, { focused: true });
}

async function restoreExtensionTab(sender) {
  if (!sender.tab?.id) return;
  await chrome.tabs.update(sender.tab.id, { active: true }).catch(() => {});
  if (sender.tab.windowId != null) await chrome.windows.update(sender.tab.windowId, { focused: true }).catch(() => {});
}

async function importChatGptMemory(sender) {
  const settings = await loadSettings();
  const tabs = await chatGptTabs();
  const projectTab = tabs.find((tab) => chatGptProjectIdentity({
    url: tab.url,
    title: tab.title
  }).projectUrl);
  const project = projectTab
    ? chatGptProjectIdentity({ url: projectTab.url, title: projectTab.title })
    : {
        projectName: settings.chatgptWebContext.projectName || '',
        projectUrl: settings.chatgptWebContext.projectUrl || ''
      };
  const tab = await chrome.tabs.create({
    url: chatGptPersonalizationUrl(),
    active: true
  });
  if (!tab?.id) throw new Error('Scholia could not open ChatGPT Personalization.');
  let completed = false;
  try {
    await focusTab(tab);
    const loaded = await waitForTabComplete(tab.id);
    await requestChatGptWebState(loaded);
    const response = await chrome.tabs.sendMessage(tab.id, { type: 'SCHOLIA_PREPARE_CHATGPT_MEMORY_IMPORT' });
    if (!response?.ok) throw new Error(response?.error || 'ChatGPT did not return its visible memory summary.');
    if (!chatGptMemoryTextIsUsable(response.value?.memoryText)) {
      throw new Error('ChatGPT did not return a valid rendered memory summary. Your saved Scholia memory was not changed.');
    }
    completed = true;
    return {
      open: true,
      ...response.value,
      projectName: response.value?.projectName || project.projectName,
      projectUrl: response.value?.projectUrl || project.projectUrl
    };
  } finally {
    if (completed) {
      await chrome.tabs.remove(tab.id).catch(() => {});
      await restoreExtensionTab(sender);
    } else {
      // Keep the dedicated tab visible so sign-in or a changed ChatGPT settings
      // screen can be fixed without losing one of the user's conversations.
      await focusTab(tab).catch(() => {});
    }
  }
}

async function importChatGptMemoryInBackground(settings) {
  const tabs = await chatGptTabs();
  const projectTab = tabs.find((tab) => chatGptProjectIdentity({
    url: tab.url,
    title: tab.title
  }).projectUrl);
  const project = projectTab
    ? chatGptProjectIdentity({ url: projectTab.url, title: projectTab.title })
    : {
        projectName: settings.chatgptWebContext.projectName || '',
        projectUrl: settings.chatgptWebContext.projectUrl || ''
      };
  const temporaryTab = await chrome.tabs.create({
    url: chatGptPersonalizationUrl(),
    active: false
  });
  if (!temporaryTab?.id) throw new Error('Scholia could not open a background ChatGPT tab.');

  try {
    const loaded = await waitForTabComplete(temporaryTab.id, 30_000);
    await requestChatGptWebState(loaded);
    const response = await chrome.tabs.sendMessage(temporaryTab.id, {
      type: 'SCHOLIA_PREPARE_CHATGPT_MEMORY_IMPORT'
    });
    if (!response?.ok) {
      throw new Error(response?.error || 'ChatGPT did not return its rendered memory summary.');
    }
    if (!chatGptMemoryTextIsUsable(response.value?.memoryText)) {
      throw new Error('ChatGPT did not return a valid rendered memory summary.');
    }
    return {
      ...response.value,
      projectName: response.value?.projectName || project.projectName,
      projectUrl: response.value?.projectUrl || project.projectUrl
    };
  } finally {
    await chrome.tabs.remove(temporaryTab.id).catch(() => {});
  }
}

async function refreshChatGptContextForQuickChat({ force = false } = {}) {
  if (automaticChatGptRefreshTask) return automaticChatGptRefreshTask;
  const task = (async () => {
    const settings = await loadSettings();
    const decision = chatGptQuickChatRefreshDecision(settings.chatgptWebContext, { force });
    if (!decision.enabled && !force) {
      return {
        refreshed: false,
        due: false,
        context: publicSettings(settings).chatgptWebContext
      };
    }
    if (!decision.due) {
      return {
        refreshed: false,
        due: false,
        context: publicSettings(settings).chatgptWebContext
      };
    }

    const state = await importChatGptMemoryInBackground(settings);
    settings.chatgptWebContext = chatGptContextAfterMemoryRefresh(
      settings.chatgptWebContext,
      state
    );
    const saved = await saveSettings(settings);
    return {
      refreshed: true,
      due: true,
      memoryCharacters: saved.chatgptWebContext.memory.length,
      context: publicSettings(saved).chatgptWebContext
    };
  })();
  automaticChatGptRefreshTask = task;
  try {
    return await task;
  } finally {
    if (automaticChatGptRefreshTask === task) automaticChatGptRefreshTask = null;
  }
}

async function storePageSelection(message, sender) {
  if (!sender.tab?.id || sender.tab.windowId == null) {
    throw new Error('Page selections must come from an open browser tab.');
  }
  const selection = String(message.selection || '').trim().slice(0, MAX_MENU_SELECTION_LENGTH);
  if (!selection) throw new Error('The page selection is empty.');
  const source = await resolvedTabSource(sender.tab, { pageUrl: sender.url });
  const kind = message.kind === 'latex' ? 'latex' : message.kind === 'mail' ? 'mail' : 'text';
  const value = {
    id: crypto.randomUUID(),
    createdAt: Date.now(),
    selection,
    kind,
    ...(kind === 'mail' ? {
      mailContext: String(message.mailContext || '').trim().slice(0, MAX_MAIL_THREAD_CONTEXT_CHARACTERS),
      mailSubject: String(message.mailSubject || '').trim().slice(0, 1_200),
      mailMessageCount: Math.max(0, Math.min(40, Number(message.mailMessageCount) || 0)),
      defaultQuestion: String(message.defaultQuestion || '').trim().slice(0, 1_200)
    } : {}),
    ...source,
    frameId: contentFrameTarget(sender.frameId).frameId
  };
  const storageKey = pageSelectionStorageKey(sender.tab.id);
  await chrome.storage.session.set({ [storageKey]: value });
  await chrome.storage.session.remove(PAGE_SELECTION_KEY).catch(() => {});
  return { id: value.id };
}

async function activePageSelection(sourceTab = null) {
  const tab = sourceTab || await activeTab();
  const storageKey = pageSelectionStorageKey(tab.id);
  const stored = (await chrome.storage.session.get(storageKey))[storageKey];
  if (!stored) return null;
  if (Date.now() - Number(stored.createdAt || 0) > PAGE_SELECTION_MAX_AGE) {
    await chrome.storage.session.remove(storageKey);
    return null;
  }
  if (stored.tabId !== tab.id) return null;
  return stored;
}

async function clearPageSelectionForSender(sender) {
  const storageKey = pageSelectionStorageKey(sender.tab?.id);
  if (!storageKey) throw new Error('Page selection cleanup requires an open browser tab.');
  await chrome.storage.session.remove(storageKey);
  return { cleared: true };
}

async function setSiteEnabled(site, enabled) {
  if (!site) throw new Error('This page cannot be configured per site.');
  const settings = await loadSettings();
  if (settings.siteAccessMode === 'allowlist') {
    const allowed = new Set(settings.allowedSites);
    if (enabled) allowed.add(site);
    else allowed.delete(site);
    settings.allowedSites = [...allowed].sort();
  } else {
    const disabled = new Set(settings.disabledSites);
    if (enabled) disabled.delete(site);
    else disabled.add(site);
    settings.disabledSites = [...disabled].sort();
  }
  await saveSettings(settings);
  return { site, enabled: siteIsEnabled(settings, site), mode: settings.siteAccessMode };
}

chrome.commands.onCommand.addListener((command, tab) => {
  if (command === 'quick-chat') {
    // sidePanel.open() must run within the keyboard command's user gesture.
    // Chromium supplies the active tab here, so do not await a tabs.query()
    // before opening the panel.
    const toggling = Number.isInteger(tab?.windowId)
      ? toggleQuickChatForTab(tab)
      : closeQuickChatFromSignal(signalQuickChatPanelClose);
    toggling?.catch(() => {});
    return;
  }
  if (command === 'capture-region') {
    routeTabCommand('SCHOLIA_START_CAPTURE').catch(() => {});
    return;
  }
  if (command === 'explain-selection') {
    routeTabCommand('SCHOLIA_EXPLAIN_CURRENT').catch(() => {});
  }
});

chrome.tabs.onCreated.addListener((tab) => {
  if (!tab?.id) return;
  if (pdfViewerTabSourceId(tab)) {
    restorePdfViewerTab(tab).catch(() => {}).finally(() => newlyCreatedTabs.delete(tab.id));
    return;
  }
  if (tab.pendingUrl || tab.url) return;
  newlyCreatedTabs.add(tab.id);
  setTimeout(() => newlyCreatedTabs.delete(tab.id), 30_000);
});

chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.url || changeInfo.status === 'loading') {
    cancelPendingPdfHandoff(tabId);
    mimePdfTabs.delete(tabId);
    const selectionKey = pageSelectionStorageKey(tabId);
    if (selectionKey) chrome.storage.session.remove(selectionKey).catch(() => {});
  }
  if (pdfRoutingTabs.has(tabId)) return;
  const url = String(changeInfo.url || tab.url || '');
  const restoredViewer = pdfViewerTabSourceId(tab);
  if (restoredViewer && (newlyCreatedTabs.has(tabId) || changeInfo.discarded === false)) {
    restorePdfViewerTab(tab).catch(() => {}).finally(() => newlyCreatedTabs.delete(tabId));
    return;
  }
  if (newlyCreatedTabs.has(tabId) && (changeInfo.url || changeInfo.status === 'complete')) {
    newlyCreatedTabs.delete(tabId);
  }
  if (!isCompletedPdfNavigation(changeInfo, tab)) {
    if (changeInfo.status === 'complete' && !isLikelyPdfTab(tab)) stagedPdfSources.delete(tabId);
    return;
  }
  if (pdfViewerSourceId(url) || bypassesPdfViewer(tabId)) return;
  schedulePdfHandoff(tabId, tab);
});

chrome.tabs.onRemoved.addListener((tabId) => {
  cancelPendingPdfHandoff(tabId);
  newlyCreatedTabs.delete(tabId);
  pdfRoutingTabs.delete(tabId);
  nativePdfBypass.delete(tabId);
  stagedPdfSources.delete(tabId);
  mimePdfTabs.delete(tabId);
  const selectionKey = pageSelectionStorageKey(tabId);
  if (selectionKey) chrome.storage.session.remove(selectionKey).catch(() => {});
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (!tab?.id) return;
  if (info.menuItemId === MENU_EXPLAIN) {
    const selection = String(info.selectionText || '').trim();
    if (isLikelyPdfTab(tab, info)) {
      queuePanelRequest(tab, { mode: 'selection', selection }, { info }).catch(() => {});
      return;
    }
    chrome.tabs.sendMessage(tab.id, { type: 'SCHOLIA_EXPLAIN_TEXT', text: selection }).catch(() => {
      queuePanelRequest(tab, { mode: 'selection', selection }, { info, assumePdf: true }).catch(() => {});
    });
  } else if (info.menuItemId === MENU_CAPTURE) {
    if (isLikelyPdfTab(tab, info)) {
      queuePanelRequest(tab, { mode: 'capture' }, { info }).catch(() => {});
      return;
    }
    chrome.tabs.sendMessage(tab.id, { type: 'SCHOLIA_START_CAPTURE' }, { frameId: 0 }).catch(() => {
      queuePanelRequest(tab, { mode: 'capture' }, { info, assumePdf: true }).catch(() => {});
    });
  }
});

async function activeContext({
  question = '',
  selection = '',
  expectedTabId = null,
  expectedFrameId = 0,
  includeContext = null,
  maxChars = null,
  correlateTabs = false
} = {}, sourceTab = null) {
  const tab = sourceTab || await activeTab();
  if (Number.isInteger(expectedTabId) && tab.id !== expectedTabId) {
    throw new Error('The active tab changed. Return to the source and try again.');
  }
  let source = await ensureTabIsEnabled(tab);
  const pageLanguage = await chrome.tabs.detectLanguage(tab.id).catch(() => '');
  const registeredFrameId = await activeMimePdfFrameId(tab.id);
  source = activeMimePdfSource(source, tab, registeredFrameId);
  const pdfSource = source.sourceKind === 'pdf';

  try {
    const requestedMaxChars = correlateTabs && includeContext !== false
      ? MAX_PACKED_CONTEXT_CHARS
      : maxChars;
    const response = await sendContentFrameMessage(chrome.tabs, tab.id, {
      type: 'SCHOLIA_GET_PAGE_CONTEXT',
      question: String(question || ''),
      selection: String(selection || ''),
      includeContext,
      maxChars: requestedMaxChars
    }, preferredContentFrameId(expectedFrameId, registeredFrameId));
    if (!response?.ok) throw new Error(response?.error || 'The page did not return context.');
    let value = response.value || {};
    if (pdfSource && value.pdfViewer !== true) return { ...source, pageLanguage };
    if (correlateTabs && includeContext !== false) {
      const relatedTabs = await relatedOpenTabContexts(tab, {
        question,
        selection,
        visibleText: value.visibleContext,
        activeUrl: value.url || source.url
      });
      const context = packCompactBrowserWorkspace({
        activeTitle: value.pageTitle || source.pageTitle,
        activeUrl: value.url || source.url,
        activeVisibleText: value.visibleContext,
        activeContext: value.context,
        relatedTabs,
        question,
        selection,
        maxChars: Number.isFinite(Number(maxChars))
          ? Number(maxChars)
          : COMPACT_PACKED_CONTEXT_CHARS
      });
      value = {
        ...value,
        context,
        packedContextCharacters: context.length,
        relatedTabCount: relatedTabs.length,
        contextNotice: relatedTabs.length
          ? `Visible screen correlated with ${relatedTabs.length} related open tab${relatedTabs.length === 1 ? '' : 's'}`
          : 'Visible screen correlated with open tabs; no additional readable tab matched'
      };
    }
    return {
      ...source,
      ...value,
      sourceKind: pdfSource ? 'pdf' : 'page',
      pageLanguage: value.pageLanguage || pageLanguage,
      ...(pdfSource ? { pdfContextReady: true } : {})
    };
  } catch (error) {
    if (pdfSource) return { ...source, pageLanguage };
    await panelSourceTab(chrome.tabs, { windowId: tab.windowId, expectedTabId: tab.id, expectedUrl: tab.url });
    const imageDataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: 'png' });
    return {
      ...source,
      sourceKind: 'visible-image',
      pageLanguage,
      imageDataUrl,
      context: '',
      contextNotice: `Page text is protected from extensions; Scholia captured the visible tab instead. ${error?.message || ''}`.trim()
    };
  }
}

async function relatedOpenTabContexts(active, {
  question = '',
  selection = '',
  visibleText = '',
  activeUrl = ''
} = {}) {
  const [tabs, settings] = await Promise.all([
    chrome.tabs.query({ currentWindow: true }),
    loadSettings()
  ]);
  const eligible = tabs.filter((candidate) => {
    try {
      const url = new URL(candidate.url || '');
      if (!['http:', 'https:'].includes(url.protocol)) return false;
      return siteIsEnabled(settings, normalizeSiteKey(url.href));
    } catch {
      return false;
    }
  });
  const ranked = rankRelatedTabs(eligible, {
    activeTabId: active.id,
    activeUrl,
    question,
    visibleText
  });
  const previews = await Promise.all(ranked.map(async (candidate) => {
    try {
      const registeredFrameId = isLikelyPdfTab(candidate)
        ? await activeMimePdfFrameId(candidate.id)
        : null;
      const response = await Promise.race([
        sendContentFrameMessage(chrome.tabs, candidate.id, {
          type: 'SCHOLIA_GET_TAB_CONTEXT_PREVIEW',
          question: String(question || ''),
          correlationText: [selection, String(visibleText).slice(0, 1_500)].filter(Boolean).join('\n'),
          maxChars: 3_500
        }, preferredContentFrameId(null, registeredFrameId)),
        delay(800).then(() => null)
      ]);
      if (!response?.ok || !String(response.value?.context || '').trim()) return null;
      return {
        title: response.value.pageTitle || candidate.title || '',
        url: response.value.url || safeSourceUrl(candidate.url),
        visibleText: response.value.visibleText || '',
        context: response.value.context
      };
    } catch {
      return null;
    }
  }));
  return previews.filter(Boolean);
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, milliseconds)));
}

async function activeFrameSnapshots(tabId) {
  try {
    const snapshots = await chrome.scripting.executeScript({
      target: { tabId, allFrames: true },
      func: () => {
        const normalize = (value) => String(value || '')
          .replace(/\r\n?/g, '\n')
          .replace(/[\t\f\v ]+/g, ' ')
          .replace(/ *\n */g, '\n')
          .replace(/\n{3,}/g, '\n\n')
          .trim();
        const parts = [normalize(document.body?.innerText || document.documentElement?.innerText || '')];
        let shadowCount = 0;
        let scanned = 0;
        for (const element of document.querySelectorAll('*')) {
          scanned += 1;
          if (scanned > 50_000) break;
          if (!element.shadowRoot) continue;
          const text = normalize(element.shadowRoot.textContent || '');
          if (text) parts.push(text);
          shadowCount += 1;
          if (shadowCount >= 96) break;
        }
        return {
          title: document.title,
          url: location.href,
          text: parts.filter(Boolean).join('\n\n'),
          width: Math.max(document.documentElement?.scrollWidth || 0, document.body?.scrollWidth || 0),
          height: Math.max(document.documentElement?.scrollHeight || 0, document.body?.scrollHeight || 0)
        };
      }
    });
    return snapshots.map((entry) => ({
      ...entry,
      result: entry.result ? { ...entry.result, url: safeSourceUrl(entry.result.url) } : entry.result
    }));
  } catch {
    return [];
  }
}

async function activeDeepContext({
  question = '',
  selection = '',
  expectedTabId = null,
  expectedFrameId = 0,
  includeVisual = true,
  includeContext = null,
  maxChars = null
} = {}, sourceTab = null) {
  const tab = sourceTab || await activeTab();
  if (Number.isInteger(expectedTabId) && tab.id !== expectedTabId) {
    throw new Error('The active tab changed. Return to the source and try again.');
  }
  const source = await ensureTabIsEnabled(tab);
  if (source.sourceKind === 'pdf') throw new Error('Complete-page capture is available for websites, not PDF documents.');
  const targetFrameId = contentFrameTarget(expectedFrameId).frameId;
  const pageLanguage = await chrome.tabs.detectLanguage(tab.id).catch(() => '');
  const preparedResponse = await sendContentFrameMessage(chrome.tabs, tab.id, {
    type: 'SCHOLIA_PREPARE_DEEP_PAGE'
  }, targetFrameId);
  if (!preparedResponse?.ok) throw new Error(preparedResponse?.error || 'The page could not load its complete content.');

  const prepared = preparedResponse.value || {};
  const sessionId = String(prepared.sessionId || '');
  const positions = Array.from(prepared.positions || []).slice(0, MAX_DEEP_PAGE_TILES);
  const tiles = [];
  let layout = {
    viewportWidth: Number(prepared.viewportWidth) || 1,
    viewportHeight: Number(prepared.viewportHeight) || 1,
    pageWidth: Number(prepared.pageWidth) || Number(prepared.viewportWidth) || 1,
    pageHeight: Number(prepared.pageHeight) || Number(prepared.viewportHeight) || 1,
    complete: prepared.complete !== false
  };
  let finished = null;
  let failure = null;
  let visualError = '';
  let nextCaptureAt = 0;

  try {
    if (includeVisual) {
      for (const position of positions) {
        const current = await chrome.tabs.get(tab.id);
        if (!current.active || current.windowId !== tab.windowId) {
          throw new Error('The active tab changed during complete-page capture. Return to the source and try again.');
        }
        const scrolled = await sendContentFrameMessage(chrome.tabs, tab.id, {
          type: 'SCHOLIA_SCROLL_DEEP_PAGE',
          sessionId,
          position
        }, targetFrameId);
        if (!scrolled?.ok) throw new Error(scrolled?.error || 'The page stopped responding during complete-page capture.');
        const state = scrolled.value || {};
        layout = {
          ...layout,
          viewportWidth: Number(state.viewportWidth) || layout.viewportWidth,
          viewportHeight: Number(state.viewportHeight) || layout.viewportHeight,
          pageWidth: Math.max(layout.pageWidth, Number(state.pageWidth) || 0),
          pageHeight: Math.max(layout.pageHeight, Number(state.pageHeight) || 0)
        };
        await delay(nextCaptureAt - Date.now());
        try {
          const dataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: 'jpeg', quality: 72 });
          tiles.push({
            dataUrl,
            scrollX: Number(state.scrollX) || 0,
            scrollY: Number(state.scrollY) || 0
          });
          nextCaptureAt = Date.now() + DEEP_PAGE_CAPTURE_INTERVAL_MS;
        } catch (error) {
          visualError = error?.message || 'Chrome could not capture the page visual.';
          break;
        }
      }
    }
  } catch (error) {
    failure = error;
  } finally {
    try {
      const response = await sendContentFrameMessage(chrome.tabs, tab.id, {
        type: 'SCHOLIA_FINISH_DEEP_PAGE',
        sessionId
      }, targetFrameId);
      if (response?.ok) finished = response.value;
      else if (!failure) failure = new Error(response?.error || 'The page could not finish complete-page capture.');
    } catch (error) {
      if (!failure) failure = error;
    }
  }
  if (failure) throw failure;

  const metadata = finished?.metadata || {};
  const frameSnapshots = await activeFrameSnapshots(tab.id);
  const frameContext = embeddedFrameContext(frameSnapshots, {
    mainFrameId: targetFrameId,
    mainContext: metadata.context
  });
  const includedFrameCount = (frameContext.match(/^\[Embedded frame:/gm) || []).length;
  const rawContext = [String(metadata.context || ''), frameContext].filter(Boolean).join('\n\n');
  const shouldIncludeContext = typeof includeContext === 'boolean'
    ? includeContext
    : true;
  const context = shouldIncludeContext
    ? packPageContext(rawContext, {
      outline: String(metadata.outline || ''),
      selection: String(selection || ''),
      question: String(question || ''),
      ...(maxChars != null && Number.isFinite(Number(maxChars)) ? { maxChars: Number(maxChars) } : {}),
      scopeDescription: `the complete live page, its sanitized DOM snapshot, image descriptions, and ${includedFrameCount} readable embedded frame${includedFrameCount === 1 ? '' : 's'}`
    })
    : '';

  return {
    ...source,
    ...metadata,
    sourceKind: 'page',
    pageLanguage: metadata.pageLanguage || pageLanguage,
    context,
    outline: '',
    rawContextCharacters: rawContext.length,
    packedContextCharacters: context.length,
    deepPage: true,
    deepPageTiles: tiles,
    deepPageLayout: layout,
    deepPageFrameCount: includedFrameCount,
    deepPageVisualRequested: Boolean(includeVisual),
    deepPageVisualError: visualError
  };
}

async function activeSiteContext({
  question = '',
  selection = '',
  expectedTabId = null,
  includeContext = null,
  maxChars = null
} = {}, sourceTab = null) {
  const tab = sourceTab || await activeTab();
  if (Number.isInteger(expectedTabId) && tab.id !== expectedTabId) {
    throw new Error('The active tab changed. Return to the site and try again.');
  }
  const source = await ensureTabIsEnabled(tab);
  if (source.sourceKind === 'pdf') throw new Error('Entire-site context is not available for PDF documents.');
  let url;
  try { url = new URL(source.url || tab.url || ''); } catch {}
  if (!url || !['http:', 'https:'].includes(url.protocol)) {
    throw new Error('Entire-site context is available only on ordinary HTTP and HTTPS sites.');
  }
  const response = await sendContentFrameMessage(chrome.tabs, tab.id, {
    type: 'SCHOLIA_GET_SITE_CONTEXT',
    question: String(question || ''),
    selection: String(selection || ''),
    includeContext,
    maxChars
  });
  if (!response?.ok) throw new Error(response?.error || 'The site did not return context.');
  return { ...source, ...response.value, sourceKind: 'site' };
}

async function captureActiveVisible(expectedTabId = null, sourceTab = null) {
  const tab = sourceTab || await activeTab();
  if (Number.isInteger(expectedTabId) && tab.id !== expectedTabId) {
    throw new Error('The active tab changed before capture. Return to the source and try again.');
  }
  const source = await ensureTabIsEnabled(tab);
  const imageDataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: 'png' });
  const pageLanguage = await chrome.tabs.detectLanguage(tab.id).catch(() => '');
  return { ...source, pageLanguage, imageDataUrl };
}

async function captureActiveRegion(message, tab) {
  // An embedded reader's sender.tab snapshot can precede its latest page anchor.
  tab = await chrome.tabs.get(tab.id);
  if (!tab.active || (Number.isInteger(message.expectedTabId) && tab.id !== message.expectedTabId)) {
    throw new Error('The active tab changed before capture. Return to the source and try again.');
  }
  const source = await ensureTabIsEnabled(tab);
  let response;
  try {
    // Select against the whole tab viewport, never an arbitrary child frame.
    response = await chrome.tabs.sendMessage(tab.id, { type: 'SCHOLIA_SELECT_REGION' }, { frameId: 0 });
  } catch {
    throw new Error('Region selection is unavailable on this page. Reload it and try again, or open the PDF in Scholia’s reader.');
  }
  if (!response?.ok) throw new Error(response?.error || 'The page could not select a region.');
  if (!response.value) return null;
  const currentTab = await chrome.tabs.get(tab.id);
  if (!currentTab.active || currentTab.url?.split('#')[0] !== tab.url?.split('#')[0]) {
    throw new Error('The source page changed during capture. Return to it and try again.');
  }
  return { ...source, imageDataUrl: response.value.imageDataUrl };
}

function respondAsync(sendResponse, task) {
  task.then((value) => sendResponse({ ok: true, value })).catch((error) => sendResponse({ ok: false, error: error?.message || String(error) }));
}

function isExtensionPage(sender) {
  return sender.url?.startsWith(chrome.runtime.getURL('')) === true;
}

function embeddedPdfSourceTab(sender, message = {}) {
  if (!isExtensionPage(sender) || !Number.isInteger(sender.tab?.id)) return null;
  const url = new URL(sender.url);
  return (url.pathname === '/panel.html' && url.searchParams.get('surface') === 'pdf-overlay')
      || (url.pathname === '/pdf-viewer.html' && message.pdfReaderPanel === true)
    ? sender.tab
    : null;
}

async function sourceTabForPanel(sender, message) {
  return embeddedPdfSourceTab(sender, message) || panelSourceTab(chrome.tabs, message);
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || typeof message.type !== 'string') return undefined;
  if (message.target === 'scholia-ocr') return undefined;
  if (message.type === 'SCHOLIA_OCR_RECOGNIZE' || message.type === 'SCHOLIA_OCR_CANCEL') {
    respondAsync(sendResponse, forwardOcrRequest(message, sender));
    return true;
  }

  if (message.type === 'SCHOLIA_MUTATE_CHAT_HISTORY') {
    if (!isExtensionPage(sender)) { sendResponse({ ok: false, error: 'History can be changed only from an extension page.' }); return false; }
    respondAsync(sendResponse, mutateChatHistory(message.operation, message.value));
    return true;
  }

  if (message.type === 'SCHOLIA_GET_PUBLIC_SETTINGS') {
    respondAsync(sendResponse, loadSettings().then(publicSettings));
    return true;
  }

  if (message.type === 'SCHOLIA_GET_SETTINGS') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'Settings are available only to extension pages.' });
      return false;
    }
    respondAsync(sendResponse, loadSettings());
    return true;
  }

  if (message.type === 'SCHOLIA_SAVE_SETTINGS') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'Settings can be changed only from an extension page.' });
      return false;
    }
    respondAsync(sendResponse, saveSettings(message.settings));
    return true;
  }

  if (message.type === 'SCHOLIA_SAVE_LANGUAGE') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'Language can be changed only from an extension page.' });
      return false;
    }
    respondAsync(sendResponse, loadSettings().then((settings) => {
      if (!['auto', 'en', 'no'].includes(message.language)) throw new Error('Choose a valid response language.');
      settings.language = message.language;
      return saveSettings(settings).then(publicSettings);
    }));
    return true;
  }

  if (message.type === 'SCHOLIA_SAVE_MODEL') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'Model settings can be changed only from an extension page.' });
      return false;
    }
    respondAsync(sendResponse, loadSettings().then((settings) => {
      const provider = String(message.provider || '');
      const model = String(message.model || '').trim();
      if (providerById(provider).id !== provider || !model || model.length > 200) {
        throw new Error('Choose a valid provider and model.');
      }
      settings.provider = provider;
      settings.models[provider] = resolveModelId(provider, model, settings);
      if (message.reasoningEffort != null) settings.reasoningEfforts[provider] = String(message.reasoningEffort);
      if (message.fastMode != null) settings.fastMode = Boolean(message.fastMode);
      return saveSettings(settings).then(publicSettings);
    }));
    return true;
  }

  if (message.type === 'SCHOLIA_BRIDGE_STATUS') {
    respondAsync(sendResponse, loadSettings().then((settings) => {
      const provider = String(message.provider || settings.provider);
      const requestedTimeout = Number(message.timeoutMs);
      const timeoutMs = Number.isFinite(requestedTimeout)
        ? Math.max(250, Math.min(5_000, requestedTimeout))
        : undefined;
      return bridgeStatusWithModelCatalog(provider, settings, {
        includeUsage: Boolean(message.includeUsage),
        refreshModels: Boolean(message.refreshModels),
        ...(timeoutMs ? { timeoutMs } : {})
      });
    }));
    return true;
  }

  if (message.type === 'SCHOLIA_SET_SITE_ENABLED') {
    respondAsync(sendResponse, resolvedTabSource(sender.tab || { url: sender.url }, { pageUrl: sender.url }).then((source) => {
      const site = siteKey(source.pdfUrl || source.url || sender.url || '');
      return setSiteEnabled(site, Boolean(message.enabled));
    }));
    return true;
  }

  if (message.type === 'SCHOLIA_PAGE_SELECTION_CHANGED') {
    respondAsync(sendResponse, storePageSelection(message, sender));
    return true;
  }

  if (message.type === 'SCHOLIA_CLEAR_PAGE_SELECTION') {
    respondAsync(sendResponse, clearPageSelectionForSender(sender));
    return true;
  }

  if (message.type === 'SCHOLIA_GET_ACTIVE_SOURCE') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'Active-source details are available only to extension pages.' });
      return false;
    }
    respondAsync(sendResponse, sourceTabForPanel(sender, message).then((tab) => activeSource(tab)));
    return true;
  }

  if (message.type === 'SCHOLIA_GET_ACTIVE_SELECTION') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'Active selections are available only to extension pages.' });
      return false;
    }
    respondAsync(sendResponse, sourceTabForPanel(sender, message).then((tab) => activePageSelection(tab)));
    return true;
  }

  if (message.type === 'SCHOLIA_GET_ACTIVE_SITE') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'Active-site details are available only to extension pages.' });
      return false;
    }
    respondAsync(sendResponse, sourceTabForPanel(sender, message).then((tab) => activeSite(tab)));
    return true;
  }

  if (message.type === 'SCHOLIA_SET_ACTIVE_SITE_ENABLED') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'Site settings can be changed only from an extension page.' });
      return false;
    }
    respondAsync(sendResponse, activeSite().then(({ site }) => setSiteEnabled(site, Boolean(message.enabled))));
    return true;
  }

  if (message.type === 'SCHOLIA_CAPTURE_VISIBLE') {
    if (sender.tab?.windowId == null || sender.tab?.id == null) {
      sendResponse({ ok: false, error: 'Screen capture must be started from a web page.' });
      return false;
    }
    respondAsync(sendResponse, chrome.tabs.get(sender.tab.id).then((tab) => {
      if (!tab.active || tab.windowId !== sender.tab.windowId) throw new Error('The page changed before capture. Try again.');
      return chrome.tabs.captureVisibleTab(sender.tab.windowId, { format: 'png' });
    }));
    return true;
  }

  if (message.type === 'SCHOLIA_GET_RESEARCH_PAGE') {
    if (!isExtensionPage(sender)) { sendResponse({ ok: false, error: 'Research is available only from a Scholia chat.' }); return false; }
    respondAsync(sendResponse, (async () => {
      const url = researchUrl(message.url);
      if (!url) throw new Error('A readable source URL is required.');
      const tab = Number.isInteger(message.tabId) ? await chrome.tabs.get(message.tabId)
        : (await chrome.tabs.query({})).find((candidate) => researchUrl(candidate.url) === url);
      if (!tab || researchUrl(tab.url) !== url) throw new Error('The source tab is no longer open.');
      await ensureTabIsEnabled(tab);
      const response = await sendContentFrameMessage(chrome.tabs, tab.id, { type: 'SCHOLIA_GET_RESEARCH_PAGE' });
      if (!response?.ok) throw new Error(response?.error || 'The source could not be read.');
      return response.value;
    })());
    return true;
  }

  if (message.type === 'SCHOLIA_GET_ACTIVE_CONTEXT') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'Page context is available only to extension pages.' });
      return false;
    }
    respondAsync(sendResponse, sourceTabForPanel(sender, message).then((tab) => activeContext(message, tab)));
    return true;
  }

  if (message.type === 'SCHOLIA_GET_ACTIVE_DEEP_CONTEXT') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'Complete-page context is available only to extension pages.' });
      return false;
    }
    respondAsync(sendResponse, sourceTabForPanel(sender, message).then((tab) => activeDeepContext(message, tab)));
    return true;
  }

  if (message.type === 'SCHOLIA_GET_ACTIVE_SITE_CONTEXT') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'Site context is available only to extension pages.' });
      return false;
    }
    respondAsync(sendResponse, sourceTabForPanel(sender, message).then((tab) => activeSiteContext(message, tab)));
    return true;
  }

  if (message.type === 'SCHOLIA_CAPTURE_ACTIVE_VISIBLE') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'Tab capture is available only to extension pages.' });
      return false;
    }
    respondAsync(sendResponse, sourceTabForPanel(sender, message).then((tab) => captureActiveVisible(message.expectedTabId, tab)));
    return true;
  }

  if (message.type === 'SCHOLIA_CAPTURE_ACTIVE_REGION') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'Region capture is available only to extension pages.' });
      return false;
    }
    respondAsync(sendResponse, sourceTabForPanel(sender, message).then((tab) => captureActiveRegion(message, tab)));
    return true;
  }

  if (message.type === 'SCHOLIA_REGISTER_MIME_PDF_HANDLER') {
    if (sender.id !== chrome.runtime.id || !sender.tab?.id) {
      sendResponse({ ok: false, error: 'The PDF handler registration is not valid.' });
      return false;
    }
    cancelPendingPdfHandoff(sender.tab.id);
    const frameId = contentFrameTarget(sender.frameId).frameId;
    mimePdfTabs.set(sender.tab.id, frameId);
    sendResponse({ ok: true, value: { registered: true, frameId } });
    return false;
  }

  if (message.type === 'SCHOLIA_PREPARE_NATIVE_PDF_FALLBACK') {
    if (sender.id !== chrome.runtime.id || !sender.tab?.id) {
      sendResponse({ ok: false, error: 'The native PDF fallback is not valid.' });
      return false;
    }
    cancelPendingPdfHandoff(sender.tab.id);
    mimePdfTabs.delete(sender.tab.id);
    nativePdfBypass.set(sender.tab.id, { url: sender.tab.url || '', expiresAt: Date.now() + 60_000 });
    sendResponse({ ok: true, value: { prepared: true } });
    return false;
  }

  if (message.type === 'SCHOLIA_GET_PDF_VIEWER_SOURCE') {
    const requestedId = String(message.sourceId || '');
    if (!isExtensionPage(sender) || !requestedId || pdfViewerSourceId(sender.url) !== requestedId) {
      sendResponse({ ok: false, error: 'The PDF source request is not valid for this viewer.' });
      return false;
    }
    respondAsync(sendResponse, storedPdfSource(requestedId).then((source) => {
      if (!source) throw new Error('Scholia no longer has this PDF address. Paste it again or choose the file.');
      return source;
    }));
    return true;
  }

  if (message.type === 'SCHOLIA_OPEN_MANUAL_PDF_VIEWER') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'The PDF reader can be opened only from Scholia.' });
      return false;
    }
    respondAsync(sendResponse, chrome.tabs.create({
      url: chrome.runtime.getURL('pdf-viewer.html?open=1'),
      active: true
    }));
    return true;
  }

  if (message.type === 'SCHOLIA_CREATE_PDF_VIEWER_SOURCE') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'PDF addresses can be opened only from Scholia.' });
      return false;
    }
    respondAsync(sendResponse, createManualPdfViewerSource(message.url));
    return true;
  }

  if (message.type === 'SCHOLIA_OPEN_PDF_VIEWER') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'The PDF viewer can be opened only from Scholia.' });
      return false;
    }
    respondAsync(sendResponse, activeTab().then(openPdfViewer));
    return true;
  }

  if (message.type === 'SCHOLIA_OPEN_NATIVE_PDF') {
    if (!isExtensionPage(sender) || !sender.tab?.id) {
      sendResponse({ ok: false, error: 'The original PDF can be opened only from its Scholia viewer.' });
      return false;
    }
    respondAsync(sendResponse, openNativePdf(sender.tab));
    return true;
  }

  if (message.type === 'SCHOLIA_TOGGLE_QUICK_CHAT') {
    if (sender.tab?.windowId == null) {
      sendResponse({ ok: false, error: 'Quick Chat can be toggled only from a browser tab.' });
      return false;
    }
    respondAsync(sendResponse, toggleQuickChatForTab(sender.tab));
    return true;
  }

  if (message.type === 'SCHOLIA_OPEN_SIDE_PANEL') {
    if (!isExtensionPage(sender) || sender.tab?.windowId == null) {
      sendResponse({ ok: false, error: 'The side panel can be opened only from a Scholia tab.' });
      return false;
    }
    const view = message.view === 'home' ? 'home' : '';
    const navigation = view ? {
      id: crypto.randomUUID(),
      createdAt: Date.now(),
      view,
      chatId: ''
    } : null;
    const open = chrome.sidePanel.open({ windowId: sender.tab.windowId });
    const navigate = navigation
      ? chrome.storage.session.set({ [PANEL_NAVIGATION_KEY]: navigation })
      : Promise.resolve();
    respondAsync(sendResponse, Promise.all([open, navigate]).then(() => ({
      surface: 'panel',
      view
    })));
    return true;
  }

  if (message.type === 'SCHOLIA_MOVE_EXPLANATION_TO_CHAT') {
    const inPdfViewer = Boolean(embeddedPdfSourceTab(sender)) || (isExtensionPage(sender)
      && new URL(sender.url || sender.tab?.url).pathname === '/pdf-viewer.html');
    respondAsync(sendResponse, openExplanationChat(message.explanation, chrome, {
      destination: inPdfViewer ? 'pdf-sidebar' : 'tab'
    }));
    return true;
  }

  if (message.type === 'SCHOLIA_OPEN_OPTIONS') {
    respondAsync(sendResponse, chrome.runtime.openOptionsPage());
    return true;
  }

  if (message.type === 'SCHOLIA_GET_CHATGPT_WEB_STATE') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'ChatGPT web status is available only from Scholia settings.' });
      return false;
    }
    respondAsync(sendResponse, chatGptWebState());
    return true;
  }

  if (message.type === 'SCHOLIA_OPEN_CHATGPT_WEB') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'ChatGPT can be opened only from Scholia settings.' });
      return false;
    }
    respondAsync(sendResponse, openChatGptWeb());
    return true;
  }

  if (message.type === 'SCHOLIA_IMPORT_CHATGPT_MEMORY') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'ChatGPT memory can be imported only from Scholia settings.' });
      return false;
    }
    respondAsync(sendResponse, importChatGptMemory(sender));
    return true;
  }

  if (message.type === 'SCHOLIA_REFRESH_CHATGPT_CONTEXT_FOR_QUICK_CHAT') {
    respondAsync(sendResponse, refreshChatGptContextForQuickChat());
    return true;
  }

  if (message.type === 'SCHOLIA_PANEL_COMMAND') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'Page commands are available only to extension pages.' });
      return false;
    }
    if (!['SCHOLIA_EXPLAIN_CURRENT', 'SCHOLIA_START_CAPTURE'].includes(message.command)) {
      sendResponse({ ok: false, error: 'Unknown page command.' });
      return false;
    }
    respondAsync(sendResponse, routeTabCommand(message.command, { openPanel: false }));
    return true;
  }

  if (message.type === 'SCHOLIA_TEST_PROVIDER') {
    if (!isExtensionPage(sender)) {
      sendResponse({ ok: false, error: 'Provider tests are available only from settings.' });
      return false;
    }
    respondAsync(sendResponse, loadSettings().then(async (settings) => {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 30_000);
      try {
        const model = resolveModelId(message.provider, message.model, settings);
        const result = await runCompletion({
          provider: message.provider,
          model,
          messages: [{ role: 'user', content: 'Reply with OK only.' }],
          pageLanguage: 'en',
          kind: 'text'
        }, settings, () => {}, controller.signal);
        return { text: result.text.trim().slice(0, 120), provider: result.provider, model: result.model };
      } finally {
        clearTimeout(timeout);
      }
    }));
    return true;
  }

  return undefined;
});

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== 'scholia-chat') return;
  let active = null;

  port.onMessage.addListener(async (message) => {
    if (message?.type === 'cancel') {
      if (!message.requestId || message.requestId === active?.id) active?.controller.abort();
      return;
    }
    if (message?.type !== 'start') return;

    active?.controller.abort();
    if (active?.heartbeat) clearInterval(active.heartbeat);

    const request = {
      id: String(message.requestId || crypto.randomUUID()),
      controller: new AbortController(),
      heartbeat: null
    };
    active = request;
    request.heartbeat = setInterval(() => {
      try {
        port.postMessage({ type: 'heartbeat', requestId: request.id });
      } catch {
        clearInterval(request.heartbeat);
      }
    }, 20_000);

    try {
      const settings = await loadSettings();
      const result = await runCompletion(message.payload || {}, settings, (token) => {
        if (active !== request) return;
        try { port.postMessage({ type: 'token', requestId: request.id, token }); } catch {}
      }, request.controller.signal, (token) => {
        if (active !== request) return;
        try { port.postMessage({ type: 'reasoning', requestId: request.id, token }); } catch {}
      }, (activity) => {
        if (active !== request) return;
        try { port.postMessage({ type: 'activity', requestId: request.id, activity }); } catch {}
      });
      if (active === request && !request.controller.signal.aborted) {
        await rememberModelUse(result.provider, result.model).catch(() => {});
        port.postMessage({ type: 'done', requestId: request.id, ...result });
      }
    } catch (error) {
      if (active !== request) return;
      if (error?.name === 'AbortError') {
        try { port.postMessage({ type: 'cancelled', requestId: request.id }); } catch {}
      } else {
        try { port.postMessage({ type: 'error', requestId: request.id, error: error?.message || String(error) }); } catch {}
      }
    } finally {
      clearInterval(request.heartbeat);
      if (active === request) active = null;
    }
  });

  port.onDisconnect.addListener(() => {
    if (active?.heartbeat) clearInterval(active.heartbeat);
    active?.controller.abort();
    active = null;
  });
});
