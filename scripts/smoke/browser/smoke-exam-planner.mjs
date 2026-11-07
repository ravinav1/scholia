import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createHostedServer } from '../../../apps/server/server.js';
import { chromiumSession } from './lib/chromium.mjs';

const root = await mkdtemp(join(tmpdir(), 'scholia-exam-browser-'));
const reserve = createServer();
await new Promise((resolve) => reserve.listen(0, '127.0.0.1', resolve));
const port = reserve.address().port;
await new Promise((resolve) => reserve.close(resolve));
let recommendationCalls = 0;
let adviceCalls = 0, releaseAdvice;
const adviceRequests = [];
const retrievalRequests = [];
const requestedModels = [];
const origin = `http://127.0.0.1:${port}`,
  app = createHostedServer({ root, origin, complete: async (payload) => {
    const input = JSON.parse(payload.context);
    if (input.degreeCatalogue) {
      retrievalRequests.push(input);
      const focused = input.degreeCatalogue.plans.filter(p => p.focus.studyYear);
      const queries = focused.map(p => ({ kind: 'year', programmeCode: p.programmeCode, studyYear: p.focus.studyYear,
        term: p.focus.term, branchPath: p.focus.branchPath }));
      if (!queries.length && input.question.includes('foundations')) queries.push({ kind: 'year', programmeCode: 'MTTK', studyYear: 1 });
      return { text: JSON.stringify({ queries }) };
    }
    requestedModels.push([payload.provider, payload.model]);
    if ('question' in input) {
      adviceCalls++;
      adviceRequests.push(input);
      if (input.question.includes('Cancel this request')) return new Promise((resolve) => {
        releaseAdvice = () => resolve({ text: 'This canceled answer must not appear.' });
      });
      if (input.question === 'Fail this follow-up') throw new Error('Fixture follow-up unavailable');
      if (input.conversation?.length) {
        assert.match(input.conversation[0].content, /practical programming and robotics/);
        assert.match(input.conversation[1].content, /Take TDT4100 over TMA4100/);
        return { text: `With your earlier robotics goal in mind, here is the next comparison.\n\nYou asked: ${input.question}` };
      }
      if (!input.courses.length) return { text: 'Start with the exams that matter most to your goals and need the most preparation.' };
      assert.ok(input.overlaps.some((pair) => pair.status === 'collision'));
      assert.ok(input.overlaps.some((pair) => pair.status === 'possible'));
      return { text: '**Take TDT4100 over TMA4100** if your priority is practical programming and robotics. Their final exams overlap on 10 December.\n\nCalculus becomes the stronger choice if it is required for your degree or you feel substantially better prepared for it. Confirm that before deciding.\n\n**TFE4146 remains an option:** its times are incomplete, so confirm the possible overlap first.' };
    }
    assert.match(payload.messages[0].content, /Robotics and practical programming/);
    if (++recommendationCalls === 1) throw new Error('Fixture provider unavailable');
    return { text: JSON.stringify({ courseLimit: 3, rankedCourses: [
      { courseKey: 'TDT4100', reason: 'Programming supports your robotics projects.' },
      { courseKey: 'TMA4100', reason: 'Calculus helps with modelling and control.' },
      { courseKey: 'TFE4146', reason: 'Sensors connect software with the physical world.' },
      { courseKey: 'TEST1000', reason: 'Independent study gives you room to apply your interests.' },
    ] }) };
  } });
let browser;
try {
  const user = await app.store.createUser('exams@example.com', 'correct horse battery staple');
  const fixtureAccount = app.workspaces.account(user.id);
  fixtureAccount.library.courses = [
    ['programming', 'TDT4100-26H', 'Object-oriented programming'],
    ['calculus', 'TMA4100', 'Calculus'],
    ['sensors', 'TFE4146', 'Sensors'],
    ['independent', 'TEST1000', 'Independent study'],
  ].map(([id, code, name]) => ({ id, code, name, documents: [], threads: [] }));
  app.store.save(fixtureAccount);
  await new Promise((resolve) => app.server.listen(port, '127.0.0.1', resolve));
  browser = await chromiumSession();
  const { evaluate, until, click, send } = browser;
  await mkdir(resolve('dist/verification'), { recursive: true });
  const input = async (selector, value) =>
    evaluate(
      `{ const input = document.querySelector(${JSON.stringify(selector)}); input.value=${JSON.stringify(value)}; input.dispatchEvent(new Event('input', {bubbles:true})); input.dispatchEvent(new Event('change', {bubbles:true})); }`
    );
  const chooseAnotherModel = async () => {
    const choice = await evaluate(`{
      const picker = document.querySelector('#exam-model-picker');
      [...picker.options].find(option => !option.disabled && option.value !== picker.value).value;
    }`);
    await input('#exam-model-picker', choice);
    await until(`!document.querySelector('#exam-model-picker').disabled && document.querySelector('#exam-model-picker').value === ${JSON.stringify(choice)}`);
    const identity = JSON.parse(choice);
    assert.deepEqual([fixtureAccount.settings.providerID, fixtureAccount.settings.modelID], identity);
    assert.equal(await evaluate('document.querySelector("#model-picker").value'), choice, 'The planner and chat use the same selected model');
    assert.ok((await evaluate('document.querySelector(".exam-recommendation-model").textContent')).includes(identity[1]), 'Model-only updates refresh the planner without changing its dates');
    return identity;
  };
  await send('Emulation.setDeviceMetricsOverride', {
    width: 1460,
    height: 1080,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await send('Page.navigate', { url: origin });
  await until('document.querySelector("#sign-in") && document.readyState === "complete"');
  await evaluate(
    `document.querySelector('[name=email]').value='exams@example.com'; document.querySelector('[name=password]').value='correct horse battery staple'; document.querySelector('#sign-in').requestSubmit()`
  );
  await until('document.querySelector(".study-dashboard")');
  assert.equal(await evaluate('document.querySelector("footer#status")'), null, 'Sync messages no longer occupy a bottom bar');
  assert.equal(await evaluate('document.querySelector("#sync-status").open'), false);
  fixtureAccount.busy = true;
  fixtureAccount.status = 'Math wiki: downloading 6 materials…';
  fixtureAccount.library.courses[0].catalogWarnings = ['One Canvas file needs another download attempt.'];
  fixtureAccount.controller = new AbortController();
  await until('document.querySelector("#sync-status").classList.contains("busy")');
  assert.equal(await evaluate('getComputedStyle(document.querySelector("#sync-status svg")).animationName'), 'spin');
  await click('#sync-status summary');
  assert.match(await evaluate('document.querySelector("#status").textContent'), /Math wiki: downloading 6 materials/);
  assert.match(await evaluate('document.querySelector("#status").textContent'), /another download attempt/);
  await browser.screenshot(resolve('dist/verification/sync-toolbar-active.png'));
  await click('#status [data-action=cancelSync]');
  await until('document.querySelector("#sync-status").open');
  assert.equal(fixtureAccount.controller.signal.aborted, true, 'Stop remains available inside the sync panel');
  fixtureAccount.busy = false;
  fixtureAccount.status = 'Math wiki: 6 materials downloaded or updated.';
  await until('!document.querySelector("#sync-status").classList.contains("busy") && document.querySelector("#status").textContent.includes("6 materials downloaded")');
  assert.equal(await evaluate('getComputedStyle(document.querySelector("#sync-status svg")).animationName'), 'none');
  assert.equal(await evaluate('document.querySelector("#sync-status .sync-attention").hidden'), false);
  await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
  assert.equal(await evaluate('document.querySelector("#sync-status").open'), false);
  assert.equal(await evaluate('document.activeElement === document.querySelector("#sync-status summary")'), true);
  await click('#sync-status summary');
  await click('#status [data-action=canvas]');
  assert.equal(await evaluate('document.querySelector("#canvas-dialog").open'), true);
  assert.equal(await evaluate('document.querySelector("#sync-status").open'), false);
  await evaluate('document.querySelector("#canvas-dialog").close()');
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await click('#sync-status summary');
  assert.equal(await evaluate('{ const box = document.querySelector("#status").getBoundingClientRect(); box.left >= 0 && box.right <= innerWidth; }'), true);
  await browser.screenshot(resolve('dist/verification/sync-toolbar-mobile.png'));
  await click('#breadcrumb');
  assert.equal(await evaluate('document.querySelector("#sync-status").open'), false, 'Clicking outside closes the panel');
  fixtureAccount.status = null;
  fixtureAccount.controller = null;
  fixtureAccount.library.courses[0].catalogWarnings = [];
  await send('Emulation.setDeviceMetricsOverride', { width: 1460, height: 1080, deviceScaleFactor: 1, mobile: false });
  await click('.exam-dashboard');
  await until('!document.querySelector("#exam-planner").hidden');
  assert.equal(await evaluate('document.querySelectorAll("dialog[open]").length'), 0);
  await click('[name=exam-recommendation-mode][value=advice]');
  await evaluate(`document.querySelector('#exam-interests').value = 'How should I prioritize revision?'; document.querySelector('#exam-interests').dispatchEvent(new Event('input', {bubbles:true}))`);
  const adviceModel = await chooseAnotherModel();
  assert.equal(await evaluate('document.querySelector("#exam-interests").value'), 'How should I prioritize revision?', 'Switching models preserves the question');
  assert.equal(await evaluate('document.querySelector("[data-recommend=generate]").disabled'), false, 'General advice is available before adding exams');
  await click('[data-recommend=generate]');
  await until('document.querySelector(".exam-advice")');
  assert.equal(adviceCalls, 1);
  assert.deepEqual(requestedModels.at(-1), adviceModel, 'Advice uses the model selected in the planner');
  assert.equal(fixtureAccount.library.examPlan, undefined);
  assert.equal(await evaluate('document.querySelector("[data-recommend=apply]")'), null);
  await click('[name=exam-recommendation-mode][value=selection]');
  assert.equal(await evaluate('document.querySelector("[data-recommend=generate]").disabled'), true);
  await click('[data-schedule-action=edit]');
  await click('.exam-import summary');
  const text =
    'TDT4100 Object-oriented programming\nMidterm 14.10.2026 09:00–11:00\nFinal exam 10.12.2026 09:00–13:00\nTMA4100 Calculus\nFinal exam 10.12.2026 12:00–16:00\nTFE4146 Sensors\nFinal exam 10.12.2026';
  await input('#exam-import-text', text);
  await click('[data-exam-action=preview]');
  await until('document.querySelectorAll(".exam-preview .exam-row").length === 4');
  assert.equal(
    app.workspaces.account(user.id).library.examPlan,
    undefined,
    'Preview never persists raw import or candidates'
  );
  assert.equal(await evaluate('document.querySelector("#exam-import-text").value'), '');
  await click('[data-exam-action=accept]');
  assert.equal(await evaluate('document.querySelector("#exam-order").value'), 'date');
  assert.deepEqual(await evaluate('[...document.querySelectorAll(".exam-groups [data-exam-field=date]")].map(input => input.value)'),
    ['2026-10-14', '2026-12-10', '2026-12-10', '2026-12-10']);
  await input('#exam-order', 'course');
  assert.equal(await evaluate('document.querySelectorAll(".exam-course").length'), 3);
  assert.equal(
    await evaluate('document.querySelector(".exam-course").querySelectorAll(".exam-row").length'),
    2
  );
  await evaluate(
    `for (let i = 0; i < 4; i++) document.querySelectorAll('.exam-groups [data-exam-field=selected]')[i].click()`
  );
  assert.equal(await evaluate('document.querySelectorAll(".exam-status.collision").length'), 2);
  assert.equal(await evaluate('document.querySelectorAll(".exam-status.possible").length'), 1);
  assert.equal(await evaluate('document.querySelectorAll(".exam-status.clear").length'), 1);
  await click('[data-exam-action=save]');
  await until('document.querySelector(".exam-feedback").textContent === "Your plan is saved."');
  assert.equal(
    app.store.account(user.id).library.examPlan.filter((exam) => exam.selected).length,
    4
  );
  await input('#exam-import-text', text);
  await click('[data-exam-action=preview]');
  await click('[data-exam-action=accept]');
  assert.equal(
    await evaluate('document.querySelectorAll(".exam-groups .exam-row").length'),
    4,
    'Repeat import deduplicates'
  );
  assert.equal(
    await evaluate('document.querySelectorAll(".exam-groups input:checked").length'),
    4,
    'Repeat import retains intent'
  );
  await click('[data-exam-action=add]');
  assert.equal(
    await evaluate('document.activeElement.dataset.examField'),
    'courseCode',
    await evaluate('document.querySelector(".exam-feedback").textContent')
  );
  await input('.exam-groups [data-exam-field=courseCode][value=""]', 'TEST1000');
  const rowID = await evaluate(
    `[...document.querySelectorAll('[data-exam-field=courseCode]')].find(input => input.value === 'TEST1000').closest('[data-exam-id]').dataset.examId`
  );
  const row = `.exam-groups [data-exam-id="${rowID}"]`;
  await evaluate(
    `document.querySelector(${JSON.stringify(`${row} [data-exam-field=courseCode]`)}).focus()`
  );
  await send('Input.insertText', { text: 'A' });
  await send('Input.dispatchKeyEvent', {
    type: 'keyDown',
    key: 'Tab',
    code: 'Tab',
    windowsVirtualKeyCode: 9,
  });
  await send('Input.dispatchKeyEvent', {
    type: 'keyUp',
    key: 'Tab',
    code: 'Tab',
    windowsVirtualKeyCode: 9,
  });
  assert.equal(
    await evaluate('document.activeElement.dataset.examField'),
    'courseName',
    'Tab should advance to the next exam field after regrouping'
  );
  await input(`${row} [data-exam-field=courseCode]`, 'TEST1000');
  await input(
    `${row} [data-exam-field=courseName]`,
    '<img src=x onerror="window.examInjected=true">'
  );
  await input(`${row} [data-exam-field=date]`, '2026-12-12');
  await click(`${row} [data-exam-field=selected]`);
  assert.equal(await evaluate('!!window.examInjected'), false);
  assert.equal(await evaluate('document.querySelectorAll(".exam-groups img").length'), 0);
  assert.equal(
    await evaluate(`document.querySelector(${JSON.stringify(`${row} .exam-status`)}).textContent`),
    'Check date / time'
  );
  await click('[data-exam-action=save]');
  await until('document.querySelector(".exam-feedback").textContent === "Your plan is saved."');
  await click('.exam-import summary');
  await mkdir(resolve('dist/verification'), { recursive: true });
  await browser.screenshot(resolve('dist/verification/exam-planner-desktop.png'));
  await send('Emulation.setDeviceMetricsOverride', {
    width: 390,
    height: 844,
    deviceScaleFactor: 1,
    mobile: true,
  });
  await browser.screenshot(resolve('dist/verification/exam-planner-mobile.png'));
  assert.equal(
    await evaluate(
      'document.querySelector("#exam-planner-editor").scrollWidth <= document.querySelector("#exam-planner-editor").clientWidth + 1'
    ),
    true
  );
  assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth + 1'), true);
  // A concurrently saved native/browser edit must not be overwritten by this draft.
  app.workspaces.account(user.id).library.examPlan[0].selected = false;
  await click(`${row} [data-exam-field=selected]`);
  await click('[data-exam-action=save]');
  await until('document.querySelector(".exam-feedback").classList.contains("error")');
  assert.match(
    await evaluate('document.querySelector(".exam-feedback").textContent'),
    /changed elsewhere/
  );
  assert.equal(app.workspaces.account(user.id).library.examPlan[0].selected, false);
  assert.equal(
    await evaluate(
      `document.querySelector(${JSON.stringify(`${row} [data-exam-field=selected]`)}).checked`
    ),
    false,
    'Failed save retains the draft'
  );
  await click('[data-exam-action=reload]');
  await until('document.querySelector(".exam-feedback").textContent === "Your plan is saved."');
  await click('[data-exam-action=close]');
  assert.equal(await evaluate('document.querySelectorAll(".exam-schedule-row").length'), 4);
  // Use readable fixture labels for visual verification after the escaping test.
  fixtureAccount.library.examPlan[0].selected = true;
  const independent = fixtureAccount.library.examPlan.find(
    (exam) => exam.courseCode === 'TEST1000'
  );
  Object.assign(independent, {
    courseName: 'Independent study',
    startTime: '09:00',
    endTime: '11:00',
  });
  await send('Page.navigate', { url: `${origin}/?exam-view=fixture#exams` });
  await until(
    'document.querySelector("#exam-planner") && !document.querySelector("#exam-planner").hidden'
  );
  assert.equal(await evaluate('document.querySelector("#exam-planner-editor").hidden'), true);
  assert.equal(await evaluate('document.querySelectorAll("dialog[open]").length'), 0);
  await send('Emulation.setDeviceMetricsOverride', {
    width: 1460,
    height: 1080,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await until('document.querySelector(".exam-favorites button")');
  await until('document.querySelector(".exam-schedule-feedback").textContent.includes("Saved.")');
  await input('#exam-interests', 'Robotics and practical programming; suggest useful courses for building robots.');
  assert.equal(await evaluate('document.querySelector("#exam-model-picker").value'), JSON.stringify(adviceModel), 'The selected model survives navigation and reload');
  const selectionModel = await chooseAnotherModel();
  await click('[data-recommend=generate]');
  await until('document.querySelector(".exam-recommendation-status").textContent.includes("Fixture provider unavailable")');
  assert.equal(await evaluate('document.querySelector("[data-recommend=generate]").disabled'), false);
  await click('[data-recommend=generate]');
  await until('document.querySelector("[data-recommend=apply]")');
  assert.deepEqual(requestedModels.at(-1), selectionModel, 'Selection recommendations use the model selected in the planner');
  assert.equal(fixtureAccount.library.examPlan.filter((exam) => exam.selected).length, 5, 'Recommendations leave current selections unchanged');
  assert.match(await evaluate('document.querySelector(".exam-recommendation-status").textContent'), /2 courses.*3 exams.*no fixed-time clashes/);
  assert.match(await evaluate('document.querySelector(".exam-recommendation-result").textContent'), /Clashes.*missing/s);
  await browser.screenshot(resolve('dist/verification/exam-recommendation-desktop.png'));
  await click('[data-recommend=apply]');
  await until('document.querySelector(".exam-schedule-feedback").textContent.includes("Saved.")');
  assert.equal(fixtureAccount.library.examPlan.filter((exam) => exam.selected).length, 3);
  assert.equal(fixtureAccount.library.examPlan.find((exam) => exam.courseCode === 'TMA4100').selected, false);
  assert.equal(fixtureAccount.library.examPlan.find((exam) => exam.courseCode === 'TFE4146').selected, false);
  await click('[data-schedule-action=undo]');
  await until('document.querySelector(".exam-schedule-feedback").textContent.includes("Saved.")');
  assert.equal(fixtureAccount.library.examPlan.filter((exam) => exam.selected).length, 5);
  assert.match(await evaluate('document.querySelector("#exam-interests").value'), /Robotics/);
  const beforeAdvice = structuredClone(fixtureAccount.library.examPlan);
  await click('[name=exam-recommendation-mode][value=advice]');
  await input('#exam-interests', 'Which overlapping exam should I take? I enjoy practical programming and robotics.');
  await click('[data-recommend=generate]');
  await until('document.querySelector(".exam-advice strong")');
  assert.match(await evaluate('document.querySelector(".exam-advice").textContent'), /Take TDT4100 over TMA4100.*possible overlap/s);
  assert.equal(await evaluate('document.querySelector("[data-recommend=apply]")'), null, 'Advice has no selection action');
  assert.deepEqual(fixtureAccount.library.examPlan, beforeAdvice, 'Advice never changes selected exams or timing');
  assert.equal(await evaluate('document.querySelector(".exam-follow-up").hidden'), false);
  await input('#exam-follow-up', 'What foundations should I prioritize for MTTK?');
  await click('[data-recommend=followUp]');
  await until('document.querySelectorAll(".exam-advice-turn").length === 4');
  assert.equal(adviceRequests.at(-1).conversation.length, 2);
  assert.equal(adviceRequests.at(-1).degreePlans.scope, 'retrieved-plans');
  const foundation = adviceRequests.at(-1).degreePlans.results[0].data;
  assert.deepEqual(foundation.plans.map(plan => [plan.programmeCode, plan.admissionYear]), [['MTTK', 2023]]);
  assert.deepEqual(foundation.plans[0].periods.map(p => p.number), [1, 2]);
  assert.deepEqual(foundation.plans[0].missingPeriods, [9, 10]);
  assert.ok(JSON.stringify(retrievalRequests.at(-1).degreeCatalogue).length < 9000);
  assert.equal(retrievalRequests.at(-1).passedCourseCodes, undefined);
  assert.equal(adviceRequests.at(-1).passedCourseCodes, undefined, 'Browser advice cannot access private Studentweb statuses');
  assert.equal(await evaluate('document.querySelector("#exam-follow-up").value'), '');
  await chooseAnotherModel();
  assert.equal(await evaluate('document.querySelectorAll(".exam-advice-turn").length'), 4, 'A model switch retains the conversation');
  await until('document.querySelector("[data-degree=enabled]")');
  assert.equal(await evaluate('document.querySelector(".exam-degree-focus").open'), false, 'The main interface only shows admission years');
  await click('.exam-degree-focus summary');
  assert.equal(await evaluate('document.querySelectorAll(".exam-degree-card").length'), 2);
  assert.equal(await evaluate('document.querySelector("[data-degree=admission][data-programme=MTTK]").options.length'), 18);
  assert.equal(await evaluate('document.querySelector("[data-degree=admission][data-programme=MTTK]").value'), '2023');
  await input('[data-degree=year][data-programme=MTTK]', '4');
  await input('[data-degree=term][data-programme=MTTK]', 'autumn');
  await input('[data-degree=branch][data-programme=MTTK]', '["MTTK-RFRO"]');
  await input('[data-degree=admission][data-programme=MTTK]', '2022');
  assert.equal(await evaluate('document.querySelector("[data-degree=branch][data-programme=MTTK]").value'), '[]', 'Changing cohort clears the old profile');
  await input('[data-degree=admission][data-programme=MTTK]', '2023');
  await input('[data-degree=branch][data-programme=MTTK]', '["MTTK-RFRO"]');
  await input('[data-degree=year][data-programme=MTNANO]', '3');
  await input('[data-degree=branch][data-programme=MTNANO]', '["MTNANO-BT"]');
  assert.match(await evaluate('document.querySelector(".exam-recommendation-status").textContent'), /Degree choices changed/);
  await input('#exam-follow-up', 'Fail this follow-up');
  await click('[data-recommend=followUp]');
  await until('document.querySelector(".exam-recommendation-status").textContent.includes("Fixture follow-up unavailable")');
  assert.equal(await evaluate('document.querySelectorAll(".exam-advice-turn").length'), 4);
  assert.equal(await evaluate('document.querySelector("#exam-follow-up").value'), 'Fail this follow-up', 'A failed reply retains the draft');
  await input('#exam-follow-up', 'Which of those should come first?');
  await click('[data-recommend=followUp]');
  await until('document.querySelectorAll(".exam-advice-turn").length === 6');
  assert.equal(adviceRequests.at(-1).conversation.length, 4, 'Every completed turn reaches the next request');
  const chosenPlans = adviceRequests.at(-1).degreePlans;
  assert.equal(chosenPlans.scope, 'retrieved-plans');
  assert.deepEqual(chosenPlans.results.flatMap(r => r.data.plans).map(p => [p.planID, p.selection.studyYear, p.selection.branchPath]),
    [['MTNANO:2023', 3, ['MTNANO-BT']], ['MTTK:2023', 4, ['MTTK-RFRO']]]);
  assert.deepEqual(chosenPlans.results.flatMap(r => r.data.plans).find(p => p.programmeCode === 'MTTK').periods.map(p => p.number), [7]);
  assert.deepEqual([...new Set(chosenPlans.results.flatMap(r => Object.values(r.data.nodes)).map(n => n.directionCode).filter(Boolean))].sort(), ['MTNANO-BT', 'MTTK-RFRO']);
  assert.equal(adviceRequests.at(-1).passedCourseCodes, undefined);
  await input('#exam-follow-up', 'Cancel this request');
  await click('[data-recommend=followUp]');
  await until('!document.querySelector("[data-recommend=cancelFollowUp]").hidden');
  assert.equal(await evaluate('document.querySelector("[data-degree=enabled]").disabled'), true, 'Curriculum choices remain fixed during a request');
  for (let i = 0; !releaseAdvice && i < 100; i++) await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(releaseAdvice);
  await click('[data-recommend=cancelFollowUp]');
  await until('document.querySelector(".exam-recommendation-status").textContent === "Advice canceled."');
  releaseAdvice(); releaseAdvice = null;
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.equal(await evaluate('document.querySelectorAll(".exam-advice-turn").length'), 6, 'Cancel keeps earlier turns');
  assert.equal(await evaluate('document.querySelector("#exam-follow-up").value'), 'Cancel this request');
  await click('.exam-degree-focus summary');
  await evaluate('document.querySelector(".exam-recommendation").scrollIntoView({block:"start"})');
  await browser.screenshot(resolve('dist/verification/exam-advice-desktop.png'));
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await browser.screenshot(resolve('dist/verification/exam-advice-mobile.png'));
  await evaluate('document.querySelector(".exam-degree-plans").scrollIntoView({block:"start"})');
  await browser.screenshot(resolve('dist/verification/degree-plan-selectors-mobile.png'));
  assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth + 1'), true);
  await send('Emulation.setDeviceMetricsOverride', { width: 1460, height: 1080, deviceScaleFactor: 1, mobile: false });
  await evaluate('document.querySelector(".exam-degree-plans").scrollIntoView({block:"start"})');
  await browser.screenshot(resolve('dist/verification/degree-plan-selectors-desktop.png'));
  await evaluate('document.querySelector(".exam-follow-up").scrollIntoView({block:"end"})');
  await browser.screenshot(resolve('dist/verification/exam-advice-follow-up.png'));
  await click('[data-recommend=newConversation]');
  assert.equal(await evaluate('document.querySelectorAll(".exam-advice-turn").length'), 0);
  await input('#exam-interests', 'Cancel this request');
  assert.equal(await evaluate('document.querySelector(".exam-advice")'), null, 'Editing a question clears its old answer');
  await click('[data-recommend=generate]');
  await until('!document.querySelector("[data-recommend=cancel]").hidden');
  assert.equal(await evaluate('document.querySelector("#exam-model-picker").disabled'), true, 'Keep the model fixed while a request is running');
  for (let i = 0; !releaseAdvice && i < 100; i++) await new Promise((resolve) => setTimeout(resolve, 20));
  assert.ok(releaseAdvice);
  await click('[data-recommend=cancel]');
  releaseAdvice();
  await until('document.querySelector(".exam-recommendation-status").textContent === "Advice canceled."');
  assert.equal(await evaluate('document.querySelector(".exam-advice")'), null);
  assert.equal(await evaluate('document.querySelector("[data-recommend=generate]").disabled'), false);
  assert.equal(await evaluate('document.querySelector("#exam-model-picker").disabled'), false);
  await click('[name=exam-recommendation-mode][value=selection]');
  assert.equal(
    fixtureAccount.library.courses.find((course) => course.id === 'independent').favorite,
    true
  );
  assert.equal(
    !!fixtureAccount.library.courses.find((course) => course.id === 'programming').favorite,
    false
  );
  await send('Emulation.setEmulatedMedia', {
    features: [{ name: 'prefers-color-scheme', value: 'light' }],
  });
  await evaluate('new Promise(resolve => setTimeout(resolve, 200))');
  await browser.screenshot(resolve('dist/verification/exam-schedule-desktop.png'));
  await send('Emulation.setEmulatedMedia', {
    features: [{ name: 'prefers-color-scheme', value: 'dark' }],
  });
  await evaluate('new Promise(resolve => setTimeout(resolve, 200))');
  await browser.screenshot(resolve('dist/verification/exam-schedule-dark.png'));
  await send('Emulation.setEmulatedMedia', {
    features: [{ name: 'prefers-color-scheme', value: 'light' }],
  });
  await send('Emulation.setDeviceMetricsOverride', {
    width: 390,
    height: 844,
    deviceScaleFactor: 1,
    mobile: true,
  });
  await evaluate('new Promise(resolve => setTimeout(resolve, 200))');
  await browser.screenshot(resolve('dist/verification/exam-schedule-mobile.png'));
  assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth + 1'), true);
  const sensorsID = fixtureAccount.library.examPlan.find((exam) => exam.courseCode === 'TFE4146').id;
  const timingAndIntent = () => fixtureAccount.library.examPlan.map(
    ({ id, date, endDate, startTime, endTime, selected }) => ({ id, date, endDate, startTime, endTime, selected })
  );
  const beforeFlexible = timingAndIntent();
  await click(`.exam-comparison.possible [data-schedule-action=flexible][data-exam-id="${sensorsID}"][data-flexible=true]`);
  await until('document.querySelector(".exam-schedule-feedback").textContent.includes("Saved.")');
  assert.deepEqual(timingAndIntent(), beforeFlexible, 'Flexible override keeps both courses selected and every date/time unchanged');
  assert.equal(fixtureAccount.library.examPlan.find((exam) => exam.id === sensorsID).flexible, true);
  assert.equal(await evaluate('document.querySelectorAll(".exam-comparison.possible").length'), 0);
  await send('Page.navigate', { url: `${origin}/?flexible-persistence=fixture#exams` });
  await until(`document.querySelector('[data-schedule-action=flexible][data-exam-id="${sensorsID}"][data-flexible=false]')`);
  assert.match(await evaluate('document.querySelector(".exam-schedule-row.flexible").textContent'), /Date kept for reference.*arrange with professor/s);
  assert.deepEqual(timingAndIntent(), beforeFlexible, 'Flexible timing survives reload without dropping either course');
  await click(`[data-schedule-action=flexible][data-exam-id="${sensorsID}"][data-flexible=false]`);
  await until('document.querySelector(".exam-schedule-feedback").textContent.includes("Saved.")');
  assert.equal(fixtureAccount.library.examPlan.find((exam) => exam.id === sensorsID).flexible, false);
  assert.ok(await evaluate('document.querySelector(".exam-comparison.possible") !== null'), 'Restoring fixed timing restores the possible overlap');
  await click('.exam-comparison.possible [data-schedule-action=choose]');
  await until('document.querySelector(".exam-schedule-feedback").textContent.includes("Saved.")');
  const afterChoice = app.workspaces.account(user.id).library.examPlan;
  assert.equal(afterChoice.find((exam) => exam.courseCode === 'TFE4146').selected, false);
  await click('[data-schedule-action=undo]');
  await until('document.querySelector(".exam-schedule-feedback").textContent.includes("Saved.")');
  assert.equal(
    app.workspaces.account(user.id).library.examPlan.find((exam) => exam.courseCode === 'TFE4146')
      .selected,
    true
  );
  await click('.exam-comparison.collision [data-keep][data-drop]');
  await until('document.querySelector(".exam-schedule-feedback").textContent.includes("Saved.")');
  await click('.exam-comparison.possible [data-keep][data-drop]');
  await until('!document.querySelector(".exam-comparison")');
  assert.equal(
    fixtureAccount.library.courses.find((course) => course.id === 'programming').favorite,
    true
  );
  assert.equal(
    !!fixtureAccount.library.courses.find((course) => course.id === 'calculus').favorite,
    false
  );
  await click('[data-schedule-action=undo]');
  await until('document.querySelector(".exam-comparison")');
  assert.equal(
    fixtureAccount.library.courses.find((course) => course.id === 'programming').favorite,
    false
  );
  const selectedIDs = () => fixtureAccount.library.examPlan.filter((exam) => exam.selected).map((exam) => exam.id).sort();
  const beforeBulk = selectedIDs();
  await click('.exam-course-selection summary');
  await click('.exam-course-selection [data-schedule-action=clearAll]');
  await until('document.querySelector(".exam-schedule-feedback").textContent.includes("Saved.")');
  assert.deepEqual(selectedIDs(), [], 'Clear selection clears every course component');
  assert.equal(await evaluate('document.querySelectorAll(".exam-schedule-row").length'), 0);
  assert.equal(await evaluate('document.querySelector(".exam-course-selection").open'), true);
  assert.equal(await evaluate('document.querySelector("[data-schedule-action=clearAll]").disabled'), true);
  await click('[data-schedule-action=undo]');
  await until('document.querySelector(".exam-schedule-feedback").textContent.includes("Saved.")');
  assert.deepEqual(selectedIDs(), beforeBulk, 'Undo restores the previous course selection');
  await click('.exam-course-selection [data-schedule-action=clearAll]');
  await until('document.querySelector(".exam-schedule-feedback").textContent.includes("Saved.")');
  await click('.exam-course-selection [data-schedule-action=selectAll]');
  await until('document.querySelector(".exam-schedule-feedback").textContent.includes("Saved.")');
  assert.equal(selectedIDs().length, fixtureAccount.library.examPlan.length);
  assert.equal(fixtureAccount.library.examPlan.filter((exam) => exam.courseCode === 'TDT4100' && exam.selected).length, 2, 'Select all includes both midterm and final exam for a course');
  assert.equal(await evaluate('document.querySelector("[data-schedule-action=selectAll]").disabled'), true);
  assert.equal(await evaluate('document.querySelector(".exam-course-selection").open'), true, 'Bulk actions retain the open course selection');
  await click('[data-schedule-action=undo]');
  await until('document.querySelector(".exam-schedule-feedback").textContent.includes("Saved.")');
  assert.deepEqual(selectedIDs(), [], 'Undo Select all restores the cleared plan');
  await click('.exam-course-selection [data-schedule-action=selectAll]');
  await until('document.querySelector(".exam-schedule-feedback").textContent.includes("Saved.")');
  await click('[data-schedule-action=edit]');
  const oralRow = `.exam-groups [data-exam-id="${sensorsID}"]`;
  await input(`${oralRow} [data-exam-field=component]`, 'Oral exam');
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(`${oralRow} [data-exam-field=flexible]`)}).checked`), true, 'Changing the component to Oral exam defaults to flexible timing');
  assert.match(await evaluate(`document.querySelector(${JSON.stringify(`${oralRow} .exam-status`)}).textContent`), /Flexible/);
  await click('[data-exam-action=save]');
  await until('document.querySelector(".exam-feedback").textContent === "Your plan is saved."');
  assert.equal(fixtureAccount.library.examPlan.find((exam) => exam.id === sensorsID).flexible, true);
  await send('Page.navigate', { url: `${origin}/?oral-default=fixture#exams` });
  await until(`document.querySelector('[data-schedule-action=flexible][data-exam-id="${sensorsID}"][data-flexible=false]')`);
  await click('[data-schedule-action=edit]');
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(`${oralRow} [data-exam-field=flexible]`)}).checked`), true);
  await click(`${oralRow} [data-exam-field=flexible]`);
  await click('[data-exam-action=save]');
  await until('document.querySelector(".exam-feedback").textContent === "Your plan is saved."');
  assert.equal(fixtureAccount.library.examPlan.find((exam) => exam.id === sensorsID).flexible, false);
  await send('Page.navigate', { url: `${origin}/?oral-fixed-override=fixture#exams` });
  await until('document.querySelector(".exam-comparison.possible")');
  await click('[data-schedule-action=edit]');
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(`${oralRow} [data-exam-field=component]`)}).value`), 'Oral exam');
  assert.equal(await evaluate(`document.querySelector(${JSON.stringify(`${oralRow} [data-exam-field=flexible]`)}).checked`), false, 'Explicit fixed timing for an oral survives saving and reload');
  const scheduleExam = (id, courseCode, date, changes = {}) => ({ id, courseCode, courseName: courseCode,
    component: 'Final exam', kind: 'final', date, startTime: date ? '09:00' : '', endTime: date ? '13:00' : '',
    endDate: '', selected: true, source: 'manual', flexible: !date, ...changes });
  fixtureAccount.library.examPlan = [
    scheduleExam('past', 'TDT4100', '2000-01-01'),
    scheduleExam('late', 'TDT4100', '2099-12-10'),
    scheduleExam('early', 'TMA4100', '2099-11-01'),
    scheduleExam('middle', 'TFE4146', '2099-11-09'),
    scheduleExam('undated', 'TEST1000', ''),
  ];
  app.store.save(fixtureAccount);
  await send('Page.navigate', { url: `${origin}/?past-and-focus=fixture#exams` });
  await until('document.querySelector(".exam-past") && document.querySelectorAll(".exam-favorites button").length === 4');
  assert.equal(await evaluate('document.querySelector(".exam-past").open'), false);
  assert.equal(await evaluate('document.querySelector(".exam-past").previousElementSibling.className'), 'exam-view-heading');
  assert.equal(await evaluate('document.querySelectorAll(".exam-schedule-row").length'), 4, 'Past exams leave the active schedule');
  assert.deepEqual(await evaluate('[...document.querySelectorAll(".exam-favorites button")].map(button => button.dataset.id)'),
    ['calculus', 'sensors', 'programming', 'independent'], 'Ready to focus follows the next selected exam date');
  await click('.exam-past summary');
  assert.match(await evaluate('document.querySelector(".exam-past-row").textContent'), /TDT4100.*1 Jan 2000/s);
  await click('.exam-course-selection summary');
  await click('.exam-course-selection [data-schedule-action=clearAll]');
  await until('document.querySelector(".exam-schedule-feedback").textContent.includes("Saved.")');
  assert.deepEqual(selectedIDs(), ['past'], 'Upcoming bulk selection preserves past exam intent');
  assert.equal(await evaluate('document.querySelector(".exam-past").open'), true, 'Refresh retains disclosure state');
  await click('[data-schedule-action=undo]');
  await until('document.querySelectorAll(".exam-favorites button").length === 4');
  await evaluate('document.querySelector(".exam-view-heading").scrollIntoView({block:"start"})');
  await browser.screenshot(resolve('dist/verification/exam-past-expanded.png'));
  await click('.exam-past summary');
  await browser.screenshot(resolve('dist/verification/exam-past-collapsed.png'));
  assert.deepEqual(browser.errors, []);
  console.log(
    'Exam planner Chromium smoke passed: spinning toolbar sync details, contextual advice follow-ups, model switching, retry/cancel/new conversation, collapsed past exams, chronological focus courses, selection/undo, flexible timing, imports, persistence, mobile and deep link.'
  );
} finally {
  await browser?.close();
  await app.close();
  await rm(root, { recursive: true, force: true });
}
