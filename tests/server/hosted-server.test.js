import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { request as httpRequest } from 'node:http';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHostedServer } from '../../apps/server/server.js';
import { assignmentDetails } from '../../apps/server/courses/canvas.js';
import { publicAddress } from '../../apps/server/network.js';
import { onePagePdf } from '../helpers/pdf.js';
import { crc32, deflateRawSync } from 'node:zlib';

function wordDocument(text) {
  const name = Buffer.from('word/document.xml');
  const xml = Buffer.from(
    `<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>${text}</w:t></w:r></w:p></w:body></w:document>`
  );
  const data = deflateRawSync(xml),
    header = Buffer.alloc(30),
    directory = Buffer.alloc(46),
    end = Buffer.alloc(22);
  header.writeUInt32LE(0x04034b50);
  header.writeUInt16LE(20, 4);
  header.writeUInt16LE(8, 8);
  header.writeUInt32LE(crc32(xml), 14);
  header.writeUInt32LE(data.length, 18);
  header.writeUInt32LE(xml.length, 22);
  header.writeUInt16LE(name.length, 26);
  directory.writeUInt32LE(0x02014b50);
  directory.writeUInt16LE(20, 4);
  directory.writeUInt16LE(20, 6);
  directory.writeUInt16LE(8, 10);
  directory.writeUInt32LE(crc32(xml), 16);
  directory.writeUInt32LE(data.length, 20);
  directory.writeUInt32LE(xml.length, 24);
  directory.writeUInt16LE(name.length, 28);
  end.writeUInt32LE(0x06054b50);
  end.writeUInt16LE(1, 8);
  end.writeUInt16LE(1, 10);
  end.writeUInt32LE(directory.length + name.length, 12);
  end.writeUInt32LE(header.length + name.length + data.length, 16);
  return Buffer.concat([header, name, data, directory, name, end]);
}

test('hosted document workers extract PDF, Office and notebook text without executing cells', async (t) => {
  const app = await fixture(t),
    alice = await app.login('formats@example.com');
  const pdf = await app.documents.import(
    alice.user.id,
    'lecture.pdf',
    Buffer.from(onePagePdf('Course PDF text'))
  );
  assert.equal(pdf.kind, 'pdf');
  assert.match((await app.documents.index(alice.user.id, pdf)).pages[0].text, /Course PDF text/);
  const office = await app.documents.import(
    alice.user.id,
    'lecture.docx',
    wordDocument('Eigenvectors and geometry')
  );
  assert.match(
    (await app.documents.index(alice.user.id, office)).pages[0].text,
    /Eigenvectors and geometry/
  );
  const notebook = await app.documents.import(
    alice.user.id,
    'lab.ipynb',
    Buffer.from(
      JSON.stringify({
        cells: [
          {
            cell_type: 'code',
            source: ['raise Exception("Do not execute")'],
            outputs: [{ text: ['Saved result 42'] }],
          },
        ],
      })
    )
  );
  assert.match(
    (await app.documents.index(alice.user.id, notebook)).pages[0].text,
    /Do not execute[\s\S]*Saved result 42/
  );
});

test('hidden assignments persist per account without altering submission status or other course IDs', async (t) => {
  const app = await fixture(t),
    alice = await app.login('hide@example.com'),
    bob = await app.login('other@example.com');
  await app.request('/api/action', {
    ...alice,
    data: { action: 'create', name: 'Private assignments' },
  });
  const account = app.workspaces.account(alice.user.id),
    course = account.library.courses[0];
  course.canvasMaterials = [
    {
      id: 'assignments:1',
      kind: 'assignments',
      title: 'Exercise',
      assignment: { status: 'submitted', submissionTypes: ['online_upload'] },
    },
  ];
  const action = {
    action: 'assignmentVisibility',
    courseID: course.id,
    id: 'assignments:1',
    enabled: true,
  };
  assert.equal((await app.request('/api/action', { ...bob, data: action })).status, 404);
  assert.equal((await app.request('/api/action', { ...alice, data: action })).status, 200);
  const saved = app.store.account(alice.user.id).library.courses[0];
  assert.deepEqual(saved.hiddenAssignmentIDs, ['assignments:1']);
  assert.equal(saved.canvasMaterials[0].assignment.status, 'submitted');
  await app.request('/api/action', { ...alice, data: { ...action, enabled: false } });
  assert.deepEqual(app.store.account(alice.user.id).library.courses[0].hiddenAssignmentIDs, []);
  const overview = await app.request('/api/action', { ...alice, data: { action: 'assignments' } });
  assert.equal(overview.body.library.courseLibraryView, 'assignments');
  assert.equal(overview.body.showingLibrary, true);
  const reload = await app.request('/api/state', alice);
  assert.equal(reload.body.library.courseLibraryView, 'assignments');
  assert.equal(reload.body.library.courses[0].canvasMaterials[0].assignment.status, 'submitted');
  const dashboard = await app.request('/api/action', { ...alice, data: { action: 'library' } });
  assert.equal(dashboard.body.library.courseLibraryView, 'all');
});

test('each hosted user indexes Canvas privately and opens the assignment PDF on demand', async (t) => {
  const calls = [];
  let dueAt = '2026-10-08T21:59:59Z', offline = false;
  const remoteRequest = async (address, options) => {
    const url = new URL(address),
      token = options.headers?.Authorization;
    calls.push({ path: url.pathname, token });
    if (offline) throw new Error('Offline');
    if (url.hostname === 'files.example') {
      assert.equal(token, undefined, 'Canvas credentials must not reach the file host');
      return { status: 200, headers: {}, data: Buffer.from(onePagePdf('Assignment PDF body')) };
    }
    const identity = token === 'Bearer alice-canvas-token' ? 'Alice' : 'Bob';
    const assignment = {
      id: 1,
      name: `${identity} exercise`,
      due_at: dueAt,
      submission_types: ['online_upload'],
      submission: { workflow_state: identity === 'Alice' ? 'submitted' : 'unsubmitted' },
      description: '<p>Show your work.</p><a href="/courses/1/files/2/download">PDF</a>',
    };
    const file = {
      id: 2,
      display_name: 'Exercises',
      filename: 'Exercises.pdf',
      size: 1000,
      url: 'https://files.example/exercise.pdf',
      updated_at: '2026-09-01T00:00:00Z',
    };
    const bodies = {
      '/api/v1/users/self/profile': { id: identity === 'Alice' ? 1 : 2, name: identity },
      '/api/v1/courses': [
        {
          id: 1,
          name: `${identity} private course`,
          course_code: 'MATH',
          term: { name: 'Autumn 2026' },
        },
      ],
      '/api/v1/courses/1/files': [file],
      '/api/v1/courses/1/assignments': [assignment],
      '/api/v1/courses/1/pages': [],
      '/api/v1/courses/1/modules': [],
      '/api/v1/courses/1/assignments/1': assignment,
      '/api/v1/courses/1/files/2': file,
    };
    assert.ok(Object.hasOwn(bodies, url.pathname), url.pathname);
    return { status: 200, headers: {}, data: Buffer.from(JSON.stringify(bodies[url.pathname])) };
  };
  const app = await fixture(t, { canvasHosts: ['canvas.example'], remoteRequest });
  const alice = await app.login('canvas-alice@example.com'),
    bob = await app.login('canvas-bob@example.com');
  for (const [user, token] of [
    [alice, 'alice-canvas-token'],
    [bob, 'bob-canvas-token'],
  ]) {
    assert.equal(
      (
        await app.request('/api/action', {
          ...user,
          data: { action: 'connect', origin: 'https://canvas.example', token },
        })
      ).status,
      200
    );
    await app.workspaces.account(user.user.id).job;
  }
  assert.equal(
    calls.some((c) => c.path.endsWith('.pdf')),
    false,
    'Indexing fetches metadata only'
  );
  const state = (await app.request('/api/state', alice)).body,
    course = state.library.courses[0];
  assert.equal(course.name, 'Alice private course');
  const opened = await app.request('/api/action', {
    ...alice,
    data: { action: 'assignment', courseID: course.id, id: 'assignments:1' },
  });
  assert.equal(opened.status, 200);
  assert.equal(opened.body.assignmentNotice, null);
  const doc = opened.body.library.courses[0].documents.find(
    (d) => d.id === opened.body.library.selectedDocumentID
  );
  assert.equal(doc.kind, 'pdf');
  assert.match(opened.body.assignmentText, /Show your work/);
  assert.match(opened.body.pageText, /Assignment PDF body/);
  assert.equal((await app.request(`/api/document/${doc.id}`, bob)).status, 404);
  assert.doesNotMatch(
    JSON.stringify((await app.request('/api/state', bob)).body),
    /Alice|Assignment PDF body/
  );
  assert.doesNotMatch(JSON.stringify(opened.body), /alice-canvas-token|bob-canvas-token/);

  const fileRequests = calls.filter(c => c.path.endsWith('.pdf')).length;
  const openAgain = () => app.request('/api/action', {
    ...alice, data: { action: 'assignment', courseID: course.id, id: 'assignments:1' },
  });
  dueAt = '2026-10-11T21:59:59Z';
  const moved = await openAgain();
  const details = moved.body.library.courses[0].canvasMaterials.find(m => m.id === 'assignments:1').assignment;
  assert.equal(details.dueAt, dueAt, 'Opening a cached assignment must fetch its revised deadline');
  assert.equal(new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/Oslo', weekday: 'long', day: 'numeric', month: 'long' })
    .format(new Date(details.dueAt)), 'Sunday 11 October');
  assert.equal(moved.body.library.selectedDocumentID, doc.id, 'The saved PDF stays selected');
  assert.equal(calls.filter(c => c.path.endsWith('.pdf')).length, fileRequests, 'Refreshing a deadline does not download the PDF again');
  offline = true;
  const saved = await openAgain();
  assert.match(saved.body.assignmentNotice, /Deadline may be out of date/);
  assert.match(saved.body.pageText, /Assignment PDF body/);
  offline = false;
  dueAt = null;
  const removed = await openAgain();
  assert.equal(removed.body.library.courses[0].canvasMaterials.find(m => m.id === 'assignments:1').assignment.dueAt, null);
  assert.equal(removed.body.assignmentNotice, null);
});

test('search API enforces auth, CSRF and account scope and finds contents across workspaces', async (t) => {
  const app = await fixture(t), alice = await app.login('search-a@example.com'), bob = await app.login('search-b@example.com');
  const document = await app.documents.import(alice.user.id, 'notes.txt', Buffer.from('Exact eigenvector evidence.'));
  const account = app.workspaces.account(alice.user.id);
  account.library.courses.push({ id: 'first', name: 'First', documents: [document], canvasMaterials: [], threads: [] },
    { id: 'second', name: 'Second', documents: [], canvasMaterials: [], threads: [] });
  assert.equal((await app.request('/api/search?q=eigenvector')).status, 401);
  assert.equal((await app.request('/api/search?q=eigenvector', { cookie: alice.cookie })).status, 403);
  const result = await app.request('/api/search?q=eigenvector', alice);
  assert.equal(result.status, 200);
  assert.equal(result.body.results[0].documentID, document.id);
  assert.equal(result.body.results[0].page, 1);
  assert.equal((await app.request('/api/search?q=eigenvector&courseID=second', alice)).body.total, 0);
  assert.equal((await app.request('/api/search?q=eigenvector', bob)).body.total, 0);
  assert.equal((await app.request('/api/search?q=eigenvector&courseID=first', bob)).status, 404);
  assert.equal((await app.request('/api/search?q=' + 'x'.repeat(513), alice)).status, 400);
});

async function fixture(t, options = {}) {
  const root = await mkdtemp(join(tmpdir(), 'scholia-hosted-test-'));
  const reserve = createServer();
  await new Promise((resolve) => reserve.listen(0, '127.0.0.1', resolve));
  const port = reserve.address().port;
  await new Promise((resolve) => reserve.close(resolve));
  const app = createHostedServer({ root, origin: `http://127.0.0.1:${port}`, ...options });
  await new Promise((resolve) => app.server.listen(port, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${app.server.address().port}`;
  t.after(async () => {
    await app.close();
    await rm(root, { recursive: true, force: true });
  });
  const request = async (path, { cookie, csrf, data, method, ...rest } = {}) => {
    const response = await fetch(url + path, {
      method: method || (data ? 'POST' : 'GET'),
      headers: {
        ...(cookie ? { Cookie: cookie } : {}),
        ...(csrf ? { 'X-Scholia-Token': csrf } : {}),
        ...(data ? { 'Content-Type': 'application/json' } : {}),
        ...rest.headers,
      },
      body: data ? JSON.stringify(data) : undefined,
      redirect: 'manual',
    });
    const text = await response.text();
    let body;
    try {
      body = JSON.parse(text);
    } catch {
      body = text;
    }
    return { status: response.status, body, headers: response.headers };
  };
  const login = async (email) => {
    const user = await app.store.createUser(email, 'correct horse battery staple');
    const result = await request('/auth/login', {
      data: { email, password: 'correct horse battery staple' },
    });
    assert.equal(result.status, 200, JSON.stringify(result.body));
    const cookie = result.headers.get('set-cookie').split(';')[0];
    const session = app.store.session(cookie.split('=')[1]);
    return { user, cookie, csrf: session.csrf, session };
  };
  return { ...app, root, request, login };
}

test('hosted accounts isolate workspaces, documents, conversations, credentials and sessions over HTTP', async (t) => {
  const app = await fixture(t, {
    complete: async (payload, _settings, onToken) => {
      const text = `Private reply: ${payload.messages.at(-1).content}`;
      onToken(text);
      return { text };
    },
  });
  const alice = await app.login('alice@example.com'),
    bob = await app.login('bob@example.com');
  const call = (user, action) => app.request('/api/action', { ...user, data: action });
  const a = await call(alice, { action: 'create', name: 'Alice private course', code: 'ALICE' });
  const aid = a.body.library.selectedCourseID;
  assert.ok(aid);
  assert.equal((await call(bob, { action: 'course', id: aid })).status, 404);
  await call(bob, { action: 'create', name: 'Bob private course', code: 'BOB' });
  assert.doesNotMatch(JSON.stringify((await app.request('/api/state', bob)).body), /Alice/);
  await call(alice, {
    action: 'import',
    name: 'secret.txt',
    data: Buffer.from('Alice private file content').toString('base64'),
  });
  await app.workspaces.account(alice.user.id).job;
  let state = (await app.request('/api/state', alice)).body;
  const doc = state.library.courses[0].documents[0];
  assert.ok(doc);
  assert.equal((await app.request(`/api/document/${doc.id}`, bob)).status, 404);
  assert.equal((await app.request(`/api/index/${doc.id}`, bob)).status, 404);
  assert.equal((await app.request(`/api/edit/${doc.id}`, bob)).status, 404);
  assert.equal((await call(bob, { action: 'resume', id: doc.id })).status, 404);
  assert.equal(
    (await app.request(`/api/document/${doc.id}`, alice)).body,
    'Alice private file content'
  );
  state = (await call(alice, { action: 'document', id: doc.id })).body;
  state = (await call(alice, { action: 'draft', text: 'Alice question', owner: state.draftOwner }))
    .body;
  const stale = state.draftOwner;
  state = (
    await call(alice, { action: 'draft', text: 'Alice newer question', owner: state.draftOwner })
  ).body;
  assert.equal((await call(alice, { action: 'send', text: 'stale', owner: stale })).status, 409);
  state = (
    await call(alice, { action: 'send', text: 'Alice newer question', owner: state.draftOwner })
  ).body;
  await app.workspaces.account(alice.user.id).job;
  state = (await app.request('/api/state', alice)).body;
  assert.match(state.messages.at(-1).content, /Alice newer question/);
  assert.doesNotMatch(
    JSON.stringify((await app.request('/api/state', bob)).body),
    /Alice|secret.txt/
  );
  await call(alice, {
    action: 'credentials',
    providerID: 'openai',
    key: 'private-alice-provider-key',
  });
  assert.equal(
    app.store.credential(alice.user.id, 'provider:openai'),
    'private-alice-provider-key'
  );
  assert.equal(app.store.credential(bob.user.id, 'provider:openai'), '');
  assert.doesNotMatch(
    JSON.stringify((await app.request('/api/state', alice)).body),
    /private-alice-provider-key/
  );
  const encrypted = app.store.db
    .prepare('SELECT value FROM credentials WHERE user_id=?')
    .get(alice.user.id).value;
  assert.doesNotMatch(encrypted, /private-alice-provider-key/);
  const saved = app.store.account(alice.user.id);
  assert.equal(saved.library.courses[0].documents[0].id, doc.id);
  assert.equal((await app.request('/auth/logout', { ...alice, data: {} })).status, 200);
  assert.equal((await app.request('/api/state', alice)).status, 401);
  assert.equal((await app.request('/api/state', bob)).status, 200);
});

test('whole-course questions retain metadata, course drafts and scope across readings and citations', async (t) => {
  const completions = [];
  const app = await fixture(t, {
    complete: async (payload) => {
      completions.push(payload);
      return { text: 'A grounded course answer.' };
    },
  });
  const user = await app.login('course-questions@example.com');
  const call = async (data) => {
    const result = await app.request('/api/action', { ...user, data });
    assert.equal(result.status, 200, JSON.stringify(result.body));
    return result.body;
  };
  let state = await call({ action: 'create', name: 'Geometric computing', code: 'MATH204' });
  const account = app.workspaces.account(user.user.id), course = account.library.courses[0];
  course.term = 'Autumn 2026';
  course.canvasMaterials = [
    { id: 'files:remote', kind: 'files', title: 'Remote syllabus' },
    { id: 'assignments:locked', kind: 'assignments', title: 'Future exercise',
      assignment: { locked: true, dueAt: '2026-11-02T10:00:00+01:00', status: 'not_submitted' } },
  ];
  app.store.save(account);
  state = await call({ action: 'context', enabled: false });
  state = await call({ action: 'send', text: 'What course is this and when is the exercise due?', owner: state.draftOwner });
  await account.job;
  assert.match(completions[0].context, /MATH204[\s\S]*Autumn 2026/);
  assert.match(completions[0].context, /Future exercise \| due: 2026-11-02T10:00:00\+01:00/);
  assert.match(completions[0].context, /Remote syllabus \| remote only; contents unavailable/);
  state = (await app.request('/api/state', user)).body;
  assert.equal(state.contextScope, 'course');
  assert.equal(state.includeCourse, true, 'course scope includes available context despite the previous reading preference');
  const courseThreadID = state.library.selectedThreadID;
  state = await call({ action: 'draft', text: 'Keep my whole-course question', owner: state.draftOwner });
  const reading = await app.documents.import(account.id, 'late-topic.ipynb', Buffer.from(JSON.stringify({ cells: [
    { cell_type: 'markdown', source: ['# Introduction'] },
    { cell_type: 'markdown', source: ['Background discussion.'] },
    { cell_type: 'markdown', source: ['The zebraquantum result is exactly 41 units.'] },
  ] })));
  course.documents.push(reading);
  const other = { id: 'other-course', name: 'Unrelated private course', documents: [], threads: [], canvasMaterials: [] };
  other.documents.push(await app.documents.import(account.id, 'unrelated.txt', Buffer.from('Secret unrelated zebraquantum result is 999.')));
  account.library.courses.push(other);
  app.store.save(account);
  state = await call({ action: 'document', id: reading.id });
  assert.equal(state.contextScope, 'document');
  state = await call({ action: 'draft', text: 'Separate reading question', owner: state.draftOwner });
  const readingThreadID = state.library.selectedThreadID;
  state = await call({ action: 'materials' });
  assert.equal(state.library.selectedThreadID, courseThreadID);
  assert.equal(state.draft, 'Keep my whole-course question');
  state = await call({ action: 'assignment', courseID: course.id, id: 'assignments:locked' });
  assert.equal(state.contextScope, 'assignment');
  state = await call({ action: 'draft', text: 'Separate assignment question', owner: state.draftOwner });
  const assignmentThreadID = state.library.selectedThreadID;
  assert.notEqual(assignmentThreadID, courseThreadID);
  state = await call({ action: 'materials' });
  assert.equal(state.library.selectedThreadID, courseThreadID);
  assert.equal(state.draft, 'Keep my whole-course question');
  state = await call({ action: 'send', text: 'Explain zebraquantum', owner: state.draftOwner });
  await account.job;
  assert.match(completions[1].context, /zebraquantum result is exactly 41 units/);
  assert.doesNotMatch(completions[1].context, /Secret unrelated|999/);
  state = (await app.request('/api/state', user)).body;
  const source = state.sources[state.messages.at(-1).id].find((entry) => entry.page === 3);
  assert.equal(source.documentID, reading.id);
  state = await call({ action: 'source', id: source.documentID, page: source.page });
  assert.equal(state.library.selectedThreadID, courseThreadID);
  assert.equal(state.contextScope, 'course');
  state = await call({ action: 'send', text: 'How does this fit the course?', owner: state.draftOwner });
  await account.job;
  assert.equal(completions[2].pageTitle, course.name);
  assert.match(completions[2].context, /COURSE INFORMATION/);
  state = await call({ action: 'thread', id: readingThreadID });
  assert.equal(state.contextScope, 'document');
  assert.equal(state.draft, 'Separate reading question');
  state = await call({ action: 'thread', id: assignmentThreadID });
  assert.equal(state.contextScope, 'assignment');
  assert.equal(state.draft, 'Separate assignment question');
  assert.equal(state.library.selectedAssignmentID, 'assignments:locked');
});

test('hosted service rejects anonymous, cross-site, wrong-host and missing-CSRF requests', async (t) => {
  const app = await fixture(t),
    user = await app.login('private@example.com');
  assert.equal((await app.request('/api/state')).status, 401);
  assert.equal((await app.request('/api/state', { cookie: user.cookie })).status, 403);
  assert.equal(
    (await app.request('/api/state', { ...user, headers: { Origin: 'https://evil.example' } }))
      .status,
    403
  );
  const rejectedHost = await new Promise((resolve, reject) => {
    const request = httpRequest(
      {
        hostname: '127.0.0.1',
        port: app.server.address().port,
        path: '/api/state',
        headers: { Host: 'evil.example', Cookie: user.cookie, 'X-Scholia-Token': user.csrf },
      },
      (response) => {
        response.resume();
        resolve(response.statusCode);
      }
    );
    request.on('error', reject);
    request.end();
  });
  assert.equal(rejectedHost, 403);
  assert.equal(
    (await app.request('/api/action', { ...user, data: { action: 'native' } })).status,
    400
  );
  const wrong = await app.request('/auth/login', {
    data: { email: 'private@example.com', password: 'wrong' },
  });
  assert.equal(wrong.status, 401);
  const row = app.store.db.prepare('SELECT password FROM users WHERE id=?').get(user.user.id);
  assert.notEqual(row.password, 'correct horse battery staple');
  assert.match(user.cookie, /scholia_session=/);
});

test('two logins for one account keep navigation separate and validate edits by revision', async (t) => {
  const app = await fixture(t),
    user = await app.login('reader@example.com');
  const call = (client, data) => app.request('/api/action', { ...client, data });
  const first = (await call(user, { action: 'create', name: 'Course A' })).body.library
    .selectedCourseID;
  const second = (await call(user, { action: 'create', name: 'Course B' })).body.library
    .selectedCourseID;
  const auth = await app.request('/auth/login', {
    data: { email: 'reader@example.com', password: 'correct horse battery staple' },
  });
  const cookie = auth.headers.get('set-cookie').split(';')[0],
    session = app.store.session(cookie.split('=')[1]),
    other = { cookie, csrf: session.csrf };
  await call(other, { action: 'course', id: first });
  assert.equal((await app.request('/api/state', user)).body.library.selectedCourseID, second);
  await call(user, {
    action: 'import',
    name: 'edit.txt',
    data: Buffer.from('Original text').toString('base64'),
  });
  await app.workspaces.account(user.user.id).job;
  const doc = (await app.request('/api/state', user)).body.library.courses.find(
    (c) => c.id === second
  ).documents[0];
  await call(user, { action: 'document', id: doc.id });
  const edit = (await app.request(`/api/edit/${doc.id}`, user)).body;
  const saved = await call(user, {
    action: 'saveDocument',
    edit: { ...edit, source: 'Changed text' },
  });
  assert.equal(saved.status, 200);
  const current = saved.body.library.selectedDocumentID;
  assert.equal((await app.request(`/api/document/${current}`, user)).body, 'Changed text');
  assert.equal((await call(user, { action: 'saveDocument', edit })).status, 409);
  const fresh = (await app.request(`/api/edit/${current}`, user)).body;
  assert.equal(
    (await call(user, { action: 'saveDocument', edit: { ...fresh, source: '' } })).status,
    200
  );
  assert.equal((await app.request(`/api/document/${current}`, user)).body, '');
  assert.equal((await app.request('/api/state', other)).body.library.selectedCourseID, first);
});

test('Canvas submission mapping and outbound addresses preserve status and credential boundaries', () => {
  const origin = 'https://canvas.example';
  assert.equal(
    assignmentDetails({ submission: { workflow_state: 'graded', missing: true } }, origin, 1)
      .status,
    'notSubmitted'
  );
  assert.equal(
    assignmentDetails({ submission: { workflow_state: 'pending_review' } }, origin, 1).status,
    'submitted'
  );
  assert.equal(assignmentDetails({}, origin, 1).status, 'unknown');
  assert.deepEqual(
    assignmentDetails(
      {
        description:
          '<a href="/courses/1/files/2/download">PDF</a><a href="https://evil.example/files/3">other</a><a href="/courses/4/files/5">wrong course</a>',
      },
      origin,
      1
    ).linkedFileIDs,
    ['2']
  );
  for (const ip of [
    '127.0.0.1',
    '10.0.0.1',
    '169.254.169.254',
    '::1',
    '::ffff:127.0.0.1',
    'fc00::1',
    '192.168.0.1',
  ])
    assert.equal(publicAddress(ip), false, ip);
  assert.equal(publicAddress('1.1.1.1'), true);
});

test('assignment attachments retain context across non-PDF reading, reloads and citations', async (t) => {
  const downloads = [],
    completions = [];
  const bodies = {
    113: Buffer.from(onePagePdf('Measure the tensile strain and report the stress response.')),
    116: Buffer.from(
      'units metal\npair_style eam\nread_data nanowire.data\n' +
        '# Molecular dynamics input\n'.repeat(40)
    ),
    117: Buffer.from('Nickel EAM potential\n28 Ni 58.6934\n' + '0.001 0.025 0.600\n'.repeat(2300)),
    118: Buffer.from('An ASCII prefix followed by binary\0contents'),
    119: Buffer.from('Unrelated course text'),
  };
  const names = {
    113: 'Exercise+2.pdf',
    116: 'in.nanowire',
    117: 'Ni.eam',
    118: 'opaque.unknown',
    119: 'other.txt',
  };
  const assignment = (id) => ({
    id,
    name: id === 1 ? 'MD tensile test' : 'Second assignment',
    updated_at: '2026-09-27',
    submission_types: ['online_upload'],
    description:
      '<p>Analyze the included nanowire input and nickel potential.</p>' +
      [113, 114, 116, 117, 118]
        .map((file) => `<a href="/courses/1/files/${file}/download">Attachment ${file}</a>`)
        .join(''),
  });
  const file = (id) => ({
    id,
    filename: names[id],
    display_name: names[id],
    size: bodies[id]?.length,
    updated_at: '2026-09-27',
    url: `https://files.example/${id}`,
  });
  const remoteRequest = async (address, options) => {
    const url = new URL(address);
    if (url.hostname === 'files.example') {
      assert.equal(options.headers?.Authorization, undefined);
      const id = Number(url.pathname.slice(1));
      downloads.push(id);
      return { status: 200, headers: {}, data: bodies[id] };
    }
    const dynamicFile = url.pathname.match(/\/files\/(\d+)$/),
      dynamicAssignment = url.pathname.match(/\/assignments\/(\d+)$/);
    const endpoints = {
      '/api/v1/users/self/profile': { id: 1, name: 'Reader' },
      '/api/v1/courses': [{ id: 1, name: 'Computational materials', course_code: 'TKT4146' }],
      '/api/v1/courses/1/files': [file(113), file(119)],
      '/api/v1/courses/1/assignments': [assignment(1), assignment(2)],
      '/api/v1/courses/1/pages': [],
      '/api/v1/courses/1/modules': [],
    };
    if (dynamicFile?.[1] === '114') return { status: 404, headers: {}, data: Buffer.from('{}') };
    const value = dynamicFile
      ? file(Number(dynamicFile[1]))
      : dynamicAssignment
        ? assignment(Number(dynamicAssignment[1]))
        : endpoints[url.pathname];
    assert.ok(value, url.pathname);
    return { status: 200, headers: {}, data: Buffer.from(JSON.stringify(value)) };
  };
  const app = await fixture(t, {
    canvasHosts: ['canvas.example'],
    remoteRequest,
    complete: async (payload) => {
      completions.push(payload);
      return { text: 'The input and potential are available.' };
    },
  });
  const user = await app.login('attachments@example.com'),
    stranger = await app.login('stranger@example.com');
  const call = (data) => app.request('/api/action', { ...user, data });
  await call({ action: 'connect', origin: 'https://canvas.example', token: 'private-token' });
  await app.workspaces.account(user.user.id).job;
  const account = app.workspaces.account(user.user.id),
    course = account.library.courses[0];
  const opened = await call({ action: 'assignment', courseID: course.id, id: 'assignments:1' });
  assert.equal(opened.status, 200);
  assert.equal(opened.body.library.selectedAssignmentID, 'assignments:1');
  assert.equal(
    opened.body.library.courses[0].documents.find(
      (doc) => doc.id === opened.body.library.selectedDocumentID
    ).kind,
    'pdf'
  );
  await account.job;
  let state = (await app.request('/api/state', user)).body;
  assert.deepEqual(
    state.assignmentFiles.map((ref) => ref.id),
    [113, 114, 116, 117, 118].map((id) => `files:${id}`)
  );
  assert.deepEqual(
    state.assignmentPDFs.map((ref) => ref.id),
    ['files:113']
  );
  assert.match(state.assignmentFileNotices['files:114'], /404/);
  assert.equal(downloads[0], 113, 'The default PDF opens before other files are prepared');
  for (const id of [116, 117]) {
    const doc = course.documents.find((entry) => entry.sourceKey === `files:${id}`);
    assert.equal(doc.kind, 'code');
    assert.equal(doc.unreadablePages, 0);
    assert.deepEqual(await app.documents.data(account.id, doc), bodies[id]);
    assert.equal((await app.request(`/api/document/${doc.id}`, stranger)).status, 404);
  }
  const binary = course.documents.find((doc) => doc.sourceKey === 'files:118');
  assert.equal(binary.kind, 'preview');
  assert.equal(binary.unreadablePages, 1);
  delete binary.unreadablePages; // Libraries created before this release are normalized from their index.
  state = (await app.request('/api/state', user)).body;
  assert.equal(
    state.library.courses[0].documents.find((doc) => doc.id === binary.id).unreadablePages,
    1
  );
  assert.equal(
    (
      await call({
        action: 'assignmentFile',
        courseID: course.id,
        assignmentID: 'assignments:1',
        id: 'files:119',
      })
    ).status,
    404
  );
  assert.equal(
    (
      await app.request('/api/action', {
        ...stranger,
        data: {
          action: 'assignmentFile',
          courseID: course.id,
          assignmentID: 'assignments:1',
          id: 'files:116',
        },
      })
    ).status,
    404
  );
  state = (
    await call({
      action: 'assignmentFile',
      courseID: course.id,
      assignmentID: 'assignments:1',
      id: 'files:116',
    })
  ).body;
  await account.job;
  const selectedID = state.library.selectedDocumentID;
  assert.match(state.pageText, /pair_style eam/);
  assert.equal(state.library.selectedAssignmentID, 'assignments:1');
  app.workspaces.accounts.delete(account.id);
  state = (await app.request('/api/state', user)).body;
  assert.equal(state.library.selectedDocumentID, selectedID);
  assert.equal(state.library.selectedAssignmentID, 'assignments:1');
  await call({ action: 'context', enabled: false });
  state = (await app.request('/api/state', user)).body;
  state = (await call({ action: 'send', text: 'Explain this assignment', owner: state.draftOwner }))
    .body;
  await app.workspaces.account(account.id).job;
  assert.match(completions[0].context, /pair_style eam/);
  assert.match(completions[0].context, /Nickel EAM potential/);
  assert.match(completions[0].context, /Measure the tensile strain/);
  assert.match(completions[0].context, /not downloaded; contents unavailable/);
  assert.match(
    completions[0].context,
    /opaque.unknown: saved original; no readable text available/
  );
  assert.doesNotMatch(completions[0].context, /Unrelated course text|ASCII prefix/);
  assert.ok(completions[0].context.length <= 48000);
  state = (await app.request('/api/state', user)).body;
  const threadID = state.library.selectedThreadID,
    reply = state.messages.at(-1);
  const source = state.sources[reply.id].find((entry) => entry.title === 'Ni.eam');
  assert.ok(source);
  state = (await call({ action: 'source', id: source.documentID, page: source.page })).body;
  assert.equal(state.library.selectedThreadID, threadID);
  assert.equal(state.library.selectedAssignmentID, 'assignments:1');
  assert.equal(state.messages.at(-1).id, reply.id);
  state = (
    await call({
      action: 'assignmentFile',
      courseID: course.id,
      assignmentID: 'assignments:1',
      id: 'files:113',
    })
  ).body;
  await app.workspaces.account(account.id).job;
  const oldOwner = state.draftOwner;
  await call({ action: 'assignment', courseID: course.id, id: 'assignments:2' });
  await app.workspaces.account(account.id).job;
  assert.equal(
    (await call({ action: 'send', text: 'Stale question', owner: oldOwner })).status,
    409
  );
  assert.equal(
    (
      await call({
        action: 'assignmentFile',
        courseID: course.id,
        assignmentID: 'assignments:1',
        id: 'files:116',
      })
    ).status,
    409
  );
  assert.equal(
    (await app.request('/api/state', user)).body.library.selectedAssignmentID,
    'assignments:2'
  );
  assert.equal(downloads.filter((id) => id === 116).length, 1, 'Cached attachments are reused');
});

test('legacy scientific previews are reindexed offline without changing document identity or the original', async (t) => {
  const app = await fixture(t, {
    remoteRequest: async () => {
      throw new Error('Network must not be used for cached indexing.');
    },
  });
  const user = await app.login('legacy-preview@example.com');
  await app.request('/api/action', {
    ...user,
    data: { action: 'create', name: 'Cached assignment' },
  });
  const account = app.workspaces.account(user.user.id),
    course = account.library.courses[0];
  const original = Buffer.from('units metal\npair_style eam\n# offline legacy input');
  const document = await app.documents.import(account.id, 'in.nanowire', original);
  const instructions = await app.documents.import(
    account.id,
    'instructions.md',
    Buffer.from('Explain this molecular dynamics input.')
  );
  Object.assign(document, {
    kind: 'preview',
    indexVersion: 1,
    unreadablePages: 1,
    sourceKey: 'files:116',
    sourceVersion: 'v1',
    locallyEditedAt: 42,
    title: 'My input',
  });
  Object.assign(instructions, { sourceKey: 'assignments:1', sourceVersion: 'v1' });
  const { writeFile, stat } = await import('node:fs/promises');
  const directory = app.documents.directory(account.id, document.id);
  await writeFile(
    join(directory, 'index.json'),
    JSON.stringify({ pages: [{ number: 1, text: '' }] })
  );
  const before = await stat(join(directory, 'original'));
  course.documents.push(instructions, document);
  course.canvasMaterials.push(
    {
      id: 'assignments:1',
      kind: 'assignments',
      title: 'MD tensile test',
      version: 'v1',
      assignment: { linkedFileIDs: ['116'] },
    },
    {
      id: 'files:116',
      kind: 'files',
      remoteID: '116',
      title: 'in.nanowire',
      fileName: 'in.nanowire',
      version: 'v1',
    }
  );
  await app.request('/api/action', {
    ...user,
    data: { action: 'assignment', courseID: course.id, id: 'assignments:1' },
  });
  await account.job;
  assert.equal(document.kind, 'code');
  assert.equal(document.unreadablePages, 0);
  assert.equal(document.title, 'My input');
  assert.equal(document.locallyEditedAt, 42);
  assert.equal(document.sourceKey, 'files:116');
  assert.equal((await stat(join(directory, 'original'))).mtimeMs, before.mtimeMs);
  assert.deepEqual(await app.documents.data(account.id, document), original);
  assert.match((await app.documents.index(account.id, document)).pages[0].text, /pair_style eam/);
  const opened = await app.request('/api/action', {
    ...user,
    data: {
      action: 'assignmentFile',
      courseID: course.id,
      assignmentID: 'assignments:1',
      id: 'files:116',
    },
  });
  assert.equal(opened.body.library.selectedDocumentID, document.id);
  assert.equal(opened.body.library.selectedAssignmentID, 'assignments:1');
  assert.deepEqual(opened.body.assignmentFileNotices, {});
});
