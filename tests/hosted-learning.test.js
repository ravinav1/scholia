import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { createHostedServer } from '../apps/server/server.js';

function completion(payload) {
  const prompt = payload.messages[0].content;
  if (prompt.startsWith('Assess'))
    return {
      text: JSON.stringify({
        verdict: 'correct',
        correct: 'The causal reasoning is sound.',
        issue: '',
        nextStep: 'Apply the relationship to another situation.',
      }),
    };
  return {
    text: JSON.stringify({
      questions: [...prompt.matchAll(/^SOURCE (\d+):/gm)].map((m) => ({
        concept: `Concept ${m[1]}`,
        prompt: `Explain the cause in source ${m[1]}.`,
        referenceAnswer: 'The result follows from the mechanism described in the source.',
        rubric: ['Identifies cause and consequence'],
        hints: ['Recall the mechanism', 'Identify cause and effect', 'Start with the first cause'],
        sourceIndex: Number(m[1]),
        requiresVisual: false,
      })),
    }),
  };
}
test('hosted course practice saves answers, hides solutions, survives reload and isolates accounts', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'scholia-learning-'));
  const app = createHostedServer({
    root,
    origin: 'http://127.0.0.1:3000',
    complete: async (payload) => completion(payload),
  });
  t.after(async () => {
    await app.close();
    await rm(root, { recursive: true, force: true });
  });
  await app.store.createUser('practice@example.com', 'test-password-for-practice');
  const login = await app.store.login('practice@example.com', 'test-password-for-practice');
  const session = app.store.session(login.value),
    account = app.workspaces.account(session.user_id);
  await app.workspaces.action(session, { action: 'create', name: 'Bionano' });
  const course = account.library.courses[0];
  for (const name of ['Brownian motion', 'Electrostatics', 'Microfluidics'])
    await app.workspaces.importFile(
      account,
      course,
      `${name}.md`,
      Buffer.from(`${name} has a mechanism with consequences.`)
    );
  const state = await app.workspaces.state(session);
  await app.workspaces.learningAction(session, {
    action: 'practiceGenerate',
    owner: state.draftOwner,
    sourceScope: 'course',
    practiceStyle: 'exam',
    count: 3,
  });
  await account.job;
  const view = () => app.workspaces.learning.view(account, session.navigation);
  assert.equal(view().error, null);
  assert.equal(view().session.questionIDs.length, 3);
  assert.equal(view().question.referenceAnswer, undefined);
  assert.equal(view().question.source.excerpt, '');
  assert.equal(
    new Set(Object.values(account.learningState.questions).map((q) => q.source.documentID)).size,
    3
  );
  const command = (action, extra = {}) => ({
    id: randomUUID(),
    action,
    sessionID: view().session.id,
    questionID: view().question.id,
    expectedVersion: view().session.version,
    ...extra,
  });
  await assert.rejects(app.workspaces.learningAction(session, { action: 'practice', learning: command('reveal') }), /Save an attempt/);
  assert.equal(view().question.referenceAnswer, undefined);
  const attempt = command('attempt', { text: 'My independent explanation.', confidence: 3 });
  await app.workspaces.learningAction(session, { action: 'practice', learning: attempt });
  assert.equal(
    app.store.learning(account.id).attempts[0].answer,
    'My independent explanation.',
    'Answer committed before feedback'
  );
  await account.job;
  assert.equal(view().attempts[0].assessment.verdict, 'correct');
  assert.equal(
    view().coverage.materials.reduce((n, m) => n + m.independent, 0),
    1
  );
  await app.workspaces.learningAction(session, { action: 'practice', learning: attempt });
  assert.equal(view().attempts.length, 1, 'Offline retries are idempotent');
  await assert.rejects(
    app.workspaces.learningAction(session, {
      action: 'practice',
      learning: { ...attempt, text: 'Changed answer' },
    }),
    /Duplicate/
  );
  await assert.rejects(
    app.workspaces.learningAction(session, {
      action: 'practice',
      learning: command('next', { expectedVersion: 1 }),
    }),
    /changed in another window/
  );
  await app.workspaces.learningAction(session, {
    action: 'practice',
    learning: command('dispute', { attemptID: attempt.id, text: 'This grading is questionable' }),
  });
  assert.equal(
    view().coverage.materials.reduce((n, m) => n + m.independent, 0),
    0
  );
  await app.workspaces.learningAction(session, { action: 'practice', learning: command('reveal') });
  assert.match(view().question.referenceAnswer, /mechanism/);
  await app.workspaces.learningAction(session, {
    action: 'practice',
    learning: command('saveReview'),
  });
  assert.equal(view().reviews.length, 1);
  await app.workspaces.learningAction(session, { action: 'practice', learning: command('finish') });
  assert.equal(view().recap.length, 3);
  assert.equal(view().recap[1].referenceAnswer, undefined);
  await assert.rejects(app.workspaces.learningAction(session, {
    action: 'practice', learning: command('revealSaved', { questionID: view().recap[1].id })
  }), /Save an attempt/);
  account.learningState = undefined;
  assert.equal(view().attempts[0].answer, 'My independent explanation.');
  assert.match(view().attempts[0].dispute, /questionable/);
  const other = await app.store.createUser('other@example.com', 'another-password-for-test');
  assert.equal(
    app.workspaces.learning.view(app.workspaces.account(other.id), {}).sessions.length,
    0
  );
});
