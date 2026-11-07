import test from 'node:test';
import assert from 'node:assert/strict';
import {
  activePdfMimeStreamInfo,
  normalizePdfMimeStreamInfo,
  pdfMimeHandlerAvailable,
  pdfMimeHandlerEnabled,
  pdfMimeHandlerFrameId,
  pdfMimeNavigationTarget,
  pdfMimeSource
} from '../../apps/chrome/src/pdf/pdf-mime-handler.js';

const streamInfo = {
  embedded: false,
  mimeType: 'application/pdf',
  originalUrl: 'file:///Users/reader/Lecture%20notes.pdf#page=2',
  responseHeaders: { 'content-type': 'application/pdf' },
  streamUrl: 'externalfile:opaque-stream',
  tabId: 42
};

test('a MIME-handled PDF retains its original address and opaque stream', () => {
  assert.deepEqual(normalizePdfMimeStreamInfo(streamInfo), streamInfo);
  assert.deepEqual(pdfMimeSource(streamInfo), {
    pageTitle: 'Lecture notes.pdf',
    pdfUrl: streamInfo.originalUrl,
    url: 'file://',
    sourceKind: 'pdf',
    mimeHandler: true
  });
});

test('MIME stream validation rejects non-PDF and privileged sources', () => {
  assert.equal(normalizePdfMimeStreamInfo({ ...streamInfo, mimeType: 'text/html' }), null);
  assert.equal(normalizePdfMimeStreamInfo({ ...streamInfo, originalUrl: 'chrome://settings' }), null);
  assert.equal(normalizePdfMimeStreamInfo({ ...streamInfo, streamUrl: '' }), null);
});

test('only durable PDF addresses are used to migrate legacy reader tabs', () => {
  assert.equal(pdfMimeNavigationTarget('file:///Users/reader/Notes.pdf'), 'file:///Users/reader/Notes.pdf');
  assert.equal(pdfMimeNavigationTarget('https://example.test/report.pdf?token=one#page=3'), 'https://example.test/report.pdf?token=one#page=3');
  assert.equal(pdfMimeNavigationTarget('blob:chrome-extension://abcdefgh/value'), '');
  assert.equal(pdfMimeNavigationTarget('data:application/pdf;base64,JVBERi0='), '');
});

test('the MIME reader frame can be rediscovered after its service worker sleeps', () => {
  const handlerUrl = 'chrome-extension://abcdefgh/pdf-viewer.html';
  assert.equal(pdfMimeHandlerFrameId([
    { documentUrl: 'chrome-extension://abcdefgh/panel.html', frameId: 3 },
    { documentUrl: `${handlerUrl}?ignored=1`, frameId: 12 }
  ], handlerUrl), 12);
  assert.equal(pdfMimeHandlerFrameId([
    { documentUrl: 'https://example.test/report.pdf', frameId: 0 }
  ], handlerUrl), null);
  assert.equal(pdfMimeHandlerFrameId([], 'https://example.test/viewer.html'), null);
});

test('MIME handler availability, options, and page-only stream lookup are guarded', async () => {
  const chromeApi = {
    runtime: {
      getManifest: () => ({ mime_types_handler: { 'application/pdf': { handler_url: 'pdf-viewer.html' } } })
    },
    mimeHandler: {
      async getMimeHandlerOptions(mimeType) {
        assert.equal(mimeType, 'application/pdf');
        return { enabled: true };
      },
      async getStreamInfo() { return streamInfo; }
    }
  };
  assert.equal(pdfMimeHandlerAvailable(chromeApi), true);
  assert.equal(await pdfMimeHandlerEnabled(chromeApi), true);
  assert.deepEqual(await activePdfMimeStreamInfo(chromeApi), streamInfo);

  chromeApi.mimeHandler.getMimeHandlerOptions = async () => ({ enabled: false });
  assert.equal(await pdfMimeHandlerEnabled(chromeApi), false);
  chromeApi.mimeHandler.getStreamInfo = async () => { throw new Error('Not a handler page'); };
  assert.equal(await activePdfMimeStreamInfo(chromeApi), null);
  assert.equal(pdfMimeHandlerAvailable({}), false);
});

test('an exposed MIME API cannot redirect standalone readers into an unregistered native handler', async () => {
  const chromeApi = {
    runtime: { getManifest: () => ({ manifest_version: 3 }) },
    mimeHandler: {
      getStreamInfo() { throw new Error('Must not enter the native handler'); },
      getMimeHandlerOptions() { throw new Error('Must not consult stale native preferences'); }
    }
  };
  assert.equal(pdfMimeHandlerAvailable(chromeApi), false);
  assert.equal(await pdfMimeHandlerEnabled(chromeApi), false);
  assert.equal(await activePdfMimeStreamInfo(chromeApi), null);
});
