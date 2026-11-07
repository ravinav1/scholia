import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { build } from 'esbuild';
import { chromiumSession } from './lib/chromium.mjs';

const bundle = await build({ stdin: { resolveDir: process.cwd(), contents: `
import { populateModelSelect } from './apps/chrome/src/model-select.js';
import { recordRecentModel } from './packages/core/src/recent-models.js';
import { studyModelPickerMarkup } from './apps/web/chat/model-picker.js';
import { practiceQuestionMarkup, practiceRecapMarkup } from './apps/web/practice/practice-view.js';
const old = 1000;
const initial = recordRecentModel(recordRecentModel([], 'openai', 'gpt-6-sol', old), 'codex', 'gpt-6.1-sol', old + 1);
const settings = { provider: 'codex', models: { codex: 'gpt-6.1-sol' }, configuredProviders: ['codex', 'openai'], recentModels: JSON.parse(localStorage.getItem('recents') || 'null') || initial };
const select = document.querySelector('#extension-picker');
populateModelSelect(select, settings);
select.addEventListener('change', () => { document.querySelector('#chosen').textContent = select.value; });
const models = [{ id: 'gpt-6-sol', label: 'GPT-6 Sol', providerID: 'openai', provider: 'OpenAI', lastUsedAt: old }, { id: 'gpt-6.1-sol', label: 'GPT-6.1 Sol', providerID: 'codex', provider: 'Codex', lastUsedAt: old + 1 }];
document.querySelector('#study-picker').innerHTML = studyModelPickerMarkup(models, 'codex', 'gpt-6.1-sol');
const question = { id: 'q', concept: 'Algebra', prompt: 'Explain why adding the same quantity preserves an equality.', hints: [], hintCount: 3, validation: 'Generated practice', source: { title: 'Algebra', page: 1 } };
const view = { question, attempts: [], session: { stage: 'question', position: 0, questionIDs: ['q'], hintCount: 0, revealed: false }, recap: [question] };
window.fixture = { useModel(providerID, modelID) { settings.recentModels = recordRecentModel(settings.recentModels, providerID, modelID); localStorage.setItem('recents', JSON.stringify(settings.recentModels)); populateModelSelect(select, settings); }, attempt() { view.attempts.push({ id: 'a', questionID: 'q', answer: 'Both sides change equally', createdAt: old }); document.querySelector('#practice').innerHTML = practiceQuestionMarkup(view); } };
document.querySelector('#practice').innerHTML = practiceQuestionMarkup(view);
document.querySelector('#recap').innerHTML = practiceRecapMarkup(view);
window.ready = true;
` }, bundle: true, write: false, format: 'iife', platform: 'browser' });
const css = await readFile('apps/chrome/panel.css', 'utf8');
const server = createServer((_req, res) => {
  res.setHeader('content-type', 'text/html');
  res.end(`<!doctype html><html><head><style>${css}\nbody{display:block;padding:24px;min-width:0}main{max-width:560px}#practice,#recap{margin-top:24px}#recap{display:none}</style></head><body><main><h2>Chat models</h2><select id="extension-picker" aria-label="Chat model"></select><p id="chosen"></p><h2>Study chat</h2><select id="study-picker"></select><div id="practice"></div><div id="recap"></div></main><script>${bundle.outputFiles[0].text.replace(/<\/script/gi, '<\\/script')}</script></body></html>`);
});
let browser;
try {
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  browser = await chromiumSession();
  const url = `http://127.0.0.1:${server.address().port}`;
  await browser.send('Page.navigate', { url });
  await browser.until('window.ready');
  assert.equal(await browser.evaluate('document.querySelector("#practice [data-practice=reveal]").disabled'), true);
  assert.equal(await browser.evaluate('document.querySelector("#recap [data-practice=revealSaved]") === null'), true);
  assert.equal(await browser.evaluate('document.querySelector("#study-picker optgroup").label'), 'Recently used');
  await browser.click('.model-picker-button');
  assert.equal(await browser.evaluate('document.querySelector(".model-picker-group-label span").textContent'), 'Recently used');
  assert.match(await browser.evaluate('document.querySelector(".model-picker-option-detail").textContent'), /gpt-6.1-sol/);
  await browser.evaluate(`{ const search = document.querySelector('.model-picker-search input'); search.value = 'OpenAI gpt-6-sol'; search.dispatchEvent(new Event('input')); }`);
  await browser.evaluate(`document.querySelector('.model-picker-option').click()`);
  assert.equal(await browser.evaluate('document.querySelector("#chosen").textContent'), 'openai::gpt-6-sol');
  await browser.evaluate(`fixture.useModel('openai','gpt-6-sol')`);
  await browser.send('Page.reload');
  await browser.until('window.ready');
  await browser.click('.model-picker-button');
  assert.match(await browser.evaluate('document.querySelector(".model-picker-option-detail").textContent'), /OpenAI.*gpt-6-sol/);
  await browser.send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
  assert.equal(await browser.evaluate('document.querySelector(".model-picker-button").getAttribute("aria-expanded")'), 'false');
  await browser.evaluate('fixture.attempt()');
  assert.equal(await browser.evaluate('document.querySelector("#practice [data-practice=reveal]").disabled'), false);
  await browser.click('.model-picker-button');
  await browser.screenshot('/private/tmp/scholia-recent-models.png');
  assert.deepEqual(browser.errors, []);
  console.log('PASS: Chromium recent ordering, search, selection, reload persistence, keyboard dismissal and practice reveal/recap gates');
} finally {
  await browser?.close();
  await new Promise((resolve) => server.close(resolve));
}
