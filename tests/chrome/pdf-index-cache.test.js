import test from 'node:test';
import assert from 'node:assert/strict';
import {
  createPdfIndexCacheRecord,
  MAX_CACHED_PDF_INDEX_CHARACTERS,
  normalizePdfIndexCacheRecord,
  pdfIndexCacheKey
} from '../../apps/chrome/src/pdf/pdf-index-cache.js';

test('PDF index cache keys use the document fingerprint instead of its source URL', () => {
  const key = pdfIndexCacheKey({ numPages: 42, fingerprints: ['abc123', null] });
  assert.equal(key, 'v3:42:abc123');
  assert.equal(pdfIndexCacheKey({ numPages: 42, fingerprints: [] }), '');
});

test('PDF index cache records preserve complete searchable and context page data', () => {
  const record = createPdfIndexCacheRecord({
    key: 'v1:2:document',
    pageCount: 2,
    indexedPageCount: 2,
    searchTexts: ['Page one', 'Page two'],
    contextPages: ['Page one', 'Page two'],
    title: 'Lecture notes',
    ocrPageCount: 1,
    ocrNotice: 'Local OCR recovered text on 1 page.',
    now: 123
  });
  assert.equal(record.characterCount, 32);
  assert.equal(record.ocrPageCount, 1);
  assert.equal(record.ocrNotice, 'Local OCR recovered text on 1 page.');
  assert.deepEqual(normalizePdfIndexCacheRecord(record, {
    key: 'v1:2:document', pageCount: 2, indexedPageCount: 2
  }), record);
  assert.equal(normalizePdfIndexCacheRecord(record, {
    key: 'v1:2:document', pageCount: 3, indexedPageCount: 2
  }), null);
  assert.equal(normalizePdfIndexCacheRecord({ ...record, version: 1 }, {
    key: record.key, pageCount: 2, indexedPageCount: 2
  }), null, 'Indexes created before OCR must be rebuilt');
  assert.equal(normalizePdfIndexCacheRecord({ ...record, version: 2 }, {
    key: record.key, pageCount: 2, indexedPageCount: 2
  }), null, 'Indexes without PDF line separators must be rebuilt');
});

test('oversized or incomplete PDF indexes are not cached', () => {
  assert.equal(createPdfIndexCacheRecord({
    key: 'v1:2:document',
    pageCount: 2,
    indexedPageCount: 2,
    searchTexts: ['only one page'],
    contextPages: []
  }), null);
  assert.equal(createPdfIndexCacheRecord({
    key: 'v1:1:large',
    pageCount: 1,
    indexedPageCount: 1,
    searchTexts: ['x'.repeat(MAX_CACHED_PDF_INDEX_CHARACTERS + 1)],
    contextPages: []
  }), null);
});
