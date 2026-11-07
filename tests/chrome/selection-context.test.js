import test from 'node:test';
import assert from 'node:assert/strict';
import { selectionContextForQuestion } from '../../apps/chrome/src/selection-context.js';

test('selection context is repacked around every new question', () => {
  const sections = Array.from({ length: 60 }, (_, index) => {
    if (index === 7) {
      return `Section ${index + 1}. The cobalt reference corrects baseline drift before measurement. ${'calibration filler '.repeat(24)}`;
    }
    if (index === 37) {
      return `Section ${index + 1}. The Zephyr correction is subtracted from the sample spectrum before concentration is estimated. ${'analysis filler '.repeat(24)}`;
    }
    return `Section ${index + 1}. ${`unrelated topic ${index} `.repeat(28)}`;
  });
  const capture = {
    context: sections.join('\n\n'),
    selection: 'The cobalt reference corrects baseline drift before measurement.'
  };

  const first = selectionContextForQuestion(capture, 'Why is the cobalt reference needed?', { maxChars: 5_000 });
  const followUp = selectionContextForQuestion(capture, 'How is the Zephyr correction applied?', { maxChars: 5_000 });

  assert.match(first, /cobalt reference corrects baseline drift/i);
  assert.match(followUp, /cobalt reference corrects baseline drift/i);
  assert.match(followUp, /Zephyr correction is subtracted from the sample spectrum/i);
  assert.notEqual(followUp, first);
});

test('selection context respects the page-context setting', () => {
  assert.equal(selectionContextForQuestion({ context: 'private page text' }, 'Why?', {
    includePageContext: false
  }), '');
});

test('selection context defaults to the compact prompt budget', () => {
  const context = Array.from(
    { length: 80 },
    (_, index) => `Section ${index + 1}. ${'Long automatic reference context. '.repeat(35)}`
  ).join('\n\n');
  const packed = selectionContextForQuestion(
    { context, selection: 'Long automatic reference context.' },
    'Summarize the relevant evidence.'
  );

  assert.ok(packed.length <= 6_000);
});
