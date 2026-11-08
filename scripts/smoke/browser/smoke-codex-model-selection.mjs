import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { createServer } from 'node:http';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { chromiumSession, sleep } from './lib/chromium.mjs';

// All provider traffic ends at this deterministic fixture. No Codex inference,
// installed extension, or existing browser profile is used.
const requests = [];
let catalogRequests = 0;
let catalogOffline = false;
const model = 'gpt-6.1-sol';
const efforts = ['low', 'medium', 'high', 'xhigh', 'max', 'ultra'];
const liveModels = [{ id: model, label: 'GPT-6.1 Sol', reasoning: { efforts, default: 'low' }, supportsImages: true }];
const server = createServer(async (request, response) => {
  response.setHeader('Access-Control-Allow-Origin', '*');
  response.setHeader('Content-Type', 'application/json');
  if (request.url === '/health') return response.end(JSON.stringify({ ok: true, images: true }));
  if (request.url === '/v1/models') {
    catalogRequests += 1;
    await sleep(350);
    if (catalogOffline) { response.statusCode = 503; return response.end('{}'); }
    return response.end(JSON.stringify({ data: liveModels }));
  }
  if (request.method === 'POST' && request.url === '/v1/chat/completions') {
    let body = '';
    for await (const chunk of request) body += chunk;
    requests.push(JSON.parse(body));
    response.setHeader('Content-Type', 'text/event-stream');
    return response.end(`data: ${JSON.stringify({ choices: [{ delta: { content: 'Fixture selection confirmed.' } }] })}\n\ndata: [DONE]\n\n`);
  }
  response.end('{}');
});
await new Promise((done) => server.listen(0, '127.0.0.1', done));
const endpoint = `http://127.0.0.1:${server.address().port}/v1/chat/completions`;
const directory = await mkdtemp(join(tmpdir(), 'scholia-model-selection-'));
let browser;
try {
  const { version } = JSON.parse(await readFile('package.json', 'utf8'));
  await promisify(execFile)('unzip', ['-q', resolve(`dist/scholia-chrome-${version}.zip`), '-d', directory]);
  browser = await chromiumSession({ extensionPath: directory });
  const { send, evaluate, until } = browser;
  let worker;
  for (let n = 0; n < 100 && !worker; n++) {
    worker = (await send('Target.getTargets')).targetInfos.find((target) => target.type === 'service_worker' && target.url.endsWith('/service-worker.js'));
    if (!worker) await sleep(100);
  }
  assert.ok(worker);
  const origin = worker.url.slice(0, worker.url.lastIndexOf('/'));
  const session = (await send('Target.attachToTarget', { targetId: worker.targetId, flatten: true })).sessionId;
  await send('Runtime.enable', {}, session);
  const workerEval = (source) => evaluate(source, session);
  const seed = async () => {
    await send('Page.navigate', { url: 'about:blank' });
    await workerEval(`chrome.storage.local.set({'scholia.settings.v1': ${JSON.stringify({
      provider: 'codex', models: { codex: 'gpt-5.5' }, endpoints: { codex: endpoint },
      reasoningEfforts: { codex: 'high' },
      // An older live cache can narrow the built-in model's supported efforts.
      discoveredModels: { codex: [{ id: model, reasoning: { efforts: ['low', 'high'], default: 'low' } }] },
      modelCatalogCheckedAt: { codex: 1 }
    })}})`);
  };
  const stored = () => workerEval("chrome.storage.local.get('scholia.settings.v1').then(value=>value['scholia.settings.v1'])");
  const surfaces = process.argv.includes('--options-only') ? ['options'] : ['popup', 'panel', 'options'];
  for (const surface of surfaces) {
    await seed();
    const beforeCatalogRequests = catalogRequests;
    await send('Page.navigate', { url: `${origin}/${surface}.html` });
    if (surface === 'options') {
      await until('document.querySelector("#model")?.value === "gpt-5.5"');
      await evaluate(`{const input=document.querySelector('#model');input.value='gpt-6.1-sol';input.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('#api-key').value='unsaved-fixture-token';document.querySelector('#language').value='no';}`);
      await until('[...document.querySelector("#reasoning").options].some(option=>option.value==="xhigh")', { timeoutMs: 5_000 });
      assert.equal(await evaluate('document.querySelector("#api-key").value'), 'unsaved-fixture-token', 'catalog refresh preserves unsaved credentials');
      assert.equal(await evaluate('document.querySelector("#language").value'), 'no', 'catalog refresh preserves other unsaved preferences');
      await evaluate(`document.querySelector('#reasoning').value='xhigh'; document.querySelector('#settings-form').requestSubmit()`);
      await until('document.querySelector("#status").textContent.startsWith("Saved.")');
    } else {
      await until('document.querySelector("#model-select")?.options.length > 0');
      await evaluate(`document.querySelector('#model-select').closest('.model-picker').querySelector('.model-picker-button').click()`);
      await evaluate(`{const input=document.querySelector('#model-select').closest('.model-picker').querySelector('input[type=search]');input.value='codex 6.1';input.dispatchEvent(new Event('input',{bubbles:true}));}`);
      await until('[...document.querySelectorAll(".model-picker-option")].some(option=>option.textContent.includes("gpt-6.1-sol"))');
      await evaluate(`[...document.querySelectorAll('.model-picker-option')].find(option=>option.textContent.includes('gpt-6.1-sol')).click()`);
      await until('!document.querySelector("#reasoning-select").disabled');
      await until('[...document.querySelector("#reasoning-select").options].some(option=>option.value==="xhigh")', { timeoutMs: 5_000 });
      assert.equal(await evaluate('document.querySelector("#model-select").value'), 'codex::gpt-6.1-sol', 'catalog arrival retains a model selected during discovery');
      await evaluate(`{const select=document.querySelector('#reasoning-select');select.value='xhigh';select.dispatchEvent(new Event('change',{bubbles:true}));}`);
      await until('!document.querySelector("#reasoning-select").disabled && document.querySelector("#reasoning-select").value === "xhigh"');
    }
    assert.ok(catalogRequests > beforeCatalogRequests, `${surface} refreshes its stale live catalog`);
    const saved = await stored();
    assert.equal(saved.provider, 'codex');
    assert.equal(saved.models.codex, model);
    assert.equal(saved.reasoningEfforts.codex, 'xhigh', `${surface} persists Extra high`);
    if (surface === 'options') {
      assert.equal(saved.apiKeys.codex, 'unsaved-fixture-token');
      assert.equal(saved.language, 'no');
    }
    await send('Page.reload');
    const select = surface === 'options' ? '#reasoning' : '#reasoning-select';
    await until(`document.querySelector(${JSON.stringify(select)})?.value === 'xhigh'`);
  }
  // Dispatch through the actual popup and service worker to the local fixture.
  await send('Page.navigate', { url: `${origin}/popup.html` });
  await until('document.querySelector("#reasoning-select")?.value === "xhigh"');
  await evaluate(`document.querySelector('#quick-none').click();document.querySelector('#quick-input').value='Verify the selected model.';document.querySelector('#quick-form').requestSubmit()`);
  for (let n = 0; n < 100 && !requests.length; n++) await sleep(100);
  assert.equal(requests.length, 1);
  assert.equal(requests[0].model, model);
  assert.equal(requests[0].reasoning_effort, 'xhigh');
  await until('document.querySelector("#quick-messages").textContent.includes("Fixture selection confirmed.")');

  // Reopening the picker uses the bounded catalog cache. A later failed refresh
  // preserves the known capabilities, selected model, effort and credentials.
  const beforeCachedOpen = catalogRequests;
  for (let n = 0; n < 3; n++) {
    await evaluate(`document.querySelector('#model-select').dispatchEvent(new Event('scholia-model-picker-open'))`);
  }
  await sleep(450);
  assert.equal(catalogRequests, beforeCachedOpen, 'repeated opens within the TTL do not rediscover models');
  catalogOffline = true;
  await send('Page.navigate', { url: 'about:blank' });
  const lastWorking = await stored();
  await workerEval(`chrome.storage.local.set({'scholia.settings.v1': ${JSON.stringify({ ...lastWorking, modelCatalogCheckedAt: { codex: 1 } })}})`);
  await send('Page.navigate', { url: `${origin}/popup.html` });
  await until('document.querySelector("#reasoning-select")?.value === "xhigh"');
  for (let n = 0; n < 100 && catalogRequests === beforeCachedOpen; n++) await sleep(50);
  assert.equal(catalogRequests, beforeCachedOpen + 1);
  await until(`chrome.storage.local.get('scholia.settings.v1').then(value=>value['scholia.settings.v1'].modelCatalogCheckedAt.codex>1)`);
  const offline = await stored();
  assert.equal(offline.models.codex, model);
  assert.equal(offline.reasoningEfforts.codex, 'xhigh');
  assert.deepEqual(offline.discoveredModels.codex, lastWorking.discoveredModels.codex);
  assert.deepEqual(offline.apiKeys, lastWorking.apiKeys);
  await evaluate(`document.querySelector('#model-select').dispatchEvent(new Event('scholia-model-picker-open'))`);
  await sleep(450);
  assert.equal(catalogRequests, beforeCachedOpen + 1, 'failed refresh is throttled too');
  assert.equal(browser.errors.length, 0, JSON.stringify(browser.errors));
  console.log(JSON.stringify({ browser: (await send('Browser.getVersion')).product, packaged: true, surfaces, model, reasoningEffort: 'xhigh', catalogRequests, cachedOpensVerified: true, offlineRetentionVerified: true, fixtureCompletions: requests.length, paidInference: false, exceptions: browser.errors.length }));
} finally {
  await browser?.close();
  await rm(directory, { recursive: true, force: true });
  await new Promise((done) => server.close(done));
}
