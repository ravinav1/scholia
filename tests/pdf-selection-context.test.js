import test from 'node:test';
import assert from 'node:assert/strict';
import { pdfSelectionMetadata, pdfSelectionPages } from '../apps/chrome/src/pdf-selection-context.js';
import { selectionContextForQuestion } from '../apps/chrome/src/selection-context.js';

test('large PDF explanations read only the selected page neighborhood, even beyond the index limit', async () => {
  const reads = [];
  const result = await pdfSelectionMetadata({
    pageCount: 8_000,
    selectedPages: [6_123],
    selection: 'local definition',
    readPage: async (page) => { reads.push(page); return `Page ${page}: local definition`; }
  });
  assert.deepEqual(reads, [6_122, 6_123, 6_124]);
  assert.equal(result.pdfLocalContext, true);
  assert.match(result.context, /\[PDF page 6123 of 8000\]/);
  assert.doesNotMatch(result.context, /\[PDF page 1 of/);
});

test('small indexed PDFs retain their full context', async () => {
  const metadata = { context: 'Complete short document', pageCount: 4 };
  const result = await pdfSelectionMetadata({
    metadata, pageCount: 4,
    readPage: () => assert.fail('No extra page reads are needed')
  });
  assert.equal(result, metadata);
});

test('dense PDFs use compact local context even with few pages', async () => {
  const result = await pdfSelectionMetadata({
    metadata: { context: 'x'.repeat(100_001) }, pageCount: 3, selectedPages: [2],
    selection: 'rare local formula',
    readPage: (page) => page === 2
      ? `${'Earlier content. '.repeat(3_000)}rare\nlocal formula${' Later content.'.repeat(3_000)}`
      : 'Other page text. '.repeat(3_000)
  });
  assert.equal(result.pdfLocalContext, true);
  assert.ok(result.context.length <= 6_000);
  const packed = selectionContextForQuestion({ ...result, selection: 'rare local formula' }, 'Explain this.');
  assert.match(packed, /rare local formula/);
  assert.match(packed, /\[PDF page 2 of 3\]/);
  assert.ok(packed.length <= 6_000);
});

test('selection page endpoints take precedence over the currently visible page', () => {
  const node = (page) => ({ nodeType: 3, parentElement: {
    closest: () => ({ dataset: { pageNumber: String(page) } })
  } });
  assert.deepEqual(pdfSelectionPages({ startContainer: node(43), endContainer: node(44) }, 1), [43, 44]);
  assert.deepEqual(pdfSelectionPages(null, 27), [27]);
});

test('cross-page selections keep both endpoints within the compact budget', async () => {
  const reads = [];
  const result = await pdfSelectionMetadata({
    pageCount: 100, selectedPages: [49, 50],
    readPage: (page) => { reads.push(page); return `Text on page ${page}. `.repeat(2_000); }
  });
  assert.deepEqual(reads, [48, 49, 50, 51]);
  assert.match(result.context, /Text on page 49/);
  assert.match(result.context, /Text on page 50/);
  assert.ok(result.context.length <= 6_000);
});

test('document boundaries and unavailable page text still produce useful local context', async () => {
  const reads = [];
  const result = await pdfSelectionMetadata({
    pageCount: 50, selectedPages: [50],
    readPage: (page) => {
      reads.push(page);
      if (page === 49) throw new Error('Page unavailable');
      return 'Selected final page';
    }
  });
  assert.deepEqual(reads, [49, 50]);
  assert.match(result.context, /Text could not be extracted/);
  assert.match(result.context, /Selected final page/);
});

test('explanations can read a page before the full index is ready', async () => {
  const result = await pdfSelectionMetadata({
    metadata: null, pageCount: 1,
    readPage: () => 'Readable page before background indexing finishes'
  });
  assert.equal(result.pdfLocalContext, true);
  assert.match(result.context, /Readable page/);
});

test('a partial basic index does not hide the selected page of a short PDF', async () => {
  const reads = [];
  const result = await pdfSelectionMetadata({
    metadata: { context: 'Only page one so far', pageCount: 4, extractedPageCount: 1 },
    pageCount: 4, selectedPages: [4],
    readPage: (page) => { reads.push(page); return `Native text on page ${page}`; }
  });
  assert.deepEqual(reads, [3, 4]);
  assert.match(result.context, /Native text on page 4/);
  assert.equal(result.pdfLocalContext, true);
});

test('image captures without text retain the current page and adjacent context', async () => {
  const result = await pdfSelectionMetadata({
    pageCount: 100, selectedPages: pdfSelectionPages(null, 80),
    readPage: (page) => `Diagram explanation on page ${page}`
  });
  assert.match(result.context, /\[PDF page 80 of 100\]/);
  assert.match(result.context, /Diagram explanation on page 80/);
});
