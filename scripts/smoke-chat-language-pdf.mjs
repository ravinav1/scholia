import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createHostedServer } from '../apps/server/server.js';
import { chromiumSession } from './smoke/browser/lib/chromium.mjs';

function readingPDF() {
  const count = 30;
  const objects = ['<< /Type /Catalog /Pages 2 0 R >>',
    `<< /Type /Pages /Kids [${Array.from({ length: count }, (_, i) => `${4 + i * 2} 0 R`).join(' ')}] /Count ${count} >>`,
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'];
  for (let page = 1; page <= count; page++) {
    const lines = Array.from({ length: 70 }, (_, i) => `Page ${page} line ${i + 1}. Evidence from the complete document connects ideas across its sections.`);
    lines[69] = `UNIQUE CONCLUSION ON PAGE ${page}`;
    const stream = `BT /F1 7 Tf 24 748 Td 10 TL ${lines.map((line, i) => `${i ? 'T* ' : ''}(${line}) Tj`).join('\n')} ET`;
    objects.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${5 + (page - 1) * 2} 0 R >>`);
    objects.push(`<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`);
  }
  let text = '%PDF-1.4\n';
  const offsets = [];
  objects.forEach((object, i) => { offsets.push(text.length); text += `${i + 1} 0 obj\n${object}\nendobj\n`; });
  const offset = text.length;
  text += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${offsets.map((n) => `${String(n).padStart(10, '0')} 00000 n \n`).join('')}trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${offset}\n%%EOF\n`;
  return Buffer.from(text);
}

const root = await mkdtemp(join(tmpdir(), 'scholia-language-pdf-'));
const file = join(root, 'Complete reading.pdf');
const pdf = readingPDF();
await writeFile(file, pdf);
const providerRequests = [];
const provider = createServer(async (request, response) => {
  response.setHeader('Access-Control-Allow-Origin', '*');
  response.setHeader('Access-Control-Allow-Headers', '*');
  if (request.method === 'OPTIONS') return response.end();
  let body = ''; for await (const chunk of request) body += chunk;
  providerRequests.push(JSON.parse(body));
  response.writeHead(200, { 'Content-Type': 'text/event-stream' });
  response.end(`data: ${JSON.stringify({ choices: [{ delta: { content: 'Complete PDF received.' } }] })}\n\ndata: [DONE]\n\n`);
});
await new Promise((resolve) => provider.listen(0, '127.0.0.1', resolve));
const reserve = createServer();
await new Promise((resolve) => reserve.listen(0, '127.0.0.1', resolve));
const port = reserve.address().port;
await new Promise((resolve) => reserve.close(resolve));
const origin = `http://127.0.0.1:${port}`;
const requests = [];
const app = createHostedServer({ root: join(root, 'account'), origin, complete: async (payload, _settings, onToken) => {
  requests.push(payload); onToken('Complete PDF received.'); return { text: 'Complete PDF received.' };
} });
let browser;
try {
  const user = await app.store.createUser('reader@example.com', 'test reading password');
  const account = app.workspaces.account(user.id);
  const course = { id: randomUUID(), name: 'Reading', code: 'READ101', documents: [], threads: [], canvasMaterials: [] };
  account.library.courses.push(course);
  const doc = await app.workspaces.importFile(account, course, 'Complete reading.pdf', pdf);
  app.store.save(account);
  await new Promise((resolve) => app.server.listen(port, '127.0.0.1', resolve));
  browser = await chromiumSession({ extensionPath: resolve('dist/chrome') });
  const { send, evaluate, until, click } = browser;
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  await send('Page.navigate', { url: origin });
  await until('document.querySelector("#sign-in") && document.readyState === "complete"');
  await evaluate(`document.querySelector('[name=email]').value='reader@example.com'; document.querySelector('[name=password]').value='test reading password'; document.querySelector('#sign-in').requestSubmit()`);
  await until('document.querySelector(".study-dashboard")');
  await click(`[data-action=course][data-id="${course.id}"]`);
  await until(`document.querySelector('.course-materials [data-action=document][data-id="${doc.id}"]')`);
  await click(`.course-materials [data-action=document][data-id="${doc.id}"]`);
  await until('document.querySelector("[data-pdf=entirePDF]") && document.querySelector(".page[data-loaded]")');
  await evaluate(`const language = document.querySelector('#response-language'); language.value='no'; language.dispatchEvent(new Event('change', { bubbles:true }));`);
  await until(`document.querySelector('#response-language').value === 'no'`);
  await click('[data-pdf=entirePDF]');
  await until('document.querySelector("#messages").textContent.includes("Complete PDF received.") && document.querySelector("#send").getAttribute("aria-label") === "Send question"');
  assert.equal(requests.at(-1).language, 'no');
  assert.equal(requests.at(-1).entirePDF, true);
  assert.ok(requests.at(-1).context.length > 140_000);
  assert.match(requests.at(-1).context, /UNIQUE CONCLUSION ON PAGE 30/);
  assert.equal(await evaluate('document.querySelector("#entire-pdf").checked'), true);
  await send('Page.reload');
  await until('document.querySelector("#response-language")?.value === "no" && document.querySelector("#entire-pdf")?.checked');
  await browser.screenshot('/private/tmp/scholia-language-entire-pdf-web.png');
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: false });
  await until('innerWidth === 390');
  assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'), true, 'Chat controls fit a narrow viewport');
  await browser.screenshot('/private/tmp/scholia-language-entire-pdf-mobile.png');
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });

  const targets = await send('Target.getTargets');
  const worker = targets.targetInfos.find((target) => target.type === 'service_worker' && target.url.endsWith('/service-worker.js'));
  assert.ok(worker);
  const extension = worker.url.slice(0, worker.url.lastIndexOf('/'));
  await send('Page.navigate', { url: `${extension}/pdf-viewer.html` });
  await until('document.querySelector("#pdf-file") && document.readyState === "complete"');
  await evaluate(`chrome.runtime.sendMessage({ type:'SCHOLIA_SAVE_SETTINGS', settings:{provider:'openai', apiKeys:{openai:'test-key'}, models:{openai:'gpt-5-mini'}, endpoints:{openai:'http://127.0.0.1:${provider.address().port}/chat/completions'}} })`);
  const { root: documentNode } = await send('DOM.getDocument');
  const { nodeId } = await send('DOM.querySelector', { nodeId: documentNode.nodeId, selector: '#pdf-file' });
  await send('DOM.setFileInputFiles', { nodeId, files: [file] });
  await until('document.querySelector("#page-total")?.textContent === "30" && !document.querySelector("#send-entire-pdf").disabled');
  await click('#send-entire-pdf');
  const panel = 'document.querySelector("#pdf-chat-content").shadowRoot';
  await until(`${panel}?.querySelector('#messages')?.textContent.includes('Complete PDF received.')`);
  assert.match(providerRequests.at(-1).messages[0].content, /Read every supplied PDF page/);
  assert.match(providerRequests.at(-1).messages.at(-1).content, /UNIQUE CONCLUSION ON PAGE 30/);
  assert.ok(providerRequests.at(-1).messages.at(-1).content.length > 140_000);
  await evaluate(`{ const language = ${panel}.querySelector('[data-response-language]'); language.value='no'; language.dispatchEvent(new Event('change')); }`);
  await until(`${panel}.querySelector('[data-response-language]').value === 'no' && !${panel}.querySelector('[data-response-language]').disabled`);
  await evaluate(`${panel}.querySelector('#composer').value = 'Explain the conclusion'; ${panel}.querySelector('#composer-form').requestSubmit()`);
  await until(`${panel}.querySelectorAll('#messages .message--assistant').length === 2 && !${panel}.querySelector('.caret')`);
  assert.match(providerRequests.at(-1).messages[0].content, /Svar på norsk bokmål/);
  assert.match(providerRequests.at(-1).messages.at(-1).content, /UNIQUE CONCLUSION ON PAGE 30/);
  await browser.screenshot('/private/tmp/scholia-language-entire-pdf-extension.png');
  await send('Page.navigate', { url: `${extension}/popup.html` });
  await until('document.querySelector("[data-response-language]")?.value === "no"');
  await evaluate(`{ const language=document.querySelector('[data-response-language]'); language.value='auto'; language.dispatchEvent(new Event('change')); }`);
  await until('document.querySelector("[data-response-language]").value === "auto" && !document.querySelector("[data-response-language]").disabled');
  await send('Page.reload');
  await until('document.querySelector("[data-response-language]")?.value === "auto" && document.querySelector("[data-response-language]").options.length === 3');
  assert.deepEqual(browser.errors, []);
  console.log('PASS: Chromium web and real extension, global language persistence, full 30-page PDF, intact final page and follow-up context.');
} catch (error) {
  if (browser) console.error(await browser.evaluate('({ url: location.href, text: document.body?.innerText.slice(0, 1200) })').catch(() => null), browser.errors);
  throw error;
} finally {
  await browser?.close();
  await app.close();
  await new Promise((resolve) => provider.close(resolve));
  await rm(root, { recursive: true, force: true });
}
