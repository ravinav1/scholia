import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { chromiumSession } from './lib/chromium.mjs';
import { parseExamImport } from '../packages/core/src/exam-planner.js';

const source = await readFile(new URL('../apps/macos/Sources/ScholiaMac/StudentwebImport.swift', import.meta.url), 'utf8');
const script = source.match(/static let script = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const browser = await chromiumSession();
try {
  const { evaluate, send } = browser;
  const { frameTree } = await send('Page.getFrameTree');
  await send('Page.setDocumentContent', { frameId: frameTree.frame.id, html: `<!doctype html><html><head><style>
  .hidden-by-css { display: none; } .invisible { visibility: hidden; }
  .fristPanel { height: 150px; overflow: auto; } td { padding: 20px; }
  </style></head><body><input value="secret"><h1>Studentweb</h1>
  <div class="fristPanel"><h2>Kommende hendelser (5)</h2><table><thead><tr><th><span class="ui-column-title">Dato</span></th><th><span class="ui-column-title">Emne</span></th><th><span class="ui-column-title">Informasjon</span></th></tr></thead><tbody>
  <tr class="hidden-by-css"><td>01.12.2026</td><td>TDT4186</td><td>Exam</td></tr>
  <tr><td><span class="invisible">01.12.2026</span>Not announced</td><td>TDT4186</td><td>Exam</td></tr>
  <tr><td>10.12.2026<br>09:00–13:00</td><td>TET5100</td><td>Skriftlig skoleeksamen<div class="hidden-by-css">Eksamen 01.12.2026 kl 23:00</div></td></tr>
  <tr><td>11.12.2026<br>09:00</td><td>TMA4100</td><td>Written exam<p>Varighet: 4 timer</p><p>Sensurfrist: 01.01.2027</p></td></tr>
  <tr><td><details><summary>Show hidden dates</summary>01.12.2026</details></td><td>TDT4186</td><td>Exam</td></tr>
  </tbody></table></div><button onclick="throw Error('Must never be clicked')">Load more</button></body></html>` });
  const read = (path = 'start.jsf') => evaluate(`new Function('document', 'location', ${JSON.stringify(script)})(document, new URL('https://fsweb.no/studentweb/${path}'))`);
  const text = await read();
  assert.doesNotMatch(text, /01\.12|secret|23:00|01\.01/);
  const exams = JSON.parse(text).rows.flatMap(row => parseExamImport(row.tokens).exams);
  assert.deepEqual(exams.map(e => [e.courseCode, e.date, e.startTime, e.endTime]), [
    ['TET5100', '2026-12-10', '09:00', '13:00'],
    ['TMA4100', '2026-12-11', '09:00', '13:00'],
  ]);
  assert.equal(await read('aktiveemner.jsf'), '');
  assert.equal(await read('login.jsf'), '');
  await evaluate(`document.querySelectorAll('tbody tr')[2].remove()`);
  assert.deepEqual(JSON.parse(await read()).rows.flatMap(row => parseExamImport(row.tokens).exams).map(e => e.courseCode), ['TMA4100'], 'Removed rows cannot remain in a later snapshot');
  assert.equal(await evaluate('document.querySelector("details").open'), false);
  assert.deepEqual(browser.errors, []);
  console.log('PASS: Chromium opening-page extraction, CSS visibility, scrolling, row association, hidden dates, no navigation/expansion and snapshot refresh');
} finally {
  await browser.close();
}
