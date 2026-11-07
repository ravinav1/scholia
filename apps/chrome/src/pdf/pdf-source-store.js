import { PDF_SOURCE_PREFIX, pdfSourceStorageKey } from '../tab-context.js';

const RESTORABLE_PDF_PROTOCOLS = new Set(['http:', 'https:', 'file:']);
const SESSION_PDF_PROTOCOLS = new Set([...RESTORABLE_PDF_PROTOCOLS, 'data:', 'blob:']);

export const PDF_SOURCE_MAX_AGE = 180 * 24 * 60 * 60_000;
export const PDF_SOURCE_MAX_RECORDS = 256;

function parsedUrl(value) {
  try {
    return new URL(String(value || ''));
  } catch {
    return null;
  }
}

export function normalizePdfSourceRecord(value, sourceId, {
  now = Date.now(),
  maxAge = PDF_SOURCE_MAX_AGE
} = {}) {
  const id = String(sourceId || '');
  if (!pdfSourceStorageKey(id) || !value || value.id !== id) return null;
  const pdfUrl = String(value.pdfUrl || '').trim();
  const parsed = parsedUrl(pdfUrl);
  const createdAt = Number(value.createdAt || 0);
  const accessedAt = Number(value.accessedAt || createdAt);
  if (!parsed || !SESSION_PDF_PROTOCOLS.has(parsed.protocol) || !Number.isFinite(createdAt) || createdAt <= 0) return null;
  if (!Number.isFinite(accessedAt) || accessedAt <= 0 || now - accessedAt > maxAge || accessedAt > now + 60_000) return null;
  const hasNativeViewportProgress = value.nativeViewportProgress !== null
    && value.nativeViewportProgress !== undefined
    && value.nativeViewportProgress !== '';
  const nativeViewportProgress = Number(value.nativeViewportProgress);
  return {
    id,
    createdAt,
    accessedAt,
    pdfUrl,
    url: String(value.url || '').trim().slice(0, 32_768),
    pageTitle: String(value.pageTitle || 'PDF document').trim().slice(0, 500) || 'PDF document',
    ...(hasNativeViewportProgress
      && Number.isFinite(nativeViewportProgress)
      && nativeViewportProgress >= 0
      && nativeViewportProgress <= 1
      ? { nativeViewportProgress }
      : {})
  };
}

export function pdfSourceRecordIsRestorable(value) {
  const parsed = parsedUrl(value?.pdfUrl);
  return Boolean(parsed
    && RESTORABLE_PDF_PROTOCOLS.has(parsed.protocol)
    && String(value.pdfUrl).length <= 32_768);
}

export async function storePdfSourceRecord(storage, value, { now = Date.now() } = {}) {
  const record = normalizePdfSourceRecord({ ...value, accessedAt: value.accessedAt || now }, value?.id, { now });
  if (!record) throw new Error('Scholia could not prepare this PDF source.');
  const key = pdfSourceStorageKey(record.id);
  await storage.session.set({ [key]: record });
  if (pdfSourceRecordIsRestorable(record)) await storage.local.set({ [key]: record });
  else await storage.local.remove(key).catch(() => {});
  return record;
}

export async function loadPdfSourceRecord(storage, sourceId, { now = Date.now() } = {}) {
  const key = pdfSourceStorageKey(sourceId);
  if (!key) return null;

  const sessionValue = (await storage.session.get(key))[key];
  let record = normalizePdfSourceRecord(sessionValue, sourceId, { now });
  if (!record) {
    if (sessionValue) await storage.session.remove(key).catch(() => {});
    const localValue = (await storage.local.get(key))[key];
    record = normalizePdfSourceRecord(localValue, sourceId, { now });
    if (!record) {
      if (localValue) await storage.local.remove(key).catch(() => {});
      return null;
    }
  }

  const touched = { ...record, accessedAt: now };
  await storage.session.set({ [key]: touched }).catch(() => {});
  if (pdfSourceRecordIsRestorable(touched)) await storage.local.set({ [key]: touched }).catch(() => {});
  return touched;
}

export function pdfSourceStorageKeysToPrune(values, {
  now = Date.now(),
  protectedSourceIds = [],
  maxRecords = PDF_SOURCE_MAX_RECORDS
} = {}) {
  const protectedIds = new Set(protectedSourceIds);
  const retained = [];
  const remove = [];
  for (const [key, value] of Object.entries(values || {})) {
    if (!key.startsWith(PDF_SOURCE_PREFIX)) continue;
    const sourceId = key.slice(PDF_SOURCE_PREFIX.length);
    const record = normalizePdfSourceRecord(value, sourceId, { now });
    if (!record) {
      if (!protectedIds.has(sourceId)) remove.push(key);
      continue;
    }
    if (protectedIds.has(sourceId)) continue;
    retained.push({ key, accessedAt: record.accessedAt });
  }
  retained.sort((left, right) => right.accessedAt - left.accessedAt);
  for (const entry of retained.slice(Math.max(0, maxRecords))) remove.push(entry.key);
  return remove;
}

export async function prunePdfSourceRecords(storage, protectedSourceIds = []) {
  const values = await storage.local.get(null);
  const keys = pdfSourceStorageKeysToPrune(values, { protectedSourceIds });
  if (keys.length) await storage.local.remove(keys);
  return keys.length;
}
