import test from 'node:test';
import assert from 'node:assert/strict';
import {
  analyzeExamCollisions,
  groupExams,
  mergeExamImports,
  normalizeExam,
  normalizeExamPlan,
  parseExamImport,
  setExamFlexibleTiming,
} from '../packages/core/src/exam-planner.js';

const exam = (id, changes = {}) => ({
  id,
  courseCode: 'TDT4100',
  courseName: 'Object-oriented programming',
  component: 'Final exam',
  kind: 'final',
  date: '2026-12-12',
  startTime: '09:00',
  endTime: '13:00',
  endDate: '',
  selected: true,
  source: 'manual',
  ...changes,
});

test('exam validation rejects impossible dates, times, reverse intervals, and invalid selection', () => {
  for (const changes of [
    { date: '2026-02-29' },
    { date: '2026-13-01' },
    { date: '2026-04-31' },
    { date: '2026-1-02' },
    { startTime: '25:00' },
    { endTime: '09:00' },
    { endTime: '08:59' },
    { endDate: '2026-12-11' },
    { date: '' },
    { selected: 'false' },
    { flexible: 'false' },
    { flexible: null },
    { source: 'website' },
    { kind: 'exam' },
    { courseCode: '', courseName: '' },
  ])
    assert.throws(() => normalizeExam(exam('a', changes)), JSON.stringify(changes));
  assert.equal(normalizeExam(exam('leap', { date: '2028-02-29' })).date, '2028-02-29');
  assert.equal(
    normalizeExam(
      exam('overnight', { startTime: '22:00', endTime: '02:00', endDate: '2026-12-13' })
    ).endDate,
    '2026-12-13'
  );
  assert.equal(normalizeExam({ courseCode: 'tdt-4100' }).courseCode, 'TDT4100');
  assert.throws(() => normalizeExamPlan({ exams: [] }), /list/);
  assert.throws(() => normalizeExamPlan([exam('a'), exam('a')]), /unique/);
  assert.throws(
    () => normalizeExamPlan(Array.from({ length: 501 }, (_, i) => exam(`${i}`))),
    /500/
  );
});

test('collision analysis ignores unselected exams and treats endpoint contact as clear', () => {
  const result = analyzeExamCollisions([
    exam('morning'),
    exam('next', { startTime: '13:00', endTime: '15:00' }),
    exam('unselected', { selected: false }),
  ]);
  assert.equal(result.byId.morning.status, 'clear');
  assert.equal(result.byId.next.status, 'clear');
  assert.equal(result.byId.unselected.status, 'unselected');
  assert.deepEqual(result.collisions, []);
  assert.deepEqual(result.summary, {
    selected: 2,
    collision: 0,
    possible: 0,
    unknown: 0,
    clear: 2,
    flexible: 0,
  });
});

test('collision analysis reports overlap, possible overlap, and unknown without guessing duration', () => {
  const result = analyzeExamCollisions([
    exam('a'),
    exam('b', { startTime: '12:00', endTime: '14:00' }),
    exam('date-only', { startTime: '', endTime: '' }),
    exam('missing', { date: '', startTime: '', endTime: '' }),
    exam('start-only', { date: '2026-12-13', endTime: '' }),
  ]);
  assert.equal(result.byId.a.status, 'collision');
  assert.equal(result.byId.b.status, 'collision');
  assert.equal(result.byId['date-only'].status, 'possible');
  assert.equal(result.byId.missing.status, 'unknown');
  assert.equal(result.byId['start-only'].status, 'unknown');
  assert.deepEqual(result.byId.a.conflicts, [
    { id: 'b', status: 'collision' },
    { id: 'date-only', status: 'possible' },
  ]);
});

test('collision analysis detects overnight and multi-day overlaps', () => {
  const result = analyzeExamCollisions([
    exam('overnight', { startTime: '22:00', endTime: '02:00', endDate: '2026-12-13' }),
    exam('next-day', { date: '2026-12-13', startTime: '01:00', endTime: '03:00' }),
    exam('multi-day', { date: '2026-12-11', startTime: '', endTime: '', endDate: '2026-12-14' }),
  ]);
  assert.equal(result.byId.overnight.status, 'collision');
  assert.equal(result.byId['next-day'].status, 'collision');
  assert.equal(result.byId['multi-day'].status, 'possible');
});

test('flexible timing overrides only that exam, preserves intent and dates, and can be reversed', () => {
  const rows = [exam('fixed'), exam('other'), exam('flex', { endTime: '', endDate: '2026-12-16' })];
  const before = structuredClone(rows);
  const flexible = setExamFlexibleTiming(rows, 'flex', true);
  const analysis = analyzeExamCollisions(flexible);
  assert.equal(analysis.collisions.length, 1, 'The two fixed exams still clash');
  assert.equal(analysis.byId.flex.status, 'flexible');
  assert.equal(analysis.summary.flexible, 1);
  assert.ok(flexible.every((row) => row.selected));
  assert.deepEqual(flexible[2], normalizeExam({ ...rows[2], flexible: true }));
  assert.deepEqual(rows, before, 'The override does not mutate its baseline');
  assert.equal(analyzeExamCollisions(setExamFlexibleTiming(flexible, 'flex', false)).collisions.length, 3);
  assert.throws(() => setExamFlexibleTiming(rows, 'missing', true), /no longer/);
  assert.throws(() => setExamFlexibleTiming(rows, 'flex', 'true'), /true or false/);
});

test('oral exams default to flexible while an explicit fixed choice survives saves and imports', () => {
  for (const component of ['Oral exam', 'Muntlig eksamen']) {
    const oral = exam('oral', { component, startTime: '', endTime: '' });
    assert.equal(normalizeExam(oral).flexible, true);
    const fixed = normalizeExam({ ...oral, flexible: false });
    assert.equal(analyzeExamCollisions([oral, exam('written')]).collisions.length, 0);
    assert.equal(analyzeExamCollisions([fixed, exam('written')]).collisions.length, 1);
    assert.equal(normalizeExam(JSON.parse(JSON.stringify(fixed))).flexible, false);
    assert.equal(mergeExamImports([fixed], [oral])[0].flexible, false);
  }
  assert.equal(normalizeExam(exam('ordinary')).flexible, false);
  assert.equal(normalizeExam(exam('temporal', { component: 'Temporal systems' })).flexible, false);
  assert.equal(parseExamImport('TDT4100\nMuntlig 12.12.2026').exams[0].flexible, true);
});

test('grouping combines midterm and final by normalized course code while accepting drafts', () => {
  const draft = { id: 'new', courseCode: '', courseName: '', date: '', startTime: '' };
  const rows = [
    exam('final'),
    exam('midterm', { courseCode: 'tdt 4100', kind: 'midterm', date: '2026-10-01' }),
    draft,
  ];
  const groups = groupExams(rows);
  const course = groups.find((group) => group.key === 'TDT4100');
  assert.deepEqual(
    course.exams.map((row) => row.id),
    ['midterm', 'final']
  );
  assert.equal(groups.find((group) => group.key === 'draft-new').exams[0], draft);
  assert.equal(rows[1].courseCode, 'tdt 4100');
});

test('copied Studentweb schedule text previews components, explicit duration and ignores personal/deadline data', () => {
  const text = `Student: Jane Example\nStudentnummer: 12345678901\nE-post: jane@example.org
TDT4100 Objektorientert programmering
Vurderingsdel: Midtsemester
Dato: 10.10.2026
Tid: 09:00 - 11:00
Trekkfrist: 01.10.2026
Sensurfrist: 20.10.2026
Results date: 24.10.2026
Birth date: 01.01.2000
Unrelated event 02.02.2026
Vurderingsform: Skriftlig skoleeksamen
Dato
12.12.2026
Tid
09:00
Varighet
4 timer`;
  const parsed = parseExamImport(text);
  assert.equal(parsed.exams.length, 2);
  assert.deepEqual(
    parsed.exams.map((row) => [row.date, row.kind, row.startTime, row.endTime, row.selected]),
    [
      ['2026-10-10', 'midterm', '09:00', '11:00', false],
      ['2026-12-12', 'final', '09:00', '13:00', false],
    ]
  );
  assert.ok(parsed.exams.every((row) => row.source === 'studentweb'));
  assert.doesNotMatch(JSON.stringify(parsed), /Jane|12345678901|jane@example|2000/);
  assert.ok(parsed.warnings.some((warning) => warning.includes('Check every')));
});

test('copied dates recognize Norwegian and English month names with explicit years', () => {
  const { exams } = parseExamImport(
    'TDT4100 Programming\nFinal exam 15. desember 2026 09:00–13:00\nTMA4100 Calculus\nFinal exam 16 December 2026 09:00–13:00'
  );
  assert.deepEqual(
    exams.map((row) => row.date),
    ['2026-12-15', '2026-12-16']
  );
  assert.deepEqual(
    exams.map((row) => row.courseCode),
    ['TDT4100', 'TMA4100']
  );
});

test('CSV handles quoted delimiters, localized headers, ranges and ignores unrelated columns', () => {
  const parsed = parseExamImport(
    'emnekode;emnenavn;vurderingsform;dato;tid;varighet;studentnummer\nTDT4100;"Programming; objects";Skriftlig skoleeksamen;12.12.2026;09:00;3 timer;12345678901'
  );
  assert.equal(parsed.exams.length, 1);
  assert.equal(parsed.exams[0].courseName, 'Programming; objects');
  assert.equal(parsed.exams[0].endTime, '12:00');
  assert.doesNotMatch(JSON.stringify(parsed), /12345678901/);
  const ranges = parseExamImport('courseCode,date,startTime\nTMA4100,2026-12-10,09:00–13:00');
  assert.equal(ranges.exams[0].endTime, '13:00');
  const invalid = parseExamImport(
    'courseCode,date,startTime,endTime\nTMA4100,2026-02-30,09:00,13:00\nTDT4100,2026-12-12,09:00,12:00'
  );
  assert.equal(invalid.exams.length, 1);
  assert.match(invalid.warnings[0], /Row 2.*valid exam date/);
});

test('imports are bounded and malformed data returns useful errors', () => {
  assert.throws(() => parseExamImport('x'.repeat(1_000_001)), /too large/);
  assert.throws(() => parseExamImport({}), /Paste exam text/);
  assert.throws(() => parseExamImport('courseCode,date\n"TDT4100,2026-12-12', 'csv'), /unclosed/);
  assert.throws(() => parseExamImport('nothing,value\none,two', 'csv'), /course code/);
  assert.equal(parseExamImport('Hello from Studentweb').exams.length, 0);
});

test('repeat imports deduplicate without overwriting intended selections and protect colliding IDs', () => {
  const text =
    'courseCode,component,date,startTime,endTime\nTDT4100,Final exam,2026-12-12,09:00,13:00';
  const first = parseExamImport(text).exams;
  const second = parseExamImport(text).exams;
  assert.equal(first[0].id, second[0].id);
  const saved = [{ ...first[0], selected: true }];
  const merged = mergeExamImports(saved, second);
  assert.equal(merged.length, 1);
  assert.equal(merged[0].selected, true);
  const collision = mergeExamImports(saved, [{ ...first[0], date: '2026-12-13' }]);
  assert.equal(collision.length, 2);
  assert.notEqual(collision[0].id, collision[1].id);
});

test('calendar converts UTC and IANA zones to Oslo including winter/summer offsets', () => {
  const input = `BEGIN:VCALENDAR
BEGIN:VEVENT
SUMMARY:TDT4100 Final exam
DTSTART:20261212T080000Z
DTEND:20261212T120000Z
ATTENDEE:mailto:private@example.org
DESCRIPTION:Student number 12345678901
END:VEVENT
BEGIN:VEVENT
SUMMARY:TMA4100 Midterm
DTSTART;TZID=America/New_York:20260610T080000
DTEND;TZID=America/New_York:20260610T100000
END:VEVENT
BEGIN:VEVENT
SUMMARY:TTK4100 Final exam
DTSTART;TZID=Europe/Oslo:20261214T090000
DURATION:PT4H
END:VEVENT
END:VCALENDAR`;
  const result = parseExamImport(input);
  assert.equal(result.exams.length, 3);
  assert.deepEqual(
    result.exams.map((row) => [row.startTime, row.endTime]),
    [
      ['09:00', '13:00'],
      ['14:00', '16:00'],
      ['09:00', '13:00'],
    ]
  );
  assert.doesNotMatch(JSON.stringify(result), /private@example|12345678901/);
});

test('calendar handles date changes and exclusive all-day end dates', () => {
  const result = parseExamImport(`BEGIN:VCALENDAR
BEGIN:VEVENT
SUMMARY:TDT4100 Final
DTSTART:20261212T233000Z
DTEND:20261213T020000Z
END:VEVENT
BEGIN:VEVENT
SUMMARY:TMA4100 Home exam
DTSTART;VALUE=DATE:20261214
DTEND;VALUE=DATE:20261217
END:VEVENT
END:VCALENDAR`);
  assert.equal(result.exams[0].date, '2026-12-13');
  assert.equal(result.exams[0].startTime, '00:30');
  assert.equal(result.exams[1].endDate, '2026-12-16');
  assert.equal(result.exams[1].startTime, '');
});

test('calendar excludes unrelated, recurring, cancelled and invalid events', () => {
  const result = parseExamImport(`BEGIN:VCALENDAR
BEGIN:VEVENT
SUMMARY:Birthday
DTSTART:20261212T080000Z
END:VEVENT
BEGIN:VEVENT
SUMMARY:TDT4100 Exam
DTSTART:20261212T080000Z
RRULE:FREQ=WEEKLY
END:VEVENT
BEGIN:VEVENT
SUMMARY:TDT4100 Exam
DTSTART:20261212T080000Z
STATUS:CANCELLED
END:VEVENT
BEGIN:VEVENT
SUMMARY:TDT4100 Exam
DTSTART:20260230T080000Z
END:VEVENT
END:VCALENDAR`);
  assert.equal(result.exams.length, 0);
  assert.ok(result.warnings.some((warning) => /Recurring/.test(warning)));
  assert.ok(result.warnings.some((warning) => /cancelled/.test(warning)));
});

test('labels remain plain data, never interpreted markup, and unknown fields are stripped', () => {
  const payload = '<img src=x onerror=alert(1)>';
  const row = normalizeExam(
    exam('__proto__', { courseName: payload, html: payload, password: 'private' })
  );
  assert.equal(row.courseName, payload);
  assert.equal(Object.hasOwn(row, 'html'), false);
  assert.equal(Object.hasOwn(row, 'password'), false);
  assert.equal(analyzeExamCollisions([row]).byId.__proto__.status, 'clear');
});

test('favorites require every selected component to have complete non-overlapping times', async () => {
  const { examFavoriteCourseIDs, resolveExamConflict } = await import(
    '../packages/core/src/exam-planner.js'
  );
  const courses = [
    { id: 'programming', code: 'TDT4100-26H', name: 'Programming' },
    { id: 'calculus', code: 'TMA4100', name: 'Calculus' },
    { id: 'sensors', code: 'TFE4146', name: 'Sensors' },
  ];
  const plan = [
    exam('midterm', { date: '2026-10-10', component: 'Midterm' }),
    exam('final'),
    exam('calculus', { courseCode: 'TMA4100' }),
    exam('sensors', { courseCode: 'TFE4146', date: '2026-12-14', endTime: '' }),
  ];
  assert.deepEqual(
    examFavoriteCourseIDs(plan, courses),
    [],
    'Clear midterm must not favorite a course with a conflicting final'
  );
  const choice = resolveExamConflict(plan, 'calculus', 'final');
  assert.deepEqual(
    choice.filter((exam) => !exam.selected).map((exam) => exam.id),
    ['midterm', 'final']
  );
  assert.deepEqual(examFavoriteCourseIDs(choice, courses), ['calculus']);
  assert.equal(plan[0].selected, true, 'Choice preview does not change the saved plan');
  assert.throws(() => resolveExamConflict(choice, 'calculus', 'final'), /no longer conflicts/);
  const internal = [exam('first'), exam('second')];
  assert.deepEqual(
    resolveExamConflict(internal, 'first', 'second').map((exam) => exam.selected),
    [true, false]
  );
});
