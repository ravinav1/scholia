import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import vm from 'node:vm';
import { build } from 'esbuild';

const bundle = await build({
  entryPoints: ['apps/chrome/src/service-worker.js'],
  bundle: true,
  write: false,
  format: 'iife',
  platform: 'browser'
});

function event() {
  const listeners = [];
  return { addListener: (listener) => listeners.push(listener), emit: (...args) => listeners.forEach((fn) => fn(...args)) };
}

function storage() {
  const values = {};
  return {
    async get(key) { return key ? { [key]: values[key] } : { ...values }; },
    async set(items) { Object.assign(values, items); },
    async remove(key) { delete values[key]; }
  };
}

function workerHarness({ brave, url, title = '', contentType = 'text/html', scriptError = false, mimeFrame = false }) {
  let tab = { id: 1, windowId: 1, url, title, status: 'complete' };
  const updates = [];
  const timers = new Map();
  const chrome = {
    runtime: {
      onInstalled: event(), onStartup: event(), onMessage: event(), onConnect: event(),
      getURL: (path) => `chrome-extension://scholia/${path}`,
      async getContexts() {
        return mimeFrame ? [{ documentUrl: 'chrome-extension://scholia/pdf-viewer.html', frameId: 5 }] : [];
      }
    },
    alarms: { onAlarm: event() },
    commands: { onCommand: event() },
    contextMenus: { onClicked: event() },
    storage: { local: storage(), session: storage() },
    scripting: {
      async executeScript({ func }) {
        if (scriptError) throw new Error('Cannot access this page');
        const result = vm.runInNewContext(`(${func.toString()})()`, {
          location: { href: tab.url },
          document: { contentType, querySelector: () => null }
        });
        return [{ frameId: 0, result }];
      }
    },
    tabs: {
      onCreated: event(), onUpdated: event(), onRemoved: event(),
      async query() { return [tab]; },
      async get() { return tab; },
      async update(id, options) { updates.push({ id, ...options }); return { ...tab, ...options }; }
    }
  };
  vm.runInNewContext(bundle.outputFiles[0].text, {
    chrome, navigator: brave ? { brave: { isBrave: async () => true } } : {},
    URL, console, crypto: { randomUUID },
    setTimeout(fn) { const id = randomUUID(); timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); }
  });
  return {
    updates,
    navigate(changeInfo) {
      tab = { ...tab, ...changeInfo };
      chrome.tabs.onUpdated.emit(1, changeInfo, tab);
    },
    restore() {
      chrome.tabs.onCreated.emit({ id: tab.id });
      chrome.tabs.onUpdated.emit(tab.id, { status: 'complete' }, tab);
    },
    changeUrl(next) { tab = { ...tab, url: next }; },
    async flush() {
      for (const [id, fn] of timers) { timers.delete(id); fn(); }
      await new Promise(setImmediate);
    }
  };
}

for (const brave of [false, true]) {
  for (const url of ['file:///Users/reader/Lecture%20notes.PDF#page=2', 'https://example.test/notes.pdf']) {
    test(`${brave ? 'Brave' : 'Chromium'} automatically opens ${new URL(url).protocol} PDFs without the MIME API`, async () => {
      const worker = workerHarness({ brave, url, contentType: 'application/pdf' });
      worker.navigate({ status: 'loading' });
      await worker.flush();
      assert.equal(worker.updates.length, 0);
      worker.navigate({ status: 'complete' });
      await worker.flush();
      assert.equal(worker.updates.length, 1);
      assert.match(worker.updates[0].url, /^chrome-extension:\/\/scholia\/pdf-viewer.html\?source=/);
    });
  }
}

test('automatic fallback leaves an active MIME reader in place', async () => {
  const worker = workerHarness({ brave: true, url: 'file:///Users/reader/notes.pdf', mimeFrame: true });
  worker.navigate({ status: 'complete' });
  await worker.flush();
  assert.equal(worker.updates.length, 0);
});

test('submitting a chat prompt mentioning a PDF never redirects an HTML chat tab', async () => {
  const prompt = 'Explain https://example.test/notes.pdf';
  for (const url of [
    `https://chatgpt.com/?q=${encodeURIComponent(prompt)}`,
    'https://chatgpt.com/c/conversation-123',
    'https://other-chat.example/conversation'
  ]) {
    const worker = workerHarness({ url, title: `${prompt} — ChatGPT` });
    worker.navigate({ status: 'complete' });
    await worker.flush();
    assert.deepEqual(worker.updates, [], url);
  }
});

test('a PDF link at the end of an HTML chat address never opens the reader', async () => {
  const prompt = 'Explain https://example.test/notes.pdf';
  for (const url of [
    `https://chat.example/chat/${encodeURIComponent(prompt)}`,
    `https://chat.example/?q=${encodeURIComponent(prompt)}`,
    `https://chat.example/#${encodeURIComponent(prompt)}`,
    'https://chat.example/conversation/notes.pdf',
    'https://chat.example/conversation/notes%2Epdf'
  ]) {
    const worker = workerHarness({ url, title: prompt });
    worker.navigate({ status: 'complete' });
    await worker.flush();
    assert.deepEqual(worker.updates, [], url);
  }
});

test('title and same-document chat updates mentioning a trailing PDF link leave the tab alone', async () => {
  const url = 'https://chat.example/c/conversation-123';
  const title = 'Explain https://example.test/notes.pdf';
  const worker = workerHarness({ url, title });
  for (const update of [{ title }, { url: `${url}?q=${encodeURIComponent(title)}` }, { status: 'complete' }]) {
    worker.navigate(update);
    await worker.flush();
    assert.deepEqual(worker.updates, [], JSON.stringify(update));
  }
});

test('native PDF viewers that block document inspection still use the compatibility reader', async () => {
  for (const url of ['file:///Users/reader/notes.pdf', 'https://example.test/notes.pdf']) {
    const worker = workerHarness({ url, scriptError: true });
    worker.navigate({ status: 'complete' });
    await worker.flush();
    assert.equal(worker.updates.length, 1, url);
  }
});

test('known repository PDF previews still resolve to their download URL', async () => {
  const worker = workerHarness({ url: 'https://github.com/example/course/blob/main/notes.pdf' });
  worker.navigate({ status: 'complete' });
  await worker.flush();
  assert.equal(worker.updates.length, 1);
  assert.equal(worker.updates[0].url, 'https://github.com/example/course/blob/main/notes.pdf?raw=1');
});

test('a title-only PDF candidate opens only when the actual document is a PDF', async () => {
  for (const contentType of ['text/html', 'application/pdf']) {
    const worker = workerHarness({
      url: 'https://files.example/download?id=42', title: 'lecture-notes.pdf', contentType
    });
    worker.navigate({ status: 'complete' });
    await worker.flush();
    assert.equal(worker.updates.length, contentType === 'application/pdf' ? 1 : 0);
  }
});

test('a PDF filename in the title cannot redirect a tab whose document cannot be checked', async () => {
  const worker = workerHarness({
    url: 'https://chatgpt.com/c/conversation-123', title: 'notes.pdf', scriptError: true
  });
  worker.navigate({ status: 'complete' });
  await worker.flush();
  assert.deepEqual(worker.updates, []);
});

test('a delayed PDF handoff cannot replace a tab that has navigated away', async () => {
  const worker = workerHarness({ brave: true, url: 'file:///Users/reader/notes.pdf' });
  worker.navigate({ status: 'complete' });
  worker.changeUrl('https://example.test/');
  await worker.flush();
  assert.equal(worker.updates.length, 0);
});

test('restoring a standalone reader does not send it back into native PDF navigation', async () => {
  const worker = workerHarness({
    brave: true,
    url: 'chrome-extension://scholia/pdf-viewer.html?source=restore-pdf-12345'
  });
  worker.restore();
  await worker.flush();
  assert.deepEqual(worker.updates, []);
});
