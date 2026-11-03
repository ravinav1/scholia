import test from 'node:test';
import assert from 'node:assert/strict';
import { parseHTML } from 'linkedom';
import { normalizeRecentModels, recordRecentModel, recentModelChoices } from '../packages/core/src/recent-models.js';
import { mergeSettings, publicSettings, providerModelChoices } from '../packages/core/src/providers.js';
import { studyModelPickerMarkup } from '../apps/web/model-picker.js';

test('recent use persists provider/model identity, moves repeats to the top and bounds history', () => {
  let records = [];
  for (let i = 1; i <= 15; i++) records = recordRecentModel(records, 'codex', `model-${i}`, i);
  records = recordRecentModel(records, 'openai', 'model-14', 20);
  records = recordRecentModel(records, 'codex', 'model-14', 21);
  assert.equal(records.length, 12);
  assert.deepEqual(records.slice(0, 2).map((r) => [r.providerID, r.modelID]), [['codex', 'model-14'], ['openai', 'model-14']]);
  const settings = publicSettings(mergeSettings(JSON.parse(JSON.stringify({ recentModels: records }))));
  assert.deepEqual(settings.recentModels, records);
  assert.ok(providerModelChoices('codex', settings).some((m) => m.id === 'model-14'));
  assert.equal(normalizeRecentModels([null, {}, { providerID: 'codex', modelID: 'bad', lastUsedAt: Infinity }]).length, 0);
});

test('study picker shows recent models once, newest first, and keeps the selected provider distinct', () => {
  const models = [
    { id: 'same', label: 'A', provider: 'OpenAI', providerID: 'openai', lastUsedAt: 10 },
    { id: 'other', label: 'Other', provider: 'OpenAI', providerID: 'openai' },
    { id: 'same', label: 'B', provider: 'Codex', providerID: 'codex', lastUsedAt: 20 }
  ];
  assert.deepEqual(recentModelChoices(models).map((m) => m.label), ['B', 'A']);
  const { document } = parseHTML(`<select>${studyModelPickerMarkup(models, 'codex', 'same')}</select>`);
  assert.equal(document.querySelector('optgroup').getAttribute('label'), 'Recently used');
  assert.equal(document.querySelectorAll('option').length, 3);
  assert.equal(document.querySelectorAll('option[selected]').length, 1);
  assert.equal(document.querySelector('option[selected]').textContent, 'B · Codex');
});
