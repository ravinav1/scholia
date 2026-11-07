import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { mkdtemp, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createHostedServer } from '../../../apps/server/server.js';
import { chromiumSession } from './lib/chromium.mjs';
const root = await mkdtemp(join(tmpdir(), 'scholia-hosted-smoke-'));
const reserve = createServer();
await new Promise((resolve) => reserve.listen(0, '127.0.0.1', resolve));
const port = reserve.address().port;
await new Promise((resolve) => reserve.close(resolve));
const origin = `http://127.0.0.1:${port}`,
  output = resolve('dist/verification');
await mkdir(output, { recursive: true });
const app = createHostedServer({
  root,
  origin,
  complete: async (_payload, _settings, onToken) => {
    onToken('A vector has a magnitude and direction.');
    return { text: 'A vector has a magnitude and direction.' };
  },
});
let browser;
try {
  await app.store.createUser('alice@example.com', 'correct horse battery staple');
  await app.store.createUser('bob@example.com', 'correct horse battery staple');
  await new Promise((resolve) => app.server.listen(port, '127.0.0.1', resolve));
  browser = await chromiumSession();
  const { send, evaluate, until, click } = browser;
  await send('Emulation.setDeviceMetricsOverride', {
    width: 1460,
    height: 960,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await send('Page.navigate', { url: origin });
  await until('document.querySelector("#sign-in") && document.readyState === "complete"');
  await browser.screenshot(join(output, 'hosted-sign-in.png'));
  const login = async (email) => {
    await evaluate(
      `document.querySelector('[name=email]').value=${JSON.stringify(email)}; document.querySelector('[name=password]').value='correct horse battery staple'; document.querySelector('#sign-in').requestSubmit()`
    );
    await until('document.querySelector(".study-dashboard")');
  };
  await login('alice@example.com');
  await evaluate(`window.preservedAgenda = document.querySelector('.assignment-agenda');
    document.querySelector('#course-search').value = 'test';
    document.querySelector('#course-search').dispatchEvent(new Event('input', { bubbles: true }));`);
  assert.equal(await evaluate("window.preservedAgenda === document.querySelector('.assignment-agenda')"), true,
    'Workspace search preserves the assignment panel');
  await evaluate(`window.preservedWorkspaces = document.querySelector('.workspace-panel');
    document.querySelector('#assignment-search').value = 'test';
    document.querySelector('#assignment-search').dispatchEvent(new Event('input', { bubbles: true }));`);
  assert.equal(await evaluate("window.preservedWorkspaces === document.querySelector('.workspace-panel')"), true,
    'Assignment search preserves the workspace panel');
  await evaluate(`for (const id of ['course-search', 'assignment-search']) {
    const input = document.getElementById(id); input.value = '';
    input.dispatchEvent(new Event('input', { bubbles: true })); }`);
  assert.equal(await evaluate('document.querySelector("#review-due").hidden'), false,
    'Hosted practice is available');
  await click('#review-due');
  await until('document.querySelector("#practice-dialog").open && document.querySelector("[data-practice=close]")');
  await click('[data-practice="close"]');
  await click('[data-action="create"]');
  await evaluate(
    'document.querySelector("#create-form [name=name]").value="Alice private workspace"; document.querySelector("#create-form").requestSubmit()'
  );
  await until(
    'document.querySelector(".course-materials h2")?.textContent === "Alice private workspace"'
  );
  await evaluate(
    `fetch('/api/action',{ method:'POST',headers:{'Content-Type':'application/json','X-Scholia-Token':document.querySelector('meta[name=scholia-token]').content},body:JSON.stringify({action:'import',name:'vectors.txt',data:btoa('Vectors have magnitude and direction. Add vectors component by component.')}) })`
  );
  await until('document.querySelector("#material-nav [data-action=document]")');
  await click('#material-nav [data-action="document"]');
  await until('document.querySelector(".paper")?.textContent.includes("Vectors have magnitude")');
  await evaluate(
    'document.querySelector("#question").value="What is a vector?"; document.querySelector("#question").dispatchEvent(new Event("input",{bubbles:true}))'
  );
  await until('!document.querySelector("#send").disabled');
  await click('#send');
  await until(
    'document.querySelector(".message.assistant")?.textContent.includes("magnitude and direction")'
  );
  await browser.screenshot(join(output, 'hosted-workspace.png'));
  await until('document.querySelector("#send").getAttribute("aria-label") !== "Stop answer"');
  await evaluate(
    `fetch('/api/action',{method:'POST',headers:{'Content-Type':'application/json','X-Scholia-Token':document.querySelector('meta[name=scholia-token]').content},body:JSON.stringify({action:'import',name:'scan-014.txt',data:btoa('# Study notes\\n## Eigenvectors and bases\\nKey ideas: diagonalization preserves eigenvector directions. Remember how basis changes work.')})})`
  );
  await until('document.querySelector("#material-nav").textContent.includes("scan-014")');
  await click('[data-action="materials"]');
  await until('document.querySelector(".course-materials")');
  assert.ok(await evaluate('[...document.querySelectorAll(".material-subheader")].some(e => e.textContent === "Eigenvectors and bases")'),
    'A generic filename receives a topic subheader from its content');
  await evaluate(`const input = document.querySelector('#material-search'); input.value = 'eigenvectors';
    input.dispatchEvent(new Event('input', { bubbles: true }));`);
  assert.equal(await evaluate('document.querySelectorAll(".course-materials .material-row").length'), 1);
  assert.match(await evaluate('document.querySelector(".course-materials .material-row strong").textContent'), /scan-014/);
  await browser.screenshot(join(output, 'hosted-content-classification.png'));
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth + 1'), true,
    'Content subheaders fit a mobile workspace');
  await send('Emulation.setDeviceMetricsOverride', { width: 1460, height: 960, deviceScaleFactor: 1, mobile: false });
  await click('#account-settings');
  await until('document.querySelector("#provider-settings")?.closest("dialog").open');
  assert.equal(
    await evaluate('document.querySelector(".account-email").textContent'),
    'alice@example.com'
  );
  await evaluate('document.querySelector("#provider-settings").closest("dialog").close()');
  await click('#sign-out');
  await until('document.querySelector("#sign-in")');
  await login('bob@example.com');
  assert.doesNotMatch(
    await evaluate('document.body.textContent'),
    /Alice private workspace|What is a vector|vectors.txt/
  );
  await send('Emulation.setDeviceMetricsOverride', {
    width: 390,
    height: 844,
    deviceScaleFactor: 1,
    mobile: true,
  });
  assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth+1'), true);
  assert.deepEqual(browser.errors, []);
  console.log(
    'PASS: Chromium hosted sign-in, isolated dashboard updates, content classification/search, private workspace, import, document reading, tutor conversation, account settings, sign-out, second-user isolation and mobile layout'
  );
} finally {
  await browser?.close();
  await app.close();
  await rm(root, { recursive: true, force: true });
}
