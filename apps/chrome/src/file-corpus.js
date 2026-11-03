import { FILE_PREVIEW_CHARACTERS, normalizeFileAttachments } from '../../../packages/core/src/file-attachments.js';

let database;
function openDatabase() {
  if (!database) database = new Promise((resolve, reject) => {
    const request = indexedDB.open('scholia-attachment-text-v1', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('texts');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  }).catch((error) => { database = null; throw error; });
  return database;
}
async function transaction(mode, operation) {
  const db = await openDatabase();
  return new Promise((resolve, reject) => {
    const tx = db.transaction('texts', mode);
    const request = operation(tx.objectStore('texts'));
    tx.oncomplete = () => resolve(request?.result);
    tx.onerror = () => reject(tx.error);
    tx.onabort = () => reject(tx.error || new Error('Attachment text storage was interrupted.'));
  });
}
export const browserFileCorpus = {
  put: (id, text) => transaction('readwrite', (store) => store.put(text, id)),
  get: (id) => transaction('readonly', (store) => store.get(id)),
};
async function corpusID(text) {
  const data = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(data)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

export async function retainBrowserFileCorpora(raw, store = browserFileCorpus) {
  const files = [];
  for (const file of normalizeFileAttachments(raw)) {
    if (file.textCorpusID && file.text.length < file.textCorpusUTF16Count) {
      files.push(file);
    } else if (file.text.length > FILE_PREVIEW_CHARACTERS) {
      const id = await corpusID(file.text);
      await store.put(id, file.text);
      files.push({ ...file, text: file.text.slice(0, FILE_PREVIEW_CHARACTERS), textCorpusID: id, textCorpusUTF16Count: file.text.length });
    } else files.push(file);
  }
  return files;
}

export async function restoreBrowserFileCorpora(raw, store = browserFileCorpus) {
  return Promise.all(normalizeFileAttachments(raw).map(async (file) => {
    if (!file.textCorpusID || file.text.length >= file.textCorpusUTF16Count) return file;
    try {
      const text = await store.get(file.textCorpusID);
      if (typeof text !== 'string' || text.length !== file.textCorpusUTF16Count || await corpusID(text) !== file.textCorpusID)
        throw new Error('Saved attachment text is unavailable');
      return { ...file, text };
    } catch {
      return { ...file, status: 'partial', truncated: true,
        notice: `${file.notice} Complete saved text is unavailable in browser storage. Only the preview can be searched; attach the original again.` };
    }
  }));
}
