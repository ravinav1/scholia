import test from 'node:test';
import assert from 'node:assert/strict';
import {
  limitedModelPickerResults,
  MAX_RENDERED_MODEL_OPTIONS,
  modelMatchesSearch,
  parseModelChoice
} from '../../apps/chrome/src/model-select.js';

test('model picker search matches model names, ids, and providers', () => {
  const model = {
    label: 'GLM 5.3 Flash',
    id: 'opencode-go/glm-5.3-flash',
    provider: 'opencode (local server)'
  };

  assert.equal(modelMatchesSearch(model, 'glm flash'), true);
  assert.equal(modelMatchesSearch(model, '5.3'), true);
  assert.equal(modelMatchesSearch(model, 'opencode local'), true);
  assert.equal(modelMatchesSearch(model, 'Claude'), false);
  assert.equal(modelMatchesSearch({ label: 'Modèle Élève' }, 'modele eleve'), true);
});

test('model choice parsing preserves model ids containing separators', () => {
  assert.deepEqual(parseModelChoice('custom::team::model'), {
    provider: 'custom',
    model: 'team::model'
  });
});

test('model picker caps rendered rows while keeping the selected model visible', () => {
  const choices = Array.from({ length: 2_000 }, (_, index) => ({
    id: `model-${index}`,
    selected: index === 1_999
  }));
  const windowed = limitedModelPickerResults(choices);

  assert.equal(windowed.total, 2_000);
  assert.equal(windowed.results.length, MAX_RENDERED_MODEL_OPTIONS);
  assert.equal(windowed.results.at(-1), choices.at(-1));
  assert.equal(limitedModelPickerResults(choices, 0).results.length, 0);
});
