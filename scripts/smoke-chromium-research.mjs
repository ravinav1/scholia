import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { chromiumSession, sleep } from './lib/chromium.mjs';

const reads = [], completions = [], pending = new Set();
let cancelledReads = 0;
const external = createServer((request, response) => {
  reads.push(`external:${request.url}`);
  if (request.url === '/slow') {
    pending.add(response);
    response.on('close', () => { pending.delete(response); cancelledReads++; });
    return;
  }
  if (request.url === '/notes.txt') {
    response.writeHead(200, { 'content-type': 'text/plain' });
    response.end('Course diffusion attachment: D has units of square metres per second.'); return;
  }
  response.writeHead(200, { 'content-type': 'text/html' });
  response.end(request.url === '/reference?chapter=2'
    ? '<main><h1>Diffusion reference</h1><p>Reference diffusion coefficient is seven.</p><a href="/proof">Diffusion derivation</a><a href="/logout">Sign out</a><a href="/delete">Delete</a><a data-method="post" href="/change">Change</a></main>'
    : '<main><h1>Diffusion proof</h1><p>Nested diffusion proof uses conservation of mass.</p></main>');
});
await new Promise(resolve => external.listen(0, '127.0.0.1', resolve));
const externalOrigin = `http://127.0.0.1:${external.address().port}`;
let origin;
const server = createServer(async (request, response) => {
  reads.push(`canvas:${request.url}`);
  if (request.url === '/notes.txt') {
    response.writeHead(200, { 'content-type': 'text/plain' });
    response.end('Course diffusion attachment: D has units of square metres per second.'); return;
  }
  if (request.url === '/chat/completions') {
    let body = ''; for await (const chunk of request) body += chunk;
    completions.push(JSON.parse(body));
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    response.end(`data: ${JSON.stringify({ choices: [{ delta: { content: 'Research answer with diffusion evidence.' } }] })}\n\ndata: [DONE]\n\n`); return;
  }
  if (request.url.startsWith('/api/')) {
    const path = new URL(request.url, origin).pathname;
    const data = path === '/api/v1/users/self' ? { id: 7 }
      : path === '/api/v1/courses/42' ? { id: 42, name: 'Diffusion course', syllabus_body: '<p>Exam covers diffusion.</p>' }
      : path.endsWith('/pages') ? [{ url: 'week1', title: 'Diffusion lecture', updated_at: 'v1' }]
      : path.endsWith('/pages/week1') ? { title: 'Diffusion lecture', body: `<p>Diffusion lecture describes Fick's law.</p><a href="${externalOrigin}/reference?chapter=2">Diffusion reference</a>` }
      : path.endsWith('/files') ? [{ id: 9, display_name: 'diffusion.txt', updated_at: 'v1', 'content-type': 'text/plain', url: `${origin}/notes.txt` }]
      : path.endsWith('/modules') ? [{ id: 1, items_count: 1, items: [{ type: 'ExternalUrl', title: 'Diffusion reference', external_url: `${externalOrigin}/reference?chapter=2` }] }] : [];
    response.writeHead(200, { 'content-type': 'application/json' }); response.end(JSON.stringify(data)); return;
  }
  response.writeHead(200, { 'content-type': 'text/html' });
  response.end('<!doctype html><html><head><title>Diffusion course</title></head><body class="ic-app"><main><h1>Diffusion course</h1><p>Course overview and reading materials.</p><a href="/courses/42/pages/week1">Diffusion lecture</a></main></body></html>');
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
origin = `http://127.0.0.1:${server.address().port}`;
let browser;
try {
  browser = await chromiumSession({ extensionPath: resolve('dist/chrome') });
  const { send, evaluate, until, click } = browser;
  await send('Emulation.setDeviceMetricsOverride', { width: 1200, height: 960, deviceScaleFactor: 1, mobile: false });
  const { targetInfos } = await send('Target.getTargets');
  const worker = targetInfos.find(target => target.type === 'service_worker' && target.url.endsWith('/service-worker.js'));
  assert.ok(worker, 'Extension worker loaded');
  const extension = worker.url.slice(0, worker.url.lastIndexOf('/'));
  await send('Page.navigate', { url: `${extension}/options.html` });
  await until('document.readyState === "complete"');
  const settings = await evaluate(`chrome.runtime.sendMessage({ type: 'SCHOLIA_SAVE_SETTINGS', settings: {
    provider: 'openai', apiKeys: { openai: 'local-smoke-key' }, includePageContext: false,
    models: { openai: 'gpt-5-mini' }, endpoints: { openai: ${JSON.stringify(`${origin}/chat/completions`)} }
  } })`);
  assert.equal(settings.ok, true);
  const source = await evaluate(`chrome.tabs.create({ url: ${JSON.stringify(`${origin}/courses/42`)}, active: false })`);
  await until(`chrome.tabs.get(${source.id}).then(tab => tab.status === 'complete')`);
  await evaluate(`chrome.storage.local.set({ 'scholia.chat-history.v1': [{
    id: 'research-smoke', createdAt: Date.now(), updatedAt: Date.now(),
    capture: { url: ${JSON.stringify(`${origin}/courses/42`)}, pageTitle: 'Diffusion course', followLinks: true,
      compactContextEnabled: false, contextEnabled: true, sourceKind: 'page' },
    messages: [{ role: 'user', content: 'Ready to study diffusion' }, { role: 'assistant', content: 'Ready.' }]
  }] })`);
  await send('Page.navigate', { url: `${extension}/chat.html?chat=research-smoke` });
  await until('document.querySelector("#chat-follow-links")?.getAttribute("aria-pressed") === "true"');
  const ask = question => evaluate(`(() => {
    document.querySelector('#composer').value = ${JSON.stringify(question)};
    document.querySelector('#composer-form').requestSubmit();
  })()`);
  await ask('Find diffusion lecture, attachment, reference, and proof details.');
  await until('!document.querySelector("#research-review").hidden');
  assert.equal(reads.some(path => path.includes('/api/')), false, 'No Canvas API reads before approval');
  assert.equal(completions.length, 0);
  assert.equal(await evaluate('document.querySelector("#send").getAttribute("aria-label")'), 'Stop research');
  await mkdir('output', { recursive: true });
  await browser.screenshot(resolve('output/chromium-research-review.png'));
  await click('#research-approve');
  await until(`!document.querySelector('#research-review').hidden && document.querySelector('#research-review-sites').textContent.includes(${JSON.stringify(externalOrigin)})`);
  assert.equal(reads.some(path => path.startsWith('external:')), false, 'Course file origin waits for approval');
  await click('#research-approve');
  await until('document.querySelector("#messages").textContent.includes("Research answer") && document.querySelector("#send").getAttribute("aria-label") === "Send"');
  assert.equal(completions.length, 1);
  const content = JSON.stringify(completions[0]);
  for (const evidence of ['Exam covers diffusion', "Fick's law", 'square metres per second', 'coefficient is seven', 'conservation of mass', '/reference?chapter=2']) assert.ok(content.includes(evidence), evidence);
  assert.ok(reads.includes('external:/proof'));
  assert.ok(!reads.some(path => /\/(logout|delete|change)/.test(path)), 'Action links never requested');
  assert.ok(await evaluate('document.querySelectorAll("#research-source-list a").length >= 5'));

  // A new normal-mode prompt reviews sites again. Stop while the review is
  // pending must never start a model response or fetch after the dialog closes.
  await ask('Find another diffusion source.');
  await until('!document.querySelector("#research-review").hidden');
  const beforeReviewStop = reads.length;
  await click('#send');
  await until('document.querySelector("#research-review").hidden && document.querySelector("#send").getAttribute("aria-label") === "Send"');
  await sleep(200);
  assert.equal(reads.length, beforeReviewStop); assert.equal(completions.length, 1);

  // Research can resume from its saved source even after the original tab is
  // closed; the extension fetches it and recognizes Canvas before indexing.
  await evaluate(`chrome.tabs.remove(${source.id})`);
  await click('#chat-research-yolo');
  assert.equal(await evaluate('document.querySelector("#chat-research-yolo").getAttribute("aria-pressed")'), 'true');
  await ask(`Find diffusion details at ${externalOrigin}/slow`);
  for (let i = 0; i < 100 && !pending.size; i++) await sleep(50);
  assert.equal(pending.size, 1, 'YOLO reached slow read without a review');
  assert.equal(await evaluate('document.querySelector("#research-review").hidden'), true);
  await click('#send');
  await until('document.querySelector("#send").getAttribute("aria-label") === "Send"');
  for (let i = 0; i < 40 && pending.size; i++) await sleep(50);
  assert.equal(pending.size, 0, 'Stop closed the pending HTTP read');
  assert.equal(completions.length, 1);

  await ask(`Find diffusion details at ${externalOrigin}/slow`);
  for (let i = 0; i < 100 && !pending.size; i++) await sleep(50);
  assert.equal(pending.size, 1);
  await click('#back-home');
  for (let i = 0; i < 40 && pending.size; i++) await sleep(50);
  assert.equal(pending.size, 0, 'Leaving chat cancels the read');
  assert.equal(completions.length, 1); assert.ok(cancelledReads >= 2);
  const afterClose = reads.length; await sleep(250); assert.equal(reads.length, afterClose);
  assert.equal(browser.errors.length, 0, JSON.stringify(browser.errors));
  console.log('PASS: Chromium Canvas + external files + multi-hop research, site review, YOLO, citations, and Stop/leave-chat cancellation.');
} catch (error) {
  if (browser) console.error(await browser.evaluate('document.body.innerText.slice(-5000)').catch(() => ''), JSON.stringify(browser.errors));
  throw error;
} finally {
  await browser?.close();
  for (const response of pending) response.destroy();
  server.closeAllConnections(); external.closeAllConnections(); server.close(); external.close();
}
