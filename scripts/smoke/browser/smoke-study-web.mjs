import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer, request as httpRequest } from 'node:http';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const address = process.argv[2], output = process.argv[3];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
class DevToolsClient {
  constructor(url) {
    this.nextID = 1;
    this.pending = new Map();
    this.events = [];
    this.socket = new WebSocket(url);
  }

  async open() {
    if (this.socket.readyState === WebSocket.OPEN) return;
    await new Promise((resolvePromise, reject) => {
      this.socket.addEventListener('open', resolvePromise, { once: true });
      this.socket.addEventListener('error', reject, { once: true });
    });
    this.socket.addEventListener('message', (event) => {
      const payload = JSON.parse(event.data);
      if (!payload.id) { this.events.push(payload); return; }
      const pending = this.pending.get(payload.id);
      if (!pending) return;
      this.pending.delete(payload.id);
      if (payload.error) pending.reject(new Error(payload.error.message));
      else pending.resolve(payload.result);
    });
  }

  send(method, params = {}) {
    const id = this.nextID++;
    return new Promise((resolvePromise, reject) => {
      this.pending.set(id, { resolve: resolvePromise, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  close() { this.socket.close(); }
}

async function evaluate(expression) {
  const result = await client.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
  if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
async function waitFor(expression, label) {
  for (let i = 0; i < 150; i++) { if (await evaluate(expression)) return; await sleep(100); }
  console.error('Browser state:', await evaluate(`({toast:document.querySelector('#toast')?.textContent, conflict:document.querySelector('#draft-conflict')?.textContent, visibleConflict:!document.querySelector('#draft-conflict')?.hidden, practice:document.querySelector('#practice-dialog')?.textContent?.slice(0,1800)})`));
  try {
    const native = await (await fetch(address + '/api/state', { headers: { 'X-Scholia-Token': token }, signal: AbortSignal.timeout(2000) })).json();
    const selectedCourse = native.library?.courses.find((course) => course.id === native.library.selectedCourseID);
    const selectedDocument = selectedCourse?.documents.find((document) => document.id === native.library.selectedDocumentID);
    console.error('Native reading state:', { loadingDocument: native.loadingDocument, canSend: native.canSend, busy: native.busy, streaming: native.streaming, status: native.status, error: native.error, page: native.page, pageTextLength: native.pageText?.length, documentID: selectedDocument?.id, documentKind: selectedDocument?.kind });
  } catch (error) { console.error('Native state unavailable:', error.message); }
  throw new Error(`Timed out: ${label}`);
}
async function click(selector) { await evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`); }
async function reloadPage() {
  const firstEvent = client.events.length;
  await client.send('Page.reload');
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    const events = client.events.slice(firstEvent);
    const navigation = events.findIndex((event) => event.method === 'Page.frameNavigated' && !event.params.frame.parentId);
    if (navigation >= 0 && events.slice(navigation + 1).some((event) => event.method === 'Page.loadEventFired')) return;
    await sleep(50);
  }
  throw new Error('Timed out: fresh document after reload');
}
async function shot(name) {
  const result = await client.send('Page.captureScreenshot', { format: 'png' });
  await writeFile(join(output, name), Buffer.from(result.data, 'base64'));
  console.log(`Screenshot: ${name}`);
}
const html = await (await fetch(address)).text();
const token = /name="scholia-token" content="([^"]+)"/.exec(html)?.[1];
assert.ok(token && token !== '__SCHOLIA_TOKEN__');
assert.equal((await fetch(address + '/api/state')).status, 403);
assert.equal((await fetch(address + '/api/state', { headers: { 'X-Scholia-Token': token, Origin: 'https://unrelated.example' } })).status, 403);
assert.equal(await new Promise((resolve, reject) => { const req = httpRequest(address + '/api/state', { headers: { 'X-Scholia-Token': token, Host: 'evil.example' } }, (res) => { res.resume(); resolve(res.statusCode); }); req.on('error', reject); req.end(); }), 403);
const apiState = await (await fetch(address + '/api/state', { headers: { 'X-Scholia-Token': token } })).json();
assert.equal(apiState.library.courses.length, 6);
assert.ok(!JSON.stringify(apiState).includes('fixture-token'));
const algebra = apiState.library.courses.find((c) => c.name.startsWith('Linear algebra &'));
const pdf = algebra.documents.find((d) => d.kind === 'pdf');
const profile = await mkdtemp(join(tmpdir(), 'scholia-web-chromium-'));
const probe = createServer(); await new Promise((resolve) => probe.listen(0, '127.0.0.1', resolve));
const port = probe.address().port; await new Promise((resolve) => probe.close(resolve));
const chromium = spawn(process.env.CHROMIUM_BIN || '/Applications/Chromium.app/Contents/MacOS/Chromium', ['--headless=new','--no-first-run','--disable-default-apps','--disable-gpu',`--remote-debugging-port=${port}`,`--user-data-dir=${profile}`,'--window-size=1460,960','about:blank'], { stdio:'ignore' });
let client;
try {
  for (let i = 0; i < 100; i++) { try { if ((await fetch(`http://127.0.0.1:${port}/json/version`)).ok) break; } catch {} await sleep(100); }
  const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method:'PUT' })).json();
  client = new DevToolsClient(target.webSocketDebuggerUrl); await client.open();
  await client.send('Page.enable'); await client.send('Runtime.enable'); await client.send('Log.enable');
  await client.send('Emulation.setDeviceMetricsOverride', { width:1460,height:960,deviceScaleFactor:1,mobile:false });
  await client.send('Emulation.setEmulatedMedia', { features:[{name:'prefers-color-scheme',value:'light'}] });
  await client.send('Page.navigate', { url:address });
  await waitFor('document.querySelectorAll(".course-card").length === 6', 'course cards');
  await shot('web-courses.png');
  await click(`[data-action="favorite"][data-id="${algebra.id}"]`);
  await waitFor(`document.querySelector('[data-action="favorite"][data-id="${algebra.id}"]').getAttribute('aria-pressed') === 'true'`, 'favorite saved');
  await evaluate('document.querySelector("#workspace-filter").value = "favorites"; document.querySelector("#workspace-filter").dispatchEvent(new Event("change", { bubbles: true }))');
  await waitFor('document.querySelectorAll(".course-card").length === 3', 'favorites filter');
  await reloadPage();
  await waitFor(`document.querySelector('[data-action="favorite"][data-id="${algebra.id}"]')?.getAttribute('aria-pressed') === 'true'`, 'favorite survives reload');
  await click(`.card-open[data-id="${algebra.id}"]`);
  await waitFor('document.querySelector(".course-materials")', 'course workspace');
  await click(`#reader-content [data-action="document"][data-id="${pdf.id}"]`);
  await waitFor('document.querySelector(".pdfViewer .page canvas") && document.querySelectorAll(".textLayer span").length > 0', 'PDF visual and selectable text');
  await evaluate('document.querySelector("#page-input").value = 2; document.querySelector("#page-input").dispatchEvent(new Event("change", { bubbles:true }))');
  await waitFor('document.querySelector("#page-input").value === "2" && document.querySelector(\'.page[data-page-number="2"] .textLayer\')?.textContent.toLowerCase().includes("eigenvectors")', 'page context');
  await evaluate(`window.studyPDFNode = document.querySelector('.study-pdf-viewport'); window.studyEarlierAnswer = document.querySelector('.message.assistant'); window.studyEarlierParagraph = window.studyEarlierAnswer?.querySelector('p'); if (window.studyEarlierAnswer) { const details = window.studyEarlierAnswer.querySelector('details'); if (details) details.open = true; }`);
  await click('[data-pdf="crop"]');
  await waitFor('document.querySelector(".crop-overlay")', 'figure tool');
  const rect = await evaluate('(()=>{const b=document.querySelector(".crop-overlay").getBoundingClientRect();return {x:b.x+50,y:b.y+100};})()');
  await client.send('Input.dispatchMouseEvent', {type:'mousePressed',x:rect.x,y:rect.y,button:'left',clickCount:1});
  await client.send('Input.dispatchMouseEvent', {type:'mouseMoved',x:rect.x+140,y:rect.y+90,button:'left'});
  await client.send('Input.dispatchMouseEvent', {type:'mouseReleased',x:rect.x+140,y:rect.y+90,button:'left',clickCount:1});
  await waitFor('!document.querySelector("#question-image").hidden', 'image attached');
  await evaluate('document.querySelector("#question").value = "Explain this diagram"; document.querySelector("#question").dispatchEvent(new Event("input", {bubbles:true}))');
  // PDF.js can render the PDF before the native text index is ready. A user
  // cannot send yet; wait for the real composer gate before forcing submits.
  await waitFor('!document.querySelector("#send").disabled', 'native reading context ready to send');
  // Hold the send response briefly so new typing exercises the pending-request race.
  await evaluate(`window.studyFetch = window.fetch; window.studySendCount = 0; window.fetch = async (...args) => {
    const sending = args[0] === '/api/action' && args[1]?.body && JSON.parse(args[1].body).action === 'send';
    if (sending) window.studySendCount++;
    const response = await window.studyFetch(...args);
    if (sending) await new Promise(resolve => setTimeout(resolve, 400));
    return response;
  };
  document.querySelector('#composer').dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  document.querySelector('#composer').dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }));
  document.querySelector('#question').value = 'My next question, typed while sending.';
  document.querySelector('#question').dispatchEvent(new Event('input', { bubbles: true }));`);
  await waitFor('document.querySelector("#messages").textContent.includes("The diagram shows a preserved direction")', 'answer through native tutor');
  assert.equal(await evaluate('window.studySendCount'), 1, 'rapid repeated submit sends once');
  assert.equal(await evaluate('document.querySelector("#question").value'), 'My next question, typed while sending.', 'new typing survives the previous send');
  assert.ok(await evaluate('document.querySelector("#question-image").hidden'), 'the sent image is cleared independently of newer draft text');
  assert.ok(await evaluate('window.studyPDFNode === document.querySelector(".study-pdf-viewport")'), 'chat updates retain the PDF viewer');
  assert.ok(await evaluate('!window.studyEarlierAnswer || window.studyEarlierAnswer.isConnected'), 'completed answers retain their DOM during streaming');
  assert.ok(await evaluate('!window.studyEarlierParagraph || window.studyEarlierParagraph.isConnected'), 'completed answer content is not regenerated during streaming');
  assert.ok(await evaluate('!window.studyEarlierAnswer?.querySelector("details") || window.studyEarlierAnswer.querySelector("details").open'), 'expanded source details stay open');
  await evaluate('window.fetch = window.studyFetch; document.querySelector("#question").value = ""; document.querySelector("#question").dispatchEvent(new Event("input", { bubbles:true }))');
  assert.ok(await evaluate('document.querySelector("#model-picker").options.length > 0'));
  await evaluate('document.querySelector("#toast").hidden = true');
  await shot('web-reader.png');
  await client.send('Emulation.setEmulatedMedia', { features:[{name:'prefers-color-scheme',value:'dark'}] });
  await sleep(250); await shot('web-reader-dark.png');
  await client.send('Emulation.setEmulatedMedia', { features:[{name:'prefers-color-scheme',value:'light'}] });
  await client.send('Emulation.setDeviceMetricsOverride', {width:1050,height:800,deviceScaleFactor:1,mobile:false});
  await sleep(400); await shot('web-reader-compact.png');
  await client.send('Emulation.setDeviceMetricsOverride', {width:390,height:844,deviceScaleFactor:1,mobile:true});
  await sleep(400); await shot('web-reader-mobile.png');
  assert.ok(await evaluate('document.documentElement.scrollWidth <= innerWidth + 1'), 'mobile should not overflow horizontally');
  await client.send('Emulation.setDeviceMetricsOverride', {width:1460,height:960,deviceScaleFactor:1,mobile:false});
  await click('[data-action="library"]');
  await waitFor('!document.querySelector("#library").hidden', 'back to library');
  await evaluate('document.querySelector("#workspace-filter").value = "all"; document.querySelector("#workspace-filter").dispatchEvent(new Event("change", { bubbles: true }))');
  await waitFor(`document.querySelector('#library [data-action="resume"][data-id="${pdf.id}"]')`, 'continue reading card');
  await shot('web-continue-reading.png');
  await reloadPage();
  await waitFor(`document.querySelector('#library [data-action="resume"][data-id="${pdf.id}"]')`, 'reading history survives reload');
  await click(`#library [data-action="resume"][data-id="${pdf.id}"]`);
  await waitFor('!document.querySelector("#workspace").hidden && document.querySelector("#page-input")?.value === "2"', 'resume exact reading position');
  await click('[data-action="newThread"]');
  await waitFor('document.querySelector("[data-study-prompt=Practice]")', 'new study conversation');
  await evaluate('document.querySelector("#question").value = "My own question."; document.querySelector("#question").dispatchEvent(new Event("input", { bubbles:true }))');
  await click('[data-study-prompt="Practice"]');
  await waitFor('document.querySelector("#practice-dialog").open && document.querySelector("#practice-setup")', 'structured practice setup');
  assert.equal(await evaluate('document.querySelector("#question").value'), 'My own question.', 'practice preserves the chat draft');
  await evaluate('document.querySelector("#practice-setup [name=count]").value = "2"; document.querySelector("#practice-setup").requestSubmit()');
  await waitFor('document.querySelector(".practice-prompt") && document.querySelector("#practice-answer")', 'generated source-linked question');
  const learningRequest = `fetch('/api/learning', {headers: {'X-Scholia-Token': document.querySelector('meta[name="scholia-token"]').content}}).then(r => r.json())`;
  const firstPractice = await evaluate(learningRequest);
  assert.equal(firstPractice.question.referenceAnswer, undefined, 'reference answer withheld by API');
  assert.equal(firstPractice.question.rubric, undefined, 'private rubric withheld by API');
  assert.equal(firstPractice.question.source.documentID, pdf.id, 'source identity bound to question');
  assert.ok(firstPractice.question.source.contentHash);
  await evaluate('document.querySelector("#practice-answer").value = "Its magnitude stays fixed."; document.querySelector("#practice-answer").dispatchEvent(new Event("input", {bubbles:true})); document.querySelector("#practice-confidence").value = "3"; document.querySelector("#practice-answer-form").requestSubmit(); document.querySelector("#practice-answer-form").requestSubmit()');
  await waitFor('document.querySelector(".practice-attempt")?.textContent.includes("Distinguish direction")', 'corrective feedback');
  assert.equal((await evaluate(learningRequest)).attempts.length, 1, 'double submit creates one attempt');
  await click('[data-practice="hint"]');
  await waitFor('document.querySelector(".practice-hint")', 'graduated hint');
  await reloadPage();
  await waitFor('document.querySelector("#review-due") && document.querySelector("#page-input")', 'reload reading');
  await click('#review-due');
  await waitFor('document.querySelector("[data-practice=resume]")', 'saved practice handoff');
  await click('[data-practice="resume"]');
  await waitFor('document.querySelector(".practice-hint") && document.querySelector(".practice-attempt")', 'attempt and hint survive reload');
  await evaluate('document.querySelector("[data-correction]").value = "Please check my interpretation."');
  await click('[data-practice="dispute"]');
  await waitFor('document.querySelector(".practice-attempt").textContent.includes("Unresolved")', 'feedback dispute saved');
  await click('[data-practice="revise"]');
  await waitFor('document.querySelector("#practice-answer")', 'revision field');
  await evaluate('document.querySelector("#practice-answer").value = "It stays on the same line, while its length may change."; document.querySelector("#practice-answer-form").requestSubmit()');
  await waitFor('document.querySelectorAll(".practice-attempt").length === 2 && !document.querySelector("[data-practice=revise]").disabled', 'revision assessed');
  const revisedPractice = await evaluate(learningRequest);
  assert.equal(revisedPractice.attempts[0].answer, 'Its magnitude stays fixed.');
  assert.equal(revisedPractice.attempts[1].previousAttemptID, revisedPractice.attempts[0].id);
  assert.equal(revisedPractice.attempts[1].hintCount, 1);
  await click('[data-practice="reveal"]');
  await waitFor('document.querySelector(".practice-solution")', 'explicit reference reveal');
  await shot('web-study-practice.png');
  await client.send('Emulation.setDeviceMetricsOverride', {width:390,height:844,deviceScaleFactor:1,mobile:true});
  await shot('web-study-practice-mobile.png');
  assert.ok(await evaluate('document.querySelector("#practice-dialog").scrollWidth <= innerWidth'), 'practice fits mobile');
  await client.send('Emulation.setDeviceMetricsOverride', {width:1460,height:960,deviceScaleFactor:1,mobile:false});
  await click('[data-practice="saveReview"]');
  await waitFor('!document.querySelector("[data-practice=next]").disabled', 'review saved before advancing');
  await click('[data-practice="next"]');
  await waitFor('document.querySelector(".practice-prompt")?.textContent.includes("Question 2")', 'next question');
  await click('[data-practice="finish"]');
  await waitFor('document.querySelector(".practice-body h2")?.textContent === "Session recap"', 'session recap');
  await click('[data-practice="reviewQueue"]');
  await waitFor('document.querySelector("[data-practice=snooze]")', 'saved review queue');
  await click('[data-practice="snooze"]');
  await waitFor('document.querySelector(".practice-body").textContent.includes("Snoozed by you")', 'snooze persisted');
  await click('[data-practice="close"]');
  await evaluate('document.querySelector("#sidebar-material-search").value = "no such material"; document.querySelector("#sidebar-material-search").dispatchEvent(new Event("input", {bubbles:true}))');
  assert.ok(await evaluate('document.querySelector("#material-nav").textContent.includes("No matching materials")'), 'material search works beside the reading');
  await evaluate('document.querySelector("#sidebar-material-search").value = ""; document.querySelector("#sidebar-material-search").dispatchEvent(new Event("input", {bubbles:true}))');
  // Text readings must retain their DOM, selection and scroll position as a draft creates a conversation.
  await evaluate(`(() => {
    const transfer = new DataTransfer();
    transfer.items.add(new File(['# Study workflow check\\n\\n' + Array.from({length: 45}, (_, i) => 'Reading paragraph ' + (i + 1) + ': explain a concept in your own words before checking the source.').join('\\n\\n')], 'Study workflow check.md', {type: 'text/markdown'}));
    const input = document.querySelector('#document-upload'); input.files = transfer.files; input.dispatchEvent(new Event('change', {bubbles: true}));
  })()`);
  await waitFor('document.querySelector(".paper h1")?.textContent === "Study workflow check"', 'text reading imported');
  await evaluate(`window.studyTextNode = document.querySelector('.paper');
    const range = document.createRange(); range.selectNodeContents(window.studyTextNode.querySelectorAll('p')[3]);
    window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
    document.querySelector('#reader-content').dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
    document.querySelector('#reader-content').scrollTop = 150;
    document.querySelector('#question').value = 'Keep my reading position.';
    document.querySelector('#question').dispatchEvent(new Event('input', {bubbles: true}));`);
  await waitFor(`fetch('/api/state', {headers: {'X-Scholia-Token': document.querySelector('meta[name="scholia-token"]').content}}).then(r => r.json()).then(s => s.draft === 'Keep my reading position.')`, 'draft saved beside text reading');
  assert.deepEqual(await evaluate('({sameNode: window.studyTextNode === document.querySelector(".paper"), scrollTop: document.querySelector("#reader-content").scrollTop})'), {sameNode: true, scrollTop: 150}, 'draft creation retains text reading and scroll position');
  assert.ok(await evaluate('!document.querySelector("#selection-note").hidden && document.querySelector("#selection-note").textContent.includes("Reading paragraph 4")'), 'selection survives first draft save');
  await click('[data-action="clearSelection"]');
  await waitFor('document.querySelector("#selection-note").hidden', 'selected passage can be removed');
  // Simulate a second window changing course before an already captured draft arrives.
  const ownerState = await (await fetch(address + '/api/state', { headers: { 'X-Scholia-Token': token } })).json();
  const other = ownerState.library.courses.find((c) => c.id !== ownerState.library.selectedCourseID);
  const post = (payload) => fetch(address + '/api/action', { method:'POST', headers:{'X-Scholia-Token':token, 'Content-Type':'application/json'}, body:JSON.stringify(payload) });
  await post({ action:'course', id:other.id });
  const conflict = await post({ action:'draft', owner:ownerState.draftOwner, text:'Delayed wrong-course draft', clearImage:true });
  assert.equal(conflict.status, 400);
  const afterConflict = await (await fetch(address + '/api/state', { headers: { 'X-Scholia-Token': token } })).json();
  assert.notEqual(afterConflict.draft, 'Delayed wrong-course draft');
  await reloadPage();
  await waitFor('document.querySelector(".course-materials")', 'second-window navigation');
  await click('[data-action="library"]');
  await waitFor('!document.querySelector("#library").hidden', 'return from practice');
  await click('.topbar [data-action="canvas"]'); await shot('web-canvas.png');
  const errors = client.events.filter((e) => e.method === 'Runtime.exceptionThrown' || e.method === 'Log.entryAdded' && e.params.entry.level === 'error');
  assert.deepEqual(errors, [], 'Browser errors');
  console.log('PASS: native web API isolation, favorites, saved reading resume, structured practice, hints/reveal/revision/review, material search, draft race and repeated send protection, stable reading/chat DOM and text selection, figure question and light/dark/responsive layouts');
} finally {
  client?.close(); chromium.kill('SIGTERM');
  await new Promise((resolve) => { if (chromium.exitCode !== null) resolve(); else chromium.once('exit',resolve); });
  await rm(profile, {recursive:true,force:true});
}
