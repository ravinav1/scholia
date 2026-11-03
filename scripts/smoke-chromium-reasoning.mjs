import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { chromiumSession } from './lib/chromium.mjs';

// Use the real extension storage, service worker and request builder with a local
// provider. No credentials or external model calls are involved.
const requests = [];
const answer = '**An eigenvector keeps its direction.** A transformation can stretch or shrink it, but it stays on the same line.\n\nThink of an arrow drawn on a sheet of rubber: if stretching the sheet leaves that arrow pointing the same way, you have found an eigenvector.\n\nThe eigenvalue tells you how much the arrow stretches.';
const server = createServer(async (request, response) => {
  response.setHeader('Access-Control-Allow-Origin', '*');
  response.setHeader('Access-Control-Allow-Headers', '*');
  if (request.method === 'OPTIONS') return response.end();
  if (request.method !== 'POST') {
    response.setHeader('Content-Type', 'application/json');
    return response.end(JSON.stringify({ ok: true, data: [] }));
  }
  let source = ''; for await (const chunk of request) source += chunk;
  requests.push(JSON.parse(source));
  response.writeHead(200, { 'Content-Type': 'text/event-stream' });
  response.end(`data: ${JSON.stringify({ choices: [{ delta: { content: answer } }] })}\n\ndata: [DONE]\n\n`);
});
await new Promise((done) => server.listen(0, '127.0.0.1', done));
const origin = `http://127.0.0.1:${server.address().port}`;
const temporary = await mkdtemp(join(tmpdir(), 'scholia-reasoning-'));
let browser;
try {
  browser = await chromiumSession({ extensionPath: resolve('dist/chrome') });
  const { send, evaluate, until, click } = browser;
  const { targetInfos } = await send('Target.getTargets');
  const worker = targetInfos.find((target) => target.type === 'service_worker' && target.url.endsWith('/service-worker.js'));
  assert.ok(worker, 'The real extension worker is loaded');
  const extension = worker.url.slice(0, worker.url.lastIndexOf('/'));
  await send('Emulation.setDeviceMetricsOverride', { width: 400, height: 850, deviceScaleFactor: 1, mobile: false });
  await send('Page.navigate', { url: `${extension}/panel.html` });
  await until('document.querySelector("#model-select")?.options.length > 0');
  const settings = {
    provider: 'openai', apiKeys: { openai: 'local-smoke-key' }, language: 'auto',
    models: { openai: 'gpt-6.1-sol', codex: 'gpt-5.6-sol', claudecode: 'sonnet' },
    endpoints: { openai: `${origin}/v1/chat/completions`, codex: `${origin}/v1/chat/completions`, claudecode: `${origin}/v1/chat/completions` },
    reasoningEfforts: { openai: 'medium', codex: 'ultra', claudecode: 'high' },
    modelCatalogCheckedAt: { codex: Date.now() }
  };
  assert.equal((await evaluate(`chrome.runtime.sendMessage({ type: 'SCHOLIA_SAVE_SETTINGS', settings: ${JSON.stringify(settings)} })`)).ok, true);
  await until('document.querySelector("#reasoning-select")?.value === "medium"');
  assert.equal(await evaluate('!!document.querySelector("#open-exam-planner, #exam-planner-settings")'), false);

  const change = async (selector, value, root = 'document') => {
    await evaluate(`{ const select = ${root}.querySelector(${JSON.stringify(selector)}); select.value = ${JSON.stringify(value)}; select.dispatchEvent(new Event('change', { bubbles: true })); }`);
    await until(`${root}.querySelector(${JSON.stringify(selector)}).value === ${JSON.stringify(value)} && !${root}.querySelector(${JSON.stringify(selector)}).disabled`);
  };
  const savedEffort = async (provider) => evaluate(`chrome.storage.local.get('scholia.settings.v1').then((data) => data['scholia.settings.v1'].reasoningEfforts[${JSON.stringify(provider)}])`);
  await change('#reasoning-select', 'high');
  assert.equal(await savedEffort('openai'), 'high');
  await send('Page.reload');
  await until('document.querySelector("#reasoning-select")?.value === "high"');

  const chatId = 'sidebar-reasoning-smoke';
  const record = {
    id: chatId, title: 'A little intuition for eigenvectors', createdAt: Date.now(), updatedAt: Date.now(),
    capture: { pageTitle: 'Understanding eigenvectors', url: 'https://example.test/linear-algebra', sourceKind: 'page',
      context: 'An eigenvector is scaled by a linear transformation.', contextEnabled: true, compactContextEnabled: true,
      contextState: 'Ready', pageLanguage: 'en' },
    messages: [{ role: 'user', content: 'Can you explain eigenvectors intuitively?' }, { role: 'assistant', content: answer }]
  };
  await evaluate(`chrome.storage.local.set({ 'scholia.chat-history.v1': [${JSON.stringify(record)}] })`);
  await until('document.querySelector(".history-open")');
  await browser.screenshot('/private/tmp/scholia-sidebar-home.png');
  await click('.history-open');
  await until('!document.querySelector("#chat-view").hidden && document.querySelector("#chat-reasoning-select").value === "high"');
  assert.equal(await evaluate('document.querySelector("#composer-form").contains(document.querySelector("#chat-reasoning-select"))'), true);
  await browser.screenshot('/private/tmp/scholia-sidebar-chat.png');

  // A send immediately after changing reasoning must await the settings write.
  await evaluate(`{ const effort = document.querySelector('#chat-reasoning-select'); effort.value = 'low'; effort.dispatchEvent(new Event('change'));
    document.querySelector('#composer').value = 'Show me a simple example'; document.querySelector('#composer-form').requestSubmit(); }`);
  await until('document.querySelectorAll("#messages .message--assistant").length === 2 && !document.querySelector(".caret")');
  assert.equal(requests.at(-1).reasoning_effort, 'low');
  assert.equal(requests.at(-1).model, 'gpt-6.1-sol');
  assert.equal(await savedEffort('openai'), 'low');
  assert.equal(await evaluate('document.querySelector("#reasoning-select").value'), 'low');

  // The picker must use capabilities of the selected model and retain each
  // provider's preference without passing another provider's effort to it.
  await change('#chat-model-select', 'codex::gpt-5.6-sol');
  await until('document.querySelector("#chat-reasoning-select").value === "ultra"');
  await change('#chat-model-select', 'codex::gpt-5.4-mini');
  assert.deepEqual(await evaluate('[...document.querySelector("#chat-reasoning-select").options].map((option) => option.value)'), ['minimal', 'low', 'medium', 'high']);
  assert.equal(await evaluate('document.querySelector("#chat-reasoning-select").value'), 'medium');
  await change('#chat-model-select', 'claudecode::sonnet');
  assert.equal(await evaluate('document.querySelector("#chat-reasoning-select").value'), 'high');
  await change('#chat-model-select', 'openai::gpt-4.1');
  assert.equal(await evaluate('document.querySelector("#chat-reasoning-select").closest("[data-reasoning-control]").hidden'), true);
  assert.equal(await evaluate('document.querySelector("#chat-reasoning-select").disabled'), true);
  await change('#chat-model-select', 'openai::gpt-6.1-sol');
  await change('#chat-reasoning-select', 'xhigh');

  await click('.composer-options > summary');
  assert.equal(await evaluate('document.querySelector("#chat-context-mode").checkVisibility()'), true);
  await click('#chat-context-none');
  await until('document.querySelector("#chat-options-summary").textContent === "No page context"');
  assert.equal(await evaluate(`(() => { const options = document.querySelector('.composer-options'); return options.scrollWidth - options.clientWidth; })()`), 0, 'Expanded chat options have no horizontal scroll');
  await browser.screenshot('/private/tmp/scholia-sidebar-options.png');
  await click('.composer-options > summary');
  await click('.chat-source > summary');
  assert.equal(await evaluate('document.querySelector("#chat-source-detail").checkVisibility()'), true);
  await click('.chat-source > summary');

  for (const width of [320, 400, 560]) {
    await send('Emulation.setDeviceMetricsOverride', { width, height: 720, deviceScaleFactor: 1, mobile: false });
    const layout = await evaluate(`(() => {
      const composer = document.querySelector('#composer-form').getBoundingClientRect();
      const reasoning = document.querySelector('#chat-reasoning-select').getBoundingClientRect();
      return { overflow: document.documentElement.scrollWidth > innerWidth, messages: document.querySelector('#messages').clientHeight,
        visible: reasoning.left >= composer.left && reasoning.right <= composer.right && composer.bottom <= innerHeight };
    })()`);
    assert.equal(layout.overflow, false, `No horizontal overflow at ${width}px`);
    assert.equal(layout.visible, true, `Composer fits at ${width}px`);
    assert.ok(layout.messages > 240, `Conversation has room at ${width}px`);
    await click('.composer-options > summary');
    const optionLayout = await evaluate(`(() => { const options = document.querySelector('.composer-options');
      return { width: options.clientWidth, scroll: options.scrollWidth, children: [...options.querySelectorAll('*')].filter((element) => element.checkVisibility()).map((element) => ({ tag: element.tagName, class: element.className, left: element.getBoundingClientRect().left, right: element.getBoundingClientRect().right, scroll: element.scrollWidth, width: element.clientWidth })) }; })()`);
    assert.ok(optionLayout.scroll <= optionLayout.width, `Expanded options fit at ${width}px: ${JSON.stringify(optionLayout)}`);
    await click('.composer-options > summary');
  }
  await send('Emulation.setDeviceMetricsOverride', { width: 400, height: 850, deviceScaleFactor: 1, mobile: false });
  await click('.chat-model-field .model-picker-button');
  await until('!document.querySelector(".chat-model-field .model-picker-popover").hidden');
  assert.equal(await evaluate(`(() => { const rect = document.querySelector('.chat-model-field .model-picker-popover').getBoundingClientRect(); return rect.top >= 0 && rect.bottom <= innerHeight; })()`), true, 'Model menu opens above the composer');
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'dark' }] });
  await browser.screenshot('/private/tmp/scholia-sidebar-dark.png');
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });

  await send('Page.navigate', { url: `${extension}/chat.html?chat=${chatId}` });
  await until('document.querySelector("#chat-reasoning-select")?.value === "xhigh" && !document.querySelector("#chat-view").hidden');
  await change('#chat-reasoning-select', 'high');
  await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 850, deviceScaleFactor: 1, mobile: false });
  await browser.screenshot('/private/tmp/scholia-sidebar-full-tab.png');
  assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'), true, 'Full-tab chat fits the desktop');
  await send('Page.reload');
  await until('document.querySelector("#chat-reasoning-select")?.value === "high"');

  await send('Emulation.setDeviceMetricsOverride', { width: 400, height: 850, deviceScaleFactor: 1, mobile: false });
  await send('Page.navigate', { url: `${extension}/popup.html` });
  await until('document.querySelector("#reasoning-select")?.value === "high"');
  await click('#quick-none');
  await evaluate(`{ const effort = document.querySelector('#reasoning-select'); effort.value = 'medium'; effort.dispatchEvent(new Event('change'));
    document.querySelector('#quick-input').value = 'Explain eigenvalues'; document.querySelector('#quick-form').requestSubmit(); }`);
  await until('document.querySelector(".quick-message.assistant")?.textContent.includes("An eigenvector") && document.querySelector("#quick-send").getAttribute("aria-label") === "Send Quick Chat message"');
  assert.equal(requests.at(-1).reasoning_effort, 'medium');

  // The PDF reader mounts the same panel in a shadow root.
  const stream = 'BT /F1 18 Tf 72 720 Td (Understanding eigenvectors) Tj ET';
  const objects = ['<< /Type /Catalog /Pages 2 0 R >>', '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>', `<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`];
  let pdf = '%PDF-1.4\n'; const offsets = [];
  for (const [i, object] of objects.entries()) { offsets.push(pdf.length); pdf += `${i + 1} 0 obj\n${object}\nendobj\n`; }
  const xref = pdf.length;
  pdf += `xref\n0 6\n0000000000 65535 f \n${offsets.map((n) => `${String(n).padStart(10, '0')} 00000 n \n`).join('')}trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  const file = join(temporary, 'eigenvectors.pdf'); await writeFile(file, pdf);
  await send('Emulation.setDeviceMetricsOverride', { width: 1400, height: 900, deviceScaleFactor: 1, mobile: false });
  await send('Page.navigate', { url: `${extension}/pdf-viewer.html` });
  await until('document.querySelector("#pdf-file") && document.readyState === "complete"');
  const { root } = await send('DOM.getDocument');
  const { nodeId } = await send('DOM.querySelector', { nodeId: root.nodeId, selector: '#pdf-file' });
  await send('DOM.setFileInputFiles', { nodeId, files: [file] });
  await until('document.querySelector("#page-total")?.textContent === "1" && !document.querySelector("#send-entire-pdf").disabled');
  await click('#send-entire-pdf');
  const panel = 'document.querySelector("#pdf-chat-content").shadowRoot';
  await until(`${panel}?.querySelector('#messages .message--assistant')?.textContent.includes('An eigenvector') && !${panel}.querySelector('.caret')`);
  assert.equal(await evaluate(`${panel}.querySelector('#chat-reasoning-select').value`), 'medium');
  await change('#chat-reasoning-select', 'max', panel);
  await evaluate(`${panel}.querySelector('#composer').value = 'Explain the key idea'; ${panel}.querySelector('#composer-form').requestSubmit()`);
  await until(`${panel}.querySelectorAll('#messages .message--assistant').length === 2 && !${panel}.querySelector('.caret')`);
  assert.equal(requests.at(-1).reasoning_effort, 'max');
  await browser.screenshot('/private/tmp/scholia-sidebar-pdf.png');
  assert.deepEqual(browser.errors, []);
  console.log('PASS: real Chromium extension; sidebar, dedicated chat, popup and PDF reasoning; persistence, model changes, immediate send, narrow layout, menus and dark mode.');
} catch (error) {
  if (browser) {
    await browser.screenshot('/private/tmp/scholia-sidebar-failure.png').catch(() => {});
    console.error(await browser.evaluate('({ url: location.href, text: document.body?.innerText.slice(-1400) })').catch(() => null), browser.errors);
  }
  throw error;
} finally {
  await browser?.close();
  await new Promise((done) => server.close(done));
  await rm(temporary, { recursive: true, force: true });
}
