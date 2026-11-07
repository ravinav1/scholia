import { pdfSourceStorageKey } from '../tab-context.js';

const DATABASE_NAME = 'scholia-pdf-files';
const DATABASE_VERSION = 1;
const FILE_STORE = 'files';

export const LOCAL_PDF_FILE_MAX_AGE = 180 * 24 * 60 * 60_000;
export const LOCAL_PDF_FILE_MAX_RECORDS = 32;

function validSourceId(value) {
  const id = String(value || '');
  return pdfSourceStorageKey(id) ? id : '';
}

function fileHandle(value) {
  return value?.kind === 'file' && typeof value.getFile === 'function' ? value : null;
}

export function normalizeLocalPdfFileRecord(value, sourceId, {
  now = Date.now(),
  maxAge = LOCAL_PDF_FILE_MAX_AGE
} = {}) {
  const id = validSourceId(sourceId);
  const handle = fileHandle(value?.handle);
  const createdAt = Number(value?.createdAt || 0);
  const accessedAt = Number(value?.accessedAt || createdAt);
  if (!id || value?.id !== id || !handle || !Number.isFinite(createdAt) || createdAt <= 0) return null;
  if (!Number.isFinite(accessedAt) || accessedAt <= 0 || now - accessedAt > maxAge || accessedAt > now + 60_000) return null;
  const name = String(value.name || handle.name || 'PDF document').trim().slice(0, 500) || 'PDF document';
  return {
    id,
    handle,
    name,
    createdAt,
    accessedAt,
    size: Math.max(0, Number(value.size) || 0),
    lastModified: Math.max(0, Number(value.lastModified) || 0)
  };
}

export function localPdfFileSource(value) {
  const id = validSourceId(value?.id);
  if (!id) return null;
  return {
    id,
    createdAt: Number(value.createdAt) || Date.now(),
    accessedAt: Number(value.accessedAt) || Date.now(),
    pdfUrl: '',
    fileHandleId: id,
    url: 'file://',
    pageTitle: String(value.name || 'PDF document').trim().slice(0, 500) || 'PDF document'
  };
}

function requestResult(request) {
  return new Promise((resolve, reject) => {
    request.addEventListener('success', () => resolve(request.result), { once: true });
    request.addEventListener('error', () => reject(request.error || new Error('IndexedDB request failed.')), { once: true });
  });
}

function transactionResult(transaction) {
  return new Promise((resolve, reject) => {
    transaction.addEventListener('complete', () => resolve(), { once: true });
    transaction.addEventListener('abort', () => reject(transaction.error || new Error('IndexedDB transaction was aborted.')), { once: true });
    transaction.addEventListener('error', () => reject(transaction.error || new Error('IndexedDB transaction failed.')), { once: true });
  });
}

function openFileDatabase(indexedDb = globalThis.indexedDB) {
  if (!indexedDb?.open) return Promise.resolve(null);
  return new Promise((resolve, reject) => {
    const request = indexedDb.open(DATABASE_NAME, DATABASE_VERSION);
    request.addEventListener('upgradeneeded', () => {
      if (!request.result.objectStoreNames.contains(FILE_STORE)) {
        request.result.createObjectStore(FILE_STORE, { keyPath: 'id' });
      }
    });
    request.addEventListener('success', () => resolve(request.result), { once: true });
    request.addEventListener('error', () => reject(request.error || new Error('Could not open the local PDF file store.')), { once: true });
  });
}

async function pruneLocalPdfFileRecords(database, now) {
  const readTransaction = database.transaction(FILE_STORE, 'readonly');
  const readDone = transactionResult(readTransaction);
  const records = await requestResult(readTransaction.objectStore(FILE_STORE).getAll());
  await readDone;

  const remove = [];
  const retained = [];
  for (const value of records) {
    const record = normalizeLocalPdfFileRecord(value, value?.id, { now });
    if (record) retained.push(record);
    else if (value?.id) remove.push(value.id);
  }
  retained.sort((left, right) => right.accessedAt - left.accessedAt);
  remove.push(...retained.slice(LOCAL_PDF_FILE_MAX_RECORDS).map((record) => record.id));
  if (!remove.length) return 0;

  const writeTransaction = database.transaction(FILE_STORE, 'readwrite');
  const writeDone = transactionResult(writeTransaction);
  const store = writeTransaction.objectStore(FILE_STORE);
  for (const id of remove) store.delete(id);
  await writeDone;
  return remove.length;
}

export async function pruneLocalPdfFileHandles({
  now = Date.now(),
  indexedDb = globalThis.indexedDB
} = {}) {
  let database;
  try {
    database = await openFileDatabase(indexedDb);
    if (!database) return 0;
    return await pruneLocalPdfFileRecords(database, now);
  } catch {
    return 0;
  } finally {
    database?.close();
  }
}

export async function storeLocalPdfFileHandle(handle, {
  id = globalThis.crypto?.randomUUID?.(),
  file = null,
  now = Date.now(),
  indexedDb = globalThis.indexedDB
} = {}) {
  const sourceId = validSourceId(id);
  const selectedHandle = fileHandle(handle);
  if (!sourceId || !selectedHandle) throw new Error('Chromium did not return a reusable PDF file handle.');
  const selectedFile = file || await selectedHandle.getFile();
  const record = normalizeLocalPdfFileRecord({
    id: sourceId,
    handle: selectedHandle,
    name: selectedFile?.name || selectedHandle.name,
    size: selectedFile?.size,
    lastModified: selectedFile?.lastModified,
    createdAt: now,
    accessedAt: now
  }, sourceId, { now });
  if (!record) throw new Error('Scholia could not remember the selected PDF file.');

  let database;
  try {
    database = await openFileDatabase(indexedDb);
    if (!database) throw new Error('IndexedDB is unavailable.');
    const transaction = database.transaction(FILE_STORE, 'readwrite');
    const done = transactionResult(transaction);
    transaction.objectStore(FILE_STORE).put(record);
    await done;
    await pruneLocalPdfFileRecords(database, now);
    return record;
  } catch (error) {
    throw new Error(`Scholia could not remember the selected PDF file: ${error?.message || error}`);
  } finally {
    database?.close();
  }
}

export async function loadLocalPdfFileRecord(sourceId, {
  now = Date.now(),
  indexedDb = globalThis.indexedDB
} = {}) {
  const id = validSourceId(sourceId);
  if (!id) return null;
  let database;
  try {
    database = await openFileDatabase(indexedDb);
    if (!database) return null;
    const readTransaction = database.transaction(FILE_STORE, 'readonly');
    const readDone = transactionResult(readTransaction);
    const value = await requestResult(readTransaction.objectStore(FILE_STORE).get(id));
    await readDone;
    const record = normalizeLocalPdfFileRecord(value, id, { now });
    if (!record) {
      if (value) {
        const removeTransaction = database.transaction(FILE_STORE, 'readwrite');
        const removeDone = transactionResult(removeTransaction);
        removeTransaction.objectStore(FILE_STORE).delete(id);
        await removeDone;
      }
      return null;
    }

    const touched = { ...record, accessedAt: now };
    const writeTransaction = database.transaction(FILE_STORE, 'readwrite');
    const writeDone = transactionResult(writeTransaction);
    writeTransaction.objectStore(FILE_STORE).put(touched);
    await writeDone;
    return touched;
  } catch {
    return null;
  } finally {
    database?.close();
  }
}
