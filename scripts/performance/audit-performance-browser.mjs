// Run by audit-performance.swift against an isolated synthetic native workspace.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const address = process.argv[2];
if (!address || !/^http:\/\/127\.0\.0\.1:\d+$/.test(address)) throw new Error('Pass the isolated fixture server address.');
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const profile = await mkdtemp(join(tmpdir(), 'scholia-audit-chromium-'));
const listener = createServer(); await new Promise((resolve) => listener.listen(0, '127.0.0.1', resolve));
const port = listener.address().port; await new Promise((resolve) => listener.close(resolve));
const binary = process.env.CHROMIUM_BIN || '/Applications/Chromium.app/Contents/MacOS/Chromium';
if (!/chromium/i.test(binary) || /brave/i.test(binary)) throw new Error('This audit requires Chromium.');
const chromium = spawn(binary, ['--headless=new', '--no-first-run', '--disable-default-apps', '--disable-gpu', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--window-size=1460,960', 'about:blank'], { stdio: 'ignore' });
let socket;
try {
  let version;
  for (let i = 0; i < 100; i++) { try { version = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json(); break; } catch { await wait(100); } }
  if (!version) throw new Error('Chromium did not start.');
  const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.addEventListener('open', resolve, { once: true }); socket.addEventListener('error', reject, { once: true }); });
  let serial = 0; const pending = new Map(); const events = [];
  socket.addEventListener('message', (event) => {
    const message = JSON.parse(event.data);
    if (!message.id) { events.push(message); return; }
    const item = pending.get(message.id); if (!item) return;
    pending.delete(message.id); clearTimeout(item.timer);
    if (message.error) item.reject(new Error(message.error.message)); else item.resolve(message.result);
  });
  const send = (method, params = {}) => new Promise((resolve, reject) => {
    const id = ++serial;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timeout: ${method}`)); }, 15000);
    pending.set(id, { resolve, reject, timer }); socket.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async (expression) => {
    const result = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails)); return result.result.value;
  };
  const until = async (expression) => { for (let i = 0; i < 150; i++) { if (await evaluate(expression)) return; await wait(100); } throw new Error(`Timed out: ${expression}`); };
  await send('Runtime.enable'); await send('Page.enable'); await send('Network.enable'); await send('Performance.enable');
  await send('Page.addScriptToEvaluateOnNewDocument', { source: `window.auditLongTasks=[]; new PerformanceObserver(list=>window.auditLongTasks.push(...list.getEntries().map(e=>({start:e.startTime,duration:e.duration})))).observe({type:'longtask',buffered:true});` });
  await send('Page.navigate', { url: address });
  await until('document.querySelectorAll(".course-card").length === 89');
  const startup = await evaluate(`({visibleMs:performance.now(),navigation:performance.getEntriesByType('navigation')[0].toJSON(),resources:performance.getEntriesByType('resource').map(r=>({name:new URL(r.name).pathname,bytes:r.encodedBodySize,duration:r.duration})),longTasks:window.auditLongTasks})`);
  console.log(JSON.stringify({ name: 'browser.startup', browser: version.Browser, ...startup }));
  const sizes = await evaluate(`(async()=>{const headers={'X-Scholia-Token':document.querySelector('meta[name="scholia-token"]').content}; const rows=[]; for(let i=0;i<10;i++){const start=performance.now();const response=await fetch('/api/state',{headers});const text=await response.text();const parsed=performance.now();JSON.parse(text);rows.push({ms:performance.now()-start,parseMs:performance.now()-parsed,bytes:new TextEncoder().encode(text).length});} return rows;})()`);
  console.log(JSON.stringify({ name: 'browser.nativeState', samples: sizes }));
  const search = await evaluate(`(async()=>{const times=[];for(const q of ['T','TE','TES','TEST','TEST1','TEST','TES','TE','T','']){const input=document.querySelector('#course-search');input.value=q;const t=performance.now();input.dispatchEvent(new Event('input',{bubbles:true}));times.push(performance.now()-t);await new Promise(requestAnimationFrame);}return times;})()`);
  console.log(JSON.stringify({ name: 'browser.courseSearch', handlerMs: search }));
  events.length = 0;
  const before = await send('Performance.getMetrics');
  const start = performance.now(); await wait(8000);
  const after = await send('Performance.getMetrics');
  const metric = (value, name) => value.metrics.find((m) => m.name === name)?.value || 0;
  const stateResponses = events.filter((e) => e.method === 'Network.responseReceived' && e.params.response.url.endsWith('/api/state'));
  console.log(JSON.stringify({ name: 'browser.idle', elapsedMs: performance.now() - start, stateRequests: stateResponses.length, taskDurationMs: 1000 * (metric(after, 'TaskDuration') - metric(before, 'TaskDuration')), jsHeapUsedBytes: metric(after, 'JSHeapUsedSize'), domNodes: metric(after, 'Nodes') }));
  const headerToken = await evaluate('document.querySelector(\'meta[name="scholia-token"]\').content');
  const response = await fetch(address + '/api/state', { headers: { 'X-Scholia-Token': headerToken } });
  assert.equal(response.status, 200);
  const failures = events.filter((e) => e.method === 'Runtime.exceptionThrown');
  console.log(JSON.stringify({ name: 'browser.errors', count: failures.length }));
  assert.equal(failures.length, 0);
  // Two clients can navigate between a draft's creation and its delayed save.
  const fixture = await response.json();
  const [first, second] = fixture.library.courses;
  const action = async (payload) => {
    const res = await fetch(address + '/api/action', { method: 'POST', headers: { 'X-Scholia-Token': headerToken, 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    if (!res.ok) throw new Error(`Fixture action failed: ${res.status}`);
    return res.json();
  };
  await action({ action: 'course', id: first.id });
  await action({ action: 'course', id: second.id });
  const stale = await action({ action: 'draft', courseID: first.id, text: 'A delayed draft intended for the first course', clearImage: true });
  console.log(JSON.stringify({ name: 'browser.staleDraft', intendedCourse: first.id, actualCourse: stale.library.selectedCourseID, wrongCourseAccepted: stale.library.selectedCourseID === second.id && stale.draft === 'A delayed draft intended for the first course' }));
} finally {
  socket?.close(); chromium.kill('SIGTERM');
  await new Promise((resolve) => { if (chromium.exitCode !== null) resolve(); else { chromium.once('exit', resolve); setTimeout(resolve, 3000); } });
  await rm(profile, { recursive: true, force: true });
}
