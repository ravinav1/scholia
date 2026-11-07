import {
  normalizeChatGptWebContext,
  publicChatGptWebContext
} from './chatgpt-context.js';
import { normalizeRecentModels } from './recent-models.js';

export const SETTINGS_KEY = 'scholia.settings.v1';
const DEFAULT_PROVIDER_ID = 'openai';
const SITE_ACCESS_MODES = new Set(['blocklist', 'allowlist']);
const FAST_MODE_PROVIDER_IDS = new Set(['claudecode', 'codex']);
const OPENCODE_MODEL_REPLACEMENTS = new Map([
  ['opencode-go/ox-alpha-free', 'opencode-go/glm-5.3-flash'],
  ['opencode/x-preview-f-free', 'opencode-go/glm-5.3-flash']
]);
const MODEL_NAME_COLLATOR = new Intl.Collator('en', { numeric: true, sensitivity: 'base' });

const CLAUDE_REASONING_EFFORTS = Object.freeze(['low', 'medium', 'high', 'xhigh', 'max']);
const CODEX_REASONING_EFFORTS = Object.freeze(['minimal', 'low', 'medium', 'high', 'xhigh', 'max']);

function reasoningModel(id, label, efforts, defaultEffort) {
  return { id, label, reasoning: { efforts, default: defaultEffort } };
}

export const PROVIDERS = Object.freeze([
  {
    id: 'anthropic',
    name: 'Anthropic',
    protocol: 'anthropic',
    endpoint: 'https://api.anthropic.com/v1/messages',
    keyRequired: true,
    keyHint: 'sk-ant-…',
    supportsImages: true,
    supportsWebSearch: true,
    defaultModel: 'claude-sonnet-4-6',
    models: [
      'claude-opus-4-8',
      'claude-opus-4-7',
      'claude-sonnet-4-6',
      'claude-haiku-4-5-20251001'
    ]
  },
  {
    id: 'openai',
    name: 'OpenAI',
    protocol: 'openai',
    endpoint: 'https://api.openai.com/v1/chat/completions',
    keyRequired: true,
    keyHint: 'sk-…',
    supportsImages: true,
    supportsWebSearch: true,
    defaultModel: 'gpt-5-mini',
    models: [reasoningModel('gpt-6-astra', 'GPT-6 Astra', ['low', 'medium', 'high', 'xhigh', 'max'], 'medium'),
      reasoningModel('gpt-6.1-sol', 'GPT-6.1 Sol', ['low', 'medium', 'high', 'xhigh', 'max'], 'medium'),
      reasoningModel('gpt-6-sol', 'GPT-6 Sol', ['none', 'low', 'medium', 'high', 'xhigh', 'max'], 'medium'),
      reasoningModel('gpt-6-luna', 'GPT-6 Luna', ['none', 'low', 'medium', 'high', 'xhigh', 'max'], 'medium'),
      'gpt-5.5', 'gpt-5', 'gpt-5-mini', 'gpt-5-nano', 'gpt-4.1', 'gpt-4.1-mini', 'o3', 'o4-mini']
  },
  {
    id: 'ntnu',
    name: 'GPT NTNU',
    protocol: 'openai',
    endpoint: 'https://llm.hpc.ntnu.no/v1/chat/completions',
    keyRequired: true,
    keyHint: 'Personal NTNU LLM API key',
    supportsImages: true,
    defaultModel: 'openai/gpt-oss-120b',
    models: [
      { id: 'openai/gpt-oss-120b', label: 'GPT OSS 120B', supportsImages: false },
      { id: 'moonshotai/Kimi-K2.6', label: 'Kimi K2.6', supportsImages: true },
      {
        id: 'NorwAI/NorwAI-Magistral-24B-reasoning',
        label: 'NorwAI Magistral 24B Reasoning',
        supportsImages: false
      },
      {
        id: 'norallm/normistral-11b-thinking',
        label: 'NorMistral 11B Thinking',
        supportsImages: false
      },
      { id: 'NbAiLab/borealis-27b', label: 'Borealis 27B', supportsImages: false },
      { id: 'Qwen/Qwen3.8-27B-FP8', label: 'Qwen 3.8 27B FP8', supportsImages: true },
      { id: 'Inferact/GLM-5.3-NVFP4', label: 'GLM 5.3 NVFP4', supportsImages: false },
      {
        id: 'mistralai/Mistral-Medium-3.5-128B',
        label: 'Mistral Medium 3.5 128B',
        supportsImages: true
      },
      {
        id: 'deepseek-ai/DeepSeek-V4-Flash-Vision-Exp',
        label: 'DeepSeek V4 Flash Vision (demo)',
        supportsImages: true
      },
      { id: 'zai-org/GLM-5.3-Flash', label: 'GLM 5.3 Flash (demo)', supportsImages: true }
    ]
  },
  {
    id: 'openrouter',
    name: 'OpenRouter',
    protocol: 'openai',
    endpoint: 'https://openrouter.ai/api/v1/chat/completions',
    keyRequired: true,
    keyHint: 'sk-or-…',
    supportsImages: true,
    supportsWebSearch: true,
    defaultModel: 'anthropic/claude-sonnet-4.6',
    models: [
      'anthropic/claude-opus-4.8',
      'anthropic/claude-sonnet-4.6',
      'openai/gpt-5.5',
      'openai/gpt-5-mini',
      'openai/gpt-oss-20b:free',
      'google/gemini-3.5-flash',
      'google/gemini-2.5-pro',
      'deepseek/deepseek-v4-pro'
    ]
  },
  {
    id: 'groq',
    name: 'Groq',
    protocol: 'openai',
    endpoint: 'https://api.groq.com/openai/v1/chat/completions',
    keyRequired: true,
    keyHint: 'gsk_…',
    supportsImages: true,
    defaultModel: 'meta-llama/llama-4-maverick-17b-128e-instruct',
    models: [
      'meta-llama/llama-4-maverick-17b-128e-instruct',
      'meta-llama/llama-4-scout-17b-16e-instruct',
      'llama-3.3-70b-versatile',
      'openai/gpt-oss-120b'
    ]
  },
  {
    id: 'together',
    name: 'Together AI',
    protocol: 'openai',
    endpoint: 'https://api.together.xyz/v1/chat/completions',
    keyRequired: true,
    keyHint: 'Together API key',
    supportsImages: true,
    defaultModel: 'deepseek-ai/DeepSeek-V3.1',
    models: [
      'deepseek-ai/DeepSeek-V3.1',
      'meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8',
      'Qwen/Qwen3-235B-A22B-Instruct-2507-tput'
    ]
  },
  {
    id: 'mistral',
    name: 'Mistral AI',
    protocol: 'openai',
    endpoint: 'https://api.mistral.ai/v1/chat/completions',
    keyRequired: true,
    keyHint: 'Mistral API key',
    supportsImages: true,
    defaultModel: 'mistral-large-latest',
    models: ['magistral-medium-latest', 'mistral-large-latest', 'mistral-small-latest', 'codestral-latest']
  },
  {
    id: 'cohere',
    name: 'Cohere',
    protocol: 'cohere',
    endpoint: 'https://api.cohere.com/v2/chat',
    keyRequired: true,
    keyHint: 'Cohere API key',
    supportsImages: false,
    defaultModel: 'command-a-03-2025',
    models: ['command-a-03-2025', 'command-r-plus-08-2024', 'command-r-08-2024']
  },
  {
    id: 'claudecode',
    name: 'Claude Code (local)',
    protocol: 'openai',
    endpoint: 'http://127.0.0.1:8787/v1/chat/completions',
    keyRequired: false,
    keyHint: 'Optional bridge bearer token',
    supportsImages: false,
    imageCapability: 'bridge-health',
    imageUnavailableMessage: 'Restart the Claude Code bridge with --allow-images to send image attachments.',
    defaultModel: 'sonnet',
    models: [
      reasoningModel('fable', 'Fable 5 (Claude Code)', CLAUDE_REASONING_EFFORTS, 'high'),
      reasoningModel('opus', 'Opus 4.8 (Claude Code)', CLAUDE_REASONING_EFFORTS, 'high'),
      reasoningModel('sonnet', 'Sonnet 4.6 (Claude Code)', CLAUDE_REASONING_EFFORTS, 'high'),
      reasoningModel('haiku', 'Haiku 4.5 (Claude Code)', CLAUDE_REASONING_EFFORTS, 'medium')
    ],
    localBridge: {
      label: 'Claude Code bridge',
      port: 8787,
      healthPath: '/health',
      usagePath: '/v1/usage',
      healthField: 'ok',
      startScheme: 'claudecode',
      startPortParameter: 'port',
      command: 'node scripts/bridges/claude-code-bridge.mjs',
      installCommand: 'npm run bridge:install:claude'
    }
  },
  {
    id: 'codex',
    name: 'Codex CLI (local)',
    protocol: 'openai',
    endpoint: 'http://127.0.0.1:8789/v1/chat/completions',
    keyRequired: false,
    keyHint: 'Optional bridge bearer token',
    supportsImages: false,
    supportsWebSearch: true,
    imageCapability: 'bridge-health',
    imageUnavailableMessage: 'Restart the Codex bridge to enable image attachments.',
    defaultModel: 'gpt-5.5',
    models: [
      reasoningModel('gpt-6-astra', 'GPT-6 Astra', ['low', 'medium', 'high', 'xhigh', 'max'], 'medium'),
      reasoningModel('gpt-6.1-sol', 'GPT-6.1 Sol', ['low', 'medium', 'high', 'xhigh', 'max'], 'medium'),
      reasoningModel('gpt-6-sol', 'GPT-6 Sol', ['low', 'medium', 'high', 'xhigh', 'max'], 'medium'),
      reasoningModel('gpt-6-luna', 'GPT-6 Luna', ['low', 'medium', 'high', 'xhigh', 'max'], 'medium'),
      reasoningModel('gpt-5.5', 'GPT-5.5', CODEX_REASONING_EFFORTS, 'high'),
      reasoningModel('gpt-5.6-sol', 'GPT-5.6 Sol', ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'], 'medium'),
      reasoningModel('gpt-5.6-terra', 'GPT-5.6 Terra', CODEX_REASONING_EFFORTS, 'high'),
      reasoningModel('gpt-5.6-luna', 'GPT-5.6 Luna', ['minimal', 'low', 'medium', 'high', 'max'], 'medium'),
      reasoningModel('gpt-5.4', 'GPT-5.4', CODEX_REASONING_EFFORTS, 'high'),
      reasoningModel('gpt-5.4-mini', 'GPT-5.4 Mini', ['minimal', 'low', 'medium', 'high'], 'medium')
    ],
    localBridge: {
      label: 'Codex bridge',
      port: 8789,
      healthPath: '/health',
      usagePath: '/v1/usage',
      healthField: 'ok',
      startScheme: 'scholia-codex',
      command: 'node scripts/bridges/codex-bridge.mjs',
      installCommand: 'npm run bridge:install:codex'
    }
  },
  {
    id: 'opencode',
    name: 'opencode (local server)',
    protocol: 'opencode',
    endpoint: 'http://127.0.0.1:4096',
    keyRequired: false,
    keyHint: 'Optional opencode server password',
    supportsImages: true,
    defaultModel: 'opencode-go/deepseek-v4-pro',
    models: [
      { id: 'opencode-go/deepseek-v4-pro', label: 'DeepSeek V4 Pro' },
      { id: 'opencode-go/glm-5.3', label: 'GLM 5.3', supportsImages: false },
      { id: 'opencode-go/glm-5.3-flash', label: 'GLM 5.3 Flash', supportsImages: false },
      { id: 'opencode-go/qwen3.7-max', label: 'Qwen3.7 Max' },
      { id: 'opencode-go/minimax-m3', label: 'MiniMax M3' },
      { id: 'opencode-go/glm-5.2', label: 'GLM 5.2', supportsImages: false },
      { id: 'opencode-go/kimi-k2.7-code', label: 'Kimi K2.7 Code' },
      { id: 'opencode-go/kimi-k2.6', label: 'Kimi K2.6' },
      { id: 'opencode-go/minimax-m2.7', label: 'MiniMax M2.7' },
      { id: 'opencode-go/glm-5.1', label: 'GLM 5.1', supportsImages: false },
      { id: 'opencode-go/deepseek-v4-flash', label: 'DeepSeek V4 Flash' }
    ],
    localBridge: {
      label: 'opencode server',
      port: 4096,
      healthPath: '/global/health',
      healthField: 'healthy',
      startScheme: 'opencode',
      command: 'opencode serve',
      installCommand: 'npm run bridge:install:opencode'
    }
  },
  {
    id: 'ollama',
    name: 'Ollama (local)',
    protocol: 'ollama',
    endpoint: 'http://127.0.0.1:11434/api/chat',
    keyRequired: false,
    keyHint: '',
    supportsImages: true,
    defaultModel: 'qwen3:8b',
    models: ['qwen3:8b', 'gemma3:12b', 'llama3.2-vision:11b', 'llama3.2:3b']
  },
  {
    id: 'custom',
    name: 'Custom compatible endpoint',
    protocol: 'openai',
    endpoint: 'http://127.0.0.1:8080/v1/chat/completions',
    keyRequired: false,
    keyHint: 'Optional bearer token',
    supportsImages: true,
    defaultModel: 'default',
    models: ['default']
  }
]);

export const DEFAULT_SETTINGS = Object.freeze({
  provider: DEFAULT_PROVIDER_ID,
  language: 'auto',
  models: Object.fromEntries(PROVIDERS.map((provider) => [provider.id, provider.defaultModel])),
  endpoints: Object.fromEntries(PROVIDERS.map((provider) => [provider.id, provider.endpoint])),
  apiKeys: {},
  customModels: {},
  discoveredModels: {},
  modelCatalogCheckedAt: {},
  reasoningEfforts: {
    claudecode: 'high',
    codex: 'high'
  },
  fastMode: false,
  includePageContext: true,
  explainOnSelection: true,
  chatgptWebContext: normalizeChatGptWebContext(),
  siteAccessMode: 'blocklist',
  allowedSites: [],
  disabledSites: []
});

const PROVIDERS_BY_ID = new Map(PROVIDERS.map((provider) => [provider.id, provider]));

export function providerById(id) {
  return PROVIDERS_BY_ID.get(id) || PROVIDERS_BY_ID.get(DEFAULT_PROVIDER_ID);
}

export function providerSupportsFastMode(providerOrId) {
  const provider = typeof providerOrId === 'string' ? providerById(providerOrId) : providerOrId;
  return FAST_MODE_PROVIDER_IDS.has(provider?.id);
}

export function providerSupportsWebSearch(providerOrId) {
  const provider = typeof providerOrId === 'string' ? providerById(providerOrId) : providerOrId;
  return provider?.supportsWebSearch === true;
}

export function modelId(model) {
  return typeof model === 'string' ? model : String(model?.id || '');
}

export function modelLabel(model) {
  return typeof model === 'string' ? model : String(model?.label || model?.id || '');
}

export function canonicalModelId(providerOrId, id) {
  const provider = typeof providerOrId === 'string' ? providerById(providerOrId) : providerOrId;
  const value = String(id || '').trim();
  return provider?.id === 'opencode'
    ? OPENCODE_MODEL_REPLACEMENTS.get(value) || value
    : value;
}

// OpenCode model IDs are case-sensitive on the wire, while its settings field
// permits typing. Resolve a case-insensitive typed value to the exact spelling
// advertised by the static or live catalog before saving or testing it.
export function resolveModelId(providerOrId, id, settings = {}) {
  const provider = typeof providerOrId === 'string' ? providerById(providerOrId) : providerOrId;
  const canonical = canonicalModelId(provider, id);
  if (provider?.id !== 'opencode' || !canonical) return canonical;
  const candidates = [
    ...(provider.models || []),
    ...(settings?.discoveredModels?.[provider.id] || []),
    ...(settings?.customModels?.[provider.id] || [])
  ];
  const folded = canonical.toLocaleLowerCase('en-US');
  for (const entry of candidates) {
    const candidate = canonicalModelId(provider, modelId(entry));
    if (candidate.toLocaleLowerCase('en-US') === folded) return candidate;
  }
  return canonical;
}

export function isRetiredModelId(providerOrId, id) {
  const provider = typeof providerOrId === 'string' ? providerById(providerOrId) : providerOrId;
  return provider?.id === 'opencode' && OPENCODE_MODEL_REPLACEMENTS.has(String(id || '').trim());
}

export function compareModelNames(left, right) {
  const byLabel = MODEL_NAME_COLLATOR.compare(modelLabel(left), modelLabel(right));
  return byLabel || MODEL_NAME_COLLATOR.compare(modelId(left), modelId(right));
}

export function sortModelChoices(models, verified = new Set()) {
  const capacity = (id) => {
    const words = new Set(String(id).toLowerCase().split(/[^a-z]+/));
    for (const [score, names] of [[0, ['nano', 'tiny']], [1, ['mini', 'lite', 'small']], [2, ['flash', 'haiku', 'luna']], [3, ['medium', 'terra']], [5, ['opus', 'astra', 'pro', 'ultra', 'max', 'large']]]) {
      if (names.some((name) => words.has(name))) return score;
    }
    return 4;
  };
  const family = (id) => String(id).toLowerCase().split('/').at(-1).split(/\d/, 1)[0].replace(/[-_.]+$/, '');
  return [...models].sort((left, right) => {
    const a = modelId(left), b = modelId(right);
    if (verified.has(a) !== verified.has(b)) return verified.has(a) ? -1 : 1;
    const tier = capacity(b) - capacity(a);
    if (tier) return tier;
    if (family(a) === family(b)) {
      const version = MODEL_NAME_COLLATOR.compare(b, a);
      if (version) return version;
    }
    return compareModelNames(left, right);
  });
}

export function modelDefinition(providerOrId, id, settings = {}) {
  const provider = typeof providerOrId === 'string' ? providerById(providerOrId) : providerOrId;
  return providerModelChoices(provider, settings).find((model) => modelId(model) === id) || null;
}

// Returns the selected model's input capability independently of transport
// capability. Unknown opencode models fail closed until /provider advertises
// image input; hosted and bridge models retain their provider-level behavior.
export function modelSupportsImages(providerOrId, id, settings = {}) {
  const provider = typeof providerOrId === 'string' ? providerById(providerOrId) : providerOrId;
  const definition = modelDefinition(provider, id, settings);
  if (typeof definition?.supportsImages === 'boolean') return definition.supportsImages;
  return provider?.id !== 'opencode';
}

export function providerModelChoices(providerOrId, settings = {}, { includeSelected = true } = {}) {
  const provider = typeof providerOrId === 'string' ? providerById(providerOrId) : providerOrId;
  const models = new Map();
  const candidates = [
    ...(provider?.models || []),
    ...(settings?.discoveredModels?.[provider?.id] || []),
    ...(settings?.customModels?.[provider?.id] || []),
    ...normalizeRecentModels(settings?.recentModels).filter((item) => item.providerID === provider?.id).map((item) => item.modelID),
    ...(includeSelected ? [settings?.models?.[provider?.id]] : [])
  ].filter(Boolean);
  for (const entry of candidates) {
    const id = canonicalModelId(provider, modelId(entry));
    if (!id) continue;
    const normalized = typeof entry === 'string'
      ? { id, label: id }
      : { ...entry, id };
    const existing = models.get(id);
    if (existing) {
      // A live catalog can enrich a built-in entry without replacing its
      // stable display name. In particular, capability metadata must survive
      // the static/discovered merge for deterministic image gating.
      if (typeof entry !== 'string') {
        models.set(id, {
          ...existing,
          ...(normalized.reasoning ? { reasoning: normalized.reasoning } : {}),
          ...(typeof normalized.supportsImages === 'boolean'
            ? { supportsImages: normalized.supportsImages }
            : {})
        });
      }
      continue;
    }
    models.set(id, normalized);
  }
  return sortModelChoices([...models.values()]);
}

export function modelReasoning(providerOrId, id, settings = {}) {
  return modelDefinition(providerOrId, id, settings)?.reasoning || null;
}

export function normalizeSiteKey(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';
  if (raw.toLowerCase() === 'file://') return 'file://';
  try {
    const hasExplicitScheme = /^[a-z][a-z\d+.-]*:\/\//i.test(raw) || /^file:/i.test(raw);
    const url = new URL(hasExplicitScheme ? raw : `https://${raw}`);
    if (url.protocol === 'http:' || url.protocol === 'https:') {
      return url.hostname.toLowerCase().replace(/\.$/, '');
    }
    return url.protocol === 'file:' ? 'file://' : '';
  } catch {
    return '';
  }
}

function normalizeSites(values) {
  if (!Array.isArray(values)) return [];
  return [...new Set(values.map(normalizeSiteKey).filter(Boolean))].sort();
}

export function siteIsEnabled(settings, site) {
  const key = normalizeSiteKey(site);
  if (!key) return false;
  return settings?.siteAccessMode === 'allowlist'
    ? settings.allowedSites?.includes(key) === true
    : settings?.disabledSites?.includes(key) !== true;
}

export function mergeSettings(raw = {}) {
  const source = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  const provider = providerById(source.provider || DEFAULT_SETTINGS.provider);
  const models = {};
  const endpoints = {};
  const apiKeys = {};
  const customModels = {};
  const discoveredModels = {};
  const modelCatalogCheckedAt = {};
  const reasoningEfforts = {};

  for (const definition of PROVIDERS) {
    const selectedModel = canonicalModelId(
      definition,
      String(source.models?.[definition.id] || definition.defaultModel).trim()
    );
    models[definition.id] = selectedModel && selectedModel.length <= 200
      ? selectedModel
      : definition.defaultModel;
    endpoints[definition.id] = String(source.endpoints?.[definition.id] ?? definition.endpoint)
      .trim()
      .slice(0, 2_048);
    const key = String(source.apiKeys?.[definition.id] || '').trim();
    if (key) apiKeys[definition.id] = key;
    const custom = Array.isArray(source.customModels?.[definition.id])
      ? source.customModels[definition.id]
        .map((model) => canonicalModelId(definition, String(model).trim()))
        .filter((model) => model && model.length <= 200)
      : [];
    if (custom.length) customModels[definition.id] = [...new Set(custom)];
    const rawDiscovered = Array.isArray(source.discoveredModels?.[definition.id])
      ? source.discoveredModels[definition.id]
      : [];
    // Older OpenCode discovery accidentally cached the first 2,000 entries in
    // the global registry. Drop that known-truncated shape before it reaches a
    // picker and force the service worker to replace it from the connected set.
    const discardedLegacyCatalog = definition.id === 'opencode' && rawDiscovered.length >= 2_000;
    const discovered = !discardedLegacyCatalog
      ? rawDiscovered
        .map((model) => {
          const rawId = modelId(model).trim();
          if (isRetiredModelId(definition, rawId)) return null;
          const id = canonicalModelId(definition, rawId);
          if (!id || id.length > 200) return null;
          const label = modelLabel(model).trim().slice(0, 240) || id;
          const efforts = Array.isArray(model?.reasoning?.efforts)
            ? [...new Set(model.reasoning.efforts.map((effort) => String(effort || '').trim()).filter(Boolean))].slice(0, 12)
            : [];
          const normalized = { id, label };
          if (efforts.length) {
            const requestedDefault = String(model?.reasoning?.default || '');
            normalized.reasoning = {
              efforts,
              default: efforts.includes(requestedDefault) ? requestedDefault : efforts[0]
            };
          }
          if (typeof model?.supportsImages === 'boolean') {
            normalized.supportsImages = model.supportsImages;
          }
          return normalized;
        })
        .filter(Boolean)
        .slice(0, 2_000)
      : [];
    if (discovered.length) {
      discoveredModels[definition.id] = [...new Map(discovered.map((model) => [model.id, model])).values()];
    }
    models[definition.id] = resolveModelId(definition, models[definition.id], {
      customModels,
      discoveredModels
    });
    const checkedAt = Number(source.modelCatalogCheckedAt?.[definition.id]);
    if (!discardedLegacyCatalog && Number.isFinite(checkedAt) && checkedAt > 0) {
      modelCatalogCheckedAt[definition.id] = Math.floor(checkedAt);
    }

    const reasoning = modelReasoning(definition, models[definition.id], { discoveredModels });
    if (reasoning) {
      const requested = String(source.reasoningEfforts?.[definition.id] || '');
      reasoningEfforts[definition.id] = reasoning.efforts.includes(requested)
        ? requested
        : reasoning.default;
    }
  }

  const disabledSource = Array.isArray(source.disabledSites)
    ? source.disabledSites
    : Array.isArray(source.disabledHosts) ? source.disabledHosts : [];
  return {
    provider: provider.id,
    language: ['auto', 'en', 'no'].includes(source.language) ? source.language : DEFAULT_SETTINGS.language,
    models,
    endpoints,
    apiKeys,
    customModels,
    discoveredModels,
    modelCatalogCheckedAt,
    recentModels: normalizeRecentModels(source.recentModels).filter((item) => PROVIDERS_BY_ID.has(item.providerID)),
    reasoningEfforts,
    fastMode: source.fastMode === true,
    includePageContext: source.includePageContext !== false,
    explainOnSelection: source.explainOnSelection !== false,
    chatgptWebContext: normalizeChatGptWebContext(source.chatgptWebContext),
    siteAccessMode: SITE_ACCESS_MODES.has(source.siteAccessMode) ? source.siteAccessMode : DEFAULT_SETTINGS.siteAccessMode,
    allowedSites: normalizeSites(source.allowedSites),
    disabledSites: normalizeSites(disabledSource)
  };
}

export function publicSettings(settings) {
  const merged = mergeSettings(settings);
  return {
    provider: merged.provider,
    language: merged.language,
    models: merged.models,
    customModels: merged.customModels,
    discoveredModels: merged.discoveredModels,
    modelCatalogCheckedAt: merged.modelCatalogCheckedAt,
    recentModels: merged.recentModels,
    reasoningEfforts: merged.reasoningEfforts,
    fastMode: merged.fastMode,
    includePageContext: merged.includePageContext,
    explainOnSelection: merged.explainOnSelection,
    chatgptWebContext: publicChatGptWebContext(merged.chatgptWebContext),
    siteAccessMode: merged.siteAccessMode,
    allowedSites: merged.allowedSites,
    disabledSites: merged.disabledSites,
    configuredProviders: PROVIDERS.filter((provider) => !provider.keyRequired || Boolean(merged.apiKeys[provider.id])).map((provider) => provider.id)
  };
}
