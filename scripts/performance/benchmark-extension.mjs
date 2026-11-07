import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile, writeFile, mkdir, mkdtemp, rm } from 'node:fs/promises';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { chromiumSession, sleep } from '../smoke/browser/lib/chromium.mjs';

const baseline = process.argv.includes('--baseline');
const stage = baseline ? 'before' : 'after';
const sampleCount = Number(process.env.SCHOLIA_BENCHMARK_SAMPLES || 10);
const requests = [];
const server = createServer(async (request, response) => {
  if (request.method === 'POST') {
    let body = ''; for await (const chunk of request) body += chunk;
    requests.push(JSON.parse(body));
    response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Access-Control-Allow-Origin': '*' });
    response.end('data: ' + JSON.stringify({ choices: [{ delta: { content: '**Fixture answer**: $x^2$\n\n```js\nconst answer = 42;\n```' } }] }) + '\n\ndata: [DONE]\n\n');
    return;
  }
  response.writeHead(200, { 'Content-Type': 'text/html', 'Content-Security-Policy': "default-src 'self'; script-src 'none'; frame-src 'self'; style-src 'self' 'unsafe-inline'" });
  response.end(`<!doctype html><html><head><title>Extension fixture</title></head><body><p id="source">An eigenvector preserves its direction under a linear map.</p><p><math alttext="x^2"><msup><mi>x</mi><mn>2</mn></msup></math></p>${request.url?.startsWith('/nested') ? '' : '<iframe src="/nested"></iframe><iframe src="/nested?second"></iframe>'}</body></html>`);
});
await new Promise((done) => server.listen(0, '127.0.0.1', done));
const origin = `http://127.0.0.1:${server.address().port}`;
let browser, packageDirectory;
let extensionPath = resolve(process.env.SCHOLIA_EXTENSION_PATH || 'dist/chrome');
if (process.argv.includes('--packaged')) {
  packageDirectory = await mkdtemp(join(tmpdir(), 'scholia-extension-package-'));
  const { version } = JSON.parse(await readFile('package.json', 'utf8'));
  await promisify(execFile)('unzip', ['-q', resolve(`dist/scholia-chrome-${version}.zip`), '-d', packageDirectory]);
  extensionPath = packageDirectory;
}
const samples = [];
try {
  browser = await chromiumSession({ extensionPath });
  const { send, evaluate, until } = browser;
  let worker;
  for (let n = 0; n < 100 && !worker; n++) {
    worker = (await send('Target.getTargets')).targetInfos.find((target) => target.type === 'service_worker' && target.url.endsWith('/service-worker.js'));
    if (!worker) await sleep(100);
  }
  assert.ok(worker, 'packaged extension service worker starts');
  const workerSession = (await send('Target.attachToTarget', { targetId: worker.targetId, flatten: true })).sessionId;
  await send('Runtime.enable', {}, workerSession);
  const workerEval = (source) => evaluate(source, workerSession);
  await until('typeof chrome !== "undefined"', {sessionId:workerSession});
  await workerEval(`chrome.storage.local.set({'scholia.settings.v1': {provider:'openai',apiKeys:{openai:'fixture-key'},models:{openai:'gpt-4.1'},endpoints:{openai:${JSON.stringify(origin + '/v1/chat/completions')}},language:'en',explainOnSelection:true,includePageContext:true}})`);
  await send('Performance.enable');
  const metric = (metrics, name) => metrics.metrics.find((item) => item.name === name)?.value;
  for (let sample = -1; sample < sampleCount; sample++) {
    await send('Page.navigate', { url: `${origin}/?sample=${sample}` });
    await until('document.readyState === "complete"');
    // Fixed post-load settling window in both builds, not treated as paint latency.
    await sleep(150);
    const metrics = await send('Performance.getMetrics');
    const row = await evaluate(`({loadMs:performance.getEntriesByType('navigation')[0].loadEventEnd,hosts:document.querySelectorAll('#scholia-extension-root').length,nestedHosts:[...document.querySelectorAll('iframe')].map(frame=>frame.contentDocument.querySelectorAll('#scholia-extension-root').length)})`);
    Object.assign(row, { taskDurationMs: metric(metrics, 'TaskDuration') * 1000, scriptDurationMs: metric(metrics, 'ScriptDuration') * 1000, usedHeapBytes: metric(metrics, 'JSHeapUsedSize'), domNodes: metric(metrics, 'Nodes') });
    if (sample >= 0) samples.push(row);
    assert.equal(row.hosts, baseline ? 1 : 0, 'idle pages mount no rich UI after the split');
    assert.deepEqual(row.nestedHosts, baseline ? [1, 1] : [0, 0], 'nested frames stay lazy too');
  }
  const tabID = await workerEval(`chrome.tabs.query({url:${JSON.stringify(origin + '/*')}}).then(tabs=>tabs.find(tab=>tab.url.includes('sample='))?.id)`);
  assert.ok(tabID);
  const contextReply = await workerEval(`chrome.tabs.sendMessage(${tabID},{type:'SCHOLIA_GET_PAGE_CONTEXT',question:'What is an eigenvector?'},{frameId:0})`);
  assert.equal(contextReply.ok, true, contextReply.error);
  assert.match(contextReply.value.context, /eigenvector/);
  assert.equal(await evaluate('document.querySelectorAll("#scholia-extension-root").length'), baseline ? 1 : 0,
    'background context retrieval does not initialize rich UI');
  // A keyboard/toolbar request must retain its captured selection while loading.
  await evaluate(`{ const range=document.createRange();range.selectNodeContents(document.querySelector('#source'));getSelection().removeAllRanges();getSelection().addRange(range); }`);
  const started = performance.now();
  const response = await workerEval(`chrome.tabs.sendMessage(${tabID},{type:'SCHOLIA_EXPLAIN_CURRENT'},{frameId:0})`);
  assert.equal(response.ok, true, response.error);
  await until('!!document.querySelector("#scholia-extension-root")');
  let answerText = '';
  for (let n = 0; n < 200; n++) {
    const { root } = await send('DOM.getDocument', { depth: -1, pierce: true });
    const nodes = []; const visit = (node) => { nodes.push(node); for(const child of [...(node.children || []), ...(node.shadowRoots || []), ...(node.contentDocument ? [node.contentDocument] : [])]) visit(child); }; visit(root);
    answerText = nodes.filter((node) => node.nodeType === 3).map((node) => node.nodeValue).join('\n');
    if (answerText.includes('Fixture answer') && requests.length) break;
    await sleep(50);
  }
  assert.match(answerText, /Fixture answer/);
  assert.ok(requests[0].messages.some((message) => typeof message.content === 'string' && message.content.includes('eigenvector preserves')));
  assert.equal(requests[0].model, 'gpt-4.1', 'first answer uses persisted provider/model configuration');
  assert.equal(await evaluate('document.querySelectorAll("#scholia-extension-root").length'), 1);
  const firstAnswerMs = performance.now() - started;
  // The packaged content script must independently initialize within an ordinary
  // nested frame. No page-world bridge or relaxed CSP is used.
  const nested = await workerEval(`chrome.scripting.executeScript({target:{tabId:${tabID},allFrames:true},func:()=>{if(window===window.top)return false;const range=document.createRange();range.selectNodeContents(document.querySelector('#source'));getSelection().removeAllRanges();getSelection().addRange(range);return true;}})`);
  const frameID = nested.find((frame) => frame.result)?.frameId;
  assert.ok(frameID, 'a content-script world is available in the nested frame');
  const nestedResponse = await workerEval(`chrome.tabs.sendMessage(${tabID},{type:'SCHOLIA_EXPLAIN_CURRENT'},{frameId:${frameID}})`);
  assert.equal(nestedResponse.ok, true);
  for(let n=0;n<100 && requests.length<2;n++) await sleep(50);
  assert.equal(requests.length, 2, 'the first nested-frame answer uses the real provider transport');
  assert.ok(await evaluate('[...document.querySelectorAll("iframe")].some(frame=>frame.contentDocument.querySelectorAll("#scholia-extension-root").length===1)'));

  let retryVerified = false;
  if (!baseline) {
    await send('Page.navigate', {url: `${origin}/?retry=1`});
    await until('document.readyState === "complete"');
    await sleep(150);
    await send('Network.enable');
    const extension = worker.url.slice(0, worker.url.lastIndexOf('/'));
    await send('Network.setBlockedURLs', {urls:[extension + '/content-ui.js*']});
    const failed = await workerEval(`chrome.tabs.sendMessage(${tabID},{type:'SCHOLIA_EXPLAIN_CURRENT'},{frameId:0})`);
    assert.equal(failed.ok, false, 'blocked module download reports failure');
    assert.equal(await evaluate('document.querySelectorAll("#scholia-extension-root").length'), 0);
    await send('Network.setBlockedURLs', {urls:[]});
    const retries = await workerEval(`Promise.all([chrome.tabs.sendMessage(${tabID},{type:'SCHOLIA_EXPLAIN_CURRENT'},{frameId:0}),chrome.tabs.sendMessage(${tabID},{type:'SCHOLIA_EXPLAIN_CURRENT'},{frameId:0})])`);
    assert.ok(retries.every(reply=>reply.ok), 'concurrent retries succeed after module loading recovers');
    assert.equal(await evaluate('document.querySelectorAll("#scholia-extension-root").length'), 1,
      'concurrent retries mount exactly one interface');
    retryVerified = true;
  }
  const graph = await readFile(`results/performance/extension-bundle-${stage}.json`, 'utf8').then(JSON.parse).catch(() => null);
  const output = { stage, runtime: process.version, browser: (await send('Browser.getVersion')).product, platform: process.platform, build: packageDirectory ? 'Chrome Web Store zip extracted into isolated directory' : 'minified extension distribution', fixture: { topLevelFrames:1,nestedFrames:2,pageCSP:"script-src 'none'", localProvider:true }, procedure: { warmups:1,sampleCount,settleMs:150 }, samples, firstAnswerMs, retryVerified, providerRequests:requests.length, bundle:graph, errors:browser.errors };
  await mkdir('results/performance', { recursive: true });
  await writeFile(`results/performance/extension-runtime-${stage}.json`, JSON.stringify(output,null,2)+'\n');
  console.log(JSON.stringify({stage,sampleCount,firstAnswerMs,errors:browser.errors.length}));
  assert.equal(browser.errors.length, 0, 'no unhandled page or module errors');
} finally {
  await browser?.close();
  if (packageDirectory) await rm(packageDirectory, {recursive:true,force:true});
  await new Promise((done) => server.close(done));
}
