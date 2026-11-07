import test from 'node:test';
import assert from 'node:assert/strict';
import {
  mergeSettings,
  modelId,
  modelLabel,
  modelReasoning,
  normalizeSiteKey,
  providerById,
  providerModelChoices,
  providerSupportsFastMode,
  providerSupportsWebSearch,
  publicSettings,
  resolveModelId,
  siteIsEnabled,
  sortModelChoices
} from '../../packages/core/src/providers.js';

test('model picker puts verified models first, then capacity and numeric newest versions', () => {
  assert.deepEqual(sortModelChoices(['gpt-6-luna', 'gpt-5-mini', 'gpt-6-astra', 'gpt-6-sol', 'gpt-5.6'], new Set(['gpt-5-mini', 'gpt-6-sol'])),
    ['gpt-6-sol', 'gpt-5-mini', 'gpt-6-astra', 'gpt-5.6', 'gpt-6-luna']);
  assert.deepEqual(sortModelChoices(['claude-opus-4-8', 'claude-opus-4-10', 'claude-opus-4-7']),
    ['claude-opus-4-10', 'claude-opus-4-8', 'claude-opus-4-7']);
});

test('website access policies are normalized and exposed without secrets', () => {
  const settings = mergeSettings({
    disabledSites: ['Example.ORG', 'example.org', ' docs.example.org '],
    allowedSites: ['https://Learn.Example.org/path', 'learn.example.org'],
    siteAccessMode: 'allowlist',
    apiKeys: { openai: 'secret' }
  });
  assert.deepEqual(settings.disabledSites, ['docs.example.org', 'example.org']);
  assert.deepEqual(settings.allowedSites, ['learn.example.org']);
  assert.equal(siteIsEnabled(settings, 'https://learn.example.org/topic'), true);
  assert.equal(siteIsEnabled(settings, 'example.org'), false);
  const visible = publicSettings(settings);
  assert.deepEqual(visible.disabledSites, settings.disabledSites);
  assert.deepEqual(visible.allowedSites, settings.allowedSites);
  assert.equal(visible.siteAccessMode, 'allowlist');
  assert.equal('apiKeys' in visible, false);
  assert.equal(normalizeSiteKey('localhost:4173'), 'localhost');

  const recovered = mergeSettings({ provider: 'unknown', disabledSites: 'example.org' });
  assert.equal(recovered.provider, 'openai');
  assert.equal(recovered.siteAccessMode, 'blocklist');
  assert.deepEqual(recovered.disabledSites, []);
});

test('structured local model entries retain ids and friendly labels', () => {
  const model = providerById('codex').models.find((entry) => modelId(entry) === 'gpt-5.6-sol');
  assert.equal(modelId(model), 'gpt-5.6-sol');
  assert.equal(modelLabel(model), 'GPT-5.6 Sol');
});

test('GPT NTNU exposes the IDUN chat endpoint and documented model capabilities', () => {
  const provider = providerById('ntnu');
  assert.equal(provider.name, 'GPT NTNU');
  assert.equal(provider.protocol, 'openai');
  assert.equal(provider.endpoint, 'https://llm.hpc.ntnu.no/v1/chat/completions');
  assert.equal(provider.defaultModel, 'openai/gpt-oss-120b');
  assert.equal(provider.models.some((model) => modelId(model) === 'Qwen/Qwen3-Embedding-8B'), false);

  const settings = mergeSettings({ provider: 'ntnu' });
  assert.equal(settings.models.ntnu, 'openai/gpt-oss-120b');
  assert.equal(
    providerModelChoices(provider, settings).find((model) => modelId(model) === 'openai/gpt-oss-120b')?.supportsImages,
    false
  );
  assert.equal(
    providerModelChoices(provider, settings).find((model) => modelId(model) === 'moonshotai/Kimi-K2.6')?.supportsImages,
    true
  );
  assert.equal(publicSettings(settings).configuredProviders.includes('ntnu'), false);
  assert.equal(
    publicSettings(mergeSettings({ apiKeys: { ntnu: 'secret' } })).configuredProviders.includes('ntnu'),
    true
  );
});

test('discovered models are normalized, public, and merged with arbitrary model ids', () => {
  const settings = mergeSettings({
    provider: 'opencode',
    models: { opencode: 'future-provider/brand-new-model' },
    customModels: { opencode: ['manual/anything'] },
    discoveredModels: {
      opencode: [
        { id: 'vendor/zulu-model', label: 'Zulu Model' },
        { id: 'vendor/alpha-model', label: 'Alpha Model' },
        { id: '', label: 'invalid' }
      ]
    },
    modelCatalogCheckedAt: { opencode: 1234 }
  });
  const choices = providerModelChoices('opencode', settings);
  const ids = choices.map(modelId);
  assert.ok(ids.includes('opencode-go/glm-5.3-flash'));
  assert.ok(ids.includes('opencode-go/glm-5.3'));
  assert.ok(ids.includes('manual/anything'));
  assert.ok(ids.includes('future-provider/brand-new-model'));
  assert.ok(ids.indexOf('opencode-go/glm-5.3') < ids.indexOf('opencode-go/glm-5.3-flash'));
  assert.equal(
    providerModelChoices('opencode', settings, { includeSelected: false })
      .some((model) => modelId(model) === 'future-provider/brand-new-model'),
    false
  );
  assert.equal(settings.discoveredModels.opencode.length, 2);
  assert.equal(publicSettings(settings).modelCatalogCheckedAt.opencode, 1234);
});

test('discovered model image capabilities survive settings normalization and static merging', () => {
  const settings = mergeSettings({
    discoveredModels: {
      opencode: [
        { id: 'future/vision', label: 'Future Vision', supportsImages: true },
        { id: 'opencode-go/glm-5.3', label: 'Catalog GLM', supportsImages: false }
      ]
    }
  });
  const choices = providerModelChoices('opencode', settings);
  assert.equal(choices.find((entry) => modelId(entry) === 'future/vision')?.supportsImages, true);
  assert.equal(choices.find((entry) => modelId(entry) === 'opencode-go/glm-5.3')?.supportsImages, false);
});

test('retired Ox Alpha selections migrate to GLM 5.3 Flash', () => {
  const settings = mergeSettings({
    provider: 'opencode',
    models: { opencode: 'opencode/x-preview-f-free' },
    customModels: { opencode: ['opencode-go/ox-alpha-free'] },
    discoveredModels: {
      opencode: [
        { id: 'opencode/x-preview-f-free', label: 'Ox Alpha Free' },
        { id: 'opencode-go/ox-alpha-free', label: 'Ox Alpha Free' }
      ]
    }
  });

  assert.equal(settings.models.opencode, 'opencode-go/glm-5.3-flash');
  assert.deepEqual(settings.customModels.opencode, ['opencode-go/glm-5.3-flash']);
  assert.equal(settings.discoveredModels.opencode, undefined);
  const ids = providerModelChoices('opencode', settings).map(modelId);
  assert.equal(ids.filter((id) => id === 'opencode-go/glm-5.3-flash').length, 1);
  assert.equal(ids.some((id) => id.includes('ox-alpha') || id.includes('x-preview-f')), false);
});

test('typed OpenCode model ids resolve to the catalog\'s exact casing', () => {
  const settings = mergeSettings({
    provider: 'opencode',
    models: { opencode: 'opencode-go/GLM-5.3-flash' },
    discoveredModels: {
      opencode: [{ id: 'future/Mixed-Case', label: 'Mixed Case' }]
    }
  });

  assert.equal(settings.models.opencode, 'opencode-go/glm-5.3-flash');
  assert.equal(resolveModelId('opencode', 'FUTURE/mixed-case', settings), 'future/Mixed-Case');
});

test('legacy truncated OpenCode registries are removed before rendering', () => {
  const discovered = Array.from({ length: 2_000 }, (_, index) => ({
    id: `registry/provider-${index}`,
    label: `Registry provider ${index}`
  }));
  const settings = mergeSettings({
    discoveredModels: { opencode: discovered },
    modelCatalogCheckedAt: { opencode: Date.now() }
  });

  assert.equal(settings.discoveredModels.opencode, undefined);
  assert.equal(settings.modelCatalogCheckedAt.opencode, undefined);
});

test('Codex local models expose and retain max reasoning effort', () => {
  assert.equal(modelReasoning('codex', 'gpt-5.5').efforts.includes('max'), true);
  assert.equal(modelReasoning('codex', 'gpt-5.6-terra').efforts.includes('max'), true);
  assert.equal(modelReasoning('codex', 'gpt-5.6-luna').efforts.includes('max'), true);

  const settings = mergeSettings({
    provider: 'codex',
    models: { codex: 'gpt-5.6-luna' },
    reasoningEfforts: { codex: 'max' }
  });
  assert.equal(settings.reasoningEfforts.codex, 'max');
});

test('Fast mode is available only for the local Codex and Claude Code providers', () => {
  assert.equal(providerSupportsFastMode('codex'), true);
  assert.equal(providerSupportsFastMode('claudecode'), true);
  assert.equal(providerSupportsFastMode('openai'), false);
});

test('native web search is exposed only by providers with a supported tool contract', () => {
  assert.equal(providerSupportsWebSearch('openai'), true);
  assert.equal(providerSupportsWebSearch('anthropic'), true);
  assert.equal(providerSupportsWebSearch('openrouter'), true);
  assert.equal(providerSupportsWebSearch('codex'), true);
  assert.equal(providerSupportsWebSearch('claudecode'), false);
  assert.equal(providerSupportsWebSearch('custom'), false);
});
