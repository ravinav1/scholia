import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { build } from 'esbuild';
import { chromiumSession, sleep } from './lib/chromium.mjs';

const root = await mkdtemp(join(tmpdir(), 'scholia-pdf-quality-'));
const output = resolve('dist/verification/pdf-quality');
await mkdir(output, { recursive: true });

function fixturePdf() {
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [4 0 R 6 0 R] /Count 2 >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
  ];
  for (let page = 1; page <= 2; page++) {
    const stream = [
      `BT /F1 20 Tf 40 744 Td (PDF detail - page ${page}) Tj ET`,
      'BT /F1 10 Tf 40 720 Td (try ry rye dry ry ry end) Tj ET',
      ...Array.from({ length: 36 }, (_, i) => `BT /F1 ${i % 3 + 6} Tf 40 ${700 - i * 17} Td (Vectors, matrices and eigenvalues: fine text 0123456789. abcdefghijklmnopqrstuvwxyz.) Tj ET`),
      '0.2 w 40 78 m 560 78 l S 0.4 w 40 74 m 560 74 l S',
      '0.5 w 350 680 m 390 730 490 630 550 680 c S'
    ].join('\n');
    objects.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${5 + (page - 1) * 2} 0 R >>`);
    objects.push(`<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`);
  }
  let pdf = '%PDF-1.4\n';
  const offsets = [];
  objects.forEach((object, i) => { offsets.push(pdf.length); pdf += `${i + 1} 0 obj\n${object}\nendobj\n`; });
  const xref = pdf.length;
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  pdf += offsets.map((offset) => `${String(offset).padStart(10, '0')} 00000 n \n`).join('');
  return Buffer.from(`${pdf}trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`);
}

const pdf = fixturePdf();
const pdfFile = join(root, 'detail.pdf');
await writeFile(pdfFile, pdf);
await build({
  stdin: { contents: `import { StudyPDFReader } from './apps/web/pdf-reader.js';
    window.mountReader = () => window.reader = new StudyPDFReader({
      host: document.querySelector('#host'), toolbar: document.querySelector('#toolbar'),
      document: { id: 'quality', pageCount: 2 }, course: {}, token: 'fixture',
      notify: console.warn, onPage() {}, onImage() {}, onSelection() {}, onChat() {}
    }); window.mountReader();`, resolveDir: resolve('.') },
  outfile: join(root, 'reader.js'), bundle: true, format: 'esm', logLevel: 'silent',
  loader: { '.svg': 'dataurl', '.gif': 'dataurl' }
});
const server = createServer(async (request, response) => {
  const path = new URL(request.url, 'http://localhost').pathname;
  if (path === '/api/document/quality') {
    response.writeHead(200, { 'Content-Type': 'application/pdf' }); response.end(pdf); return;
  }
  if (path === '/') {
    response.setHeader('Content-Type', 'text/html');
    response.end(`<!doctype html><html><head><link rel="stylesheet" href="/app.css"><link rel="stylesheet" href="/reader.css">
      <style>body{margin:0}#toolbar{height:46px;display:flex}#host{height:calc(100vh - 46px);position:relative}</style></head>
      <body><div id="toolbar"></div><div id="host" class="reader-content"></div><script type="module" src="/reader.js"></script></body></html>`);
    return;
  }
  const file = path === '/reader.js' || path === '/reader.css'
    ? join(root, path.slice(1)) : join(resolve('dist/web'), path.slice(1));
  try {
    response.setHeader('Content-Type', path.endsWith('.css') ? 'text/css' : 'text/javascript');
    response.end(await readFile(file));
  } catch { response.writeHead(404); response.end(); }
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
let browser;
const statsExpression = (selector) => `(() => {
  const page = document.querySelector(${JSON.stringify(selector)});
  const base = page.querySelector('canvas:not(.pdf-detail-canvas)');
  const detail = page.querySelector('.pdf-detail-canvas');
  const measure = canvas => {
    if (!canvas) return null;
    const r = canvas.getBoundingClientRect();
    return { width: canvas.width, height: canvas.height, density: Math.min(canvas.width / r.width, canvas.height / r.height),
      left: r.left, top: r.top, right: r.right, bottom: r.bottom, pixels: canvas.width * canvas.height };
  };
  return { base: measure(base), detail: measure(detail), selection: getSelection().toString() };
})()`;
try {
  browser = await chromiumSession();
  const { send, evaluate, until } = browser;
  const metrics = (dpr, width = 1280, height = 900) => send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: dpr, mobile: false });
  await metrics(1);
  await send('Page.navigate', { url: `http://127.0.0.1:${server.address().port}/` });
  await until('window.reader?.ready && document.querySelector(".pdf-detail-canvas")');
  assert.equal(await evaluate('reader.outline.querySelectorAll("button").length'), 0, 'Opening a PDF does not build a hidden outline');
  await evaluate('reader.control("outline")');
  assert.equal(await evaluate('reader.outline.querySelectorAll("button").length'), 2);
  assert.equal(await evaluate(`(async () => {
    const first = reader.outline.querySelector('button');
    await reader.control('outline'); await reader.control('outline');
    return reader.outline.querySelector('button') === first;
  })()`), true, 'The outline is reused when reopened');
  await evaluate('reader.control("outline")');
  assert.equal(await evaluate(`(async () => {
    let requests = 0; reader.request = async () => { requests++; return { pages: [] }; };
    await reader.search(); return requests;
  })()`), 0, 'An empty search does not fetch a document index');
  await evaluate(`(() => {
    reader.request = () => { throw Error('Exact search must not fetch a duplicate server index'); };
    reader.searchBar.hidden = false;
    reader.searchBar.querySelector('input').value = ' ry ';
    reader.search();
  })()`);
  await until('reader.searchBar.querySelector("small").textContent === "1 / 6"');
  assert.equal(await evaluate('document.querySelector(".textLayer .highlight.selected")?.textContent'), 'ry');
  await evaluate('reader.moveMatch(1)');
  await until('reader.searchBar.querySelector("small").textContent === "2 / 6"');
  assert.equal(await evaluate('reader.page'), 1, 'Exact navigation visits separate occurrences on the same page');
  await evaluate('reader.moveMatch(1); reader.moveMatch(1)');
  await until('reader.searchBar.querySelector("small").textContent === "4 / 6" && reader.page === 2');
  await evaluate(`reader.searchBar.querySelector('input').value = 'ry'; reader.search()`);
  await until('reader.find.pageMatches.flat().length === 12');
  await evaluate('reader.closeSearch(); reader.setPage(1)');
  await until('!document.querySelector(".textLayer .highlight") && reader.page === 1');
  const indexing = await evaluate(`(async () => {
    const previous = reader.texts;
    reader.texts = Array.from({ length: 400 }, (_, i) => ('Solar energy and vector spaces page ' + i + '. ').repeat(80));
    let yielded = false; setTimeout(() => { yielded = true; }, 0);
    const index = await reader.buildSemanticIndex();
    reader.texts = previous;
    return { yielded, pages: index.pages.length, finalized: index.finalized };
  })()`);
  assert.deepEqual(indexing, { yielded: true, pages: 400, finalized: true }, 'Semantic indexing yields to reader interactions');
  const webFit = await evaluate(statsExpression('.page[data-page-number="1"]'));
  assert.ok(webFit.base.density < 1.1);
  assert.ok(webFit.detail.density > 1.99, 'Ordinary displays get supersampled text');
  await browser.screenshot(join(output, 'web-fit.png'));
  await evaluate(`(() => {
    const node = [...document.querySelectorAll('.textLayer span')].find(span => span.textContent.includes('Vectors')).firstChild;
    const range = document.createRange(); range.setStart(node, 0); range.setEnd(node, 7);
    getSelection().removeAllRanges(); getSelection().addRange(range);
  })()`);
  await metrics(2);
  await sleep(200);
  assert.equal(await evaluate('getSelection().toString()'), 'Vectors', 'Refining display density preserves the selection');
  await evaluate('reader.setZoom("4")');
  await until('document.querySelector(".pdf-detail-canvas")?.width > 0');
  let zoomed = await evaluate(statsExpression('.page[data-page-number="1"]'));
  assert.ok(zoomed.base.density < 1.1, 'Fixture exceeds the full-page pixel budget at 400%');
  assert.ok(zoomed.detail.density > 1.99, 'Visible details retain Retina resolution at 400%');
  assert.ok(zoomed.detail.pixels <= 16_000_000);
  await browser.screenshot(join(output, 'web-retina-400.png'));
  await evaluate('reader.viewport.scrollTop = 1100; reader.viewport.scrollLeft = 500');
  await until(`(() => { const c = document.querySelector('.pdf-detail-canvas')?.getBoundingClientRect();
    const v = reader.viewport.getBoundingClientRect(); return c && c.top <= v.top && c.bottom >= v.bottom && c.left <= v.left; })()`);
  await browser.screenshot(join(output, 'web-retina-scrolled.png'));
  await metrics(3, 1100, 760);
  await until('(() => { const c = document.querySelector(".pdf-detail-canvas"); return c && c.width / c.getBoundingClientRect().width > 2.99; })()');
  for (const layout of ['spread', 'page', 'continuous']) {
    await evaluate(`reader.setLayout(${JSON.stringify(layout)}); reader.setZoom('page-fit'); reader.setPage(2)`);
    await until('reader.viewer.getPageView(1).renderingState === 3');
  }
  assert.equal(await evaluate(`(async () => {
    let aborted = false;
    reader.request = (_path, _payload, signal) => new Promise((_resolve, reject) => signal.addEventListener('abort', () => {
      aborted = true; reject(new DOMException('Reader closed', 'AbortError'));
    }, { once: true }));
    reader.searchBar.querySelector('input').value = 'pending search';
    reader.searchBar.querySelector('select').value = 'semantic';
    const pending = reader.search().catch(() => {});
    reader.destroy(); await pending;
    document.querySelector('#host').replaceChildren(); return aborted;
  })()`), true, 'Closing the reader aborts its pending search request');
  await sleep(150);
  assert.equal(await evaluate('document.querySelectorAll(".pdf-detail-canvas").length'), 0);
  await evaluate('mountReader(); void 0');
  await until('reader.ready && reader.viewer.getPageView(0).renderingState === 3');
  assert.deepEqual(browser.errors, [], 'No web reader exceptions');
  await browser.close();

  browser = await chromiumSession({ extensionPath: resolve('dist/chrome') });
  const targets = await browser.send('Target.getTargets');
  const worker = targets.targetInfos.find((target) => target.type === 'service_worker' && target.url.endsWith('/service-worker.js'));
  assert.ok(worker, 'Extension loaded');
  await browser.send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 1, mobile: false });
  await browser.send('Page.navigate', { url: worker.url.replace('service-worker.js', 'pdf-viewer.html?open=1') });
  await browser.until('document.readyState === "complete" && document.querySelector("#error")?.hidden === false');
  const { root: documentNode } = await browser.send('DOM.getDocument');
  const { nodeId } = await browser.send('DOM.querySelector', { nodeId: documentNode.nodeId, selector: '#pdf-file' });
  await browser.send('DOM.setFileInputFiles', { nodeId, files: [pdfFile] });
  await browser.until('document.querySelector(".pdf-page .textLayer span") && !document.querySelector("#print-pdf").disabled');
  const extensionFit = await browser.evaluate(statsExpression('.pdf-page[data-page-number="1"]'));
  assert.ok(extensionFit.base.density > 1.99, 'Extension supersamples full pages on ordinary screens');
  await browser.screenshot(join(output, 'extension-fit.png'));
  const toolbarStyle = await browser.evaluate(`(() => {
    const bar = document.querySelector('.toolbar'), style = getComputedStyle(bar);
    return { position: style.position, blur: style.backdropFilter, background: style.backgroundColor };
  })()`);
  assert.equal(toolbarStyle.position, 'fixed');
  assert.equal(toolbarStyle.blur, 'none', 'Scrolling canvases cannot repaint through a blurred toolbar');
  assert.match(toolbarStyle.background, /^rgb\(/, 'Toolbar background is opaque');
  await browser.evaluate(`(() => {
    const bar = document.querySelector('.toolbar');
    window.toolbarFrames = [];
    window.watchToolbar = true;
    const sample = () => {
      if (!window.watchToolbar) return;
      const r = bar.getBoundingClientRect(), z = document.querySelector('#zoom-label').getBoundingClientRect();
      toolbarFrames.push([r.x, r.y, r.width, r.height, z.x, z.y]);
      requestAnimationFrame(sample);
    }; requestAnimationFrame(sample);
  })()`);
  await browser.evaluate(`(() => {
    const surface = document.querySelector('.pdf-page[data-page-number="1"] .pdf-page__surface');
    window.previousPageCanvas = surface.querySelector('canvas');
    window.blankPageFrames = 0;
    window.watchPageFrames = true;
    const sample = () => {
      if (!window.watchPageFrames) return;
      const canvas = surface.querySelector('canvas:not(.pdf-detail-canvas)');
      if (!canvas || !canvas.width || !canvas.height || surface.classList.contains('is-loading')) window.blankPageFrames++;
      requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
  })()`);
  await browser.send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 900, deviceScaleFactor: 3, mobile: false });
  await browser.evaluate(`(() => { const zoom = document.querySelector('#zoom-label');
    zoom.append(new Option('200%', '2')); zoom.value = '2'; zoom.dispatchEvent(new Event('change'));
    zoom.append(new Option('250%', '2.5')); zoom.value = '2.5'; zoom.dispatchEvent(new Event('change'));
    if (!window.previousPageCanvas.isConnected) throw Error('Zoom discarded the visible page before replacement was ready');
  })()`);
  await browser.until('(() => { const c = document.querySelector(".pdf-detail-canvas"); return c && c.width / c.getBoundingClientRect().width > 2.99; })()');
  const extensionZoom = await browser.evaluate(statsExpression('.pdf-page[data-page-number="1"]'));
  assert.ok(extensionZoom.base.density < 2);
  assert.ok(extensionZoom.detail.density > 2.99);
  await browser.screenshot(join(output, 'extension-250.png'));
  assert.equal(await browser.evaluate('window.blankPageFrames'), 0, 'Zoom never exposes an empty page or loading flash');
  await browser.evaluate(`window.watchPageFrames = false; window.blankDetailFrames = 0; window.watchDetailFrames = true;
    const sample = () => {
      if (!window.watchDetailFrames) return;
      if (!document.querySelector('.pdf-page[data-page-number="1"] .pdf-detail-canvas')) window.blankDetailFrames++;
      requestAnimationFrame(sample);
    }; requestAnimationFrame(sample);`);
  await browser.evaluate('scrollTo(200, 900)');
  await browser.until(`(() => {const r=document.querySelector('.pdf-detail-canvas')?.getBoundingClientRect();return r && r.top <= 90 && r.bottom >= innerHeight;})()`);
  assert.equal(await browser.evaluate('window.watchDetailFrames = false; window.blankDetailFrames'), 0, 'Scrolling retains the sharp tile until the next tile is ready');
  await browser.evaluate(`(async () => {
    const progress = document.querySelector('.document-progress'), wasHidden = progress.hidden;
    for (let i = 0; i < 30; i++) {
      progress.hidden = i % 2 === 0;
      scrollTo(i % 2 ? 200 : 0, i % 2 ? 900 : 200);
      await new Promise(requestAnimationFrame);
    }
    progress.hidden = wasHidden; window.watchToolbar = false;
  })()`);
  const toolbarFrames = await browser.evaluate('toolbarFrames');
  assert.ok(toolbarFrames.length >= 30);
  assert.ok(toolbarFrames.every(frame => frame.every((value, i) => Math.abs(value - toolbarFrames[0][i]) < 0.1)),
    'Toolbar and tools stay in exactly the same place during zoom, horizontal/vertical scroll, and progress updates');
  await browser.screenshot(join(output, 'extension-toolbar-scrolled.png'));
  await browser.send('Emulation.setDeviceMetricsOverride', { width: 760, height: 900, deviceScaleFactor: 1, mobile: false });
  await browser.until('Math.abs(parseFloat(getComputedStyle(document.body).paddingTop) - document.querySelector(".toolbar").getBoundingClientRect().height) < 1');
  const compactBar = await browser.evaluate(`(() => {
    const bar = document.querySelector('.toolbar').getBoundingClientRect();
    return { top: bar.top, right: bar.right, width: innerWidth,
      visible: [...document.querySelectorAll('.page-tools button, .toolbar-actions > button')].every(el => {
        const r = el.getBoundingClientRect(); return !r.width || r.left >= 0 && r.right <= innerWidth;
      }) };
  })()`);
  assert.equal(compactBar.top, 0);
  assert.equal(compactBar.visible, true, 'Responsive toolbar keeps its controls inside the viewport');
  await browser.screenshot(join(output, 'extension-toolbar-compact.png'));
  assert.deepEqual(browser.errors, [], 'No extension reader exceptions');
  console.log('PASS: Stable extension toolbar during scrolling/zoom/progress updates, responsive controls, PDF resolution, supersampling, page layouts, selection, lazy outline, cooperative indexing and teardown.');
  console.log(JSON.stringify({ webFit, webZoom: zoomed, extensionFit, extensionZoom }, null, 2));
} catch (error) {
  console.error(await browser?.evaluate('({ text: document.body.innerText.slice(0, 2000) })').catch(() => null));
  console.error(browser?.errors);
  throw error;
} finally {
  await browser?.close();
  server.close();
  await rm(root, { recursive: true, force: true });
}
