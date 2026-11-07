import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough, Writable } from 'node:stream';
import { codexModelChoices, queryCodexModels, createCodexModelCatalog } from '../../scripts/bridges/lib/codex-model-catalog.mjs';
import { discoverCodexModels, buildProviderRequest } from '../../apps/chrome/src/provider-runtime.js';

const model = (id) => ({ id, model: id, displayName: id.toUpperCase(), hidden: false,
  supportedReasoningEfforts: [{ reasoningEffort: 'low' }, { reasoningEffort: 'future' }], defaultReasoningEffort: 'future', inputModalities: ['text'] });

test('Codex discovery accepts new model IDs and capabilities without showing hidden models', () => {
  const models = codexModelChoices([model('gpt-6.1-sol'), { ...model('hidden'), hidden: true }, model('future-version')]);
  assert.deepEqual(models.map((m) => m.id), ['gpt-6.1-sol', 'future-version']);
  assert.deepEqual(models[0].reasoning, { efforts: ['low', 'future'], default: 'future' });
  assert.equal(models[0].supportsImages, false);
});

test('discovery initializes app-server, follows pagination, and never starts inference', async () => {
  const sent = [];
  let killed = false;
  const spawnProcess = (_command, args) => {
    assert.deepEqual(args, ['app-server', '--listen', 'stdio://']);
    const child = new EventEmitter();
    child.stdout = new PassThrough(); child.stderr = new PassThrough();
    child.kill = () => { killed = true; queueMicrotask(() => child.emit('close')); };
    child.stdin = new Writable({ write(chunk, _encoding, done) {
      const request = JSON.parse(String(chunk)); sent.push(request);
      const result = request.method === 'initialize' ? {} : request.method === 'model/list'
        ? { data: [model(request.params.cursor ? 'future-version' : 'gpt-6.1-sol')], nextCursor: request.params.cursor ? null : 'page2' } : null;
      if (result) queueMicrotask(() => child.stdout.write(JSON.stringify({ id: request.id, result }) + '\n'));
      done();
    }});
    return child;
  };
  const result = await queryCodexModels('fixture-codex', { spawnProcess });
  assert.deepEqual(result.map((m) => m.id), ['gpt-6.1-sol', 'future-version']);
  assert.deepEqual(sent.map((r) => r.method), ['initialize', 'initialized', 'model/list', 'model/list']);
  assert.equal(sent[2].params.includeHidden, false);
  assert.equal(killed, true);
});

test('catalog refresh is deduplicated, picks up new releases and retains last-known models offline', async () => {
  let time = 0, calls = 0, fail = false;
  const catalog = createCodexModelCatalog({ codex: 'fixture', now: () => time, fallback: ['old'],
    query: async () => { calls++; if (fail) throw Error('offline'); return codexModelChoices([model(calls === 1 ? 'gpt-6.1-sol' : 'future-version')]); } });
  const [first, second] = await Promise.all([catalog.read(), catalog.read()]);
  assert.equal(calls, 1); assert.deepEqual(first, second);
  time = 121_000;
  assert.equal((await catalog.read())[0].id, 'future-version');
  fail = true; time += 121_000;
  assert.equal((await catalog.read())[0].id, 'future-version');
  await catalog.read(); assert.equal(calls, 3, 'failure retry is throttled');
});

test('extension discovery preserves new capabilities through settings normalization and request creation', async (t) => {
  const original = globalThis.fetch;
  t.after(() => { globalThis.fetch = original; });
  globalThis.fetch = async (url) => {
    assert.equal(url, 'http://127.0.0.1:8789/v1/models');
    return Response.json({ data: codexModelChoices([model('gpt-6.1-sol')]) });
  };
  const { models } = await discoverCodexModels({});
  const request = buildProviderRequest({ provider: 'codex', model: 'gpt-6.1-sol', reasoningEffort: 'future', messages: [{ role: 'user', content: 'Explain a concept' }] },
    { discoveredModels: { codex: models } });
  assert.equal(JSON.parse(request.fetchOptions.body).reasoning_effort, 'future');
  assert.throws(() => buildProviderRequest({ provider: 'codex', model: 'gpt-6.1-sol', bridgeSupportsImages: true,
    messages: [{ role: 'user', content: 'Look', imageDataUrl: 'data:image/png;base64,AAAA' }] },
  { discoveredModels: { codex: models } }), /text-only/);
});
