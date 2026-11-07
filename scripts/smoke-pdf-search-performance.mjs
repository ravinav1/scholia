import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { chromiumSession, sleep } from './smoke/browser/lib/chromium.mjs';

// Dense, repeated matches exercise the expensive text-layer path, without
// depending on an external textbook or network access. Chromium disables GPU
// acceleration in the shared harness, matching the reported worst case.
const measureOnly = process.argv.includes('--measure');
const root = await mkdtemp(join(tmpdir(), 'scholia-pdf-search-'));
const pages = 40;
const objects = [
  '<< /Type /Catalog /Pages 2 0 R >>',
  `<< /Type /Pages /Kids [${Array.from({ length: pages }, (_, i) => `${4 + i * 2} 0 R`).join(' ')}] /Count ${pages} >>`,
  '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
];
for (let page = 1; page <= pages; page++) {
  const stream = [
    `BT /F1 10 Tf 24 770 Td (Search performance page ${page}) Tj ET`,
    ...Array.from({ length: 60 }, (_, row) =>
      `BT /F1 7 Tf 24 ${750 - row * 12} Td (${'try ry rye dry '.repeat(8)}) Tj ET`)
  ].join('\n');
  objects.push(`<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents ${5 + (page - 1) * 2} 0 R >>`);
  objects.push(`<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`);
}
let pdf = '%PDF-1.4\n';
const offsets = [];
objects.forEach((object, i) => { offsets.push(pdf.length); pdf += `${i + 1} 0 obj\n${object}\nendobj\n`; });
const xref = pdf.length;
pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
pdf += offsets.map(offset => `${String(offset).padStart(10, '0')} 00000 n \n`).join('');
pdf += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
const file = join(root, 'search.pdf');
await writeFile(file, pdf);
let browser;
try {
  browser = await chromiumSession({ extensionPath: resolve('dist/chrome') });
  const { send, evaluate, until, click } = browser;
  const { targetInfos } = await send('Target.getTargets');
  const worker = targetInfos.find(target => target.type === 'service_worker' && target.url.endsWith('/service-worker.js'));
  assert.ok(worker);
  await send('Page.navigate', { url: worker.url.replace('service-worker.js', 'pdf-viewer.html?open=1') });
  await until('document.querySelector("#error")?.hidden === false');
  const { root: doc } = await send('DOM.getDocument');
  const { nodeId } = await send('DOM.querySelector', { nodeId: doc.nodeId, selector: '#pdf-file' });
  await send('DOM.setFileInputFiles', { nodeId, files: [file] });
  await until('/index cached/.test(document.querySelector("#document-status").textContent)', { timeoutMs: 30_000 });
  await click('#search-toggle');
  const search = async (query) => {
    await evaluate(`(() => { const input = document.querySelector('#search-input');
      input.value = ${JSON.stringify(query)}; input.dispatchEvent(new Event('input', { bubbles: true })); })()`);
    await sleep(400);
    await until('document.querySelector(".pdf-search-highlight.is-current")');
  };
  await search('ry');
  await sleep(300);
  const metrics = await evaluate(`(async () => {
    let mutations = 0;
    const observer = new MutationObserver(records => { mutations += records.length; });
    observer.observe(document.querySelector('#pages'), { childList: true, subtree: true });
    const first = document.querySelector('.pdf-search-highlight');
    const started = performance.now();
    for (let i = 0; i < 20; i++) document.querySelector('#search-next').click();
    await new Promise(requestAnimationFrame);
    const elapsed = performance.now() - started;
    mutations += observer.takeRecords().length;
    observer.disconnect();
    return { elapsed, mutations, retainedHighlight: first.isConnected,
      counter: document.querySelector('#search-count').textContent };
  })()`);
  console.log(JSON.stringify({ gpu: 'disabled', navigation: metrics }));
  if (!measureOnly) {
    assert.ok(metrics.retainedHighlight, 'Next result reuses the existing highlight nodes');
    assert.equal(metrics.mutations, 0, 'Navigation only changes the active highlight classes');
    assert.match(metrics.counter, /^21 \/ /);
    assert.ok(metrics.elapsed < 150, 'Twenty result moves stay responsive with GPU disabled');
  }
  await search(' ry ');
  const bounded = await evaluate(`(() => {
    const page = document.querySelector('.pdf-page[data-page-number="1"]');
    return { count: page.querySelectorAll('.pdf-search-highlight').length,
      texts: [...page.querySelectorAll('.pdf-search-highlight')].map(node => node.textContent) };
  })()`);
  if (!measureOnly) {
    assert.equal(bounded.count, 480, 'Spaces exclude try, rye and dry');
    assert.ok(bounded.texts.every(text => text === 'ry'));
    await click('#search-close');
    assert.equal(await evaluate('document.querySelectorAll(".pdf-search-highlight").length'), 0);
  }
  assert.deepEqual(browser.errors, []);
  console.log(`PASS: GPU-disabled PDF search navigation; spaced query has ${bounded.count} highlights on page 1.`);
} finally {
  await browser?.close();
  await rm(root, { recursive: true, force: true });
}
