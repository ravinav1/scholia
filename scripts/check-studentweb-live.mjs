// Explicit, interactive verification only. Never run this as an automated smoke
// test: a person signs in directly on Studentweb, without sharing credentials.
// No screenshots, page dumps, network tracing, cookies, console messages or
// exception details are collected. Only aggregate checks leave the browser.
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

const binary = process.env.CHROMIUM_BIN || '/Applications/Chromium.app/Contents/MacOS/Chromium';
if (!/chromium/i.test(binary) || /brave/i.test(binary)) throw new Error('Chromium is required.');
const profile = await mkdtemp(join(tmpdir(), 'scholia-private-studentweb-'));
const browser = spawn(binary, [
  '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run',
  '--no-default-browser-check', '--disable-sync', '--disable-extensions',
  '--disable-default-apps', '--disable-background-networking',
  '--disable-breakpad', '--disable-crash-reporter', 'about:blank',
], { stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'] });
let buffer = '', sequence = 0, sessionId, contextId, closing = false, busy = false, browserStopped = false, transportFailed = false;
const pending = new Map();
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
const input = createInterface({ input: process.stdin, terminal: false });
function send(method, params = {}, session = sessionId) {
  if (browserStopped || transportFailed) return Promise.reject(new Error('Browser closed.'));
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('Browser command failed.')); }, 15000);
    pending.set(id, { resolve, reject, timer });
    browser.stdio[3].write(JSON.stringify({ id, method, params, ...(session ? { sessionId: session } : {}) }) + '\0');
  });
}
browser.stdio[4].on('data', data => {
  buffer += data.toString();
  let boundary;
  while ((boundary = buffer.indexOf('\0')) >= 0) {
    const message = JSON.parse(buffer.slice(0, boundary));
    buffer = buffer.slice(boundary + 1);
    const handler = pending.get(message.id);
    if (!handler) continue; // Never retain browser events or console output.
    pending.delete(message.id); clearTimeout(handler.timer);
    if (message.error) handler.reject(new Error('Browser command failed.'));
    else handler.resolve(message.result);
  }
});
async function evaluate(expression) {
  const { frameTree } = await send('Page.getFrameTree');
  const { executionContextId } = await send('Page.createIsolatedWorld', {
    frameId: frameTree.frame.id, worldName: 'Scholia private result verification',
  });
  const value = await send('Runtime.evaluate', {
    expression, contextId: executionContextId, returnByValue: true, awaitPromise: true,
  });
  if (value.exceptionDetails) throw new Error('Page check could not complete.');
  return value.result.value;
}
async function state() {
  return evaluate(`(() => {
    if (location.origin !== 'https://fsweb.no') return 'external';
    const path = location.pathname.toLowerCase();
    if (path === '/studentweb/login.jsf') return 'login';
    if (path === '/studentweb/resultater.jsf') return document.readyState === 'complete' ? 'results' : 'loading';
    if (['/studentweb/index.jsf','/studentweb/forsiden.jsf','/studentweb/forside.jsf','/studentweb/start.jsf','/studentweb/','/studentweb'].includes(path)) return 'landing';
    return 'other';
  })()`);
}
async function check() {
  const source = await readFile(new URL('../apps/macos/Sources/ScholiaMac/StudentwebResults.swift', import.meta.url), 'utf8');
  const script = source.match(/static let script = #"""\n([\s\S]*?)\n\s*"""#/)[1];
  const report = await evaluate(`(() => {
    if (location.origin !== 'https://fsweb.no' || location.pathname !== '/studentweb/resultater.jsf') return {resultsPage:false};
    let rows;
    try { rows = JSON.parse(new Function('document', 'location', ${JSON.stringify(script)})(document, location)); }
    catch { return {resultsPage:true, readable:false}; }
    const schemaValid = Array.isArray(rows) && rows.every(r =>
      Object.keys(r).sort().join(',') === 'courseCode,passed' &&
      /^[A-ZÆØÅ]{2,8}[0-9]{3,5}[A-Z]?$/.test(r.courseCode) && typeof r.passed === 'boolean');
    return {resultsPage:true, schemaValid, courseCount:rows.length,
      passedCount:rows.filter(r => r.passed === true).length,
      uniqueCodes:new Set(rows.map(r => r.courseCode)).size === rows.length};
  })()`);
  console.log('CHECK', JSON.stringify(report));
}
async function structure() {
  const report = await evaluate(`(() => {
    if (location.origin !== 'https://fsweb.no' || location.pathname !== '/studentweb/resultater.jsf') return {resultsPage:false};
    const allowed = new Set(['semester','emne','course','vurderingsgrunnlag','assessment basis','dato','date','kand.nr','resultat','result','grade','karakter','stp.','credits','studiepoeng']);
    return [...document.querySelectorAll('table')].filter(t => !t.parentElement.closest('table')).map(t => ({
      columns:[...t.querySelectorAll('thead th')].map(h => { const label=h.textContent.trim().toLowerCase(); return allowed.has(label) ? label : 'other'; }),
      rows:t.querySelectorAll('tbody > tr').length,
      wholeRows:t.querySelectorAll('tr.resultatTop').length,
      componentRows:t.querySelectorAll('tr.resultat').length,
      nestedTables:t.querySelectorAll('table').length,
      rowspans:t.querySelectorAll('td[rowspan]').length,
      duplicateCodeElements:t.querySelectorAll('.col2Emne > *').length
    }));
  })()`);
  console.log('STRUCTURE', JSON.stringify(report));
}
function rejectPending() {
  for (const handler of pending.values()) { clearTimeout(handler.timer); handler.reject(new Error('Browser closed.')); }
  pending.clear();
}
async function close(exitCode = 0) {
  if (closing) return;
  closing = true; clearInterval(poll); clearTimeout(deadline); input.close();
  try { if (contextId) await send('Target.disposeBrowserContext', { browserContextId: contextId }, null); } catch {}
  try { await send('Browser.close', {}, null); } catch {}
  if (!browserStopped && browser.exitCode === null) {
    browser.kill('SIGTERM');
    await Promise.race([new Promise(resolve => browser.once('exit', resolve)), delay(3000)]);
  }
  if (!browserStopped && browser.exitCode === null) { browser.kill('SIGKILL'); await delay(300); }
  await rm(profile, { recursive: true, force: true });
  rejectPending();
  console.log('CLOSED: private browser context and temporary profile removed.');
  process.exit(exitCode);
}
let previous = '', checked = false;
const poll = setInterval(async () => {
  if (busy || closing) return;
  busy = true;
  try {
    const current = await state();
    if (current !== previous) {
      previous = current;
      console.log('PAGE', current);
      if (current === 'landing') await send('Page.navigate', { url: 'https://fsweb.no/studentweb/resultater.jsf' });
    }
    if (current === 'results' && !checked) { await delay(700); await check(); checked = true; }
  } catch { /* Navigation can invalidate an isolated world; retry without logging page errors. */ }
  finally { busy = false; }
}, 1000);
const deadline = setTimeout(close, 30 * 60 * 1000);
browser.once('error', () => {
  browserStopped = true; rejectPending();
  console.log('START_FAILED: could not open private Chromium.');
  void close(1);
});
browser.once('exit', () => { browserStopped = true; rejectPending(); void close(); });
browser.stdio[3].on('error', () => { transportFailed = true; rejectPending(); void close(1); });
input.once('close', () => { void close(); });
input.on('line', async line => {
  if (line.trim() === 'stop') { await close(); return; }
  if (busy || closing) { console.log('BUSY: retry shortly.'); return; }
  busy = true;
  try {
    if (line.trim() === 'check') await check();
    else if (line.trim() === 'structure') await structure();
    else if (line.trim() === 'refresh') { checked = false; await send('Page.reload', { ignoreCache: true }); }
    else if (line.trim() === 'status') console.log('PAGE', await state());
  } catch { console.log('CHECK_UNAVAILABLE: page still loading or navigation changed.'); }
  finally { busy = false; }
});
process.once('SIGINT', () => { void close(); }); process.once('SIGTERM', () => { void close(); });
try {
  ({ browserContextId: contextId } = await send('Target.createBrowserContext', { disposeOnDetach: true }, null));
  const { targetId } = await send('Target.createTarget', { url: 'about:blank', browserContextId: contextId, newWindow: true }, null);
  ({ sessionId } = await send('Target.attachToTarget', { targetId, flatten: true }, null));
  await send('Page.navigate', { url: 'https://fsweb.no/studentweb/login.jsf?inst=FSNTNU' });
  await send('Page.bringToFront');
  console.log('READY: sign in directly in the private Chromium window using Norwegian ID and PIN.');
  console.log('Commands: status, check, structure, refresh, stop. Credentials must never be entered in this terminal.');
} catch { if (!closing) console.log('START_FAILED: could not open private Chromium.'); await close(1); }
