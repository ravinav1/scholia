import test from 'node:test';
import assert from 'node:assert/strict';
import {
  configurePdfMimeHandling,
  isBraveBrowser
} from '../apps/chrome/src/browser-compat.js';

test('Brave is detected through its navigator API or browser brand', async () => {
  assert.equal(await isBraveBrowser({ brave: { isBrave: async () => true } }), true);
  assert.equal(await isBraveBrowser({ userAgentData: { brands: [{ brand: 'Brave' }] } }), true);
  assert.equal(await isBraveBrowser({ userAgentData: { brands: [{ brand: 'Chromium' }] } }), false);
});

test('a Chromium-derived browser with the public MIME API enables the fixed handler', async () => {
  const calls = [];
  const result = await configurePdfMimeHandling({
    mimeHandler: {
      async setMimeHandlerOptions(...args) { calls.push(args); }
    }
  }, {
    brave: { isBrave: async () => true }
  });

  assert.deepEqual(calls, [['application/pdf', { enabled: true }]]);
  assert.deepEqual(result, {
    brave: true,
    mimeHandlerConfigured: true,
    mimeHandlerEnabled: true
  });
});

test('Chromium enables the original-URL PDF reader with the history crash workaround', async () => {
  const calls = [];
  const result = await configurePdfMimeHandling({
    mimeHandler: {
      async setMimeHandlerOptions(...args) { calls.push(args); }
    }
  }, {});

  assert.deepEqual(calls, [['application/pdf', { enabled: true }]]);
  assert.deepEqual(result, {
    brave: false,
    mimeHandlerConfigured: true,
    mimeHandlerEnabled: true
  });
});

test('browsers without the public MIME API retain URL-based PDF fallback behavior', async () => {
  assert.deepEqual(await configurePdfMimeHandling({}, {}), {
    brave: false,
    mimeHandlerConfigured: false,
    mimeHandlerEnabled: false
  });
});
