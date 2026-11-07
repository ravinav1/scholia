import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { mkdtemp, mkdir, rm, readFile, writeFile } from 'node:fs/promises';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createHostedServer } from '../../../apps/server/server.js';
import { chromiumSession } from './lib/chromium.mjs';
import { onePagePdf } from '../../../tests/helpers/pdf.js';

const root = await mkdtemp(join(tmpdir(), 'scholia-course-browser-'));
const reserve = createServer();
await new Promise((resolve) => reserve.listen(0, '127.0.0.1', resolve));
const port = reserve.address().port;
await new Promise((resolve) => reserve.close(resolve));
const origin = `http://127.0.0.1:${port}`,
  canvasOrigin = 'https://canvas.example';
const body =
  '<h2>Extra material</h2><p><a href="/courses/24659/files/1174749?wrap=1">Brown_Brownian.pdf</a></p><p><a href="https://doi.org/example">Original article</a></p><script>window.injected=true</script>';
const app = createHostedServer({
  root,
  origin,
  canvasHosts: ['canvas.example'],
  remoteRequest: async (url) => ({
    status: 200,
    headers: {},
    data: Buffer.from(
      JSON.stringify(
        url.pathname.endsWith('/assignments')
          ? []
          : {
              title: 'Week 35 - Brownian dynamics',
              url: 'week-35-brownian-dynamics-2',
              body,
              updated_at: '1',
            }
      )
    ),
  }),
  complete: async (payload) => {
    const prompt = payload.messages[0].content;
    if (prompt.startsWith('Assess'))
      return {
        text: JSON.stringify({
          verdict: 'partial',
          correct: 'You identified random motion.',
          issue: 'Explain the mechanism.',
          nextStep: 'Connect the motion to molecular impacts.',
        }),
      };
    return {
      text: JSON.stringify({
        questions: [...prompt.matchAll(/^SOURCE (\d+):/gm)].map((m) => ({
          concept: `Brownian dynamics ${m[1]}`,
          prompt: `Using source ${m[1]}, explain how the observations support the mechanism.`,
          referenceAnswer:
            'Use the recorded observations to support the mechanism, stating the assumptions and explaining the causal connection.',
          rubric: ['States the observation', 'Explains the cause'],
          hints: [
            'Consider the observations',
            'Identify their cause',
            'State the first connection',
          ],
          sourceIndex: Number(m[1]),
          requiresVisual: false,
        })),
      }),
    };
  },
});
let browser;
try {
  const user = await app.store.createUser('practice@example.com', 'correct horse battery staple');
  const account = app.workspaces.account(user.id);
  Object.assign(account.library, { canvasOrigin, canvasUserID: 1 });
  app.store.credential(user.id, `canvas:${canvasOrigin}`, 'fixture-token');
  const course = {
    id: randomUUID(),
    name: 'Bionano',
    code: 'TFY4335',
    canvasID: 24659,
    canvasOrigin,
    canvasUserID: 1,
    documents: [],
    threads: [],
    canvasMaterials: [],
  };
  account.library.courses.push(course);
  const weekly = await app.workspaces.importFile(
    account,
    course,
    'Week 35 - Brownian dynamics.md',
    Buffer.from('# Week 35\n\nExtra material\n\nBrown_Brownian.pdf')
  );
  Object.assign(weekly, {
    sourceKey: 'pages:week-35-brownian-dynamics-2',
    sourceURL: `${canvasOrigin}/courses/24659/pages/week-35-brownian-dynamics-2`,
    sourceVersion: '1',
  });
  let paper;
  if (process.argv.includes('--real-bionano')) {
    const study = join(homedir(), 'Library/Application Support/Scholia/Study');
    const library = JSON.parse(await readFile(join(study, 'library.json'), 'utf8'));
    const saved = library.courses
      .find((c) => c.code?.startsWith('TFY4335'))
      ?.documents.find((d) => d.sourceKey === 'files:1174749');
    assert.ok(saved, 'Saved Brown paper exists');
    paper = {
      ...saved,
      id: randomUUID(),
      fileName: 'Brown_Brownian.pdf',
      indexVersion: 3,
      addedAt: Date.now() / 1000,
    };
    const path = app.documents.directory(user.id, paper.id);
    await mkdir(path, { recursive: true });
    await writeFile(
      join(path, 'original'),
      await readFile(join(study, 'Documents', saved.id, saved.fileName))
    );
    await writeFile(
      join(path, 'index.json'),
      await readFile(join(study, 'Documents', saved.id, 'index.json'))
    );
    course.documents.push(paper);
  } else
    paper = await app.workspaces.importFile(
      account,
      course,
      'Brown_Brownian.pdf',
      Buffer.from(onePagePdf('Brownian motion: observation and mechanism.'))
    );
  Object.assign(paper, {
    sourceKey: 'files:1174749',
    sourceURL: `${canvasOrigin}/courses/24659/files/1174749`,
    sourceVersion: '1',
  });
  course.canvasMaterials = [
    {
      id: weekly.sourceKey,
      kind: 'pages',
      remoteID: 'week-35-brownian-dynamics-2',
      title: weekly.title,
      sourceURL: weekly.sourceURL,
      version: '1',
    },
    {
      id: paper.sourceKey,
      kind: 'files',
      remoteID: '1174749',
      title: 'Brown_Brownian.pdf',
      fileName: 'Brown_Brownian.pdf',
      sourceURL: paper.sourceURL,
      version: '1',
      linkedFromID: weekly.sourceKey,
      linkedFromTitle: weekly.title,
    },
  ];
  app.store.save(account);
  await new Promise((resolve) => app.server.listen(port, '127.0.0.1', resolve));
  browser = await chromiumSession();
  const { send, evaluate, until, click } = browser;
  await send('Emulation.setDeviceMetricsOverride', {
    width: 1440,
    height: 1000,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await send('Page.navigate', { url: origin });
  await until('document.querySelector("#sign-in") && document.readyState === "complete"');
  await evaluate(
    `document.querySelector('[name=email]').value='practice@example.com'; document.querySelector('[name=password]').value='correct horse battery staple'; document.querySelector('#sign-in').requestSubmit()`
  );
  await until('document.querySelector(".study-dashboard")');
  await click(`[data-action=course][data-id="${course.id}"]`);
  await until(`document.querySelector('[data-action=document][data-id="${weekly.id}"]')`);
  await click(`[data-action=document][data-id="${weekly.id}"]`);
  await until(
    `document.querySelector('.original-document-frame')?.contentDocument?.querySelector('a[href*="1174749"]')`,
    { timeoutMs: 20000 }
  );
  assert.equal(
    weekly.id,
    course.documents.find((d) => d.sourceKey === weekly.sourceKey).id,
    'Content upgrade preserves document identity'
  );
  assert.equal(
    await evaluate('document.querySelector(".original-document-frame").contentWindow.injected'),
    undefined
  );
  await evaluate(
    `document.querySelector('.original-document-frame').contentDocument.querySelector('a[href*="1174749"]').click()`
  );
  await until('document.querySelector(".pdfViewer .page canvas")', { timeoutMs: 20000 });
  assert.equal(
    await evaluate('document.querySelectorAll(".pdfViewer .page").length'),
    paper.pageCount
  );
  await mkdir('dist/verification/course-documents', { recursive: true });
  await browser.screenshot('dist/verification/course-documents/brown-original.png');
  await click('[data-action=practiceThis]');
  await until('document.querySelector("#practice-setup")');
  await evaluate(
    `document.querySelector('[name=sourceScope]').value='course'; document.querySelector('[name=practiceStyle]').value='exam'; document.querySelector('#practice-setup').requestSubmit()`
  );
  await until('document.querySelector("#practice-answer")', { timeoutMs: 20000 });
  assert.equal(await evaluate('!!document.querySelector(".practice-solution")'), false);
  await evaluate(
    `const answer=document.querySelector('#practice-answer'); answer.value='Random impacts lead to irregular movement.'; answer.dispatchEvent(new Event('input',{bubbles:true})); document.querySelector('#practice-answer-form').requestSubmit()`
  );
  await until('document.querySelector(".practice-attempt")?.textContent.includes("partial")');
  await click('[data-practice=reveal]');
  await until('document.querySelector(".practice-solution")');
  await click('[data-practice=finish]');
  await until('document.querySelector(".practice-body h2")?.textContent === "Session recap"');
  await click('[data-practice=setup]');
  await until('document.querySelector(".course-practice-coverage")?.textContent.includes("1 of")');
  await browser.screenshot('dist/verification/course-documents/course-practice.png');
  await send('Emulation.setDeviceMetricsOverride', {
    width: 390,
    height: 844,
    deviceScaleFactor: 1,
    mobile: true,
  });
  assert.equal(await evaluate('document.documentElement.scrollWidth > innerWidth'), false);
  await browser.screenshot('dist/verification/course-documents/course-practice-mobile.png');
  assert.deepEqual(browser.errors, []);
  console.log(
    `Chromium passed: original HTML, Brown PDF (${paper.pageCount} pages), course exam practice, persisted feedback, coverage and mobile layout.`
  );
} catch (error) {
  console.error(
    await browser?.evaluate(
      '({location:location.pathname, text:document.body.innerText.slice(0,1800)})'
    )
  );
  console.error(browser?.errors);
  throw error;
} finally {
  await browser?.close();
  await app.close();
  await rm(root, { recursive: true, force: true });
}
