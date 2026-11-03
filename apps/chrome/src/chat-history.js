import { normalizeFileAttachments } from '../../../packages/core/src/file-attachments.js';
import { retainBrowserFileCorpora, restoreBrowserFileCorpora } from './file-corpus.js';
import { MAX_ENTIRE_PDF_CHARS } from '../../../packages/core/src/entire-pdf.js';
import { FULL_CONTEXT_CHARS } from './context-mode.js';
import { researchUrl } from './research-links.js';
export const CHAT_HISTORY_KEY = 'scholia.chat-history.v1';

export const MAX_SAVED_CHATS = 24;
const MAX_HISTORY_BYTES = 5_500_000;
const MAX_CHAT_BYTES = 1_350_000;
const MAX_MESSAGES = 40;
const MAX_MESSAGE_CHARS = 24_000;
const MAX_CONTEXT_CHARS = FULL_CONTEXT_CHARS;
const MAX_SELECTION_CHARS = 12_000;
const MAX_IMAGE_DATA_URL_CHARS = 900_000;

function text(value, maximum = 1_000) {
  return String(value || '').trim().slice(0, maximum);
}

function finiteTime(value, fallback) {
  const timestamp = Number(value);
  return Number.isFinite(timestamp) && timestamp > 0 ? timestamp : fallback;
}

function byteSize(value) {
  return new TextEncoder().encode(JSON.stringify(value)).length;
}

function normalizedAttachment(raw) {
  if (!raw || typeof raw !== 'object') return null;
  const selected = text(raw.text, MAX_SELECTION_CHARS);
  if (!selected) return null;
  return {
    origin: ['page', 'response'].includes(raw.origin) ? raw.origin : 'page',
    text: selected,
    embedded: Boolean(raw.embedded),
    label: text(raw.label, 160),
    ...(Number.isInteger(raw.messageIndex) ? { messageIndex: raw.messageIndex } : {})
  };
}

function normalizedMessageImage(raw) {
  const original = String(raw?.imageDataUrl || '');
  const isImage = /^data:image\/[a-z0-9.+-]+;base64,/i.test(original);
  const retained = isImage && original.length <= MAX_IMAGE_DATA_URL_CHARS;
  return {
    imageDataUrl: retained ? original : '',
    imageUnavailable: Boolean(raw?.imageUnavailable) || (isImage && !retained)
  };
}

function normalizedMessages(raw) {
  if (!Array.isArray(raw)) return [];
  return raw
    .filter((entry) => entry && ['user', 'assistant'].includes(entry.role))
    .slice(-MAX_MESSAGES)
    .map((entry) => {
      const attachment = entry.role === 'user' ? normalizedAttachment(entry.attachment) : null;
      const image = entry.role === 'user' ? normalizedMessageImage(entry) : {};
      return {
        role: entry.role,
        content: text(entry.content, MAX_MESSAGE_CHARS),
        ...(entry.role === 'assistant' && entry.reasoning
          ? { reasoning: text(entry.reasoning, MAX_MESSAGE_CHARS) }
          : {}),
        ...(entry.meta ? { meta: text(entry.meta, 300) } : {}),
        ...(entry.role === 'assistant' && Array.isArray(entry.activity) ? {
          activity: entry.activity.slice(-80).filter((event) => event?.title).map((event) => ({
            title: text(event.title, 180), detail: text(event.detail, 2000),
            timestamp: Number.isFinite(event.timestamp) ? event.timestamp : 0
          }))
        } : {}),
        ...(entry.error ? { error: true } : {}),
        ...(attachment ? { attachment } : {}),
        ...(entry.role === 'user' && entry.files?.length ? { files: normalizeFileAttachments(entry.files) } : {}),
        ...(image.imageDataUrl ? { imageDataUrl: image.imageDataUrl } : {}),
        ...(image.imageUnavailable ? { imageUnavailable: true } : {})
      };
    })
    .filter((entry) => entry.content || entry.attachment || entry.imageDataUrl || entry.imageUnavailable);
}

function normalizedCapture(raw) {
  const source = raw && typeof raw === 'object' ? raw : {};
  const originalImage = String(source.imageDataUrl || '');
  const imageRetained = originalImage.startsWith('data:image/')
    && originalImage.length <= MAX_IMAGE_DATA_URL_CHARS;
  const imageUnavailable = Boolean(source.imageUnavailable)
    || (originalImage.startsWith('data:image/') && !imageRetained);
  return {
    kind: ['text', 'latex', 'image', 'mail'].includes(source.kind) ? source.kind : 'text',
    selection: text(source.selection, MAX_SELECTION_CHARS),
    context: String(source.context || '').slice(0, source.entirePDF ? MAX_ENTIRE_PDF_CHARS : MAX_CONTEXT_CHARS),
    ...(source.entirePDF === true && String(source.context || '').length <= MAX_ENTIRE_PDF_CHARS ? { entirePDF: true } : {}),
    followLinks: source.followLinks === true,
    researchYolo: source.researchYolo === true,
    researchUrl: researchUrl(source.researchUrl || source.url),
    ...(Array.isArray(source.researchSources) ? { researchSources: source.researchSources.slice(0, 300)
      .map((item) => ({ title: text(item?.title, 300), url: researchUrl(item?.url) })).filter((item) => item.url) } : {}),
    ...(source.parentContext ? { parentContext: text(source.parentContext, 12_000) } : {}),
    ...(typeof source.webSearch === 'boolean' ? { webSearch: source.webSearch } : {}),
    ...(typeof source.contextEnabled === 'boolean'
      ? { contextEnabled: source.contextEnabled }
      : {}),
    ...(typeof source.compactContextEnabled === 'boolean'
      ? { compactContextEnabled: source.compactContextEnabled }
      : {}),
    pageTitle: text(source.pageTitle, 500),
    pageLanguage: text(source.pageLanguage, 40),
    url: text(source.url, 2_048),
    imageDataUrl: imageRetained ? originalImage : '',
    imageUnavailable,
    sourceKind: text(source.sourceKind, 80) || 'page',
    ...(source.canvasCourse ? { canvasCourse: { courseId: text(source.canvasCourse.courseId, 40), origin: text(source.canvasCourse.origin, 500) } } : {}),
    contextNotice: text(source.contextNotice, 1_000),
    contextState: text(source.contextState, 240),
    useChatGptWebContext: source.useChatGptWebContext === true
  };
}

function fallbackTitle(messages, capture) {
  const firstQuestion = messages.find((entry) => entry.role === 'user')?.content || '';
  return text(firstQuestion || capture.pageTitle || 'Untitled chat', 90);
}

function fitChatRecord(record) {
  if (byteSize(record) <= MAX_CHAT_BYTES) return record;
  if (record.capture.imageDataUrl) {
    record.capture.imageDataUrl = '';
    record.capture.imageUnavailable = true;
  }
  for (const message of record.messages) {
    if (byteSize(record) <= MAX_CHAT_BYTES) break;
    if (!message.imageDataUrl) continue;
    delete message.imageDataUrl;
    message.imageUnavailable = true;
  }
  while (record.messages.length > 2 && byteSize(record) > MAX_CHAT_BYTES) {
    const firstUser = record.messages.findIndex((entry) => entry.role === 'user');
    if (firstUser < 0) break;
    const nextUser = record.messages.findIndex((entry, index) => index > firstUser && entry.role === 'user');
    if (nextUser < 0) break;
    record.messages.splice(0, nextUser);
    record.trimmed = true;
  }
  return record;
}

export function normalizeChatRecord(raw, now = Date.now()) {
  if (!raw || typeof raw !== 'object') return null;
  const id = text(raw.id, 120);
  if (!id) return null;
  const capture = normalizedCapture(raw.capture);
  const messages = normalizedMessages(raw.messages);
  if (!messages.some((entry) => entry.role === 'user')) return null;
  const createdAt = finiteTime(raw.createdAt, now);
  const updatedAt = Math.max(createdAt, finiteTime(raw.updatedAt, createdAt));
  return fitChatRecord({
    id,
    title: text(raw.title, 90) || fallbackTitle(messages, capture),
    sourceTitle: text(raw.sourceTitle || capture.pageTitle, 500),
    sourceUrl: text(raw.sourceUrl || capture.url, 2_048),
    sourceKind: text(raw.sourceKind || capture.sourceKind, 80) || 'page',
    provider: text(raw.provider, 80),
    model: text(raw.model, 200),
    createdAt,
    updatedAt,
    revision: Math.max(0, Math.floor(Number(raw.revision) || 0)),
    capture,
    messages,
    ...(raw.draft ? { draft: String(raw.draft).slice(0, MAX_MESSAGE_CHARS) } : {}),
    ...(raw.trimmed ? { trimmed: true } : {})
  });
}

export function pruneChatHistory(raw, now = Date.now()) {
  const unique = new Map();
  for (const candidate of Array.isArray(raw) ? raw : []) {
    const chat = normalizeChatRecord(candidate, now);
    if (!chat) continue;
    const existing = unique.get(chat.id);
    if (!existing || existing.updatedAt < chat.updatedAt) unique.set(chat.id, chat);
  }
  const chats = [...unique.values()]
    .sort((left, right) => right.updatedAt - left.updatedAt)
    .slice(0, MAX_SAVED_CHATS);
  while (chats.length > 1 && byteSize(chats) > MAX_HISTORY_BYTES) chats.pop();
  return chats;
}

function localStorageArea(storageArea) {
  const area = storageArea || globalThis.chrome?.storage?.local;
  if (!area) throw new Error('Chrome local storage is unavailable.');
  return area;
}

export async function listChats(storageArea) {
  const area = localStorageArea(storageArea);
  const stored = await area.get(CHAT_HISTORY_KEY);
  return pruneChatHistory(stored[CHAT_HISTORY_KEY]);
}

export async function getChat(chatId, storageArea) {
  const id = text(chatId, 120);
  const chat = (await listChats(storageArea)).find((chat) => chat.id === id) || null;
  if (!chat) return null;
  return { ...chat, messages: await Promise.all(chat.messages.map(async (message) => ({ ...message,
    ...(message.files?.length ? { files: await restoreBrowserFileCorpora(message.files) } : {}) }))) };
}

// All extension surfaces send mutations to the service worker. Its queue covers
// save/delete/clear together; one storage.set commits records and tombstones.
const mutationQueues = new WeakMap();
const HISTORY_META_KEY = 'scholia.chat-history-meta.v1';
let isMutationOwner = false;
export function ownChatHistoryMutations() { isMutationOwner = true; }
export async function mutateChatHistory(operation, value, storageArea) {
  if (!storageArea && !isMutationOwner && globalThis.chrome?.runtime?.sendMessage) {
    const response = await chrome.runtime.sendMessage({ type: 'SCHOLIA_MUTATE_CHAT_HISTORY', operation, value });
    if (!response?.ok) throw new Error(response?.error || 'Could not save chat history.');
    return response.value;
  }
  const area = localStorageArea(storageArea);
  const job = (mutationQueues.get(area) || Promise.resolve()).catch(() => {}).then(async () => {
    const chats = await listChats(area);
    const meta = (await area.get(HISTORY_META_KEY))[HISTORY_META_KEY] || { deleted: {}, clearedAt: 0 };
    if (operation === 'save') {
      const compact = { ...value, messages: await Promise.all((value?.messages || []).map(async (message) => ({ ...message,
        ...(message.files?.length ? { files: await retainBrowserFileCorpora(message.files) } : {}) }))) };
      const chat = normalizeChatRecord(compact); if (!chat) return null;
      if (meta.deleted[chat.id] || chat.createdAt <= meta.clearedAt) throw new Error('This chat was removed. Start a new chat to save again.');
      const previous = chats.find((item) => item.id === chat.id);
      if (previous) {
        const content = ({ createdAt, updatedAt, revision, ...rest }) => JSON.stringify(rest);
        if (content(previous) === content(chat)) return previous; // retry after navigation/response loss
      }
      if (previous && (chat.updatedAt < previous.updatedAt || chat.revision !== previous.revision)) throw new Error('This chat changed in another window. Reopen it before saving.');
      chat.revision = (previous?.revision || 0) + 1;
      const next = pruneChatHistory([chat, ...chats.filter((item) => item.id !== chat.id)]);
      await area.set({ [CHAT_HISTORY_KEY]: next, [HISTORY_META_KEY]: meta });
      return next.find((item) => item.id === chat.id) || null;
    }
    if (operation === 'delete') {
      const id = text(value, 120); meta.deleted[id] = Date.now();
      const next = chats.filter((chat) => chat.id !== id);
      await area.set({ [CHAT_HISTORY_KEY]: next, [HISTORY_META_KEY]: meta }); return next;
    }
    if (operation === 'clear') {
      // Clear's epoch also rejects old unsaved windows without retaining all IDs.
      await area.set({ [CHAT_HISTORY_KEY]: [], [HISTORY_META_KEY]: { deleted: {}, clearedAt: Date.now() } });
      await area.remove(CHAT_HISTORY_KEY); return;
    }
    throw new Error('Unknown chat history operation.');
  });
  mutationQueues.set(area, job); return job;
}
export function saveChat(raw, storageArea) { return mutateChatHistory('save', raw, storageArea); }
export function deleteChat(chatId, storageArea) { return mutateChatHistory('delete', chatId, storageArea); }
export function clearChats(storageArea) { return mutateChatHistory('clear', null, storageArea); }
