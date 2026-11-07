// Synthetic PDF: measure backing-store pixels rather than noisy process RSS.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { build } from 'esbuild';
import { chromiumSession, sleep } from './smoke/browser/lib/chromium.mjs';

const root = await mkdtemp(join(tmpdir(), 'scholia-pdf-memory-'));
const count = 16;
const objects = [
  '<< /Type /Catalog /Pages 2 0 R >>',
  `<< /Type /Pages /Kids [${Array.from({ length: count }, (_, i) => `${4 + i * 2} 0 R`).join(' ')}] /Count ${count} >>`,
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
];
for (let page = 1; page <= count; page++) {
  const stream = `BT /F1 14 Tf 72 720 Td (Memory fixture page ${page}) Tj ET`;
  objects.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${5 + (page - 1) * 2} 0 R >>`);
  objects.push(`<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`);
}
let pdf = '%PDF-1.4\n';
const offsets = [];
objects.forEach((object, i) => { offsets.push(pdf.length); pdf += `${i + 1} 0 obj\n${object}\nendobj\n`; });
const xref = pdf.length;
pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
pdf += offsets.map((offset) => `${String(offset).padStart(10, '0')} 00000 n \n`).join('');
pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;

await build({
  stdin: { contents: `import { StudyPDFReader } from './apps/web/reader/pdf-reader.js';
    window.mountReader = (budget = true) => {
      window.reader?.destroy();
      window.reader = new StudyPDFReader({ host: document.querySelector('#host'), toolbar: document.querySelector('#toolbar'),
        document: { id: 'memory', pageCount: ${count} }, course: {}, token: 'fixture', notify: console.warn,
        onPage() {}, onImage() {}, onSelection() {}, onChat() {} });
      if (!budget) reader.trimPageCache = () => {};
    };`, resolveDir: resolve('.') },
  outfile: join(root, 'reader.js'), bundle: true, format: 'esm', logLevel: 'silent',
  loader: { '.svg': 'dataurl', '.gif': 'dataurl' },
});
const server = createServer(async (request, response) => {
  const path = new URL(request.url, 'http://localhost').pathname;
  if (path === '/api/document/memory') {
    response.writeHead(200, { 'Content-Type': 'application/pdf' }); response.end(pdf); return;
  }
  if (path === '/') {
    response.setHeader('Content-Type', 'text/html');
    response.end(`<!doctype html><html><head><link rel="stylesheet" href="/app.css"><link rel="stylesheet" href="/reader.css">
      <style>body{margin:0}#toolbar{height:46px;display:flex}#host{height:calc(100vh - 46px);position:relative}</style></head>
      <body><div id="toolbar"></div><div id="host" class="reader-content"></div><script type="module" src="/reader.js"></script></body></html>`);
    return;
  }
  const file = ['/reader.js', '/reader.css'].includes(path) ? join(root, path.slice(1))
    : join(resolve('dist/web'), path.slice(1));
  try {
    response.setHeader('Content-Type', path.endsWith('.css') ? 'text/css' : 'text/javascript');
    response.end(await readFile(file));
  } catch { response.writeHead(404); response.end(); }
});
let browser;
try {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  browser = await chromiumSession();
  const { send, evaluate, until } = browser;
  await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 2, mobile: false });
  await send('Page.navigate', { url: `http://127.0.0.1:${server.address().port}` });
  await until('typeof mountReader === "function"');
  const results = {};
  for (const budget of [false, true]) {
    await evaluate(`mountReader(${budget}); window.renderedPages = 0;
      reader.bus.on('pagerendered', () => window.renderedPages++);`);
    await until('reader.ready && reader.viewer.getPageView(0).renderingState === 3');
    await evaluate('reader.setZoom("4")');
    for (let page = 1; page <= 12; page++) {
      await evaluate(`reader.setPage(${page})`);
      await until(`reader.viewer.getPageView(${page - 1}).renderingState === 3`);
      await sleep(200);
    }
    results[budget ? 'bounded' : 'defaultCache'] = await evaluate(`(() => {
      const canvases = [...document.querySelectorAll('.pdfViewer canvas')];
      const base = canvases.filter(c => !c.classList.contains('pdf-detail-canvas'));
      return { basePages: base.length, basePixels: base.reduce((sum, c) => sum + c.width * c.height, 0),
        totalPixels: canvases.reduce((sum, c) => sum + c.width * c.height, 0), renderedPages };
    })()`);
  }
  assert.ok(results.defaultCache.basePixels > 90_000_000, 'Fixture exercises the large default cache');
  assert.ok(results.bounded.basePixels <= 24_000_000, 'Offscreen base canvases respect the pixel budget');
  assert.ok(results.bounded.totalPixels < results.defaultCache.totalPixels * 0.4, 'At least 60% fewer retained canvas pixels');
  assert.ok(results.bounded.renderedPages < 50, 'Eviction does not trigger a background rerender loop');
  const beforeScroll = await evaluate('window.renderedPages');
  for (let step = 0; step < 10; step++) {
    await evaluate('reader.viewport.scrollTop += 24');
    await sleep(150);
  }
  results.bounded.scrollRenders = await evaluate('window.renderedPages') - beforeScroll;
  assert.ok(results.bounded.scrollRenders <= 2, 'Scrolling within one page preserves the prefetched adjacent page');
  // Prepare three pages before selecting across them. With the budget active,
  // scrolling alone would already evict page 1 before reaching page 3.
  await evaluate('window.trimBudget = reader.trimPageCache.bind(reader); reader.trimPageCache = () => {}');
  for (let page = 1; page <= 3; page++) {
    await evaluate(`reader.setPage(${page})`);
    await until(`reader.viewer.getPageView(${page - 1}).renderingState === 3
      && reader.viewer.getPageView(${page - 1}).div.querySelector('.textLayer span')`);
  }
  await evaluate(`(() => {
    window.selectedCanvases = [0, 1, 2].map(index => reader.viewer.getPageView(index).canvas);
    const first = reader.viewer.getPageView(0).div.querySelector('.textLayer span').firstChild;
    const last = reader.viewer.getPageView(2).div.querySelector('.textLayer span').firstChild;
    const range = document.createRange(); range.setStart(first, 0); range.setEnd(last, last.length);
    getSelection().removeAllRanges(); getSelection().addRange(range);
    reader.trimPageCache = window.trimBudget;
    reader.setPage(5);
  })()`);
  await until('reader.viewer.getPageView(4).renderingState === 3');
  await sleep(300);
  const selectedText = await evaluate('getSelection().toString()');
  for (let page = 1; page <= 3; page++) assert.ok(selectedText.includes(`Memory fixture page ${page}`), 'Eviction preserves all pages in a selection');
  assert.equal(await evaluate('selectedCanvases.every(canvas => canvas.width > 0)'), true,
    'Selection protects offscreen middle pages as well as both endpoints');
  await evaluate('getSelection().removeAllRanges(); reader.trimPageCache()');
  assert.ok(await evaluate('selectedCanvases.filter(canvas => canvas.width === 0).length') >= 2,
    'Deselected pages are eligible for eviction again');
  assert.ok(await evaluate(`[...document.querySelectorAll('.pdfViewer canvas:not(.pdf-detail-canvas)')]
    .reduce((sum, canvas) => sum + canvas.width * canvas.height, 0)`) <= 24_000_000,
    'Clearing the selection restores the base-page memory budget');
  await evaluate('reader.setPage(1)');
  await until('reader.viewer.getPageView(0).renderingState === 3');
  assert.equal(await evaluate('reader.viewer.getPageView(0).div.querySelector(".textLayer span")?.textContent'), 'Memory fixture page 1');
  await evaluate(`window.retiredCanvases = [...document.querySelectorAll('.pdfViewer canvas')];
    reader.destroy(); document.querySelector('#host').replaceChildren();`);
  assert.equal(await evaluate('retiredCanvases.every(c => c.width === 0)'), true, 'Closing the reader releases backing stores');
  assert.deepEqual(browser.errors, []);
  results.retainedPixelReduction = 1 - results.bounded.totalPixels / results.defaultCache.totalPixels;
  await mkdir(resolve('dist/verification'), { recursive: true });
  await writeFile(resolve('dist/verification/pdf-memory.json'), JSON.stringify(results, null, 2));
  console.log(JSON.stringify(results, null, 2));
  console.log('PASS: Chromium PDF cache budget, selection preservation, revisiting evicted pages, and teardown');
} finally {
  await browser?.close();
  await new Promise((resolve) => server.close(resolve));
  await rm(root, { recursive: true, force: true });
}
