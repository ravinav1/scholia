import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DOMParser } from 'linkedom';
import { parseExamImport } from '../packages/core/src/exam-planner.js';

// Exercise the exact extraction program embedded in the native app.
const source = readFileSync(new URL('../apps/macos/Sources/ScholiaMac/StudentwebImport.swift', import.meta.url), 'utf8');
const script = source.match(/static let script = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const extract = new Function('document', 'location', script);
const page = (html, url = 'https://fsweb.no/studentweb/start.jsf') => extract(
  new DOMParser().parseFromString(`<html><body>${html}</body></html>`, 'text/html'), new URL(url)
);
const parsePage = text => ({ exams: JSON.parse(text || '{"rows":[]}').rows.flatMap(({tokens, component}) => parseExamImport(tokens).exams.map(exam => ({...exam, component, kind: component === 'Midterm' ? 'midterm' : ['Final exam', 'Oral exam', 'Home exam'].includes(component) ? 'final' : 'other'}))) });
const row = (code, date, info = 'Skriftlig skoleeksamen') => `<tr><td>${date}</td><td>${code}</td><td>${info}</td></tr>`;
const table = (rows, heading = 'Kommende hendelser (3)') => `<div class="fristPanel"><div class="ui-datatable-header">${heading}</div><table><thead><tr><th><span class="ui-column-title">Dato</span></th><th><span class="ui-column-title">Emne</span></th><th><span class="ui-column-title">Informasjon</span></th></tr></thead><tbody>${rows}</tbody></table></div>`;
const fixture = `<nav><a href="/studentweb/aktiveEmner.jsf">Aktive emner</a></nav>
<div>Private Person 01010112345 private@example.com</div><input type="password" value="never-read-this">
${table(row('TET5100 Electromagnetic Analysis', '10.12.2026<br>09:00', '<p>Skriftlig skoleeksamen</p><p>Varighet: 4 timer</p><p>Kandidatnummer: 98765</p><p>Sensurfrist: 30.12.2026</p>') + row('TET5100', '14.10.2026<br>12:00–14:00', 'Midterm') + row('TMA4100 Calculus', '10. desember 2026<br>13:00–17:00'))}
<form id="aktiveEmnerForm"><h3>TDT4186</h3><div class="vurdkombTre">Final exam 01.12.2026 09:00–13:00</div></form>`;

test('oral labels survive exam periods and do not match words inside course titles', () => {
  const result = JSON.parse(page(table([
    row('MA8107 Operatoralgebraiske metoder for kvanteinformasjon', '15.12.2026', '<p>Eksamen:</p><p>15.12.2026.</p>'),
    row('TEST1000 Topologi. Muntlig eksamen', '', '<p>Eksamensperiode:</p><p>26.11.2026 til 27.11.2026.</p>'),
  ].join(''))));
  assert.equal(result.rows[0].component, 'Exam');
  assert.equal(result.rows[1].component, 'Oral exam');
  assert.match(result.rows[1].tokens, /26\.11\.2026 – 27\.11\.2026/);
});

test('opening-page extraction reads only explicit dates in visible upcoming exam rows', () => {
  const text = page(fixture);
  for (const url of ['https://fsweb.no/studentweb/', 'https://fsweb.no/studentweb', 'https://fsweb.no/studentweb/index.jsf', 'https://fsweb.no/studentweb/forside.jsf', 'https://fsweb.no/studentweb/forsiden.jsf']) assert.equal(page(fixture, url), text);
  assert.doesNotMatch(text, /Private|12345|98765|@|password|secret|Karakter|Electromagnetic|TDT4186|01\.12|30\.12/);
  const { exams } = parsePage(text);
  assert.equal(exams.length, 3);
  assert.equal(exams[0].courseCode, 'TET5100');
  assert.equal(exams[0].endTime, '13:00');
  assert.equal(exams[1].kind, 'midterm');
  assert.equal(exams[2].courseCode, 'TMA4100');
  assert.equal(exams[2].date, '2026-12-10');
});

test('Active courses, login, other pages and deceptive origins are never imported', () => {
  for (const url of [
    'https://fsweb.no/studentweb/aktiveEmner.jsf', 'https://fsweb.no/studentweb/aktiveemner.jsf',
    'https://fsweb.no/studentweb/login.jsf', 'https://fsweb.no/studentweb/resultater.jsf',
    'https://fsweb.no.evil.test/studentweb/start.jsf', 'http://fsweb.no/studentweb/start.jsf',
    'https://fsweb.no:444/studentweb/start.jsf', 'https://idp.feide.no/studentweb/start.jsf',
    'https://user:secret@fsweb.no/studentweb/start.jsf',
  ]) assert.equal(page(fixture, url), '');
  assert.equal(JSON.parse(page('<main>TET5100 Final exam 10.12.2026 09:00–13:00</main>')).rows.length, 0);
  assert.equal(JSON.parse(page(table(row('TET5100', '10.12.2026'), 'Aktive emner'))).rows.length, 0);
  assert.doesNotMatch(source, /expansionScript|\.click\(|Reading Active courses|routed =|collected\[/);
});

test('hidden and collapsed rows never contribute dates, even with a visible course code', () => {
  const text = page(table([
    '<tr hidden><td>01.12.2026</td><td>TDT4186</td><td>Exam</td></tr>',
    '<tr style="display: none"><td>02.12.2026</td><td>TDT4186</td><td>Exam</td></tr>',
    '<tr aria-hidden="true"><td>03.12.2026</td><td>TDT4186</td><td>Exam</td></tr>',
    row('TDT4186', '<span hidden>04.12.2026</span>Unknown'),
    row('TDT4186', '<span style="visibility:hidden">05.12.2026</span>'),
    row('TDT4186', '<details><summary>More</summary>06.12.2026</details>'),
    row('TDT4137', '10.12.2026 12:00', '<p>Midtsemesterprøve</p><p>Varighet: 3t 30min</p><dl hidden><dd>Eksamen: 01.12.2026 kl 09:00</dd></dl>'),
  ].join('')));
  const { exams } = parsePage(text);
  assert.equal(exams.length, 1);
  assert.equal(exams[0].courseCode, 'TDT4137');
  assert.equal(exams[0].kind, 'midterm');
  assert.equal(exams[0].endTime, '15:30');
  assert.doesNotMatch(text, /01\.12|09:00/);
});

test('withdrawal and result deadlines, yearless dates and other cells cannot supply exam dates', () => {
  const text = page(table([
    row('TDT4186', '<p>Trekkfrist</p><p>01.12.2026</p>'),
    row('TDT4186', 'Sensurfrist: 01.12.2026'),
    row('TDT4186', '01.12'),
    row('TDT4186', 'Not announced', 'An unrelated event 01.12.2026'),
    row('TDT4186 01.12.2026', 'Not announced'),
    row('TDT4186', '01.12.2026', 'Semesterregistrering'),
    row('TDT4186 TMA4100', '01.12.2026'),
    row('TET5100', '10.12.2026', '<p>Eksamen</p><p>Trekkfrist</p><p>01.12.2026 23:59</p><p>Kandidatnr</p><p>98765</p>'),
  ].join('')));
  assert.doesNotMatch(text, /01\.12|23:59|98765/);
  const { exams } = parsePage(text);
  assert.equal(exams.length, 1);
  assert.equal(exams[0].date, '2026-12-10');
  assert.equal(exams[0].startTime, '');
  assert.equal(exams[0].endTime, '');
});

test('table headings bind each date to its course regardless of column order', () => {
  const text = page(`<section><h2>Upcoming events</h2><table>
  <tr><th>Course</th><th>Information</th><th>Date</th></tr>
  <tr><td>TET5100</td><td>Written exam</td><td>2026-12-10<br>09:00–13:00</td></tr>
  <tr><td>TDT4186</td><td>Exam 2026-12-01</td><td>Not announced</td></tr>
  </table></section>${table(row('TMA4100', '01.12.2026'), 'Other dates')}`);
  const { exams } = parsePage(text);
  assert.equal(exams.length, 1);
  assert.equal(exams[0].courseCode, 'TET5100');
  assert.equal(exams[0].endTime, '13:00');
  assert.equal(page(fixture), page(fixture), 'Reads do not mutate or expand the page');
});

test('every opening-page assessment remains a separate row, including releases, hand-ins and exam periods', () => {
  const ordinary = Array.from({length: 84}, (_, i) => row(`TEST${1000 + i}`, '10.12.2026', '<dl><dt>Eksamen:</dt><dd>10.12.2026 kl 09:00 - 4t ordinær tid.</dd><dt>Oppmøte:</dt><dd>30 minutter før start på eksamen.</dd><dt>Kandidatnr:</dt><dd>98765.</dd></dl>')).join('');
  const extra = row('TDT4173', '11.11.2026', '<div>Innleveringsfrist:</div><div>11.11.2026 kl 14:00</div>')
    + row('MEDT8002', '18.11.2026', '<div>Uttak:</div><div>18.11.2026 kl 09:00</div>')
    + row('TDT4195', '19.11.2026', '<div>Innleveringsfrist:</div><div>19.11.2026 kl 14:00</div>')
    + row('TFE4141', '20.11.2026', '<div>Innleveringsfrist:</div><div>20.11.2026 kl 23:59</div>')
    + row('KLMED8020', '23.11.2026', '<div>Uttak:</div><div>23.11.2026 kl 08:00</div>')
    + row('KLMED8009', '07.12.2026', '<div>Uttak:</div><div>07.12.2026 kl 08:00</div>')
    + row('MA3408', '', '<div>Eksamensperiode:</div><div>26.11.2026 til 27.11.2026.</div>');
  const text = page(table(ordinary + extra, 'Kommende hendelser (91)'));
  const snapshot = JSON.parse(text), { exams } = parsePage(text);
  assert.equal(snapshot.sourceCount, 91);
  assert.equal(snapshot.rows.length, 91);
  assert.equal(exams.length, 91);
  assert.equal(exams[0].startTime, '09:00');
  assert.equal(exams[0].endTime, '13:00', 'Arrival instructions are not an exam duration');
  assert.equal(exams[84].component, 'Submission deadline');
  assert.equal(exams[84].startTime, '14:00');
  assert.equal(exams[85].component, 'Exam release');
  assert.equal(exams.at(-1).date, '2026-11-26');
  assert.equal(exams.at(-1).endDate, '2026-11-27');
  assert.doesNotMatch(text, /98765|Kandidat|Oppmøte/);
});

test('same-course rows and identical-looking components are preserved without inventing durations', () => {
  const info = '<p>Uttak:</p><p>18.11.2026 kl 09:00</p>';
  const text = page(table(row('MEDT8002', '18.11.2026', info + '<p>Innleveringsfrist:</p><p>18.11.2026 kl 11:00</p>')
    + row('MEDT8002', '18.11.2026', info) + row('MEDT8002', '18.11.2026', info)
    + row('TMA4100', '19.11.2026', '<p>Eksamen:</p><p>19.11.2026 kl 09:00</p><p>Oppmøte:</p><p>30 minutter før start på eksamen.</p>')));
  const { exams } = parsePage(text);
  assert.equal(exams.length, 4);
  assert.deepEqual(exams.slice(0, 3).map(e => [e.component, e.startTime, e.endTime]), [
    ['Exam window', '09:00', '11:00'], ['Exam release', '09:00', ''], ['Exam release', '09:00', ''],
  ]);
  assert.equal(exams[3].endTime, '', 'No duration is inferred from arrival guidance');
});
