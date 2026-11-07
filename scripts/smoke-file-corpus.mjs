import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { resolve, sep } from 'node:path';
import { chromiumSession } from './smoke/browser/lib/chromium.mjs';

const root = process.cwd();
const server = createServer(async (request, response) => {
  const path = new URL(request.url, 'http://localhost').pathname;
  if (path === '/') {
    response.setHeader('Content-Type', 'text/html');
    response.end('<!doctype html><meta charset="utf-8"><title>Attachment corpus smoke</title><body>Attachment history storage test</body>');
    return;
  }
  const file = resolve(root, `.${path}`);
  if (!file.startsWith(`${root}${sep}`) || !/^\/(apps\/chrome\/src|packages\/core\/src)\/.*\.js$/.test(path)) {
    response.writeHead(404); response.end(); return;
  }
  try { response.setHeader('Content-Type', 'text/javascript'); response.end(await readFile(file)); }
  catch { response.writeHead(404); response.end(); }
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
let browser;
const area = `({
  async get(key) { return { [key]: JSON.parse(localStorage.getItem(key) || 'null') }; },
  async set(values) { for (const [key, value] of Object.entries(values)) localStorage.setItem(key, JSON.stringify(value)); },
  async remove(key) { localStorage.removeItem(key); }
})`;
try {
  browser = await chromiumSession();
  const { send, evaluate, until } = browser;
  await send('Page.navigate', { url: `http://127.0.0.1:${server.address().port}/` });
  await until('document.title === "Attachment corpus smoke"');
  const saved = await evaluate(`(async () => {
    const { saveChat, CHAT_HISTORY_KEY } = await import('/apps/chrome/src/chat/chat-history.js');
    const source = 'Routine project source.\\n'.repeat(90000);
    const record = await saveChat({ id: 'corpus-smoke', createdAt: Date.now(), updatedAt: Date.now(), capture: {}, messages: [
      { role: 'user', content: 'What is tailparameter?', files: [
        { id: 'old-file', name: 'model.m', sourcePath: '/books/model.m', text: source + 'tailparameter = 13;' },
        { id: 'actual-file', name: 'model.m', sourcePath: '/programming/model.m', text: source + 'tailparameter = 28;' }
      ] }
    ] }, ${area});
    return { count: record.messages[0].files[0].textCorpusUTF16Count, preview: record.messages[0].files[0].text.length,
      stateBytes: localStorage.getItem(CHAT_HISTORY_KEY).length, distinct: record.messages[0].files[0].textCorpusID !== record.messages[0].files[1].textCorpusID };
  })()`);
  assert.ok(saved.count > 2_000_000);
  assert.equal(saved.preview, 16_000);
  assert.ok(saved.stateBytes < 40_000);
  assert.equal(saved.distinct, true);
  await send('Page.reload');
  await until('document.title === "Attachment corpus smoke" && document.readyState === "complete"');
  const restored = await evaluate(`(async () => {
    const { getChat } = await import('/apps/chrome/src/chat/chat-history.js');
    const { sanitizeConversation } = await import('/packages/core/src/prompt.js');
    const record = await getChat('corpus-smoke', ${area});
    const request = sanitizeConversation([...record.messages, { role: 'assistant', content: 'Let us examine it.' }, { role: 'user', content: 'Why?' }]);
    return { lengths: record.messages[0].files.map(file => file.text.length), text: request[0].content,
      paths: record.messages[0].files.map(file => file.sourcePath) };
  })()`);
  assert.deepEqual(restored.lengths, [saved.count, saved.count]);
  assert.match(restored.text, /tailparameter = 13/);
  assert.match(restored.text, /tailparameter = 28/);
  assert.match(restored.text, /id="old-file"/);
  assert.match(restored.text, /id="actual-file"/);
  assert.ok(restored.text.length < 52_000);
  assert.deepEqual(restored.paths, ['/books/model.m', '/programming/model.m']);
  assert.deepEqual(browser.errors, []);
  console.log('Chromium corpus history smoke passed: two distinct 2 MB same-name files saved in IndexedDB, compact history, full restoration after reload, source paths/IDs preserved, and late evidence retrieved within the prompt budget.');
} finally {
  await browser?.close();
  await new Promise((resolve) => server.close(resolve));
}
