import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

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
      clearTimeout(pending.timer);
      if (payload.error) pending.reject(new Error(payload.error.message));
      else pending.resolve(payload.result);
    });
  }

  send(method, params = {}) {
    const id = this.nextID++;
    return new Promise((resolvePromise, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`Timed out: ${method} ${params.expression || ''}`)); }, 15_000);
      this.pending.set(id, { resolve: resolvePromise, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  close() { this.socket.close(); }
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
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text || 'Evaluation failed.');
  return result.result.value;
}

async function waitFor(client, expression, label) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (await evaluate(client, expression)) return;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 50));
  }
  throw new Error(`Timed out waiting for ${label}.`);
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

const server = createServer((request, response) => {
  if (request.url === '/fixture.pdf') {
    response.writeHead(200, { 'Content-Type': 'application/pdf' });
    response.end(pdfSearchFixture());
    return;
  }
  response.writeHead(200, { 'Content-Type': 'text/html' });
  response.end(`<!doctype html><html lang="en"><title>Region capture fixture</title>
    <style>body{margin:0;background:#fff;height:2000px}#target{position:absolute;left:100px;top:160px;width:200px;height:100px;background:rgb(30,180,80)}</style>
    <h1>Capture the green rectangle</h1><div id="target"></div>
    <iframe srcdoc="<p>Child frame</p>" style="position:absolute;top:450px"></iframe></html>`);
});
await new Promise((done) => server.listen(0, '127.0.0.1', done));
const sourceUrl = `http://127.0.0.1:${server.address().port}`;
const profile = await mkdtemp(join(tmpdir(), 'scholia-region-smoke-'));
const debugPort = await availablePort();
const extension = resolve('dist/chrome');
const chromium = spawn(process.env.CHROMIUM_BIN || '/Applications/Chromium.app/Contents/MacOS/Chromium', [
  '--headless=new', '--no-first-run', '--disable-default-apps', '--disable-gpu', '--force-device-scale-factor=2',
  `--remote-debugging-port=${debugPort}`, `--user-data-dir=${profile}`,
  `--disable-extensions-except=${extension}`, `--load-extension=${extension}`,
  '--window-size=1000,800', 'about:blank'
], { stdio: 'ignore' });
const clients = [];
const targets = () => fetch(`http://127.0.0.1:${debugPort}/json/list`).then((response) => response.json());
async function connectTarget(predicate) {
  for (let attempt = 0; attempt < 100; attempt++) {
    const target = (await targets()).find(predicate);
    if (target) {
      const client = new DevToolsClient(target.webSocketDebuggerUrl);
      await client.open();
      clients.push(client);
      return client;
    }
    await new Promise((done) => setTimeout(done, 100));
  }
  throw new Error('Target did not appear.');
}

// DevTools can inspect the production closed shadow root without changing it.
async function captureLayer(client, expression) {
  const { root } = await client.send('DOM.getDocument', { depth: -1, pierce: true });
  function find(node) {
    if (node.attributes?.includes('data-capture-layer')) return node;
    for (const child of [...(node.children || []), ...(node.shadowRoots || [])]) {
      const match = find(child);
      if (match) return match;
    }
  }
  const node = find(root);
  if (!node) return null;
  const { object } = await client.send('DOM.resolveNode', { nodeId: node.nodeId });
  const result = await client.send('Runtime.callFunctionOn', {
    objectId: object.objectId,
    functionDeclaration: `function() { ${expression} }`,
    returnByValue: true
  });
  return result.result.value;
}
async function waitForLayer(client) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (await captureLayer(client, 'return !this.hidden;')) return;
    await new Promise((done) => setTimeout(done, 50));
  }
  throw new Error('The selection overlay did not open on the source page.');
}
async function drag(client, start, end) {
  await client.send('Input.dispatchMouseEvent', { type: 'mousePressed', ...start, button: 'left', clickCount: 1 });
  await client.send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...end, button: 'left', buttons: 1 });
  await client.send('Input.dispatchMouseEvent', { type: 'mouseReleased', ...end, button: 'left', clickCount: 1 });
}
const escape = (client) => client.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });

try {
  await waitForDebugger(debugPort);
  const worker = await connectTarget((target) => target.type === 'service_worker' && target.url.endsWith('/service-worker.js'));
  await worker.send('Runtime.enable');
  await waitFor(worker, '!!globalThis.chrome?.runtime?.id', 'extension worker initialization');
  const extensionUrl = await evaluate(worker, 'chrome.runtime.getURL("")');
  const source = await evaluate(worker, `chrome.tabs.create({ url: ${JSON.stringify(sourceUrl)}, active: true })`);
  const page = await connectTarget((target) => target.url.startsWith(sourceUrl));
  await page.send('Emulation.setDeviceMetricsOverride', { width: 1000, height: 800, deviceScaleFactor: 2, mobile: false });
  await waitFor(page, '!!document.getElementById("scholia-extension-root")', 'content script');
  await evaluate(worker, `chrome.tabs.create({ url: ${JSON.stringify(extensionUrl + 'panel.html')}, active: false, windowId: ${source.windowId} })`);
  const panel = await connectTarget((target) => target.url === extensionUrl + 'panel.html');
  await waitFor(panel, 'document.querySelector("#current-title")?.textContent.includes("Region capture fixture")', 'panel source');
  await evaluate(panel, 'document.querySelector("#capture").click()');
  await waitForLayer(page);
  assert.equal(await evaluate(panel, '!!document.getElementById("capture-editor")'), false);
  const bounds = await captureLayer(page, 'const r = this.getBoundingClientRect(); return [r.width, r.height];');
  assert.deepEqual(bounds, await evaluate(page, '[document.documentElement.clientWidth, innerHeight]'));
  // Reverse drag at 2x density; the attachment must contain undimmed source pixels.
  await drag(page, { x: 300, y: 260 }, { x: 100, y: 160 });
  await waitFor(panel, 'document.querySelector("#chat-source-image")?.src.startsWith("data:image/")', 'captured attachment');
  const image = await evaluate(panel, `(async () => {
    const image = new Image();
    await new Promise((done, fail) => { image.onload = done; image.onerror = fail; image.src = document.querySelector('#chat-source-image').src; });
    const canvas = document.createElement('canvas'); canvas.width = image.naturalWidth; canvas.height = image.naturalHeight;
    const ctx = canvas.getContext('2d'); ctx.drawImage(image, 0, 0);
    return { width: canvas.width, height: canvas.height, pixel: [...ctx.getImageData(canvas.width / 2, canvas.height / 2, 1, 1).data] };
  })()`);
  assert.deepEqual([image.width, image.height], [400, 200]);
  assert.ok(image.pixel.slice(0, 3).every((value, index) => Math.abs(value - [30, 180, 80][index]) < 5), JSON.stringify(image));
  assert.equal(await captureLayer(page, 'return this.hidden;'), true);
  console.log('Live page crop matches the selected source pixels at 2x density.');

  // Real runtime cancellation must resolve the awaiting panel request.
  const beginRequest = () => evaluate(panel, `globalThis.captureResult = 'pending';
    chrome.runtime.sendMessage({type:'SCHOLIA_CAPTURE_ACTIVE_REGION', expectedTabId:${source.id}, windowId:${source.windowId}})
      .then(value => { globalThis.captureResult = value; }); undefined;`);
  const expectCancelled = async () => {
    await waitFor(panel, 'globalThis.captureResult !== "pending"', 'cancelled region request');
    assert.deepEqual(await evaluate(panel, 'globalThis.captureResult'), { ok: true, value: null });
  };
  await beginRequest(); await waitForLayer(page); await escape(page); await expectCancelled();
  await beginRequest(); await waitForLayer(page);
  await drag(page, { x: 150, y: 180 }, { x: 151, y: 181 }); await expectCancelled();
  await beginRequest(); await waitForLayer(page);
  await captureLayer(page, 'this.querySelector("[data-capture-cancel]").click();'); await expectCancelled();
  await beginRequest(); await waitForLayer(page);
  await page.send('Emulation.setDeviceMetricsOverride', { width: 980, height: 800, deviceScaleFactor: 2, mobile: false });
  await expectCancelled();
  console.log('Escape, tiny drag, Cancel button, and viewport resize all cancel cleanly.');

  // Exercise extension-owned PDF messaging and its embedded chat, with real APIs.
  await evaluate(worker, `chrome.tabs.update(${source.id}, {url:${JSON.stringify(sourceUrl + '/fixture.pdf')}})`);
  await waitFor(page, 'location.href.includes("pdf-viewer.html") && !!document.getElementById("scholia-extension-root")', 'PDF reader capture controls');
  await waitFor(page, '!document.querySelector("#open-chat").disabled', 'PDF text ready');
  await evaluate(page, 'document.querySelector("#open-chat").click()');
  await waitFor(page, '!!document.querySelector("#pdf-chat-content")?.shadowRoot?.querySelector("#capture") && !document.querySelector("#pdf-chat").hidden', 'embedded PDF chat');
  await evaluate(page, 'document.querySelector("#pdf-chat-content").shadowRoot.querySelector("#capture").click()');
  await waitForLayer(page);
  assert.equal(await evaluate(page, 'getComputedStyle(document.querySelector("#pdf-chat")).visibility'), 'hidden');
  await drag(page, { x: 150, y: 160 }, { x: 400, y: 260 });
  try {
    await waitFor(page, 'document.querySelector("#pdf-chat-content").shadowRoot.querySelector("#chat-source-image")?.src.startsWith("data:image/")', 'PDF region attachment');
  } catch (error) {
    console.error(await evaluate(page, `(() => {
      const root = document.querySelector('#pdf-chat-content').shadowRoot;
      return { detail: root.querySelector('#chat-source-detail')?.textContent,
        messages: root.querySelector('#messages')?.textContent,
        loading: !root.querySelector('#loading-card')?.hidden };
    })()`));
    throw error;
  }
  assert.equal(await evaluate(page, 'getComputedStyle(document.querySelector("#pdf-chat")).visibility'), 'visible');
  console.log('Chromium region smoke passed: live page selection, 2x crop pixels, reverse drag, Escape/button/tiny-drag/resize cancellation, and embedded PDF capture.');
} finally {
  for (const client of clients) client.close();
  chromium.kill('SIGTERM');
  server.close();
  await new Promise((done) => chromium.once('exit', done));
  await rm(profile, { recursive: true, force: true });
}
