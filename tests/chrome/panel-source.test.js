import test from 'node:test';
import assert from 'node:assert/strict';
import { panelSourceTab } from '../../apps/chrome/src/panel-source.js';

test('sidebar source queries its own window and rejects tab or page changes', async () => {
  let query;
  const tabs = { query: async (value) => { query = value; return [{ id: 12, windowId: 4, url: 'https://course.test/page' }]; } };
  assert.equal((await panelSourceTab(tabs, { windowId: 4, expectedTabId: 12 })).id, 12);
  assert.deepEqual(query, { active: true, windowId: 4 });
  await assert.rejects(panelSourceTab(tabs, { windowId: 4, expectedTabId: 11 }), /source page changed/);
  await assert.rejects(panelSourceTab(tabs, { windowId: 4, expectedTabId: 12, expectedUrl: 'https://course.test/old' }), /source page changed/);
});
