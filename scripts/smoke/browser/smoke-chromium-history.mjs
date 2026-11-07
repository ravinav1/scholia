import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
class Client {
  constructor(url) { this.ws = new WebSocket(url); this.id = 0; this.pending = new Map(); }
  async open() {
    await new Promise((r, reject) => { this.ws.addEventListener('open', r, { once: true }); this.ws.addEventListener('error', reject, { once: true }); });
    this.ws.addEventListener('message', (e) => { const data = JSON.parse(e.data), p = this.pending.get(data.id); if (!p) return; this.pending.delete(data.id); if (data.error) p.reject(new Error(data.error.message)); else p.resolve(data.result); });
  }
  send(method, params = {}) { const id = ++this.id; return new Promise((resolve, reject) => { this.pending.set(id, { resolve, reject }); this.ws.send(JSON.stringify({ id, method, params })); }); }
  async evaluate(expression) { const r = await this.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }); if (r.exceptionDetails) throw new Error(JSON.stringify(r.exceptionDetails)); return r.result.value; }
}
const profile = await mkdtemp(join(tmpdir(), 'scholia-history-chromium-'));
const portProbe = createServer(); await new Promise((r) => portProbe.listen(0, '127.0.0.1', r)); const port = portProbe.address().port; await new Promise((r) => portProbe.close(r));
const extension = resolve('dist/chrome');
const chromium = spawn(process.env.CHROMIUM_BIN || '/Applications/Chromium.app/Contents/MacOS/Chromium', ['--headless=new','--no-first-run','--disable-default-apps','--disable-gpu',`--remote-debugging-port=${port}`,`--user-data-dir=${profile}`,`--load-extension=${extension}`,`--disable-extensions-except=${extension}`,'about:blank'], { stdio:'ignore' });
const clients = [];
try {
  let worker;
  for (let i = 0; i < 100 && !worker; i++) {
    try { const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json(); worker = targets.find((t) => t.type === 'service_worker' && t.url.endsWith('/service-worker.js')); } catch {}
    if (!worker) await sleep(100);
  }
  assert.ok(worker, 'extension service worker started in Chromium');
  const origin = new URL(worker.url).origin === 'null' ? worker.url.replace(/\/service-worker.js$/, '') : new URL(worker.url).origin;
  for (const page of ['options.html','popup.html']) {
    const target = await (await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(origin + '/' + page)}`, { method:'PUT' })).json();
    const client = new Client(target.webSocketDebuggerUrl); await client.open(); clients.push(client);
    for (let i = 0; i < 100; i++) { if (await client.evaluate('!!globalThis.chrome?.runtime?.id')) break; await sleep(50); }
  }
  const mutate = (client, operation, value) => client.evaluate(`chrome.runtime.sendMessage(${JSON.stringify({ type:'SCHOLIA_MUTATE_CHAT_HISTORY', operation, value })})`);
  const record = (id) => ({ id, createdAt:Date.now(), updatedAt:Date.now(), messages:[{role:'user',content:`Question ${id}`}], capture:{pageTitle:'History fixture'} });
  const [left, right] = await Promise.all([mutate(clients[0], 'save', record('left')), mutate(clients[1], 'save', record('right'))]);
  assert.equal(left.ok, true); assert.equal(right.ok, true);
  const read = () => clients[0].evaluate(`chrome.storage.local.get('scholia.chat-history.v1').then(v => v['scholia.chat-history.v1'] || [])`);
  assert.equal((await read()).length, 2);
  const latest = await mutate(clients[0], 'save', { ...left.value, updatedAt:Date.now()+10, messages:[{role:'user',content:'Newer branch'}] });
  assert.equal(latest.ok, true);
  const stale = await mutate(clients[1], 'save', { ...left.value, updatedAt:Date.now()+20, messages:[{role:'user',content:'Stale branch'}] });
  assert.equal(stale.ok, false); assert.match(stale.error, /another window/);
  await mutate(clients[1], 'delete', 'left');
  assert.equal((await mutate(clients[0], 'save', latest.value)).ok, false);
  assert.deepEqual((await read()).map((c) => c.id), ['right']);
  await mutate(clients[0], 'clear', null);
  assert.equal((await mutate(clients[1], 'save', right.value)).ok, false);
  assert.deepEqual(await read(), []);
  console.log('PASS: real Chromium extension, concurrent writers across two pages, stale revision rejection, deletion/clear protection');
} finally {
  for (const c of clients) c.ws.close();
  chromium.kill('SIGTERM');
  if (chromium.exitCode === null) await new Promise((r) => chromium.once('exit', r));
  await rm(profile, { recursive:true, force:true });
}
