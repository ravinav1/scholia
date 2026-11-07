import test from 'node:test';
import assert from 'node:assert/strict';
import { fetchOpencodeModels, modelsFromOpencodeCatalog } from '../../apps/chrome/src/opencode-models.js';

test('OpenCode catalog discovery includes only connected and built-in providers when connection data exists', () => {
  const models = modelsFromOpencodeCatalog({
    connected: ['opencode-go'],
    all: [
      {
        id: 'opencode', name: 'OpenCode Zen', models: {
          'x-preview-f-free': { id: 'x-preview-f-free', name: 'Ox Alpha Free (Unlimited)', variants: { low: {}, medium: {}, high: {} } }
        }
      },
      {
        id: 'opencode-go', name: 'OpenCode Go', models: {
          'ox-alpha-free': { id: 'ox-alpha-free', name: 'Ox Alpha Free' },
          'glm-5.3-flash': { id: 'glm-5.3-flash', name: 'GLM 5.3 Flash', variants: { low: {}, medium: {}, high: {} } }
        }
      },
      {
        id: 'my-local', name: 'My local models', source: 'custom', models: {
          'new/model': { name: 'A newly configured model' }
        }
      },
      {
        id: 'unused', name: 'Unused', models: { hidden: { id: 'hidden', name: 'Hidden' } }
      }
    ]
  });

  assert.deepEqual(models.map((model) => model.id), [
    'opencode-go/glm-5.3-flash'
  ]);
  assert.equal(models[0].label, 'GLM 5.3 Flash · OpenCode Go');
  assert.deepEqual(models[0].reasoning, { efforts: ['low', 'medium', 'high'], default: 'medium' });
});

test('unconnected registry providers cannot exhaust the catalog before a connected provider', () => {
  const registry = Array.from({ length: 2_010 }, (_, index) => ({
    id: `registry-${String(index).padStart(4, '0')}`,
    source: 'custom',
    models: { default: { id: 'default' } }
  }));
  const models = modelsFromOpencodeCatalog({
    connected: ['opencode-go'],
    all: [
      ...registry,
      {
        id: 'opencode-go',
        name: 'OpenCode Go',
        models: { 'glm-5.3-flash': { id: 'glm-5.3-flash', name: 'GLM 5.3 Flash' } }
      }
    ]
  });

  assert.deepEqual(models, [{
    id: 'opencode-go/glm-5.3-flash',
    label: 'GLM 5.3 Flash · OpenCode Go'
  }]);
});

test('OpenCode discovery falls back to the older config providers endpoint', async () => {
  const requested = [];
  const fetchImpl = async (url) => {
    requested.push(url);
    if (url.endsWith('/provider')) return { ok: false, status: 404 };
    return {
      ok: true,
      async json() {
        return { providers: [{ id: 'future', name: 'Future', models: [{ id: 'anything-new', name: 'Anything New' }] }] };
      }
    };
  };
  const result = await fetchOpencodeModels({ baseUrl: 'http://127.0.0.1:4096/', fetchImpl });
  assert.deepEqual(requested, [
    'http://127.0.0.1:4096/provider',
    'http://127.0.0.1:4096/config/providers'
  ]);
  assert.deepEqual(result.models, [{ id: 'future/anything-new', label: 'Anything New · Future' }]);
});

test('OpenCode catalog discovery preserves deterministic per-model image capabilities', () => {
  const models = modelsFromOpencodeCatalog({
    connected: ['future'],
    all: [{
      id: 'future',
      models: {
        vision: { id: 'vision', capabilities: { input: { image: true } } },
        text: { id: 'text', capabilities: { input: { image: false } } },
        array: { id: 'array', modalities: { input: ['text', 'image'] } }
      }
    }]
  });
  assert.deepEqual(models.map(({ id, supportsImages }) => ({ id, supportsImages })), [
    { id: 'future/array', supportsImages: true },
    { id: 'future/text', supportsImages: false },
    { id: 'future/vision', supportsImages: true }
  ]);
});

test('OpenCode catalog discovery accepts array variants and orders custom modes deterministically', () => {
  const [model] = modelsFromOpencodeCatalog({
    providers: [{
      id: 'future',
      models: [{
        id: 'reasoner',
        variants: [{ id: 'ultra' }, 'low', { id: 'custom' }, { id: 'low' }]
      }]
    }]
  });
  assert.deepEqual(model.reasoning, {
    efforts: ['low', 'ultra', 'custom'],
    default: 'low'
  });
});
