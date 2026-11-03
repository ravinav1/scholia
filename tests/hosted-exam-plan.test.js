import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AccountStore } from '../apps/server/store.js';
import { Workspaces } from '../apps/server/workspaces.js';

test('exam plans persist per account, strip unrelated fields and reject stale or invalid saves atomically', async () => {
  const root = await mkdtemp(join(tmpdir(), 'scholia-exam-test-'));
  const store = new AccountStore(root);
  try {
    const workspaces = new Workspaces(store, {});
    await store.createUser('exams@example.com', 'correct horse battery staple');
    await store.createUser('other@example.com', 'correct horse battery staple');
    const alice = store.session(
      (await store.login('exams@example.com', 'correct horse battery staple')).value
    );
    const bob = store.session(
      (await store.login('other@example.com', 'correct horse battery staple')).value
    );
    const account = workspaces.account(alice.user_id);
    account.library.courses = [
      { id: 'programming', code: 'TDT4100-26H', name: 'Programming', documents: [], threads: [] },
      { id: 'pinned', code: 'PIN1000', name: 'Pinned', favorite: true, documents: [], threads: [] },
    ];
    const exam = {
      id: 'one',
      courseCode: 'TDT4100',
      courseName: 'Programming',
      component: 'Final exam',
      kind: 'final',
      date: '2026-12-10',
      startTime: '09:00',
      endTime: '13:00',
      selected: true,
      flexible: true,
      source: 'studentweb',
      password: 'never-store-this',
      rawText: 'never-store-this',
    };
    const saved = await workspaces.action(alice, {
      action: 'examPlan',
      exams: [exam],
      baseExams: [],
    });
    assert.equal(saved.library.examPlan.length, 1);
    assert.equal(account.library.courses[0].favorite, true);
    assert.equal(account.library.courses[0].examFavorite, true);
    assert.equal(saved.library.examPlan[0].selected, true);
    assert.equal(saved.library.examPlan[0].flexible, true);
    assert.equal(JSON.stringify(store.account(alice.user_id)).includes('never-store-this'), false);
    assert.equal((await workspaces.state(bob)).library.examPlan, undefined);
    await assert.rejects(
      workspaces.action(alice, { action: 'examPlan', exams: [], baseExams: [] }),
      { status: 409 }
    );
    const baseline = saved.library.examPlan;
    for (const exams of [
      [{ ...exam, date: '2026-02-30' }],
      [{ ...exam, endTime: '08:00' }],
      [{ ...exam, selected: 'yes' }],
      [{ ...exam, flexible: 'yes' }],
      [exam, exam],
      null,
    ]) {
      await assert.rejects(
        workspaces.action(alice, { action: 'examPlan', exams, baseExams: baseline }),
        { status: 400 }
      );
      assert.deepEqual(store.account(alice.user_id).library.examPlan, baseline);
    }
    await assert.rejects(workspaces.action(alice, { action: 'examPlan', exams: [] }), {
      status: 400,
    });
    assert.deepEqual((await new Workspaces(store, {}).state(alice)).library.examPlan, baseline);
    await workspaces.action(alice, { action: 'examPlan', exams: [], baseExams: baseline });
    assert.deepEqual(store.account(alice.user_id).library.examPlan, []);
    assert.equal(
      account.library.courses[0].favorite,
      false,
      'Automatic favorites follow plan changes'
    );
    assert.equal(account.library.courses[1].favorite, true, 'Personal favorites are preserved');
  } finally {
    store.db.close();
    await rm(root, { recursive: true, force: true });
  }
});
