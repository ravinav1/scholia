import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHostedServer } from '../apps/server/server.js';
import { chromiumSession } from './smoke/browser/lib/chromium.mjs';

const root = await mkdtemp(join(tmpdir(), 'scholia-chat-files-'));
const reserve = createServer();
await new Promise((resolve) => reserve.listen(0, '127.0.0.1', resolve));
const port = reserve.address().port;
await new Promise((resolve) => reserve.close(resolve));
const origin = `http://127.0.0.1:${port}`;
let payload, browser;
const app = createHostedServer({ root, origin, complete: async (request) => {
  payload = request;
  return { text: 'The model references Kp, but its value and the measurements are missing. Please attach the initialization script and export the measurements as CSV.' };
} });
try {
  const user = await app.store.createUser('files@example.com', 'isolated-file-test');
  const login = await app.store.login('files@example.com', 'isolated-file-test');
  const session = app.store.session(login.value);
  await app.workspaces.action(session, { action: 'create', name: 'Kybintro project', code: 'KYB' });
  const account = app.workspaces.account(user.id), course = account.library.courses[0];
  const reading = await app.workspaces.importFile(account, course, 'Compendium.txt', Buffer.from('AUTOMATIC_COMPENDIUM_CONTEXT'));
  const originalIndex = app.documents.index.bind(app.documents);
  const seedIndex = await originalIndex(user.id, reading);
  const pages = Array.from({ length: 150 }, (_, index) => ({ number: index + 1,
    text: index === 1 ? 'CURRENT_PAGE: An introduction to control systems.'
      : index === 126 ? 'DISTANT_EVIDENCE: The phase margin collapses when additional delay changes the loop phase.'
      : `AUTOMATIC_COMPENDIUM_CONTEXT. Routine material on page ${index + 1}.` }));
  reading.pageCount = pages.length;
  app.documents.index = (accountID, item) => item.id === reading.id
    ? Promise.resolve({ ...seedIndex, pages }) : originalIndex(accountID, item);
  app.store.save(account);
  await new Promise((resolve) => app.server.listen(port, '127.0.0.1', resolve));
  browser = await chromiumSession();
  const { send, evaluate, until, click } = browser;
  await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 1000, deviceScaleFactor: 1, mobile: false });
  await send('Page.navigate', { url: origin });
  await until('document.querySelector("#sign-in") && document.readyState === "complete"');
  await evaluate(`document.querySelector('[name=email]').value='files@example.com'; document.querySelector('[name=password]').value='isolated-file-test'; document.querySelector('#sign-in').requestSubmit()`);
  await until('document.querySelector("#question") && document.querySelector("[data-action=course]")');
  await click(`[data-action=course][data-id="${course.id}"]`);
  await until('document.querySelector("#ask-course-button")');
  await click('#ask-course-button');
  assert.equal(await evaluate('document.querySelector("#question-files input[type=file]").hasAttribute("accept")'), false);
  // A drop outside the composer must still attach to the visible conversation.
  await evaluate(`(() => {
    const transfer = new DataTransfer();
    transfer.items.add(new File(['Model { Name "Project" Block { BlockType Gain Gain Kp } }'], 'controller.mdl'));
    transfer.items.add(new File([new Uint8Array([0,1,2,3])], 'measurements.mat'));
    document.body.dispatchEvent(new DragEvent('drop', {bubbles:true,cancelable:true,dataTransfer:transfer}));
  })()`);
  await until('document.querySelectorAll("#question-files .scholia-file-chip").length === 2 && !document.querySelector("#question-files").textContent.includes("Reading files")');
  assert.match(await evaluate('document.querySelector("#question-files").textContent'), /controller.mdl.*Partial/s);
  assert.match(await evaluate('document.querySelector("#question-files").textContent'), /measurements.mat.*Not read/s);
  await evaluate(`(() => { const transfer=new DataTransfer(); transfer.items.add(new File(['SHOULD_BE_EXCLUDED'], 'private-notes.txt')); const input=document.querySelector('#question-files input[type=file]'); input.files=transfer.files; input.dispatchEvent(new Event('change',{bubbles:true})); })()`);
  await until('document.querySelectorAll("#question-files .scholia-file-chip").length === 3');
  await click('#question-files input[aria-label="Include private-notes.txt in context"]');
  await click('#question-files .scholia-file-preview summary');
  assert.match(await evaluate('document.querySelector("#question-files pre").textContent'), /Gain Kp/);
  await click('#automatic-context');
  await until('document.querySelector("#context-label").textContent === "Course context off"');
  await evaluate(`document.querySelector('#question').value='What is the measured overshoot and Kp?'; document.querySelector('#question').dispatchEvent(new Event('input',{bubbles:true}));`);
  await until(`document.querySelector('#draft-conflict').hidden && !document.querySelector('#send').disabled`);
  // Wait for the real persisted draft rather than assuming the debounce elapsed.
  for (let attempt = 0; attempt < 50; attempt++) {
    const draft = course.threads.find((thread) => thread.draftFiles?.length === 3);
    if (draft?.draftFiles[2].enabled === false && draft.draft.includes('overshoot')) break;
    if (attempt === 49) throw new Error('Files were not saved with the draft');
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  await writeFile('/private/tmp/scholia-chat-files.png', Buffer.from((await send('Page.captureScreenshot', { format: 'png' })).data, 'base64'));
  await click('#send');
  await until('document.querySelector(".message.assistant")?.textContent.includes("initialization script")');
  assert.equal(payload.context, '');
  assert.equal(payload.pageTitle, '');
  assert.deepEqual(payload.messages[0].files.map((file) => file.name), ['controller.mdl', 'measurements.mat']);
  assert.equal(payload.messages[0].files[1].status, 'unavailable');
  assert.doesNotMatch(JSON.stringify(payload), /SHOULD_BE_EXCLUDED|AUTOMATIC_COMPENDIUM_CONTEXT/);
  assert.match(await evaluate('document.querySelector("#messages").textContent'), /measurements.mat.*Not read/s);
  assert.equal(await evaluate('document.querySelectorAll("#question-files .scholia-file-chip").length'), 0);
  await click(`[data-action=course][data-id="${course.id}"]`);
  await until(`document.querySelector('.course-materials [data-action=document][data-id="${reading.id}"]')`);
  await click('[data-action="search"]');
  await until('document.querySelector("#workspace-search-dialog").open');
  await evaluate(`document.querySelector('#workspace-search-query').value='Compendium'; document.querySelector('#workspace-search-query').dispatchEvent(new Event('input',{bubbles:true}));`);
  await until('document.querySelectorAll(".search-result").length === 1');
  await click('.search-result');
  await until('document.querySelector("#page-input")');
  assert.equal(await evaluate('document.querySelector("#conversation-scope").textContent'), 'Reading conversation');
  await evaluate(`document.querySelector('#page-input').value='2'; document.querySelector('#page-input').dispatchEvent(new Event('change',{bubbles:true}));`);
  await until('document.querySelector("#page-input").value === "2" && document.querySelector("#automatic-context-label").textContent === "Reading context · Compendium"');
  if (!await evaluate('document.querySelector("#automatic-context").checked')) await click('#automatic-context');
  assert.equal(await evaluate('document.querySelector("#include-course").checked'), false);
  assert.equal(await evaluate('document.querySelector("#include-course-option").closest("details")'), null);
  assert.match(await evaluate('document.querySelector("#include-course-option").textContent'), /Also use other course materials/);
  await until('document.querySelector("#automatic-context-summary").textContent === "Current page + relevant pages found across the document"');
  assert.equal(await evaluate('document.querySelector("#entire-pdf-control").hidden'), false);
  const ask = async (question) => {
    const count = await evaluate('document.querySelectorAll(".message.assistant").length');
    await evaluate(`document.querySelector('#question').value=${JSON.stringify(question)}; document.querySelector('#question').dispatchEvent(new Event('input',{bubbles:true}));`);
    await click('#send');
    await until(`document.querySelectorAll('.message.assistant').length === ${count + 1} && document.querySelector('#send').getAttribute('aria-label') === 'Send question'`);
  };
  await ask('Explain this page.');
  assert.match(payload.context, /CURRENT_PAGE/);
  assert.doesNotMatch(payload.context, /DISTANT_EVIDENCE/);
  await ask('Why does the phase margin collapse?');
  assert.match(payload.context, /DISTANT_EVIDENCE/);
  assert.match(payload.context, /included excerpts from pages: 2, 127/);
  assert.match(await evaluate('document.querySelector("#context-summary").textContent'), /Compendium.*pp\. 2, 127/);
  await ask('Why?');
  assert.match(payload.context, /DISTANT_EVIDENCE/);
  await click('#entire-pdf');
  await until('document.querySelector("#automatic-context-summary").textContent === "Whole document · all indexed text"');
  await ask('Explain the whole document.');
  assert.equal(payload.entireDocument, true);
  assert.match(payload.context, /All 150 pages of extracted text/);
  assert.match(payload.context, /page 150/);
  await writeFile('/private/tmp/scholia-reading-context.png', Buffer.from((await send('Page.captureScreenshot', { format: 'png' })).data, 'base64'));
  await click('#automatic-context');
  await until('!document.querySelector("#automatic-context").checked');
  await evaluate(`(() => {
    const transfer = new DataTransfer();
    transfer.items.add(new File(['Routine source.\\n'.repeat(35000) + '\\nTAIL_PARAMETER: auroragain = 72.5;'], 'actual-model.m'));
    document.body.dispatchEvent(new DragEvent('drop', {bubbles:true,cancelable:true,dataTransfer:transfer}));
  })()`);
  await until('document.querySelector("#question-files").textContent.includes("actual-model.m") && !document.querySelector("#question-files").textContent.includes("Reading files")');
  assert.match(await evaluate('document.querySelector("#question-files").textContent'), /File · actual-model.m/);
  assert.match(await evaluate('document.querySelector("#question-files").textContent'), /560,0\d\d characters/);
  await ask('What is auroragain?');
  let evidence = payload.messages.filter((message) => message.role === 'user' && message.files?.length).at(-1).files[0];
  assert.match(evidence.text, /auroragain = 72\.5/);
  assert.match(evidence.contextCoverage, /Searched the full saved text/);
  assert.ok(evidence.text.length <= 24_000);
  await ask('Why?');
  evidence = payload.messages.filter((message) => message.role === 'user' && message.files?.length).at(-1).files[0];
  assert.match(evidence.text, /auroragain = 72\.5/);
  assert.ok(evidence.textCorpusUTF16Count > 500_000);
  assert.deepEqual(browser.errors, []);
  console.log('Chromium file and reading-context smoke passed: file drop/picker/status/toggles, compact current page, distant page retrieval, vague follow-up evidence, actual source ranges, whole-document text transport, and full retained 560k-character attachment with late-parameter retrieval.');
} catch (error) {
  if (browser) console.error(JSON.stringify({ browserErrors: browser.errors, page: await browser.evaluate('document.body.innerText.slice(0, 2000)').catch(() => '') }, null, 2));
  throw error;
} finally {
  await browser?.close();
  await app.close();
  await rm(root, { recursive: true, force: true });
}
