import test from 'node:test';
import assert from 'node:assert/strict';
import { Canvas } from '../apps/server/canvas.js';
import { MathWiki, mathWikiCourse, mathWikiLink } from '../apps/server/math-wiki.js';
import { courseLinkTarget } from '../packages/core/src/course-documents.js';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AccountStore } from '../apps/server/store.js';
import { Documents } from '../apps/server/documents.js';
import { Workspaces } from '../apps/server/workspaces.js';
import { trainedPollingModel } from './helpers/content-polling.js';

const wiki = 'https://wiki.math.ntnu.no', canvasOrigin = 'https://canvas.ntnu.no';
const start = `${wiki}/ma1301/2026h/start`, pdf = `${wiki}/_media/ma1301/2026h/notes.pdf`;
const html = (body, nav = '') => `<html><head><title>Number theory - wiki.math.ntnu.no</title></head><body><nav>${nav}</nav><article><div class="content">${body}</div></article></body></html>`;

function refreshFixture() {
  const state = { page: 1, file: 1, failed: false, requests: 0, heads: 0, fileGets: 0, notModified: 0 };
  const request = async (url, options) => {
    state.requests++;
    assert.equal(url.origin, wiki, 'Wiki polling never requests Canvas');
    assert.equal(options.headers.Authorization, undefined);
    assert.equal(options.headers.Cookie, undefined);
    if (state.failed) return { status: 503, headers: {}, data: Buffer.alloc(0) };
    if (url.pathname.endsWith('.txt')) {
      if (options.method === 'HEAD') state.heads++; else state.fileGets++;
      return { status: 200, headers: { etag: `file-${state.file}`, 'content-length': '6' }, data: Buffer.from(`Note ${state.file}`) };
    }
    const archive = url.href === wiki + '/ma1301';
    const etag = archive ? 'archive' : `page-${state.page}`;
    if (options.headers['If-None-Match'] === etag) {
      state.notModified++;
      return { status: 304, headers: { etag }, data: Buffer.alloc(0) };
    }
    return { status: 200, headers: { etag }, data: Buffer.from(html(archive
      ? `<a href='${start}'>Autumn 2026</a>`
      : `<h1>Number theory ${state.page}</h1><a href='/_media/ma1301/2026h/notes.txt'>Notes</a>`)) };
  };
  return { state, request };
}

test('learned wiki checks import before the regular deadline, persist and share a workspace budget', async () => {
  const root = await mkdtemp(join(tmpdir(), 'scholia-wiki-prediction-')), store = new AccountStore(root);
  const { state, request } = refreshFixture(), { model, time } = trainedPollingModel();
  const workspaces = new Workspaces(store, new Documents(root), { remoteRequest: request });
  try {
    const user = await store.createUser('wiki-prediction@example.com', 'correct horse battery staple');
    const account = workspaces.account(user.id);
    Object.assign(account.library, { canvasOrigin, canvasUserID: 42 });
    const courses = Array.from({ length: 10 }, (_, i) => ({ id: `math-${i}`, code: 'MA1301-26H', term: '2026 HØST',
      canvasOrigin, canvasID: i + 1, canvasUserID: 42, documents: [], threads: [], canvasMaterials: [],
      mathWikiPolling: structuredClone(model), mathWikiUpdateAttemptedAt: time }));
    account.library.courses = courses;
    await workspaces.refreshMathWiki(account, courses[0].id, (time + 59) * 1000);
    assert.equal(state.requests, 0);
    const first = workspaces.refreshMathWiki(account, courses[0].id, (time + 60) * 1000);
    assert.equal(workspaces.refreshMathWiki(account, courses[0].id, (time + 60) * 1000), first);
    await first;
    assert.equal(courses.filter(c => c.documents.length === 2).length, 8);
    assert.equal(courses.flatMap(c => c.mathWikiPolling.extraChecks).length, 8, 'Ten courses share eight slots');
    assert.ok(courses.every(c => c.mathWikiUpdateAttemptedAt === time), 'Regular deadlines are preserved');
    assert.equal(store.account(user.id).library.courses.flatMap(c => c.mathWikiPolling.extraChecks).length, 8);
    const calls = state.requests;
    await workspaces.refreshMathWiki(account, courses[0].id, (time + 90) * 1000);
    assert.equal(state.requests, calls);
    await workspaces.refreshMathWiki(account, courses[0].id, (time + 120) * 1000);
    assert.equal(courses.filter(c => c.documents.length === 2).length, 10, 'Regular checks are never limited by prediction budget');
    assert.equal(courses.flatMap(c => c.mathWikiPolling.extraChecks).length, 8);
  } finally {
    await workspaces.stop(); store.db.close(); await rm(root, { recursive: true, force: true });
  }
});

test('conditional wiki checks reuse unchanged pages, space out file metadata and immediately follow page changes', async () => {
  const { state, request } = refreshFixture();
  let time = 1_000_000;
  const client = new MathWiki({ request, clock: () => time });
  const course = { code: 'MA1301-26H', canvasOrigin, canvasMaterials: [] };
  const refresh = async () => {
    const result = await client.catalog(course, { fileRecheckInterval: MathWiki.fileCheckInterval });
    assert.deepEqual(result.warnings, []);
    course.canvasMaterials = result.items;
    return result.items.find(ref => ref.kind === 'files');
  };
  assert.equal((await refresh()).version, 'file-1');
  time += MathWiki.checkInterval;
  await refresh();
  assert.equal(state.notModified, 2);
  assert.equal(state.heads, 1, 'Do not HEAD every old attachment on each page poll');
  time += 180_000; state.file = 2;
  assert.equal((await refresh()).version, 'file-2', 'In-place file changes are found even when the page is unchanged');
  assert.equal(state.heads, 2);
  time += MathWiki.checkInterval; state.page = 2; state.file = 3;
  assert.equal((await refresh()).version, 'file-3');
  assert.equal(state.heads, 3, 'A changed teaching page bypasses the attachment interval');
});

test('automatic wiki updates work without Canvas credentials, throttle tabs and preserve saved work on failures', async () => {
  const root = await mkdtemp(join(tmpdir(), 'scholia-wiki-refresh-'));
  const store = new AccountStore(root);
  const { state, request } = refreshFixture();
  const workspaces = new Workspaces(store, new Documents(root), { remoteRequest: request });
  try {
    const user = await store.createUser('wiki-refresh@example.com', 'correct horse battery staple');
    const account = workspaces.account(user.id);
    Object.assign(account.library, { canvasOrigin, canvasUserID: 42 });
    const canvasRef = { id: 'files:1', kind: 'files', title: 'Canvas notes', version: 'canvas-1' };
    const course = { id: 'math', code: 'MA1301-26H', term: '2026 HØST', canvasOrigin, canvasID: 1, canvasUserID: 42,
      documents: [], threads: [], canvasMaterials: [canvasRef] };
    account.library.courses = [course, { ...course, id: 'archive', code: 'MA1301-25H', term: '2025 HØST' }];
    const time = new Date('2026-10-04T12:00:00Z').getTime();
    await workspaces.refreshMathWiki(account, course.id, time);
    assert.equal(course.documents.length, 2);
    assert.ok(course.canvasMaterials.includes(canvasRef));
    const file = course.documents.find(doc => doc.kind === 'text' && doc.sourceURL.endsWith('.txt'));
    const ids = course.documents.map(doc => doc.id);
    const initial = state.requests;
    await workspaces.refreshMathWiki(account, course.id, time + 119_999);
    assert.equal(state.requests, initial);
    const first = workspaces.refreshMathWiki(account, course.id, time + 120_000);
    const second = workspaces.refreshMathWiki(account, course.id, time + 120_000);
    assert.equal(first, second, 'Open tabs share one in-flight refresh');
    await first;
    assert.deepEqual(course.documents.map(doc => doc.id), ids);
    assert.equal(state.fileGets, 1);
    assert.equal(state.heads, 1);
    file.locallyEditedAt = 1;
    state.page = 2; state.file = 2;
    await workspaces.refreshMathWiki(account, course.id, time + 240_000);
    assert.equal(file.sourceKey, null, 'Local edits remain as a separate saved document');
    assert.equal(course.documents.length, 3);
    assert.ok(course.documents.some(doc => doc.sourceVersion === 'file-2'));
    const checked = course.mathWikiCheckedAt;
    state.failed = true;
    await workspaces.refreshMathWiki(account, course.id, time + 360_000);
    assert.equal(course.mathWikiCheckedAt, checked);
    assert.equal(course.documents.length, 3);
    assert.equal(course.canvasMaterials.length, 3);
    assert.match(course.mathWikiWarnings.join(), /503/);
    const failedRequests = state.requests;
    await workspaces.refreshMathWiki(account, course.id, time + 360_001);
    account.settings.automaticallyUpdateMathWiki = false;
    await workspaces.refreshMathWiki(account, course.id, time + 600_000);
    assert.equal(state.requests, failedRequests);
    assert.equal(account.library.courses[1].mathWikiUpdateAttemptedAt, undefined, 'Inactive archived courses are not polled');
  } finally {
    await workspaces.stop(); store.db.close(); await rm(root, { recursive: true, force: true });
  }
});
function fixture({ failWiki = false, failCanvas = false, changed = false, old = [] } = {}) {
  const requests = [];
  const course = { code: 'MA1301-26H', term: '2026 HØST', canvasOrigin, canvasID: 1, canvasMaterials: old, documents: [] };
  const request = async (url, options) => {
    requests.push({ url: url.href, method: options.method || 'GET' });
    let status = 200, headers = {}, data;
    if (url.origin === canvasOrigin) {
      assert.equal(options.headers.Authorization, 'Bearer private-canvas-token');
      if (failCanvas) { status = 403; data = {}; }
      else if (url.pathname.endsWith('/files')) data = [{ id: 1, filename: 'Canvas.txt', display_name: 'Canvas notes', updated_at: 'v1' }];
      else if (url.pathname.endsWith('/files/1')) data = { id: 1, filename: 'Canvas.txt', url: `${canvasOrigin}/download/1`, updated_at: 'v1' };
      else if (url.pathname.startsWith('/download/')) return { status: 200, headers, data: Buffer.from('Canvas notes') };
      else data = [];
      return { status, headers, data: Buffer.from(JSON.stringify(data)) };
    }
    assert.equal(options.headers?.Authorization, undefined, 'never forward Canvas credentials to the wiki or staff hosts');
    assert.equal(options.headers?.Cookie, undefined);
    if (failWiki) return { status: 503, headers, data: Buffer.alloc(0) };
    if (url.href === `${wiki}/ma1301`) data = html(`<a href='/ma1301/2027h/start'>Next year</a><a href='/ma1301/2026h/start'>2026</a><a href='/ma1301/2025h/start'>2025</a>`);
    else if (url.href === start) data = html(`<h1>2026 Number theory</h1><a href='${pdf}'>Notes</a>
      <a href='/lib/exe/fetch.php?media=ma1301:2026h:notes.pdf&amp;cache=cache'>Same notes</a>
      <a href='/ma1301/2025h/start'>Wrong semester</a><a href='/tma4145/2026h/start'>Other course</a>
      <a class='wikilink2' href='/ma1301/2026h/missing'>Missing</a>
      <a href='/ma1301/2026h/start?do=edit'>Edit</a><script><a href='/ma1301/2026h/evil'>Bad</a></script>`,
      `<a href='/ma1301/2026h/exercises'>Exercises</a>`);
    else if (url.pathname === '/ma1301/2026h/exercises') data = html(`<h1>Exercises</h1>
      <a href='start'>Cycle</a><a href='http://folk.ntnu.no/teacher/exercise.ipynb'>Notebook</a>
      <a href='/_media/ma1301/2020h/exam.pdf'>Explicitly assigned old exam</a>
      <a href='/ma1301/exams'>Shared exam page</a><a href='https://127.0.0.1/private.pdf'>Private</a>`);
    else if (url.pathname === '/ma1301/exams') data = html(`<h1>Exams</h1><a href='${start}'>Back</a>`);
    else if (options.method === 'HEAD') { headers = { etag: changed ? 'v2' : 'v1', 'content-length': '8' }; data = ''; }
    else if (url.href === pdf) { headers = { 'content-type': 'application/pdf' }; data = '%PDF-1.4'; }
    else if (url.pathname === '/teacher/exercise.ipynb') data = '{"cells":[]}';
    else { assert.fail(`Unexpected request: ${url.href}`); }
    return { status, headers, data: Buffer.from(data) };
  };
  const canvas = new Canvas(canvasOrigin, 'private-canvas-token', { request });
  return { canvas, course, requests, request };
}

test('math wiki selects explicit Norwegian/English terms and Canvas code suffixes without guessing the current year', () => {
  for (const term of ['2026 HØST', 'Autumn 2026', 'H2026', '2026h']) assert.deepEqual(mathWikiCourse({ code: 'TMA4145-25H', term }).terms, ['2026h']);
  assert.deepEqual(mathWikiCourse({ code: 'MA1301-25H' }).terms, ['2025h']);
  assert.deepEqual(mathWikiCourse({ code: 'TMA4121', term: '2026 VÅR' }).terms, ['2026v']);
  assert.deepEqual(mathWikiCourse({ code: 'MA1301', term: '2026 HØST|2027 VÅR' }).terms, ['2026h', '2027v']);
  assert.deepEqual(mathWikiCourse({ code: 'MA1301', term: 'Default term' }).terms, []);
  assert.equal(mathWikiCourse({ code: 'TDT4100-26H' }), null);
  assert.equal(mathWikiCourse({ code: 'MA1301-26H', canvasOrigin: 'https://another-university.example' }), null);
});

test('a combined catalog keeps Canvas and crawls the exact wiki semester, navigation, shared pages and linked staff files', async () => {
  const { canvas, course, requests } = fixture();
  const result = await canvas.catalog(course);
  assert.deepEqual(result.warnings, []);
  assert.equal(result.items.filter(r => r.kind === 'files').length, 4);
  assert.equal(result.items.filter(r => r.kind === 'pages').length, 3);
  assert.equal(result.items.filter(r => r.sourceURL === pdf).length, 1);
  assert.ok(result.items.some(r => r.sourceURL.includes('/2020h/exam.pdf')), 'older files explicitly linked by the selected semester are course readings');
  assert.ok(!requests.some(r => /2025h|2027h|tma4145|missing|evil|do=edit|127\.0/.test(r.url)));
  const notebook = result.items.find(r => r.fileName === 'exercise.ipynb');
  assert.equal(notebook.linkedFromTitle, 'Exercises');
  assert.equal(notebook.version, 'v1');
  assert.equal(notebook.byteCount, 8);
  const page = await canvas.material(result.items.find(r => r.sourceURL === start), course);
  assert.match(page.data.toString(), /<base href="https:\/\/wiki.math.ntnu.no\/ma1301\/2026h\/start">/);
  assert.doesNotMatch(page.data.toString(), /<script>/);
  const file = await canvas.material(result.items.find(r => r.sourceURL === pdf), course);
  assert.equal(file.data.toString(), '%PDF-1.4');
  assert.equal((await canvas.material(result.items.find(r => r.id === 'files:1'), course)).data.toString(), 'Canvas notes');
  assert.equal(courseLinkTarget(`${wiki}/lib/exe/fetch.php?media=ma1301:2026h:notes.pdf`, { ...course, canvasMaterials: result.items }).material.sourceURL, pdf);
});

test('wiki failures retain previous wiki entries independently of a complete Canvas refresh', async () => {
  const first = fixture(), before = (await first.canvas.catalog(first.course)).items;
  const next = fixture({ old: before, failWiki: true });
  const result = await next.canvas.catalog(next.course);
  assert.equal(result.items.length, before.length);
  assert.deepEqual(result.changes.removed, []);
  assert.match(result.warnings.join(' '), /Math wiki.*503/);
  const unavailableCanvas = fixture({ failCanvas: true });
  const wikiOnly = await unavailableCanvas.canvas.catalog(unavailableCanvas.course);
  assert.equal(wikiOnly.items.length, 6);
  assert.ok(wikiOnly.items.every(r => r.id.startsWith('math-wiki:')));
  const updated = fixture({ old: before, changed: true });
  assert.ok((await updated.canvas.catalog(updated.course)).changes.updated.includes(`math-wiki:${pdf}`));
});

test('extra Canvas catalogs skip public-site requests while retaining their existing materials', async () => {
  const initial = fixture(), before = (await initial.canvas.catalog(initial.course)).items;
  const next = fixture({ old: before });
  const result = await next.canvas.catalog(next.course, { includePublic: false });
  assert.ok(result.canvasComplete);
  assert.equal(result.mathWikiComplete, false);
  assert.deepEqual(result.items.filter(ref => ref.id.startsWith('math-wiki:')), before.filter(ref => ref.id.startsWith('math-wiki:')));
  assert.ok(next.requests.every(r => new URL(r.url).origin === canvasOrigin));
  assert.ok(!next.requests.some(r => r.url.includes('discussion_topics')));
  assert.deepEqual(result.changes.removed, []);
});

test('unknown semesters skip wiki requests and cross-semester redirects cannot import the wrong archive', async () => {
  let calls = 0;
  const client = new MathWiki({ request: async () => { calls++; return { status: 302, headers: { location: `${wiki}/ma1301/2025h/start` }, data: Buffer.alloc(0) }; } });
  assert.match((await client.catalog({ code: 'MA1301' })).warnings.join(), /semester/);
  assert.equal(calls, 0);
  const result = await client.catalog({ code: 'MA1301-26H' });
  assert.equal(calls, 1);
  assert.equal(result.items.length, 0);
  assert.match(result.warnings.join(), /different course or semester/);
});

test('media aliases deduplicate and unsafe/admin links are excluded', () => {
  assert.equal(mathWikiLink(`${wiki}/_detail/ma1301/2026h/notes.pdf?cache=1`).url, pdf);
  assert.equal(mathWikiLink(`${wiki}/lib/exe/fetch.php?media=${encodeURIComponent('https://folk.ntnu.no/teacher/notes.pdf')}`).url, 'https://folk.ntnu.no/teacher/notes.pdf');
  for (const value of ['javascript:alert(1)', 'https://user:pass@wiki.math.ntnu.no/a.pdf', 'https://ntnu.no.evil.example/a.pdf', `${start}?do=login`, `${start}?rev=123`])
    assert.equal(mathWikiLink(value), null);
});
