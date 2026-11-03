import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { onePagePdf } from '../tests/helpers/pdf.js';
import { chromiumSession, sleep } from './lib/chromium.mjs';

// Pages 2 and 4 have graphics without selectable text. OCR is deliberately
// held below so reader functionality is verified before enrichment completes.
function mixedPdf(label = 'Progressive indexing') {
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    `<< /Type /Pages /Kids [${Array.from({ length: 16 }, (_, i) => `${4 + i * 2} 0 R`).join(' ')}] /Count 16 >>`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
  ];
  for (let page = 1; page <= 16; page++) {
    const text = `Shared result on page ${page}. ${label}. `
      + 'Vectors and matrices describe linear transformations and their eigenvalues. '.repeat(5);
    const stream = [2, 4].includes(page) ? '20 30 60 70 re f'
      : `BT /F1 8 Tf 24 740 Td (${text}) Tj ET`;
    objects.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${5 + (page - 1) * 2} 0 R >>`);
    objects.push(`<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`);
  }
  let pdf = `%PDF-1.4\n%${label}\n`;
  const offsets = [];
  objects.forEach((object, index) => {
    offsets.push(pdf.length);
    pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const xref = pdf.length;
  pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  pdf += offsets.map((offset) => `${String(offset).padStart(10, '0')} 00000 n \n`).join('');
  pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(pdf);
}

const root = await mkdtemp(join(tmpdir(), 'scholia-pdf-indexing-'));
const chatRequests = [];
const server = createServer(async (request, response) => {
  response.setHeader('Access-Control-Allow-Origin', '*');
  response.setHeader('Access-Control-Allow-Headers', '*');
  if (request.method !== 'POST') { response.end(); return; }
  let body = '';
  for await (const chunk of request) body += chunk;
  chatRequests.push(JSON.parse(body));
  response.writeHead(200, { 'Content-Type': 'text/event-stream' });
  response.end(`data: ${JSON.stringify({ choices: [{ delta: { content: 'Reader is available.' } }] })}\n\ndata: [DONE]\n\n`);
});
await new Promise((done) => server.listen(0, '127.0.0.1', done));
const mixedFile = join(root, 'progressive.pdf');
const otherScan = join(root, 'other-scan.pdf');
const replacement = join(root, 'replacement.pdf');
const bytes = mixedPdf();
await writeFile(mixedFile, bytes);
await writeFile(otherScan, mixedPdf('Cancelled scan'));
await writeFile(replacement, onePagePdf('Replacement document with fresh context'));
let browser;
try {
  browser = await chromiumSession({ extensionPath: resolve('dist/chrome') });
  const { send, evaluate, until, click } = browser;
  const targets = await send('Target.getTargets');
  const worker = targets.targetInfos.find((target) => target.type === 'service_worker' && target.url.endsWith('/service-worker.js'));
  assert.ok(worker, 'Extension loaded in Chromium');
  const extension = worker.url.slice(0, worker.url.lastIndexOf('/'));
  const downloads = join(root, 'downloads');
  await mkdir(downloads);
  await send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: downloads });
  await send('Emulation.setDeviceMetricsOverride', { width: 1400, height: 900, deviceScaleFactor: 1, mobile: false });
  await send('Page.navigate', { url: `${extension}/pdf-viewer.html` });
  await until('document.readyState === "complete" && !document.querySelector("#error").hidden');
  const settings = await evaluate(`chrome.runtime.sendMessage({ type: 'SCHOLIA_SAVE_SETTINGS', settings: {
    provider: 'openai', apiKeys: { openai: 'local-test-key' }, includePageContext: false,
    models: { openai: 'gpt-5-mini' }, endpoints: { openai: 'http://127.0.0.1:${server.address().port}/chat/completions' }
  } })`);
  assert.equal(settings.ok, true);
  await evaluate(`(() => {
    const original = chrome.runtime.sendMessage.bind(chrome.runtime);
    globalThis.heldOCR = [];
    globalThis.ocrCalls = 0;
    globalThis.ocrCancelled = 0;
    chrome.runtime.sendMessage = (payload, ...args) => {
      if (payload.type === 'SCHOLIA_OCR_RECOGNIZE') {
        ocrCalls++;
        heldOCR.push(args[0]);
      } else if (payload.type === 'SCHOLIA_OCR_CANCEL') {
        ocrCancelled++;
        args[0]?.({ ok: true });
      } else return original(payload, ...args);
    };
    globalThis.releaseOCR = (failure = false) => heldOCR.shift()(failure
      ? { ok: false, error: 'Deliberate OCR failure' }
      : { ok: true, value: { text: 'Shared result from scanned diagram. OCRTOKEN eigenvectors and diagonalization.', confidence: 99 } });

    // Hold text extraction on an offscreen page as well. Stream follow-up
    // messages must stay queued with the original PDF.js request.
    const post = Worker.prototype.postMessage;
    globalThis.heldText = [];
    globalThis.textRequests = 0;
    let holdText = true;
    const streams = new WeakMap();
    Worker.prototype.postMessage = function(value, ...args) {
      if (value?.action === 'GetTextContent') textRequests++;
      if (holdText && value?.action === 'GetTextContent' && value.data?.pageIndex === 8) {
        if (!streams.has(this)) streams.set(this, new Set());
        streams.get(this).add(value.streamId);
      }
      if (holdText && streams.get(this)?.has(value?.streamId)) heldText.push([this, value, args]);
      else return post.call(this, value, ...args);
    };
    globalThis.releaseText = () => {
      holdText = false;
      for (const [worker, value, args] of heldText.splice(0)) post.call(worker, value, ...args);
    };
    window.print = () => {
      globalThis.printCapture = {
        pages: document.querySelectorAll('#print-pages .printed-page').length,
        imagesReady: [...document.querySelectorAll('#print-pages img')].every((image) => image.complete && image.naturalWidth > 0),
        status: document.querySelector('#document-status').textContent
      };
      dispatchEvent(new Event('afterprint'));
    };
  })()`);
  async function openFile(path) {
    const { root: doc } = await send('DOM.getDocument');
    const { nodeId } = await send('DOM.querySelector', { nodeId: doc.nodeId, selector: '#pdf-file' });
    await send('DOM.setFileInputFiles', { nodeId, files: [path] });
  }
  async function search(query) {
    await evaluate(`(() => {
      const input = document.querySelector('#search-input');
      input.value = ${JSON.stringify(query)};
      input.dispatchEvent(new Event('input', { bubbles: true }));
    })()`);
  }
  await openFile(mixedFile);
  await until('heldText.length > 0 && !document.querySelector("#print-pdf").disabled');
  assert.equal(await evaluate('ocrCalls'), 0, 'Native text is indexed before OCR starts');
  const partial = await evaluate('globalThis.__scholiaGetPageMetadata()');
  assert.equal(partial.pdfIndexStage, 'basic');
  assert.ok(partial.extractedPageCount < 16);
  assert.match(partial.context, /indexing is still in progress/);
  await click('#search-toggle');
  await search('Shared result');
  await until('!document.querySelector("#search-next").disabled');
  assert.match(await evaluate('document.querySelector("#search-count").textContent'), /indexing/);

  // Printing renders every page without waiting for either text extraction
  // or OCR. The capture substitutes only Chromium's native print dialog.
  await click('#print-pdf');
  await until('globalThis.printCapture && !document.querySelector("#print-pdf").disabled', { timeoutMs: 30_000 });
  assert.deepEqual(await evaluate('({ pages: printCapture.pages, imagesReady: printCapture.imagesReady })'), { pages: 16, imagesReady: true });
  assert.match(await evaluate('printCapture.status'), /print preview/);
  assert.equal(await evaluate('document.querySelectorAll("#print-pages img").length'), 0);
  assert.equal(await evaluate('ocrCalls'), 0);
  await click('#download-pdf');
  let downloaded;
  for (let attempt = 0; attempt < 100; attempt++) {
    try { downloaded = await readFile(join(downloads, 'progressive.pdf')); break; } catch {}
    await sleep(50);
  }
  assert.deepEqual(downloaded, bytes, 'Download preserves the original PDF during basic indexing');
  // A tab switch must suspend background extraction, even though browser
  // timers continue firing. Keep visibility deterministic in headless mode.
  await evaluate(`Object.defineProperty(document, 'hidden', { configurable: true, value: true });
    document.dispatchEvent(new Event('visibilitychange')); releaseText();`);
  await sleep(200);
  const pausedRequests = await evaluate('textRequests');
  await sleep(250);
  assert.equal(await evaluate('textRequests'), pausedRequests, 'Hidden PDF tabs stop submitting text-extraction jobs');
  assert.equal(await evaluate('ocrCalls'), 0, 'Hidden tabs do not start OCR');
  await evaluate(`delete document.hidden; document.dispatchEvent(new Event('visibilitychange'));`);
  await until('heldOCR.length === 1');
  const basic = await evaluate('globalThis.__scholiaGetPageMetadata()');
  assert.equal(basic.pdfIndexStage, 'basic');
  assert.equal(basic.extractedPageCount, 16);
  assert.match(basic.context, /Shared result on page 16/);
  assert.doesNotMatch(basic.context, /OCRTOKEN/);

  // Start a real reader chat against the local test provider before OCR is
  // released, then verify the same conversation upgrades on its next turn.
  await click('#open-chat');
  const panel = "document.querySelector('#pdf-chat-content').shadowRoot";
  await until(`${panel}?.querySelector('#context-full')?.checked`);
  await evaluate(`${panel}.querySelector('#context-question').value = 'Explain the available text'; ${panel}.querySelector('#context-form').requestSubmit()`);
  await until(`${panel}.querySelector('#messages .message--assistant')?.textContent.includes('Reader is available.') && !${panel}.querySelector('.caret')`);
  assert.match(chatRequests.at(-1).messages.at(-1).content, /Shared result on page 16/);
  assert.doesNotMatch(chatRequests.at(-1).messages.at(-1).content, /OCRTOKEN/);
  assert.equal(await evaluate('heldOCR.length'), 1);
  await click('#pdf-chat-close');

  await search('Shared result on page 16');
  await until('document.querySelector("#page-number").value === "16" && document.querySelector(".pdf-search-highlight.is-current")');
  await evaluate(`(() => {
    const zoom = document.querySelector('#zoom-label');
    zoom.value = '1.25'; zoom.dispatchEvent(new Event('change', { bubbles: true }));
  })()`);
  await until(`document.querySelector('#zoom-label').value === '1.25' && document.querySelector('.pdf-page[data-page-number="16"] .textLayer span')`);
  const selection = await evaluate(`(() => {
    const range = document.createRange();
    range.selectNodeContents(document.querySelector('.pdf-page[data-page-number="16"] .pdf-search-highlight'));
    getSelection().removeAllRanges(); getSelection().addRange(range);
    return getSelection().toString();
  })()`);
  assert.match(selection, /Shared result on page 16/);
  const selectedContext = await evaluate('globalThis.__scholiaGetPageMetadata({ forSelection: true, fullContext: true })');
  assert.match(selectedContext.context, /Shared result on page 16/);
  assert.equal(await evaluate('heldOCR.length'), 1, 'Selection and chat context do not wait for OCR');

  await evaluate('releaseOCR()');
  await until('heldOCR.length === 1 && ocrCalls === 2');
  assert.equal(await evaluate('getSelection().toString()'), selection, 'Enrichment preserves text selection');
  assert.equal(await evaluate('document.querySelector("#page-number").value'), '16');
  await evaluate('getSelection().removeAllRanges()');
  // An OCR result on an earlier page must not replace the active search hit.
  await search('Shared result');
  await until('document.querySelector("#search-count").textContent.startsWith("1 / 15")');
  await click('#search-previous');
  await until('document.querySelector("#page-number").value === "16"');
  await evaluate('releaseOCR()');
  await until('/semantic search ready/.test(document.querySelector("#document-status").textContent)');
  assert.equal(await evaluate('document.querySelector("#page-number").value'), '16');
  assert.equal(await evaluate('document.querySelector("#search-count").textContent'), '16 / 16');
  const complete = await evaluate('globalThis.__scholiaGetPageMetadata()');
  assert.equal(complete.pdfIndexStage, 'complete');
  assert.equal(complete.ocrPageCount, 2);
  assert.match(complete.context, /OCRTOKEN/);
  await click('#open-chat');
  await evaluate(`${panel}.querySelector('#composer').value = 'Include the scanned diagrams now'; ${panel}.querySelector('#composer-form').requestSubmit()`);
  await until(`${panel}.querySelectorAll('#messages .message--assistant').length === 2 && !${panel}.querySelector('.caret')`);
  assert.match(chatRequests.at(-1).messages.at(-1).content, /OCRTOKEN/, 'Follow-ups adopt the enriched index automatically');
  await click('#pdf-chat-close');
  await search('OCRTOKEN');
  await until('document.querySelector("#search-count").textContent === "1 / 2"');
  await evaluate(`document.querySelector('#search-mode').value = 'semantic'; document.querySelector('#search-mode').dispatchEvent(new Event('change', { bubbles: true }))`);
  await until('!document.querySelector("#search-next").disabled && document.querySelector("#search-count").textContent.includes("pages")');
  await mkdir(resolve('dist/verification'), { recursive: true });
  await browser.screenshot(resolve('dist/verification/pdf-progressive-indexing.png'));

  // A completed index should restore its enriched text without repeating OCR.
  await until('document.querySelector("#document-status").textContent.includes("index cached")');
  await openFile(mixedFile);
  await until('/index restored from cache/.test(document.querySelector("#document-status").textContent)');
  assert.equal(await evaluate('ocrCalls'), 2);
  assert.match((await evaluate('globalThis.__scholiaGetPageMetadata()')).context, /OCRTOKEN/);

  // Switching documents cancels background recognition and rejects late data.
  await openFile(otherScan);
  await until('heldOCR.length === 1');
  await openFile(replacement);
  await until('document.querySelector("#page-total").textContent === "1" && /context ready/.test(document.querySelector("#document-status").textContent)');
  await evaluate('releaseOCR()');
  assert.equal(await evaluate('ocrCancelled'), 1);
  const fresh = await evaluate('globalThis.__scholiaGetPageMetadata()');
  assert.match(fresh.context, /Replacement document/);
  assert.doesNotMatch(fresh.context, /OCRTOKEN/);

  // Recognition errors leave basic search and printing usable.
  await openFile(otherScan);
  await until('heldOCR.length === 1');
  await evaluate('releaseOCR(true)');
  await until('heldOCR.length === 1');
  await evaluate('releaseOCR(true)');
  await until('/semantic search ready/.test(document.querySelector("#document-status").textContent)');
  const failed = await evaluate('globalThis.__scholiaGetPageMetadata()');
  assert.match(failed.context, /Shared result on page 16/);
  assert.match(failed.ocrNotice, /could not recover reliable text on 2 pages/);
  assert.equal(await evaluate('document.querySelector("#print-pdf").disabled'), false);
  assert.deepEqual(browser.errors, []);
  console.log('PASS: Chromium progressive PDF indexing, early search/chat, automatic chat context upgrade, full printing and original download while indexing is blocked, selection/position preservation, automatic semantic index, cache restore, cancellation, and OCR failure recovery.');
} catch (error) {
  if (browser) console.error(await browser.evaluate('({ text: document.body.innerText.slice(0, 1800), heldText: heldText?.length, heldOCR: heldOCR?.length, ocrCalls })').catch(() => null), browser.errors);
  throw error;
} finally {
  await browser?.close();
  await new Promise((done) => server.close(done));
  await rm(root, { recursive: true, force: true });
}
