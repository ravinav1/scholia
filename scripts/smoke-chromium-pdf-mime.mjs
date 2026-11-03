import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, mkdir, readFile, writeFile, cp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { chromiumSession, sleep } from './lib/chromium.mjs';

// Two pages exercise the History API crash regression through navigation and
// reload, not just the initial MIME-handler load.
function twoPagePdf() {
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [4 0 R 6 0 R] /Count 2 >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
  ];
  for (let page = 1; page <= 2; page++) {
    const stream = `BT /F1 14 Tf 40 740 Td (Original URL page ${page}. Vectors and matrices describe linear transformations.) Tj ET`;
    objects.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${5 + (page - 1) * 2} 0 R >>`);
    objects.push(`<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`);
  }
  let pdf = '%PDF-1.4\n';
  const offsets = [];
  objects.forEach((object, i) => { offsets.push(pdf.length); pdf += `${i + 1} 0 obj\n${object}\nendobj\n`; });
  const xref = pdf.length;
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  pdf += offsets.map(offset => `${String(offset).padStart(10, '0')} 00000 n \n`).join('');
  return Buffer.from(`${pdf}trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`);
}

const root = await mkdtemp(join(tmpdir(), 'scholia-pdf-mime-'));
const bytes = twoPagePdf();
const file = join(root, 'local notes.pdf');
await writeFile(file, bytes);
const requests = [];
const server = createServer((request, response) => {
  requests.push({ method: request.method, url: request.url });
  if (request.url === '/embed') {
    response.setHeader('Content-Type', 'text/html');
    response.end('<!doctype html><iframe title="Embedded PDF" src="/embedded.pdf" style="width:100%;height:90vh"></iframe>');
  } else if (request.url === '/post-form') {
    response.setHeader('Content-Type', 'text/html');
    response.end('<!doctype html><form method="post" action="/post-only"><button>Open</button></form>');
  } else if (request.url === '/post-only' && request.method !== 'POST') {
    response.writeHead(405); response.end('This PDF must not be fetched twice');
  } else {
    response.writeHead(200, { 'Content-Type': 'application/pdf', 'Content-Disposition': 'inline; filename="notes.pdf"' });
    response.end(bytes);
  }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
let browser;
try {
  browser = await chromiumSession({ extensionPath: resolve('dist/chrome') });
  const { send, evaluate, until } = browser;
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 2, mobile: false });
  const targets = await send('Target.getTargets');
  const worker = targets.targetInfos.find(target => target.type === 'service_worker' && target.url.endsWith('/service-worker.js'));
  assert.ok(worker);
  const extension = worker.url.slice(0, worker.url.lastIndexOf('/'));
  const handler = `${extension}/pdf-viewer.html`;
  let frameId;
  let attachedSession;
  async function reader() {
    if (attachedSession) await send('Target.detachFromTarget', { sessionId: attachedSession }).catch(() => {});
    // Reload may reuse the iframe target while replacing its execution context.
    await sleep(300);
    let target;
    for (let i = 0; i < 100; i++) {
      const { targetInfos } = await send('Target.getTargets');
      target = targetInfos.find(target => target.type === 'iframe' && target.url === handler);
      if (target) break;
      await sleep(100);
    }
    if (!target) {
      console.error(await send('Target.getTargets'));
      console.error(await evaluate('({url:location.href,html:document.body.innerHTML.slice(0,800)})'));
      console.error(requests);
    }
    assert.ok(target, 'Chromium loads Scholia as an embedded MIME handler');
    frameId = target.targetId;
    const { sessionId } = await send('Target.attachToTarget', { targetId: frameId, flatten: true });
    attachedSession = sessionId;
    await send('Runtime.enable', {}, sessionId);
    await until('document.querySelector(".pdf-page .textLayer span") && !document.querySelector("#print-pdf").disabled', { sessionId });
    return sessionId;
  }
  const original = `${origin}/notes.pdf`;
  await send('Page.navigate', { url: original });
  let sessionId = await reader();
  console.log('MIME: opened original URL');
  assert.equal(await evaluate('location.href'), original);
  await evaluate(`(() => { const input=document.querySelector('#page-number');input.value='2';input.dispatchEvent(new Event('change')); })()`, sessionId);
  await until('JSON.parse(sessionStorage.getItem("scholia.pdf-reading-position.v1"))?.pageNumber === 2', { sessionId });
  await send('Page.reload');
  sessionId = await reader();
  console.log('MIME: reloaded reader');
  await until('document.querySelector("#page-number").value === "2"', { sessionId });
  assert.equal(await evaluate('location.href'), original, 'Reload preserves the original address and reading position');
  await evaluate('document.querySelector("#open-chat").click()', sessionId);
  await until('document.querySelector("#pdf-chat-content").shadowRoot?.querySelector("#home-view")', { sessionId });
  const metadata = await evaluate('globalThis.__scholiaGetPageMetadata()', sessionId);
  assert.match(metadata.context, /Original URL page 2/);
  const downloads = join(root, 'downloads');
  await mkdir(downloads);
  await send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: downloads });
  await evaluate('document.querySelector("#download-pdf").click()', sessionId);
  let downloaded;
  for (let i = 0; i < 100; i++) {
    try { downloaded = await readFile(join(downloads, 'notes.pdf')); break; } catch { await sleep(50); }
  }
  assert.deepEqual(downloaded, bytes, 'MIME reader downloads the original bytes');
  await evaluate('document.querySelector("#choose-file").click()', sessionId);
  const opened = (await send('Target.getTargets')).targetInfos.find(target => target.type === 'page' && target.url === `${handler}?open=1`);
  assert.ok(opened, 'Opening another PDF starts a separate chooser');
  assert.equal(await evaluate('location.href'), original, 'The chooser does not mislabel a replacement file with the old address');
  await send('Target.closeTarget', { targetId: opened.targetId });
  await mkdir(resolve('dist/verification/pdf-quality'), { recursive: true });
  await browser.screenshot(resolve('dist/verification/pdf-quality/original-url-reader.png'));
  await evaluate('document.querySelector("#open-native").click()', sessionId);
  let nativeTarget;
  for (let i = 0; i < 100; i++) {
    const { targetInfos } = await send('Target.getTargets');
    nativeTarget = targetInfos.find(target => target.url.startsWith('chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/'));
    if (nativeTarget) break;
    await sleep(100);
  }
  assert.ok(nativeTarget, 'Chrome view opens the built-in PDF renderer');
  assert.equal(await evaluate('location.href'), original, 'Chrome-view fallback keeps the address');
  console.log('MIME: navigation, chat, download and native fallback passed');

  await send('Page.navigate', { url: pathToFileURL(file).href });
  sessionId = await reader();
  assert.equal(await evaluate('location.href'), pathToFileURL(file).href, 'Local PDF keeps its file URL without enabling file access');
  console.log('MIME: local file passed');
  await send('Page.navigate', { url: `${origin}/embed` });
  sessionId = await reader();
  assert.equal(await evaluate('location.href'), `${origin}/embed`, 'Embedded reader preserves its containing site');
  console.log('MIME: embedded PDF passed');
  await evaluate('document.querySelector("#page-number").value="2"; document.querySelector("#page-number").dispatchEvent(new Event("change"))', sessionId);
  await until('document.querySelector("#page-number").value === "2"', { sessionId });

  await send('Page.navigate', { url: `${origin}/post-form` });
  await until('document.querySelector("form")');
  await evaluate('document.querySelector("form").submit()');
  sessionId = await reader();
  assert.equal(await evaluate('location.href'), `${origin}/post-only`);
  assert.deepEqual(requests.filter(request => request.url === '/post-only'), [{ method: 'POST', url: '/post-only' }], 'The handler consumes the original response without refetching');
  assert.deepEqual(browser.errors, [], 'No MIME reader exceptions');
  console.log('PASS: Chromium original-URL PDF reader, page navigation, reload, local files, embedded PDFs, POST streams, chat, downloads and native fallback.');
  await browser.close();

  // An unregistered build exercises the same capability fallback used on
  // Chromium versions that predate the public MIME API.
  const compatibility = join(root, 'compatibility');
  await cp(resolve('dist/chrome'), compatibility, { recursive: true });
  const manifest = JSON.parse(await readFile(join(compatibility, 'manifest.json'), 'utf8'));
  delete manifest.mime_types_handler;
  await writeFile(join(compatibility, 'manifest.json'), JSON.stringify(manifest));
  browser = await chromiumSession({ extensionPath: compatibility });
  const compatibilityWorker = (await browser.send('Target.getTargets')).targetInfos
    .find(target => target.type === 'service_worker' && target.url.endsWith('/service-worker.js'));
  assert.ok(compatibilityWorker);
  await browser.send('Page.navigate', { url: compatibilityWorker.url.replace('service-worker.js', 'pdf-viewer.html?open=1') });
  await browser.until('document.readyState === "complete" && document.querySelector("#error")?.hidden === false');
  await browser.evaluate(`document.querySelector('#pdf-address').value=${JSON.stringify(original)}; document.querySelector('#manual-pdf-form').requestSubmit()`);
  await browser.until('location.protocol === "chrome-extension:" && location.search.includes("source=")');
  await browser.until('document.querySelector(".pdf-page .textLayer span")');
  const fallbackUrl = await browser.evaluate('location.href');
  await browser.send('Page.reload');
  await browser.until('document.querySelector(".pdf-page .textLayer span")');
  assert.equal(await browser.evaluate('location.href'), fallbackUrl, 'Compatibility tabs remain usable after reload');
  assert.deepEqual(browser.errors, []);
  console.log('PASS: Standalone PDF compatibility path opens and reloads without MIME registration.');
} finally {
  await browser?.close();
  server.close();
  await rm(root, { recursive: true, force: true });
}
