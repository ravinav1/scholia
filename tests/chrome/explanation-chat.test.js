import test from 'node:test';
import assert from 'node:assert/strict';
import { openExplanationChat } from '../../apps/chrome/src/chat/explanation-chat.js';
import { CHAT_HISTORY_KEY } from '../../apps/chrome/src/chat/chat-history.js';

function fixture() {
  const stored = {};
  const tabs = [];
  const browser = {
    storage: { local: {
      async get(key) { return { [key]: stored[key] }; },
      async set(values) { Object.assign(stored, values); }
    } },
    runtime: { getURL: (path) => `chrome-extension://scholia/${path}` },
    tabs: { async create(tab) {
      assert.equal(stored[CHAT_HISTORY_KEY].length, 1, 'chat must be saved before opening');
      tabs.push(tab);
    } }
  };
  const explanation = {
    id: 'explanation-chat-1',
    provider: 'openai', model: 'test-model',
    capture: {
      kind: 'latex', selection: '$x$', context: 'Page context',
      parentContext: 'The preceding explanation defines x.',
      pageTitle: 'Source notes', url: 'https://example.com/notes',
      contextEnabled: true, compactContextEnabled: false, webSearch: true,
      imageDataUrl: 'data:image/png;base64,YQ=='
    },
    messages: [
      { role: 'user', content: 'Explain x' },
      { role: 'assistant', content: 'It is a variable.', reasoning: 'Read the definition.' },
      { role: 'user', content: 'Which variable?' },
      { role: 'assistant', content: 'The horizontal coordinate.' }
    ],
    draft: '  Show an example\nusing x'
  };
  return { stored, tabs, browser, explanation };
}

test('moving an explanation retains transcript, grounding, image, and draft before opening chat', async () => {
  const { stored, tabs, browser, explanation } = fixture();
  const result = await openExplanationChat(explanation, browser);
  const saved = stored[CHAT_HISTORY_KEY][0];
  assert.equal(result.chatId, explanation.id);
  assert.deepEqual(saved.messages, explanation.messages);
  for (const [key, value] of Object.entries(explanation.capture)) assert.equal(saved.capture[key], value);
  assert.equal(saved.draft, explanation.draft);
  assert.equal(saved.model, explanation.model);
  assert.deepEqual(tabs, [{ url: `chrome-extension://scholia/chat.html?chat=${explanation.id}` }]);
});

test('failed saves do not open an empty chat', async () => {
  const { tabs, browser, explanation } = fixture();
  browser.storage.local.set = async () => { throw new Error('Storage full'); };
  await assert.rejects(openExplanationChat(explanation, browser), /Storage full/);
  assert.equal(tabs.length, 0);
});

test('moving a PDF explanation saves its full conversation for the local sidebar without opening a tab', async () => {
  const { stored, tabs, browser, explanation } = fixture();
  const result = await openExplanationChat(explanation, browser, { destination: 'pdf-sidebar' });
  assert.deepEqual(result, { chatId: explanation.id, surface: 'pdf-sidebar' });
  const saved = stored[CHAT_HISTORY_KEY][0];
  assert.deepEqual(saved.messages, explanation.messages);
  for (const [key, value] of Object.entries(explanation.capture)) assert.equal(saved.capture[key], value);
  assert.equal(saved.draft, explanation.draft);
  assert.equal(tabs.length, 0);
});

test('PDF sidebar navigation is not returned when saving fails', async () => {
  const { browser, explanation } = fixture();
  browser.storage.local.set = async () => { throw new Error('Storage full'); };
  await assert.rejects(
    openExplanationChat(explanation, browser, { destination: 'pdf-sidebar' }), /Storage full/
  );
});

test('failed tab creation can be retried without duplicating the saved explanation', async () => {
  const { stored, browser, explanation } = fixture();
  const create = browser.tabs.create;
  browser.tabs.create = async () => { throw new Error('Tab unavailable'); };
  await assert.rejects(openExplanationChat(explanation, browser), /Tab unavailable/);
  browser.tabs.create = create;
  await openExplanationChat(explanation, browser);
  assert.equal(stored[CHAT_HISTORY_KEY].length, 1);
});

test('empty explanations cannot open a chat', async () => {
  const { tabs, browser } = fixture();
  await assert.rejects(openExplanationChat({ messages: [] }, browser), /Send a message/);
  assert.equal(tabs.length, 0);
});
