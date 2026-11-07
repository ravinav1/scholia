import test from 'node:test';
import assert from 'node:assert/strict';
import {
  loadPdfSourceRecord,
  normalizePdfSourceRecord,
  pdfSourceRecordIsRestorable,
  prunePdfSourceRecords,
  pdfSourceStorageKeysToPrune,
  storePdfSourceRecord
} from '../../apps/chrome/src/pdf/pdf-source-store.js';

function storageArea(initial = {}) {
  const values = { ...initial };
  return {
    values,
    async get(key) {
      if (key == null) return { ...values };
      return { [key]: values[key] };
    },
    async set(next) { Object.assign(values, next); },
    async remove(keys) {
      for (const key of Array.isArray(keys) ? keys : [keys]) delete values[key];
    }
  };
}

test('PDF source maintenance uses the local storage area and protects open documents', async () => {
  const storage = {
    local: storageArea({
      'scholia.pdf-source.v1.closed-pdf-123': { broken: true },
      'scholia.pdf-source.v1.open-pdf-12345': { broken: true },
      settings: { keep: true }
    }),
    session: storageArea({ untouched: true })
  };
  assert.equal(await prunePdfSourceRecords(storage, ['open-pdf-12345']), 1);
  assert.deepEqual(storage.local.values, {
    'scholia.pdf-source.v1.open-pdf-12345': { broken: true },
    settings: { keep: true }
  });
  assert.deepEqual(storage.session.values, { untouched: true });
});

test('restorable PDF sources survive a missing browser-session record', async () => {
  const now = 50_000;
  const id = 'restore-source-123';
  const key = `scholia.pdf-source.v1.${id}`;
  const session = storageArea();
  const local = storageArea();
  const record = {
    id,
    createdAt: now,
    accessedAt: now,
    pdfUrl: 'https://papers.example/report.pdf?signature=private',
    url: 'https://papers.example/report.pdf',
    pageTitle: 'Report',
    nativeViewportProgress: 0.61
  };

  await storePdfSourceRecord({ session, local }, record, { now });
  assert.deepEqual(local.values[key], record);
  delete session.values[key];

  const restored = await loadPdfSourceRecord({ session, local }, id, { now: now + 1_000 });
  assert.equal(restored.pdfUrl, record.pdfUrl);
  assert.equal(restored.nativeViewportProgress, 0.61);
  assert.equal(restored.accessedAt, now + 1_000);
  assert.deepEqual(session.values[key], restored);
});

test('transient blob and data PDF sources stay session-only', async () => {
  const now = 80_000;
  for (const [id, pdfUrl] of [
    ['blob-source-1234', 'blob:https://example.test/1234'],
    ['data-source-1234', 'data:application/pdf;base64,JVBERi0=']
  ]) {
    const session = storageArea();
    const local = storageArea();
    const record = { id, createdAt: now, accessedAt: now, pdfUrl, url: new URL(pdfUrl).protocol, pageTitle: 'PDF' };
    assert.equal(pdfSourceRecordIsRestorable(record), false);
    await storePdfSourceRecord({ session, local }, record, { now });
    assert.equal(Object.keys(session.values).length, 1);
    assert.equal(Object.keys(local.values).length, 0);
  }
});

test('expired, malformed, and excess PDF source records are pruned', () => {
  const now = 200 * 24 * 60 * 60_000;
  const recent = (id, accessedAt) => ({
    id,
    createdAt: accessedAt,
    accessedAt,
    pdfUrl: `https://example.test/${id}.pdf`,
    url: `https://example.test/${id}.pdf`,
    pageTitle: id
  });
  const values = {
    'scholia.pdf-source.v1.recent-12345': recent('recent-12345', now - 1_000),
    'scholia.pdf-source.v1.older-123456': recent('older-123456', now - 2_000),
    'scholia.pdf-source.v1.expired-1234': recent('expired-1234', 1),
    'scholia.pdf-source.v1.protected-12': { broken: true },
    unrelated: { keep: true }
  };
  assert.deepEqual(pdfSourceStorageKeysToPrune(values, {
    now,
    maxRecords: 1,
    protectedSourceIds: ['protected-12']
  }).sort(), [
    'scholia.pdf-source.v1.expired-1234',
    'scholia.pdf-source.v1.older-123456'
  ]);
  assert.equal(normalizePdfSourceRecord(values['scholia.pdf-source.v1.expired-1234'], 'expired-1234', { now }), null);
});
