import { spawn } from 'node:child_process';
import { createReadStream } from 'node:fs';
import { access, mkdtemp, rm, stat, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, extname, join, normalize, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chatFilesSmoke } from './lib/chat-files-smoke.mjs';
import { pdfLogErrorsSmoke } from './lib/pdf-log-errors-smoke.mjs';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const chromiumCandidates = [
  process.env.CHROMIUM_BIN,
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser'
].filter(Boolean);

async function chromiumBinary() {
  for (const candidate of chromiumCandidates) {
    try { await access(candidate); return candidate; } catch {}
  }
  throw new Error('Chromium was not found. Set CHROMIUM_BIN to its executable.');
}

function pdfSearchFixture() {
  const firstStream = 'BT /F1 18 Tf 72 720 Td (First needle phrase in this PDF) Tj 0 -28 Td (Photosynthesis converts sunlight into chemical energy for plants) Tj ET';
  const secondStream = 'BT /F1 18 Tf 72 720 Td (Second needle phrase in this PDF) Tj 0 -28 Td (A wall socket supplies electrical power) Tj ET';
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R /PageMode /UseOutlines >>',
    '<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 6 0 R /Annots [8 0 R 9 0 R] >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 7 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    `<< /Length ${firstStream.length} >>\nstream\n${firstStream}\nendstream`,
    `<< /Length ${secondStream.length} >>\nstream\n${secondStream}\nendstream`,
    '<< /Type /Annot /Subtype /Link /Rect [72 680 360 710] /Border [0 0 0] /A << /S /URI /URI (https://linkinghub.elsevier.com/retrieve/pii/S0123456789012345) >> >>',
    '<< /Type /Annot /Subtype /Link /Rect [72 630 360 660] /Border [0 0 0] /Dest [4 0 R /Fit] >>',
    '<< /Type /Outlines /First 11 0 R /Last 12 0 R /Count 3 >>',
    '<< /Title (Introduction) /Parent 10 0 R /Next 12 0 R /Dest [3 0 R /Fit] >>',
    '<< /Title (Study sections) /Parent 10 0 R /Prev 11 0 R /First 13 0 R /Last 13 0 R /Count 1 /Dest [3 0 R /Fit] >>',
    '<< /Title (Results) /Parent 12 0 R /Dest [4 0 R /Fit] >>'
  ];
  let source = '%PDF-1.4\n';
  const offsets = [];
  for (const [index, object] of objects.entries()) {
    offsets.push(source.length);
    source += `${index + 1} 0 obj\n${object}\nendobj\n`;
  }
  const xref = source.length;
  source += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const offset of offsets) source += `${String(offset).padStart(10, '0')} 00000 n \n`;
  source += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return new TextEncoder().encode(source);
}

function installChromeStub() {
  // Record launch requests without opening installed apps or Chromium protocol dialogs.
  const frameSource = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'src');
  Object.defineProperty(HTMLIFrameElement.prototype, 'src', {
    ...frameSource,
    set(value) {
      if (/^(?:scholia-codex|claudecode|opencode):/.test(String(value))) {
        this.dataset.smokeBridgeUrl = String(value);
        frameSource.set.call(this, 'about:blank');
      } else {
        frameSource.set.call(this, value);
      }
    }
  });
  const attachShadow = Element.prototype.attachShadow;
  Element.prototype.attachShadow = function(options) {
    const root = attachShadow.call(this, options);
    if (this.id === 'scholia-extension-root') globalThis.__scholiaShadow = root;
    return root;
  };
  if (new URLSearchParams(location.search).get('simulate-brave') === '1') {
    const frameSrc = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, 'src');
    Object.defineProperty(HTMLIFrameElement.prototype, 'src', {
      ...frameSrc,
      set(value) {
        if (String(value).includes('/panel.html')) throw new Error('Brave simulation: nested extension chat frame blocked');
        frameSrc.set.call(this, value);
      }
    });
    Object.defineProperty(navigator, 'brave', {
      configurable: true,
      value: { isBrave: async () => true }
    });
  }
  const eventChannel = () => {
    const listeners = [];
    return { listeners, addListener(listener) { listeners.push(listener); } };
  };
  let completion = 0;
  const changed = eventChannel();
  let localValues = {};
  try { localValues = JSON.parse(localStorage.getItem('__scholia_chrome_local_stub__') || '{}'); } catch {}
  const persistLocalValues = () => {
    try { localStorage.setItem('__scholia_chrome_local_stub__', JSON.stringify(localValues)); } catch {}
  };
  const canvasPdfFrame = location.pathname === '/__scholia-canvas-pdf-frame-fixture.html';
  const settings = {
    provider: canvasPdfFrame ? 'codex' : 'openai',
    language: 'en',
    models: { openai: 'gpt-5-mini', codex: 'gpt-5.6-sol' },
    customModels: {},
    discoveredModels: {
      opencode: [
        { id: 'opencode-go/glm-5.3-flash', label: 'GLM 5.3 Flash · OpenCode Go' },
        { id: 'future-provider/brand-new-model', label: 'Brand New Model · Future Provider' }
      ]
    },
    modelCatalogCheckedAt: { opencode: Date.now() },
    reasoningEfforts: { codex: 'high' },
    fastMode: canvasPdfFrame,
    includePageContext: true,
    explainOnSelection: true,
    chatgptWebContext: {
      enabled: true,
      quickChatRefreshInterval: '3h',
      available: true,
      hasMemory: true,
      hasProject: true,
      projectName: 'Study project',
      updatedAt: Date.now(),
      fetchedAt: Date.now() - 4 * 60 * 60_000
    },
    siteAccessMode: 'blocklist',
    allowedSites: [],
    disabledSites: [],
    configuredProviders: [canvasPdfFrame ? 'codex' : 'openai']
  };
  const activeSource = {
    tabId: 1,
    windowId: 1,
    pageTitle: 'Recursive smoke notes',
    pageLanguage: 'en',
    url: 'https://example.test/notes',
    sourceKind: 'page'
  };
  const valuesFor = (payload) => {
    if (payload.type === 'SCHOLIA_GET_PUBLIC_SETTINGS') return settings;
    if (payload.type === 'SCHOLIA_GET_SETTINGS') {
      return {
        ...settings,
        chatgptWebContext: {
          enabled: true,
          quickChatRefreshInterval: '3h',
          memory: 'Existing imported memory.',
          projectName: 'Study project',
          projectUrl: 'https://chatgpt.com/g/g-p-study/project',
          projectContext: 'Existing imported project context.',
          updatedAt: Date.now(),
          fetchedAt: Date.now() - 4 * 60 * 60_000
        }
      };
    }
    if (payload.type === 'SCHOLIA_REFRESH_CHATGPT_CONTEXT_FOR_QUICK_CHAT') {
      globalThis.__scholiaChatGptRefreshes = Number(globalThis.__scholiaChatGptRefreshes || 0) + 1;
      return {
        refreshed: true,
        due: true,
        memoryCharacters: 34,
        context: {
          ...settings.chatgptWebContext,
          quickChatRefreshInterval: '3h',
          fetchedAt: Date.now()
        }
      };
    }
    if (payload.type === 'SCHOLIA_GET_CHATGPT_WEB_STATE') {
      return {
        open: true,
        supported: true,
        loggedIn: true,
        projectName: 'Study project',
        projectUrl: 'https://chatgpt.com/g/g-p-study/project',
        captureText: 'New visible ChatGPT context.',
        captureKind: 'selection',
        capturedCharacters: 28
      };
    }
    if (payload.type === 'SCHOLIA_IMPORT_CHATGPT_MEMORY') {
      return {
        open: true,
        supported: true,
        loggedIn: true,
        projectName: 'Study project',
        projectUrl: 'https://chatgpt.com/g/g-p-study/project',
        memoryText: 'Full rendered ChatGPT memory summary.',
        captureText: 'Full rendered ChatGPT memory summary.',
        captureKind: 'memory',
        capturedCharacters: 37
      };
    }
    if (payload.type === 'SCHOLIA_SAVE_SETTINGS') return payload.settings;
    if (payload.type === 'SCHOLIA_SAVE_MODEL') {
      settings.provider = payload.provider;
      settings.models[payload.provider] = payload.model;
      settings.fastMode = Boolean(payload.fastMode);
      return settings;
    }
    if (payload.type === 'SCHOLIA_BRIDGE_STATUS') {
      const provider = String(payload.provider || 'opencode');
      const schemes = { claudecode: 'claudecode', codex: 'scholia-codex', opencode: 'opencode' };
      return {
        up: globalThis.__scholiaBridgeUp ?? (canvasPdfFrame && provider === 'codex'),
        provider,
        label: provider === 'opencode' ? 'opencode server' : `${provider} bridge`,
        base: provider === 'opencode' ? 'http://127.0.0.1:4096' : 'http://127.0.0.1:8789',
        startUrl: `${schemes[provider] || provider}://start`,
        command: provider === 'opencode' ? 'opencode serve --port 4096' : `npm run bridge:${provider}`,
        installCommand: `node scripts/install-${provider}-handler.mjs`
      };
    }
    if (payload.type === 'SCHOLIA_GET_PDF_VIEWER_SOURCE') {
      const pdfUrl = new URL('/__scholia-pdf-search-fixture.pdf', location.href).href;
      return { pageTitle: 'Searchable PDF fixture', url: pdfUrl, pdfUrl };
    }
    if (payload.type === 'SCHOLIA_OPEN_SIDE_PANEL') {
      globalThis.__scholiaSidePanelRequest = payload;
      return { surface: 'panel', view: payload.view || '' };
    }
    if (payload.type === 'SCHOLIA_TOGGLE_QUICK_CHAT') {
      globalThis.__scholiaSidePanelRequest = { ...payload, view: 'new' };
      return { surface: 'panel', mode: 'quick-chat' };
    }
    if (payload.type === 'SCHOLIA_GET_ACTIVE_SOURCE') return globalThis.__scholiaSourceOverride || activeSource;
    if (payload.type === 'SCHOLIA_GET_ACTIVE_SITE') {
      return { site: 'example.test', enabled: true, mode: 'blocklist' };
    }
    if (payload.type === 'SCHOLIA_GET_ACTIVE_SELECTION') return null;
    if (payload.type === 'SCHOLIA_GET_ACTIVE_CONTEXT') {
      globalThis.__scholiaLastContextRequest = payload;
      const requestedLimit = Number(payload.maxChars) || 6_000;
      const full = requestedLimit > 6_000;
      const source = `${full ? 'FULL_SIDEBAR_CONTEXT' : 'COMPACT_SIDEBAR_CONTEXT'}\n${'Complete source context evidence. '.repeat(700)}`;
      const context = source.slice(0, Math.min(requestedLimit, full ? 12_000 : 5_000));
      return {
        ...(globalThis.__scholiaSourceOverride || activeSource),
        context,
        rawContextCharacters: source.length,
        packedContextCharacters: context.length
      };
    }
    if (payload.type === 'SCHOLIA_CAPTURE_ACTIVE_VISIBLE' || payload.type === 'SCHOLIA_CAPTURE_ACTIVE_REGION') {
      const canvas = document.createElement('canvas');
      canvas.width = 160;
      canvas.height = 100;
      const context = canvas.getContext('2d');
      context.fillStyle = '#dcebe4';
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.fillStyle = '#173f34';
      context.fillRect(24, 20, 112, 60);
      return { ...activeSource, imageDataUrl: canvas.toDataURL('image/png') };
    }
    return {};
  };
  const chromeStub = {
    runtime: {
      lastError: null,
      onMessage: eventChannel(),
      getURL(path) { return new URL(`/dist/chrome/${path}`, location.href).href; },
      openOptionsPage() {},
      sendMessage(payload, callback) {
        if (typeof callback !== 'function') return new Promise((resolve) => chromeStub.runtime.sendMessage(payload, resolve));
        (globalThis.__scholiaRuntimeMessages ||= []).push(payload.type + (payload.pdfReaderPanel ? ':pdf' : ''));
        if (payload.type === 'SCHOLIA_MUTATE_CHAT_HISTORY') {
          import('/apps/chrome/src/chat-history.js')
            .then(({ mutateChatHistory }) => mutateChatHistory(payload.operation, payload.value, chromeStub.storage.local))
            .then((value) => callback({ ok: true, value }))
            .catch((error) => callback({ ok: false, error: error.message }));
          return;
        }
        if (payload.type === 'SCHOLIA_MOVE_EXPLANATION_TO_CHAT') {
          if (globalThis.__scholiaFailMove) {
            queueMicrotask(() => callback({ ok: false, error: 'Test transfer failure' }));
            return;
          }
          import('/apps/chrome/src/explanation-chat.js')
            .then(({ openExplanationChat }) => openExplanationChat(payload.explanation, chromeStub, {
              destination: location.pathname.endsWith('/pdf-viewer.html')
                || new URLSearchParams(location.search).get('surface') === 'pdf-overlay'
                ? 'pdf-sidebar' : 'tab'
            }))
            .then((value) => callback({ ok: true, value }))
            .catch((error) => callback({ ok: false, error: error.message }));
          return;
        }
        queueMicrotask(() => callback({ ok: true, value: valuesFor(payload) }));
      },
      connect() {
        const onMessage = eventChannel();
        const onDisconnect = eventChannel();
        return {
          onMessage,
          onDisconnect,
          postMessage(payload) {
            if (payload.type !== 'start') return;
            globalThis.__scholiaLastChatPayload = payload.payload;
            globalThis.__scholiaChatPayloads ||= [];
            globalThis.__scholiaChatPayloads.push(payload.payload);
            completion += 1;
            const text = completion === 1
              ? '## Root answer\n\nThe root recursion target is ready for another explanation.\n\n$$M_{\\text{final}} = M_{\\text{objective}}M_{\\text{{ocular}}}.$$\n\n```js\nconst result = 42;\n```'
              : completion === 2
                ? `## Child answer\n\n${Array.from({ length: 40 }, (_, index) => `Scrollable prelude ${index + 1}.`).join('\n\n')}\n\nThe child recursion target is ready too.\n\n${Array.from({ length: 100 }, (_, index) => `Scrollable child line ${index + 1}.`).join('\n\n')}`
                : completion === 3
                  ? '## Grandchild answer\n\nRecursive response selection completed successfully.'
                  : `## Regenerated answer\n\nEdited turn ${completion} regenerated successfully.`;
            setTimeout(() => onMessage.listeners.forEach((listener) => listener({
              type: 'token', requestId: payload.requestId, token: text
            })), 15);
            setTimeout(() => onMessage.listeners.forEach((listener) => listener({
              type: 'done', requestId: payload.requestId, provider: 'openai', model: 'gpt-5-mini',
              reasoning: completion === 1 ? 'Checked provider context before answering.' : ''
            })), 35);
          },
          disconnect() { onDisconnect.listeners.forEach((listener) => listener()); }
        };
      }
    },
    storage: {
      onChanged: changed,
      local: {
        async get(key) {
          if (typeof key === 'string') return { [key]: localValues[key] };
          return { ...localValues };
        },
        async set(values) {
          const changes = {};
          for (const [key, value] of Object.entries(values)) {
            changes[key] = { oldValue: localValues[key], newValue: value };
            localValues[key] = value;
          }
          persistLocalValues();
          changed.listeners.forEach((listener) => listener(changes, 'local'));
        },
        async remove(key) {
          const keys = Array.isArray(key) ? key : [key];
          const changes = {};
          for (const candidate of keys) {
            changes[candidate] = { oldValue: localValues[candidate] };
            delete localValues[candidate];
          }
          persistLocalValues();
          changed.listeners.forEach((listener) => listener(changes, 'local'));
        }
      },
      session: {
        async get() { return {}; },
        async set() {},
        async remove() {}
      }
    },
    commands: {
      async getAll() {
        return [
          { name: 'explain-selection', shortcut: 'Command+Shift+E' },
          { name: 'capture-region', shortcut: 'Command+Shift+S' },
          { name: 'quick-chat', shortcut: 'Command+Shift+K' }
        ];
      }
    },
    tabs: {
      onActivated: eventChannel(),
      onUpdated: eventChannel(),
      async create(options) {
        globalThis.__scholiaCreatedTabUrl = options?.url || '';
        return { id: 99, url: options?.url || '' };
      }
    }
  };
  Object.defineProperty(globalThis, 'chrome', { value: chromeStub, configurable: true });
}

class DevToolsClient {
  constructor(url) {
    this.nextID = 1;
    this.pending = new Map();
    this.events = [];
    this.socket = new WebSocket(url);
  }

  async open() {
    if (this.socket.readyState === WebSocket.OPEN) return;
    await new Promise((resolvePromise, reject) => {
      this.socket.addEventListener('open', resolvePromise, { once: true });
      this.socket.addEventListener('error', reject, { once: true });
    });
    this.socket.addEventListener('message', (event) => {
      const payload = JSON.parse(event.data);
      if (!payload.id) { this.events.push(payload); return; }
      const pending = this.pending.get(payload.id);
      if (!pending) return;
      this.pending.delete(payload.id);
      if (payload.error) pending.reject(new Error(payload.error.message));
      else pending.resolve(payload.result);
    });
  }

  send(method, params = {}) {
    const id = this.nextID++;
    return new Promise((resolvePromise, reject) => {
      this.pending.set(id, { resolve: resolvePromise, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  close() { this.socket.close(); }
}

function contentType(path) {
  return ({
    '.css': 'text/css', '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
    '.json': 'application/json', '.svg': 'image/svg+xml', '.woff2': 'font/woff2'
  })[extname(path)] || 'application/octet-stream';
}

async function startStaticServer() {
  const root = `${projectRoot}/`;
  const server = createServer(async (request, response) => {
    try {
      const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
      if (pathname === '/__scholia-pdf-search-fixture.pdf') {
        const bytes = pdfSearchFixture();
        response.writeHead(200, {
          'Content-Type': 'application/pdf',
          'Content-Length': String(bytes.byteLength)
        });
        response.end(bytes);
        return;
      }
      if (pathname === '/__scholia-pdf-wrapper/report.pdf') {
        response.writeHead(200, {
          'Content-Type': 'text/html; charset=utf-8',
          'X-Raw-Download': '/__scholia-pdf-search-fixture.pdf'
        });
        response.end('<!doctype html><title>Repository PDF preview</title><p>Download the raw document.</p>');
        return;
      }
      if (pathname === '/__scholia-html-context-fixture.html') {
        response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        response.end(`<!doctype html><html lang="en"><head><title>HTML context fixture</title>
          <script>window.__privateScriptMarker = 'must-not-reach-model-context';</script>
          <style>.hidden-proof { display:none }</style></head><body>
          <main id="lesson" data-course="logic"><h1>DOM theorem</h1><p>Visible proof text.</p>
          <section class="hidden-proof" aria-label="Supplemental proof">Hidden DOM-only lemma.</section>
          <a href="/source?chapter=4">Chapter source</a><input name="token" value="private-form-value"></main>
          <div id="scholia-extension-root">Extension-only controls</div></body></html>`);
        return;
      }
      if (pathname === '/__scholia-quick-chat-shortcut-fixture.html') {
        response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        response.end(`<!doctype html><html lang="en"><head><meta charset="utf-8">
          <title>Quick Chat shortcut fixture</title></head><body><main>Keyboard shortcut target</main>
          <script src="/dist/chrome/content.js"></script></body></html>`);
        return;
      }
      if (pathname === '/__scholia-canvas-course-fixture.html') {
        response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        response.end(`<!doctype html><html lang="en"><head><meta charset="utf-8">
          <title>Canvas course document preview</title><style>
          html,body{height:100%;margin:0;background:#eef0ed;font:16px system-ui,sans-serif}
          header{height:52px;display:flex;align-items:center;padding:0 20px;background:#9d1f35;color:white;font-weight:700}
          iframe{display:block;width:100%;height:calc(100% - 52px);border:0}
          </style></head><body><header>Canvas · Course PDF</header>
          <iframe id="canvas-pdf-frame" title="Document Preview" src="/__scholia-canvas-pdf-frame-fixture.html"></iframe>
          </body></html>`);
        return;
      }
      if (pathname === '/__scholia-clipboard-policy-fixture.html') {
        response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        response.end(`<!doctype html><html><head><title>Restricted clipboard frame</title>
          <style>html,body{margin:0;height:100%}iframe{width:100%;height:100%;border:0;display:block}</style>
          </head><body><iframe id="restricted-frame" allow="clipboard-write 'none'"
          src="/__scholia-canvas-pdf-frame-fixture.html"></iframe></body></html>`);
        return;
      }
      if (pathname === '/__scholia-canvas-pdf-frame-fixture.html') {
        response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        response.end(`<!doctype html><html lang="en" data-theme="dark"><head><meta charset="utf-8">
          <title>Canvas embedded PDF reader</title><style>
          html,body{min-height:100%;margin:0;background:#202421}
          #viewerContainer{padding:28px;overflow:auto}
          .page{position:relative;width:680px;height:720px;margin:0 auto;background:white;box-shadow:0 8px 28px rgba(0,0,0,.3)}
          canvas{position:absolute;inset:0;width:100%;height:100%}
          .textLayer{position:absolute;inset:72px;color:transparent;font:18px/1.5 sans-serif}
          .textLayer span{display:inline-block;color:#17231f}
          </style><script>
          window.__scholiaShadow = null;
          const originalAttachShadow = Element.prototype.attachShadow;
          Element.prototype.attachShadow = function(options) {
            const root = originalAttachShadow.call(this, options);
            if (this.id === 'scholia-extension-root') window.__scholiaShadow = root;
            return root;
          };
          </script></head><body><div id="viewerContainer"><section class="page" data-page-number="1">
          <canvas width="680" height="720"></canvas><div class="textLayer" role="presentation">
          <span id="canvas-pdf-text">A source point emits a cone of light through the specimen in the embedded Canvas PDF reader.</span>
          </div></section></div><script src="/dist/chrome/content.js"></script></body></html>`);
        return;
      }
      const target = normalize(join(projectRoot, pathname));
      if (!`${target}`.startsWith(root)) throw new Error('Unsafe path');
      const details = await stat(target);
      if (!details.isFile()) throw new Error('Not a file');
      response.writeHead(200, { 'Content-Type': contentType(target) });
      createReadStream(target).pipe(response);
    } catch {
      response.writeHead(404).end('Not found');
    }
  });
  await new Promise((resolvePromise) => server.listen(0, '127.0.0.1', resolvePromise));
  return { server, port: server.address().port };
}

async function availablePort() {
  const probe = createServer();
  await new Promise((resolvePromise) => probe.listen(0, '127.0.0.1', resolvePromise));
  const port = probe.address().port;
  await new Promise((resolvePromise) => probe.close(resolvePromise));
  return port;
}

async function waitForDebugger(port) {
  for (let attempt = 0; attempt < 80; attempt += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`);
      if (response.ok) return;
    } catch {}
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 75));
  }
  throw new Error('Chromium debugging endpoint did not start.');
}

async function evaluate(client, expression) {
  const result = await client.send('Runtime.evaluate', {
    expression,
    awaitPromise: true,
    returnByValue: true
  });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.text || 'Evaluation failed.');
  return result.result.value;
}

async function waitFor(client, expression, label) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (await evaluate(client, expression)) return;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 50));
  }
  throw new Error(`Timed out waiting for ${label}.`);
}

function selectionExpression(selector, needle) {
  return `(() => {
    const root = document.querySelector(${JSON.stringify(selector)});
    if (!root) return false;
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      const start = node.data.indexOf(${JSON.stringify(needle)});
      if (start < 0) continue;
      const range = document.createRange();
      range.setStart(node, start);
      range.setEnd(node, start + ${JSON.stringify(needle)}.length);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      node.parentElement.dispatchEvent(new PointerEvent('pointerup', { bubbles: true, pointerType: 'mouse' }));
      return true;
    }
    return false;
  })()`;
}

const profile = await mkdtemp(join(tmpdir(), 'scholia-chromium-smoke-'));
const { server, port: staticPort } = await startStaticServer();
const debugPort = await availablePort();
const chromium = spawn(await chromiumBinary(), [
  '--headless=new', '--no-first-run', '--disable-default-apps', '--disable-gpu',
  `--remote-debugging-port=${debugPort}`, `--user-data-dir=${profile}`,
  '--window-size=900,900', 'about:blank'
], { stdio: 'ignore' });
let client;

smoke: try {
  await waitForDebugger(debugPort);
  const targetResponse = await fetch(`http://127.0.0.1:${debugPort}/json/new?about:blank`, { method: 'PUT' });
  const target = await targetResponse.json();
  client = new DevToolsClient(target.webSocketDebuggerUrl);
  await client.open();
  await client.send('Page.enable');
  await client.send('Runtime.enable');
  await client.send('Page.addScriptToEvaluateOnNewDocument', {
    source: `(${installChromeStub.toString()})()`
  });
  if (process.argv.includes('--chat-files')) {
    await chatFilesSmoke({ client, evaluate, waitFor, staticPort, selectionExpression });
    break smoke;
  }
  if (process.argv.includes('--pdf-log-errors')) {
    await pdfLogErrorsSmoke({ client, evaluate, waitFor, staticPort, selectionExpression });
    break smoke;
  }
  await client.send('Page.navigate', { url: `http://127.0.0.1:${staticPort}/__scholia-html-context-fixture.html` });
  await waitFor(client, "document.readyState === 'complete' && document.querySelector('#lesson')", 'HTML context fixture');
  const htmlContextState = await evaluate(client, `(async () => {
    const { pageMetadata } = await import('/apps/chrome/src/page-capture.js');
    const metadata = pageMetadata();
    return JSON.stringify({
      context: metadata.context,
      visible: metadata.visibleContext,
      rendered: metadata.renderedContextCharacters,
      html: metadata.htmlContextCharacters
    });
  })()`);
  const htmlContext = JSON.parse(htmlContextState);
  if (!htmlContext.context.includes('<scholia-page-html>')
      || !htmlContext.context.includes('<main id="lesson" data-course="logic">')
      || !htmlContext.context.includes('Hidden DOM-only lemma.')
      || !htmlContext.context.includes('href="http://127.0.0.1:')
      || htmlContext.context.includes('must-not-reach-model-context')
      || htmlContext.context.includes('private-form-value')
      || htmlContext.context.includes('Extension-only controls')
      || !htmlContext.visible.includes('Visible proof text')
      || htmlContext.visible.includes('Hidden DOM-only lemma')
      || !htmlContext.rendered
      || !htmlContext.html) {
    throw new Error(`The Chromium page context did not include a safe DOM HTML snapshot: ${htmlContextState.slice(0, 900)}`);
  }
  const memoryImportDOMState = JSON.parse(await evaluate(client, `(async () => {
    const {
      collectMemoryPanelText,
      findChatGptMemoryManageButton,
      readChatGptMemoryPanel
    } = {
      ...await import('/apps/chrome/src/chatgpt-web.js'),
      ...await import('/apps/chrome/src/chatgpt-probe.js')
    };
    const settings = document.createElement('section');
    settings.innerHTML = '<h1>Personalization</h1><h2>Base style and tone</h2><section><h2>Subscription</h2><button data-testid="subscription-manage">Manage</button></section><h2>Characteristics</h2><h2>Custom instructions</h2><section><h2>Memory</h2><p>Enable memory</p><button data-testid="memory-toggle" aria-label="Enable memory"></button><p>View an overview of what ChatGPT has learned about you.</p><button data-testid="memory-manage-button">Manage</button></section><h2>About you</h2><h2>Record mode</h2><h2>Advanced</h2>';
    document.body.append(settings);
    const manageFound = findChatGptMemoryManageButton(document)?.dataset.testid === 'memory-manage-button';
    const settingsRejected = readChatGptMemoryPanel(document, { allowBareMemory: true }) == null;
    settings.remove();

    const modal = document.createElement('section');
    modal.setAttribute('role', 'dialog');
    modal.innerHTML = '<h2>Memory</h2><p>Prefers direct answers.</p><p>Studies engineering at Waterloo.</p><button>Close</button>';
    document.body.append(modal);
    const memory = readChatGptMemoryPanel(document, { allowBareMemory: true });
    modal.remove();

    const virtualized = document.createElement('section');
    virtualized.setAttribute('role', 'dialog');
    virtualized.style.cssText = 'display:block;height:100px;overflow:auto';
    virtualized.innerHTML = '<h2>Memory</h2><div data-spacer style="height:900px"></div><p data-entry>First remembered preference.</p><button>Close</button>';
    const entry = virtualized.querySelector('[data-entry]');
    const spacer = virtualized.querySelector('[data-spacer]');
    virtualized.addEventListener('scroll', () => {
      if (virtualized.scrollTop > 500) {
        entry.textContent = 'Third lazy-loaded preference.';
        spacer.style.height = '1500px';
      } else if (virtualized.scrollTop > 100) {
        entry.textContent = 'Second remembered preference.';
      } else {
        entry.textContent = 'First remembered preference.';
      }
    });
    document.body.append(virtualized);
    const virtualizedPanel = readChatGptMemoryPanel(document, { allowBareMemory: true });
    const virtualizedText = await collectMemoryPanelText(virtualizedPanel);
    virtualized.remove();
    return JSON.stringify({ manageFound, settingsRejected, text: memory?.text || '', virtualizedText });
  })()`));
  if (!memoryImportDOMState.manageFound
      || !memoryImportDOMState.settingsRejected
      || !memoryImportDOMState.text.includes('Prefers direct answers.')
      || memoryImportDOMState.text.includes('Personalization')
      || !memoryImportDOMState.virtualizedText.includes('First remembered preference.')
      || !memoryImportDOMState.virtualizedText.includes('Second remembered preference.')
      || !memoryImportDOMState.virtualizedText.includes('Third lazy-loaded preference.')) {
    throw new Error(`ChatGPT memory DOM classification was not deterministic: ${JSON.stringify(memoryImportDOMState)}`);
  }
  await client.send('Page.navigate', { url: `http://127.0.0.1:${staticPort}/__scholia-quick-chat-shortcut-fixture.html` });
  await waitFor(client, "document.readyState === 'complete' && document.querySelector('#scholia-extension-root')", 'Quick Chat shortcut fixture');
  await client.send('Input.dispatchKeyEvent', {
    type: 'keyDown', key: 'k', code: 'KeyK', modifiers: 12,
    windowsVirtualKeyCode: 75, nativeVirtualKeyCode: 40
  });
  await client.send('Input.dispatchKeyEvent', {
    type: 'keyUp', key: 'k', code: 'KeyK', modifiers: 12,
    windowsVirtualKeyCode: 75, nativeVirtualKeyCode: 40
  });
  await waitFor(client, "globalThis.__scholiaSidePanelRequest?.view === 'new'", 'Command-Shift-K Quick Chat handoff');
  await client.send('Page.navigate', { url: `http://127.0.0.1:${staticPort}/__scholia-canvas-course-fixture.html` });
  await waitFor(client, `document.querySelector('#canvas-pdf-frame')?.contentWindow?.__scholiaShadow
    && document.querySelector('#canvas-pdf-frame').contentWindow.__scholiaShadow.querySelector('[data-model] optgroup')`, 'Scholia inside Canvas PDF frame');
  await evaluate(client, `(() => {
    const frame = document.querySelector('#canvas-pdf-frame');
    const frameWindow = frame.contentWindow;
    const node = frame.contentDocument.querySelector('#canvas-pdf-text').firstChild;
    const needle = 'source point';
    const start = node.data.indexOf(needle);
    const range = frame.contentDocument.createRange();
    range.setStart(node, start);
    range.setEnd(node, start + needle.length);
    frameWindow.getSelection().removeAllRanges();
    frameWindow.getSelection().addRange(range);
    node.parentElement.dispatchEvent(new frameWindow.PointerEvent('pointerup', {
      bubbles: true, pointerType: 'mouse'
    }));
  })()`);
  await waitFor(client, `(() => {
    const frame = document.querySelector('#canvas-pdf-frame');
    const shadow = frame.contentWindow.__scholiaShadow;
    return !shadow.querySelector('[data-pill]').hidden
      && frame.contentWindow.getSelection()?.toString() === 'source point'
      && !shadow.querySelector('.scholia-highlight--text');
  })()`, 'native-only text selection in Canvas PDF frame');
  await evaluate(client, `(() => {
    const shadow = document.querySelector('#canvas-pdf-frame').contentWindow.__scholiaShadow;
    shadow.querySelector('[data-pill-question]').value = 'What is the source point?';
    shadow.querySelector('[data-pill-send]').click();
  })()`);
  await waitFor(client, `(() => {
    const shadow = document.querySelector('#canvas-pdf-frame').contentWindow.__scholiaShadow;
    return !shadow.querySelector('[data-backdrop]').hidden
      && shadow.querySelector('.scholia-message--assistant .scholia-bubble')?.textContent.includes('root recursion target')
      && !shadow.querySelector('.scholia-message--assistant .scholia-caret');
  })()`, 'contained response popup in Canvas PDF frame');
  const canvasPopupState = JSON.parse(await evaluate(client, `JSON.stringify((() => {
    const shadow = document.querySelector('#canvas-pdf-frame').contentWindow.__scholiaShadow;
    const modal = shadow.querySelector('[data-modal]');
    const header = modal.querySelector('.scholia-header');
    const source = modal.querySelector('.scholia-source');
    const messages = modal.querySelector('.scholia-messages');
    const composer = modal.querySelector('.scholia-composer__box');
    const send = modal.querySelector('.scholia-send').getBoundingClientRect();
    const userBubble = modal.querySelector('.scholia-message--user .scholia-bubble').getBoundingClientRect();
    const modalRect = modal.getBoundingClientRect();
    return {
      modalOverflow: modal.scrollWidth - modal.clientWidth,
      headerOverflow: header.scrollWidth - header.clientWidth,
      sourceOverflow: source.scrollWidth - source.clientWidth,
      messagesOverflow: messages.scrollWidth - messages.clientWidth,
      composerOverflow: composer.scrollWidth - composer.clientWidth,
      sendInside: send.right <= modalRect.right + 1,
      userInside: userBubble.right <= modalRect.right + 1,
      hasRedundantTextHighlight: Boolean(shadow.querySelector('.scholia-highlight--text')),
      selectedPage: document.querySelector('#canvas-pdf-frame').contentDocument.title
    };
  })())`));
  if (canvasPopupState.modalOverflow > 1
      || canvasPopupState.headerOverflow > 1
      || canvasPopupState.sourceOverflow > 1
      || canvasPopupState.messagesOverflow > 1
      || canvasPopupState.composerOverflow > 1
      || !canvasPopupState.sendInside
      || !canvasPopupState.userInside
      || canvasPopupState.hasRedundantTextHighlight) {
    throw new Error(`The Canvas PDF selection or response popup was invalid: ${JSON.stringify(canvasPopupState)}`);
  }
  await evaluate(client, `document.querySelector('#canvas-pdf-frame').contentWindow.__scholiaShadow
    .querySelector('.model-picker-button').click()`);
  await waitFor(client, `(() => {
    const shadow = document.querySelector('#canvas-pdf-frame').contentWindow.__scholiaShadow;
    const menu = shadow.querySelector('.model-picker-popover');
    const rect = menu.getBoundingClientRect();
    const modal = shadow.querySelector('[data-modal]').getBoundingClientRect();
    return !menu.hidden && rect.left >= modal.left && rect.right <= modal.right
      && rect.top >= modal.top && rect.bottom <= modal.bottom;
  })()`, 'Codex model menu contained inside the response popup');
  await evaluate(client, `(() => {
    const shadow = document.querySelector('#canvas-pdf-frame').contentWindow.__scholiaShadow;
    shadow.querySelector('.model-picker-button').click();
  })()`);
  await evaluate(client, `(() => {
    const shadow = document.querySelector('#canvas-pdf-frame').contentWindow.__scholiaShadow;
    shadow.querySelector('[data-composer]').value = 'Continue this page explanation';
    shadow.querySelector('[data-move-chat]').click();
  })()`);
  await waitFor(client, `document.querySelector('#canvas-pdf-frame').contentWindow.__scholiaCreatedTabUrl?.includes('/chat.html?chat=')
    && document.querySelector('#canvas-pdf-frame').contentWindow.__scholiaShadow.querySelector('[data-backdrop]').hidden`, 'page explanation moved to chat');
  await evaluate(client, `document.querySelector('#canvas-pdf-frame').contentDocument
    .dispatchEvent(new CustomEvent('scholia:document-instance-changed'))`);
  await waitFor(client, `!document.querySelector('#canvas-pdf-frame').contentWindow.__scholiaShadow
    .querySelector('.scholia-highlight')`, 'selection marker cleanup for a replaced PDF instance');
  const pageExplanationUrl = await evaluate(client, "document.querySelector('#canvas-pdf-frame').contentWindow.__scholiaCreatedTabUrl");
  await client.send('Page.navigate', { url: pageExplanationUrl });
  await waitFor(client, `document.querySelector('#messages .message--assistant')?.textContent.includes('root recursion target')
    && document.querySelector('#chat-selection').textContent.includes('source point')
    && document.querySelector('#composer').value === 'Continue this page explanation'`, 'page explanation transcript and draft restored');
  await evaluate(client, "chrome.storage.local.remove('scholia.chat-history.v1')");
  await client.send('Page.navigate', { url: `http://127.0.0.1:${staticPort}/dist/chrome/popup.html` });
  await waitFor(client, "document.readyState === 'complete' && document.querySelector('#quick-input')", 'toolbar Quick Chat boot');
  await waitFor(client, "document.querySelector('#quick-context-state')?.textContent === 'Compact'", 'toolbar compact-context default');
  await waitFor(client, "document.activeElement === document.querySelector('#quick-input')", 'toolbar Quick Chat keyboard focus');
  await client.send('Input.insertText', { text: 'Explain this screen from the toolbar.' });
  if (await evaluate(client, "document.querySelector('#quick-input').value") !== 'Explain this screen from the toolbar.') {
    throw new Error('Quick Chat must accept actual browser text entry, not only programmatically assigned drafts.');
  }
  if (await evaluate(client, `(() => {
    const input = document.querySelector('#quick-input');
    const clipboard = new DataTransfer();
    clipboard.setData('text/plain', ' Pasted text remains editable.');
    const event = new ClipboardEvent('paste', { clipboardData: clipboard, bubbles: true, cancelable: true });
    input.dispatchEvent(event);
    return event.defaultPrevented;
  })()`)) throw new Error('Quick Chat must allow normal text pastes.');
  await client.send('Input.insertText', { text: ' Pasted text remains editable.' });
  if (!await evaluate(client, "document.querySelector('#quick-input').value.endsWith(' Pasted text remains editable.')")) {
    throw new Error('Quick Chat must accept pasted text insertion without losing focus.');
  }
  await evaluate(client, "document.querySelector('#quick-compact').click()");
  await waitFor(client, `document.querySelector('#quick-context-state').textContent === 'Full'
    && document.querySelector('#quick-compact').getAttribute('aria-pressed') === 'false'`, 'toolbar full-context mode');
  await evaluate(client, "document.querySelector('#quick-none').click()");
  await waitFor(client, `document.querySelector('#quick-context-state').textContent === 'None'
    && document.querySelector('#quick-none').getAttribute('aria-pressed') === 'true'`, 'toolbar no-context mode');
  await evaluate(client, `(() => {
    document.querySelector('#quick-none').click();
    document.querySelector('#quick-compact').click();
    const input = document.querySelector('#quick-input');
    input.focus();
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', shiftKey: true, bubbles: true }));
  })()`);
  if (await evaluate(client, 'Boolean(globalThis.__scholiaLastChatPayload)')) {
    throw new Error('Shift+Enter unexpectedly sent the toolbar Quick Chat message.');
  }
  await evaluate(client, `document.querySelector('#quick-input')
    .dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))`);
  await waitFor(client, `document.querySelector('#quick-messages .quick-message.assistant')?.textContent.includes('root recursion target')
    && document.querySelector('#quick-messages .scholia-code')
    && document.querySelector('#quick-messages .scholia-reasoning')`, 'independent toolbar Quick Chat answer');
  if (!await evaluate(client, `globalThis.__scholiaLastChatPayload?.includeContext === true
      && globalThis.__scholiaLastChatPayload?.compactContext === true`)) {
    throw new Error('The toolbar Quick Chat did not send its compact context contract.');
  }
  await client.send('Page.navigate', { url: `http://127.0.0.1:${staticPort}/dist/chrome/panel.html` });
  await waitFor(client, "document.readyState === 'complete' && document.querySelector('#context-question')", 'panel boot');
  await waitFor(client, "document.querySelector('#current-title')?.textContent === 'Recursive smoke notes'", 'stubbed active source');
  const initialContextControl = JSON.parse(await evaluate(client, `JSON.stringify({
    checked: document.querySelector('#context-mode').checked,
    full: document.querySelector('#context-full').checked,
    none: document.querySelector('#context-none').checked,
    chatPressed: document.querySelector('#chat-context-mode').getAttribute('aria-pressed'),
    chatFullPressed: document.querySelector('#chat-context-full').getAttribute('aria-pressed')
  })`));
  if (!initialContextControl.checked || initialContextControl.full || initialContextControl.none
      || initialContextControl.chatPressed !== 'true' || initialContextControl.chatFullPressed !== 'false') {
    throw new Error(`Compact context did not default on: ${JSON.stringify(initialContextControl)}`);
  }
  await evaluate(client, "document.querySelector('#context-full').click()");
  await waitFor(client, `document.querySelector('#context-full').checked
    && !document.querySelector('#context-mode').checked
    && !document.querySelector('#site-scope').disabled
    && !document.querySelector('#deep-page').disabled
    && document.querySelector('#context-hint').textContent.includes('Full mode')`, 'full context after compact is disabled');
  await evaluate(client, "document.querySelector('#context-none').click()");
  await waitFor(client, `document.querySelector('#context-none').checked
    && document.querySelector('#site-scope').disabled
    && document.querySelector('#deep-page').disabled`, 'explicit no-context controls');
  await evaluate(client, "document.querySelector('#context-full').click()");
  await waitFor(client, `document.querySelector('#context-full').checked
    && !document.querySelector('#context-none').checked
    && !document.querySelector('#site-scope').disabled`, 'restored full context controls');
  await evaluate(client, "document.querySelector('#context-mode').click()");
  await waitFor(client, `document.querySelector('#context-mode').checked
    && !document.querySelector('#site-scope').disabled
    && document.querySelector('#chat-context-mode').getAttribute('aria-pressed') === 'true'`, 'enabled compact context controls');
  const sortedModelState = JSON.parse(await evaluate(client, `JSON.stringify(
    [...document.querySelectorAll('#model-select optgroup')].map((group) => {
      return { provider: group.label, ids: [...group.querySelectorAll('option')].map((option) => option.value.split('::').slice(1).join('::')) };
    })
  )`));
  const openAIOrder = sortedModelState.find((group) => /OpenAI$/.test(group.provider))?.ids || [];
  const anthropicOrder = sortedModelState.find((group) => /Anthropic$/.test(group.provider))?.ids || [];
  if (openAIOrder[0] !== 'gpt-6-astra' || openAIOrder.indexOf('gpt-6-sol') > openAIOrder.indexOf('gpt-6-luna')
      || anthropicOrder.indexOf('claude-opus-4-8') > anthropicOrder.indexOf('claude-opus-4-7'))
    throw new Error(`The model picker did not prioritize capacity and newest versions: ${JSON.stringify(sortedModelState)}`);
  await evaluate(client, "document.querySelector('#model-select').closest('.model-picker').querySelector('.model-picker-button').click()");
  await waitFor(client, `!document.querySelector('#model-select').closest('.model-picker').querySelector('.model-picker-popover').hidden
    && document.activeElement === document.querySelector('#model-select').closest('.model-picker').querySelector('.model-picker-search input')`, 'searchable model picker');
  const groupedModelState = JSON.parse(await evaluate(client, `JSON.stringify((() => {
    const picker = document.querySelector('#model-select').closest('.model-picker');
    const nativeGroups = [...document.querySelectorAll('#model-select optgroup')];
    const visibleGroups = [...picker.querySelectorAll('.model-picker-group')];
    return {
      nativeCount: nativeGroups.length,
      visibleCount: visibleGroups.length,
      headings: visibleGroups.map((group) => group.querySelector('.model-picker-group-label span')?.textContent),
      counts: visibleGroups.map((group) => group.querySelectorAll('.model-picker-option').length),
      countLabels: visibleGroups.map((group) => group.querySelector('.model-picker-group-count')?.textContent)
    };
  })())`));
  if (groupedModelState.visibleCount !== groupedModelState.nativeCount
      || groupedModelState.visibleCount < 2
      || groupedModelState.headings.some((heading) => !heading)
      || groupedModelState.counts.some((count, index) => !groupedModelState.countLabels[index]?.startsWith(String(count)))) {
    throw new Error(`The searchable picker lost its provider-delimited groups: ${JSON.stringify(groupedModelState)}`);
  }
  await evaluate(client, `(() => {
    const input = document.querySelector('#model-select').closest('.model-picker').querySelector('.model-picker-search input');
    input.value = 'opencode glm 5.3 flash';
    input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: 'glm 5.3 flash' }));
  })()`);
  await waitFor(client, `document.querySelector('#model-select').closest('.model-picker').querySelectorAll('.model-picker-option').length === 1
    && document.querySelector('#model-select').closest('.model-picker').querySelector('.model-picker-option-label')?.textContent === 'GLM 5.3 Flash'`, 'filtered model search result');
  await evaluate(client, `document.querySelector('#model-select').closest('.model-picker').querySelector('.model-picker-search input')
    .dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))`);
  await waitFor(client, "document.querySelector('#model-select').closest('.model-picker').querySelector('.model-picker-popover').hidden", 'close searchable model picker');
  await evaluate(client, `(() => {
    document.querySelector('#context-full').click();
    document.querySelector('#web-search').click();
    document.querySelector('#context-question').value = 'Explain the root topic.';
    document.querySelector('#context-question').dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', bubbles: true })
    );
  })()`);
  await waitFor(client, `document.querySelector('#messages .message--assistant')?.textContent.includes('root recursion target')
    && !document.querySelector('#messages .message--assistant .caret')
    && document.querySelector('#messages .message--assistant .katex-display')
    && document.querySelector('#messages .message--assistant .scholia-code')
    && document.querySelector('#messages .message--assistant .scholia-reasoning')`, 'root answer with rendered LaTeX, code, and reasoning');
  const renderedMathState = JSON.parse(await evaluate(client, `JSON.stringify((() => {
    const display = document.querySelector('#messages .message--assistant .katex-display');
    const math = display.querySelector('.katex');
    const bubble = display.closest('.bubble');
    const rect = display.getBoundingClientRect();
    return {
      width: rect.width,
      height: rect.height,
      fontRatio: parseFloat(getComputedStyle(math).fontSize) / parseFloat(getComputedStyle(bubble).fontSize),
      errors: document.querySelectorAll('#messages .message--assistant .katex-error').length,
      fallbacks: document.querySelectorAll('#messages .message--assistant .scholia-math-fallback').length,
      reasoningOpen: document.querySelector('#messages .message--assistant .scholia-reasoning').open,
      reasoningBorder: parseFloat(getComputedStyle(document.querySelector('#messages .message--assistant .scholia-reasoning')).borderTopWidth),
      codeBorder: parseFloat(getComputedStyle(document.querySelector('#messages .message--assistant .scholia-code')).borderTopWidth)
    };
  })())`));
  if (renderedMathState.width <= 0 || renderedMathState.height <= 0
      || renderedMathState.fontRatio < 0.98 || renderedMathState.fontRatio > 1.15
      || renderedMathState.errors || renderedMathState.fallbacks
      || renderedMathState.reasoningOpen || renderedMathState.reasoningBorder < 1
      || renderedMathState.codeBorder < 1) {
    throw new Error(`The representative model response was not rendered cleanly: ${JSON.stringify(renderedMathState)}`);
  }
  if (!await evaluate(client, "globalThis.__scholiaLastChatPayload?.webSearch === true")) {
    throw new Error('The sidebar Web search control did not enable search for the selected-context request.');
  }
  if (!await evaluate(client, `globalThis.__scholiaLastContextRequest?.maxChars > 6000
      && globalThis.__scholiaLastChatPayload?.includeContext === true
      && globalThis.__scholiaLastChatPayload?.compactContext === false
      && globalThis.__scholiaLastChatPayload?.context.length > 6000
      && globalThis.__scholiaLastChatPayload?.context.includes('FULL_SIDEBAR_CONTEXT')
      && document.querySelector('#chat-context-full').getAttribute('aria-pressed') === 'true'
      && document.querySelector('#context-state').textContent.includes('Full')`)) {
    throw new Error('The sidebar Full control did not send the larger per-chat context contract.');
  }
  if (!await evaluate(client, `globalThis.__scholiaChatGptRefreshes === 1
      && globalThis.__scholiaLastChatPayload?.useChatGptWebContext === true`)) {
    throw new Error('Quick Chat did not refresh and attach the configured ChatGPT context before its first request.');
  }
  if (!await evaluate(client, selectionExpression('#messages .message--assistant .bubble', 'root recursion target'))) {
    throw new Error('Could not select the root response text.');
  }
  await waitFor(client, "!document.querySelector('#response-explain').hidden", 'root Explain popup');
  const chatGptContextToggle = await evaluate(client, `JSON.stringify({
    hidden: document.querySelector('#response-explain-chatgpt').hidden,
    checked: document.querySelector('#response-explain-chatgpt-toggle').checked,
    label: document.querySelector('#response-explain-chatgpt').textContent.trim(),
    webHidden: document.querySelector('#response-explain-web-search').hidden,
    webChecked: document.querySelector('#response-explain-web-search-toggle').checked
  })`);
  const chatGptToggle = JSON.parse(chatGptContextToggle);
  if (chatGptToggle.hidden || !chatGptToggle.checked || !chatGptToggle.label.includes('Study project')
      || chatGptToggle.webHidden || !chatGptToggle.webChecked) {
    throw new Error(`Imported ChatGPT context was not offered for response selection: ${chatGptContextToggle}`);
  }
  await evaluate(client, "document.querySelector('#response-explain-send').click()");
  await waitFor(client, "document.querySelector('#response-window-messages .response-window-message--assistant')?.textContent.includes('child recursion target') && !document.querySelector('#response-window-messages .caret')", 'child answer');
  if (!await evaluate(client, 'globalThis.__scholiaLastChatPayload?.useChatGptWebContext === true && globalThis.__scholiaLastChatPayload?.webSearch === true')) {
    throw new Error('The selected-response request did not preserve its imported-context and Web search choices.');
  }
  await evaluate(client, `(() => {
    const root = document.querySelector('#response-window-messages .response-window-message--assistant .bubble');
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      if (!node.data.includes('child recursion target')) continue;
      node.parentElement.scrollIntoView({ block: 'center' });
      return true;
    }
    return false;
  })()`);
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  const parentScrollTop = await evaluate(client, "document.querySelector('#response-window-messages').scrollTop");
  if (!await evaluate(client, selectionExpression('#response-window-messages .response-window-message--assistant .bubble', 'child recursion target'))) {
    throw new Error('Could not select the child response text.');
  }
  await waitFor(client, "!document.querySelector('#response-explain').hidden", 'nested Explain popup');
  const popupAboveLayer = await evaluate(client, `Number(getComputedStyle(document.querySelector('#response-explain')).zIndex)
    > Number(getComputedStyle(document.querySelector('#response-window-backdrop')).zIndex)`);
  if (!popupAboveLayer) throw new Error('The recursive Explain popup is behind the response layer.');
  await evaluate(client, "document.querySelector('#response-explain-send').click()");
  await waitFor(client, "document.querySelector('#response-window-messages .response-window-message--assistant')?.textContent.includes('Recursive response selection completed') && !document.querySelector('#response-window-messages .caret')", 'grandchild answer');
  const depth = await evaluate(client, "document.querySelector('#response-window-depth').textContent");
  if (depth !== 'Explanation layer 2') throw new Error(`Unexpected recursive depth label: ${depth}`);
  await evaluate(client, "document.querySelector('#response-window-close').click()");
  await waitFor(client, "document.querySelector('#response-window-depth').textContent === 'Response explanation'", 'parent layer restoration');
  const restoredScrollTop = await evaluate(client, "document.querySelector('#response-window-messages').scrollTop");
  if (Math.abs(restoredScrollTop - parentScrollTop) > 4) {
    throw new Error(`Parent scroll position changed from ${parentScrollTop} to ${restoredScrollTop}.`);
  }
  await evaluate(client, `(() => {
    document.querySelector('#response-window-messages [data-edit-query="0"]').click();
    const editor = document.querySelector('#response-window-messages [data-query-editor="0"]');
    editor.value = 'Revised nested question';
    document.querySelector('#response-window-messages [data-save-query-edit="0"]').click();
  })()`);
  await waitFor(client, "document.querySelector('#response-window-messages .response-window-message--assistant')?.textContent.includes('Edited turn 4') && !document.querySelector('#response-window-messages .caret')", 'edited nested response');
  const nestedEditState = await evaluate(client, `JSON.stringify({
    rows: document.querySelectorAll('#response-window-messages .response-window-message').length,
    user: document.querySelector('#response-window-messages .response-window-message--user .query-copy')?.textContent,
    stale: document.querySelector('#response-window-messages').textContent.includes('child recursion target')
  })`);
  const nestedEdit = JSON.parse(nestedEditState);
  if (nestedEdit.rows !== 2 || nestedEdit.user !== 'Revised nested question' || nestedEdit.stale) {
    throw new Error(`Nested edit did not replace the stale branch: ${nestedEditState}`);
  }
  await evaluate(client, "document.querySelector('#response-window-close').click()");
  await waitFor(client, "document.querySelector('#response-window-backdrop').hidden", 'return to sidebar chat');
  await evaluate(client, `(() => {
    document.querySelector('#messages [data-edit-query="0"]').click();
    const editor = document.querySelector('#messages [data-query-editor="0"]');
    editor.value = 'Revised root question';
    document.querySelector('#messages [data-save-query-edit="0"]').click();
  })()`);
  await waitFor(client, "document.querySelector('#messages .message--assistant')?.textContent.includes('Edited turn 5') && !document.querySelector('#messages .caret')", 'edited sidebar response');
  const rootEditState = await evaluate(client, `JSON.stringify({
    rows: document.querySelectorAll('#messages .message').length,
    user: document.querySelector('#messages .message--user .query-copy')?.textContent,
    stale: document.querySelector('#messages').textContent.includes('root recursion target')
  })`);
  const rootEdit = JSON.parse(rootEditState);
  if (rootEdit.rows !== 2 || rootEdit.user !== 'Revised root question' || rootEdit.stale) {
    throw new Error(`Sidebar edit did not replace the stale branch: ${rootEditState}`);
  }
  await evaluate(client, `document.dispatchEvent(new KeyboardEvent('keydown', {
    key: 'f', ctrlKey: true, bubbles: true
  }))`);
  await waitFor(client, "!document.querySelector('#chat-search').hidden && document.activeElement === document.querySelector('#chat-search-input')", 'chat search shortcut');
  await evaluate(client, `(() => {
    const input = document.querySelector('#chat-search-input');
    input.value = 're';
    input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: 're' }));
  })()`);
  await waitFor(client, "document.querySelector('#chat-search-count').textContent === '1 / 2' && document.querySelectorAll('#messages .message.is-search-result').length === 2", 'sidebar search results');
  const firstSearchState = await evaluate(client, `JSON.stringify({
    current: document.querySelector('#messages .message.is-current-search-result')?.dataset.messageIndex,
    highlights: document.querySelectorAll('#messages mark[data-chat-search-match]').length
  })`);
  const firstSearch = JSON.parse(firstSearchState);
  if (firstSearch.current !== '0' || firstSearch.highlights < 2) {
    throw new Error(`Sidebar search did not highlight its first result: ${firstSearchState}`);
  }
  await evaluate(client, "document.querySelector('#chat-search-next').click()");
  await waitFor(client, "document.querySelector('#chat-search-count').textContent === '2 / 2' && document.querySelector('#messages .message.is-current-search-result')?.dataset.messageIndex === '1'", 'next sidebar search result');
  await evaluate(client, `document.querySelector('#chat-search-input').dispatchEvent(new KeyboardEvent('keydown', {
    key: 'Escape', bubbles: true
  }))`);
  await waitFor(client, "document.querySelector('#chat-search').hidden && !document.querySelector('#messages [data-chat-search-match]')", 'close sidebar search');

  const chatIdBeforeRegion = await evaluate(client, `JSON.parse(localStorage.getItem('__scholia_chrome_local_stub__'))['scholia.chat-history.v1'][0].id`);
  await evaluate(client, "document.querySelector('#attach-region').click()");
  await waitFor(client, "globalThis.__scholiaRuntimeMessages.includes('SCHOLIA_CAPTURE_ACTIVE_REGION')", 'direct page region selection request');
  await waitFor(client, `!document.querySelector('#composer-image').hidden
    && document.querySelectorAll('#messages .message').length === 2
    && document.activeElement === document.querySelector('#composer')`, 'region question draft');
  const regionDraftState = await evaluate(client, `JSON.stringify({
    label: document.querySelector('#composer-image-label').textContent,
    preview: document.querySelector('#composer-image-preview').src.startsWith('data:image/'),
    placeholder: document.querySelector('#composer').placeholder
  })`);
  const regionDraft = JSON.parse(regionDraftState);
  if (regionDraft.label !== 'Captured screen region'
      || !regionDraft.preview
      || !regionDraft.placeholder.includes('attached image')) {
    throw new Error(`The selected region did not become an editable image draft: ${regionDraftState}`);
  }
  await evaluate(client, `(() => {
    const composer = document.querySelector('#composer');
    composer.value = 'Which visual detail supports the conclusion?';
    document.querySelector('#composer-form').requestSubmit();
  })()`);
  await waitFor(client, `document.querySelectorAll('#messages .message').length === 4
    && document.querySelector('#messages .message--user .query-image')
    && document.querySelector('#composer-image').hidden
    && document.querySelector('#messages .message--assistant:last-child')?.textContent.includes('Edited turn 6')
    && !document.querySelector('#messages .message--assistant:last-child .caret')`, 'region appended to sidebar chat');
  const regionChatState = await evaluate(client, `JSON.stringify((() => {
    const stored = JSON.parse(localStorage.getItem('__scholia_chrome_local_stub__'))['scholia.chat-history.v1'];
    const payload = globalThis.__scholiaLastChatPayload;
    return {
      id: stored[0].id,
      chats: stored.length,
      rows: document.querySelectorAll('#messages .message').length,
      firstQuestion: document.querySelector('#messages .message--user .query-copy')?.textContent,
      lastQuestion: [...document.querySelectorAll('#messages .message--user .query-copy')].at(-1)?.textContent,
      imageTurns: [...document.querySelectorAll('#messages .message--user')].filter((row) => row.querySelector('.query-image')).length,
      requestTurns: payload.messages.length,
      lastTurnHasImage: payload.messages.at(-1)?.imageDataUrl?.startsWith('data:image/'),
      sourceImageChanged: Boolean(payload.imageDataUrl)
    };
  })())`);
  const regionChat = JSON.parse(regionChatState);
  if (regionChat.id !== chatIdBeforeRegion
      || regionChat.chats !== 1
      || regionChat.rows !== 4
      || regionChat.firstQuestion !== 'Revised root question'
      || regionChat.lastQuestion !== 'Which visual detail supports the conclusion?'
      || regionChat.imageTurns !== 1
      || regionChat.requestTurns !== 3
      || !regionChat.lastTurnHasImage
      || regionChat.sourceImageChanged) {
    throw new Error(`The selected region replaced the sidebar conversation instead of appending a turn: ${regionChatState}`);
  }

  await evaluate(client, `(async () => {
    const canvas = document.createElement('canvas');
    canvas.width = 24;
    canvas.height = 24;
    const context = canvas.getContext('2d');
    context.fillStyle = '#385d53';
    context.fillRect(0, 0, 24, 24);
    const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
    document.querySelector('#composer').value = 'How does this diagram change the answer?';
    document.querySelector('#attach-files').click();
    const transfer = new DataTransfer();
    transfer.items.add(new File([blob], 'diagram.png', { type: 'image/png' }));
    const input = document.querySelector('#composer-files input[type=file]');
    input.files = transfer.files;
    input.dispatchEvent(new Event('change', { bubbles: true }));
  })()`);
  await waitFor(client, `!document.querySelector('#composer-files').hidden
    && document.querySelector('#composer-files .scholia-file-chip')?.textContent.includes('diagram.png')
    && document.querySelector('#composer').value === 'How does this diagram change the answer?'
    && document.querySelectorAll('#messages .message').length === 4`, 'selected image question draft');
  await evaluate(client, "document.querySelector('#composer-files .scholia-file-chip button').click()");
  await waitFor(client, "document.querySelector('#composer-files').hidden", 'remove selected image draft');

  await evaluate(client, "document.querySelector('#expand-chat').click()");
  await waitFor(client, "globalThis.__scholiaCreatedTabUrl?.includes('/chat.html?chat=')", 'dedicated chat URL');
  const dedicatedChatUrl = await evaluate(client, 'globalThis.__scholiaCreatedTabUrl');
  await client.send('Page.navigate', { url: dedicatedChatUrl });
  await waitFor(client, `document.body.classList.contains('dedicated-chat')
    && document.body.classList.contains('is-chat-open')
    && !document.querySelector('#chat-view').hidden
    && !document.querySelector('#home-view').hidden
    && document.querySelector('#messages .message--assistant')?.textContent.includes('Edited turn 5')`, 'dedicated chat restoration');
  const dedicatedState = await evaluate(client, `JSON.stringify({
    path: location.pathname,
    title: document.title,
    rows: document.querySelectorAll('#messages .message').length,
    historyRows: document.querySelectorAll('#chat-history-list .history-row').length,
    expandHidden: document.querySelector('#expand-chat').hidden,
    chatColumn: getComputedStyle(document.querySelector('#chat-view')).gridColumnStart
  })`);
  const dedicated = JSON.parse(dedicatedState);
  if (dedicated.path !== '/dist/chrome/chat.html'
      || dedicated.rows !== 4
      || dedicated.historyRows < 1
      || !dedicated.expandHidden
      || dedicated.chatColumn !== '2') {
    throw new Error(`The dedicated extension chat did not restore its full-page layout: ${dedicatedState}`);
  }
  await evaluate(client, `(() => {
    const composer = document.querySelector('#composer');
    composer.value = 'Continue in the dedicated chat';
    document.querySelector('#composer-form').requestSubmit();
  })()`);
  await waitFor(client, "document.querySelectorAll('#messages .message').length === 6 && document.querySelector('#messages .message--assistant:last-child')?.textContent.includes('root recursion target') && !document.querySelector('#messages .message--assistant:last-child .caret')", 'dedicated chat continuation');

  if (!await evaluate(client, selectionExpression('#messages .message--assistant:last-child .bubble', 'root recursion target'))) {
    throw new Error('Could not select text for the explanation transfer.');
  }
  await waitFor(client, "!document.querySelector('#response-explain').hidden", 'explanation transfer selection');
  await evaluate(client, `(() => {
    document.querySelector('#response-explain-send').click();
    if (!document.querySelector('#response-window-move').disabled) throw new Error('Moving must wait for streaming to finish');
  })()`);
  await waitFor(client, "!document.querySelector('#response-window-move').disabled", 'explanation ready to move');
  await evaluate(client, `(() => {
    globalThis.__scholiaFailMove = true;
    document.querySelector('#response-window-composer').value = 'Keep this follow-up draft';
    document.querySelector('#response-window-move').click();
  })()`);
  await waitFor(client, "document.querySelector('#response-window-status').textContent === 'Test transfer failure' && !document.querySelector('#response-window-move').disabled", 'failed transfer remains retryable');
  if (!await evaluate(client, `!document.querySelector('#response-window-backdrop').hidden
    && document.querySelector('#response-window-composer').value === 'Keep this follow-up draft'
    && document.querySelectorAll('#messages .message').length === 6`)) {
    throw new Error('Failed transfer lost the explanation or parent conversation.');
  }
  await evaluate(client, `(() => {
    globalThis.__scholiaFailMove = false;
    globalThis.__scholiaCreatedTabUrl = '';
    document.querySelector('#response-window-move').click();
  })()`);
  await waitFor(client, "globalThis.__scholiaCreatedTabUrl?.includes('/chat.html?chat=') && document.querySelector('#response-window-backdrop').hidden", 'response explanation moved to chat');
  const movedExplanationUrl = await evaluate(client, 'globalThis.__scholiaCreatedTabUrl');
  await client.send('Page.navigate', { url: movedExplanationUrl });
  await waitFor(client, `document.querySelectorAll('#messages .message').length === 2
    && document.querySelector('#messages .message--assistant')?.textContent.includes('child recursion target')
    && document.querySelector('#chat-selection').textContent === 'root recursion target'
    && document.querySelector('#composer').value === 'Keep this follow-up draft'`, 'response explanation restored as a normal chat');
  await evaluate(client, "document.querySelector('#composer-form').requestSubmit()");
  await waitFor(client, `globalThis.__scholiaLastChatPayload?.parentContext.includes('Root answer')
    && globalThis.__scholiaLastChatPayload?.selection === 'root recursion target'
    && globalThis.__scholiaLastChatPayload?.messages.length === 3
    && !document.querySelector('#messages .caret')`, 'moved explanation continues with its parent context');

  if (process.argv.includes('--explanation-chat')) {
    console.log('Chromium explanation-to-chat smoke test passed (page and response popups, saved transcript, draft, parent context, continuation, streaming guard, and failed-transfer retry).');
    break smoke;
  }

  // A cold bridge must recover in the existing chat, preserving its transcript and draft.
  await evaluate(client, `(() => {
    globalThis.__scholiaBridgeUp = false;
    globalThis.__scholiaColdChatDocument = document;
    globalThis.__scholiaColdChatTranscript = document.querySelector('#messages').textContent;
    document.querySelector('#composer').value = 'Continue after starting Codex';
    const select = document.querySelector('#chat-model-select');
    select.value = [...select.options].find((option) => option.value.startsWith('codex:')).value;
    select.dispatchEvent(new Event('change', { bubbles: true }));
  })()`);
  await waitFor(client, `document.querySelector('#bridge-status').textContent.includes('offline')
    && !document.querySelector('#bridge-start').disabled`, 'cold Codex bridge in a live chat');
  const coldBridgeLaunches = await evaluate(client, `(() => {
    for (let i = 0; i < 5; i++) document.querySelector('#bridge-start').click();
    return document.querySelectorAll('iframe[data-smoke-bridge-url^="scholia-codex://start"]').length;
  })()`);
  if (coldBridgeLaunches !== 1) throw new Error('Live chat did not guard repeated Codex bridge launches.');
  await evaluate(client, 'globalThis.__scholiaBridgeUp = true');
  await waitFor(client, `document.querySelector('#bridge-status').textContent.includes('connected')
    && !document.querySelector('#bridge-start').disabled`, 'Codex startup detected without reloading');
  if (!await evaluate(client, `document === globalThis.__scholiaColdChatDocument
    && document.querySelector('#composer').value === 'Continue after starting Codex'
    && document.querySelector('#messages').textContent === globalThis.__scholiaColdChatTranscript`)) {
    throw new Error('Cold bridge recovery replaced the chat document, transcript, or draft.');
  }
  await evaluate(client, `(() => {
    globalThis.__scholiaBridgeUp = false;
    window.dispatchEvent(new Event('focus'));
  })()`);
  await waitFor(client, "document.querySelector('#bridge-status').textContent.includes('offline')", 'bridge stopped during live chat');
  await evaluate(client, 'globalThis.__scholiaBridgeUp = true');
  await waitFor(client, "document.querySelector('#bridge-status').textContent.includes('connected')", 'externally restarted bridge detected');
  await evaluate(client, "document.querySelector('#composer-form').requestSubmit()");
  await waitFor(client, `globalThis.__scholiaLastChatPayload?.provider === 'codex'
    && globalThis.__scholiaLastChatPayload?.messages.at(-1)?.content === 'Continue after starting Codex'
    && !document.querySelector('#messages .caret')`, 'live chat continues after Codex cold start');

  if (process.argv.includes('--chat-bridge')) {
    console.log('Chromium chat smoke passed (contained Codex model menu, guarded launch, cold bridge recovery, external restart, and transcript/draft preservation).');
    break smoke;
  }

  await client.send('Page.navigate', {
    url: `http://127.0.0.1:${staticPort}/dist/chrome/pdf-viewer.html`
  });
  await waitFor(client, "document.readyState === 'complete' && !document.querySelector('#error').hidden", 'PDF viewer file fallback');
  const wrapperResolutionState = await evaluate(client, `(async () => {
    const { fetchPdfDocument } = await import('/apps/chrome/src/pdf-context.js');
    const source = new URL('/__scholia-pdf-wrapper/report.pdf?utm_source=chat', location.href).href;
    const result = await fetchPdfDocument(source);
    return JSON.stringify({
      source,
      resolvedUrl: result.url,
      bytes: result.blob.size,
      prefix: await result.blob.slice(0, 8).text()
    });
  })()`);
  const wrapperResolution = JSON.parse(wrapperResolutionState);
  if (!wrapperResolution.resolvedUrl.endsWith('/__scholia-pdf-search-fixture.pdf')
      || wrapperResolution.bytes < 100
      || !wrapperResolution.prefix.startsWith('%PDF-')) {
    throw new Error(`The Chromium PDF loader did not resolve an HTML/raw-download wrapper: ${wrapperResolutionState}`);
  }
  await client.send('Page.navigate', {
    url: `http://127.0.0.1:${staticPort}/dist/chrome/pdf-viewer.html?source=smoke_pdf_source_123${process.argv.includes('--simulate-brave') ? '&simulate-brave=1' : ''}`
  });
  await waitFor(client, `document.readyState === 'complete'
    && document.querySelector('#document-title')?.textContent === 'Searchable PDF fixture'
    && document.querySelector('#error')?.hidden`, 'stored PDF source boot');
  await waitFor(client, `document.querySelector('.pdf-page[data-page-number="1"] canvas')
    && !document.querySelector('.pdf-page[data-page-number="1"] .pdf-page__surface').classList.contains('is-loading')`, 'first PDF page paint');
  await waitFor(client, `document.querySelector('.pdf-page[data-page-number="2"] canvas')
    && !document.querySelector('.pdf-page[data-page-number="2"] .pdf-page__surface').classList.contains('is-loading')`, 'adjacent PDF page prefetch');
  const paintedPdfCanvases = JSON.parse(await evaluate(client, `JSON.stringify(
    [...document.querySelectorAll('.pdf-page canvas')].map((canvas) => {
      const pixels = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data;
      for (let index = 0; index < pixels.length; index += 4) {
        if (pixels[index + 3] && (pixels[index] < 245 || pixels[index + 1] < 245 || pixels[index + 2] < 245)) return true;
      }
      return false;
    })
  )`));
  if (paintedPdfCanvases.length < 2 || paintedPdfCanvases.some((painted) => !painted)) {
    throw new Error(`PDF canvases were present but blank: ${JSON.stringify(paintedPdfCanvases)}`);
  }
  await waitFor(client, `document.querySelector('#page-number').value === '1'
    && document.querySelector('#page-total').textContent === '2'
    && !document.querySelector('#page-number').disabled`, 'editable PDF page counter');
  await evaluate(client, `(() => {
    const input = document.querySelector('#page-number');
    input.value = '2';
    document.querySelector('#page-count').requestSubmit();
  })()`);
  await waitFor(client, `document.querySelector('#page-number').value === '2'
    && document.querySelector('.pdf-page.is-current-page')?.dataset.pageNumber === '2'`, 'page-counter jump');
  await evaluate(client, `(() => {
    const input = document.querySelector('#page-number');
    input.value = '99';
    document.querySelector('#page-count').requestSubmit();
  })()`);
  await waitFor(client, "document.querySelector('#page-number').value === '2'", 'page-counter range clamp');
  await evaluate(client, `(() => {
    const input = document.querySelector('#page-number');
    input.value = '1';
    input.dispatchEvent(new Event('change', { bubbles: true }));
  })()`);
  await waitFor(client, `document.querySelector('#page-number').value === '1'
    && document.querySelector('.pdf-page.is-current-page')?.dataset.pageNumber === '1'`, 'page-counter change navigation');
  const zoomAnchorBefore = JSON.parse(await evaluate(client, `JSON.stringify((() => {
    const surface = document.querySelector('.pdf-page[data-page-number="1"] .pdf-page__surface');
    const toolbar = document.querySelector('.toolbar').getBoundingClientRect();
    const initial = surface.getBoundingClientRect();
    const readingLine = toolbar.bottom + 18;
    window.scrollTo({ top: window.scrollY + initial.top + initial.height * 0.4 - readingLine, behavior: 'auto' });
    const rect = surface.getBoundingClientRect();
    return { page: document.querySelector('#page-number').value, ratio: (readingLine - rect.top) / rect.height };
  })())`));
  await waitFor(client, "document.querySelector('#page-number').value === '1'", 'page one before zoom-anchor check');
  await evaluate(client, "document.querySelector('#zoom-in').click()");
  await waitFor(client, `document.querySelector('#zoom-label').selectedOptions[0].textContent === '115%'
    && document.querySelector('#page-number').value === '1'`, 'zoom without changing the active PDF page');
  await evaluate(client, 'new Promise((resolvePromise) => setTimeout(resolvePromise, 100))');
  const zoomAnchorAfter = JSON.parse(await evaluate(client, `JSON.stringify((() => {
    const rect = document.querySelector('.pdf-page[data-page-number="1"] .pdf-page__surface').getBoundingClientRect();
    const readingLine = document.querySelector('.toolbar').getBoundingClientRect().bottom + 18;
    return { page: document.querySelector('#page-number').value, ratio: (readingLine - rect.top) / rect.height };
  })())`));
  if (zoomAnchorBefore.page !== '1'
      || zoomAnchorAfter.page !== '1'
      || Math.abs(zoomAnchorBefore.ratio - zoomAnchorAfter.ratio) > 0.025) {
    throw new Error(`PDF zoom changed the page or reading anchor: ${JSON.stringify({ before: zoomAnchorBefore, after: zoomAnchorAfter })}`);
  }
  await evaluate(client, "document.querySelector('#zoom-out').click()");
  await waitFor(client, `document.querySelector('#zoom-label').selectedOptions[0].textContent === '100%'
    && document.querySelector('#page-number').value === '1'`, 'restore zoom without changing the active PDF page');
  await evaluate(client, 'window.scrollTo(0, 0)');
  await waitFor(client, "document.querySelector('#page-number').value === '1'", 'restore first PDF page after zoom-anchor check');
  await evaluate(client, `(() => {
    const reader = document.querySelector('#reader-layout').getBoundingClientRect();
    const viewer = document.querySelector('#viewer').getBoundingClientRect();
    globalThis.__scholiaPdfBeforeChat = { readerWidth: reader.width, viewerWidth: viewer.width };
    document.querySelector('#open-chat').click();
  })()`);
  await waitFor(client, `!document.querySelector('#pdf-chat').hidden
    && document.querySelector('#open-chat').getAttribute('aria-expanded') === 'true'
    && !document.querySelector('#pdf-chat iframe')
    && document.querySelector('#pdf-chat-content').shadowRoot?.querySelector('#home-view')`, 'in-viewer PDF chat overlay');
  const pdfChatState = JSON.parse(await evaluate(client, `JSON.stringify((() => {
    const chat = document.querySelector('#pdf-chat');
    const reader = document.querySelector('#reader-layout').getBoundingClientRect();
    const viewer = document.querySelector('#viewer').getBoundingClientRect();
    const position = getComputedStyle(chat).position;
    return {
      position,
      readerWidthBefore: globalThis.__scholiaPdfBeforeChat.readerWidth,
      readerWidthAfter: reader.width,
      viewerWidthBefore: globalThis.__scholiaPdfBeforeChat.viewerWidth,
      viewerWidthAfter: viewer.width,
      panelReady: Boolean(document.querySelector('#pdf-chat-content').shadowRoot?.querySelector('#home-view')),
      closeFocused: document.activeElement === document.querySelector('#pdf-chat-close')
    };
  })())`));
  if (pdfChatState.position !== 'fixed'
      || pdfChatState.readerWidthAfter >= pdfChatState.readerWidthBefore
      || pdfChatState.viewerWidthAfter >= pdfChatState.viewerWidthBefore
      || !pdfChatState.panelReady
      || !pdfChatState.closeFocused) {
    throw new Error(`PDF chat failed to reserve space beside the reader: ${JSON.stringify(pdfChatState)}`);
  }
  await evaluate(client, "document.querySelector('#pdf-chat-close').click()");
  await waitFor(client, `document.querySelector('#pdf-chat').hidden
    && document.querySelector('#open-chat').getAttribute('aria-expanded') === 'false'
    && document.activeElement === document.querySelector('#open-chat')`, 'close in-viewer PDF chat overlay');
  await waitFor(client, "globalThis.__scholiaShadow?.querySelector('[data-move-chat]')", 'PDF Quick Chat controls');
  await evaluate(client, `(() => {
    globalThis.__scholiaCreatedTabUrl = '';
    for (const listener of chrome.runtime.onMessage.listeners) {
      listener({ type: 'SCHOLIA_EXPLAIN_TEXT', text: 'PDF-specific sidebar transfer' }, {}, () => {});
    }
  })()`);
  await waitFor(client, `!globalThis.__scholiaShadow.querySelector('[data-backdrop]').hidden
    && !globalThis.__scholiaShadow.querySelector('[data-move-chat]').disabled`, 'PDF quick explanation ready to move');
  await evaluate(client, `(() => {
    const shadow = globalThis.__scholiaShadow;
    shadow.querySelector('[data-composer]').value = 'Continue in this PDF only';
    shadow.querySelector('[data-move-chat]').click();
  })()`);
  await waitFor(client, `!document.querySelector('#pdf-chat').hidden
    && globalThis.__scholiaShadow.querySelector('[data-backdrop]').hidden
    && document.querySelector('#pdf-chat-content').shadowRoot?.querySelector('#composer')?.value === 'Continue in this PDF only'
    && !document.querySelector('#pdf-chat-content').shadowRoot?.querySelector('#chat-view')?.hidden`, 'Quick Chat restored inside its PDF sidebar');
  const pdfTransfer = JSON.parse(await evaluate(client, `(async () => {
    const root = document.querySelector('#pdf-chat-content').shadowRoot;
    const before = root.querySelector('#messages').textContent;
    const sourceReads = globalThis.__scholiaRuntimeMessages.filter(type => type === 'SCHOLIA_GET_ACTIVE_SOURCE:pdf').length;
    const navigation = { id: 'foreign-navigation', createdAt: Date.now(), view: 'new' };
    for (const listener of chrome.storage.onChanged.listeners) {
      listener({ 'scholia.panel-navigation.v1': { newValue: navigation } }, 'session');
    }
    for (const listener of chrome.tabs.onActivated.listeners) listener({ tabId: 999, windowId: 999 });
    await new Promise(resolve => setTimeout(resolve, 200));
    return JSON.stringify({ openedTab: globalThis.__scholiaCreatedTabUrl,
      stayedInChat: !root.querySelector('#chat-view').hidden,
      preservedMessages: before === root.querySelector('#messages').textContent,
      stayedOnSource: sourceReads === globalThis.__scholiaRuntimeMessages.filter(type => type === 'SCHOLIA_GET_ACTIVE_SOURCE:pdf').length });
  })()`));
  if (pdfTransfer.openedTab || !pdfTransfer.stayedInChat || !pdfTransfer.preservedMessages || !pdfTransfer.stayedOnSource) {
    throw new Error('PDF sidebar transfer escaped its owning view: ' + JSON.stringify(pdfTransfer));
  }
  const pdfChatInteractions = JSON.parse(await evaluate(client, `JSON.stringify((() => {
    const host = document.querySelector('#pdf-chat-content');
    const root = host.shadowRoot;
    const composer = root.querySelector('#composer');
    const messageCount = root.querySelectorAll('#messages .message').length;
    composer.focus();
    composer.dispatchEvent(new KeyboardEvent('keydown', { key: 'f', ctrlKey: true, bubbles: true, composed: true, cancelable: true }));
    const localSearch = !root.querySelector('#chat-search').hidden && document.querySelector('#pdf-search').hidden;
    root.querySelector('#chat-search-close').click();
    globalThis.__scholiaPdfChatExpectedCount = messageCount + 2;
    root.querySelector('#composer-form').requestSubmit();
    return { localSearch, noFrame: !host.querySelector('iframe') && !root.querySelector('iframe'),
      noBrowserSidebar: !globalThis.__scholiaSidePanelRequest,
      scopedSource: globalThis.__scholiaRuntimeMessages.includes('SCHOLIA_GET_ACTIVE_SOURCE:pdf') };
  })())`));
  if (Object.values(pdfChatInteractions).some(value => !value)) {
    throw new Error('Direct PDF chat integration failed: ' + JSON.stringify(pdfChatInteractions));
  }
  await waitFor(client, `document.querySelector('#pdf-chat-content').shadowRoot.querySelectorAll('#messages .message').length >= globalThis.__scholiaPdfChatExpectedCount
    && !document.querySelector('#pdf-chat-content').shadowRoot.querySelector('#messages .caret')`, 'follow-up in direct PDF chat');
  await evaluate(client, "document.querySelector('#pdf-chat-close').click()");
  await evaluate(client, "document.querySelector('#open-chat').click()");
  await waitFor(client, `!document.querySelector('#pdf-chat').hidden
    && document.querySelector('#pdf-chat-content').shadowRoot.querySelectorAll('#messages .message').length >= globalThis.__scholiaPdfChatExpectedCount`, 'reopen same PDF chat');
  if (process.env.SCHOLIA_PDF_CHAT_SCREENSHOT) {
    const screenshot = await client.send('Page.captureScreenshot', { format: 'png' });
    await writeFile(process.env.SCHOLIA_PDF_CHAT_SCREENSHOT, Buffer.from(screenshot.data, 'base64'));
  }
  await evaluate(client, "document.querySelector('#pdf-chat-close').click()");
  if (process.argv.includes('--pdf-chat')) {
    console.log('Chromium PDF chat smoke passed (direct reader UI, blocked-frame simulation, transcript/draft transfer, follow-ups, local search, reopen, and per-window isolation).');
    break smoke;
  }
  await evaluate(client, `(() => {
    globalThis.__scholiaPrintCapture = null;
    window.print = () => {
      globalThis.__scholiaPrintCapture = {
        calls: (globalThis.__scholiaPrintCapture?.calls || 0) + 1,
        pages: document.querySelectorAll('#print-pages .printed-page').length,
        images: [...document.querySelectorAll('#print-pages img')].map((image) => ({
          loaded: image.complete && image.naturalWidth > 0,
          alt: image.alt
        })),
        printing: document.body.dataset.pdfPrinting === 'true',
        pageRule: [...document.querySelectorAll('style[data-scholia-pdf-print-page]')]
          .map((style) => style.textContent).join(' ')
      };
    };
    document.querySelector('#print-pdf').click();
  })()`);
  await waitFor(client, "globalThis.__scholiaPrintCapture?.calls === 1", 'PDF print preparation');
  const pdfPrintState = JSON.parse(await evaluate(client, 'JSON.stringify(globalThis.__scholiaPrintCapture)'));
  if (pdfPrintState.pages !== 2
      || pdfPrintState.images.length !== 2
      || pdfPrintState.images.some((image) => !image.loaded)
      || pdfPrintState.images.map((image) => image.alt).join('|') !== 'PDF page 1|PDF page 2'
      || !pdfPrintState.printing
      || !pdfPrintState.pageRule.includes('@page')) {
    throw new Error(`The PDF print action did not prepare every page before opening Chrome print preview: ${JSON.stringify(pdfPrintState)}`);
  }
  await waitFor(client, `!document.body.hasAttribute('data-pdf-printing')
    && document.querySelector('#print-pages').childElementCount === 0
    && !document.querySelector('#print-pdf').disabled`, 'PDF print cleanup');
  await waitFor(client, `!document.querySelector('#outline-toggle').disabled
    && document.querySelector('#outline-status').textContent === '3 sections'
    && document.querySelectorAll('.pdf-outline-page:not(:empty)').length === 3`, 'PDF table of contents');
  const closedPdfLayoutState = await evaluate(client, `JSON.stringify((() => {
    const layout = document.querySelector('#reader-layout').getBoundingClientRect();
    const viewer = document.querySelector('#viewer').getBoundingClientRect();
    const page = document.querySelector('.pdf-page__surface').getBoundingClientRect();
    return {
      layoutLeft: layout.left,
      layoutWidth: layout.width,
      viewerLeft: viewer.left,
      viewerWidth: viewer.width,
      viewerCenter: viewer.left + viewer.width / 2,
      pageCenter: page.left + page.width / 2
    };
  })())`);
  const closedPdfLayout = JSON.parse(closedPdfLayoutState);
  if (Math.abs(closedPdfLayout.viewerLeft - closedPdfLayout.layoutLeft) > 1
      || Math.abs(closedPdfLayout.viewerWidth - closedPdfLayout.layoutWidth) > 1
      || Math.abs(closedPdfLayout.viewerCenter - closedPdfLayout.pageCenter) > 1) {
    throw new Error(`The closed PDF outline left the page in the sidebar grid column: ${closedPdfLayoutState}`);
  }
  await evaluate(client, "document.querySelector('#view-toggle').click()");
  await waitFor(client, `!document.querySelector('#pdf-view-menu').hidden
    && document.querySelector('#view-toggle').getAttribute('aria-expanded') === 'true'`, 'open PDF view menu');
  await evaluate(client, "document.querySelector('[data-pdf-zoom=\"width\"]').click()");
  await waitFor(client, `document.querySelector('#zoom-label').value === 'width'
    && document.querySelector('[data-pdf-zoom="width"]').getAttribute('aria-checked') === 'true'
    && document.querySelector('#pdf-view-menu').hidden
    && Math.abs(document.querySelector('.pdf-page[data-page-number="1"] .pdf-page__surface').getBoundingClientRect().width
      - (document.querySelector('#viewer').clientWidth
        - parseFloat(getComputedStyle(document.querySelector('#viewer')).paddingLeft)
        - parseFloat(getComputedStyle(document.querySelector('#viewer')).paddingRight))) < 4`, 'PDF fit-width zoom');
  await evaluate(client, `(() => {
    const zoom = document.querySelector('#zoom-label');
    zoom.value = 'page';
    zoom.dispatchEvent(new Event('change', { bubbles: true }));
  })()`);
  await waitFor(client, `document.querySelector('#zoom-label').value === 'page'
    && document.querySelector('.pdf-page[data-page-number="1"] .pdf-page__surface').getBoundingClientRect().height
      <= innerHeight - document.querySelector('.toolbar').getBoundingClientRect().height - 46`, 'PDF fit-page zoom');
  await evaluate(client, `(() => {
    const zoom = document.querySelector('#zoom-label');
    zoom.value = 'auto';
    zoom.dispatchEvent(new Event('change', { bubbles: true }));
  })()`);
  await waitFor(client, "document.querySelector('#zoom-label').value === 'auto'", 'PDF automatic zoom');
  await evaluate(client, `(() => {
    const zoom = document.querySelector('#zoom-label');
    zoom.value = '1';
    zoom.dispatchEvent(new Event('change', { bubbles: true }));
  })()`);
  await waitFor(client, `document.querySelector('#zoom-label').value === '1'
    && document.querySelector('#zoom-label').selectedOptions[0].textContent === '100%'`, 'PDF percentage zoom');

  await evaluate(client, "document.querySelector('#view-toggle').click()");
  await waitFor(client, "!document.querySelector('#pdf-view-menu').hidden", 'reopen PDF view menu for single-page layout');
  await evaluate(client, "document.querySelector('[data-pdf-layout=\"page\"]').click()");
  await waitFor(client, `document.querySelector('#pages').classList.contains('is-single-page')
    && !document.querySelector('#pages').classList.contains('is-spread-view')
    && document.querySelector('[data-pdf-layout="page"]').getAttribute('aria-checked') === 'true'
    && document.querySelector('.pdf-page[data-page-number="1"]').getBoundingClientRect().height > 0
    && document.querySelector('.pdf-page[data-page-number="2"]').getBoundingClientRect().height === 0`, 'single-page PDF layout');
  await evaluate(client, `(() => {
    const button = document.querySelector('#view-toggle');
    button.focus();
    button.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }));
  })()`);
  await waitFor(client, `document.querySelector('#page-number').value === '2'
    && document.querySelector('.pdf-page[data-page-number="1"]').getBoundingClientRect().height === 0
    && document.querySelector('.pdf-page[data-page-number="2"]').getBoundingClientRect().height > 0`, 'right-arrow navigation in single-page layout');
  await evaluate(client, `document.querySelector('#view-toggle').dispatchEvent(
    new KeyboardEvent('keydown', { key: 'ArrowLeft', bubbles: true })
  )`);
  await waitFor(client, `document.querySelector('#page-number').value === '1'
    && document.querySelector('.pdf-page[data-page-number="1"]').getBoundingClientRect().height > 0
    && document.querySelector('.pdf-page[data-page-number="2"]').getBoundingClientRect().height === 0`, 'left-arrow navigation in single-page layout');
  await evaluate(client, `(() => {
    document.querySelector('#page-number').value = '2';
    document.querySelector('#page-count').requestSubmit();
  })()`);
  await waitFor(client, `document.querySelector('#page-number').value === '2'
    && document.querySelector('.pdf-page[data-page-number="2"]').getBoundingClientRect().height > 0`, 'second page before spread-layout anchor check');

  await evaluate(client, "document.querySelector('#view-toggle').click()");
  await waitFor(client, "!document.querySelector('#pdf-view-menu').hidden", 'reopen PDF view menu for spread layout');
  await evaluate(client, "document.querySelector('[data-pdf-layout=\"spread\"]').click()");
  await waitFor(client, `document.querySelector('#pages').classList.contains('is-spread-view')
    && !document.querySelector('#pages').classList.contains('is-single-page')
    && document.querySelector('#page-number').value === '2'
    && document.querySelector('[data-pdf-layout="spread"]').getAttribute('aria-checked') === 'true'
    && Number.parseInt(document.querySelector('#zoom-label').selectedOptions[0].textContent, 10) < 100
    && !document.querySelector('.pdf-page[data-page-number="1"] .pdf-page__surface').classList.contains('is-loading')
    && !document.querySelector('.pdf-page[data-page-number="2"] .pdf-page__surface').classList.contains('is-loading')
    && Math.abs(document.querySelector('.pdf-page[data-page-number="1"]').getBoundingClientRect().top
      - document.querySelector('.pdf-page[data-page-number="2"]').getBoundingClientRect().top) < 1`, 'two-page PDF spread');
  const pdfSpreadState = await evaluate(client, `JSON.stringify((() => {
    const viewer = document.querySelector('#viewer').getBoundingClientRect();
    const firstPage = document.querySelector('.pdf-page[data-page-number="1"]');
    const secondPage = document.querySelector('.pdf-page[data-page-number="2"]');
    const first = firstPage.querySelector('.pdf-page__surface').getBoundingClientRect();
    const second = secondPage.querySelector('.pdf-page__surface').getBoundingClientRect();
    const firstShell = firstPage.getBoundingClientRect();
    const secondShell = secondPage.getBoundingClientRect();
    return {
      firstLeft: first.left,
      firstRight: first.right,
      secondLeft: second.left,
      secondRight: second.right,
      gutter: second.left - first.right,
      firstShellWidth: firstShell.width,
      firstSurfaceWidth: first.width,
      secondShellWidth: secondShell.width,
      secondSurfaceWidth: second.width,
      sameSpreadRow: firstPage.parentElement === secondPage.parentElement
        && firstPage.parentElement.classList.contains('pdf-spread'),
      viewerLeft: viewer.left,
      viewerRight: viewer.right,
      zoom: document.querySelector('#zoom-label').selectedOptions[0].textContent
    };
  })())`);
  const pdfSpread = JSON.parse(pdfSpreadState);
  if (pdfSpread.firstLeft < pdfSpread.viewerLeft
      || pdfSpread.secondRight > pdfSpread.viewerRight
      || pdfSpread.secondLeft <= pdfSpread.firstRight
      || Math.abs(pdfSpread.gutter - 8) > 1
      || Math.abs(pdfSpread.firstShellWidth - pdfSpread.firstSurfaceWidth) > 1
      || Math.abs(pdfSpread.secondShellWidth - pdfSpread.secondSurfaceWidth) > 1
      || !pdfSpread.sameSpreadRow
      || Number.parseInt(pdfSpread.zoom, 10) >= 100) {
    throw new Error(`The two-page PDF spread did not fit beside itself: ${pdfSpreadState}`);
  }
  const mixedSpreadState = await evaluate(client, `JSON.stringify((() => {
    const fixture = document.createElement('div');
    fixture.className = 'pages is-spread-view';
    fixture.style.cssText = 'position:fixed;left:0;top:0;width:1500px;visibility:hidden;pointer-events:none';
    const createRow = (width) => {
      const row = document.createElement('div');
      row.className = 'pdf-spread';
      for (let index = 0; index < 2; index += 1) {
        const page = document.createElement('section');
        page.className = 'pdf-page';
        page.style.width = width + 'px';
        const surface = document.createElement('div');
        surface.className = 'pdf-page__surface';
        surface.style.cssText = 'width:' + width + 'px;height:100px';
        page.append(surface);
        row.append(page);
      }
      return row;
    };
    const narrowRow = createRow(420);
    const wideRow = createRow(650);
    fixture.append(narrowRow, wideRow);
    document.body.append(fixture);
    const [first, second] = [...narrowRow.children].map((page) => page.getBoundingClientRect());
    const result = {
      gutter: second.left - first.right,
      rowDisplay: getComputedStyle(narrowRow).display,
      rowGap: getComputedStyle(narrowRow).columnGap
    };
    fixture.remove();
    return result;
  })())`);
  const mixedSpread = JSON.parse(mixedSpreadState);
  if (Math.abs(mixedSpread.gutter - 8) > 1
      || mixedSpread.rowDisplay !== 'flex'
      || mixedSpread.rowGap !== '8px') {
    throw new Error(`A wider PDF spread changed another row's center gutter: ${mixedSpreadState}`);
  }
  await evaluate(client, "document.querySelector('#view-toggle').click()");
  await waitFor(client, "!document.querySelector('#pdf-view-menu').hidden", 'reopen PDF view menu for continuous layout');
  await evaluate(client, "document.querySelector('[data-pdf-layout=\"continuous\"]').click()");
  await waitFor(client, `!document.querySelector('#pages').classList.contains('is-spread-view')
    && !document.querySelector('#pages').classList.contains('is-single-page')
    && document.querySelector('#page-number').value === '2'
    && document.querySelector('[data-pdf-layout="continuous"]').getAttribute('aria-checked') === 'true'
    && document.querySelector('#zoom-label').selectedOptions[0].textContent === '100%'
    && document.querySelector('.pdf-page[data-page-number="2"]').getBoundingClientRect().top
      > document.querySelector('.pdf-page[data-page-number="1"]').getBoundingClientRect().bottom`, 'restore continuous PDF layout');
  await evaluate(client, `(() => {
    document.querySelector('#page-number').value = '1';
    document.querySelector('#page-count').requestSubmit();
  })()`);
  await waitFor(client, "document.querySelector('#page-number').value === '1'", 'restore first page after layout-anchor check');
  await evaluate(client, "document.querySelector('#outline-toggle').click()");
  await waitFor(client, `!document.querySelector('#pdf-outline').hidden
    && document.querySelectorAll('#outline-tree .pdf-outline-title').length === 3
    && document.querySelector('#outline-tree [aria-current="location"]')`, 'open PDF table of contents');
  const pdfOutlineState = await evaluate(client, `JSON.stringify({
    titles: [...document.querySelectorAll('#outline-tree .pdf-outline-title')].map((item) => item.textContent),
    pages: [...document.querySelectorAll('#outline-tree .pdf-outline-page')].map((item) => item.textContent),
    nestedLists: document.querySelectorAll('#outline-tree .pdf-outline-list .pdf-outline-list').length,
    panelWidth: document.querySelector('#pdf-outline').getBoundingClientRect().width,
    viewerWidth: document.querySelector('#viewer').getBoundingClientRect().width,
    viewportWidth: innerWidth
  })`);
  const pdfOutline = JSON.parse(pdfOutlineState);
  if (pdfOutline.titles.join('|') !== 'Introduction|Study sections|Results'
      || pdfOutline.pages.join('|') !== '1|1|2'
      || pdfOutline.nestedLists !== 1
      || pdfOutline.panelWidth < 250
      || pdfOutline.viewerWidth >= pdfOutline.viewportWidth) {
    throw new Error(`The PDF table of contents was not rendered beside the document: ${pdfOutlineState}`);
  }
  await evaluate(client, "document.querySelector('#outline-tree .pdf-outline-disclosure').click()");
  await waitFor(client, "document.querySelector('#outline-tree .pdf-outline-list .pdf-outline-list').hidden", 'collapse PDF outline branch');
  await evaluate(client, `(() => {
    document.querySelector('#outline-tree .pdf-outline-disclosure').click();
    [...document.querySelectorAll('#outline-tree .pdf-outline-link')]
      .find((item) => item.textContent.includes('Results')).click();
  })()`);
  await waitFor(client, `document.querySelector('#page-number').value === '2'
    && document.querySelector('#outline-tree [aria-current="location"] .pdf-outline-title')?.textContent === 'Results'`, 'PDF outline destination');
  await evaluate(client, "document.querySelector('#outline-close').click()");
  await waitFor(client, `document.querySelector('#pdf-outline').hidden
    && document.activeElement === document.querySelector('#outline-toggle')
    && Math.abs(document.querySelector('#viewer').getBoundingClientRect().width
      - document.querySelector('#reader-layout').getBoundingClientRect().width) < 1`, 'close PDF table of contents');
  await waitFor(client, "document.querySelectorAll('.pdf-page[data-page-number=\"1\"] .annotationLayer .linkAnnotation a[aria-label]').length === 2", 'PDF link annotations');
  const pdfLinkState = await evaluate(client, `JSON.stringify((() => {
    const links = [...document.querySelectorAll('.pdf-page[data-page-number="1"] .annotationLayer .linkAnnotation a')];
    const external = links.find((link) => link.href.startsWith('https://linkinghub.elsevier.com/'));
    const internal = links.find((link) => link.closest('[data-internal-link]'));
    return {
      external: external && { href: external.href, target: external.target, rel: external.rel, label: external.getAttribute('aria-label') },
      internalLabel: internal?.getAttribute('aria-label') || ''
    };
  })())`);
  const pdfLinks = JSON.parse(pdfLinkState);
  if (pdfLinks.external?.href !== 'https://linkinghub.elsevier.com/retrieve/pii/S0123456789012345'
      || pdfLinks.external.target !== '_blank'
      || !pdfLinks.external.rel.includes('noopener')
      || !pdfLinks.external.rel.includes('noreferrer')
      || !pdfLinks.external.label.includes('linkinghub.elsevier.com')
      || pdfLinks.internalLabel !== 'Go to linked location in this PDF') {
    throw new Error(`PDF links were not rendered with safe Chrome-compatible navigation: ${pdfLinkState}`);
  }
  await evaluate(client, `document.querySelector('.pdf-page[data-page-number="1"] .annotationLayer [data-internal-link] a').click()`);
  await waitFor(client, "document.querySelector('#page-number').value === '2'", 'internal PDF destination');
  await waitFor(client, "document.readyState === 'complete' && document.querySelector('#document-status')?.textContent.includes('context ready')", 'Scholia PDF viewer');
  await evaluate(client, `document.dispatchEvent(new KeyboardEvent('keydown', {
    key: 'f', ctrlKey: true, bubbles: true
  }))`);
  await waitFor(client, "!document.querySelector('#pdf-search').hidden && document.activeElement === document.querySelector('#search-input')", 'PDF search shortcut');
  await evaluate(client, `(() => {
    const input = document.querySelector('#search-input');
    input.value = 'needle phrase';
    input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: 'needle phrase' }));
  })()`);
  await waitFor(client, "document.querySelector('#search-count').textContent === '1 / 2' && document.querySelector('.pdf-page[data-page-number=\"1\"] .pdf-search-highlight.is-current')", 'first PDF search result');
  const firstPdfSearch = await evaluate(client, `JSON.stringify({
    page: document.querySelector('.pdf-search-highlight.is-current')?.closest('.pdf-page')?.dataset.pageNumber,
    text: document.querySelector('.pdf-search-highlight.is-current')?.textContent,
    background: getComputedStyle(document.querySelector('.pdf-search-highlight.is-current')).backgroundColor
  })`);
  const firstPdfResult = JSON.parse(firstPdfSearch);
  if (firstPdfResult.page !== '1' || firstPdfResult.text !== 'needle phrase' || firstPdfResult.background === 'rgba(0, 0, 0, 0)') {
    throw new Error(`The first PDF search result was not visibly highlighted: ${firstPdfSearch}`);
  }
  await evaluate(client, "document.querySelector('#search-next').click()");
  await waitFor(client, "document.querySelector('#search-count').textContent === '2 / 2' && document.querySelector('.pdf-page[data-page-number=\"2\"] .pdf-search-highlight.is-current')", 'next PDF search result');
  await evaluate(client, `(() => {
    const mode = document.querySelector('#search-mode');
    mode.value = 'semantic';
    mode.dispatchEvent(new Event('change', { bubbles: true }));
    const input = document.querySelector('#search-input');
    input.value = 'How do plants store solar power?';
    input.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText' }));
  })()`);
  await waitFor(client, `document.querySelector('#search-count').textContent.endsWith('pages')
    && document.querySelector('.pdf-page[data-page-number="1"] .pdf-search-highlight.is-current')`, 'semantic PDF search result');
  await evaluate(client, `document.querySelector('#search-input').dispatchEvent(new KeyboardEvent('keydown', {
    key: 'Escape', bubbles: true
  }))`);
  await waitFor(client, "document.querySelector('#pdf-search').hidden && !document.querySelector('.pdf-search-highlight')", 'close PDF search');
  await evaluate(client, `(() => {
    window.scrollTo(0, 0);
    document.querySelector('#zoom-in').focus();
  })()`);
  await waitFor(client, "document.querySelector('#page-number').value === '1'", 'first PDF page before arrow navigation');
  await evaluate(client, 'new Promise((resolvePromise) => setTimeout(resolvePromise, 150))');
  await client.send('Input.dispatchKeyEvent', {
    type: 'keyDown', key: 'ArrowRight', code: 'ArrowRight', modifiers: 0, windowsVirtualKeyCode: 39, nativeVirtualKeyCode: 39
  });
  await client.send('Input.dispatchKeyEvent', {
    type: 'keyUp', key: 'ArrowRight', code: 'ArrowRight', modifiers: 0, windowsVirtualKeyCode: 39, nativeVirtualKeyCode: 39
  });
  await waitFor(client, "document.querySelector('#page-number').value === '2' && window.scrollY > 100", 'right-arrow PDF page navigation from toolbar focus');
  await client.send('Input.dispatchKeyEvent', {
    type: 'keyDown', key: 'ArrowLeft', code: 'ArrowLeft', modifiers: 0, windowsVirtualKeyCode: 37, nativeVirtualKeyCode: 37
  });
  await client.send('Input.dispatchKeyEvent', {
    type: 'keyUp', key: 'ArrowLeft', code: 'ArrowLeft', modifiers: 0, windowsVirtualKeyCode: 37, nativeVirtualKeyCode: 37
  });
  await waitFor(client, "document.querySelector('#page-number').value === '1' && window.scrollY < 100", 'left-arrow PDF page navigation from toolbar focus');
  await evaluate(client, `(() => {
    window.scrollTo(0, 0);
    document.dispatchEvent(new KeyboardEvent('keydown', {
      key: 'PageDown', bubbles: true, cancelable: true
    }));
  })()`);
  await waitFor(client, 'window.scrollY > 100', 'PDF keyboard page scrolling');
  await evaluate(client, `(() => {
    if (document.documentElement.dataset.theme !== 'dark') document.querySelector('#theme-toggle').click();
  })()`);
  await waitFor(client, "document.documentElement.dataset.theme === 'dark'", 'PDF dark interface');
  const darkPdfState = await evaluate(client, `JSON.stringify({
    surface: getComputedStyle(document.querySelector('.pdf-page__surface')).backgroundColor,
    filters: [...document.querySelectorAll('.pdf-page canvas')].map((canvas) => getComputedStyle(canvas).filter),
    paper: getComputedStyle(document.documentElement).getPropertyValue('--paper').trim()
  })`);
  const darkPdf = JSON.parse(darkPdfState);
  if (darkPdf.surface !== 'rgb(255, 255, 255)'
      || darkPdf.filters.some((filter) => filter !== 'none')
      || darkPdf.paper === '#e8e8e3') {
    throw new Error(`Dark reader mode changed PDF page rendering: ${darkPdfState}`);
  }
  for (const layout of ['continuous', 'page', 'spread']) {
    await evaluate(client, `(() => {
      document.querySelector('[data-pdf-layout="${layout}"]').click();
      document.querySelector('#page-number').value = '2';
      document.querySelector('#page-count').requestSubmit();
    })()`);
    await waitFor(client, `document.querySelector('#page-number').value === '2'
      && history.state?.scholiaPdfPosition?.pageNumber === 2`, `save page two in ${layout} layout`);
    await client.send('Page.reload');
    await waitFor(client, `document.querySelector('#document-status')?.textContent.includes('index restored from cache')
      && document.querySelector('#search-mode')?.value === 'semantic'
      && document.querySelector('#page-number')?.value === '2'
      && document.querySelector('[data-pdf-layout="${layout}"]')?.getAttribute('aria-checked') === 'true'
      && document.querySelector('.pdf-page[data-page-number="2"] canvas')`, `restore PDF page after reload in ${layout} layout`);
  }
  await client.send('Page.navigate', {
    url: `http://127.0.0.1:${staticPort}/dist/chrome/pdf-viewer.html?source=smoke_pdf_source_123&simulate-brave=1`
  });
  await waitFor(client, "document.querySelector('.pdf-page canvas')", 'Brave-compatible PDF reader');
  await evaluate(client, "document.querySelector('#open-chat').click()");
  await waitFor(client, `!document.querySelector('#pdf-chat').hidden
    && document.querySelector('#pdf-chat-content').shadowRoot?.querySelector('#home-view')`, 'Brave chat inside reader');
  const bravePdfChatState = JSON.parse(await evaluate(client, `JSON.stringify({
    browserSidebar: Boolean(globalThis.__scholiaSidePanelRequest),
    nestedFrame: Boolean(document.querySelector('#pdf-chat iframe')),
    ariaControls: document.querySelector('#open-chat').getAttribute('aria-controls'),
    ariaExpanded: document.querySelector('#open-chat').getAttribute('aria-expanded')
  })`));
  if (bravePdfChatState.browserSidebar || bravePdfChatState.nestedFrame
      || bravePdfChatState.ariaControls !== 'pdf-chat' || bravePdfChatState.ariaExpanded !== 'true') {
    throw new Error(`Brave PDF chat did not stay in the reader: ${JSON.stringify(bravePdfChatState)}`);
  }
  await client.send('Page.navigate', {
    url: `http://127.0.0.1:${staticPort}/dist/chrome/options.html`
  });
  await waitFor(client, "document.readyState === 'complete' && document.querySelector('#chatgpt-web-status')?.textContent === 'Signed in'", 'ChatGPT web settings connection');
  await waitFor(client, `document.querySelector('#capture-region-shortcut').textContent === 'Command+Shift+S'
    && document.querySelector('#quick-chat-shortcut').textContent === 'Command+Shift+K'`, 'extension keyboard shortcut settings');
  await evaluate(client, "document.querySelector('#open-shortcuts').click()");
  await waitFor(client, "globalThis.__scholiaCreatedTabUrl === 'chrome://extensions/shortcuts'", 'Chrome shortcut editor link');
  const chatGptRefreshOptions = await evaluate(client, `JSON.stringify({
    selected: document.querySelector('#chatgpt-quick-chat-refresh').value,
    choices: [...document.querySelector('#chatgpt-quick-chat-refresh').options].map((option) => option.value),
    detail: document.querySelector('#chatgpt-quick-chat-refresh-detail').textContent
  })`);
  const refreshOptions = JSON.parse(chatGptRefreshOptions);
  if (refreshOptions.selected !== '3h'
      || refreshOptions.choices.join(',') !== 'off,always,3h,12h,1d,3d,7d'
      || !refreshOptions.detail.includes('temporary background ChatGPT tab')) {
    throw new Error(`ChatGPT Quick Chat refresh settings were incomplete: ${chatGptRefreshOptions}`);
  }
  await evaluate(client, `(() => {
    document.querySelector('#chatgpt-project-import').click();
    document.querySelector('#chatgpt-memory-import').click();
  })()`);
  await waitFor(client, "document.querySelector('#chatgpt-memory').value === 'Full rendered ChatGPT memory summary.'", 'automatic full ChatGPT memory import');
  const chatGptImportState = await evaluate(client, `JSON.stringify({
    memory: document.querySelector('#chatgpt-memory').value,
    project: document.querySelector('#chatgpt-project-context').value,
    projectName: document.querySelector('#chatgpt-project-name').value,
    enabled: document.querySelector('#chatgpt-web-enabled').checked
  })`);
  const chatGptImport = JSON.parse(chatGptImportState);
  if (chatGptImport.memory !== 'Full rendered ChatGPT memory summary.'
      || chatGptImport.project !== 'New visible ChatGPT context.'
      || chatGptImport.projectName !== 'Study project'
      || !chatGptImport.enabled) {
    throw new Error(`ChatGPT web context was not imported into editable settings: ${chatGptImportState}`);
  }
  await evaluate(client, "document.querySelector('#settings-form').requestSubmit()");
  await waitFor(client, "document.querySelector('#status').textContent.includes('Saved')", 'save imported ChatGPT web context');
  await evaluate(client, `(() => {
    const provider = document.querySelector('#provider');
    provider.value = 'opencode';
    provider.dispatchEvent(new Event('change', { bubbles: true }));
  })()`);
  await waitFor(client, `!document.querySelector('#bridge-card').hidden
    && document.querySelector('#bridge-status').textContent.includes('offline')`, 'offline local bridge controls');
  const opencodeModelOptions = JSON.parse(await evaluate(client, `JSON.stringify(
    [...document.querySelectorAll('#model-list option')].map((option) => ({ value: option.value, label: option.label }))
  )`));
  if (!opencodeModelOptions.some((option) => option.value === 'opencode-go/glm-5.3-flash')
      || opencodeModelOptions.some((option) => option.value.includes('ox-alpha') || option.value.includes('x-preview-f'))
      || !opencodeModelOptions.some((option) => option.value === 'future-provider/brand-new-model'
        && option.label === 'Brand New Model · Future Provider')) {
    throw new Error(`OpenCode catalog models were not merged into the settings picker: ${JSON.stringify(opencodeModelOptions)}`);
  }
  const bridgeLaunchFrames = await evaluate(client, `(() => {
    const button = document.querySelector('#bridge-start');
    for (let attempt = 0; attempt < 10; attempt += 1) button.click();
    return document.querySelectorAll('iframe[data-smoke-bridge-url^="opencode://start"]').length;
  })()`);
  if (bridgeLaunchFrames !== 1) {
    throw new Error(`Repeated local bridge clicks launched ${bridgeLaunchFrames} URL-scheme frames instead of one.`);
  }
  await waitFor(client, `!document.querySelector('#bridge-start').disabled
    && document.querySelector('#status').textContent.includes('launcher may not be installed')`, 'missing bridge launcher guidance');
  console.log('Chromium extension smoke test passed (Quick Chat, contained model picker, live Codex bridge recovery, direct in-reader PDF chat with Brave frame blocking simulated, PDF page restoration after reload in all layouts, PDF print/search/navigation, and recursive chat handoff).');
} catch (error) {
  if (client) {
    const pageState = await evaluate(client, `JSON.stringify({
      title: document.title,
      status: document.querySelector('#status')?.textContent,
      selection: window.getSelection()?.toString(),
      selectionStartBubble: (() => {
        const node = window.getSelection()?.anchorNode;
        const element = node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
        return element?.closest('.message--assistant .bubble, .response-window-message--assistant .bubble')?.className;
      })(),
      selectionEndBubble: (() => {
        const node = window.getSelection()?.focusNode;
        const element = node?.nodeType === Node.ELEMENT_NODE ? node : node?.parentElement;
        return element?.closest('.message--assistant .bubble, .response-window-message--assistant .bubble')?.className;
      })(),
      activeElement: document.activeElement?.id || document.activeElement?.className,
      pageNumber: document.querySelector('#page-number')?.value,
      pageLayout: document.querySelector('#pages')?.className,
      scrollY: window.scrollY,
      activeOutline: document.querySelector('#outline-tree [aria-current="location"] .pdf-outline-title')?.textContent,
      responsePopupHidden: document.querySelector('#response-explain')?.hidden,
      responseDepth: document.querySelector('#response-window-depth')?.textContent,
      responseSendLabel: document.querySelector('#response-window-send')?.getAttribute('aria-label'),
      responseRows: [...document.querySelectorAll('#response-window-messages .response-window-message')].map((row) => ({
        className: row.className,
        index: row.dataset.messageIndex,
        text: row.textContent.slice(0, 120)
      })),
      body: document.body?.innerText?.slice(0, 1200)
    })`).catch(() => 'Page state unavailable');
    console.error(pageState);
    console.error(JSON.stringify(
      client.events.filter((event) => event.method === 'Runtime.exceptionThrown').slice(-5),
      null,
      2
    ));
  }
  throw error;
} finally {
  client?.close();
  chromium.kill('SIGTERM');
  server.close();
  await rm(profile, { recursive: true, force: true });
}
