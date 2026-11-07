import test from 'node:test';
import assert from 'node:assert/strict';
import {
  contentFrameTarget,
  isCompletedPdfNavigation,
  isLikelyPdfTab,
  isPdfUrl,
  manualPdfSourceUrl,
  pageSelectionStorageKey,
  pdfSourceStorageKey,
  pdfSourceUrl,
  pdfViewerSourceId,
  pdfViewerTabSourceId,
  preferredContentFrameId,
  safeSourceUrl,
  sendContentFrameMessage,
  tabSource
} from '../../apps/chrome/src/tab-context.js';

test('page selection drafts are isolated to their originating tab', () => {
  assert.equal(pageSelectionStorageKey(41), 'scholia.page-selection.v1.41');
  assert.equal(pageSelectionStorageKey(42), 'scholia.page-selection.v1.42');
  assert.notEqual(pageSelectionStorageKey(41), pageSelectionStorageKey(42));
  assert.equal(pageSelectionStorageKey(null), '');
  assert.equal(pageSelectionStorageKey(-1), '');
});

test('page context messages target one document frame instead of every iframe', () => {
  assert.deepEqual(contentFrameTarget(), { frameId: 0 });
  assert.deepEqual(contentFrameTarget(0), { frameId: 0 });
  assert.deepEqual(contentFrameTarget(7), { frameId: 7 });
  assert.deepEqual(contentFrameTarget('12'), { frameId: 12 });
  assert.deepEqual(contentFrameTarget(-1), { frameId: 0 });
  assert.deepEqual(contentFrameTarget('not-a-frame'), { frameId: 0 });
});

test('a registered MIME reader frame replaces only the default top-level target', () => {
  assert.equal(preferredContentFrameId(undefined, 17), 17);
  assert.equal(preferredContentFrameId(0, 17), 17);
  assert.equal(preferredContentFrameId(8, 17), 8);
  assert.equal(preferredContentFrameId(0, undefined), 0);
});

test('content-frame messaging passes the requested frame to Chrome', async () => {
  const calls = [];
  const tabs = {
    sendMessage: (...args) => {
      calls.push(args);
      return Promise.resolve({ ok: true });
    }
  };
  const message = { type: 'SCHOLIA_GET_PAGE_CONTEXT' };

  assert.deepEqual(await sendContentFrameMessage(tabs, 42, message, 9), { ok: true });
  assert.deepEqual(calls, [[42, message, { frameId: 9 }]]);
});

test('PDF URLs are recognized without leaking query credentials to provider context', () => {
  const url = 'https://papers.example/research/report.pdf?signature=secret#page=4';
  assert.equal(isPdfUrl(url), true);
  assert.equal(pdfSourceUrl({ url }), url);
  assert.equal(safeSourceUrl(url), 'https://papers.example/research/report.pdf');
});

test('Chrome PDF viewer URLs are unwrapped for local extraction', () => {
  const source = 'https://example.test/paper.pdf?token=private';
  const viewer = `chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/index.html?file=${encodeURIComponent(source)}`;
  assert.equal(pdfSourceUrl({ url: viewer }), source);
  assert.deepEqual(tabSource({ id: 7, windowId: 3, title: 'Paper', url: viewer }), {
    tabId: 7,
    windowId: 3,
    pageTitle: 'Paper',
    url: 'https://example.test/paper.pdf',
    pdfUrl: source,
    sourceKind: 'pdf',
    viewerSourceId: ''
  });
});

test('Scholia PDF viewer URLs carry only an opaque source id', () => {
  const viewer = 'chrome-extension://abcdefghijk/pdf-viewer.html?source=12345678-abcd_EF';
  assert.equal(pdfViewerSourceId(viewer), '12345678-abcd_EF');
  assert.equal(pdfSourceStorageKey('12345678-abcd_EF'), 'scholia.pdf-source.v1.12345678-abcd_EF');
  assert.deepEqual(tabSource({ id: 9, windowId: 2, title: 'Paper — Scholia PDF', url: viewer }), {
    tabId: 9,
    windowId: 2,
    pageTitle: 'Paper — Scholia PDF',
    url: '',
    pdfUrl: '',
    sourceKind: 'pdf',
    viewerSourceId: '12345678-abcd_EF'
  });
});

test('restored PDF viewer tabs recover source ids from pending and committed URLs', () => {
  const first = 'chrome-extension://abcdefghijk/pdf-viewer.html?source=restore-source-123';
  const second = 'chrome-extension://abcdefghijk/pdf-viewer.html?source=restore-source-456';
  assert.equal(pdfViewerTabSourceId({ pendingUrl: first, url: 'chrome://newtab/' }), 'restore-source-123');
  assert.equal(pdfViewerTabSourceId({ url: second }), 'restore-source-456');
  assert.equal(pdfViewerTabSourceId({ pendingUrl: 'https://example.test/', url: 'about:blank' }), '');
});

test('manual PDF addresses allow durable sources without embedded credentials', () => {
  assert.equal(
    manualPdfSourceUrl('https://papers.example/report.pdf?download=1#page=4'),
    'https://papers.example/report.pdf?download=1#page=4'
  );
  assert.equal(manualPdfSourceUrl('file:///Users/reader/report.pdf'), 'file:///Users/reader/report.pdf');
  assert.equal(manualPdfSourceUrl('https://user:secret@papers.example/report.pdf'), '');
  assert.equal(manualPdfSourceUrl('data:application/pdf;base64,JVBERi0='), '');
  assert.equal(manualPdfSourceUrl('javascript:alert(1)'), '');
});

test('a PDF filename in the tab title covers endpoints without a PDF suffix', () => {
  const tab = { title: 'lecture-notes.pdf', url: 'https://files.example/download?id=42' };
  assert.equal(isLikelyPdfTab(tab), true);
  assert.equal(pdfSourceUrl(tab), tab.url);
});

test('automatic PDF handoff waits until Chrome finishes rendering the navigation', () => {
  const tab = { title: 'lecture-notes.pdf', url: 'https://files.example/lecture-notes.pdf' };
  assert.equal(isCompletedPdfNavigation({ url: tab.url, status: 'loading' }, tab), false);
  assert.equal(isCompletedPdfNavigation({ url: tab.url }, tab), false);
  assert.equal(isCompletedPdfNavigation({ status: 'complete' }, tab), true);
  assert.equal(isCompletedPdfNavigation({ status: 'complete' }, {
    title: 'Article', url: 'https://files.example/article'
  }), false);
});

test('ordinary web pages remain page sources', () => {
  assert.deepEqual(tabSource({ id: 4, title: 'Article', url: 'https://example.test/read?utm_source=x#part' }), {
    tabId: 4,
    windowId: null,
    pageTitle: 'Article',
    url: 'https://example.test/read',
    pdfUrl: '',
    sourceKind: 'page',
    viewerSourceId: ''
  });
});
