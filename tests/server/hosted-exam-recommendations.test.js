import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AccountStore } from '../../apps/server/store.js';
import { Workspaces } from '../../apps/server/workspaces.js';
import { buildProviderRequest } from '../../apps/chrome/src/provider-runtime.js';
import { mergeSettings } from '../../packages/core/src/providers.js';
import { examRecommendationInput } from '../../packages/core/src/exam-recommendations.js';
const recommendation = JSON.stringify({ courseLimit: 3, rankedCourses: [{ courseKey: 'TDT4100', reason: 'Programming is useful for your robotics goal.' }] });
const withLookups = (complete, choose = () => ({ queries: [] })) => async (...args) => {
  const input = JSON.parse(args[0].context);
  return input.degreeCatalogue ? { text: JSON.stringify(await choose(input)) } : complete(...args);
};

test('hosted advice validates explicit curriculum choices and refreshes them on follow-up without private completion data', async t => {
  const sent = [];
  const planning = [];
  const f = await fixture(t, async request => { sent.push(JSON.parse(request.context)); return { text: 'Synthetic advice.' }; }, input => {
    planning.push(input);
    return { queries: input.degreeCatalogue.plans.map(p => ({ kind: 'year', programmeCode: p.programmeCode,
      studyYear: p.focus.studyYear, term: p.focus.term, branchPath: p.focus.branchPath })) };
  });
  const selection = { programmeCode: 'MTNANO', admissionYear: 2022, studyYear: 3, term: 'spring', branchPath: ['MTNANO-BT'] };
  const request = { ...f.request, mode: 'advice', interests: 'What should I prioritise?', degreeSelections: [selection],
    includePassedCourses: true, passedCourseCodes: ['PRIVATE1000'] };
  await f.workspaces.recommendExams(f.session, request);
  assert.equal(sent[0].degreePlans.scope, 'retrieved-plans');
  assert.equal(sent[0].degreePlans.results[0].data.plans[0].planID, 'MTNANO:2022');
  assert.deepEqual(sent[0].degreePlans.results[0].data.plans[0].periods.map(p => p.number), [6]);
  assert.equal(planning[0].degreeCatalogue.plans[0].courses, undefined);
  assert.equal(planning[0].passedCourseCodes, undefined, 'Even lookup selection cannot access private Studentweb data through the web API');
  assert.equal(sent[0].passedCourseCodes, undefined);
  request.history = [{ role: 'user', content: request.interests }, { role: 'assistant', content: 'Synthetic advice.' }];
  request.degreeSelections = [{ programmeCode: 'MTTK', admissionYear: 2023, studyYear: 5 }];
  await f.workspaces.recommendExams(f.session, request);
  assert.equal(sent[1].degreePlans.results[0].data.plans[0].planID, 'MTTK:2023');
  assert.deepEqual(sent[1].degreePlans.results[0].data.plans[0].periods, []);
  assert.deepEqual(sent[1].degreePlans.results[0].data.plans[0].selectedPeriods, [9, 10]);
  assert.equal(sent[1].conversation.length, 2);
  request.degreeSelections = [{ ...selection, branchPath: ['MTTK-RFRO'] }];
  await assert.rejects(f.workspaces.recommendExams(f.session, request), /Choose an available/);
  assert.equal(sent.length, 2, 'Invalid branch never reaches a provider');
  request.degreeSelections = []; request.interests = 'MTTK';
  await f.workspaces.recommendExams(f.session, request);
  assert.equal(sent[2].degreePlans, undefined);
});

async function fixture(t, complete, choose) {
  const root = await mkdtemp(join(tmpdir(), 'scholia-exam-advice-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const store = new AccountStore(root);
  await store.createUser('exams@example.com', 'local-test-password');
  const session = store.session((await store.login('exams@example.com', 'local-test-password')).value);
  const workspaces = new Workspaces(store, {}, { complete: withLookups(complete, choose) });
  const account = workspaces.account(session.user_id);
  account.library.examPlan = [{ id: 'one', courseCode: 'TDT4100', courseName: 'Programming', component: 'Final', kind: 'final', date: '2026-12-10', startTime: '09:00', endTime: '13:00', endDate: '', selected: false, source: 'manual' }];
  return { store, workspaces, account, session, request: { exams: structuredClone(account.library.examPlan), interests: 'Robotics' } };
}

test('hosted recommendations use the account model and interests without changing the saved selection', async (t) => {
  let payload;
  const f = await fixture(t, async (request) => { payload = request; return { text: recommendation }; });
  f.account.settings.modelID = 'fixture-model';
  const result = await f.workspaces.recommendExams(f.session, f.request);
  assert.deepEqual(result.selectedExamIDs, ['one']);
  assert.equal(payload.model, 'fixture-model');
  assert.match(payload.messages[0].content, /Robotics/);
  assert.equal(f.account.library.examPlan[0].selected, false);
  assert.equal(f.account.examRecommendationBusy, false);
  await f.store.createUser('other@example.com', 'local-test-password');
  const other = f.store.session((await f.store.login('other@example.com', 'local-test-password')).value);
  await assert.rejects(f.workspaces.recommendExams(other, f.request), /plan changed/);
});

test('malformed lookup plans get one repair attempt; no raw model response becomes advice', async t => {
  const f = await fixture(t, async () => ({ text: 'Unused' }));
  const stages = [];
  f.workspaces.options.complete = async payload => {
    const input = JSON.parse(payload.context); stages.push(input);
    if (stages.length === 1) return { text: '{"queries":[{"kind":"year","programmeCode":"MTTK","studyYear":1,"admissionYear":2024}]}' };
    if (input.degreeCatalogue) {
      assert.match(payload.messages[0].content, /previous lookup was rejected/);
      return { text: '{"queries":[{"kind":"courses","programmeCode":"MTTK","courseCodes":["TTK4100"]}]}' };
    }
    return { text: 'Repaired advice.' };
  };
  const result = await f.workspaces.recommendExams(f.session, { ...f.request, mode: 'advice', interests: 'TTK4100 for MTTK?' });
  assert.equal(result.advice, 'Repaired advice.');
  assert.equal(stages.length, 3);
  assert.equal(stages[2].degreePlans.results[0].data.planID, 'MTTK:2023');
  let invalidCalls = 0;
  f.workspaces.options.complete = async () => { invalidCalls++; return { text: 'Not a lookup plan' }; };
  await assert.rejects(f.workspaces.recommendExams(f.session, { ...f.request, mode: 'advice' }), /valid degree information/);
  assert.equal(invalidCalls, 2);
  assert.equal(f.account.examRecommendationBusy, false);
});

test('cancelling during lookup selection prevents the final advice call', async t => {
  const f = await fixture(t, async () => ({ text: 'Unused' }));
  let release, started, calls = 0;
  const ready = new Promise(resolve => { started = resolve; });
  f.workspaces.options.complete = async () => {
    calls++; started();
    return new Promise(resolve => { release = () => resolve({ text: '{"queries":[]}' }); });
  };
  const controller = new AbortController();
  const pending = f.workspaces.recommendExams(f.session, { ...f.request, mode: 'advice' }, controller.signal);
  await ready; controller.abort(); release();
  await assert.rejects(pending, { name: 'AbortError' });
  assert.equal(calls, 1);
  assert.equal(f.account.examRecommendationBusy, false);
});

test('hosted advice answers overlapping-exam questions without filtering options or changing the plan', async (t) => {
  let payload;
  const answer = '**Take TDT4100 over TMA4100** for your programming goal. Confirm the missing times before deciding.';
  const f = await fixture(t, async (request) => { payload = request; return { text: answer }; });
  f.account.library.examPlan.push({ ...f.account.library.examPlan[0], id: 'two', courseCode: 'TMA4100', courseName: 'Calculus', endTime: '' });
  f.request.exams = structuredClone(f.account.library.examPlan);
  f.request.mode = 'advice';
  f.request.interests = 'Which overlapping exam should I take? I want to focus on programming.';
  const before = structuredClone(f.account.library);
  assert.deepEqual(await f.workspaces.recommendExams(f.session, f.request), { advice: answer });
  const input = JSON.parse(payload.context);
  assert.equal(input.question, f.request.interests);
  assert.equal(input.courses.length, 2);
  assert.equal(input.overlaps[0].status, 'possible');
  assert.match(payload.messages[0].content, /recommend which one to take over the other/);
  assert.deepEqual(f.account.library, before);
  assert.equal(f.account.examRecommendationBusy, false);
  await assert.rejects(f.workspaces.recommendExams(f.session, { ...f.request, mode: 'unknown' }), /Choose/);
  f.account.library.examPlan = [];
  assert.deepEqual(await f.workspaces.recommendExams(f.session, { ...f.request, exams: [] }), { advice: answer });
  f.workspaces.options.complete = withLookups(async () => ({ text: '   ' }));
  await assert.rejects(f.workspaces.recommendExams(f.session, { ...f.request, exams: [] }), /readable exam advice/);
  assert.equal(f.account.examRecommendationBusy, false);
});

for (const mode of ['selection', 'advice']) test(`${mode}: a large plan and the student's specific request survive provider serialization`, async (t) => {
  const question = 'Should i take the exam for TTK4100 or TFY4330, which is for MTTK first year and MTNANO third year respectively for the best progression?';
  const f = await fixture(t, async (payload) => {
    assert.ok(payload.context.length > 12000, 'The fixture must exceed the chat-message limit');
    assert.ok(payload.messages[0].content.includes(question));
    const expected = JSON.parse(examRecommendationInput(f.request.exams, question, f.account.library.courses, mode));
    for (const provider of ['openai', 'anthropic', 'cohere', 'ollama', 'codex']) {
      const wire = buildProviderRequest({ ...payload, provider, model: undefined }, mergeSettings({
        provider, apiKeys: { [provider]: 'fixture-key' }, language: 'en',
      }));
      const body = JSON.parse(wire.fetchOptions.body);
      const content = body.messages.findLast((message) => message.role === 'user').content;
      assert.ok(content.includes(question), `${provider} must receive the exact question`);
      const context = content.split('<scholia-context>\n')[1].split('\n</scholia-context>')[0];
      const { degreePlans, ...examPlan } = JSON.parse(context);
      assert.deepEqual(examPlan, expected, `${provider} must receive complete, valid plan JSON`);
      if (mode === 'advice') {
        assert.equal(degreePlans.scope, 'retrieved-plans');
        assert.deepEqual(degreePlans.results.flatMap(({ data }) => data.matches.map(r => [data.courses[r.courseID].code, r.planID, r.studyYear])),
          [['TFY4330', 'MTNANO:2023', 3], ['TTK4100', 'MTTK:2023', 1]]);
      } else assert.equal(degreePlans, undefined);
      assert.ok(content.indexOf(question, content.indexOf('</scholia-context>')) > 0,
        'The student request is also explicit outside the reference data');
    }
    return { text: mode === 'advice' ? 'Compare TTK4100 and TFY4330 for your intended programme.'
      : JSON.stringify({ courseLimit: 1, rankedCourses: [{ courseKey: 'TTK4100', reason: 'Matches the stated goal.' }] }) };
  }, () => ({ queries: [{ kind: 'courses', programmeCode: 'MTNANO', courseCodes: ['TFY4330'] },
    { kind: 'courses', programmeCode: 'MTTK', courseCodes: ['TTK4100'] }] }));
  f.account.library.examPlan = Array.from({ length: 500 }, (_, index) => ({
    ...f.request.exams[0], id: `exam-${index}`, courseCode: index === 498 ? 'TFY4330' : index === 499 ? 'TTK4100' : `AAA${1000 + index}`,
    courseName: `Course ${index}`, selected: index % 2 === 0,
  }));
  f.request = { exams: structuredClone(f.account.library.examPlan), interests: question, mode };
  const before = structuredClone(f.account.library.examPlan);
  await f.workspaces.recommendExams(f.session, f.request);
  assert.deepEqual(f.account.library.examPlan, before);
});

test('follow-up requests keep the original question and complete answers beyond the chat text limit', async (t) => {
  const history = [{ role: 'user', content: 'Should I take TTK4100 or TFY4330 for progression?' },
    { role: 'assistant', content: 'Detailed comparison with preparation and goals. '.repeat(400) + 'END OF ORIGINAL ADVICE' }];
  let sent;
  const f = await fixture(t, async (payload) => {
    const wire = buildProviderRequest(payload, mergeSettings({ apiKeys: { [payload.provider]: 'fixture-key' }, language: 'en' }));
    sent = JSON.parse(wire.fetchOptions.body).messages.at(-1).content;
    return { text: 'For your follow-up, consider which programme you intend to continue.' };
  });
  const before = structuredClone(f.account.library.examPlan);
  const result = await f.workspaces.recommendExams(f.session, { ...f.request, interests: 'What if I focus on MTTK?', mode: 'advice', history });
  const context = JSON.parse(sent.split('<scholia-context>\n')[1].split('\n</scholia-context>')[0]);
  assert.deepEqual(context.conversation, history);
  assert.equal(context.question, 'What if I focus on MTTK?');
  assert.match(sent, /Continue the supplied conversation/);
  assert.match(result.advice, /follow-up/);
  assert.deepEqual(f.account.library.examPlan, before);
  await assert.rejects(f.workspaces.recommendExams(f.session, { ...f.request, history }), /only supported/);
});

for (const mode of ['selection', 'advice']) test(`${mode}: changed plans, overlapping requests, aborted responses and provider failures remain retryable`, async (t) => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const response = mode === 'advice' ? 'Prioritize programming for robotics.' : recommendation;
  const f = await fixture(t, async () => { await gate; return { text: response }; });
  f.request.mode = mode;
  const pending = f.workspaces.recommendExams(f.session, f.request);
  await assert.rejects(f.workspaces.recommendExams(f.session, f.request), /already running/);
  f.account.library.examPlan[0].date = '2026-12-11';
  release();
  await assert.rejects(pending, /changed/);
  assert.equal(f.account.examRecommendationBusy, false);
  f.request.exams = structuredClone(f.account.library.examPlan);
  const controller = new AbortController(); controller.abort();
  await assert.rejects(f.workspaces.recommendExams(f.session, f.request, controller.signal), { name: 'AbortError' });
  f.workspaces.options.complete = async () => { throw new Error('Fixture offline'); };
  await assert.rejects(f.workspaces.recommendExams(f.session, f.request), /Fixture offline/);
  assert.equal(f.account.examRecommendationBusy, false);
  f.workspaces.options.complete = withLookups(async () => ({ text: response }));
  const result = await f.workspaces.recommendExams(f.session, f.request);
  if (mode === 'advice') assert.equal(result.advice, response);
  else assert.deepEqual(result.selectedExamIDs, ['one']);
});
