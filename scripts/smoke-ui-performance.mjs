// Synthetic accounts only. Checks architectural budgets and real Chromium
// navigation rather than machine-dependent timing thresholds.
import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createHostedServer } from '../apps/server/server.js';
import { onePagePdf } from '../tests/helpers/pdf.js';
import { chromiumSession } from './smoke/browser/lib/chromium.mjs';

const meta = JSON.parse(await readFile('dist/web-meta.json', 'utf8'));
const eager = new Set();
function visit(path) {
  if (eager.has(path)) return;
  eager.add(path);
  for (const dependency of meta.outputs[path].imports)
    if (dependency.kind === 'import-statement' && !dependency.external) visit(dependency.path);
}
visit('dist/web/app.js');
const eagerBytes = [...eager].reduce((sum, path) => sum + meta.outputs[path].bytes, 0);
const eagerInputs = [...eager].flatMap((path) => Object.keys(meta.outputs[path].inputs));
assert.ok(eagerBytes < 350_000, `Dashboard JavaScript budget exceeded: ${eagerBytes} bytes`);
assert.equal(eagerInputs.some((path) => /node_modules\/(pdfjs-dist|highlight.js|katex|markdown-it)\//.test(path)), false,
  'Readers, math and code grammars must stay outside the dashboard dependency graph');

const root = await mkdtemp(join(tmpdir(), 'scholia-ui-performance-'));
const reserve = createServer();
await new Promise((resolve) => reserve.listen(0, '127.0.0.1', resolve));
const port = reserve.address().port;
await new Promise((resolve) => reserve.close(resolve));
const origin = `http://127.0.0.1:${port}`;
const app = createHostedServer({ root, origin });
let browser;
try {
  const user = await app.store.createUser('performance@example.com', 'synthetic test password');
  const account = app.workspaces.account(user.id);
  account.library.courses = Array.from({ length: 89 }, (_, i) => ({
    id: `course-${i}`, name: `Synthetic course ${i}`, code: `TEST${i}`, favorite: i === 0,
    documents: [], threads: [],
    canvasMaterials: Array.from({ length: 64 }, (_, j) => ({
      id: `files:${i}-${j}`, kind: 'files', title: `Lecture ${j}`, remoteID: `${i}-${j}`,
      sourceURL: `https://canvas.example/courses/${i}/files/${j}`, version: '1',
    })),
  }));
  const course = account.library.courses[0];
  const pdf = await app.workspaces.importFile(account, course, 'fixture.pdf', Buffer.from(onePagePdf('A small PDF for lazy reader verification.')));
  const text = await app.workspaces.importFile(account, course, 'notes.md', Buffer.from('# Study notes\n\nMath: $x^2$.\n\n```python\nprint(42)\n```'));
  app.store.save(account);
  let failPDFOnce = true;
  const serve = app.server.listeners('request')[0];
  app.server.removeListener('request', serve);
  app.server.on('request', (request, response) => {
    if (failPDFOnce && request.url === `/api/document/${pdf.id}`) {
      failPDFOnce = false;
      response.writeHead(503, { 'Content-Type': 'text/plain', 'Cache-Control': 'no-store' });
      response.end('Synthetic transient reader failure');
    } else void serve(request, response);
  });
  await new Promise((resolve) => app.server.listen(port, '127.0.0.1', resolve));
  browser = await chromiumSession();
  const { send, evaluate, until, click } = browser;
  await send('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
  await send('Page.addScriptToEvaluateOnNewDocument', { source: `
    window.stateRequests = [];
    const originalFetch = window.fetch;
    window.fetch = async (...args) => {
      const response = await originalFetch(...args);
      if (args[0] === '/api/state') window.stateRequests.push({
        status: response.status,
        conditional: new Headers(args[1]?.headers).get('If-None-Match'),
        etag: response.headers.get('ETag')
      });
      return response;
    };` });
  await send('Page.navigate', { url: origin });
  await until('document.querySelector("#sign-in") && document.readyState === "complete"');
  await evaluate(`document.querySelector('[name=email]').value='performance@example.com';
    document.querySelector('[name=password]').value='synthetic test password';
    document.querySelector('#sign-in').requestSubmit()`);
  await until('document.querySelectorAll(".course-card").length === 89', { timeoutMs: 25_000 });
  const startup = await evaluate(`({
    visibleMs: performance.now(),
    scripts: performance.getEntriesByType('resource').filter(r => new URL(r.name).pathname.endsWith('.js')).map(r => ({ path: new URL(r.name).pathname, bytes: r.encodedBodySize })),
    domNodes: document.querySelectorAll('*').length
  })`);
  assert.equal(startup.scripts.some((r) => /\/(pdf-reader|render|notebook-reader|practice)-/.test(r.path)), false);
  await evaluate('window.savedNavigation = document.querySelector("#course-nav").firstElementChild');
  await until('window.stateRequests.some(r => r.status === 304 && r.conditional)', { timeoutMs: 10_000 });
  assert.equal(await evaluate('window.savedNavigation === document.querySelector("#course-nav").firstElementChild'), true);
  const polling = await evaluate(`(async () => {
    const headers = { 'X-Scholia-Token': document.querySelector('meta[name=scholia-token]').content };
    const full = await fetch('/api/state', { headers });
    const bytes = new TextEncoder().encode(await full.text()).length;
    const unchanged = await fetch('/api/state', { headers: { ...headers, 'If-None-Match': full.headers.get('ETag') } });
    return { fullBytes: bytes, unchangedStatus: unchanged.status, unchangedBytes: (await unchanged.text()).length };
  })()`);
  assert.equal(polling.unchangedStatus, 304);
  assert.equal(polling.unchangedBytes, 0);
  await click('#library [data-action="course"][data-id="course-0"]');
  await until('document.querySelector(".course-materials")');
  const courseLayout = await evaluate(`(() => {
    const content = document.querySelector('.course-materials').getBoundingClientRect();
    const readerElement = document.querySelector('#reader-content');
    const reader = readerElement.getBoundingClientRect();
    return { width: content.width, leftGap: content.left - reader.left,
      rightGap: reader.left + readerElement.clientWidth - content.right };
  })()`);
  assert.ok(courseLayout.width > 1400, 'Wide course content fills the available reader width');
  assert.ok(courseLayout.leftGap <= 32 && courseLayout.rightGap <= 32, 'Only normal content padding remains');
  await mkdir(resolve('dist/verification'), { recursive: true });
  await browser.screenshot(resolve('dist/verification/course-wide.png'));
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'), true, 'Course remains usable on narrow screens');
  await browser.screenshot(resolve('dist/verification/course-narrow.png'));
  await send('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
  await click(`#material-nav [data-action="document"][data-id="${pdf.id}"]`);
  await until('document.querySelector("[data-action=retryReading]")');
  await click('[data-action="retryReading"]');
  await until('document.querySelector(".pdfViewer .page canvas")?.width > 0');
  assert.ok(await evaluate(`performance.getEntriesByType('resource').some(r => r.name.includes('/pdf-reader-'))`));
  assert.equal(await evaluate('document.querySelectorAll(".pdf-outline-panel button").length'), 0,
    'Closed PDF contents do no page-list work');
  await click('[data-pdf="outline"]');
  await until('document.querySelector(".pdf-outline-panel button")');
  await evaluate('window.outlineButton = document.querySelector(".pdf-outline-panel button")');
  await click('[data-pdf="outline"]');
  await click('[data-pdf="outline"]');
  assert.equal(await evaluate('window.outlineButton === document.querySelector(".pdf-outline-panel button")'), true);
  await click(`#material-nav [data-action="document"][data-id="${text.id}"]`);
  await until('document.querySelector(".paper .katex") && document.querySelector(".paper .hljs-number")');
  // Returning to the dashboard retires the active reader.
  await click('[data-action="library"]');
  await until('!document.querySelector("#library").hidden');
  assert.equal(await evaluate('document.querySelector("#workspace").hidden'), true);
  assert.deepEqual(browser.errors, []);
  const report = { eagerJavaScriptBytes: eagerBytes, courses: 89, materials: 5696, courseLayout, startup, polling };
  await mkdir(resolve('dist/verification'), { recursive: true });
  await writeFile(resolve('dist/verification/ui-performance.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
  console.log('PASS: Chromium dashboard budget, conditional idle polling, retained navigation, lazy PDF, math/code rendering and return to dashboard');
} catch (error) {
  if (browser) console.error(JSON.stringify({ errors: browser.errors,
    page: await browser.evaluate('({url: location.href, text: document.body.innerText.slice(0, 2500)})').catch(() => null) }));
  throw error;
} finally {
  await browser?.close();
  await app.close();
  await rm(root, { recursive: true, force: true });
}
