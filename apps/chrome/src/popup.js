import { mountFileComposer, appendFileChips } from './file-composer.js';
import { mountResponseLanguage, renderResponseLanguage } from './response-language.js';
import { copyCodeBlock } from './clipboard.js';
import { getCanvasCourseContext } from './canvas-index.js';
import { SETTINGS_KEY, providerById, providerSupportsFastMode } from '../../../packages/core/src/providers.js';
import { packPageContext } from '../../../packages/core/src/context.js';
import { CHAT_HISTORY_KEY, clearChats, deleteChat, listChats } from './chat/chat-history.js';
import { createUserTurn, requestConversation } from './chat/chat-turn.js';
import {
  CONTEXT_MODE_COMPACT,
  CONTEXT_MODE_FULL,
  CONTEXT_MODE_NONE,
  contextCharacterLimit,
  defaultContextMode
} from './context-mode.js';
import { parseModelChoice, populateModelSelect } from './model-select.js';
import { populateReasoningSelect } from './reasoning-select.js';
import { extractPdfContext, fetchPdfBlob } from './pdf/pdf-context.js';
import { renderMarkdown, renderReasoning, renderActivity, addActivity, bindActivityDisclosure } from './render.js';
import { sendRuntimeMessage as sendPopupMessage } from './runtime-message.js';
import { PANEL_NAVIGATION_KEY } from './tab-context.js';
import { openExamPlanner } from './exam-planner-launch.js';

const popupWindow = chrome.windows?.getCurrent ? chrome.windows.getCurrent().then((value) => value.id).catch(() => null) : Promise.resolve(null);
const message = async (payload) => sendPopupMessage({ ...payload, windowId: await popupWindow });

const elements = Object.fromEntries([
  'settings', 'site-dot', 'site-state', 'site', 'site-toggle', 'open-sidebar', 'new-chat',
  'explain', 'capture', 'open-pdf', 'open-pdf-viewer', 'open-exam-planner', 'model-settings', 'model-select', 'fast-mode', 'fast-mode-state', 'model-hint', 'chat-count',
  'clear-chats', 'chat-list', 'chat-empty', 'status', 'quick-context-state', 'quick-reset',
  'quick-files', 'quick-attach', 'quick-messages', 'quick-empty', 'quick-compact', 'quick-none', 'quick-form', 'quick-input', 'quick-send', 'reasoning-select'
].map((id) => [id, document.getElementById(id)]));

let settings = null;
let modelSaving = false;
let modelSave = Promise.resolve();
let activeSite = null;
let activeSource = null;
let quickContextMode = CONTEXT_MODE_COMPACT;
let quickMessages = [];
let quickStreaming = false;
let quickPort = null;
let quickRequestId = '';
let quickRenderFrame = null;
let quickCaptureController = null;

function showStatus(value, error = false) {
  elements.status.textContent = value;
  elements.status.classList.toggle('error', error);
}

function isPdfSource(source) {
  return source?.sourceKind === 'pdf' || Boolean(source?.pdfUrl);
}

function selectedProviderModel() {
  const chosen = parseModelChoice(elements['model-select'].value);
  const provider = chosen.provider || settings?.provider || 'openai';
  return {
    provider,
    model: chosen.model || settings?.models?.[provider] || providerById(provider).defaultModel,
    reasoningEffort: settings?.reasoningEfforts?.[provider],
    fastMode: Boolean(settings?.fastMode)
  };
}

function renderQuickContextMode() {
  const compact = quickContextMode === CONTEXT_MODE_COMPACT;
  const none = quickContextMode === CONTEXT_MODE_NONE;
  elements['quick-compact'].setAttribute('aria-pressed', String(compact));
  elements['quick-none'].setAttribute('aria-pressed', String(none));
  elements['quick-context-state'].textContent = compact ? 'Compact' : none ? 'None' : 'Full';
  elements['quick-input'].placeholder = none
    ? 'Ask without automatic context…'
    : compact ? 'Ask about this screen…' : 'Ask with full page context…';
}

function setQuickContextMode(mode) {
  if (quickStreaming) return;
  quickContextMode = mode;
  renderQuickContextMode();
}

function quickMessageElement(entry) {
  const row = document.createElement('article');
  row.className = `quick-message ${entry.role}${entry.error ? ' error' : ''}`;
  const bubble = document.createElement('div');
  bubble.className = 'quick-bubble';
  if (entry.role === 'assistant') {
    bubble.innerHTML = `${renderActivity(entry.activity)}${renderReasoning(entry.reasoning, { streaming: entry.streaming })}${renderMarkdown(entry.content)}`;
    if (entry.streaming && !entry.content) bubble.append(document.createTextNode('Preparing answer…'));
    bindActivityDisclosure(bubble, entry);
  } else {
    appendFileChips(bubble, entry.files);
    if (entry.imageDataUrl) {
      const image = document.createElement('img');
      image.src = entry.imageDataUrl; image.alt = 'Attached image';
      image.style.cssText = 'max-width:100%;max-height:120px;display:block';
      bubble.append(image);
    }
    bubble.append(document.createTextNode(entry.content));
  }
  row.append(bubble);
  return row;
}

function renderQuickMessages() {
  elements['quick-messages'].textContent = '';
  if (!quickMessages.length) {
    const empty = document.createElement('p');
    empty.id = 'quick-empty';
    empty.className = 'quick-empty';
    empty.textContent = 'Ask about what is on screen without opening the sidebar.';
    elements['quick-messages'].append(empty);
  } else {
    for (const entry of quickMessages) elements['quick-messages'].append(quickMessageElement(entry));
  }
  elements['quick-send'].textContent = quickStreaming ? '■' : '↑';
  elements['quick-send'].setAttribute('aria-label', quickStreaming ? 'Stop Quick Chat response' : 'Send Quick Chat message');
  elements['quick-reset'].disabled = quickStreaming || !quickMessages.length;
  elements['quick-messages'].scrollTop = elements['quick-messages'].scrollHeight;
}

function scheduleQuickRender() {
  if (quickRenderFrame) return;
  quickRenderFrame = requestAnimationFrame(() => {
    quickRenderFrame = null;
    renderQuickMessages();
  });
}

async function quickChatGptContextAvailable() {
  if (quickContextMode === CONTEXT_MODE_NONE) return false;
  const imported = settings?.chatgptWebContext;
  if (!imported || imported.quickChatRefreshInterval === 'off') return false;
  try {
    const result = await message({ type: 'SCHOLIA_REFRESH_CHATGPT_CONTEXT_FOR_QUICK_CHAT' });
    if (result?.context) settings.chatgptWebContext = result.context;
    return Boolean(
      result?.context?.available
      || result?.context?.memory
      || result?.context?.projectContext
      || imported.available
    );
  } catch {
    return Boolean(imported.available);
  }
}

async function quickPdfCapture(source, question) {
  const signal = quickCaptureController?.signal;
  try {
    // Reuse the reader's complete/OCR-enriched index, including local files
    // whose bytes cannot be fetched from a public PDF URL.
    const prepared = await message({
      type: 'SCHOLIA_GET_ACTIVE_CONTEXT', expectedTabId: source.tabId,
      expectedFrameId: source.frameId, expectedUrl: source.tabUrl,
      question, includeContext: true, maxChars: contextCharacterLimit(quickContextMode)
    }).catch(() => null);
    if (signal?.aborted) throw new DOMException('PDF capture was cancelled.', 'AbortError');
    if (prepared?.pdfContextReady) {
      if (prepared.extractedCharacters > 0) return { ...source, ...prepared, imageDataUrl: '' };
      return message({ type: 'SCHOLIA_CAPTURE_ACTIVE_VISIBLE', expectedTabId: source.tabId });
    }
    const blob = await fetchPdfBlob(source.pdfUrl, { signal });
    const extracted = await extractPdfContext(blob, { signal });
    const context = extracted.extractedCharacters
      ? packPageContext(extracted.context, {
        outline: extracted.outline,
        question,
        maxChars: contextCharacterLimit(quickContextMode)
      })
      : '';
    if (context) {
      return {
        ...source,
        pageTitle: extracted.title || source.pageTitle,
        context,
        imageDataUrl: ''
      };
    }
  } catch (error) {
    if (signal?.aborted) throw error;
  }
  return message({ type: 'SCHOLIA_CAPTURE_ACTIVE_VISIBLE', expectedTabId: source.tabId });
}

async function quickCaptureForQuestion(question) {
  if (!activeSource) activeSource = await message({ type: 'SCHOLIA_GET_ACTIVE_SOURCE' });
  if (quickContextMode === CONTEXT_MODE_NONE) {
    return { ...activeSource, context: '', imageDataUrl: '', useChatGptWebContext: false };
  }
  const capture = isPdfSource(activeSource)
    ? await quickPdfCapture(activeSource, question)
    : await message({
      type: 'SCHOLIA_GET_ACTIVE_CONTEXT',
      expectedTabId: activeSource.tabId,
      question,
      selection: '',
      includeContext: true,
      correlateTabs: false,
      expectedUrl: activeSource.tabUrl,
      maxChars: contextCharacterLimit(quickContextMode)
    });
  if (capture.canvasCourse) Object.assign(capture, await getCanvasCourseContext(capture.url, {
    question, maxChars: contextCharacterLimit(quickContextMode), signal: quickCaptureController?.signal,
    onProgress: (detail) => showStatus(detail)
  }));
  const firstQuestion = quickMessages.filter((entry) => entry.role === 'user').length === 1;
  return {
    ...activeSource,
    ...capture,
    useChatGptWebContext: firstQuestion
      ? await quickChatGptContextAvailable()
      : Boolean(capture.useChatGptWebContext)
  };
}

function stopQuickChat() {
  quickCaptureController?.abort();
  quickCaptureController = null;
  try { quickPort?.postMessage({ type: 'cancel', requestId: quickRequestId }); } catch {}
  quickPort?.disconnect();
  quickPort = null;
  const assistant = quickMessages.at(-1);
  if (assistant?.role === 'assistant' && assistant.streaming) {
    assistant.streaming = false;
    if (!assistant.content) quickMessages.pop();
  }
  quickStreaming = false;
  renderQuickMessages();
}

async function sendQuickChat(rawQuestion) {
  await modelSave;
  const question = String(rawQuestion || '').trim();
  if (!question || quickStreaming) return;
  const user = createUserTurn(question, null, quickFiles.options);
  if (!user) return;
  quickMessages.push(user);
  quickFiles.set();
  const assistant = { role: 'assistant', content: '', reasoning: '', streaming: true };
  quickMessages.push(assistant);
  quickStreaming = true;
  renderQuickMessages();
  const captureController = new AbortController();
  quickCaptureController = captureController;

  let capture;
  try {
    capture = await quickCaptureForQuestion(question);
  } catch (error) {
    if (captureController.signal.aborted || !quickStreaming) return;
    assistant.streaming = false;
    assistant.error = true;
    assistant.content = error?.message || 'Scholia could not read the current screen.';
    quickStreaming = false;
    quickCaptureController = null;
    renderQuickMessages();
    return;
  }
  if (captureController.signal.aborted || !quickStreaming) return;
  if (quickCaptureController === captureController) quickCaptureController = null;

  const conversation = requestConversation(quickMessages);
  conversation.pop();
  const chosen = selectedProviderModel();
  quickRequestId = crypto.randomUUID();
  const requestId = quickRequestId;
  const port = chrome.runtime.connect({ name: 'scholia-chat' });
  quickPort = port;
  port.onMessage.addListener((event) => {
    if (event.requestId !== requestId) return;
    if (event.type === 'token') {
      assistant.content += event.token || '';
      scheduleQuickRender();
    } else if (event.type === 'activity') {
      addActivity(assistant, event.activity);
      scheduleQuickRender();
    } else if (event.type === 'reasoning') {
      assistant.reasoning = `${assistant.reasoning || ''}${event.token || ''}`;
      scheduleQuickRender();
    } else if (event.type === 'done') {
      assistant.streaming = false;
      assistant.reasoning = event.reasoning || '';
      quickStreaming = false;
      renderQuickMessages();
      port.disconnect();
      if (quickPort === port) quickPort = null;
    } else if (event.type === 'error') {
      assistant.streaming = false;
      assistant.error = true;
      assistant.content = event.error || 'The provider request failed.';
      quickStreaming = false;
      renderQuickMessages();
      port.disconnect();
      if (quickPort === port) quickPort = null;
    } else if (event.type === 'cancelled') {
      assistant.streaming = false;
      quickStreaming = false;
      renderQuickMessages();
    }
  });
  port.onDisconnect.addListener(() => {
    if (!quickStreaming || quickRequestId !== requestId) return;
    assistant.streaming = false;
    assistant.error = true;
    assistant.content ||= chrome.runtime.lastError?.message
      || 'The connection closed before the provider replied. Try again.';
    quickStreaming = false;
    if (quickPort === port) quickPort = null;
    renderQuickMessages();
  });
  port.postMessage({
    type: 'start',
    requestId,
    payload: {
      ...chosen,
      messages: conversation,
      kind: capture.kind || 'text',
      selection: '',
      context: capture.context || '',
      includeContext: quickContextMode !== CONTEXT_MODE_NONE,
      compactContext: quickContextMode === CONTEXT_MODE_COMPACT,
      parentContext: '',
      pageTitle: capture.pageTitle || '',
      pageLanguage: capture.pageLanguage || navigator.language,
      url: capture.url || '',
      imageDataUrl: capture.imageDataUrl || '',
      useChatGptWebContext: quickContextMode !== CONTEXT_MODE_NONE
        && Boolean(capture.useChatGptWebContext)
    }
  });
}

function relativeTime(value) {
  const elapsed = Math.max(0, Date.now() - Number(value || 0));
  if (elapsed < 60_000) return 'now';
  if (elapsed < 60 * 60_000) return `${Math.floor(elapsed / 60_000)}m`;
  if (elapsed < 24 * 60 * 60_000) return `${Math.floor(elapsed / (60 * 60_000))}h`;
  if (elapsed < 7 * 24 * 60 * 60_000) return `${Math.floor(elapsed / (24 * 60 * 60_000))}d`;
  return new Date(value).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

function renderSite() {
  if (!activeSite) {
    elements.site.textContent = 'Website access unavailable';
    elements['site-state'].textContent = 'Current page';
    elements['site-dot'].className = 'status-dot';
    elements['site-toggle'].textContent = 'Open settings to manage website access';
    elements['site-toggle'].disabled = false;
    return;
  }
  elements.site.textContent = activeSite.site;
  elements['site-state'].textContent = activeSite.enabled ? 'Scholia is active here' : 'Scholia is inactive here';
  elements['site-dot'].className = `status-dot ${activeSite.enabled ? 'enabled' : 'disabled'}`;
  elements['site-toggle'].disabled = false;
  elements['site-toggle'].textContent = activeSite.mode === 'allowlist'
    ? activeSite.enabled ? 'Remove from whitelist' : 'Whitelist this website'
    : activeSite.enabled ? 'Disable on this website' : 'Enable on this website';
}

async function refreshSite() {
  try {
    activeSite = await message({ type: 'SCHOLIA_GET_ACTIVE_SITE' });
  } catch {
    activeSite = null;
  }
  renderSite();
}

function renderModel() {
  elements['model-select'].disabled = modelSaving;
  populateModelSelect(elements['model-select'], settings);
  populateReasoningSelect(elements['reasoning-select'], settings, { disabled: modelSaving });
  const provider = providerById(settings?.provider);
  const configured = settings?.configuredProviders?.includes(provider.id);
  const supportsFastMode = providerSupportsFastMode(provider);
  elements['fast-mode'].disabled = modelSaving || !supportsFastMode;
  elements['fast-mode'].title = supportsFastMode
    ? `Toggle Fast mode for ${provider.name} (uses more credits)`
    : 'Fast mode is available with Codex CLI and Claude Code';
  elements['fast-mode'].setAttribute('aria-pressed', String(supportsFastMode && Boolean(settings?.fastMode)));
  elements['fast-mode-state'].textContent = supportsFastMode ? settings?.fastMode ? 'On' : 'Off' : 'Unavailable';
  elements['model-hint'].textContent = configured || !provider.keyRequired
    ? supportsFastMode ? 'Changes apply to new turns. Fast uses more provider credits.' : 'Fast mode is available with Codex CLI and Claude Code.'
    : `${provider.name} still needs an API key in Settings.`;
}

function renderPdfAction() {
  const pdf = activeSource?.sourceKind === 'pdf' || Boolean(activeSource?.pdfUrl);
  const readerActive = Boolean(activeSource?.viewerSourceId || activeSource?.pdfReaderActive);
  elements['open-pdf-viewer'].hidden = !pdf || readerActive;
}

async function refreshSettings() {
  settings = await message({ type: 'SCHOLIA_GET_PUBLIC_SETTINGS' });
  renderResponseLanguage(settings);
  renderModel();
}

function chatRow(chat) {
  const row = document.createElement('div');
  row.className = 'chat-row';
  const open = document.createElement('button');
  open.type = 'button';
  open.className = 'chat-open';
  open.dataset.openChat = chat.id;
  const title = document.createElement('span');
  title.className = 'chat-title';
  title.textContent = chat.title;
  const meta = document.createElement('span');
  meta.className = 'chat-meta';
  meta.textContent = [chat.sourceTitle || chat.sourceUrl || 'Saved chat', relativeTime(chat.updatedAt)].filter(Boolean).join(' · ');
  open.append(title, meta);
  const remove = document.createElement('button');
  remove.type = 'button';
  remove.className = 'chat-delete';
  remove.dataset.deleteChat = chat.id;
  remove.title = `Delete ${chat.title}`;
  remove.setAttribute('aria-label', `Delete ${chat.title}`);
  remove.textContent = '×';
  row.append(open, remove);
  return row;
}

async function refreshChats() {
  const chats = await listChats();
  elements['chat-list'].textContent = '';
  for (const chat of chats.slice(0, 5)) elements['chat-list'].append(chatRow(chat));
  elements['chat-empty'].hidden = chats.length > 0;
  elements['clear-chats'].hidden = chats.length === 0;
  elements['chat-count'].textContent = chats.length ? String(chats.length) : '';
}

async function openSidebar(view = 'home', chatId = '') {
  if (!Number.isInteger(activeSource?.windowId)) {
    activeSource = await message({ type: 'SCHOLIA_GET_ACTIVE_SOURCE' });
  }
  const navigation = { id: crypto.randomUUID(), createdAt: Date.now(), view, chatId };
  await Promise.all([
    chrome.storage.session.set({ [PANEL_NAVIGATION_KEY]: navigation }),
    chrome.sidePanel.open({ windowId: activeSource.windowId })
  ]);
  window.close();
}

async function runPageCommand(command) {
  await message({ type: 'SCHOLIA_PANEL_COMMAND', command });
  window.close();
}

const quickFiles = mountFileComposer({
  button: elements['quick-attach'], container: elements['quick-files'], dropTarget: document.body, pasteTarget: elements['quick-input'],
  disabled: () => quickStreaming
});

elements.settings.addEventListener('click', () => chrome.runtime.openOptionsPage());
elements['open-exam-planner'].addEventListener('click', () => {
  openExamPlanner().then(() => window.close()).catch((error) => showStatus(error.message, true));
});
elements['model-settings'].addEventListener('click', () => chrome.runtime.openOptionsPage());
elements['quick-compact'].addEventListener('click', () => setQuickContextMode(
  quickContextMode === CONTEXT_MODE_COMPACT ? CONTEXT_MODE_FULL : CONTEXT_MODE_COMPACT
));
elements['quick-none'].addEventListener('click', () => setQuickContextMode(
  quickContextMode === CONTEXT_MODE_NONE ? CONTEXT_MODE_FULL : CONTEXT_MODE_NONE
));
elements['quick-reset'].addEventListener('click', () => {
  if (quickStreaming) return;
  quickMessages = [];
  quickFiles.set();
  renderQuickMessages();
  elements['quick-input'].focus();
});
elements['quick-input'].addEventListener('input', () => {
  elements['quick-input'].style.height = 'auto';
  elements['quick-input'].style.height = `${Math.min(elements['quick-input'].scrollHeight, 105)}px`;
});
elements['quick-input'].addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    elements['quick-form'].requestSubmit();
  }
});
elements['quick-form'].addEventListener('submit', (event) => {
  event.preventDefault();
  if (quickStreaming) {
    stopQuickChat();
    return;
  }
  if (quickFiles.busy) return;
  const question = elements['quick-input'].value.trim() || (quickFiles.files.length ? 'Explain the attached files.' : '');
  if (!question) return;
  elements['quick-input'].value = '';
  elements['quick-input'].style.height = 'auto';
  sendQuickChat(question).catch((error) => showStatus(error.message, true));
});
elements['quick-messages'].addEventListener('click', (event) => {
  void copyCodeBlock(event, (error) => showStatus(error.message, true));
});
elements['site-toggle'].addEventListener('click', async () => {
  if (!activeSite) {
    chrome.runtime.openOptionsPage();
    return;
  }
  elements['site-toggle'].disabled = true;
  try {
    activeSite = await message({ type: 'SCHOLIA_SET_ACTIVE_SITE_ENABLED', enabled: !activeSite.enabled });
    renderSite();
    showStatus(activeSite.mode === 'allowlist'
      ? activeSite.enabled ? 'Website added to the whitelist.' : 'Website removed from the whitelist.'
      : activeSite.enabled ? 'Scholia enabled on this website.' : 'Scholia disabled on this website.');
  } catch (error) {
    showStatus(error.message, true);
    elements['site-toggle'].disabled = false;
  }
});
elements['open-sidebar'].addEventListener('click', () => openSidebar('home').catch((error) => showStatus(error.message, true)));
elements['new-chat'].addEventListener('click', () => openSidebar('new').catch((error) => showStatus(error.message, true)));
elements['open-pdf'].addEventListener('click', async () => {
  elements['open-pdf'].disabled = true;
  try {
    await message({ type: 'SCHOLIA_OPEN_MANUAL_PDF_VIEWER' });
    window.close();
  } catch (error) {
    showStatus(error.message, true);
    elements['open-pdf'].disabled = false;
  }
});
elements['open-pdf-viewer'].addEventListener('click', async () => {
  elements['open-pdf-viewer'].disabled = true;
  showStatus('Opening selectable Scholia PDF view…');
  try {
    await message({ type: 'SCHOLIA_OPEN_PDF_VIEWER' });
    window.close();
  } catch (error) {
    showStatus(error.message, true);
    elements['open-pdf-viewer'].disabled = false;
  }
});
elements.explain.addEventListener('click', () => runPageCommand('SCHOLIA_EXPLAIN_CURRENT').catch((error) => showStatus(error.message, true)));
elements.capture.addEventListener('click', () => runPageCommand('SCHOLIA_START_CAPTURE').catch((error) => showStatus(error.message, true)));
function saveInlineModel({ reasoningEffort, fastMode } = {}) {
  if (modelSaving) return modelSave;
  const chosen = parseModelChoice(elements['model-select'].value);
  modelSaving = true;
  for (const id of ['model-select', 'reasoning-select', 'fast-mode']) {
    elements[id].disabled = true;
  }
  modelSave = (async () => {
    try {
      settings = await message({ type: 'SCHOLIA_SAVE_MODEL', ...chosen, reasoningEffort, fastMode });
      showStatus('Preferences saved for your next message.');
    } catch (error) {
      showStatus(error.message, true);
    } finally {
      modelSaving = false;
      renderModel();
    }
  })();
  return modelSave;
}
elements['model-select'].addEventListener('change', () => saveInlineModel());
elements['reasoning-select'].addEventListener('change', () => saveInlineModel({ reasoningEffort: elements['reasoning-select'].value }));
elements['fast-mode'].addEventListener('click', () => saveInlineModel({ fastMode: !settings?.fastMode }));
elements['chat-list'].addEventListener('click', async (event) => {
  const remove = event.target.closest?.('[data-delete-chat]');
  if (remove) {
    await deleteChat(remove.dataset.deleteChat);
    await refreshChats();
    showStatus('Chat deleted.');
    return;
  }
  const open = event.target.closest?.('[data-open-chat]');
  if (open) await openSidebar('chat', open.dataset.openChat);
});
elements['clear-chats'].addEventListener('click', async () => {
  if (!confirm('Delete every saved Scholia chat from this device?')) return;
  await clearChats();
  await refreshChats();
  showStatus('Saved chats cleared.');
});

mountResponseLanguage({ message, onSettings: (value) => { settings = value; }, onError: (error) => showStatus(error.message, true) });

chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local' && changes[SETTINGS_KEY]) refreshSettings().catch(() => {});
  if (area === 'local' && changes[CHAT_HISTORY_KEY]) refreshChats().catch(() => {});
});

async function boot() {
  const sourceTask = message({ type: 'SCHOLIA_GET_ACTIVE_SOURCE' }).then((source) => {
    activeSource = source;
    renderPdfAction();
  });
  await Promise.all([sourceTask, refreshSettings(), refreshSite(), refreshChats()]);
  quickContextMode = defaultContextMode(settings);
  renderQuickContextMode();
  renderQuickMessages();
  elements['quick-input'].focus();
}

boot().catch((error) => showStatus(error.message, true));
