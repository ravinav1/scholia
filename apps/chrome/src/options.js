import { PROVIDERS, mergeSettings, modelId, modelLabel, modelReasoning, modelSupportsImages, normalizeSiteKey, providerById, providerModelChoices, providerSupportsFastMode, resolveModelId } from '../../../packages/core/src/providers.js';
import { CHATGPT_QUICK_CHAT_REFRESH_INTERVALS } from '../../../packages/core/src/chatgpt-context.js';
import { bridgeLaunchDecision } from './bridge-launch.js';
import { sendRuntimeMessage as message } from './runtime-message.js';
import { formatUsageRemaining } from './usage.js';
import { chatGptMemoryTextIsUsable } from './chatgpt-web.js';
import { copyText as writeClipboardText } from './clipboard.js';
import { loadExamWorkspaceUrl, openExamPlanner, saveExamWorkspaceUrl } from './exam-planner-launch.js';

const elements = Object.fromEntries([
  'settings-form', 'provider', 'language', 'explain-on-selection', 'include-context',
  'exam-workspace-url', 'exam-workspace-save', 'exam-workspace-status', 'open-exam-planner',
  'open-shortcuts', 'capture-region-shortcut', 'quick-chat-shortcut',
  'provider-name', 'vision-badge', 'model', 'model-list', 'endpoint', 'key-row',
  'api-key', 'key-hint', 'local-note', 'reveal-key', 'test', 'status',
  'reasoning-row', 'reasoning', 'fast-row', 'fast-mode', 'bridge-card', 'bridge-dot',
  'bridge-status', 'bridge-detail', 'bridge-start', 'bridge-copy', 'bridge-install',
  'chatgpt-web-enabled', 'chatgpt-web-auto-use', 'chatgpt-web-status', 'chatgpt-web-heading', 'chatgpt-web-detail',
  'chatgpt-quick-chat-refresh', 'chatgpt-quick-chat-refresh-detail',
  'chatgpt-web-open', 'chatgpt-web-refresh', 'chatgpt-memory', 'chatgpt-memory-import',
  'chatgpt-memory-capture', 'chatgpt-memory-clear', 'chatgpt-project-name', 'chatgpt-project-url',
  'chatgpt-project-context', 'chatgpt-project-import', 'chatgpt-project-clear',
  'site-access-mode', 'site-list-title', 'site-policy-copy', 'site-entry', 'site-add',
  'site-list', 'site-list-empty'
].map((id) => [id, document.getElementById(id)]));

let settings = mergeSettings();
let renderedProviderId = settings.provider;
let bridgeStatus = null;
let bridgeRequest = 0;
let bridgeLaunchState = null;
let bridgeLaunchPending = false;
let bridgeLaunchTimer = 0;
let chatGptWebState = null;
let chatGptWebRequest = 0;
let chatGptFocusTimer = 0;
let chatGptMemoryImporting = false;

async function renderShortcuts() {
  const labels = {
    'capture-region': elements['capture-region-shortcut'],
    'quick-chat': elements['quick-chat-shortcut']
  };
  try {
    const commands = await chrome.commands.getAll();
    for (const [name, element] of Object.entries(labels)) {
      const shortcut = commands.find((command) => command.name === name)?.shortcut;
      element.textContent = shortcut || 'Not assigned';
      element.classList.toggle('is-unassigned', !shortcut);
    }
  } catch {
    for (const element of Object.values(labels)) element.textContent = 'Open Chrome settings';
  }
}

function wait(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function showStatus(text, error = false) {
  elements.status.textContent = text;
  elements.status.classList.toggle('error', error);
}

function renderProviderOptions() {
  elements.provider.textContent = '';
  for (const provider of PROVIDERS) {
    const option = document.createElement('option');
    option.value = provider.id;
    option.textContent = provider.name;
    elements.provider.append(option);
  }
}

function renderChatGptRefreshOptions() {
  elements['chatgpt-quick-chat-refresh'].textContent = '';
  for (const interval of CHATGPT_QUICK_CHAT_REFRESH_INTERVALS) {
    const option = document.createElement('option');
    option.value = interval.id;
    option.textContent = interval.label;
    elements['chatgpt-quick-chat-refresh'].append(option);
  }
}

function renderChatGptRefreshDetail(context = settings.chatgptWebContext || {}) {
  const enabled = context.quickChatRefreshInterval && context.quickChatRefreshInterval !== 'off';
  const fetchedAt = Number(context.fetchedAt || 0);
  const lastFetched = fetchedAt
    ? ` Last fetched ${new Date(fetchedAt).toLocaleString()}.`
    : ' No memory snapshot has been fetched yet.';
  elements['chatgpt-quick-chat-refresh-detail'].textContent = enabled
    ? `Scholia refreshes on this schedule through a temporary background ChatGPT tab. Quick Chat uses the latest saved snapshot immediately and catches up in the background if a refresh was missed.${lastFetched}`
    : `Manual only. Quick Chat will not automatically refresh or include the saved snapshot.${lastFetched}`;
}

function rememberVisibleProvider(providerId = renderedProviderId) {
  const provider = providerById(providerId);
  settings.models[provider.id] = resolveModelId(
    provider,
    elements.model.value.trim() || provider.defaultModel,
    settings
  );
  settings.endpoints[provider.id] = elements.endpoint.value.trim() || provider.endpoint;
  settings.apiKeys[provider.id] = elements['api-key'].value.trim();
  if (!elements['reasoning-row'].hidden) settings.reasoningEfforts[provider.id] = elements.reasoning.value;
  settings.fastMode = elements['fast-mode'].checked;
  const model = settings.models[provider.id];
  if (!providerModelChoices(provider, settings, { includeSelected: false }).some((entry) => modelId(entry) === model)) {
    settings.customModels[provider.id] = [...new Set([...(settings.customModels[provider.id] || []), model])];
  }
}

function renderReasoning(provider, model) {
  const config = modelReasoning(provider, model, settings);
  elements['reasoning-row'].hidden = !config;
  elements.reasoning.textContent = '';
  if (config) {
    const current = config.efforts.includes(settings.reasoningEfforts[provider.id])
      ? settings.reasoningEfforts[provider.id]
      : config.default;
    for (const effort of config.efforts) {
      const option = document.createElement('option');
      option.value = effort;
      option.textContent = effort;
      option.selected = effort === current;
      elements.reasoning.append(option);
    }
  }
  elements['fast-row'].hidden = !providerSupportsFastMode(provider);
  elements['fast-mode'].checked = Boolean(settings.fastMode);
}

function renderVisionCapability(provider, model) {
  if (provider.imageCapability === 'bridge-health') {
    elements['vision-badge'].textContent = 'Bridge-reported vision';
    elements['vision-badge'].classList.add('no-vision');
    return;
  }
  const supportsImages = provider.supportsImages
    && modelSupportsImages(provider, model, settings);
  elements['vision-badge'].textContent = supportsImages ? 'Vision capable' : 'Text only';
  elements['vision-badge'].classList.toggle('no-vision', !supportsImages);
}

function renderProvider(providerId = elements.provider.value, { refreshBridge = true } = {}) {
  const provider = providerById(providerId);
  renderedProviderId = provider.id;
  elements['provider-name'].textContent = provider.name;
  elements.model.value = settings.models[provider.id] || provider.defaultModel;
  renderVisionCapability(provider, elements.model.value);
  elements.endpoint.value = settings.endpoints[provider.id] || provider.endpoint;
  elements['api-key'].value = settings.apiKeys[provider.id] || '';
  elements['api-key'].placeholder = provider.keyHint || 'No key required';
  elements['key-hint'].textContent = provider.keyRequired
    ? `Required by ${provider.name}. Saved only in extension-local storage.`
    : provider.id === 'opencode'
      ? 'Optional opencode server password. Sent as HTTP Basic auth with username “opencode”.'
      : 'Optional. Leave blank unless your local or custom endpoint requires a bearer token.';
  elements['local-note'].hidden = provider.keyRequired;
  elements['model-list'].textContent = '';
  for (const entry of providerModelChoices(provider, settings)) {
    const model = modelId(entry);
    const label = modelLabel(entry);
    const option = document.createElement('option');
    option.value = model;
    option.label = label;
    elements['model-list'].append(option);
  }
  renderReasoning(provider, elements.model.value);
  elements['bridge-card'].hidden = !provider.localBridge;
  if (provider.localBridge && refreshBridge) refreshBridgeStatus();
  else bridgeStatus = null;
}

function renderAll() {
  elements.provider.value = settings.provider;
  elements.language.value = settings.language;
  elements['explain-on-selection'].checked = settings.explainOnSelection;
  elements['include-context'].checked = settings.includePageContext;
  const chatGpt = settings.chatgptWebContext || {};
  elements['chatgpt-web-enabled'].checked = Boolean(chatGpt.enabled);
  elements['chatgpt-web-auto-use'].checked = chatGpt.autoUseOnChatGpt !== false;
  elements['chatgpt-quick-chat-refresh'].value = chatGpt.quickChatRefreshInterval || 'off';
  elements['chatgpt-memory'].value = chatGpt.memory || '';
  elements['chatgpt-project-name'].value = chatGpt.projectName || '';
  elements['chatgpt-project-url'].value = chatGpt.projectUrl || '';
  elements['chatgpt-project-context'].value = chatGpt.projectContext || '';
  renderChatGptRefreshDetail(chatGpt);
  elements['site-access-mode'].value = settings.siteAccessMode;
  renderProvider(settings.provider);
  renderSitePolicy();
}

function paintChatGptWebState(state) {
  chatGptWebState = state;
  const connected = Boolean(state?.open && state?.supported && !state?.connectionError);
  const signedIn = connected && Boolean(state?.loggedIn);
  elements['chatgpt-web-status'].textContent = signedIn ? 'Signed in' : connected ? 'Connected' : state?.open ? 'Can’t connect' : 'Not open';
  elements['chatgpt-web-status'].classList.toggle('no-vision', !connected);
  elements['chatgpt-web-heading'].textContent = signedIn
    ? state.projectName ? `Connected · ${state.projectName}` : 'Connected to ChatGPT in Chrome'
    : connected
      ? 'Connected to ChatGPT. Its current UI does not expose a reliable signed-in marker.'
      : state?.open ? 'A ChatGPT tab is open, but Scholia cannot read it.' : 'Open ChatGPT and sign in to import context.';
  const capture = state?.captureText
    ? state.captureKind === 'memory'
      ? `${state.capturedCharacters.toLocaleString()} characters collected from ChatGPT Memory summary.`
      : `${state.capturedCharacters.toLocaleString()} visible characters ready to import from the ${state.captureKind}.`
    : connected ? 'Use Get full memory, or select project text in ChatGPT and return here.' : '';
  elements['chatgpt-web-detail'].textContent = state?.error || capture;
  elements['chatgpt-memory-import'].disabled = chatGptMemoryImporting;
  elements['chatgpt-memory-capture'].disabled = !connected || state?.captureKind !== 'selection';
  elements['chatgpt-project-import'].disabled = !connected || !state?.captureText || state.captureKind === 'memory';
  return connected;
}

async function refreshChatGptWebState({ announce = false } = {}) {
  const request = ++chatGptWebRequest;
  elements['chatgpt-web-status'].textContent = 'Checking…';
  try {
    const state = await message({ type: 'SCHOLIA_GET_CHATGPT_WEB_STATE' });
    if (request !== chatGptWebRequest) return;
    const connected = paintChatGptWebState(state);
    if (announce) showStatus(
      connected ? state.loggedIn ? 'Connected to the signed-in ChatGPT tab.' : 'Connected to ChatGPT; select the context you want to import.' : state.error || 'Open ChatGPT and sign in, then check again.',
      !connected
    );
  } catch (error) {
    if (request !== chatGptWebRequest) return;
    paintChatGptWebState({ open: false, loggedIn: false, error: error.message });
    if (announce) showStatus(error.message, true);
  }
}

function refreshChatGptWebStateOnReturn() {
  clearTimeout(chatGptFocusTimer);
  if (document.visibilityState === 'hidden') return;
  chatGptFocusTimer = setTimeout(() => refreshChatGptWebState(), 150);
}

function importChatGptCapture(kind) {
  const text = String(chatGptWebState?.captureText || '').trim();
  if (!text) {
    showStatus('Select the text in ChatGPT, or leave its Memory/Project settings dialog open, then click Check again.', true);
    return;
  }
  if (kind === 'memory') {
    if (chatGptWebState?.captureKind !== 'selection') {
      showStatus('Select the fallback memory text in ChatGPT first, then return here.', true);
      return;
    }
    if (!chatGptMemoryTextIsUsable(text)) {
      showStatus('That selection is the Personalization settings page, not a memory summary. Your saved memory was not changed.', true);
      return;
    }
    elements['chatgpt-memory'].value = text;
  } else {
    if (chatGptWebState?.captureKind === 'memory') {
      showStatus('Select project instructions or project text before importing project context.', true);
      return;
    }
    elements['chatgpt-project-context'].value = text;
    if (chatGptWebState.projectName) elements['chatgpt-project-name'].value = chatGptWebState.projectName;
    if (chatGptWebState.projectUrl) elements['chatgpt-project-url'].value = chatGptWebState.projectUrl;
  }
  showStatus(`Imported the visible ChatGPT ${chatGptWebState.captureKind} as ${kind} context. Review it, then save settings.`);
}

async function importFullChatGptMemory() {
  chatGptMemoryImporting = true;
  elements['chatgpt-memory-import'].disabled = true;
  showStatus('Opening ChatGPT Personalization and collecting Memory summary…');
  try {
    const state = await message({ type: 'SCHOLIA_IMPORT_CHATGPT_MEMORY' });
    paintChatGptWebState(state);
    const memory = String(state?.memoryText || '').trim();
    if (!chatGptMemoryTextIsUsable(memory)) {
      throw new Error('ChatGPT did not expose a valid rendered memory summary. Your saved memory was not changed.');
    }
    elements['chatgpt-memory'].value = memory;
    if (state.projectName) elements['chatgpt-project-name'].value = state.projectName;
    if (state.projectUrl) elements['chatgpt-project-url'].value = state.projectUrl;
    elements['chatgpt-web-auto-use'].checked = true;
    const previous = settings.chatgptWebContext || {};
    settings = mergeSettings(await message({
      type: 'SCHOLIA_SAVE_SETTINGS',
      settings: {
        ...settings,
        chatgptWebContext: {
          ...previous,
          memory,
          projectName: state.projectName || previous.projectName,
          projectUrl: state.projectUrl || previous.projectUrl,
          autoUseOnChatGpt: true,
          updatedAt: Date.now(),
          fetchedAt: Date.now()
        }
      }
    }));
    renderChatGptRefreshDetail(settings.chatgptWebContext);
    showStatus(`Imported and saved ${memory.length.toLocaleString()} characters. Scholia will use this memory automatically on chatgpt.com.`);
  } catch (error) {
    showStatus(error.message, true);
  } finally {
    chatGptMemoryImporting = false;
    paintChatGptWebState(chatGptWebState || { open: false, loggedIn: false });
  }
}

function activeSiteList() {
  return settings.siteAccessMode === 'allowlist' ? settings.allowedSites : settings.disabledSites;
}

function renderSitePolicy() {
  const allowlist = settings.siteAccessMode === 'allowlist';
  const sites = activeSiteList();
  elements['site-list-title'].textContent = allowlist ? 'Whitelisted websites' : 'Blocked websites';
  elements['site-policy-copy'].textContent = allowlist
    ? 'Scholia stays inactive everywhere except the websites listed here. Add the current website quickly from the toolbar panel.'
    : 'Scholia runs everywhere except the websites listed here. Use ⊘ in the selection popup to block the current website.';
  elements['site-add'].textContent = allowlist ? 'Add to whitelist' : 'Block website';
  elements['site-list-empty'].textContent = allowlist
    ? 'No websites are whitelisted. Scholia is inactive everywhere.'
    : 'No websites are blocked. Scholia is enabled everywhere.';
  elements['site-list'].textContent = '';
  elements['site-list-empty'].hidden = sites.length > 0;
  for (const site of sites) {
    const row = document.createElement('div');
    row.className = 'site-row';
    const label = document.createElement('code');
    label.textContent = site;
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'quiet';
    button.textContent = allowlist ? 'Remove' : 'Enable';
    button.addEventListener('click', async () => {
      const listName = allowlist ? 'allowedSites' : 'disabledSites';
      const nextSettings = {
        ...settings,
        [listName]: settings[listName].filter((entry) => entry !== site)
      };
      try {
        settings = mergeSettings(await message({ type: 'SCHOLIA_SAVE_SETTINGS', settings: nextSettings }));
        renderSitePolicy();
      } catch (error) { showStatus(error.message, true); }
    });
    row.append(label, button);
    elements['site-list'].append(row);
  }
}

async function addSiteRule() {
  const site = normalizeSiteKey(elements['site-entry'].value);
  if (!site) {
    showStatus('Enter a valid hostname such as example.org.', true);
    return;
  }
  const listName = settings.siteAccessMode === 'allowlist' ? 'allowedSites' : 'disabledSites';
  const nextSettings = {
    ...settings,
    [listName]: [...new Set([...settings[listName], site])].sort()
  };
  try {
    settings = mergeSettings(await message({ type: 'SCHOLIA_SAVE_SETTINGS', settings: nextSettings }));
    elements['site-entry'].value = '';
    renderSitePolicy();
    showStatus('Website policy saved.');
  } catch (error) {
    showStatus(error.message, true);
  }
}

function paintBridgeStatus(status) {
  bridgeStatus = status;
  const provider = providerById(renderedProviderId);
  const selectedSupportsImages = Boolean(status.supportsImages)
    && modelSupportsImages(provider, elements.model.value.trim(), settings);
  elements['bridge-dot'].className = `status-dot ${status.up == null ? 'is-checking' : status.up ? 'is-up' : 'is-down'}`;
  elements['bridge-status'].textContent = status.up == null
    ? `Checking ${status.label || 'local bridge'}…`
    : status.up ? `${status.label} is running` : `${status.label} is offline`;
  const usage = formatUsageRemaining(status.usage);
  elements['bridge-detail'].textContent = status.up
    ? [status.health?.version || status.health?.claudeVersion || '', Array.isArray(status.models) ? `${status.models.length} models synced` : '', usage, selectedSupportsImages ? 'images enabled' : 'text only'].filter(Boolean).join(' · ')
    : `Expected at ${status.base || settings.endpoints[renderedProviderId]}.`;
  elements['bridge-start'].disabled = bridgeLaunchPending;
  elements['bridge-start'].textContent = bridgeLaunchPending ? 'Starting…' : status.up ? 'Check again' : 'Start bridge';
  elements['bridge-copy'].hidden = !status.command;
  elements['bridge-install'].hidden = !status.installCommand;
  if (provider.imageCapability === 'bridge-health' && status.up != null) {
    elements['vision-badge'].textContent = selectedSupportsImages ? 'Images enabled' : 'Text only';
    elements['vision-badge'].classList.toggle('no-vision', !selectedSupportsImages);
  }
}

async function refreshBridgeStatus({ includeUsage = false, timeoutMs, refreshModels = false } = {}) {
  const provider = providerById(renderedProviderId);
  if (!provider.localBridge) return null;
  const request = ++bridgeRequest;
  paintBridgeStatus({ up: null, label: provider.localBridge.label, base: settings.endpoints[provider.id] });
  try {
    const result = await message({
      type: 'SCHOLIA_BRIDGE_STATUS',
      provider: provider.id,
      includeUsage,
      refreshModels,
      ...(timeoutMs ? { timeoutMs } : {})
    });
    if (request === bridgeRequest && renderedProviderId === provider.id) {
      if (Array.isArray(result.models)) {
        settings.discoveredModels[provider.id] = result.models;
        renderProvider(provider.id, { refreshBridge: false });
      }
      paintBridgeStatus(result);
    }
    return result;
  } catch (error) {
    const result = { up: false, label: provider.localBridge.label, base: settings.endpoints[provider.id], error: error.message };
    if (request === bridgeRequest) paintBridgeStatus(result);
    return result;
  }
}

async function waitForBridgeStart(providerId) {
  for (const pause of [250, 350, 500, 700, 900]) {
    await wait(pause);
    if (renderedProviderId !== providerId) return false;
    const result = await refreshBridgeStatus({ includeUsage: false, timeoutMs: 650 });
    if (result?.up) return true;
  }
  return false;
}

function openBridge() {
  if (!bridgeStatus?.startUrl) return;
  if (bridgeStatus.up) {
    refreshBridgeStatus({ includeUsage: true, refreshModels: true });
    return;
  }
  const decision = bridgeLaunchDecision(bridgeLaunchState, bridgeStatus.startUrl);
  bridgeLaunchState = decision.state;
  if (!decision.allowed) {
    const seconds = Math.max(1, Math.ceil(decision.retryAfterMs / 1_000));
    showStatus(`A bridge launch was already requested. Wait ${seconds}s, or run the copied start command if no launcher opened.`);
    refreshBridgeStatus({ includeUsage: true });
    return;
  }
  bridgeLaunchPending = true;
  paintBridgeStatus(bridgeStatus);
  showStatus(`Opening ${bridgeStatus.label || 'the local bridge'}…`);
  const frame = document.createElement('iframe');
  frame.hidden = true;
  frame.src = bridgeStatus.startUrl;
  document.body.append(frame);
  setTimeout(() => frame.remove(), 1_500);
  clearTimeout(bridgeLaunchTimer);
  const providerId = renderedProviderId;
  bridgeLaunchTimer = setTimeout(async () => {
    const started = await waitForBridgeStart(providerId);
    if (renderedProviderId !== providerId) return;
    bridgeLaunchPending = false;
    if (bridgeStatus) paintBridgeStatus(bridgeStatus);
    if (!started) {
      showStatus('The bridge did not start. Its URL launcher may not be installed; copy the start command or launcher installer below.', true);
    }
  }, 0);
}

async function copyText(value) {
  if (!value) return;
  await writeClipboardText(value);
  showStatus(`Copied: ${value}`);
}

function collect() {
  rememberVisibleProvider();
  settings.provider = elements.provider.value;
  settings.language = elements.language.value;
  settings.explainOnSelection = elements['explain-on-selection'].checked;
  settings.includePageContext = elements['include-context'].checked;
  const previousChatGpt = settings.chatgptWebContext || {};
  const nextChatGpt = {
    enabled: elements['chatgpt-web-enabled'].checked,
    autoUseOnChatGpt: elements['chatgpt-web-auto-use'].checked,
    quickChatRefreshInterval: elements['chatgpt-quick-chat-refresh'].value,
    memory: elements['chatgpt-memory'].value,
    projectName: elements['chatgpt-project-name'].value,
    projectUrl: elements['chatgpt-project-url'].value,
    projectContext: elements['chatgpt-project-context'].value
  };
  const changed = ['memory', 'projectName', 'projectUrl', 'projectContext']
    .some((key) => String(nextChatGpt[key] || '').trim() !== String(previousChatGpt[key] || '').trim());
  settings.chatgptWebContext = {
    ...nextChatGpt,
    updatedAt: changed ? Date.now() : previousChatGpt.updatedAt,
    fetchedAt: String(nextChatGpt.memory || '').trim() ? previousChatGpt.fetchedAt : 0
  };
  settings.siteAccessMode = elements['site-access-mode'].value;
  return settings;
}

async function save() {
  settings = mergeSettings(await message({ type: 'SCHOLIA_SAVE_SETTINGS', settings: collect() }));
  showStatus('Saved. New explanations will use these settings.');
  if (providerById(settings.provider).localBridge) refreshBridgeStatus();
}

elements.provider.addEventListener('change', () => {
  rememberVisibleProvider();
  settings.provider = elements.provider.value;
  renderProvider(settings.provider);
  showStatus('');
});

elements['reveal-key'].addEventListener('click', () => {
  const reveal = elements['api-key'].type === 'password';
  elements['api-key'].type = reveal ? 'text' : 'password';
  elements['reveal-key'].textContent = reveal ? 'Hide' : 'Show';
});
async function saveExamWorkspace() {
  const url = await saveExamWorkspaceUrl(elements['exam-workspace-url'].value);
  elements['exam-workspace-url'].value = url;
  elements['exam-workspace-status'].textContent = 'Website address saved.';
  return url;
}
elements['exam-workspace-save'].addEventListener('click', () => {
  saveExamWorkspace().catch((error) => { elements['exam-workspace-status'].textContent = error.message; });
});
elements['open-exam-planner'].addEventListener('click', () => {
  saveExamWorkspace().then(openExamPlanner)
    .catch((error) => { elements['exam-workspace-status'].textContent = error.message; });
});
loadExamWorkspaceUrl().then((url) => { elements['exam-workspace-url'].value = url; })
  .catch((error) => { elements['exam-workspace-status'].textContent = error.message; });

elements['open-shortcuts'].addEventListener('click', () => {
  chrome.tabs.create({ url: 'chrome://extensions/shortcuts' });
});

elements.model.addEventListener('input', () => {
  const provider = providerById(renderedProviderId);
  const model = elements.model.value.trim();
  renderReasoning(provider, model);
  renderVisionCapability(provider, model);
});
elements['chatgpt-quick-chat-refresh'].addEventListener('change', () => {
  renderChatGptRefreshDetail({
    ...(settings.chatgptWebContext || {}),
    quickChatRefreshInterval: elements['chatgpt-quick-chat-refresh'].value
  });
});
elements['site-access-mode'].addEventListener('change', () => {
  settings.siteAccessMode = elements['site-access-mode'].value;
  renderSitePolicy();
});
elements['site-add'].addEventListener('click', addSiteRule);
elements['site-entry'].addEventListener('keydown', (event) => {
  if (event.key === 'Enter') { event.preventDefault(); addSiteRule(); }
});
elements['bridge-start'].addEventListener('click', openBridge);
elements['bridge-copy'].addEventListener('click', () => copyText(bridgeStatus?.command).catch((error) => showStatus(error.message, true)));
elements['bridge-install'].addEventListener('click', () => copyText(bridgeStatus?.installCommand).catch((error) => showStatus(error.message, true)));
elements['chatgpt-web-open'].addEventListener('click', async () => {
  elements['chatgpt-web-open'].disabled = true;
  elements['chatgpt-web-detail'].textContent = 'Connecting before opening the ChatGPT tab…';
  try {
    const opened = await message({ type: 'SCHOLIA_OPEN_CHATGPT_WEB' });
    if (opened?.state) paintChatGptWebState(opened.state);
    showStatus('ChatGPT opened. Select memory or project text, then return to this Settings tab.');
  } catch (error) {
    showStatus(error.message, true);
  } finally {
    elements['chatgpt-web-open'].disabled = false;
  }
});
elements['chatgpt-web-refresh'].addEventListener('click', () => refreshChatGptWebState({ announce: true }));
elements['chatgpt-memory-import'].addEventListener('click', importFullChatGptMemory);
elements['chatgpt-memory-capture'].addEventListener('click', () => importChatGptCapture('memory'));
elements['chatgpt-project-import'].addEventListener('click', () => importChatGptCapture('project'));
elements['chatgpt-memory-clear'].addEventListener('click', () => { elements['chatgpt-memory'].value = ''; });
elements['chatgpt-project-clear'].addEventListener('click', () => {
  elements['chatgpt-project-name'].value = '';
  elements['chatgpt-project-url'].value = '';
  elements['chatgpt-project-context'].value = '';
});

window.addEventListener('focus', refreshChatGptWebStateOnReturn);
window.addEventListener('focus', renderShortcuts);
document.addEventListener('visibilitychange', refreshChatGptWebStateOnReturn);

elements['settings-form'].addEventListener('submit', async (event) => {
  event.preventDefault();
  showStatus('Saving…');
  try { await save(); } catch (error) { showStatus(error.message, true); }
});

elements.test.addEventListener('click', async () => {
  showStatus('Saving and testing…');
  elements.test.disabled = true;
  try {
    await save();
    const provider = providerById(settings.provider);
    const result = await message({ type: 'SCHOLIA_TEST_PROVIDER', provider: provider.id, model: settings.models[provider.id] });
    showStatus(`Connected to ${provider.name} · ${result.model}: ${result.text || 'response received'}`);
  } catch (error) {
    showStatus(error.message, true);
  } finally {
    elements.test.disabled = false;
  }
});

async function boot() {
  renderProviderOptions();
  renderChatGptRefreshOptions();
  try {
    settings = mergeSettings(await message({ type: 'SCHOLIA_GET_SETTINGS' }));
    renderAll();
    renderShortcuts();
    refreshChatGptWebState();
  } catch (error) {
    showStatus(error.message, true);
  }
}

boot();
