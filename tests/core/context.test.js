import test from 'node:test';
import assert from 'node:assert/strict';
import {
  COMPACT_PACKED_CONTEXT_CHARS,
  packPageContext,
  packParentContext,
  packSiteContext
} from '../../packages/core/src/context.js';

test('compact automatic context uses the fast prompt budget', () => {
  assert.equal(COMPACT_PACKED_CONTEXT_CHARS, 6_000);
});

test('page context stays complete when small and becomes a relevant bounded pack when large', () => {
  assert.equal(packPageContext('A complete short page.'), 'A complete short page.');

  const sections = Array.from({ length: 36 }, (_, index) => {
    const detail = index === 27
      ? 'The rare calibration rule uses a cobalt reference before every measurement.'
      : `General background material for chapter ${index + 1}.`;
    return `Chapter ${index + 1}\n${detail}\n${'Supporting explanation. '.repeat(45)}`;
  });
  const packed = packPageContext(sections.join('\n\n'), {
    outline: sections.map((_, index) => `- Chapter ${index + 1}`).join('\n'),
    selection: 'The rare calibration rule uses a cobalt reference before every measurement.',
    question: 'Why is the cobalt reference needed?',
    maxChars: 6_000
  });

  assert.ok(packed.length <= 6_000);
  assert.match(packed, /indexed the complete rendered page locally/);
  assert.match(packed, /rare calibration rule uses a cobalt reference/);
  assert.match(packed, /Chapter 1/);
  assert.match(packed, /Chapter 36/);
});

test('recursive context retains the parent answer and recent conversation within budget', () => {
  const parent = packParentContext({
    messages: [
      { role: 'user', content: 'Explain the theorem.' },
      { role: 'assistant', content: 'Earlier answer.' },
      { role: 'user', content: 'Can you make that concrete?' }
    ],
    response: `Opening. ${'Detailed derivation. '.repeat(900)} The cobalt step is essential. Closing.`,
    selection: 'The cobalt step is essential.',
    maxChars: 4_000
  });

  assert.ok(parent.length <= 4_000);
  assert.match(parent, /cobalt step is essential/);
  assert.match(parent, /Can you make that concrete/);
});

test('site context keeps a page map and ranks evidence across pages', () => {
  const pages = Array.from({ length: 12 }, (_, index) => ({
    title: `Chapter ${index + 1}`,
    url: `https://course.example/chapter-${index + 1}/`,
    text: index === 8
      ? `Recovery chapter. ${'Write-ahead logging detail. '.repeat(120)} ARIES repeats history during redo.`
      : `Chapter ${index + 1} material. ${'General database explanation. '.repeat(120)}`
  }));
  const packed = packSiteContext(pages, {
    question: 'How does ARIES redo work?',
    discoveredPages: 14,
    truncated: true,
    maxChars: 7_000
  });

  assert.ok(packed.length <= 7_000);
  assert.match(packed, /discovered site corpus/);
  assert.match(packed, /Site map:/);
  assert.match(packed, /ARIES repeats history during redo/);
  assert.match(packed, /safety limit/);
});
