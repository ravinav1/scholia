import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createHostedServer } from '../apps/server/server.js';
import { onePagePdf } from '../tests/helpers/pdf.js';
import { chromiumSession } from './lib/chromium.mjs';

const root = await mkdtemp(join(tmpdir(), 'scholia-pdf-download-'));
const reserve = createServer();
await new Promise((resolve) => reserve.listen(0, '127.0.0.1', resolve));
const port = reserve.address().port;
await new Promise((resolve) => reserve.close(resolve));
const origin = `http://127.0.0.1:${port}`,
  app = createHostedServer({ root, origin });
let browser;
try {
  const user = await app.store.createUser('pdf@example.com', 'correct horse battery staple');
  const session = app.store.session(
    (await app.store.login('pdf@example.com', 'correct horse battery staple')).value
  );
  await app.workspaces.action(session, {
    action: 'create',
    name: 'Linear algebra',
    code: 'TMA4115',
  });
  const account = app.workspaces.account(user.id),
    course = account.library.courses[0];
  const bytes = Buffer.from(onePagePdf('Linear algebra: vectors and matrices.'));
  const fixtures = [
    { name: 'Lecture notes.pdf', expected: 'Lecture notes.pdf' },
    { name: 'Øving 3.pdf', stored: 'original.pdf', expected: 'Øving 3.pdf' },
    {
      name: 'Legacy exercise.pdf',
      stored: 'original.pdf',
      legacy: true,
      sourceKey: 'files:42',
      expected: 'Exercise 4 - vectors.pdf',
    },
    {
      name: 'Eigenvectors.pdf',
      title: 'Eigenvectors.pdf',
      stored: 'original.pdf',
      legacy: true,
      expected: 'TMA4115 - Eigenvectors.pdf',
    },
    {
      name: 'linear_maps.py',
      stored: 'original.py',
      data: Buffer.from('print("Linear maps")\n'),
      expected: 'linear_maps.py',
    },
  ];
  course.canvasMaterials = [
    {
      id: 'files:42',
      kind: 'files',
      remoteID: '42',
      title: 'Exercise 4',
      fileName: 'Exercise 4 - vectors.pdf',
    },
  ];
  for (const fixture of fixtures) {
    fixture.bytes = fixture.data || bytes;
    const doc = await app.documents.import(user.id, fixture.name, fixture.bytes);
    if (fixture.stored) doc.fileName = fixture.stored;
    if (fixture.legacy) delete doc.originalFileName;
    if (fixture.sourceKey) doc.sourceKey = fixture.sourceKey;
    if (fixture.title) doc.title = fixture.title;
    fixture.doc = doc;
    course.documents.push(doc);
  }
  app.store.save(account);
  await new Promise((resolve) => app.server.listen(port, '127.0.0.1', resolve));
  browser = await chromiumSession();
  const { send, evaluate, until, click } = browser;
  const downloads = join(root, 'downloads');
  await mkdir(downloads);
  await send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: downloads });
  await send('Emulation.setDeviceMetricsOverride', {
    width: 1460,
    height: 960,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await send('Page.navigate', { url: origin });
  await until('document.querySelector("#sign-in")');
  await evaluate(
    `document.querySelector('[name=email]').value='pdf@example.com'; document.querySelector('[name=password]').value='correct horse battery staple'; document.querySelector('#sign-in').requestSubmit()`
  );
  await until('document.querySelector(".study-dashboard")');
  await mkdir(resolve('dist/verification'), { recursive: true });
  for (const fixture of fixtures) {
    const { doc } = fixture;
    await click(`[data-action=course][data-id="${course.id}"]`);
    await until(
      `!document.querySelector('.pdfViewer') && document.querySelector('[data-action=document][data-id="${doc.id}"]')`
    );
    await click(`[data-action=document][data-id="${doc.id}"]`);
    const button = doc.kind === 'pdf' ? '[data-pdf=download]' : '[data-action=downloadOriginal]';
    if (doc.kind === 'pdf') {
      await until(
        'document.querySelector(".pdfViewer .page canvas") && document.querySelectorAll(".textLayer span").length > 0'
      );
    } else await until(`document.querySelector('${button}')`);
    assert.equal(await evaluate(`document.querySelector('${button}').closest('details')`), null);
    assert.equal(
      await evaluate(`document.querySelector('${button}').getBoundingClientRect().width > 0`),
      true
    );
    if (fixture === fixtures[0])
      await browser.screenshot(resolve('dist/verification/pdf-download.png'));
    await click(button);
    let downloaded;
    for (let i = 0; i < 100; i++) {
      try {
        downloaded = await readFile(join(downloads, fixture.expected));
        break;
      } catch {}
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    assert.deepEqual(
      downloaded,
      fixture.bytes,
      `Download saves unchanged bytes as ${fixture.expected}`
    );
  }
  assert.deepEqual(browser.errors, []);
  console.log(
    'Download Chromium smoke passed: original names, legacy Canvas names, course/title fallback, PDF and code bytes.'
  );
} catch (error) {
  console.error('Browser errors:', JSON.stringify(browser?.errors || []));
  if (browser) console.error(await browser.evaluate('document.body.innerText.slice(0, 2500)'));
  throw error;
} finally {
  await browser?.close();
  await app.close();
  await rm(root, { recursive: true, force: true });
}
