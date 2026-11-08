import test from 'node:test';
import assert from 'node:assert/strict';
import { canvasCourseFromUrl, canvasIndexKey, canvasNextPage, buildCanvasCourseIndex, canvasCourseContext } from '../../apps/chrome/src/canvas-course.js';
import { canvasDocumentLinks } from '../../packages/core/src/canvas-links.js';
import { DOMParser } from 'linkedom';
import { researchLinksFromDocument } from '../../apps/chrome/src/research-links.js';

const canvasContentLinks = (html, origin, courseID, sourceURL) => canvasDocumentLinks(
  new DOMParser().parseFromString(`<html><body>${html || ''}</body></html>`, 'text/html'),
  origin, courseID, sourceURL
);

const course = canvasCourseFromUrl('https://school.instructure.com/courses/42/pages/overview?secret=hidden');

test('Canvas preserves external module, syllabus and page links for prompt-driven research, including cached pages', async () => {
  const options = { course, userId: 7, courseInfo: { name: 'Physics', syllabus_body: '<a href="https://wiki.test/syllabus">Syllabus</a>' },
    htmlToText: html => html.replace(/<[^>]+>/g, ''),
    htmlToResearchLinks: (html, url) => researchLinksFromDocument(new DOMParser().parseFromString(html, 'text/html'), url),
    list: async path => path.endsWith('/pages') ? [{ url: 'week1', title: 'Week 1', updated_at: 'v1' }]
      : path.includes('/modules?') ? [{ id: 1, items_count: 1, items: [{ type: 'ExternalUrl', title: 'Course website', external_url: 'https://course.test/physics' }] }] : [],
    get: async () => ({ body: '<a href="https://wiki.test/diffusion?chapter=2">Diffusion notes</a>' }), readFile: async () => '' };
  const first = await buildCanvasCourseIndex(options);
  const second = await buildCanvasCourseIndex({ ...options, previous: first });
  assert.equal(second.reused, 1);
  assert.equal(second.researchLinks[0].url, 'https://course.test/physics');
  assert.equal(second.documents.find(doc => doc.key === 'syllabus').researchLinks[0].url, 'https://wiki.test/syllabus');
  assert.equal(second.documents.find(doc => doc.key === 'page:week1').researchLinks[0].url, 'https://wiki.test/diffusion?chapter=2');
});

test('Canvas identity separates course, host and account; pagination stays on its API route', () => {
  assert.deepEqual(course, { courseId: '42', origin: 'https://school.instructure.com', url: 'https://school.instructure.com/courses/42' });
  assert.notEqual(canvasIndexKey(course, 1), canvasIndexKey(course, 2));
  const route = `${course.origin}/api/v1/courses/42/pages`;
  assert.equal(canvasNextPage(`<${route}?page=2>; rel="next"`, route, course), `${route}?page=2`);
  assert.equal(canvasNextPage('<https://evil.test/api/v1/courses/42/pages>; rel="next"', route, course), '');
  assert.equal(canvasNextPage(`<${course.origin}/api/v1/courses/99/pages>; rel="next"`, route, course), '');
});

test('course indexing discovers module-only files, omits locked content, and incrementally replaces changed/deleted sources', async () => {
  let revision = 'v1';
  let downloads = 0;
  const calls = [];
  const options = {
    course, userId: 7, courseInfo: { name: 'Physics', syllabus_body: 'Exam covers entropy' },
    htmlToText: (html) => html,
    list: async (path) => {
      calls.push(path);
      if (path.endsWith('/pages')) return [{ url: 'entropy', title: 'Entropy', updated_at: revision }, ...(revision === 'v1' ? [{ url: 'old', title: 'Old material', updated_at: 'v1' }] : [])];
      if (path.endsWith('/files')) throw new Error('Files tab hidden');
      if (path.includes('/modules?')) return [{ id: 1, name: 'Week one', items_count: 2, items: [{ type: 'File', content_id: 9, title: 'Lecture' }, { type: 'File', content_id: 10, title: 'Locked' }] }];
      return [];
    },
    get: async (path) => {
      calls.push(path);
      if (path.endsWith('/files/9')) return { id: 9, display_name: 'Lecture.pdf', updated_at: 'v1' };
      if (path.endsWith('/files/10')) return { id: 10, locked_for_user: true };
      return { body: path.endsWith('/old') ? 'Deleted later' : `Entropy lecture revision ${revision}` };
    },
    readFile: async () => { downloads += 1; return 'Entropy measures the number of microscopic states.'; }
  };
  const first = await buildCanvasCourseIndex(options);
  assert.equal(downloads, 1);
  assert.equal(first.documents.length, 4);
  assert.ok(calls.every((path) => path.startsWith('/api/v1/courses/42/')));
  assert.ok(!first.documents.some((doc) => doc.key === 'file:10'));
  const cached = await buildCanvasCourseIndex({ ...options, previous: first });
  assert.equal(downloads, 1);
  assert.equal(cached.reused, 3);
  revision = 'v2';
  const updated = await buildCanvasCourseIndex({ ...options, previous: first });
  assert.ok(!updated.documents.some((doc) => doc.key === 'page:old'));
  assert.match(updated.documents.find((doc) => doc.key === 'page:entropy').text, /v2/);
  assert.match(canvasCourseContext(updated, { question: 'What is entropy?' }), /microscopic states/);
});

test('transient listing and download failures retain stale sources; confirmed removal deletes them', async () => {
  const options = {
    course, userId: 7, courseInfo: { name: 'Physics' }, htmlToText: (s) => s,
    list: async (path) => path.endsWith('/files') ? [{ id: 1, updated_at: 'v1', title: 'Saved' }] : [],
    get: async () => ({}), readFile: async () => 'Saved source content'
  };
  const first = await buildCanvasCourseIndex(options);
  const failedList = await buildCanvasCourseIndex({ ...options, previous: first, list: async (path) => { if (path.endsWith('/files')) throw Object.assign(new Error('Unavailable'), { status: 503 }); return []; } });
  assert.equal(failedList.documents[0].stale, true);
  assert.equal(failedList.skipped, 1);
  assert.match(canvasCourseContext(failedList), /may be stale/);
  const failedDownload = await buildCanvasCourseIndex({ ...options, previous: first, list: async (path) => path.endsWith('/files') ? [{ id: 1, updated_at: 'v2' }] : [], readFile: async () => { throw new Error('Network'); } });
  assert.equal(failedDownload.documents[0].version, first.documents[0].version);
  assert.equal(failedDownload.documents[0].stale, true);
  const removed = await buildCanvasCourseIndex({ ...options, previous: first, list: async () => [] });
  assert.equal(removed.documents.length, 0);
  const denied = await buildCanvasCourseIndex({ ...options, previous: first, list: async (path) => path.endsWith('/files') ? [{ id: 1, updated_at: 'v2' }] : [], readFile: async () => { throw Object.assign(new Error('Access revoked'), { status: 403 }); } });
  assert.equal(denied.documents.length, 0);
});

test('deadline-only assignment changes refresh indexed context', async () => {
  let due = '2026-10-01';
  const options = { course, userId: 7, courseInfo: {}, htmlToText: (s) => s, readFile: async () => '', get: async () => ({}),
    list: async (path) => path.endsWith('/assignments') ? [{ id: 3, updated_at: 'unchanged', name: 'Problem set', description: 'Justify your answer', due_at: due }] : [] };
  const first = await buildCanvasCourseIndex(options); due = '2026-10-08';
  const next = await buildCanvasCourseIndex({ ...options, previous: first });
  assert.match(next.documents[0].text, /2026-10-08/);
  assert.notEqual(first.documents[0].version, next.documents[0].version);
});

test('extension downloads and indexes nested page attachments and rediscovers them from cached pages', async () => {
  let downloads = 0;
  const calls = [];
  const options = {
    course, userId: 7, courseInfo: {}, htmlToText: (html) => html.replace(/<[^>]+>/g, ''),
    htmlToLinks: (html, url) => canvasContentLinks(html, course.origin, course.courseId, url),
    list: async (path) => path.endsWith('/pages') ? [{ url: 'week35', title: 'Week 35', updated_at: 'v1' }] : [],
    get: async (path) => {
      calls.push(path);
      if (path.endsWith('/pages/week35')) return { body: '<a href="/courses/42/pages/more">Nested page</a><iframe src="/courses/42/files/1/preview"></iframe>' };
      if (path.endsWith('/pages/more')) return { title: 'More', updated_at: 'v1', body: '<a href="week35">Cycle</a><a href="/files/2?wrap=1">Notebook</a>' };
      if (path.startsWith('/api/v1/courses/42/files/')) throw Object.assign(new Error('Files tab disabled'), { status: 403 });
      return { id: path.split('/').at(-1), updated_at: 'v1', hidden_for_user: true, filename: path.endsWith('/2') ? 'lab.ipynb' : 'notes.pdf' };
    },
    readFile: async (item) => { downloads++; return `Brownian diffusion from ${item.filename}`; },
  };
  const first = await buildCanvasCourseIndex(options);
  assert.equal(downloads, 2);
  assert.deepEqual(first.documents.map((doc) => doc.key).sort(), ['file:1', 'file:2', 'page:more', 'page:week35']);
  assert.match(canvasCourseContext(first), /Brownian diffusion from lab.ipynb/);
  assert.equal(calls.filter((path) => path.endsWith('/pages/week35')).length, 1);
  const second = await buildCanvasCourseIndex({ ...options, previous: first });
  assert.equal(downloads, 2, 'unchanged attachments are indexed once');
  assert.equal(second.documents.length, 4, 'cached pages retain their attachment links');
  assert.equal(second.reused, 4);
});
