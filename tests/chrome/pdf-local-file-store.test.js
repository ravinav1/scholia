import test from 'node:test';
import assert from 'node:assert/strict';
import {
  LOCAL_PDF_FILE_MAX_AGE,
  localPdfFileSource,
  normalizeLocalPdfFileRecord
} from '../../apps/chrome/src/pdf/pdf-local-file-store.js';

const SOURCE_ID = 'local-file-source-1234';

function fileHandle(name = 'Lecture notes.pdf') {
  return {
    kind: 'file',
    name,
    async getFile() {}
  };
}

test('local PDF handles retain only bounded restore metadata', () => {
  const now = 1_000_000;
  const handle = fileHandle();
  const record = normalizeLocalPdfFileRecord({
    id: SOURCE_ID,
    handle,
    name: ' Lecture notes.pdf ',
    size: 42_000,
    lastModified: 900_000,
    createdAt: now - 500,
    accessedAt: now - 10
  }, SOURCE_ID, { now });

  assert.deepEqual(record, {
    id: SOURCE_ID,
    handle,
    name: 'Lecture notes.pdf',
    size: 42_000,
    lastModified: 900_000,
    createdAt: now - 500,
    accessedAt: now - 10
  });
  assert.deepEqual(localPdfFileSource(record), {
    id: SOURCE_ID,
    createdAt: now - 500,
    accessedAt: now - 10,
    pdfUrl: '',
    fileHandleId: SOURCE_ID,
    url: 'file://',
    pageTitle: 'Lecture notes.pdf'
  });
});

test('invalid, mismatched, and stale local PDF handles are rejected', () => {
  const now = LOCAL_PDF_FILE_MAX_AGE + 10_000;
  const valid = {
    id: SOURCE_ID,
    handle: fileHandle(),
    createdAt: 1,
    accessedAt: now
  };

  assert.equal(normalizeLocalPdfFileRecord({ ...valid, id: 'another-source-1234' }, SOURCE_ID, { now }), null);
  assert.equal(normalizeLocalPdfFileRecord({ ...valid, handle: { kind: 'directory', getFile() {} } }, SOURCE_ID, { now }), null);
  assert.equal(normalizeLocalPdfFileRecord({ ...valid, accessedAt: 1 }, SOURCE_ID, { now }), null);
  assert.equal(normalizeLocalPdfFileRecord(valid, 'short', { now }), null);
});
