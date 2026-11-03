export const PDF_INDEX_CACHE_VERSION = 3;
export const MAX_CACHED_PDF_INDEX_CHARACTERS = 20_000_000;
export const MAX_TOTAL_CACHED_PDF_INDEX_CHARACTERS = 60_000_000;
export const MAX_CACHED_PDF_INDEXES = 12;

const DATABASE_NAME = 'scholia-pdf-indexes';
const DATABASE_VERSION = 1;
const INDEX_STORE = 'indexes';

function finiteInteger(value) {
  const number = Number(value);
  return Number.isInteger(number) && number >= 0 ? number : -1;
}

function stringArray(value) {
  return Array.isArray(value) && value.every((entry) => typeof entry === 'string');
}

function indexCharacterCount(searchTexts, contextPages) {
  let total = 0;
  for (const value of searchTexts) total += value.length;
  for (const value of contextPages) total += value.length;
  return total;
}

/**
 * PDF.js fingerprints identify the document bytes without retaining a source
 * URL or local filename in extension storage. The cache schema stays in the
 * key so extraction changes can invalidate old indexes atomically.
 */
export function pdfIndexCacheKey(documentProxy) {
  const pageCount = finiteInteger(documentProxy?.numPages);
  const fingerprint = (Array.isArray(documentProxy?.fingerprints) ? documentProxy.fingerprints : [])
    .map((value) => String(value || '').trim())
    .find(Boolean);
  if (!fingerprint || pageCount <= 0 || fingerprint.length > 512) return '';
  return `v${PDF_INDEX_CACHE_VERSION}:${pageCount}:${fingerprint}`;
}

export function createPdfIndexCacheRecord({
  key,
  pageCount,
  indexedPageCount,
  searchTexts,
  contextPages,
  title = '',
  ocrPageCount = 0,
  ocrNotice = '',
  now = Date.now()
} = {}) {
  const totalPages = finiteInteger(pageCount);
  const indexedPages = finiteInteger(indexedPageCount);
  if (!key || totalPages <= 0 || indexedPages <= 0 || indexedPages > totalPages) return null;
  if (!stringArray(searchTexts) || searchTexts.length !== indexedPages) return null;
  if (!stringArray(contextPages) || contextPages.length > indexedPages) return null;
  const characterCount = indexCharacterCount(searchTexts, contextPages);
  if (characterCount > MAX_CACHED_PDF_INDEX_CHARACTERS) return null;
  const timestamp = Number.isFinite(Number(now)) ? Number(now) : Date.now();
  return {
    key: String(key),
    version: PDF_INDEX_CACHE_VERSION,
    pageCount: totalPages,
    indexedPageCount: indexedPages,
    searchTexts,
    contextPages,
    title: String(title || '').slice(0, 500),
    ocrPageCount: Math.min(indexedPages, Math.max(0, Number(ocrPageCount) || 0)),
    ocrNotice: String(ocrNotice || '').slice(0, 1_000),
    characterCount,
    updatedAt: timestamp
  };
}

export function normalizePdfIndexCacheRecord(record, {
  key,
  pageCount,
  indexedPageCount
} = {}) {
  if (!record || record.version !== PDF_INDEX_CACHE_VERSION || record.key !== key) return null;
  if (record.pageCount !== finiteInteger(pageCount)) return null;
  if (record.indexedPageCount !== finiteInteger(indexedPageCount)) return null;
  return createPdfIndexCacheRecord({ ...record, key, pageCount, indexedPageCount, now: record.updatedAt });
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

function openIndexDatabase(indexedDb = globalThis.indexedDB) {
  if (!indexedDb?.open) return Promise.resolve(null);
  return new Promise((resolve, reject) => {
    const request = indexedDb.open(DATABASE_NAME, DATABASE_VERSION);
    request.addEventListener('upgradeneeded', () => {
      if (!request.result.objectStoreNames.contains(INDEX_STORE)) {
        request.result.createObjectStore(INDEX_STORE, { keyPath: 'key' });
      }
    });
    request.addEventListener('success', () => resolve(request.result), { once: true });
    request.addEventListener('error', () => reject(request.error || new Error('Could not open the PDF index cache.')), { once: true });
  });
}

async function evictOldPdfIndexes(database) {
  const readTransaction = database.transaction(INDEX_STORE, 'readonly');
  const readDone = transactionResult(readTransaction);
  const records = await requestResult(readTransaction.objectStore(INDEX_STORE).getAll());
  await readDone;
  records.sort((left, right) => Number(right.updatedAt || 0) - Number(left.updatedAt || 0));

  let retainedCharacters = 0;
  const removals = [];
  for (const [index, record] of records.entries()) {
    const characters = Math.max(0, Number(record.characterCount) || 0);
    if (index >= MAX_CACHED_PDF_INDEXES
        || retainedCharacters + characters > MAX_TOTAL_CACHED_PDF_INDEX_CHARACTERS) {
      removals.push(record.key);
    } else {
      retainedCharacters += characters;
    }
  }
  if (!removals.length) return;

  const writeTransaction = database.transaction(INDEX_STORE, 'readwrite');
  const writeDone = transactionResult(writeTransaction);
  const store = writeTransaction.objectStore(INDEX_STORE);
  for (const key of removals) store.delete(key);
  await writeDone;
}

export async function readPdfIndexCache(cacheKey, {
  pageCount,
  indexedPageCount,
  indexedDb = globalThis.indexedDB
} = {}) {
  if (!cacheKey) return null;
  let database;
  try {
    database = await openIndexDatabase(indexedDb);
    if (!database) return null;
    const transaction = database.transaction(INDEX_STORE, 'readonly');
    const done = transactionResult(transaction);
    const record = await requestResult(transaction.objectStore(INDEX_STORE).get(cacheKey));
    await done;
    return normalizePdfIndexCacheRecord(record, { key: cacheKey, pageCount, indexedPageCount });
  } catch {
    return null;
  } finally {
    database?.close();
  }
}

export async function writePdfIndexCache(value, { indexedDb = globalThis.indexedDB } = {}) {
  const record = createPdfIndexCacheRecord(value);
  if (!record) return false;
  let database;
  try {
    database = await openIndexDatabase(indexedDb);
    if (!database) return false;
    const transaction = database.transaction(INDEX_STORE, 'readwrite');
    const done = transactionResult(transaction);
    transaction.objectStore(INDEX_STORE).put(record);
    await done;
    await evictOldPdfIndexes(database);
    return true;
  } catch {
    return false;
  } finally {
    database?.close();
  }
}
