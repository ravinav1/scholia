import test from 'node:test';
import assert from 'node:assert/strict';
import {
  collectLivePageText,
  deepPageScrollPlan,
  embeddedFrameContext,
  fullPageCanvasSize,
  mergePageTextSources
} from '../../apps/chrome/src/deep-page.js';

test('live page text merges dynamic sources without repeating an already rendered source', () => {
  const merged = mergePageTextSources([
    { text: 'Visible article text.' },
    { label: 'Duplicate', text: 'Visible article text.' },
    { label: 'Open shadow content', text: 'A dynamically loaded explanation.' }
  ]);
  assert.equal((merged.match(/Visible article text\./g) || []).length, 1);
  assert.match(merged, /\[Open shadow content\]\nA dynamically loaded explanation\./);
});

test('live page extraction includes semantic fallback, open shadow text, accessible frames, and image labels', () => {
  const shadowRoot = { textContent: 'Shadow lesson detail', querySelectorAll: () => [] };
  const article = {
    textContent: 'Visible article text. Deferred article ending.',
    contains: () => false
  };
  const embeddedDocument = {
    title: 'Interactive figure',
    documentElement: { querySelectorAll: () => [] },
    body: { innerText: 'Embedded simulation explanation.' },
    querySelectorAll: () => []
  };
  const frame = { contentDocument: embeddedDocument };
  const image = {
    getAttribute: (name) => name === 'alt' ? 'A labelled phase diagram' : '',
    closest: () => null
  };
  const aria = { getAttribute: () => 'Unrendered chart controls' };
  const documentValue = {
    title: 'Lesson',
    body: { innerText: 'Visible article text.' },
    documentElement: {
      querySelectorAll: (selector) => selector === '*' ? [{ shadowRoot }] : []
    },
    querySelectorAll: (selector) => {
      if (selector.includes('article')) return [article];
      if (selector === 'iframe, frame') return [frame];
      if (selector.startsWith('img')) return [image];
      if (selector === '[aria-label]') return [aria];
      return [];
    }
  };

  const text = collectLivePageText(documentValue);
  assert.match(text, /Visible article text\./);
  assert.match(text, /Deferred article ending\./);
  assert.match(text, /Shadow lesson detail/);
  assert.match(text, /Embedded simulation explanation\./);
  assert.match(text, /Image 1: A labelled phase diagram/);
  assert.match(text, /Unrendered chart controls/);
});

test('deep-page scroll planning covers ordinary pages and clearly caps unbounded pages', () => {
  assert.deepEqual(deepPageScrollPlan(2_500, 1_000, 8), {
    positions: [0, 1_000, 1_500],
    complete: true,
    pageHeight: 2_500,
    viewportHeight: 1_000
  });
  const capped = deepPageScrollPlan(10_000, 1_000, 3);
  assert.equal(capped.complete, false);
  assert.deepEqual(capped.positions, [0, 4_500, 9_000]);
});

test('full-page visual canvas stays within browser-safe dimensions and pixel budget', () => {
  const size = fullPageCanvasSize({
    viewportWidth: 1_200,
    viewportHeight: 800,
    pageHeight: 30_000,
    imageWidth: 2_400,
    imageHeight: 1_600
  });
  assert.ok(size.width <= 1_400);
  assert.ok(size.height <= 16_000);
  assert.ok(size.width * size.height <= 14_000_000);
  assert.ok(size.scale > 0 && size.scale <= 1);
});

test('embedded-frame context excludes the main frame and duplicate page text', () => {
  const context = embeddedFrameContext([
    { frameId: 0, result: { title: 'Main', text: 'Main article'.repeat(20) } },
    { frameId: 2, result: { title: 'Duplicate', text: 'Main article'.repeat(20) } },
    { frameId: 3, result: { title: 'Useful widget', url: 'https://widget.test/', text: 'Interactive derivation '.repeat(12) } }
  ], { mainContext: 'Main article'.repeat(20) });
  assert.doesNotMatch(context, /Duplicate/);
  assert.match(context, /Embedded frame: Useful widget/);
  assert.match(context, /Interactive derivation/);
});
