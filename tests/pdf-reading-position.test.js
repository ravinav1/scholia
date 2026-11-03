import test from 'node:test';
import assert from 'node:assert/strict';
import { readPdfPosition, writePdfPosition } from '../apps/chrome/src/pdf-reading-position.js';

test('MIME reader saves and restores its page without navigating the handler frame', () => {
  const values = new Map();
  const context = {
    mimeHandled: true,
    history: { get state() { throw new Error('MIME readers must not use browser history'); }, replaceState() { assert.fail('Would crash Chromium'); } },
    storage: { getItem: (key) => values.get(key), setItem: (key, value) => values.set(key, value) }
  };
  assert.equal(readPdfPosition(context), null);
  const position = { fingerprint: 'document-one', pageNumber: 42 };
  writePdfPosition(position, context);
  assert.deepEqual(readPdfPosition(context), position);
});

test('standalone reader preserves other history state and tolerates unavailable storage', () => {
  const history = { state: { existing: 1 }, replaceState(state) { this.state = state; } };
  const position = { fingerprint: 'local-file', pageNumber: 3 };
  writePdfPosition(position, { history });
  assert.deepEqual(history.state, { existing: 1, scholiaPdfPosition: position });
  assert.deepEqual(readPdfPosition({ history }), position);
  const storage = { getItem() { throw new Error('Blocked'); }, setItem() { throw new Error('Blocked'); } };
  assert.equal(readPdfPosition({ mimeHandled: true, storage }), null);
  assert.doesNotThrow(() => writePdfPosition(position, { mimeHandled: true, storage }));
});
