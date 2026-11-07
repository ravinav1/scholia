import test from 'node:test';
import assert from 'node:assert/strict';
import {
  activePdfOutlineEntry,
  pdfOutlineItemCount
} from '../../apps/chrome/src/pdf/pdf-outline.js';

test('PDF outline item counts include nested sections and ignore malformed entries', () => {
  assert.equal(pdfOutlineItemCount([
    { title: 'Introduction', items: [] },
    {
      title: 'Methods',
      items: [
        { title: 'Sample', items: [] },
        { title: 'Analysis', items: [{ title: 'Model', items: [] }] }
      ]
    },
    null
  ]), 5);
  assert.equal(pdfOutlineItemCount(null), 0);
});

test('PDF outline current section follows the latest destination at or before the page', () => {
  const entries = [
    { title: 'Introduction', pageNumber: 1, order: 0 },
    { title: 'Methods', pageNumber: 3, order: 1 },
    { title: 'Analysis', pageNumber: 3, order: 2 },
    { title: 'Results', pageNumber: 8, order: 3 },
    { title: 'External resource', pageNumber: null, order: 4 }
  ];
  assert.equal(activePdfOutlineEntry(entries, 1)?.title, 'Introduction');
  assert.equal(activePdfOutlineEntry(entries, 5)?.title, 'Analysis');
  assert.equal(activePdfOutlineEntry(entries, 10)?.title, 'Results');
  assert.equal(activePdfOutlineEntry(entries, 0), null);
});
