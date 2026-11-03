import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHostedServer } from '../apps/server/server.js';

async function fixture(t, complete) {
  const root = await mkdtemp(join(tmpdir(), 'scholia-course-chat-'));
  const requests = [];
  const app = createHostedServer({
    root,
    origin: 'http://127.0.0.1:3000',
    complete: async (payload, ...rest) => {
      requests.push(payload);
      if (complete) return complete(payload, ...rest);
      return { text: 'A grounded course answer.' };
    },
  });
  t.after(async () => {
    await app.close();
    await rm(root, { recursive: true, force: true });
  });
  const user = await app.store.createUser('course@example.com', 'isolated-course-test');
  const login = await app.store.login('course@example.com', 'isolated-course-test');
  const session = app.store.session(login.value);
  const account = app.workspaces.account(user.id);
  const action = async (command) => {
    const state = await app.workspaces.state(session);
    return app.workspaces.action(session, { owner: state.draftOwner, ...command });
  };
  await action({ action: 'create', name: 'Geometric computing', code: 'MATH204' });
  const course = account.library.courses[0];
  course.term = 'Autumn 2026';
  return { ...app, session, account, course, action, requests };
}

test('General mode reaches the provider and stays with its conversation', async (t) => {
  const app = await fixture(t);
  await app.action({ action: 'draft', text: 'Help me brainstorm a weekend project.', mode: 'General' });
  assert.equal(app.course.threads[0].mode, 'General');
  await app.action({ action: 'send', text: 'Help me brainstorm a weekend project.', mode: 'General' });
  await app.account.job;
  assert.equal(app.requests[0].learningMode, 'General');
  const doc = await app.workspaces.importFile(app.account, app.course, 'Reading.md', Buffer.from('Course reading'));
  await app.action({ action: 'document', id: doc.id });
  assert.equal((await app.workspaces.state(app.session)).mode, 'Explain');
  await app.action({ action: 'course', id: app.course.id });
  assert.equal((await app.workspaces.state(app.session)).mode, 'General');
});

test('reading context defaults to the open document and preserves explicit additional-course choices', async (t) => {
  const app = await fixture(t);
  const reading = await app.workspaces.importFile(app.account, app.course, 'Compendium.txt', Buffer.from('READING_SIGNAL: controller phase margin.'));
  const other = await app.workspaces.importFile(app.account, app.course, 'Other course notes.txt', Buffer.from('OTHER_SIGNAL: controller phase margin.'));
  app.course.aiMemory = { notes: 'COURSE_MEMORY_SIGNAL', documentIDs: [other.id] };
  await app.action({ action: 'document', id: reading.id });
  assert.equal((await app.workspaces.state(app.session)).contextScope, 'document');
  assert.equal((await app.workspaces.state(app.session)).includeCourse, false);
  const ask = async () => {
    await app.action({ action: 'send', text: 'Explain controller phase margin.' });
    await app.account.job;
    assert.equal(app.account.error, null);
    return app.requests.at(-1).context;
  };
  const initial = await ask();
  assert.match(initial, /READING_SIGNAL/);
  assert.doesNotMatch(initial, /OTHER_SIGNAL|COURSE_MEMORY_SIGNAL/);

  await app.action({ action: 'context', enabled: true });
  await app.action({ action: 'askCourse' });
  await app.action({ action: 'document', id: reading.id });
  assert.equal((await app.workspaces.state(app.session)).includeCourse, true);
  const expanded = await ask();
  assert.match(expanded, /READING_SIGNAL/);
  assert.match(expanded, /OTHER_SIGNAL/);
  assert.match(expanded, /COURSE_MEMORY_SIGNAL/);

  await app.action({ action: 'context', enabled: false });
  await app.action({ action: 'askCourse' });
  const resumed = await app.action({ action: 'resume', id: reading.id });
  assert.equal(resumed.contextScope, 'document');
  assert.equal(resumed.includeCourse, false);
  assert.doesNotMatch(await ask(), /OTHER_SIGNAL|COURSE_MEMORY_SIGNAL/);

  app.session.navigation.includeCourse = null;
  app.store.navigate(app.session);
  assert.equal((await app.workspaces.state(app.session)).includeCourse, false);
  assert.doesNotMatch(await ask(), /OTHER_SIGNAL|COURSE_MEMORY_SIGNAL/);
});

test('project files survive draft, send, history and edit while context off excludes automatic sources', async (t) => {
  const app = await fixture(t);
  const doc = await app.workspaces.importFile(app.account, app.course, 'Compendium.txt', Buffer.from('AUTOMATIC_COMPENDIUM_EVIDENCE'));
  await app.action({ action: 'document', id: doc.id });
  const files = [
    { name: 'controller.slx', text: '<Block Name="Gain"><P Name="Gain">Kp</P></Block>', status: 'partial', notice: 'Model source only. Workspace variable Kp is unresolved.' },
    { name: 'measurements.mat', text: '', status: 'unavailable', notice: 'Binary data requires a readable export.' },
    { name: 'excluded.txt', text: 'DO_NOT_SEND_THIS_FILE', enabled: false },
  ];
  const before = (await app.workspaces.state(app.session)).draftOwner;
  const draft = await app.action({ action: 'draft', text: '', files });
  assert.equal(draft.canSend, true);
  assert.equal(draft.draftFiles.length, 3);
  assert.notDeepEqual(draft.draftOwner, before);
  await app.action({ action: 'automaticContext', enabled: false });
  assert.equal((await app.workspaces.state(app.session)).automaticContextEnabled, false);
  await app.action({ action: 'send', text: '', files });
  await app.account.job;
  assert.equal(app.account.error, null);
  assert.equal(app.requests.at(-1).context, '');
  assert.equal(app.requests.at(-1).pageTitle, '');
  const sent = app.requests.at(-1).messages[0];
  assert.deepEqual(sent.files.map((file) => file.name), ['controller.slx', 'measurements.mat']);
  assert.equal(sent.files[1].status, 'unavailable');
  assert.doesNotMatch(JSON.stringify(app.requests.at(-1)), /DO_NOT_SEND_THIS_FILE|AUTOMATIC_COMPENDIUM_EVIDENCE/);
  const state = await app.workspaces.state(app.session);
  assert.deepEqual(state.draftFiles, []);
  await app.action({ action: 'edit', id: state.messages[0].id });
  assert.equal((await app.workspaces.state(app.session)).draftFiles[1].name, 'measurements.mat');
});

test('large chat attachments retain complete text outside state and retrieve late evidence after followup and edit', async (t) => {
  const app = await fixture(t);
  const text = `${'Routine model notes.\n'.repeat(18_000)}\nAURORA_PARAMETER: tailgain = 72.5.\n${'Other material.\n'.repeat(8000)}FINAL_PROJECT_SECTION`;
  const draft = await app.action({ action: 'draft', text: 'What is tailgain?', files: [{ id: 'exact-file', name: 'actual-model.m', text }] });
  const saved = draft.draftFiles[0];
  assert.equal(saved.text.length, 16_000);
  assert.equal(saved.textCorpusUTF16Count, text.length);
  assert.match(saved.textCorpusID, /^[a-f0-9]{64}$/);
  assert.equal(saved.truncated, false);
  assert.equal(saved.status, 'readable');
  assert.equal((await app.workspaces.attachmentCorpus.fullText(app.account.id, saved)).text, text);
  assert.ok(JSON.stringify(app.store.account(app.account.id)).length < 25_000);
  await app.action({ action: 'send', text: 'What is tailgain?', files: [saved] });
  await app.account.job;
  assert.equal(app.account.error, null);
  const sent = app.requests.at(-1).messages[0].files[0];
  assert.match(sent.text, /tailgain = 72\.5/);
  assert.match(sent.contextCoverage, /Searched the full saved text/);
  assert.ok(sent.text.length <= 24_000);
  assert.equal(sent.id, 'exact-file');
  await app.action({ action: 'send', text: 'Why?' });
  await app.account.job;
  assert.match(app.requests.at(-1).messages[0].files[0].text, /tailgain = 72\.5/);
  const state = await app.workspaces.state(app.session);
  assert.equal(state.messages[0].files[0].text.length, 16_000);
  assert.ok(state.messages.at(-1).activity.some((event) => event.title === 'Read attached file' && /saved characters/.test(event.detail)));
  const editing = await app.action({ action: 'edit', id: state.messages[0].id });
  assert.equal(editing.draftFiles[0].textCorpusID, saved.textCorpusID);
  await app.action({ action: 'send', text: 'Explain tailgain.', files: editing.draftFiles });
  await app.account.job;
  assert.match(app.requests.at(-1).messages[0].files[0].text, /tailgain = 72\.5/);
  await assert.rejects(app.action({ action: 'draft', files: [{ ...saved, id: 'forged-reference' }] }), /current conversation/);
});

test('response language persists as the default across chats and reaches each request', async (t) => {
  const app = await fixture(t);
  assert.equal((await app.workspaces.state(app.session)).language, 'auto');
  await app.action({ action: 'language', text: 'no' });
  assert.equal(app.store.account(app.account.id).settings.language, 'no');
  await app.action({ action: 'send', text: 'Explain vectors.' });
  await app.account.job;
  assert.equal(app.requests.at(-1).language, 'no');
  await app.action({ action: 'newThread' });
  assert.equal((await app.workspaces.state(app.session)).language, 'no');
  await app.action({ action: 'language', text: 'auto' });
  await app.action({ action: 'send', text: 'Kan du forklare vektorer?' });
  await app.account.job;
  assert.equal(app.requests.at(-1).language, 'auto');
  await assert.rejects(app.action({ action: 'language', text: 'invalid' }), /Unknown response language/);
  assert.equal(app.store.account(app.account.id).settings.language, 'auto');
});

test('entire PDF sends all indexed pages, persists for follow-ups, and fails without a partial request', async (t) => {
  const app = await fixture(t);
  const text = Array.from({ length: 30 }, (_, i) => `Section ${i + 1}. ${'Evidence throughout the document. '.repeat(350)} Conclusion ${i + 1}.`).join('\n\n');
  const doc = await app.workspaces.importFile(app.account, app.course, 'Long reading.txt', Buffer.from(text));
  // Exercise the PDF request path against a real stored multi-page index.
  doc.kind = 'pdf';
  await app.action({ action: 'document', id: doc.id });
  await app.action({ action: 'send', text: 'Explain the entire PDF.', entirePDF: true });
  await app.account.job;
  assert.equal(app.account.error, null);
  assert.equal(app.requests.at(-1).entirePDF, true);
  assert.ok(app.requests.at(-1).context.length > 140_000);
  assert.match(app.requests.at(-1).context, /Conclusion 30/);
  assert.equal((await app.workspaces.state(app.session)).entirePDF, true);
  await app.action({ action: 'send', text: 'How does the ending relate to the introduction?' });
  await app.account.job;
  assert.match(app.requests.at(-1).context, /Conclusion 30/);
  await app.action({ action: 'newThread' });
  assert.equal((await app.workspaces.state(app.session)).entirePDF, false);
  const count = app.requests.length;
  doc.pageCount += 1;
  await app.action({ action: 'send', text: 'Explain the entire PDF.', entirePDF: true });
  await app.account.job;
  assert.equal(app.requests.length, count);
  assert.match(app.account.error, /could not be read/);
});

test('whole document mode includes all indexed text for code and text readings', async (t) => {
  const app = await fixture(t);
  const text = Array.from({ length: 12 }, (_, i) => `Section ${i + 1}. ${'Evidence across the complete reading. '.repeat(350)} Ending ${i + 1}.`).join('\n\n');
  const doc = await app.workspaces.importFile(app.account, app.course, 'Project notes.txt', Buffer.from(text));
  await app.action({ action: 'document', id: doc.id });
  await app.action({ action: 'send', text: 'Explain the whole document.', selection: 'Explicit selected passage', entirePDF: true });
  await app.account.job;
  assert.equal(app.account.error, null);
  assert.equal(app.requests.at(-1).entireDocument, true);
  assert.equal(app.requests.at(-1).selection, 'Explicit selected passage');
  assert.match(app.requests.at(-1).context, /Whole document:/);
  assert.match(app.requests.at(-1).context, /Ending 12/);
  assert.equal((await app.workspaces.state(app.session)).entirePDF, true);
});

test('project context keeps instructions and retrieves parameter evidence deep in an included file', async (t) => {
  const app = await fixture(t);
  const assignment = { id: 'assignments:project', title: 'Course project', assignment: { linkedFileIDs: ['17'] } };
  const instructions = await app.workspaces.importFile(app.account, app.course, 'Instructions.txt', Buffer.from('PROJECT_REQUIREMENT: compare controller gains.'));
  instructions.sourceKey = assignment.id;
  const model = await app.workspaces.importFile(app.account, app.course, 'model.m', Buffer.from('Model placeholder.'));
  model.sourceKey = 'files:17';
  const original = app.documents.index.bind(app.documents);
  app.documents.index = (accountID, item) => item.id === model.id ? Promise.resolve({ pages: [
    { number: 1, text: 'Model introduction.' },
    { number: 127, text: `${'Routine derivation. '.repeat(5000)}\nKp = 7.25 is the controller value.\n${'Other material. '.repeat(2000)}` },
  ] }) : original(accountID, item);
  model.pageCount = 127;
  const packed = await app.workspaces.assignmentContext(app.account, app.course, assignment, 'What is Kp?', model, 1);
  assert.match(packed.context, /PROJECT_REQUIREMENT/);
  assert.match(packed.context, /Kp = 7.25 is the controller value/);
  assert.ok(packed.sources.some((source) => source.documentID === model.id && source.page === 127));
});

test('chat reports generation phases and elapsed start, then saves streamed text', async (t) => {
  let release, begun;
  const started = new Promise((resolve) => { begun = resolve; });
  const gate = new Promise((resolve) => { release = resolve; });
  let token, reasoning;
  const app = await fixture(t, async (_payload, _settings, onToken, _signal, onReasoning) => {
    token = onToken; reasoning = onReasoning; begun(); await gate;
    return { text: 'A streamed answer.' };
  });
  await app.action({ action: 'send', text: 'Describe this course.' });
  await started;
  let state = await app.workspaces.state(app.session);
  const reply = () => app.course.threads[0].messages.at(-1);
  assert.match(reply().metadata, /Waiting for/);
  assert.ok(state.answerStartedAt > 0);
  reasoning('private reasoning delta');
  assert.equal(reply().metadata, 'Model is reasoning…');
  assert.doesNotMatch(reply().metadata, /private reasoning/);
  token('A streamed answer.');
  assert.equal(reply().metadata, 'Writing answer…');
  release(); await app.account.job;
  state = await app.workspaces.state(app.session);
  assert.equal(reply().isStreaming, false);
  assert.equal(reply().content, 'A streamed answer.');
  assert.equal(state.answerStartedAt, null);
});

test('empty model responses fail visibly and leave chat ready to retry', async (t) => {
  const app = await fixture(t, async () => ({ text: '' }));
  await app.action({ action: 'send', text: 'Describe this course.' });
  await app.account.job;
  assert.match(app.account.error, /empty response/);
  assert.equal(app.account.streaming, false);
  assert.equal(app.course.threads[0].messages.at(-1).isStreaming, false);
});

test('a selected passage can be sent without a comment and retains its document context', async (t) => {
  const app = await fixture(t);
  const doc = await app.workspaces.importFile(app.account, app.course, 'Orbitals.md', Buffer.from('The ground state has the lowest energy.'));
  await app.action({ action: 'document', id: doc.id });
  const draft = await app.action({ action: 'draft', text: '', selection: 'ground state' });
  assert.equal(draft.canSend, true);
  await app.action({ action: 'send', text: '', selection: 'ground state' });
  await app.account.job;
  assert.equal(app.account.error, null);
  assert.match(app.requests[0].context, /lowest energy/);
  const thread = app.course.threads.find((thread) => thread.documentID === doc.id);
  assert.match(thread.messages[0].content, /Explain this passage[\s\S]*> ground state/);
  assert.equal(thread.messages.at(-1).content, 'A grounded course answer.');
});

test('course chat uses catalog information without a document and preserves scope, drafts and course isolation', async (t) => {
  const app = await fixture(t);
  const { action, course, account } = app;
  course.canvasMaterials.push(
    { id: 'files:1', title: 'Course syllabus', kind: 'files' },
    {
      id: 'assignments:1',
      title: 'Capstone project',
      kind: 'assignments',
      assignment: { dueAt: '2026-10-02T12:00:00+02:00', status: 'notSubmitted' },
    }
  );
  await action({ action: 'askCourse' });
  await action({ action: 'context', enabled: false });
  await action({ action: 'send', text: 'When is the capstone project due?' });
  await account.job;
  assert.equal(account.error, null);
  assert.match(app.requests[0].context, /MATH204[\s\S]*Autumn 2026/);
  assert.match(app.requests[0].context, /Capstone project \| due: 2026-10-02T12:00:00\+02:00/);
  assert.match(app.requests[0].context, /Course syllabus \| remote only; contents unavailable/);
  assert.match(app.requests[0].context, /Reading contents were not loaded/);
  const courseThread = (await action({ action: 'draft', text: 'My course draft' })).library
    .selectedThreadID;
  const doc = await app.workspaces.importFile(
    account,
    course,
    'Vectors.md',
    Buffer.from('Vectors combine through linear maps.')
  );
  await action({ action: 'document', id: doc.id });
  const reading = await action({ action: 'draft', text: 'My reading draft' });
  const back = await action({ action: 'askCourse' });
  assert.equal(back.draft, 'My course draft');
  assert.equal(back.library.selectedThreadID, courseThread);
  assert.equal(back.contextScope, 'course');
  assert.equal(
    course.threads.find((thread) => thread.id === reading.library.selectedThreadID).draft,
    'My reading draft'
  );
  const citation = await action({ action: 'source', id: doc.id, page: 1 });
  assert.equal(citation.contextScope, 'course');
  assert.equal(citation.includeCourse, true);
  await action({ action: 'send', text: 'How do these topics connect?' });
  await account.job;
  assert.match(app.requests[1].context, /Vectors combine through linear maps/);
  assert.equal(app.requests[1].pageTitle, course.name);
  const newThread = await action({ action: 'newThread' });
  assert.equal(newThread.contextScope, 'course');
  await action({ action: 'create', name: 'Separate course', code: 'PRIVATE' });
  await action({ action: 'send', text: 'What do we know about this course?' });
  await account.job;
  assert.doesNotMatch(app.requests[2].context, /Vectors|Capstone|MATH204/);
  assert.match(app.requests[2].context, /PRIVATE/);
});

test('reasoning selection survives reopening, reaches completion, and rejects unsupported or stale model choices', async (t) => {
  const app = await fixture(t);
  const { action, account, course } = app;
  const model = { id: 'gpt-6-astra', providerID: 'openai' };
  let state = await action({ action: 'model', ...model });
  assert.equal(state.reasoningEffort, 'medium');
  assert.ok(
    state.models
      .find((entry) => entry.id === model.id && entry.providerID === model.providerID)
      .reasoningEfforts.includes('high')
  );
  state = await action({ action: 'reasoning', ...model, text: 'high' });
  assert.equal(state.reasoningEffort, 'high');
  assert.equal(app.store.account(account.id).settings.reasoningEfforts.openai, 'high');
  await action({ action: 'send', text: 'Describe this course.' });
  await account.job;
  assert.equal(app.requests[0].reasoningEffort, 'high');
  assert.equal(course.threads[0].messages.at(-1).content, 'A grounded course answer.');
  await assert.rejects(action({ action: 'reasoning', ...model, text: 'invented' }), /unavailable/);
  state = await action({ action: 'model', id: 'claude-sonnet-4-6', providerID: 'anthropic' });
  assert.equal(state.reasoningEffort, null);
  await assert.rejects(action({ action: 'reasoning', ...model, text: 'low' }), /model changed/);
  await assert.rejects(
    action({ action: 'reasoning', id: 'claude-sonnet-4-6', providerID: 'anthropic', text: 'high' }),
    /unavailable/
  );
  state = await action({ action: 'model', ...model });
  assert.equal(state.reasoningEffort, 'high');
});

test('study model mode persists, routes each turn and preserves the manual selection', async (t) => {
  const app = await fixture(t);
  const { action, account, course } = app;
  await action({ action: 'model', providerID: 'openai', id: 'gpt-5-mini' });
  let state = await action({ action: 'studyModelMode', text: 'auto' });
  assert.equal(state.studyModelMode, 'auto');
  assert.equal(app.store.account(account.id).settings.studyModelMode, 'auto');
  for (const [question, model, effort] of [
    ['Define a vector', 'gpt-6-luna', 'low'],
    ['Solve this system of equations', 'gpt-6.1-sol', 'medium'],
    ['Prove this theorem', 'gpt-6-astra', 'high'],
    ['Why does that follow?', 'gpt-6-astra', 'high'],
    ['Summarize this lecture', 'gpt-6-luna', 'low'],
  ]) {
    await action({ action: 'send', text: question });
    await account.job;
    assert.equal(account.error, null);
    assert.equal(app.requests.at(-1).model, model);
    assert.equal(app.requests.at(-1).reasoningEffort, effort);
    const reply = course.threads[0].messages.at(-1);
    assert.equal(reply.modelRouting.modelID, model);
    assert.ok(reply.activity.some((event) => event.title === 'Study model selected' && event.detail.includes(model)));
  }
  state = await app.workspaces.state(app.session);
  assert.equal(state.modelID, 'gpt-5-mini');
  assert.equal(state.providerID, 'openai');
  await assert.rejects(action({ action: 'studyModelMode', text: 'invented' }), /Unknown study model mode/);
  await action({ action: 'studyModelMode', text: 'manual' });
  await action({ action: 'send', text: 'Prove this theorem' });
  await account.job;
  assert.equal(app.requests.at(-1).model, 'gpt-5-mini');
  assert.equal(course.threads[0].messages.at(-1).modelRouting, undefined);
});

test('workspace memory and reference files survive new chats, assignment changes and account reload', async (t) => {
  const app = await fixture(t);
  const file = await app.workspaces.importFile(app.account, app.course, 'Motor.txt', Buffer.from('Pinned motor torque constant: 0.042 Nm/A.'));
  app.course.canvasMaterials.push(...['a', 'b'].map((id) => ({ id, kind: 'assignments', title: id, remoteID: id, version: '1' })));
  await app.action({ action: 'workspaceMemory', courseID: app.course.id, text: 'Prefer SI notation', documentIDs: [] });
  await app.action({ action: 'workspaceMemory', courseID: app.course.id, assignmentID: 'a', text: 'Remember motor project', documentIDs: [file.id] });
  await app.action({ action: 'newThread' });
  const thread = app.course.threads.at(-1);
  thread.assignmentID = 'a';
  await app.action({ action: 'thread', id: thread.id });
  await app.action({ action: 'context', enabled: false });
  await app.action({ action: 'send', text: 'What do we know?', mode: 'General' });
  await app.account.job;
  assert.match(app.requests.at(-1).context, /Remember motor project/);
  assert.match(app.requests.at(-1).context, /0.042 Nm\/A/);
  await app.action({ action: 'newThread' });
  const next = app.course.threads.at(-1);
  next.assignmentID = 'b';
  await app.action({ action: 'thread', id: next.id });
  await app.action({ action: 'send', text: 'What do we know?', mode: 'General' });
  await app.account.job;
  assert.match(app.requests.at(-1).context, /Prefer SI notation/);
  assert.doesNotMatch(app.requests.at(-1).context, /Remember motor project|0.042 Nm\/A/);
  assert.deepEqual(app.store.account(app.account.id).library.courses[0].assignmentMemories.a.documentIDs, [file.id]);
  await assert.rejects(app.action({ action: 'workspaceMemory', courseID: 'foreign', text: '', documentIDs: [] }), /not found/);
});
