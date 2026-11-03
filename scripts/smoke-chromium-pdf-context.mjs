import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createCanvas } from '@napi-rs/canvas';
import { chromiumSession } from './lib/chromium.mjs';

function articlePdf({ scanned = false } = {}) {
  const canvas = createCanvas(1500, 1600), context = canvas.getContext('2d');
  context.fillStyle = 'white'; context.fillRect(0, 0, 1500, 1600);
  context.fillStyle = 'black'; context.font = '36px sans-serif';
  ['Scanned article evidence', 'Eigenvectors and diagonalization',
    'The scanned conclusion connects all results.',
    'Norske studienotater: teori og metoder.'].forEach((line, index) => context.fillText(line, 60, 150 + index * 100));
  const jpeg = canvas.toBuffer('image/jpeg');
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    `<< /Type /Pages /Kids [${Array.from({ length: 15 }, (_, i) => `${5 + i * 2} 0 R`).join(' ')}] /Count 15 >>`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    Buffer.concat([Buffer.from(`<< /Type /XObject /Subtype /Image /Width 1500 /Height 1600 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>\nstream\n`), jpeg, Buffer.from('\nendstream')])
  ];
  for (let number = 1; number <= 15; number++) {
    const scanPage = scanned || number === 8;
    const lines = Array.from({ length: 70 }, (_, i) => `Article page ${number} line ${i + 1}. Evidence supports the complete argument across all pages.`);
    lines[69] = `Unique conclusion for article page ${number}.`;
    const stream = scanPage ? 'q 560 0 0 650 26 80 cm /Scan Do Q'
      : `BT /F1 7 Tf 24 748 Td 10 TL ${lines.map((line, i) => `${i ? 'T* ' : ''}(${line}) Tj`).join('\n')} ET`;
    objects.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> /XObject << /Scan 4 0 R >> >> /Contents ${6 + (number - 1) * 2} 0 R >>`);
    objects.push(`<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`);
  }
  const chunks = [Buffer.from(`%PDF-1.4\n%${scanned ? 'scanned' : 'mixed'} article fixture\n`)], offsets = [];
  let size = chunks[0].length;
  objects.forEach((object, i) => {
    offsets.push(size);
    const chunk = Buffer.concat([Buffer.from(`${i + 1} 0 obj\n`), Buffer.from(object), Buffer.from('\nendobj\n')]);
    chunks.push(chunk); size += chunk.length;
  });
  chunks.push(Buffer.from(`xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${offsets.map((offset) => `${String(offset).padStart(10, '0')} 00000 n \n`).join('')}trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${size}\n%%EOF\n`));
  return Buffer.concat(chunks);
}

const requests = [];
const server = createServer(async (request, response) => {
  response.setHeader('Access-Control-Allow-Origin', '*');
  response.setHeader('Access-Control-Allow-Headers', '*');
  if (request.method === 'OPTIONS') { response.end(); return; }
  if (request.method !== 'POST') { response.end('Local OCR smoke'); return; }
  let body = ''; for await (const chunk of request) body += chunk;
  requests.push(JSON.parse(body));
  response.writeHead(200, { 'Content-Type': 'text/event-stream' });
  response.end(`data: ${JSON.stringify({ choices: [{ delta: { content: 'The entire article is available.' } }] })}\n\ndata: [DONE]\n\n`);
});
await new Promise((done) => server.listen(0, '127.0.0.1', done));
const root = await mkdtemp(join(tmpdir(), 'scholia-pdf-context-'));
const mixedFile = join(root, 'mixed-article.pdf'), scannedFile = join(root, 'scanned-article.pdf');
await writeFile(mixedFile, articlePdf());
await writeFile(scannedFile, articlePdf({ scanned: true }));
let browser;
try {
  browser = await chromiumSession({ extensionPath: resolve('dist/chrome') });
  const { send, evaluate, until } = browser;
  const targets = await send('Target.getTargets');
  const worker = targets.targetInfos.find((target) => target.type === 'service_worker' && target.url.endsWith('/service-worker.js'));
  assert.ok(worker, 'Extension service worker loaded');
  // URL.origin is null for extension URLs in Node.
  const extension = worker.url.slice(0, worker.url.lastIndexOf('/'));
  await send('Page.navigate', { url: `${extension}/pdf-viewer.html` });
  await until('document.readyState === "complete" && document.querySelector("#pdf-file") && !document.querySelector("#error").hidden');
  const settings = await evaluate(`chrome.runtime.sendMessage({ type: 'SCHOLIA_SAVE_SETTINGS', settings: {
    provider: 'openai', apiKeys: { openai: 'local-test-key' }, includePageContext: false,
    models: { openai: 'gpt-5-mini' }, endpoints: { openai: 'http://127.0.0.1:${server.address().port}/chat/completions' }
  } })`);
  assert.equal(settings.ok, true);
  async function openFile(path) {
    await evaluate("document.querySelector('#document-status').textContent = 'Opening test document'");
    const { root: doc } = await send('DOM.getDocument');
    const { nodeId } = await send('DOM.querySelector', { nodeId: doc.nodeId, selector: '#pdf-file' });
    await send('DOM.setFileInputFiles', { nodeId, files: [path] });
    await until("document.querySelector('#page-total')?.textContent === '15' && /context ready|index restored from cache/.test(document.querySelector('#document-status')?.textContent)", { timeoutMs: 120_000 });
  }
  await openFile(mixedFile);
  const metadata = await evaluate('globalThis.__scholiaGetPageMetadata()');
  assert.ok(metadata.context.length > 32_000 && metadata.context.length < 120_000);
  assert.equal(metadata.ocrPageCount, 1);
  assert.match(metadata.context, /Eigenvectors and diagonalization/);
  assert.match(metadata.context, /Unique conclusion for article page 15/);
  await evaluate("document.querySelector('#open-chat').click()");
  const panel = "document.querySelector('#pdf-chat-content').shadowRoot";
  await until(`${panel}?.querySelector('#context-full')?.checked`);
  await evaluate(`${panel}.querySelector('#context-question').value = 'Explain the article from beginning to end'; ${panel}.querySelector('#context-form').requestSubmit()`);
  await until(`${panel}.querySelector('#messages .message--assistant')?.textContent.includes('entire article')`);
  const full = requests.at(-1).messages.at(-1).content;
  assert.ok(full.includes(metadata.context), 'Full PDF reaches the provider intact');
  const saved = await evaluate("chrome.storage.local.get('scholia.chat-history.v1')");
  assert.ok(JSON.stringify(saved).includes('Unique conclusion for article page 15'));
  await evaluate(`${panel}.querySelector('#chat-context-mode').click()`);
  await until(`${panel}.querySelector('#context-state').textContent.includes('Compact') && !${panel}.querySelector('#send').disabled`);
  await evaluate(`${panel}.querySelector('#composer').value = 'Summarize the article'; ${panel}.querySelector('#composer-form').requestSubmit()`);
  await until(`${panel}.querySelectorAll('#messages .message--assistant').length === 2 && !${panel}.querySelector('.caret')`);
  const compact = requests.at(-1).messages.at(-1).content.match(/<scholia-context>\n([\s\S]*?)\n<\/scholia-context>/)?.[1];
  assert.ok(compact && compact.length <= 6_000);
  await evaluate(`${panel}.querySelector('#chat-context-full').click()`);
  await until(`${panel}.querySelector('#context-state').textContent.includes('Full') && !${panel}.querySelector('#send').disabled`);
  await evaluate(`${panel}.querySelector('#composer').value = 'Compare every page'; ${panel}.querySelector('#composer-form').requestSubmit()`);
  await until(`${panel}.querySelectorAll('#messages .message--assistant').length === 3 && !${panel}.querySelector('.caret')`);
  assert.ok(requests.at(-1).messages.at(-1).content.includes(metadata.context));
  // Exercise the toolbar's real module in an extension frame while the local
  // PDF stays active. No public download URL exists for this file.
  await evaluate(`(() => {
    const frame = document.createElement('iframe'); frame.id = 'smoke-popup';
    frame.src = chrome.runtime.getURL('popup.html'); document.body.append(frame);
  })()`);
  const popup = "document.querySelector('#smoke-popup').contentDocument";
  await until(`${popup}?.querySelector('#quick-context-state')?.textContent === 'Full'`);
  await evaluate(`${popup}.querySelector('#quick-input').value = 'Explain the full local PDF'; ${popup}.querySelector('#quick-form').requestSubmit()`);
  await until(`${popup}.querySelector('#quick-messages')?.textContent.includes('entire article')`);
  assert.ok(requests.at(-1).messages.at(-1).content.includes(metadata.context), 'Toolbar Full context uses the local PDF index');
  await evaluate("document.querySelector('#smoke-popup').remove()");
  await openFile(scannedFile);
  const scan = await evaluate('globalThis.__scholiaGetPageMetadata()');
  assert.equal(scan.ocrPageCount, 15, scan.ocrNotice);
  assert.equal((scan.context.match(/Eigenvectors and diagonalization/g) || []).length, 15);
  assert.equal(scan.extractedPageCount, 15);
  // Reopening must use the OCR-enriched cache, not an old empty text index.
  await openFile(mixedFile);
  assert.match((await evaluate('globalThis.__scholiaGetPageMetadata()')).context, /Eigenvectors and diagonalization/);
  console.log(`PASS: real Chromium extension, full ${metadata.context.length}-character 15-page PDF, Full/Compact switching, saved context, local OCR on all 15 scanned pages, and cached OCR text.`);
} catch (error) {
  if (browser) console.error(await browser.evaluate('({ url: location.href, title: document.title, text: document.body?.innerText.slice(0, 1000) })').catch(() => null), browser.errors);
  throw error;
} finally {
  await browser?.close();
  await new Promise((done) => server.close(done));
  await rm(root, { recursive: true, force: true });
}
