import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createHostedServer } from '../apps/server/server.js';
import { chromiumSession } from './smoke/browser/lib/chromium.mjs';

const root = await mkdtemp(join(tmpdir(), 'scholia-course-chat-'));
const reserve = createServer();
await new Promise((resolve) => reserve.listen(0, '127.0.0.1', resolve));
const port = reserve.address().port;
await new Promise((resolve) => reserve.close(resolve));
const origin = `http://127.0.0.1:${port}`;
const paperLinks = [
  ['Before and beyond trust: reliance in medical AI', 'https://doi.org/10.1136/medethics-2020-107095'],
  ['Saving or Creating: Which Are We Doing When We Resuscitate Extremely Preterm Infants?', 'https://doi.org/10.1080/15265161.2017.1340988'],
];
const answer = paperLinks.map(([title, url]) => `[${title}](${url})`).join('\n\n') + '\n\n' + Array.from({ length: 18 }, (_, i) =>
  `Topic ${i + 1}: A vector has magnitude and direction. Start with a geometric example, then connect the picture to its components.`
).join('\n\n');
let lastPayload;
const app = createHostedServer({
  root, origin,
  complete: async (_payload, _settings, onToken) => {
    lastPayload = _payload;
    onToken(answer);
    return { text: answer };
  },
});
let browser;
try {
  const user = await app.store.createUser('study@example.com', 'correct horse battery staple');
  const account = app.workspaces.account(user.id);
  const course = {
    id: randomUUID(), name: 'Linear algebra', code: 'MA1202',
    documents: [], threads: [], canvasMaterials: [],
  };
  account.library.courses.push(course);
  const reading = await app.workspaces.importFile(account, course, 'Vectors.txt',
    Buffer.from('Vectors have magnitude and direction. Vector spaces have a basis.'));
  await app.workspaces.importFile(account, course, 'Reading list.html', Buffer.from(
    `<!doctype html><html><body><h1>Reading list</h1>${paperLinks.map(([title, url]) => `<p><a href="${url}">${title}</a></p>`).join('')}</body></html>`));
  app.store.save(account);
  await new Promise((resolve) => app.server.listen(port, '127.0.0.1', resolve));
  browser = await chromiumSession();
  const { send, evaluate, until, click } = browser;
  await send('Emulation.setDeviceMetricsOverride', {
    width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false,
  });
  await send('Page.navigate', { url: origin });
  await until('document.querySelector("#sign-in") && document.readyState === "complete"');
  await evaluate(`document.querySelector('[name=email]').value='study@example.com';
    document.querySelector('[name=password]').value='correct horse battery staple';
    document.querySelector('#sign-in').requestSubmit()`);
  await until('document.querySelector(".study-dashboard")');
  await evaluate(`document.querySelector('[data-action=keyboardShortcuts]').focus()`);
  await click('[data-action=keyboardShortcuts]');
  await until('document.querySelector("#keyboard-shortcuts-dialog").open');
  assert.match(await evaluate('document.querySelector("#keyboard-shortcuts-dialog").textContent'), /Search files and contents/);
  assert.match(await evaluate('document.querySelector("#keyboard-shortcuts-dialog").textContent'), /Send message/);
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
  await until('!document.querySelector("#keyboard-shortcuts-dialog").open');
  assert.equal(await evaluate('document.activeElement.dataset.action'), 'keyboardShortcuts');
  await click(`[data-action=course][data-id="${course.id}"]`);
  await until('document.querySelector("#course-chat-slot")');
  assert.equal(await evaluate('document.querySelector("#course-chat-slot").hidden'), true);
  assert.equal(await evaluate('document.querySelector("#workspace > .tutor") === null'), true);
  assert.equal(await evaluate('getComputedStyle(document.querySelector("#tutor-divider")).display'), 'none');
  await click('#ask-course-button');
  assert.equal(await evaluate('document.querySelector("#course-chat-slot").hidden'), false);
  assert.equal(await evaluate('document.querySelector("#course-chat-slot").previousElementSibling.className'), 'course-tools');
  assert.equal(await evaluate('document.activeElement.id'), 'question');
  assert.deepEqual(await evaluate('[...document.querySelectorAll("[data-mode]")].map(el => el.dataset.mode)'), ['Explain', 'Practice', 'General']);
  await click('#workspace-memory');
  await until('document.querySelector("#workspace-memory-dialog").open');
  await evaluate(`document.querySelector('#memory-notes').value='Remember: prefer geometric examples.'`);
  await click(`#memory-files input[value="${reading.id}"]`);
  await click('#memory-save');
  await until('!document.querySelector("#workspace-memory-dialog").open');
  await click('#workspace-memory');
  assert.equal(await evaluate('document.querySelector("#memory-notes").value'), 'Remember: prefer geometric examples.');
  assert.equal(await evaluate(`document.querySelector('#memory-files input[value="${reading.id}"]').checked`), true);
  await click('#memory-cancel');
  await click('[data-mode="General"]');
  await until('document.querySelector("[data-mode=General]").getAttribute("aria-pressed") === "true"');
  assert.match(await evaluate('document.querySelector("#messages").textContent'), /What[’']s on your mind/);
  await evaluate(`window.originalComposer = document.querySelector('#composer');
    document.querySelector('#question').value='Explain vector spaces';
    document.querySelector('#question').dispatchEvent(new Event('input',{bubbles:true}));
    const search=document.querySelector('#material-search'); search.value='vectors';
    search.dispatchEvent(new Event('input',{bubbles:true}));`);
  assert.equal(await evaluate('window.originalComposer === document.querySelector("#composer")'), true);
  assert.equal(await evaluate('document.querySelector("#question").value'), 'Explain vector spaces');
  await click('#course-chat-toggle');
  assert.equal(await evaluate('document.querySelector("#course-chat-toggle").getAttribute("aria-expanded")'), 'false');
  assert.ok(await evaluate('document.querySelector(".tutor").getBoundingClientRect().height < 70'));
  await click('#ask-course-button');
  assert.equal(await evaluate('document.querySelector("#question").value'), 'Explain vector spaces');
  await evaluate(`document.querySelector('#study-model-mode').value='auto';
    document.querySelector('#study-model-mode').dispatchEvent(new Event('change',{bubbles:true}));`);
  await until('document.querySelector("#reasoning-picker").disabled');
  assert.match(await evaluate('document.querySelector("#model-picker").selectedOptions[0].textContent'), / · Auto study$/);
  assert.equal(await evaluate('document.querySelector("#model-picker").getAttribute("aria-label")'), 'Provider and fallback model');
  await evaluate(`const picker = document.querySelector('#model-picker');
    const option = [...picker.options].find(option => !option.disabled && JSON.parse(option.value)[0] === 'openai');
    window.fallbackModel = option.value;
    picker.value = option.value;
    picker.dispatchEvent(new Event('change',{bubbles:true}));`);
  await until('document.querySelector("#model-picker").selectedOptions[0].textContent === "OpenAI · Auto study"');
  assert.equal(await evaluate('document.querySelector("#study-model-mode").value'), 'auto');
  await click('#send');
  await until('document.querySelector(".message.assistant")?.textContent.includes("Topic 18")');
  await until('document.querySelector("#send").getAttribute("aria-label") === "Send question"');
  assert.match(JSON.stringify(lastPayload), /Remember: prefer geometric examples/);
  assert.match(JSON.stringify(lastPayload), /Vectors have magnitude and direction/);
  for (const [title, url] of paperLinks) {
    assert.ok(lastPayload.context.includes(`[${title}](${url})`));
    const link = await evaluate(`(() => { const a = document.querySelector('.message.assistant a[href="${url}"]');
      return a && { text: a.textContent, target: a.target, rel: a.rel }; })()`);
    assert.equal(link.text, title);
    assert.equal(link.target, '_blank');
    assert.match(link.rel, /noopener/);
  }
  assert.ok(await evaluate('document.querySelector(".study-model-route")?.textContent.includes("Auto study")'));
  assert.ok(await evaluate('document.querySelector(".tutor").getBoundingClientRect().height >= 600 && document.querySelector(".tutor").getBoundingClientRect().height <= 780'));
  assert.ok(await evaluate('document.querySelector("#messages").scrollHeight > document.querySelector("#messages").clientHeight'));
  await evaluate(`const messages=document.querySelector('#messages'); messages.scrollTop=30;
    window.scrollBefore=messages.scrollTop;
    document.querySelector('#material-search').value='';
    document.querySelector('#material-search').dispatchEvent(new Event('input',{bubbles:true}));`);
  assert.equal(await evaluate('document.querySelector("#messages").scrollTop'), await evaluate('window.scrollBefore'));
  await evaluate(`const text=document.querySelector('.message.assistant p').firstChild;
    const range=document.createRange(); range.selectNodeContents(text);
    window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
    document.querySelector('#messages').dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));`);
  assert.equal(await evaluate('document.querySelector("#selection-note").hidden'), true);
  await evaluate('window.getSelection().removeAllRanges()');
  await mkdir('dist/verification/course-chat', { recursive: true });
  await evaluate(`document.querySelector('#course-chat-slot').scrollIntoView({block:'center'});`);
  await browser.screenshot('dist/verification/course-chat/desktop.png');
  await send('Emulation.setDeviceMetricsOverride', {
    width: 390, height: 844, deviceScaleFactor: 1, mobile: true,
  });
  assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth + 1'), true);
  assert.ok(await evaluate('document.querySelector(".tutor").getBoundingClientRect().height >= 480 && document.querySelector(".tutor").getBoundingClientRect().height <= 780'));
  await evaluate(`document.querySelector('#course-chat-slot').scrollIntoView({block:'center'});`);
  assert.ok(await evaluate(`[...document.querySelectorAll('.composer-controls > *')].every(control =>
    control.hidden || control.getBoundingClientRect().right <= document.querySelector('#composer').getBoundingClientRect().right)`));
  await browser.screenshot('dist/verification/course-chat/mobile.png');
  await click('.mobile-menu');
  await click('[data-action=keyboardShortcuts]');
  await until('document.querySelector("#keyboard-shortcuts-dialog").open');
  assert.ok(await evaluate('document.querySelector("#keyboard-shortcuts-dialog").getBoundingClientRect().right <= innerWidth'));
  assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth + 1'), true);
  await browser.screenshot('dist/verification/course-chat/shortcuts-mobile.png');
  await click('#keyboard-shortcuts-dialog .quick-close');
  await send('Emulation.setDeviceMetricsOverride', {
    width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false,
  });
  await click(`.course-materials [data-action=document][data-id="${reading.id}"]`);
  await until('document.querySelector(".paper")');
  assert.equal(await evaluate('document.querySelector("#workspace > .tutor") !== null'), true);
  assert.equal(await evaluate('document.querySelector("#course-chat-toggle").hidden'), true);
  assert.equal(await evaluate('getComputedStyle(document.querySelector("#tutor-divider")).display'), 'block');
  await evaluate(`document.querySelector('#question').value='Reading draft';
    document.querySelector('#question').dispatchEvent(new Event('input',{bubbles:true}));`);
  await click('#change-scope');
  await until('document.querySelector("#course-chat-slot .message.assistant")');
  assert.equal(await evaluate('document.querySelector("[data-mode=General]").getAttribute("aria-pressed")'), 'true');
  assert.equal(await evaluate('document.querySelector("#question").value'), '');
  assert.equal(await evaluate('document.querySelector("#study-model-mode").value'), 'auto');
  await click(`.course-materials [data-action=document][data-id="${reading.id}"]`);
  await until('document.querySelector(".paper")');
  assert.equal(await evaluate('document.querySelector("#question").value'), 'Reading draft');
  await evaluate(`document.querySelector('#study-model-mode').value='manual';
    document.querySelector('#study-model-mode').dispatchEvent(new Event('change',{bubbles:true}));`);
  await until('!document.querySelector("#reasoning-picker").disabled');
  assert.doesNotMatch(await evaluate('document.querySelector("#model-picker").selectedOptions[0].textContent'), / · Auto study$/);
  assert.equal(await evaluate('document.querySelector("#model-picker").value'), await evaluate('window.fallbackModel'));
  assert.deepEqual(browser.errors, []);
  console.log('PASS: Chromium course chat, direct paper links, subtle shortcut help, focus restoration, mobile layout, drafts and study model controls.');
} catch (error) {
  console.error(await browser?.evaluate('({text:document.body.innerText.slice(-2200), html:document.querySelector(".tutor")?.outerHTML.slice(0,500)})'));
  console.error(browser?.errors);
  throw error;
} finally {
  await browser?.close();
  await app.close();
  await rm(root, { recursive: true, force: true });
}
