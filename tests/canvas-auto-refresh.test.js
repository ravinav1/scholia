import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AccountStore } from '../apps/server/store.js';
import { Workspaces } from '../apps/server/workspaces.js';
import { Canvas } from '../apps/server/canvas.js';
import { assignmentAgendaMarkup } from '../apps/web/assignments.js';
import { Documents } from '../apps/server/documents.js';
import { trainedPollingModel } from './helpers/content-polling.js';

test('predicted Canvas checks download changed content and honor opt-out, budgets and backoff', async () => {
  const root = await mkdtemp(join(tmpdir(), 'scholia-content-prediction-')), store = new AccountStore(root);
  const workspaces = new Workspaces(store, new Documents(root));
  try {
    const user = await store.createUser('predict@example.com', 'correct horse battery staple');
    const account = workspaces.account(user.id), { model, time } = trainedPollingModel();
    account.library.canvasOrigin = 'https://canvas.example'; account.library.canvasUserID = 42;
    const course = { id: 'course', name: 'Notes', code: 'TMA4100-26H', canvasID: 1, canvasOrigin: account.library.canvasOrigin,
      canvasUserID: 42, term: '2026 HØST', documents: [], threads: [], canvasMaterials: [],
      canvasPolling: model, contentUpdateAttemptedAt: time };
    account.library.courses = [course];
    let catalogs = 0, downloads = 0, failure = false;
    const includePublic = [];
    workspaces.canvas = () => ({ origin: course.canvasOrigin,
      catalog: async (_, options) => {
        catalogs++; includePublic.push(options.includePublic);
        if (failure) throw new Error('Offline');
        return { items: [{ id: 'files:1', kind: 'files', title: 'Notes', version: 'v2', fileName: 'notes.txt', sourceURL: course.canvasOrigin + '/files/1' }],
          warnings: [], changes: { added: ['files:1'], updated: [], removed: [] }, canvasComplete: true, mathWikiComplete: true };
      },
      material: async ref => { downloads++; return { reference: ref, name: 'notes.txt', data: Buffer.from('New teaching material') }; },
    });
    await workspaces.refreshCanvasContent(account, course.id, (time + 150) * 1000);
    assert.equal(catalogs, 0, 'Opt-in is required for automatic Canvas content');
    account.settings.automaticallyUpdateCanvasContent = true;
    const first = workspaces.refreshCanvasContent(account, course.id, (time + 150) * 1000);
    assert.equal(first, workspaces.refreshCanvasContent(account, course.id, (time + 150) * 1000));
    await first;
    assert.equal(downloads, 1);
    assert.equal(course.documents[0].sourceVersion, 'v2');
    assert.deepEqual(includePublic, [false], 'An extra Canvas check must not also crawl public sites');
    assert.equal(course.contentUpdateAttemptedAt, time);
    assert.equal(store.account(user.id).library.courses[0].canvasPolling.extraChecks.length, 1);
    await workspaces.refreshCanvasContent(account, course.id, (time + 300) * 1000);
    assert.deepEqual(includePublic, [false, true]);
    assert.equal(downloads, 1, 'Unchanged originals are reused');
    failure = true;
    await workspaces.refreshCanvasContent(account, course.id, (time + 600) * 1000);
    await workspaces.refreshCanvasContent(account, course.id, (time + 900) * 1000);
    const calls = catalogs;
    await workspaces.refreshCanvasContent(account, course.id, (time + 1200) * 1000);
    assert.equal(catalogs, calls, 'A second failure doubles the retry delay');
    assert.equal(course.documents.length, 1);
    assert.equal(course.canvasPolling.failures, 2);
    await workspaces.refreshCanvasContent(account, course.id, (time + 1500) * 1000);
    assert.equal(catalogs, calls + 1);
  } finally {
    await workspaces.stop(); store.db.close(); await rm(root, { recursive: true, force: true });
  }
});

test('automatic Canvas checks refresh submissions and grades without downloading files, throttle repeats and preserve failed data', async () => {
  const root = await mkdtemp(join(tmpdir(), 'scholia-refresh-'));
  const store = new AccountStore(root);
  const workspaces = new Workspaces(store, {});
  try {
    const user = await store.createUser('refresh@example.com', 'correct horse battery staple');
    const account = workspaces.account(user.id);
    account.library.canvasOrigin = 'https://canvas.example';
    account.library.canvasUserID = 42;
    const course = {
      id: 'one',
      canvasID: 1,
      canvasUserID: 42,
      canvasOrigin: account.library.canvasOrigin,
      code: 'TMA4100-26H',
      favorite: true,
      name: 'Calculus',
      documents: [{ id: 'local', sourceVersion: 'unchanged' }],
      canvasMaterials: [],
    };
    account.library.courses = [course];
    let calls = 0,
      submission = { workflow_state: 'unsubmitted' },
      fail = false,
      unblock;
    const canvas = new Canvas(account.library.canvasOrigin, 'fixture', {
      hosts: ['canvas.example'],
    });
    canvas.list = async (path) => {
      calls++;
      assert.equal(path, '/api/v1/courses/1/assignments?include[]=submission');
      if (fail) throw new Error('Offline');
      if (unblock) await unblock;
      return [
        {
          id: 7,
          name: 'Problem set',
          updated_at: 'unchanged',
          submission_types: ['online_upload'],
          due_at: '2026-10-10T10:00:00Z',
          points_possible: 10,
          grading_type: 'points',
          submission,
        },
      ];
    };
    workspaces.canvas = () => canvas;
    const start = Date.now();
    await workspaces.refreshCanvasAssignments(account, start);
    const ref = course.canvasMaterials[0];
    ref.moduleID = 123;
    assert.equal(ref.assignment.status, 'notSubmitted');
    const version = ref.version;
    submission = { workflow_state: 'submitted', submitted_at: '2026-09-28T10:00:00Z' };
    await workspaces.refreshCanvasAssignments(account, start + 119_999);
    assert.equal(calls, 1);
    let release;
    unblock = new Promise((resolve) => {
      release = resolve;
    });
    const first = workspaces.refreshCanvasAssignments(account, start + 120_000);
    const second = workspaces.refreshCanvasAssignments(account, start + 120_000);
    account.settings.automaticallyUpdateCanvasContent = true;
    workspaces.options.remoteRequest = () => assert.fail('Automatic content must wait for deadline refresh');
    await workspaces.refreshMathWiki(account, course.id, start + 120_000);
    await workspaces.refreshCanvasContent(account, course.id, start + 120_000);
    assert.ok(!account.busy && !account.mathWikiRefresh && !account.contentRefresh,
      'Automatic wiki and file checks must not interrupt the deadline refresh midway through the library');
    release();
    await Promise.all([first, second]);
    assert.equal(calls, 2, 'Multiple open tabs share the refresh');
    assert.equal(ref.assignment.status, 'submitted');
    assert.equal(ref.moduleID, 123);
    assert.equal(ref.version, version);
    assert.equal(course.documents[0].sourceVersion, 'unchanged');
    assert.match(assignmentAgendaMarkup([course], { filter: 'handedIn' }), /Handed in/);
    submission = {
      workflow_state: 'graded',
      grade: '9',
      score: 9,
      posted_at: '2026-09-28T12:00:00Z',
    };
    await workspaces.refreshCanvasAssignments(account, start + 240_000);
    assert.equal(ref.assignment.score, 9);
    assert.equal(ref.assignment.status, 'graded');
    const checked = account.library.canvasAssignmentsCheckedAt;
    fail = true;
    await workspaces.refreshCanvasAssignments(account, start + 360_000);
    assert.equal(ref.assignment.status, 'graded');
    assert.equal(account.library.canvasAssignmentsCheckedAt, checked);
    assert.match(account.library.canvasAssignmentsError, /Retrying/);
    fail = false;
    await workspaces.refreshCanvasAssignments(account, start + 480_000);
    assert.equal(account.library.canvasAssignmentsError, null);
    assert.equal(store.account(user.id).library.courses[0].canvasMaterials[0].assignment.score, 9);
    account.busy = true;
    const before = calls;
    await workspaces.refreshCanvasAssignments(account, start + 600_000);
    assert.equal(calls, before, 'Manual sync and automatic refresh do not compete');
    account.busy = false;
    submission = { workflow_state: 'submitted', submitted_at: '2026-09-28T13:00:00Z' };
    await workspaces.refreshCanvasAssignments(account, start + 480_001, true);
    assert.equal(calls, before + 1, 'Manual status refresh bypasses the automatic interval');
    assert.equal(ref.assignment.status, 'submitted');
  } finally {
    await workspaces.stop();
    store.db.close();
    await rm(root, { recursive: true, force: true });
  }
});
