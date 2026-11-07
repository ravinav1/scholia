import test from 'node:test';
import assert from 'node:assert/strict';
import {
  nativePdfPageFromProgress,
  nativePdfProgressFromScriptResults,
  nativePdfViewportProgress,
  pdfByteProgressView
} from '../../apps/chrome/src/pdf/pdf-progress.js';

test('PDF byte progress describes opening downloads and local range reads', () => {
  assert.deepEqual(
    pdfByteProgressView({ phase: 'download', loaded: 1024 * 1024, total: 4 * 1024 * 1024 }),
    {
      detail: 'Downloading 1.0 MB of 4.0 MB locally…',
      current: 1024 * 1024,
      total: 4 * 1024 * 1024
    }
  );
  assert.deepEqual(
    pdfByteProgressView({ phase: 'load', loaded: 2 * 1024 * 1024, total: 0 }),
    {
      detail: 'Reading 2.0 MB locally…',
      current: 2 * 1024 * 1024,
      total: 0
    }
  );
});

test('late PDF.js range progress cannot replace an interactive or ready state', () => {
  assert.equal(
    pdfByteProgressView(
      { phase: 'load', loaded: 20.2 * 1024 * 1024, total: 42.2 * 1024 * 1024 },
      { interactive: true }
    ),
    null
  );
  assert.equal(pdfByteProgressView({ phase: 'extract', page: 200, total: 573 }), null);
});

test('native PDF scroll progress maps to the page visible at the viewport center', () => {
  assert.equal(nativePdfViewportProgress(0.758), 0.758);
  assert.equal(nativePdfViewportProgress(-0.1), null);
  assert.equal(nativePdfViewportProgress(1.1), null);
  assert.equal(nativePdfPageFromProgress(0, 15), 1);
  assert.equal(nativePdfPageFromProgress(0.758, 15), 12);
  assert.equal(nativePdfPageFromProgress(0.999, 15), 15);
  assert.equal(nativePdfPageFromProgress(null, 15), 0);
});

test('native PDF progress is selected only from a matching injected frame', () => {
  assert.equal(nativePdfProgressFromScriptResults([
    { frameId: 0, result: null },
    { frameId: 4, result: { nativePdfViewer: true, progress: 0.42 } }
  ]), 0.42);
  assert.equal(nativePdfProgressFromScriptResults([
    { result: { nativePdfViewer: false, progress: 0.5 } },
    { result: { nativePdfViewer: true, progress: 4 } }
  ]), null);
});
