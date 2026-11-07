import test from 'node:test';
import assert from 'node:assert/strict';
import {
  packCompactBrowserWorkspace,
  rankRelatedTabs
} from '../../apps/chrome/src/browser-workspace-context.js';

test('compact browser context correlates the visible page with relevant open tabs', () => {
  const tabs = rankRelatedTabs([
    { id: 1, title: 'Active lecture', url: 'https://course.test/lecture', lastAccessed: 30 },
    { id: 2, title: 'Mitochondrial membrane notes', url: 'https://notes.test/biology', lastAccessed: 20 },
    { id: 3, title: 'Unrelated shopping', url: 'https://shop.test/', lastAccessed: 40 }
  ], {
    activeTabId: 1,
    activeUrl: 'https://course.test/lecture',
    question: 'How does the mitochondrial membrane create ATP?',
    visibleText: 'Oxidative phosphorylation and the proton gradient'
  });
  assert.equal(tabs[0].id, 2);

  const context = packCompactBrowserWorkspace({
    activeTitle: 'Active lecture',
    activeUrl: 'https://course.test/lecture',
    activeVisibleText: 'Oxidative phosphorylation is visible on screen.',
    activeContext: 'The current lecture explains the proton gradient. '.repeat(80),
    relatedTabs: [{
      title: 'Mitochondrial membrane notes',
      url: 'https://notes.test/biology',
      context: 'ATP synthase uses the proton-motive force. '.repeat(40)
    }],
    question: 'How is ATP produced?'
  });

  assert.ok(context.length <= 6_000);
  assert.match(context, /Visible on screen/i);
  assert.match(context, /mitochondrial membrane|ATP synthase/i);
});
