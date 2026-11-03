import {
  mergeSettings,
  modelSupportsImages,
  modelReasoning,
  providerById,
  providerSupportsFastMode,
  providerSupportsWebSearch
} from '../../../packages/core/src/providers.js';
import { fetchOpencodeModels } from './opencode-models.js';
import { initialUserPrompt, normalizeLanguage, sanitizeConversation, systemPrompt } from '../../../packages/core/src/prompt.js';
import { packPageContext } from '../../../packages/core/src/context.js';
import {
  formatChatGptWebContext,
  formatChatGptWebContextForPage,
  isChatGptWebUrl
} from '../../../packages/core/src/chatgpt-context.js';
import {
  boundedProviderReasoning,
  reasoningDeltaFromProviderEvent,
  reasoningFromOpencodeResponse,
  reasoningFromProviderResponse
} from './provider-reasoning.js';

const COMPACT_ACCOUNT_CONTEXT_CHARS = 4_000;

function assertSecureEndpoint(endpoint, providerName) {
  let url;
  try {
    url = new URL(endpoint);
  } catch {
    throw new Error(`Set a valid endpoint for ${providerName} in Scholia settings.`);
  }

  const host = url.hostname.toLowerCase();
  const loopback = host === 'localhost'
    || host.endsWith('.localhost')
    || host === '[::1]'
    || /^127(?:\.\d{1,3}){3}$/.test(host);
  if (url.username || url.password) {
    throw new Error(`Remove embedded credentials from the ${providerName} endpoint and use the API key field.`);
  }
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback)) {
    throw new Error(`${providerName} must use HTTPS unless it runs on this device.`);
  }
}

function endpointBase(endpoint) {
  const clean = String(endpoint || '').trim().replace(/\/+$/, '');
  return clean.replace(/\/v1\/chat\/completions$/i, '');
}

function endpointPort(endpoint, fallback) {
  try { return Number(new URL(endpoint).port) || fallback; } catch { return fallback; }
}

function basicAuthorization(username, password) {
  const bytes = new TextEncoder().encode(`${username}:${password}`);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return `Basic ${btoa(binary)}`;
}

function bridgeHeaders(provider, settings) {
  const key = String(settings.apiKeys[provider.id] || '').trim();
  if (!key) return {};
  if (provider.protocol === 'opencode') return { authorization: basicAuthorization('opencode', key) };
  return { authorization: `Bearer ${key}` };
}

function bridgeInstructions(provider, endpoint) {
  const bridge = provider.localBridge;
  const fallbackPort = bridge.port;
  const port = endpointPort(endpoint, fallbackPort);
  let startUrl = `${bridge.startScheme}://start`;
  if (bridge.startPortParameter) startUrl += `?${bridge.startPortParameter}=${port}`;
  const command = `${bridge.command} --port ${port}`;
  const installCommand = bridge.installCommand ? `${bridge.installCommand} --port ${port}` : '';
  return { startUrl, command, installCommand, port };
}

export async function discoverCodexModels(rawSettings, options = {}) {
  const settings = mergeSettings(rawSettings);
  const endpoint = String(settings.endpoints.codex || providerById('codex').endpoint).trim();
  assertSecureEndpoint(endpoint, 'Codex');
  const signal = AbortSignal.any([AbortSignal.timeout(options.timeoutMs || 15_000), ...(options.signal ? [options.signal] : [])]);
  const response = await fetch(`${endpointBase(endpoint)}/v1/models`, {
    headers: settings.apiKeys.codex ? { authorization: `Bearer ${settings.apiKeys.codex}` } : {}, signal
  });
  if (!response.ok) throw new Error(`Codex model catalog returned HTTP ${response.status}.`);
  const result = await response.json();
  if (!Array.isArray(result.data)) throw new Error('Codex returned an invalid model catalog.');
  const models = mergeSettings({ discoveredModels: { codex: result.data } }).discoveredModels.codex || [];
  if (!models.length) throw new Error('Codex returned no models.');
  return { models };
}

export async function discoverOpencodeModels(rawSettings, options = {}) {
  const settings = mergeSettings(rawSettings);
  const provider = providerById('opencode');
  const endpoint = String(settings.endpoints[provider.id] || provider.endpoint).trim();
  assertSecureEndpoint(endpoint, provider.name);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs || 2_500);
  const abortFromParent = () => controller.abort();
  if (options.signal) {
    if (options.signal.aborted) controller.abort();
    else options.signal.addEventListener('abort', abortFromParent, { once: true });
  }
  try {
    const result = await fetchOpencodeModels({
      baseUrl: endpointBase(endpoint),
      headers: bridgeHeaders(provider, settings),
      signal: controller.signal
    });
    return { ...result, fetchedAt: Date.now() };
  } finally {
    clearTimeout(timeout);
    options.signal?.removeEventListener('abort', abortFromParent);
  }
}

export async function checkBridgeStatus(providerId, rawSettings, options = {}) {
  const settings = mergeSettings(rawSettings);
  const provider = providerById(providerId);
  if (!provider.localBridge) throw new Error(`${provider.name} does not use a local bridge.`);
  const endpoint = String(settings.endpoints[provider.id] || provider.endpoint).trim();
  const base = endpointBase(endpoint);
  const instructions = bridgeInstructions(provider, endpoint);
  try {
    assertSecureEndpoint(endpoint, provider.name);
  } catch (error) {
    return { up: false, provider: provider.id, label: provider.localBridge.label, base, ...instructions, error: error.message };
  }
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs || 1_800);
  const abortFromParent = () => controller.abort();
  if (options.signal) {
    if (options.signal.aborted) controller.abort();
    else options.signal.addEventListener('abort', abortFromParent, { once: true });
  }

  try {
    const response = await fetch(`${base}${provider.localBridge.healthPath}`, {
      method: 'GET',
      cache: 'no-store',
      headers: bridgeHeaders(provider, settings),
      signal: controller.signal
    });
    if (!response.ok) {
      return { up: false, provider: provider.id, label: provider.localBridge.label, base, ...instructions, error: `HTTP ${response.status}` };
    }
    const health = await response.json();
    const up = Boolean(health?.[provider.localBridge.healthField]);
    let usage = null;
    if (up && options.includeUsage && provider.localBridge.usagePath) {
      try {
        const usageResponse = await fetch(`${base}${provider.localBridge.usagePath}`, {
          method: 'GET', cache: 'no-store', headers: bridgeHeaders(provider, settings), signal: controller.signal
        });
        if (usageResponse.ok) usage = await usageResponse.json();
      } catch {}
    }
    return {
      up, provider: provider.id, label: provider.localBridge.label, base, health, usage,
      supportsImages: provider.supportsImages || Boolean(health?.images), ...instructions
    };
  } catch (error) {
    return {
      up: false, provider: provider.id, label: provider.localBridge.label, base, ...instructions,
      error: error?.name === 'AbortError' ? 'Connection timed out' : (error?.message || 'Bridge is unreachable')
    };
  } finally {
    clearTimeout(timeout);
    options.signal?.removeEventListener('abort', abortFromParent);
  }
}

function imageParts(dataUrl) {
  if (!dataUrl) return null;
  const match = /^data:(image\/[a-z0-9.+-]+);base64,([a-z0-9+/=\r\n]+)$/i.exec(dataUrl);
  if (!match) throw new Error('The captured image could not be encoded.');
  return { mediaType: match[1], base64: match[2].replace(/\s/g, '') };
}

function preparedConversation(payload, settings, { purpose = 'chat' } = {}) {
  const language = normalizeLanguage(payload.language ?? settings.language);
  const legacyImage = imageParts(payload.imageDataUrl);
  const conversation = sanitizeConversation(payload.messages).map((message, index) => {
    const { imageDataUrl, ...textMessage } = message;
    const image = imageParts(imageDataUrl) || (index === 0 ? legacyImage : null);
    return image ? { ...textMessage, image } : textMessage;
  });
  if (!conversation.length || conversation[0].role !== 'user') {
    throw new Error('Nothing was provided to explain.');
  }

  const first = conversation[0];
  const contextEnabled = payload.includeContext !== false;
  const compactContext = typeof payload.compactContext === 'boolean'
    ? payload.compactContext
    : settings.includePageContext !== false;
  const activeUserIndex = conversation.findLastIndex((message) => message.role === 'user');
  const activeQuestion = conversation[activeUserIndex]?.content || first.content;
  const quickChatAccountContextEnabled = settings.chatgptWebContext.quickChatRefreshInterval !== 'off';
  const manualAccountContext = contextEnabled && payload.useChatGptWebContext
    && (String(payload.parentContext || '').trim() || quickChatAccountContextEnabled)
    ? formatChatGptWebContext(settings.chatgptWebContext)
    : '';
  const automaticAccountContext = contextEnabled && isChatGptWebUrl(payload.url)
    ? formatChatGptWebContextForPage(settings.chatgptWebContext, payload.url)
    : '';
  const rawAccountContext = automaticAccountContext || manualAccountContext;
  const accountContext = rawAccountContext
    ? compactContext ? packPageContext(rawAccountContext, {
      question: activeQuestion,
      maxChars: COMPACT_ACCOUNT_CONTEXT_CHARS,
      scopeDescription: 'the locally saved ChatGPT memory and matching project snapshot',
      mapLabel: 'Saved context map'
    }) : rawAccountContext
    : '';
  const followUp = activeUserIndex > 0 && !conversation[activeUserIndex]?.image;
  conversation[0] = {
    ...first,
    role: 'user',
    content: initialUserPrompt({
      question: first.content,
      selection: payload.selection,
      context: followUp ? '' : contextEnabled ? payload.context : '',
      parentContext: followUp ? '' : payload.parentContext,
      accountContext: followUp ? '' : accountContext,
      pageTitle: followUp || !contextEnabled ? '' : payload.pageTitle,
      url: followUp || !contextEnabled ? '' : payload.url,
      kind: payload.kind,
      language,
      documentLanguage: payload.pageLanguage
    })
  };
  if (followUp) {
    const active = conversation[activeUserIndex];
    conversation[activeUserIndex] = {
      ...active,
      role: 'user',
      content: initialUserPrompt({
        question: active.content,
        selection: payload.selection,
        context: contextEnabled ? payload.context : '',
        parentContext: payload.parentContext,
        accountContext,
        pageTitle: contextEnabled ? payload.pageTitle : '',
        url: contextEnabled ? payload.url : '',
        kind: payload.kind,
        language,
        documentLanguage: payload.pageLanguage
      })
    };
  }

  return {
    language,
    conversation,
    hasImages: conversation.some((message) => Boolean(message.image)),
    learningMode: payload.learningMode,
    entirePDF: payload.entirePDF === true && contextEnabled,
    entireDocument: payload.entireDocument === true && contextEnabled,
    purpose
  };
}

function openAiMessages(prepared) {
  return [
    { role: 'system', content: systemPrompt(prepared.language, prepared) },
    ...prepared.conversation.map((message) => {
      const { image, ...textMessage } = message;
      if (!image || message.role !== 'user') return textMessage;
      return {
        role: 'user',
        content: [
          { type: 'text', text: message.content },
          { type: 'image_url', image_url: { url: `data:${image.mediaType};base64,${image.base64}` } }
        ]
      };
    })
  ];
}

function openAiResponsesInput(prepared) {
  return prepared.conversation.map((message) => {
    const { image, ...textMessage } = message;
    if (!image || message.role !== 'user') return textMessage;
    return {
      role: 'user',
      content: [
        { type: 'input_text', text: message.content },
        { type: 'input_image', image_url: `data:${image.mediaType};base64,${image.base64}` }
      ]
    };
  });
}

function openAiResponsesEndpoint(endpoint) {
  const url = new URL(endpoint);
  const pathname = url.pathname.replace(/\/+$/, '');
  if (/\/responses$/i.test(pathname)) return url.href;
  if (/\/chat\/completions$/i.test(pathname)) {
    url.pathname = pathname.replace(/\/chat\/completions$/i, '/responses');
    return url.href;
  }
  if (/\/v1$/i.test(pathname)) {
    url.pathname = `${pathname}/responses`;
    return url.href;
  }
  throw new Error('Web search requires an OpenAI Responses API endpoint ending in /v1/responses.');
}

function anthropicMessages(prepared) {
  return prepared.conversation.map((message) => {
    const { image, ...textMessage } = message;
    if (!image || message.role !== 'user') return textMessage;
    return {
      role: 'user',
      content: [
        { type: 'text', text: message.content },
        {
          type: 'image',
          source: { type: 'base64', media_type: image.mediaType, data: image.base64 }
        }
      ]
    };
  });
}

function ollamaMessages(prepared) {
  return [
    { role: 'system', content: systemPrompt(prepared.language, prepared) },
    ...prepared.conversation.map((message) => {
      const { image, ...textMessage } = message;
      return { ...textMessage, ...(image ? { images: [image.base64] } : {}) };
    })
  ];
}

export function buildProviderRequest(payload, rawSettings, options = {}) {
  const settings = mergeSettings(rawSettings);
  const providerId = payload.provider || settings.provider;
  const provider = providerById(providerId);
  const model = payload.model || settings.models[provider.id] || provider.defaultModel;
  const endpoint = String(settings.endpoints[provider.id] || provider.endpoint).trim();
  const key = String(settings.apiKeys[provider.id] || '').trim();
  const prepared = preparedConversation(payload, settings, options);
  const webSearch = payload.webSearch === true;

  if (!endpoint) throw new Error(`Set an endpoint for ${provider.name} in Scholia settings.`);
  assertSecureEndpoint(endpoint, provider.name);
  if (provider.keyRequired && !key) throw new Error(`Add your ${provider.name} API key in Scholia settings.`);
  if (webSearch && !providerSupportsWebSearch(provider)) {
    throw new Error(`Web search is not available through ${provider.name}. Choose OpenAI, Anthropic, OpenRouter, or the local Codex bridge.`);
  }
  if (prepared.hasImages && !provider.supportsImages && !payload.bridgeSupportsImages) {
    throw new Error(`${provider.name} cannot receive images. Choose a vision-capable provider.`);
  }
  if (prepared.hasImages && !modelSupportsImages(provider, model, settings)) {
    throw new Error(`${model} is text-only. Choose a vision-capable model or remove the image.`);
  }

  const headers = { 'content-type': 'application/json' };
  let body;
  let requestUrl = endpoint;
  let responseProtocol = provider.protocol;

  if (provider.protocol === 'anthropic') {
    headers['x-api-key'] = key;
    headers['anthropic-version'] = '2023-06-01';
    headers['anthropic-dangerous-direct-browser-access'] = 'true';
    body = {
      model,
      max_tokens: 1400,
      stream: true,
      system: systemPrompt(prepared.language, prepared),
      messages: anthropicMessages(prepared)
    };
    if (webSearch) {
      body.tools = [{ type: 'web_search_20250305', name: 'web_search', max_uses: 5 }];
    }
  } else if (provider.protocol === 'ollama') {
    if (key) headers.authorization = `Bearer ${key}`;
    body = { model, stream: true, messages: ollamaMessages(prepared), options: { temperature: 0.25 } };
  } else if (provider.protocol === 'opencode') {
    const reasoning = modelReasoning(provider, model, settings);
    const effort = String(payload.reasoningEffort || settings.reasoningEfforts[provider.id] || reasoning?.default || '');
    const variant = reasoning?.efforts?.includes(effort) ? effort : '';
    return { provider, model, variant, url: endpointBase(endpoint), prepared, key, fetchOptions: null };
  } else if (provider.protocol === 'cohere') {
    headers.authorization = `Bearer ${key}`;
    body = { model, stream: true, messages: openAiMessages(prepared), temperature: 0.25 };
  } else {
    if (key) headers.authorization = `Bearer ${key}`;
    if (webSearch && provider.id === 'openai') {
      requestUrl = openAiResponsesEndpoint(endpoint);
      responseProtocol = 'openai-responses';
      body = {
        model,
        stream: true,
        instructions: systemPrompt(prepared.language, prepared),
        input: openAiResponsesInput(prepared),
        tools: [{ type: 'web_search' }]
      };
      if (/^(?:gpt-[56](?:[.-]|$)|o\d(?:-|$))/i.test(model)) {
        body.reasoning = { summary: 'auto' };
      }
    } else {
      body = {
        model,
        stream: true,
        messages: openAiMessages(prepared),
        temperature: 0.25
      };
      if (webSearch && provider.id === 'openrouter') {
        body.tools = [{ type: 'openrouter:web_search' }];
      }
    }
    if (provider.id === 'claudecode' || provider.id === 'codex') {
      const reasoning = modelReasoning(provider, model, settings);
      const effort = String(payload.reasoningEffort || settings.reasoningEfforts[provider.id] || reasoning?.default || '');
      if (reasoning?.efforts?.includes(effort)) body.reasoning_effort = effort;
    }
    if (provider.id === 'openai' && /^gpt-6(?:[.-]|$)/.test(model)) {
      const reasoning = modelReasoning(provider, model, settings);
      const requested = payload.reasoningEffort || settings.reasoningEfforts[provider.id];
      const effort = reasoning?.efforts.includes(requested) ? requested : reasoning?.default || 'medium';
      delete body.temperature;
      if (responseProtocol === 'openai-responses') body.reasoning = { ...body.reasoning, effort };
      else body.reasoning_effort = effort;
    }
    if (provider.id === 'codex' && webSearch) body.web_search = true;
    if (providerSupportsFastMode(provider) && (payload.fastMode ?? settings.fastMode)) body.fast_mode = true;
  }

  return {
    provider,
    model,
    url: requestUrl,
    responseProtocol,
    webSearch,
    fetchOptions: { method: 'POST', headers, body: JSON.stringify(body) }
  };
}

function responseError(response, raw) {
  let detail = raw;
  try {
    const parsed = JSON.parse(raw);
    detail = parsed.error?.message || parsed.message || raw;
  } catch {}
  const suffix = detail ? `: ${String(detail).slice(0, 500)}` : '';
  return new Error(`${response.status} ${response.statusText || 'Provider request failed'}${suffix}`);
}

function textFromOpenAiEvent(data) {
  const delta = data?.choices?.[0]?.delta?.content;
  if (typeof delta === 'string') return delta;
  if (Array.isArray(delta)) return delta.map((part) => part?.text || '').join('');
  return '';
}

function textFromOpenAiResponsesEvent(data) {
  return data?.type === 'response.output_text.delta' && typeof data.delta === 'string'
    ? data.delta
    : '';
}

function textFromAnthropicEvent(data) {
  if (data?.type === 'content_block_delta' && data?.delta?.type === 'text_delta') return data.delta.text || '';
  return '';
}

function textFromCohereEvent(data) {
  if (data?.type === 'content-delta') return data?.delta?.message?.content?.text || '';
  return '';
}

function textFromOpenAiResponses(data) {
  if (typeof data?.output_text === 'string') return data.output_text;
  return (data?.output || []).flatMap((item) => item?.content || [])
    .filter((part) => part?.type === 'output_text' && typeof part.text === 'string')
    .map((part) => part.text)
    .join('');
}

function textFromJsonResponse(request, data) {
  if (request.responseProtocol === 'openai-responses') return textFromOpenAiResponses(data);
  if (request.provider.protocol === 'anthropic') {
    return (data?.content || []).map((part) => part?.text || '').join('');
  }
  if (request.provider.protocol === 'ollama') return data?.message?.content || data?.response || '';
  if (request.provider.protocol === 'cohere') return (data?.message?.content || []).map((part) => part?.text || '').join('');
  const content = data?.choices?.[0]?.message?.content;
  return typeof content === 'string' ? content : (content || []).map((part) => part?.text || '').join('');
}

function addWebCitation(citations, value) {
  const candidate = value?.url_citation || value?.citation || value;
  const rawUrl = String(candidate?.url || '').trim();
  if (!rawUrl) return;
  let url;
  try {
    const parsed = new URL(rawUrl);
    if (!['http:', 'https:'].includes(parsed.protocol) || parsed.username || parsed.password) return;
    parsed.hash = '';
    url = parsed.href;
  } catch { return; }
  const fallback = new URL(url).hostname.replace(/^www\./, '');
  const title = String(candidate?.title || fallback).replace(/\s+/g, ' ').trim().slice(0, 180) || fallback;
  if (!citations.has(url)) citations.set(url, title);
}

function collectWebCitations(value, citations) {
  if (!value) return;
  if (Array.isArray(value)) {
    for (const entry of value) collectWebCitations(entry, citations);
    return;
  }
  if (typeof value !== 'object') return;
  if (value.type === 'url_citation' || value.type === 'web_search_result_location') addWebCitation(citations, value);
  for (const key of ['annotation', 'annotations', 'citation', 'citations', 'content', 'delta', 'message', 'output', 'response', 'choices']) {
    collectWebCitations(value[key], citations);
  }
}

function containsWebSearchMarker(value) {
  if (!value) return false;
  if (Array.isArray(value)) return value.some(containsWebSearchMarker);
  if (typeof value !== 'object') return false;
  if (value.web_search_used === true) return true;
  if (/web_search/i.test(String(value.type || '')) || /^web_search$/i.test(String(value.name || ''))) return true;
  return ['annotation', 'annotations', 'citation', 'citations', 'content', 'delta', 'message', 'output', 'response', 'choices']
    .some((key) => containsWebSearchMarker(value[key]));
}

function markdownSources(citations) {
  const entries = [...citations.entries()].slice(0, 10);
  if (!entries.length) return '';
  const lines = entries.map(([url, title]) => {
    const safeTitle = title.replace(/\\/g, '\\\\').replace(/\[/g, '\\[').replace(/\]/g, '\\]');
    const safeUrl = url.replace(/\\/g, '%5C').replace(/\(/g, '%28').replace(/\)/g, '%29');
    return `- [${safeTitle}](${safeUrl})`;
  });
  return `\n\n### Sources\n${lines.join('\n')}`;
}

function finalizeProviderText(request, text, citations, webSearchUsed, onToken, reasoning = '') {
  const sources = request.webSearch ? markdownSources(citations) : '';
  const complete = `${text}${sources}`;
  if (sources) onToken(sources);
  return {
    text: complete,
    reasoning: boundedProviderReasoning(reasoning),
    webSearch: request.webSearch,
    webSearchUsed: Boolean(request.webSearch && (webSearchUsed || citations.size)),
    sourceCount: request.webSearch ? citations.size : 0
  };
}

export function providerActivity(event) {
  if (event?.scholia_activity?.title) return {
    title: String(event.scholia_activity.title).slice(0, 180),
    detail: String(event.scholia_activity.detail || '').slice(0, 2000)
  };
  const type = String(event?.type || '');
  if (/web_search_call\.(in_progress|searching)$/.test(type)) return { title: 'Searching the web' };
  if (/web_search_call\.completed$/.test(type)) return { title: 'Web search complete' };
  const block = event?.content_block;
  if (type === 'content_block_start' && block?.type === 'server_tool_use')
    return { title: 'Provider started a tool', detail: String(block.name || 'Tool').slice(0, 180) };
  if (type === 'content_block_start' && /tool_result$/.test(block?.type || ''))
    return { title: 'Tool result received', detail: String(block.type).replaceAll('_', ' ') };
  return null;
}

async function consumeSse(response, request, onToken, onReasoning, onActivity) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  let complete = '';
  let reasoning = '';
  let webSearchUsed = false;
  const citations = new Map();

  const processBlock = (block) => {
    const dataLines = block.split(/\r?\n/).filter((line) => line.startsWith('data:')).map((line) => line.slice(5).trim());
    if (!dataLines.length) return;
    const raw = dataLines.join('\n');
    if (raw === '[DONE]') return;
    let data;
    try { data = JSON.parse(raw); } catch { return; }
    const streamError = data?.type === 'response.failed' ? data?.response?.error : data?.error;
    if (data?.type === 'error' || streamError) {
      throw new Error(streamError?.message || data?.message || 'The provider stream reported an error.');
    }
    collectWebCitations(data, citations);
    const activity = providerActivity(data);
    if (activity) onActivity(activity);
    webSearchUsed ||= containsWebSearchMarker(data);
    const reasoningDelta = reasoningDeltaFromProviderEvent(data, {
      protocol: request.provider.protocol,
      responseProtocol: request.responseProtocol
    });
    reasoning += reasoningDelta;
    if (reasoningDelta) onReasoning(reasoningDelta);
    const token = request.responseProtocol === 'openai-responses'
      ? textFromOpenAiResponsesEvent(data)
      : request.provider.protocol === 'anthropic'
      ? textFromAnthropicEvent(data)
      : request.provider.protocol === 'cohere'
        ? textFromCohereEvent(data)
        : textFromOpenAiEvent(data);
    if (token) {
      complete += token;
      onToken(token);
    }
  };

  while (true) {
    const { value, done } = await reader.read();
    buffer += decoder.decode(value || new Uint8Array(), { stream: !done });
    const blocks = buffer.split(/\r?\n\r?\n/);
    buffer = blocks.pop() || '';

    for (const block of blocks) processBlock(block);

    if (done) {
      if (buffer.trim()) processBlock(buffer);
      break;
    }
  }

  return finalizeProviderText(request, complete, citations, webSearchUsed, onToken, reasoning);
}

async function consumeNdjson(response, onToken, onReasoning) {
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = '';
  let complete = '';
  let reasoning = '';

  while (true) {
    const { value, done } = await reader.read();
    buffer += decoder.decode(value || new Uint8Array(), { stream: !done });
    const lines = buffer.split(/\r?\n/);
    buffer = lines.pop() || '';
    for (const line of lines) {
      if (!line.trim()) continue;
      let data;
      try { data = JSON.parse(line); } catch { continue; }
      const token = data?.message?.content || data?.response || '';
      const reasoningDelta = reasoningDeltaFromProviderEvent(data, { protocol: 'ollama' });
      reasoning += reasoningDelta;
      if (reasoningDelta) onReasoning(reasoningDelta);
      if (token) {
        complete += token;
        onToken(token);
      }
    }
    if (done) break;
  }

  if (buffer.trim()) {
    try {
      const data = JSON.parse(buffer);
      const token = data?.message?.content || data?.response || '';
      const reasoningDelta = reasoningDeltaFromProviderEvent(data, { protocol: 'ollama' });
      reasoning += reasoningDelta;
      if (reasoningDelta) onReasoning(reasoningDelta);
      if (token) { complete += token; onToken(token); }
    } catch {}
  }
  return { text: complete, reasoning: boundedProviderReasoning(reasoning) };
}

function opencodeModel(model) {
  const separator = model.indexOf('/');
  if (separator < 0) return { providerID: '', modelID: model };
  return { providerID: model.slice(0, separator), modelID: model.slice(separator + 1) };
}

function preparedImageFilename(message, index) {
  if (!message?.image) return '';
  const extension = message.image.mediaType.split('/')[1]?.replace('jpeg', 'jpg') || 'png';
  return `scholia-turn-${index + 1}.${extension}`;
}

function opencodeTranscript(prepared) {
  return [
    { role: 'system', content: systemPrompt(prepared.language, prepared) },
    ...prepared.conversation
  ].map((message, index) => {
    const role = message.role === 'assistant' ? 'Assistant' : message.role === 'system' ? 'System' : 'User';
    const content = typeof message.content === 'string'
      ? message.content
      : (message.content || []).map((part) => part?.type === 'text' ? part.text : '').filter(Boolean).join(' ');
    const image = preparedImageFilename(message, index - 1);
    return `${role}:\n${content}${image ? `\n[Attached image: ${image}]` : ''}`;
  }).join('\n\n');
}

function opencodeText(data) {
  const parts = Array.isArray(data?.parts) ? data.parts : [];
  const typed = parts.filter((part) => part?.type === 'text' && typeof part.text === 'string').map((part) => part.text).join('');
  if (typed) return typed;
  return parts.filter((part) => part?.type !== 'reasoning' && typeof part?.text === 'string').map((part) => part.text).join('');
}

function opencodeError(data) {
  const error = data?.info?.error;
  if (!error) return null;
  return new Error(`opencode: ${error?.data?.message || error?.message || error?.name || 'the model returned an error'}`);
}

function opencodeRelayFallback(model) {
  const separator = model.indexOf('/');
  if (separator < 0) return `opencode-go/${model}`;
  const prefix = model.slice(0, separator);
  if (prefix === 'opencode-go' || prefix === 'openrouter') return null;
  return `opencode-go/${model.slice(separator + 1)}`;
}

async function runOpencode(request, onToken, signal, onReasoning) {
  const { provider, prepared, model, variant, url: base, key } = request;
  const headers = key ? { authorization: basicAuthorization('opencode', key) } : {};

  async function requestJson(path, init = {}) {
    let response;
    try {
      response = await fetch(`${base}${path}`, {
        ...init,
        headers: { ...(init.headers || {}), ...headers },
        signal
      });
    } catch (error) {
      if (error?.name === 'AbortError') throw error;
      throw new Error(`${provider.localBridge.label} is not reachable at ${base}. Start it and try again.`);
    }
    if (!response.ok) throw responseError(response, await response.text());
    return response.json();
  }

  async function createSession() {
    const data = await requestJson('/session', {
      method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}'
    });
    const id = String(data?.id || '');
    if (!id) throw new Error('opencode did not return a session id.');
    return id;
  }

  const parts = [{ type: 'text', text: opencodeTranscript(prepared) }];
  for (const [index, message] of prepared.conversation.entries()) {
    if (!message.image) continue;
    parts.push({
      type: 'file',
      mime: message.image.mediaType,
      url: `data:${message.image.mediaType};base64,${message.image.base64}`,
      filename: preparedImageFilename(message, index)
    });
  }

  async function send(id, chosenModel) {
    return requestJson(`/session/${encodeURIComponent(id)}/message`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ model: opencodeModel(chosenModel), system: systemPrompt(prepared.language, prepared), ...(variant ? { variant } : {}), parts })
    });
  }

  const rewritten = opencodeRelayFallback(model);
  const primary = rewritten || model;
  const fallback = rewritten ? model : '';
  async function attempt(id) {
    try {
      const data = await send(id, primary);
      if (opencodeError(data) && fallback) return send(id, fallback);
      return data;
    } catch (error) {
      if (!fallback) throw error;
      return send(id, fallback);
    }
  }

  // Every request already contains Scholia's complete bounded transcript.
  // Reusing one opencode session across unrelated chats duplicated that
  // transcript and allowed one bad attachment to poison all future requests.
  // A request-scoped session keeps the browser and native clients consistent.
  let sessionId = await createSession();
  let data;
  try {
    data = await attempt(sessionId);
  } catch (error) {
    if (/session|404/i.test(error?.message || '')) {
      sessionId = await createSession();
      data = await attempt(sessionId);
    } else {
      throw error;
    }
  }
  const providerError = opencodeError(data);
  if (providerError) throw providerError;
  const text = opencodeText(data);
  const reasoning = reasoningFromOpencodeResponse(data);
  if (!text.trim()) throw new Error('opencode returned an empty response. Try a different model.');
  if (reasoning) onReasoning(reasoning);
  onToken(text);
  return { text, reasoning, provider: provider.id, model };
}

export async function runCompletion(payload, settings, onToken = () => {}, signal, onReasoning = () => {}, onActivity = () => {}, options = {}) {
  const merged = mergeSettings(settings);
  const provider = providerById(payload.provider || merged.provider);
  let effectivePayload = payload;
  const hasImage = Boolean(payload.imageDataUrl)
    || (Array.isArray(payload.messages) && payload.messages.some((message) => Boolean(message?.imageDataUrl)));
  if (hasImage && provider.imageCapability === 'bridge-health') {
    const status = await checkBridgeStatus(provider.id, merged, { signal });
    if (!status.up) throw new Error(`${provider.localBridge.label} is offline. Start it before sending this image.`);
    if (!status.supportsImages) {
      throw new Error(provider.imageUnavailableMessage || `Restart ${provider.localBridge.label} to send image attachments.`);
    }
    effectivePayload = { ...payload, bridgeSupportsImages: true };
  }
  const request = buildProviderRequest(effectivePayload, merged, options);
  onActivity({ title: `Connecting to ${request.provider.name}`, timestamp: Date.now() });
  if (request.provider.protocol === 'opencode') return runOpencode(request, onToken, signal, onReasoning);

  let response;
  try {
    response = await fetch(request.url, { ...request.fetchOptions, signal });
  } catch (error) {
    if (error?.name === 'AbortError') throw error;
    if (request.provider.localBridge) {
      throw new Error(`${request.provider.localBridge.label} is not reachable. Start it and try again.`);
    }
    throw error;
  }
  if (!response.ok) throw responseError(response, await response.text());

  const contentType = response.headers.get('content-type') || '';
  if (contentType.includes('application/json')) {
    const data = await response.json();
    const text = textFromJsonResponse(request, data);
    const reasoning = reasoningFromProviderResponse(data, {
      protocol: request.provider.protocol,
      responseProtocol: request.responseProtocol
    });
    if (!text.trim()) throw new Error(`${request.provider.name} returned an empty response.`);
    if (reasoning) onReasoning(reasoning);
    if (text) onToken(text);
    const citations = new Map();
    collectWebCitations(data, citations);
    return {
      ...finalizeProviderText(
        request,
        text,
        citations,
        containsWebSearchMarker(data),
        onToken,
        reasoning
      ),
      provider: request.provider.id,
      model: request.model
    };
  }

  const completion = request.provider.protocol === 'ollama'
    ? { ...await consumeNdjson(response, onToken, onReasoning), webSearch: false, webSearchUsed: false, sourceCount: 0 }
    : await consumeSse(response, request, onToken, onReasoning, onActivity);

  if (!completion.text.trim()) throw new Error(`${request.provider.name} returned an empty response.`);
  return { ...completion, provider: request.provider.id, model: request.model };
}
