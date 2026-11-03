import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { DOMParser } from 'linkedom';

const source = readFileSync(new URL('../apps/macos/Sources/ScholiaMac/StudentwebResults.swift', import.meta.url), 'utf8');
const script = source.match(/static let script = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const extract = new Function('document', 'location', script);
const page = (html, url = 'https://fsweb.no/studentweb/resultater.jsf') => extract(
  new DOMParser().parseFromString(`<html><body>${html}</body></html>`, 'text/html'), new URL(url)
);
const row = (code, grade, credits = '7,5', extra = '') => `<tr ${extra}><td>${code}</td><td>${grade}</td><td>${credits}</td></tr>`;
const table = (rows, heading = 'Mine resultater') => `<section><h2>${heading}</h2><table><tr><th>Emne</th><th>Karakter</th><th>Studiepoeng</th></tr>${rows}</table></section>`;
const read = html => JSON.parse(page(html));

test('only canonical course codes and real booleans cross the results bridge', () => {
  const html = `<div>SECRET_IDENTITY 12345678901 secret@example.invalid</div><input value="SECRET_LOGIN">`
    + table(row('TDT4100 SECRET_TITLE', 'A') + row('TMA4100', 'Bestått') + row('TFE4100', 'F', '0'));
  const encoded = page(html);
  assert.deepEqual(JSON.parse(encoded), [
    { courseCode: 'TDT4100', passed: true }, { courseCode: 'TFE4100', passed: false }, { courseCode: 'TMA4100', passed: true }
  ]);
  assert.doesNotMatch(encoded, /SECRET|12345678901|@|grade|karakter|credits|name|date|login/i);
});

test('results origin and path are exact; login, exam dates and deceptive origins fail closed', () => {
  for (const url of [
    'https://fsweb.no/studentweb/start.jsf', 'https://fsweb.no/studentweb/',
    'https://fsweb.no/studentweb/login.jsf', 'https://fsweb.no/studentweb/resultater.jsf/extra',
    'https://fsweb.no.evil.test/studentweb/resultater.jsf', 'http://fsweb.no/studentweb/resultater.jsf',
    'https://fsweb.no:444/studentweb/resultater.jsf', 'https://user:secret@fsweb.no/studentweb/resultater.jsf',
    'https://idp.feide.no/studentweb/resultater.jsf', 'https://fsweb.no/studentweb-evil/resultater.jsf'
  ]) assert.equal(page(table(row('TDT4100', 'A')), url), '', url);
});

test('recognises only explicit Norwegian/English pass-fail and A–F grades', () => {
  const yes = ['A', 'B', 'C', 'D', 'E', 'Bestått', 'Greidd', 'Pass', 'Passed'];
  const no = ['F', 'Ikke bestått', 'Ikkje bestått', 'Ikkje greidd', 'Fail', 'Failed', 'Not passed'];
  const unknown = ['', '-', 'Pending', 'Ikke publisert', 'Avbrutt', 'Trukket', 'Ikke møtt', 'Fritatt', 'Godkjent', '1.0', '5', 'A / F', 'Bestått?'];
  for (const grade of yes) assert.deepEqual(read(table(row('TEST1000', grade))), [{ courseCode: 'TEST1000', passed: true }], grade);
  for (const grade of no) assert.deepEqual(read(table(row('TEST1000', grade))), [{ courseCode: 'TEST1000', passed: false }], grade);
  for (const grade of unknown) assert.deepEqual(read(table(row('TEST1000', grade))), [], grade);
});

test('complete pass wins over failed attempts regardless of order; no attempt history leaves page', () => {
  for (const grades of [['A', 'F'], ['F', 'E'], ['Bestått', 'Ikke bestått']]) {
    assert.deepEqual(read(table(grades.map(g => row('TDT4100', g)).join(''))), [{ courseCode: 'TDT4100', passed: true }]);
  }
  assert.deepEqual(read(table(row('TDT4100', 'F') + row('TDT4100', 'F'))), [{ courseCode: 'TDT4100', passed: false }]);
});

test('partial assessments, other panels and unknown table structures cannot establish completion', () => {
  for (const heading of ['Deler der samlet resultat ikke er beregnet', 'Partial results', 'Course components', 'Aktive emner', 'Upcoming events']) {
    assert.deepEqual(read(table(row('PART1000', 'A'), heading)), []);
  }
  assert.deepEqual(read('<h2>Mine resultater</h2><p>TDT4100 A 7.5</p>'), []);
  assert.deepEqual(read(table(row('PART1000', 'A')).replace('<th>Studiepoeng</th>', '<th>Score</th>')), []);
  assert.deepEqual(read(table(row('PART1000', 'A')).replace('<th>Studiepoeng</th>', '<th>Karakter</th>')), []);
  assert.deepEqual(read(`<h1>Results</h1>${table(row('PART1000', 'A'), 'Parts not completed')}`), []);
  assert.deepEqual(read(table(row('PART1000', 'A')).replace('</tr><tr', '<th>Vurdering</th></tr><tr').replace('</td></tr>', '</td><td>Midterm</td></tr>')), []);
});

test('whole-course retakes with no awarded credits and zero-credit courses still count', () => {
  for (const credits of ['', '0', 'PRIVATE_CREDITS']) {
    assert.deepEqual(read(table(row('TEST1000', 'Bestått', credits))), [{ courseCode: 'TEST1000', passed: true }]);
  }
});

test('Studentweb visual course labels can be aria-hidden beside a screen-reader duplicate', () => {
  const course = '<span class="uuHidden">TEST1000</span><a aria-hidden="true">TEST1000</a> Course title';
  assert.deepEqual(read(table(row(course, 'A'))), [{ courseCode: 'TEST1000', passed: true }]);
  assert.deepEqual(read(table(row('<button aria-hidden="true">TEST1000</button> Course title', 'Bestått'))), [{ courseCode: 'TEST1000', passed: true }]);
  // The exception applies only to presentation labels inside the course cell.
  for (const html of [
    row(course, 'A', '7.5', 'aria-hidden="true"'),
    row(course, '<span aria-hidden="true">A</span>'),
    row('<span style="display:none" aria-hidden="true">TEST1000</span> Course title', 'A'),
    row(course, 'A').replace('<td>', '<td aria-hidden="true">').replace('<td>', '<td aria-hidden="true">'),
  ]) assert.deepEqual(read(table(html)), []);
  assert.deepEqual(read(table(row(course + '<span aria-hidden="true">OTHER1000</span>', 'A'))), []);
});

test('semantic captions and repeated field labels do not confuse result scope', () => {
  const html = table(row('<span>Emne</span><a aria-hidden="true">TEST1000</a>', '<span>Resultat</span>A'));
  assert.deepEqual(read(html), [{ courseCode: 'TEST1000', passed: true }]);
  assert.deepEqual(read(html.replace('<table>', '<table><caption class="uuHidden">Resultater</caption>')), [{ courseCode: 'TEST1000', passed: true }]);
  assert.deepEqual(read(html.replace('<table>', '<table><caption class="uuHidden">Deler der samlet resultat ikke er beregnet</caption>')), []);
});

test('Studentweb responsive codes, stp. heading, statistics links and assessment basis are supported', () => {
  const header = '<tr><th>Semester</th><th>Emne</th><th>Vurderingsgrunnlag</th><th>Dato</th><th>Kand.nr</th><th>Resultat</th><th>stp.</th></tr>';
  const result = (code, grade, basis, extra = '', credits = '') => `<tr ${extra}><td>PRIVATE_TERM</td>`
    + `<td><span class="ui-column-title">Emne</span><span>${code}</span> <a>${code}</a><div>PRIVATE_TITLE</div><a>Ta emnet på nytt</a></td>`
    + `<td><span class="ui-column-title">Vurderingsgrunnlag</span>${basis}</td><td>PRIVATE_DATE</td><td>PRIVATE_CANDIDATE</td>`
    + `<td><span class="ui-column-title">Resultat</span><a class="statistikkButton">Statistikk for ${code}</a>${grade}</td>`
    + `<td><span class="ui-column-title">Studiepoeng</span>${credits}</td></tr>`;
  const html = '<h1>Resultater</h1><p>Hvilke resultater vil du se?</p><div><h2>Resultater</h2><table>' + header
    + result('TEST1000', 'Ikke bestått', 'Samlet karakter', 'class="resultatTop"')
    + result('TEST1000', 'A', 'Del: Oppgave', 'class="resultat"')
    + result('TEST1001', 'B', 'Skriftlig skoleeksamen')
    + result('TEST1001', 'Ikke møtt', 'Skriftlig skoleeksamen')
    + result('TEST1002', 'Bestått', 'Deltakelse på kurs', '', '0')
    + result('ØKO1000', 'E', 'Muntlig')
    + result('TEST1003', 'A', 'Del: Flervalgeksamen')
    + result('TEST1004', 'Godkjent', 'Obligatoriske aktiviteter')
    + result('TEST1005', 'A', 'Samlet karakter', 'class="ui-expanded-row-content"')
    + result('TEST1006', 'A', 'Midtsemesterprøve', 'class="resultat"')
    + '<tr class="ui-expanded-row-content"><td colspan="7"><table><tr><td>PRIVATE_DETAIL A</td></tr></table></td></tr>'
    + '</table><h2>Deler der samlet resultat ikke er beregnet</h2><table>' + header
    + result('TEST1000', 'A', 'Prosjektoppgave') + result('PART1000', 'B', 'Mappe') + '</table></div>';
  const encoded = page(html);
  assert.deepEqual(JSON.parse(encoded), [
    { courseCode: 'TEST1000', passed: false }, { courseCode: 'TEST1001', passed: true },
    { courseCode: 'TEST1002', passed: true }, { courseCode: 'ØKO1000', passed: true },
  ].sort((a, b) => a.courseCode.localeCompare(b.courseCode)));
  assert.doesNotMatch(encoded, /PRIVATE|Kand|grade|credits|møtt|Godkjent|PART/);
  // Statistics controls need not have Studentweb's current CSS class.
  assert.deepEqual(JSON.parse(page(html.replaceAll('class="statistikkButton"', ''))), JSON.parse(encoded));
  assert.deepEqual(JSON.parse(page(html.replaceAll('</span> <a>', '</span><a>'))), JSON.parse(encoded));
});

test('hidden fields, collapsed rows and nested component tables cannot provide grades', () => {
  assert.deepEqual(read(table([
    row('TEST1000', 'A', '7.5', 'hidden'), row('TEST1001', 'A', '7.5', 'aria-hidden="true"'),
    row('TEST1002', 'A', '7.5', 'style="display:none"'), row('TEST1003', '<span hidden>A</span>'),
    row('TEST1004', '<details><summary>Details</summary>A</details>'),
    row('TEST1005', '<input value="A">'), row('TEST1006', '<button>A</button>'),
    row('TEST1007', '<span class="ui-column-title">Karakter</span>E'),
  ].join(''))), [{ courseCode: 'TEST1007', passed: true }]);
  const nested = `<section><h2>Results</h2><table><tr><td>${table(row('PART1000', 'A'))}</td></tr></table></section>`;
  assert.deepEqual(read(nested), []);
});

test('an explicit overall assessment is accepted while its individual components are ignored', () => {
  const html = '<section><h2>Resultater</h2><table><tr><th>Emne</th><th>Vurdering</th><th>Karakter</th><th>Studiepoeng</th></tr>'
    + '<tr><td>TDT4100</td><td>Samlet vurdering</td><td>F</td><td>0</td></tr>'
    + '<tr><td>TDT4100</td><td>Midterm</td><td>A</td><td>7.5</td></tr>'
    + '<tr><td>TMA4100</td><td>Overall assessment</td><td>E</td><td>7.5</td></tr></table></section>';
  assert.deepEqual(read(html), [{ courseCode: 'TDT4100', passed: false }, { courseCode: 'TMA4100', passed: true }]);
});

test('column binding, course validation and row structure prevent accidental matches', () => {
  const good = '<h2>My results</h2><table><tr><th>Credits</th><th>Grade</th><th>Course</th></tr><tr><td>7.5</td><td>E</td><td>TDT 4100 Algorithms</td></tr></table>';
  assert.deepEqual(read(good), [{ courseCode: 'TDT4100', passed: true }]);
  for (const code of ['TDT4100 TMA4100', 'private@example.invalid TDT4100', '01010112345', 'AB123456', 'AB123Xsuffix', '../TDT4100', 'TDT4100<script>secret</script>TMA4100']) {
    assert.deepEqual(read(table(row(code, 'A'))), [], code);
  }
  assert.deepEqual(read(table('<tr><td colspan="2">TDT4100</td><td>A</td></tr>')), []);
});

test('bounded reads fail closed instead of silently truncating a transcript', () => {
  const many = Array.from({ length: 1001 }, (_, i) => row(`TEST${1000 + i}`, 'A')).join('');
  assert.equal(page(table(many)), '');
  const repeated = Array.from({ length: 2001 }, () => row('TEST1000', 'A')).join('');
  assert.equal(page(table(repeated)), '');
});

test('reads are side-effect free and never retain removed rows between reads', () => {
  const document = new DOMParser().parseFromString(`<html><head></head><body>${table(row('TEST1000', 'A'))}</body></html>`, 'text/html');
  const location = new URL('https://fsweb.no/studentweb/resultater.jsf');
  const before = document.toString();
  assert.equal(JSON.parse(extract(document, location)).length, 1);
  assert.equal(document.toString(), before);
  document.querySelectorAll('tr')[1].remove();
  assert.equal(extract(document, location), '[]');
  assert.doesNotMatch(script, /\bfetch\s*\(|XMLHttpRequest|\.click\s*\(|localStorage|sessionStorage|document\.cookie|\.innerHTML|\.value\b|console\./);
});
