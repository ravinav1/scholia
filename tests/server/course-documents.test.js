import test from 'node:test';
import assert from 'node:assert/strict';
import { DOMParser } from 'linkedom';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { Canvas } from '../../apps/server/courses/canvas.js';
import { Documents } from '../../apps/server/documents/documents.js';
import {
  courseHTMLDocument,
  htmlReadingText,
  originalDocumentHTML,
  restoreCourseLinks,
  courseLinkTarget,
  safeDocumentURL,
} from '../../packages/core/src/course-documents.js';

const origin = 'https://canvas.example';
const source = `${origin}/courses/24659/pages/week-35-brownian-dynamics-2`;
const body = `<h2>Extra material</h2><p><a class="instructure_file_link" href="/courses/24659/files/1174749?wrap=1">Brown_Brownian.pdf</a></p><a href="https://doi.org/example">Original article</a><script>window.bad = true</script>`;

test('uploaded reading lists preserve absolute paper links without a base URL', () => {
  const html = new DOMParser().parseFromString('<html><body><a href="https://doi.org/10.1136/medethics-2020-107095">Before and beyond trust</a><a href="/relative">Unknown relative source</a></body></html>', 'text/html');
  const text = htmlReadingText(html);
  assert.ok(text.includes('[Before and beyond trust](https://doi.org/10.1136/medethics-2020-107095)'));
  assert.ok(text.includes('Unknown relative source'));
  assert.doesNotMatch(text, /\]\(\/relative\)/);
});
const parse = (html) => new DOMParser().parseFromString(html, 'text/html');

test('Canvas original retains relative and external hyperlinks; its text index retains usable absolute links', async (t) => {
  const canvas = new Canvas(origin, 'fixture', {
    hosts: ['canvas.example'],
    request: async () => ({
      status: 200,
      headers: {},
      data: Buffer.from(
        JSON.stringify({ title: 'Brownian dynamics', url: 'week-35-brownian-dynamics-2', body })
      ),
    }),
  });
  const material = await canvas.material(
    { kind: 'pages', remoteID: 'week-35-brownian-dynamics-2' },
    { canvasID: 24659 }
  );
  assert.match(material.name, /\.html$/);
  assert.match(material.data.toString(), /href="\/courses\/24659\/files\/1174749\?wrap=1"/);
  const root = await mkdtemp(join(tmpdir(), 'scholia-original-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const documents = new Documents(root),
    user = randomUUID();
  const doc = await documents.import(user, material.name, material.data);
  assert.equal(doc.kind, 'text');
  assert.deepEqual(
    await documents.data(user, doc),
    material.data,
    'The original is preserved byte for byte'
  );
  const text = (await documents.index(user, doc)).pages.map((p) => p.text).join('\n');
  assert.match(
    text,
    /\[Brown_Brownian\.pdf\]\(https:\/\/canvas.example\/courses\/24659\/files\/1174749\?wrap=1\)/
  );
  assert.match(text, /\[Original article\]\(https:\/\/doi.org\/example\)/);
  assert.doesNotMatch(text, /window.bad/);
});

test('Brown paper in a legacy weekly page resolves to its saved original, while unavailable known files remain downloadable', () => {
  const weekly = { id: 'week', sourceKey: 'pages:week-35-brownian-dynamics-2' };
  const paper = { id: 'brown', sourceKey: 'files:1174749', kind: 'pdf' };
  const ref = {
    id: paper.sourceKey,
    title: 'Brown_Brownian.pdf',
    linkedFromID: weekly.sourceKey,
    sourceURL: `${origin}/courses/24659/files/1174749`,
  };
  const course = {
    canvasOrigin: origin,
    canvasID: 24659,
    documents: [weekly, paper],
    canvasMaterials: [ref],
  };
  const reading = restoreCourseLinks(
    '# Week\n\nExtra material\n\nBrown_Brownian.pdf',
    course,
    weekly
  );
  assert.match(reading, /\[Brown_Brownian.pdf\]/);
  assert.equal(courseLinkTarget(ref.sourceURL + '?wrap=1', course).document.id, 'brown');
  course.documents.pop();
  assert.equal(courseLinkTarget(ref.sourceURL, course).material.id, paper.sourceKey);
  assert.equal(courseLinkTarget('https://external.example/paper.pdf', course), null);
  assert.equal(restoreCourseLinks('Brown_Brownian.pdf', course, {}), 'Brown_Brownian.pdf');
});

test('original HTML is inert and cannot introduce application actions or unsafe URLs', () => {
  const html = courseHTMLDocument(
    'Week',
    body +
      `<form action="/api/action"><input></form><iframe src="https://example.com"></iframe><a href="javascript:alert(1)" data-action="removeDocument" onclick="alert(1)">Unsafe</a><img src="https://example.com/image.png" onerror="alert(1)"><table><tr><td colspan="2">Detail</td></tr></table>`,
    source
  );
  const safe = originalDocumentHTML(parse(html));
  assert.match(safe, /href="https:\/\/canvas.example\/courses\/24659\/files\/1174749\?wrap=1"/);
  assert.match(safe, /<table>/);
  assert.doesNotMatch(safe, /<script|<form|<iframe|onclick|onerror|javascript:|data-action/);
  for (const url of [
    'javascript:alert(1)',
    'data:text/html,bad',
    'file:///etc/passwd',
    'https://user:secret@example.com',
    null,
    undefined,
    '',
  ])
    assert.equal(safeDocumentURL(url, source), '');
  assert.match(htmlReadingText(parse(html)), /Extra material/);
});
