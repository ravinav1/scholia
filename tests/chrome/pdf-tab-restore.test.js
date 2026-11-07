import test from 'node:test';
import assert from 'node:assert/strict';
import { restoredPdfTabTarget } from '../../apps/chrome/src/pdf/pdf-tab-restore.js';

const viewer = (sourceId) => `chrome-extension://abcdefghijk/pdf-viewer.html?source=${sourceId}`;

test('a recreated reader tab resolves directly to its original PDF URL', async () => {
  const requested = [];
  const target = await restoredPdfTabTarget({
    id: 42,
    pendingUrl: viewer('restore-source-123'),
    url: 'chrome://newtab/'
  }, async (sourceId) => {
    requested.push(sourceId);
    return {
      id: sourceId,
      createdAt: 10,
      accessedAt: 10,
      pdfUrl: 'file:///Users/reader/Lecture%20notes.pdf',
      url: 'file://',
      pageTitle: 'Lecture notes'
    };
  });

  assert.deepEqual(requested, ['restore-source-123']);
  assert.deepEqual(target, {
    sourceId: 'restore-source-123',
    url: 'file:///Users/reader/Lecture%20notes.pdf'
  });
});

test('restore uses the complete PDF address rather than its sanitized display URL', async () => {
  const sourceId = 'signed-source-1234';
  const target = await restoredPdfTabTarget({ id: 43, url: viewer(sourceId) }, async () => ({
    id: sourceId,
    createdAt: 10,
    accessedAt: 10,
    pdfUrl: 'https://papers.example/report.pdf?signature=private#page=4',
    url: 'https://papers.example/report.pdf',
    pageTitle: 'Report'
  }));

  assert.equal(target.url, 'https://papers.example/report.pdf?signature=private#page=4');
});

test('ordinary tabs and transient PDF sources are not redirected during restore', async () => {
  let loads = 0;
  assert.equal(await restoredPdfTabTarget({ id: 7, url: 'https://example.test/' }, async () => {
    loads += 1;
    return null;
  }), null);
  assert.equal(loads, 0);

  assert.equal(await restoredPdfTabTarget({ id: 8, url: viewer('blob-source-1234') }, async (sourceId) => ({
    id: sourceId,
    createdAt: 10,
    accessedAt: 10,
    pdfUrl: 'blob:chrome-extension://abcdefghijk/transient',
    url: 'blob:',
    pageTitle: 'Transient PDF'
  })), null);

  assert.equal(await restoredPdfTabTarget({ id: 9, url: viewer('local-file-source-1234') }, async (sourceId) => ({
    id: sourceId,
    createdAt: 10,
    accessedAt: 10,
    pdfUrl: '',
    fileHandleId: sourceId,
    url: 'file://',
    pageTitle: 'Chosen file.pdf'
  })), null);
});
