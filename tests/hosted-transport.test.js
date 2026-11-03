import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { get } from 'node:http';
import { randomUUID } from 'node:crypto';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHostedServer } from '../apps/server/server.js';
import { Workspaces } from '../apps/server/workspaces.js';

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'scholia-transport-'));
  const assets = join(root, 'assets');
  await mkdir(join(assets, 'chunks'), { recursive: true });
  await writeFile(join(assets, 'index.html'), '<html><head>__SCHOLIA_TOKEN__</head></html>');
  await writeFile(join(assets, 'chunks', 'reader.js'), 'export const version = 1;');
  const reservation = createServer();
  await new Promise((resolve) => reservation.listen(0, '127.0.0.1', resolve));
  const port = reservation.address().port;
  await new Promise((resolve) => reservation.close(resolve));
  const origin = `http://127.0.0.1:${port}`;
  const app = createHostedServer({ root, assets, origin });
  await new Promise((resolve) => app.server.listen(port, '127.0.0.1', resolve));
  t.after(async () => {
    await app.close();
    await rm(root, { recursive: true, force: true });
  });
  const request = async (path, client = {}, options = {}) => {
    const response = await fetch(origin + path, {
      redirect: 'manual', ...options,
      headers: {
        ...(client.cookie ? { Cookie: client.cookie, 'X-Scholia-Token': client.csrf } : {}),
        ...options.headers,
      },
    });
    const text = await response.text();
    return { status: response.status, headers: response.headers, text };
  };
  const login = async (email) => {
    const user = await app.store.createUser(email, 'correct horse battery staple');
    const session = await app.store.login(email, 'correct horse battery staple');
    return { user, cookie: `scholia_session=${session.value}`, csrf: session.csrf };
  };
  const action = (client, command) => request('/api/action', client, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(command),
  });
  return { ...app, assets, origin, request, login, action };
}

test('unchanged workspace polls transfer no snapshot and mutations invalidate the validator', async (t) => {
  const app = await fixture(t);
  const alice = await app.login('alice@example.com');
  const account = app.workspaces.account(alice.user.id);
  account.library.courses = Array.from({ length: 15 }, (_, index) => ({
    id: randomUUID(), name: `Course ${index}`, code: `CODE${index}`, term: 'Autumn 2026',
    documents: [], threads: [],
    canvasMaterials: Array.from({ length: 80 }, (_, number) => ({
      id: `files:${number}`, kind: 'files', remoteID: String(number),
      title: `Lecture ${number} on algorithms and data structures`,
      fileName: `lecture-${number}.pdf`, version: 'revision-1',
      sourceURL: `https://canvas.example/courses/${index}/files/${number}`,
    })),
  }));
  app.store.save(account);
  await app.action(alice, { action: 'course', id: account.library.courses[0].id });
  const initial = await app.request('/api/state', alice);
  assert.equal(initial.status, 200);
  assert.ok(initial.text.length > 100_000);
  assert.equal(initial.headers.get('cache-control'), 'no-store');
  const etag = initial.headers.get('etag');
  assert.ok(etag);
  for (let index = 0; index < 3; index++) {
    const unchanged = await app.request('/api/state', alice, { headers: { 'If-None-Match': etag } });
    assert.equal(unchanged.status, 304);
    assert.equal(unchanged.text, '');
    assert.equal(unchanged.headers.get('etag'), etag);
  }
  const changed = await app.action(alice, { action: 'favorite', id: account.library.courses[0].id });
  assert.equal(changed.status, 200);
  const current = await app.request('/api/state', alice, { headers: { 'If-None-Match': etag } });
  assert.equal(current.status, 200);
  assert.notEqual(current.headers.get('etag'), etag);
  assert.equal(JSON.parse(current.text).library.courses[0].favorite, true);
  const bob = await app.login('bob@example.com');
  const separate = await app.request('/api/state', bob, { headers: { 'If-None-Match': etag } });
  assert.equal(separate.status, 200);
  assert.deepEqual(JSON.parse(separate.text).library.courses, []);
  const forbidden = await app.request('/api/state', {}, { headers: { 'If-None-Match': '*' } });
  assert.equal(forbidden.status, 401, 'Conditional requests still require authentication');
  t.diagnostic(`15-course fixture: ${Buffer.byteLength(initial.text)} snapshot bytes -> 0 on unchanged polls`);
});

test('split assets revalidate without caching the session-specific HTML shell', async (t) => {
  const app = await fixture(t);
  const user = await app.login('assets@example.com');
  const initial = await app.request('/chunks/reader.js', user);
  assert.equal(initial.status, 200);
  assert.equal(initial.headers.get('cache-control'), 'private, no-cache');
  assert.match(initial.headers.get('content-type'), /javascript/);
  const etag = initial.headers.get('etag');
  assert.ok(etag);
  const unchanged = await app.request('/chunks/reader.js', user, {
    headers: { 'If-None-Match': `"old", ${etag.replace(/^W\//, '')}` },
  });
  assert.equal(unchanged.status, 304);
  assert.equal(unchanged.text, '');
  await writeFile(join(app.assets, 'chunks', 'reader.js'), 'export const version = 22;');
  const rebuilt = await app.request('/chunks/reader.js', user, { headers: { 'If-None-Match': etag } });
  assert.equal(rebuilt.status, 200);
  assert.match(rebuilt.text, /22/);
  assert.notEqual(rebuilt.headers.get('etag'), etag);
  const shell = await app.request('/', user, { headers: { 'If-None-Match': '*' } });
  assert.equal(shell.status, 200);
  assert.equal(shell.headers.get('cache-control'), 'no-store');
  assert.equal(shell.headers.get('etag'), null);
  assert.ok(shell.text.includes(user.csrf));
  const unauthenticated = await app.request('/chunks/reader.js', {}, { headers: { 'If-None-Match': '*' } });
  assert.equal(unauthenticated.status, 303, 'Asset validators do not bypass the authenticated route');
});

test('document streaming preserves complete bytes, storage aliases and account boundaries', async (t) => {
  const app = await fixture(t);
  const alice = await app.login('reader@example.com');
  const bob = await app.login('other-reader@example.com');
  const account = app.workspaces.account(alice.user.id);
  const doc = { id: randomUUID(), storageID: randomUUID(), title: 'Large notes',
    fileName: 'large notes.pdf', kind: 'pdf' };
  account.library.courses = [{ id: randomUUID(), name: 'Course', documents: [doc], threads: [] }];
  const directory = app.documents.directory(account.id, doc.storageID);
  await mkdir(directory, { recursive: true });
  const bytes = '%PDF-1.7\n' + 'A long document passage.\n'.repeat(100_000) + '%%EOF';
  await writeFile(join(directory, 'original'), bytes);
  const response = await app.request(`/api/document/${doc.id}`, alice);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-length'), String(Buffer.byteLength(bytes)));
  assert.equal(response.headers.get('content-type'), 'application/pdf');
  assert.equal(response.headers.get('cache-control'), 'no-store');
  assert.match(response.headers.get('content-disposition'), /large%20notes.pdf/);
  assert.equal(response.text.length, bytes.length);
  assert.equal(response.text, bytes);
  assert.equal((await app.request(`/api/document/${doc.id}`, bob)).status, 404);
  await new Promise((resolve, reject) => {
    const request = get(`${app.origin}/api/document/${doc.id}`, {
      headers: { Cookie: alice.cookie, 'X-Scholia-Token': alice.csrf },
    }, (response) => {
      response.once('data', () => {
        // Closing a reader mid-transfer must tear down the file stream without
        // an unhandled error or a response that keeps server shutdown waiting.
        response.destroy();
        request.destroy();
        resolve();
      });
      response.once('error', reject);
    });
    request.once('error', reject);
  });
  assert.equal((await app.request('/healthz')).status, 200);
  assert.equal((await app.request(`/api/document/${doc.id}`, alice)).text.length, bytes.length);
  await rm(join(directory, 'original'));
  assert.equal((await app.request(`/api/document/${doc.id}`, alice)).status, 404);
});

test('material inventory reuse survives reading and chat changes but observes catalog mutations', () => {
  const workspace = new Workspaces({}, {});
  const document = {
    id: randomUUID(), sourceKey: 'files:1', sourceVersion: '1', title: 'Lecture 1',
    kind: 'pdf', fileName: 'lecture.pdf', pageCount: 10,
  };
  const course = {
    id: randomUUID(), documents: [document], threads: [],
    canvasMaterials: [{ id: 'files:1', kind: 'files', title: 'Lecture 1', version: '1' }],
  };
  const initial = workspace.materialInventory(course);
  document.lastPage = 8;
  document.lastOpenedAt = Date.now();
  course.threads.push({ id: randomUUID(), messages: [{ content: 'A new chat token' }] });
  assert.equal(workspace.materialInventory(course), initial);
  course.canvasMaterials[0].version = '2';
  const updated = workspace.materialInventory(course);
  assert.notEqual(updated, initial);
  assert.equal(updated.files[0].updateAvailable, true);
  document.title = 'Renamed lecture';
  const renamed = workspace.materialInventory(course);
  assert.notEqual(renamed, updated);
  assert.equal(renamed.groups[0].items[0].title, 'Renamed lecture');
});
