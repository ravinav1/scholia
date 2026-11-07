import test from 'node:test';
import assert from 'node:assert/strict';
import { Canvas } from '../../apps/server/courses/canvas.js';
import { canvasContentLinks } from '../../apps/server/courses/canvas-content.js';
import { materialInventory } from '../../apps/server/workspaces.js';
import { Workspaces } from '../../apps/server/workspaces.js';
import { Documents } from '../../apps/server/documents/documents.js';
import { mkdtemp, rm } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { onePagePdf } from '../helpers/pdf.js';

const origin = 'https://canvas.example', prefix = '/api/v1/courses/24659';
const pageID = 'week-35-brownian-dynamics-2';
const page = { url: pageID, title: 'Week 35 - Brownian dynamics', updated_at: 'v1', body: `
  <h3>Attachments</h3>
  <a href="/courses/24659/files/1213943?wrap=1" data-api-endpoint="${origin}/api/v1/courses/24659/files/1213943">Slides</a>
  <a href="../files/1213956?wrap=1">Notebook</a>
  <a href="/courses/24659/files/1290422/download">Lecture</a>
  <h4>This week with (partial) answers:</h4><a href="/files/1267641">Answers</a>
  <h4>Extra material</h4><a href="/courses/24659/files/1174749">Brown</a>
  <a data-api-endpoint="/api/v1/files/1174756">Einstein</a>
  <iframe src="/courses/24659/files/1144828/preview"></iframe>
  <a href="/courses/24659/pages/nested?module_item_id=42">More</a>
  <a href="/courses/99/files/900">Another course</a>
  <a href="https://external.example/files/901">External</a>` };
const attachmentIDs = ['1213943', '1213956', '1290422', '1267641', '1174749', '1174756', '1144828'];

function fixture({ failedModule = false, failedPage = false, old = [] } = {}) {
  const paths = [];
  const canvas = new Canvas(origin, 'fixture', { hosts: ['canvas.example'], request: async (url) => {
    paths.push(url.pathname + url.search);
    assert.equal(url.origin, origin);
    if (url.pathname.startsWith('/downloads/')) return { status: 200, headers: {}, data: url.pathname.endsWith('/1213956')
      ? Buffer.from(JSON.stringify({ cells: [{ cell_type: 'markdown', source: ['# Brownian diffusion\nMolecular motion in thermal equilibrium.'] },
        { cell_type: 'code', source: ['raise Exception("Do not execute")'], outputs: [] }] }))
      : Buffer.from(onePagePdf('Brownian diffusion describes random motion. Molecular fluctuations determine displacement and thermal equilibrium.')) };
    let status = 200, body = [], headers = {};
    if (url.pathname === `${prefix}/files`) { status = 403; body = {}; }
    else if (url.pathname === `${prefix}/pages`) body = [{ url: pageID, title: page.title }];
    else if (url.pathname === `${prefix}/modules`) body = [
      ...(failedModule ? [{ id: 9, name: 'Unavailable', position: 1, items_count: 1 }] : []),
      { id: 10, name: 'Weekly Plan', position: 2, items_count: 3, items: [{ type: 'SubHeader', title: 'Partial inline data' }] },
    ];
    else if (url.pathname === `${prefix}/modules/9/items`) { status = 500; body = {}; }
    else if (url.pathname === `${prefix}/modules/10/items`) {
      if (url.searchParams.get('page') === '2') body = [{ type: 'File', content_id: 77, title: 'Direct file', position: 3 }];
      else {
        body = [{ type: 'SubHeader', title: 'Weekly readings', position: 1 },
          { type: 'Page', page_url: pageID, title: page.title, position: 2 }];
        headers.link = `<${origin}${prefix}/modules/10/items?page=2>; rel="next"`;
      }
    } else if (url.pathname === `${prefix}/pages/${pageID}`) { status = failedPage ? 500 : 200; body = page; }
    else if (url.pathname === `${prefix}/pages/nested`) body = { url: 'nested', title: 'Further reading', body:
      `<a href="${pageID}">Cycle</a><a href="/files/88/download">Nested PDF</a>` };
    else if (url.pathname.startsWith(`${prefix}/files/`)) { status = 403; body = {}; }
    else if (url.pathname.startsWith('/api/v1/files/')) {
      const id = url.pathname.split('/').at(-1);
      body = { id, display_name: id === '1213956' ? 'Brownian.ipynb' : `Lecture ${id}.pdf`,
        filename: id === '1213956' ? 'Brownian.ipynb' : `lecture-${id}.pdf`, hidden_for_user: true, updated_at: 'v1', url: `${origin}/downloads/${id}` };
    }
    return { status, headers, data: Buffer.from(JSON.stringify(body)) };
  } });
  return { canvas, paths, course: { canvasID: 24659, documents: [], canvasMaterials: old } };
}

test('course crawl discovers every page attachment, previews and nested pages when the Files tab is disabled', async () => {
  const { canvas, paths, course } = fixture();
  const { items } = await canvas.catalog(course);
  assert.deepEqual(items.filter((ref) => ref.kind === 'files').map((ref) => ref.remoteID).sort(),
    [...attachmentIDs, '77', '88'].sort());
  const pdf = items.find((ref) => ref.id === 'files:1213943');
  assert.equal(pdf.moduleTitle, 'Weekly Plan');
  assert.equal(pdf.linkedFromTitle, page.title);
  assert.equal(pdf.linkedSection, 'Attachments');
  assert.equal(pdf.sourceURL, `${origin}/courses/24659/files/1213943`);
  assert.equal(items.find((ref) => ref.id === 'files:1213956').fileName, 'Brownian.ipynb');
  assert.equal(items.find((ref) => ref.id === 'files:88').moduleID, 10);
  assert.equal(paths.filter((path) => path === `${prefix}/pages/${pageID}`).length, 1, 'cycles do not reread pages');
  assert.ok(paths.some((path) => path.includes('/items?page=2')));
  assert.ok(paths.every((path) => !path.includes('/900') && !path.includes('/901')));
  const inventory = materialInventory({ ...course, canvasMaterials: items });
  assert.equal(inventory.groups.length, 1);
  assert.deepEqual(inventory.groups[0].items.map((item) => item.materialID), [
    `pages:${pageID}`, ...attachmentIDs.map((id) => `files:${id}`), 'pages:nested', 'files:88', 'files:77',
  ]);
  assert.equal(inventory.files.length, 9);
});

test('one failed module does not stop crawling later modules, and failed refreshes retain known groupings', async () => {
  const first = fixture({ failedModule: true });
  const result = await first.canvas.catalog(first.course);
  assert.ok(result.items.some((ref) => ref.id === 'files:1213956'));
  assert.match(result.warnings.join(' '), /Module 9/);
  const next = fixture({ failedPage: true, old: result.items });
  const refreshed = await next.canvas.catalog(next.course);
  const retained = refreshed.items.find((ref) => ref.id === 'files:1213943');
  assert.equal(retained.moduleTitle, 'Weekly Plan');
  assert.equal(retained.linkedFromTitle, page.title);
  assert.deepEqual(refreshed.changes.removed, []);
});

test('Canvas content links deduplicate identities and ignore scripts, foreign courses and credential URLs', () => {
  const links = canvasContentLinks(`<script>"<a href='/files/9'>"</script>
    <a href='/courses/24659/files/1?wrap=1' data-api-endpoint='/api/v1/files/1'>One</a>
    <iframe src=/files/2/preview></iframe><a href='https://user@canvas.example/files/3'>Unsafe</a>
    <a href='/courses/5/pages/no'>No</a><a href='javascript:evil()'>No</a>`, origin, 24659);
  assert.deepEqual(links.map((link) => link.id), ['files:1', 'files:2']);
});

test('Canvas folders and page groups precede the existing content grouping, with no duplicates for saved files', () => {
  const course = { documents: [{ id: 'saved', sourceKey: 'files:1', title: 'Lecture 1', pageCount: 1 }], canvasMaterials: [
    { id: 'files:1', kind: 'files', title: 'Lecture 1', moduleID: 1, moduleTitle: 'Week one', folderID: 2, folderTitle: 'Handouts' },
    { id: 'files:2', kind: 'files', title: 'Lecture 2', linkedFromID: 'pages:extra', linkedFromTitle: 'Extra reading' },
    { id: 'files:3', kind: 'files', title: 'Lecture 3', folderID: 2, folderTitle: 'Handouts' },
    { id: 'files:4', kind: 'files', title: 'Lecture 4' },
  ] };
  const inventory = materialInventory(course);
  assert.deepEqual(inventory.groups.map((group) => group.id), ['module:1', 'canvas-page:pages:extra', 'folder:2', 'lectures']);
  assert.equal(inventory.files.length, 4);
  assert.equal(inventory.groups[0].items[0].documentID, 'saved');
});

test('discovered nested files download and persist searchable PDF and notebook indexes', async () => {
  const root = await mkdtemp(join(tmpdir(), 'scholia-canvas-crawl-'));
  const documents = new Documents(root);
  const workspaces = new Workspaces({}, documents);
  try {
    const { canvas, course, paths } = fixture();
    const account = { id: randomUUID(), library: { courses: [course], canvasUserID: 42 }, settings: {} };
    Object.assign(course, { canvasOrigin: origin, canvasUserID: 42 });
    course.canvasMaterials = (await canvas.catalog(course)).items;
    for (const reference of course.canvasMaterials) await workspaces.fetchMaterial(account, course, reference, canvas);
    for (const id of [...attachmentIDs, '88']) {
      const document = course.documents.find((doc) => doc.sourceKey === `files:${id}`);
      assert.ok(document, `${id} was downloaded`);
      assert.equal(document.kind, id === '1213956' ? 'notebook' : 'pdf');
      const index = await documents.index(account.id, document);
      assert.match(index.pages.map((page) => page.text).join('\n'), /Brownian diffusion/);
      assert.ok((await documents.data(account.id, document)).length > 0, 'original file is saved');
    }
    const downloadCount = paths.filter((path) => path.startsWith('/downloads/')).length;
    for (const reference of course.canvasMaterials) await workspaces.fetchMaterial(account, course, reference, canvas);
    assert.equal(paths.filter((path) => path.startsWith('/downloads/')).length, downloadCount, 'unchanged files reuse the saved index');
    assert.equal(materialInventory(course).files.length, 9, 'downloading does not duplicate entries');
    assert.equal(course.canvasMaterials.find((ref) => ref.id === 'files:1213956').linkedFromTitle, page.title);
  } finally {
    await workspaces.stop();
    await rm(root, { recursive: true, force: true });
  }
});
