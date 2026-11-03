import test from 'node:test';
import assert from 'node:assert/strict';
import { packPageContext } from '../packages/core/src/context.js';
import { mergeSettings } from '../packages/core/src/providers.js';
import { contextCharacterLimit, contextIsEnabled, FULL_CONTEXT_CHARS } from '../apps/chrome/src/context-mode.js';
import { formatPdfContext } from '../apps/chrome/src/pdf-context.js';
import { pdfSelectionMetadata } from '../apps/chrome/src/pdf-selection-context.js';
import { selectionContextForQuestion } from '../apps/chrome/src/selection-context.js';
import { normalizeChatRecord } from '../apps/chrome/src/chat-history.js';
import { buildProviderRequest } from '../apps/chrome/src/provider-runtime.js';

const pages = Array.from({ length: 15 }, (_, index) =>
  `Article page ${index + 1} introduction.\n${'Evidence from the complete research article. '.repeat(160)}\nUnique conclusion ${index + 1}.`);
const article = formatPdfContext(pages);

test('Full context carries a dense 15-page article through selection, saved chat, and provider follow-ups', async () => {
  assert.ok(article.context.length > 100_000);
  assert.ok(article.context.length < FULL_CONTEXT_CHARS);
  const metadata = await pdfSelectionMetadata({
    metadata: article, pageCount: pages.length, fullContext: true,
    readPage: () => assert.fail('An indexed article should not be read twice')
  });
  const context = selectionContextForQuestion({ ...metadata, selection: 'Article page 7' }, 'Explain this.', {
    maxChars: contextCharacterLimit('full')
  });
  assert.equal(context, article.context);
  const chat = normalizeChatRecord({
    id: 'article', capture: { context, sourceKind: 'pdf', compactContextEnabled: false },
    messages: [{ role: 'user', content: 'Explain this.' }, { role: 'assistant', content: 'Explanation.' }]
  });
  assert.equal(chat.capture.context, article.context);
  const request = buildProviderRequest({
    provider: 'openai', model: 'gpt-5-mini', context: chat.capture.context,
    includeContext: true, compactContext: false,
    messages: [...chat.messages, { role: 'user', content: 'Compare all of the findings.' }]
  }, mergeSettings({ apiKeys: { openai: 'test-key' } }));
  const sent = JSON.parse(request.fetchOptions.body).messages.at(-1).content;
  assert.ok(sent.includes(article.context));
});

test('Full context keeps an entire web article and still bounds oversized sources', () => {
  const options = { maxChars: contextCharacterLimit('full') };
  assert.equal(packPageContext(pages.join('\n\n'), options), pages.join('\n\n'));
  const oversized = packPageContext(pages.join('\n\n').repeat(4), options);
  assert.ok(oversized.length <= FULL_CONTEXT_CHARS);
  assert.match(oversized, /Source excerpts:/);
  assert.equal(packPageContext('x'.repeat(FULL_CONTEXT_CHARS), options).length, FULL_CONTEXT_CHARS);
});

test('Compact and None keep their smaller or empty context', () => {
  for (const mode of ['compact', 'none']) {
    const packed = selectionContextForQuestion(article, 'Explain this.', {
      maxChars: contextCharacterLimit(mode), includePageContext: contextIsEnabled(mode)
    });
    if (mode === 'compact') assert.ok(packed.length > 0 && packed.length <= 6_000);
    else assert.equal(packed, '');
  }
});

test('Full selections read all article pages before the background index is ready', async () => {
  const reads = [];
  const result = await pdfSelectionMetadata({
    pageCount: pages.length, selectedPages: [7], fullContext: true,
    readPage: (page) => { reads.push(page); return pages[page - 1]; }
  });
  assert.deepEqual(reads, Array.from({ length: 15 }, (_, index) => index + 1));
  assert.equal(result.context, article.context);
  assert.equal(result.pdfLocalContext, false);
});

test('Full context uses extracted size rather than a hard article page-count cutoff', async () => {
  const metadata = formatPdfContext(Array.from({ length: 60 }, (_, index) => `Short page ${index + 1}`));
  assert.equal(await pdfSelectionMetadata({
    metadata, pageCount: 60, fullContext: true,
    readPage: () => assert.fail('Use the complete cached text')
  }), metadata);
});

test('early Full selections stop reading oversized PDFs and retain the selected neighborhood', async () => {
  const reads = [];
  const result = await pdfSelectionMetadata({
    pageCount: 15, selectedPages: [10], fullContext: true,
    readPage: (page) => { reads.push(page); return `Page ${page} evidence. ${'x'.repeat(FULL_CONTEXT_CHARS)}`; }
  });
  assert.deepEqual(reads, [1, 9, 10, 11]);
  assert.equal(result.pdfLocalContext, true);
  assert.match(result.context, /Page 10 evidence/);
  assert.ok(result.context.length <= 6_000);
});

test('unavailable article pages fall back without discarding the selection or repeating failed reads', async () => {
  const reads = [];
  const result = await pdfSelectionMetadata({
    pageCount: 15, selectedPages: [2], fullContext: true,
    readPage: (page) => { reads.push(page); if (page === 1) throw new Error('Damaged page'); return pages[page - 1]; }
  });
  assert.deepEqual(reads, [1, 2, 3]);
  assert.equal(result.pdfLocalContext, true);
  assert.match(result.context, /Article page 2 introduction/);
  assert.match(result.context, /Text could not be extracted/);
});
