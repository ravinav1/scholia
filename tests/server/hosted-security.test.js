import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AccountStore } from '../../apps/server/store.js';
import { Workspaces } from '../../apps/server/workspaces.js';
import { Canvas } from '../../apps/server/courses/canvas.js';

async function fixture(t, options = {}) {
  const root = await mkdtemp(join(tmpdir(), 'scholia-security-'));
  const store = new AccountStore(root);
  const documents = {
    index: async () => ({ pages: [{ number: 1, text: 'Private document' }] }),
    import: async (_user, fileName) => ({
      id: randomUUID(),
      fileName,
      title: fileName,
      kind: 'text',
      pageCount: 1,
    }),
    ...options.documents,
  };
  const workspaces = new Workspaces(store, documents, options);
  t.after(async () => {
    await workspaces.stop();
    store.close();
    await rm(root, { recursive: true, force: true });
  });
  const user = await store.createUser('owner@example.com', 'a sufficiently long password');
  const login = await store.login(user.email, 'a sufficiently long password');
  return { store, documents, workspaces, user, login, session: () => store.session(login.value) };
}

test('queued actions refresh same-session navigation before validating draft ownership', async (t) => {
  const app = await fixture(t);
  const first = await app.workspaces.action(app.session(), {
    action: 'create',
    name: 'First course',
  });
  const staleSession = app.session();
  const second = await app.workspaces.action(app.session(), {
    action: 'create',
    name: 'Second course',
  });
  await assert.rejects(
    app.workspaces.action(staleSession, {
      action: 'draft',
      text: 'A stale first-course draft',
      owner: first.draftOwner,
    }),
    { status: 409 }
  );
  assert.equal(app.session().navigation.selectedCourseID, second.library.selectedCourseID);
  assert.equal(app.store.account(app.user.id).library.courses[0].threads.length, 0);
});

test('background imports exclude conflicting writes but permit navigation', async (t) => {
  let finishImport;
  const app = await fixture(t, {
    documents: {
      import: () =>
        new Promise((resolve) => {
          finishImport = resolve;
        }),
    },
  });
  await app.workspaces.action(app.session(), { action: 'create', name: 'Import destination' });
  const account = app.workspaces.account(app.user.id),
    course = account.library.courses[0];
  course.canvasMaterials.push({ id: 'files:1', kind: 'files', title: 'Uncached file' });
  await app.workspaces.action(app.session(), {
    action: 'import',
    name: 'notes.txt',
    data: Buffer.from('notes').toString('base64'),
  });
  try {
    for (const action of [
      { action: 'material', id: 'files:1' },
      { action: 'saveDocument', edit: {} },
      { action: 'connect', origin: 'https://canvas.ntnu.no', token: 'replacement' },
      { action: 'import', name: 'other.txt', data: 'YWJj' },
    ])
      await assert.rejects(app.workspaces.action(app.session(), action), { status: 409 });
    await app.workspaces.action(app.session(), { action: 'create', name: 'Another destination' });
    assert.equal(account.library.courses.length, 2);
  } finally {
    finishImport({
      id: randomUUID(),
      fileName: 'notes.txt',
      title: 'notes',
      kind: 'text',
      pageCount: 1,
    });
    await account.job;
  }
  assert.equal(account.settings.storageBytes, 5);
  assert.equal(course.documents.length, 1);
  assert.equal(account.library.courses[1].documents.length, 0);
});

test('failed Canvas replacement preserves the link to locally edited material', async (t) => {
  const app = await fixture(t, {
    documents: {
      import: async () => {
        throw new Error('Cannot index this file.');
      },
    },
  });
  await app.workspaces.action(app.session(), { action: 'create', name: 'Course' });
  const account = app.workspaces.account(app.user.id),
    course = account.library.courses[0];
  Object.assign(course, { canvasOrigin: 'https://canvas.ntnu.no', canvasUserID: 4 });
  account.library.canvasUserID = 4;
  const document = {
    id: randomUUID(),
    sourceKey: 'files:1',
    sourceVersion: 'old',
    title: 'My notes',
    locallyEditedAt: 1,
  };
  course.documents.push(document);
  const canvas = {
    origin: course.canvasOrigin,
    material: async () => ({
      reference: { version: 'new' },
      name: 'notes.txt',
      data: Buffer.from('updated'),
    }),
  };
  await assert.rejects(
    app.workspaces.fetchMaterial(account, course, { id: 'files:1', version: 'new' }, canvas),
    /Cannot index/
  );
  assert.equal(document.sourceKey, 'files:1');
  assert.equal(document.title, 'My notes');
});

test('account cache evicts only saved idle accounts and retains running jobs', async (t) => {
  const app = await fixture(t, { maxCachedAccounts: 1 });
  const second = await app.store.createUser('second@example.com', 'a sufficiently long password');
  const first = app.workspaces.account(app.user.id);
  first.settings.example = 'persisted';
  app.store.save(first);
  first.job = Promise.resolve();
  assert.throws(() => app.workspaces.account(second.id), { status: 503 });
  first.job = null;
  app.workspaces.account(second.id);
  assert.equal(app.workspaces.accounts.size, 1);
  assert.equal(app.workspaces.account(app.user.id).settings.example, 'persisted');
});

test('Canvas retries stop promptly when the user cancels', async () => {
  const controller = new AbortController();
  const canvas = new Canvas('https://canvas.ntnu.no', 'private-token', {
    signal: controller.signal,
    request: async () => ({ status: 429, headers: { 'retry-after': '60' } }),
  });
  const request = canvas.api('/api/v1/users/self/profile');
  controller.abort();
  await assert.rejects(request, { name: 'AbortError' });
});

test('Canvas downloads never attach the account token to an external file host', async () => {
  const requests = [];
  const canvas = new Canvas('https://canvas.ntnu.no', 'private-token', {
    request: async (url, options) => {
      requests.push({ url: String(url), options });
      return requests.length === 1
        ? {
            status: 200,
            headers: {},
            data: JSON.stringify({
              id: 7,
              filename: 'reading.pdf',
              url: 'https://files.example.edu/reading.pdf',
            }),
          }
        : { status: 200, headers: {}, data: Buffer.from('file') };
    },
  });
  await canvas.material({ kind: 'files', remoteID: '7' }, { canvasID: 3 });
  assert.equal(requests[0].options.headers.Authorization, 'Bearer private-token');
  assert.deepEqual(requests[1].options.headers, {});
  assert.equal(requests[1].options.redirects, true);
});

test('encryption configuration rejects trailing non-hex text', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'scholia-invalid-secret-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  assert.throws(() => new AccountStore(root, { secret: 'ab'.repeat(32) + 'invalid' }), /64 hex/);
});

test('expired or revoked sessions cannot finish a queued mutation', async (t) => {
  const app = await fixture(t),
    session = app.session();
  app.store.logout(app.login.value);
  await assert.rejects(
    app.workspaces.action(session, { action: 'create', name: 'Revoked request' }),
    { status: 401 }
  );
  assert.equal(app.store.account(app.user.id).library.courses.length, 0);
});

test('successful logins retain at most twenty sessions per account', async (t) => {
  const app = await fixture(t);
  let latest;
  for (let i = 0; i < 20; i++)
    latest = await app.store.login(app.user.email, 'a sufficiently long password');
  assert.equal(app.store.session(app.login.value), null);
  assert.ok(app.store.session(latest.value));
  assert.equal(
    app.store.db.prepare('SELECT COUNT(*) AS count FROM sessions WHERE user_id=?').get(app.user.id)
      .count,
    20
  );
});

test('failed automatic transfers consume the batch budget and never cross Canvas account ownership', async (t) => {
  const transfers = [],
    requests = [];
  const app = await fixture(t, {
    canvasHosts: ['canvas.example'],
    remoteRequest: async (address, options) => {
      const url = new URL(address);
      requests.push(url.href);
      if (url.hostname === 'files.example') {
        transfers.push(options.limit);
        throw new Error('Transfer interrupted.');
      }
      const id = url.pathname.split('/').at(-1);
      return {
        status: 200,
        headers: {},
        data: JSON.stringify({
          id,
          filename: `input-${id}.nanowire`,
          url: `https://files.example/${id}`,
        }),
      };
    },
  });
  await app.workspaces.action(app.session(), { action: 'create', name: 'Prepared files' });
  const account = app.workspaces.account(app.user.id),
    course = account.library.courses[0];
  Object.assign(account.library, { canvasOrigin: 'https://canvas.example', canvasUserID: 1 });
  Object.assign(course, { canvasOrigin: 'https://canvas.example', canvasUserID: 1, canvasID: 1 });
  app.store.credential(account.id, 'canvas:https://canvas.example', 'private-token');
  const assignment = {
    id: 'assignments:1',
    kind: 'assignments',
    assignment: { linkedFileIDs: ['1', '2', '3', '4'] },
  };
  app.workspaces.prepareAssignmentFiles(account, course, assignment);
  await account.job;
  assert.deepEqual(transfers, [20_000_000, 20_000_000, 10_000_000]);
  assert.match(app.workspaces.assignmentNotices(course, assignment)['files:4'], /50 MB/);
  const before = requests.length;
  course.canvasUserID = 2;
  app.workspaces.prepareAssignmentFiles(account, course, assignment);
  await account.job;
  assert.equal(
    requests.length,
    before,
    'No request uses a token belonging to another Canvas account'
  );
  assert.match(
    app.workspaces.assignmentNotices(course, assignment)['files:1'],
    /owns this workspace/
  );
});

test('the default PDF respects automatic download limits while explicit attachment opening remains available', async (t) => {
  const transfers = [];
  const assignmentRecord = {
    id: 1, name: 'Large PDF', updated_at: 'v1', published: true,
    description: '<a href="/courses/1/files/1/download">large.pdf</a>',
    submission_types: ['online_upload'],
  };
  const app = await fixture(t, {
    canvasHosts: ['canvas.example'],
    remoteRequest: async (address, options) => {
      const url = new URL(address);
      if (url.hostname === 'files.example') {
        transfers.push(options.limit);
        return { status: 200, headers: {}, data: Buffer.from('PDF fixture') };
      }
      if (url.pathname === '/api/v1/courses/1/assignments/1')
        return { status: 200, headers: {}, data: JSON.stringify(assignmentRecord) };
      if (url.pathname === '/api/v1/courses/1/assignments')
        return { status: 200, headers: {}, data: JSON.stringify([assignmentRecord]) };
      return {
        status: 200,
        headers: {},
        data: JSON.stringify({
          id: 1,
          filename: 'large.pdf',
          size: 21_000_000,
          updated_at: 'v1',
          url: 'https://files.example/1',
        }),
      };
    },
  });
  await app.workspaces.action(app.session(), { action: 'create', name: 'Large attachment' });
  const account = app.workspaces.account(app.user.id),
    course = account.library.courses[0];
  const assignment = {
    id: 'assignments:1',
    kind: 'assignments',
    remoteID: '1',
    title: 'Large PDF',
    version: 'v1',
    assignment: { linkedFileIDs: ['1'] },
  };
  course.canvasMaterials.push(assignment, {
    id: 'files:1',
    kind: 'files',
    remoteID: '1',
    fileName: 'large.pdf',
    title: 'large.pdf',
    version: 'v1',
    byteCount: 21_000_000,
  });
  course.documents.push({
    id: randomUUID(),
    sourceKey: assignment.id,
    sourceVersion: 'v1',
    title: 'Instructions',
    kind: 'text',
    pageCount: 1,
  });
  const state = await app.workspaces.action(app.session(), {
    action: 'assignment',
    id: assignment.id,
    courseID: course.id,
  });
  assert.equal(state.library.selectedDocumentID, null);
  assert.match(state.assignmentFileNotices['files:1'], /20 MB/);
  assert.equal(account.job, undefined);
  assert.deepEqual(transfers, []);
  Object.assign(account.library, { canvasOrigin: 'https://canvas.example', canvasUserID: 1 });
  Object.assign(course, { canvasOrigin: 'https://canvas.example', canvasUserID: 1, canvasID: 1 });
  app.store.credential(account.id, 'canvas:https://canvas.example', 'private-token');
  const selected = await app.workspaces.action(app.session(), {
    action: 'assignmentFile',
    courseID: course.id,
    assignmentID: assignment.id,
    id: 'files:1',
  });
  assert.ok(selected.library.selectedDocumentID);
  assert.deepEqual(transfers, [100_000_000]);
});
