import test from 'node:test';
import assert from 'node:assert/strict';

import {
  normalizePdfPageInput,
  normalizePdfPageLayout,
  normalizePdfZoomMode,
  pdfPageNavigationTarget,
  pdfPageLayoutLabel,
  pdfSpreadIndex,
  pdfZoomModeLabel
} from '../../apps/chrome/src/pdf/pdf-view-mode.js';

test('PDF page-number input keeps valid pages and clamps out-of-range values', () => {
  assert.equal(normalizePdfPageInput('4', 12, 2), 4);
  assert.equal(normalizePdfPageInput('99', 12, 2), 12);
  assert.equal(normalizePdfPageInput('-3', 12, 2), 1);
  assert.equal(normalizePdfPageInput('4.9', 12, 2), 4);
  assert.equal(normalizePdfPageInput('', 12, 7), 7);
  assert.equal(normalizePdfPageInput('not a page', 12, 7), 7);
  assert.equal(normalizePdfPageInput('1', 0, 1), 0);
});

test('PDF view modes expose continuous, single-page, and spread layouts', () => {
  assert.equal(normalizePdfPageLayout('continuous'), 'continuous');
  assert.equal(normalizePdfPageLayout('page'), 'page');
  assert.equal(normalizePdfPageLayout('spread'), 'spread');
  assert.equal(normalizePdfPageLayout('single'), 'continuous');
  assert.equal(normalizePdfPageLayout('unknown'), 'continuous');
  assert.equal(pdfPageLayoutLabel('page'), 'Single page');
  assert.equal(pdfPageLayoutLabel('spread'), 'Two-page spread');
});

test('PDF page sizing supports automatic, fit-page, and wide fit-width modes', () => {
  assert.equal(normalizePdfZoomMode('auto'), 'auto');
  assert.equal(normalizePdfZoomMode('page'), 'page');
  assert.equal(normalizePdfZoomMode('width'), 'width');
  assert.equal(normalizePdfZoomMode('custom'), 'custom');
  assert.equal(pdfZoomModeLabel('page'), 'Fit page');
  assert.equal(pdfZoomModeLabel('width'), 'Fit width');
});

test('PDF arrow navigation advances by a page or by a complete two-page spread', () => {
  assert.equal(pdfPageNavigationTarget(2, 8, 1, 'continuous'), 3);
  assert.equal(pdfPageNavigationTarget(2, 8, -1, 'page'), 1);
  assert.equal(pdfPageNavigationTarget(1, 8, 1, 'spread'), 3);
  assert.equal(pdfPageNavigationTarget(2, 8, 1, 'spread'), 3);
  assert.equal(pdfPageNavigationTarget(3, 8, -1, 'spread'), 1);
  assert.equal(pdfPageNavigationTarget(7, 8, 1, 'spread'), 7);
  assert.equal(pdfPageNavigationTarget(8, 8, 1, 'spread'), 8);
  assert.equal(pdfPageNavigationTarget(8, 8, -1, 'spread'), 5);
  assert.equal(pdfPageNavigationTarget(5, 5, 1, 'spread'), 5);
  assert.equal(pdfPageNavigationTarget(2, 2, 1, 'spread'), 2);
});

test('PDF spread rows pair adjacent pages without sharing layout across the document', () => {
  assert.equal(pdfSpreadIndex(1), 0);
  assert.equal(pdfSpreadIndex(2), 0);
  assert.equal(pdfSpreadIndex(45), 22);
  assert.equal(pdfSpreadIndex(46), 22);
  assert.equal(pdfSpreadIndex(47), 23);
  assert.equal(pdfSpreadIndex('not a page'), 0);
});
