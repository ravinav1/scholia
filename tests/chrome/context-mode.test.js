import test from 'node:test';
import assert from 'node:assert/strict';
import {
  CONTEXT_MODE_COMPACT,
  CONTEXT_MODE_FULL,
  CONTEXT_MODE_NONE,
  contextCharacterLimit,
  contextIsEnabled,
  defaultContextMode,
  normalizeContextMode
} from '../../apps/chrome/src/context-mode.js';

test('the global compact preference falls back to full context when disabled', () => {
  assert.equal(defaultContextMode({ includePageContext: true }), CONTEXT_MODE_COMPACT);
  assert.equal(defaultContextMode({ includePageContext: false }), CONTEXT_MODE_FULL);
  assert.ok(contextCharacterLimit(CONTEXT_MODE_FULL) > contextCharacterLimit(CONTEXT_MODE_COMPACT));
});

test('no context is an explicit third mode', () => {
  assert.equal(contextIsEnabled(CONTEXT_MODE_COMPACT), true);
  assert.equal(contextIsEnabled(CONTEXT_MODE_FULL), true);
  assert.equal(contextIsEnabled(CONTEXT_MODE_NONE), false);
  assert.equal(normalizeContextMode('', { legacyContextEnabled: false }), CONTEXT_MODE_NONE);
});
