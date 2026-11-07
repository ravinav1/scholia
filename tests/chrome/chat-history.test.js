import test from 'node:test';
import assert from 'node:assert/strict';
import {
  CHAT_HISTORY_KEY,
  MAX_SAVED_CHATS,
  clearChats,
  deleteChat,
  getChat,
  listChats,
  normalizeChatRecord,
  pruneChatHistory,
  saveChat
} from '../../apps/chrome/src/chat/chat-history.js';

function chat(id, updatedAt = 1, overrides = {}) {
  return {
    id,
    createdAt: 1,
    updatedAt,
    capture: { pageTitle: `Source ${id}`, url: `https://example.com/${id}`, context: 'Grounding' },
    messages: [
      { role: 'user', content: `Question ${id}` },
      { role: 'assistant', content: `Answer ${id}`, streaming: true }
    ],
    ...overrides
  };
}

function memoryStorage(initial = {}) {
  const values = { ...initial };
  return {
    values,
    async get(key) { return { [key]: values[key] }; },
    async set(next) { Object.assign(values, next); },
    async remove(key) { delete values[key]; }
  };
}

test('chat history sanitizes restorable transcript and source context', () => {
  const record = normalizeChatRecord(chat('alpha', 20, {
    capture: {
      kind: 'image',
      pageTitle: 'Diagram',
      url: 'https://example.com/diagram',
      context: 'Useful context',
      contextEnabled: false,
      compactContextEnabled: false,
      useChatGptWebContext: true,
      imageDataUrl: `data:image/png;base64,${'a'.repeat(900_001)}`,
      pdfUrl: 'https://example.com/private.pdf?token=secret',
      tabId: 42
    },
    messages: [
      { role: 'system', content: 'not allowed' },
      {
        role: 'user',
        content: '  Explain this  ',
        attachment: { origin: 'page', text: ' selected ' },
        imageDataUrl: 'data:image/png;base64,aGVsbG8='
      },
      { role: 'assistant', content: '  Done  ', reasoning: '  Checked the source  ', streaming: true }
    ]
  }), 50);

  assert.equal(record.title, 'Explain this');
  assert.equal(record.capture.imageDataUrl, '');
  assert.equal(record.capture.imageUnavailable, true);
  assert.equal(record.capture.useChatGptWebContext, true);
  assert.equal(record.capture.contextEnabled, false);
  assert.equal(record.capture.compactContextEnabled, false);
  assert.equal('pdfUrl' in record.capture, false);
  assert.equal('tabId' in record.capture, false);
  assert.deepEqual(record.messages.map(({ role, content }) => ({ role, content })), [
    { role: 'user', content: 'Explain this' },
    { role: 'assistant', content: 'Done' }
  ]);
  assert.equal('streaming' in record.messages[1], false);
  assert.equal(record.messages[1].reasoning, 'Checked the source');
  assert.equal(record.messages[0].imageDataUrl, 'data:image/png;base64,aGVsbG8=');
});

test('oversized turn images are marked unavailable without dropping the transcript', () => {
  const record = normalizeChatRecord(chat('turn-image', 30, {
    messages: [
      { role: 'user', content: 'Inspect this region', imageDataUrl: `data:image/png;base64,${'a'.repeat(900_001)}` },
      { role: 'assistant', content: 'It contains a chart.' }
    ]
  }));
  assert.equal(record.messages[0].content, 'Inspect this region');
  assert.equal(record.messages[0].imageDataUrl, undefined);
  assert.equal(record.messages[0].imageUnavailable, true);
});

test('chat history deduplicates, sorts, and caps records', () => {
  const records = Array.from({ length: MAX_SAVED_CHATS + 5 }, (_, index) => chat(`chat-${index}`, index + 1));
  records.push(chat('chat-8', 1_000));
  const pruned = pruneChatHistory(records);
  assert.equal(pruned.length, MAX_SAVED_CHATS);
  assert.equal(pruned[0].id, 'chat-8');
  assert.equal(new Set(pruned.map(({ id }) => id)).size, pruned.length);
});

test('chat history storage can save, read, delete, and clear chats', async () => {
  const storage = memoryStorage();
  await saveChat(chat('first', 10), storage);
  await saveChat(chat('second', 20), storage);
  assert.deepEqual((await listChats(storage)).map(({ id }) => id), ['second', 'first']);
  assert.equal((await getChat('first', storage)).title, 'Question first');

  await deleteChat('second', storage);
  assert.deepEqual((await listChats(storage)).map(({ id }) => id), ['first']);

  await clearChats(storage);
  assert.equal(CHAT_HISTORY_KEY in storage.values, false);
  assert.deepEqual(await listChats(storage), []);
});

test('concurrent history writers retain both chats and reject stale revisions', async () => {
  const storage = memoryStorage();
  await Promise.all([saveChat(chat('left', 10), storage), saveChat(chat('right', 20), storage)]);
  assert.equal((await listChats(storage)).length, 2);
  const original = await getChat('left', storage);
  const newer = await saveChat({ ...original, updatedAt: 30, messages: [{ role: 'user', content: 'New branch' }] }, storage);
  assert.equal(newer.revision, original.revision + 1);
  await assert.rejects(saveChat({ ...original, updatedAt: 40 }, storage), /another window/);
  await assert.rejects(saveChat({ ...newer, updatedAt: 5, messages: [{ role: 'user', content: 'An older branch' }] }, storage), /another window/);
  assert.equal((await getChat('left', storage)).messages[0].content, 'New branch');
});

test('delete and clear cannot be undone by delayed saves', async () => {
  const storage = memoryStorage();
  const saved = await saveChat(chat('deleted', 20), storage);
  await Promise.all([saveChat({ ...saved, updatedAt: 30 }, storage), deleteChat('deleted', storage)]);
  await assert.rejects(saveChat({ ...saved, updatedAt: 100 }, storage), /removed/);
  assert.equal(await getChat('deleted', storage), null);
  const other = await saveChat(chat('cleared', 200), storage);
  await clearChats(storage);
  await assert.rejects(saveChat(other, storage), /removed/);
});
