import test from 'node:test';
import assert from 'node:assert/strict';
import { parseHTML } from 'linkedom';
import { examScheduleMarkup } from '../../apps/web/exams/exam-schedule.js';
import { examToday, isPastExam } from '../../packages/core/src/exam-planner.js';

const exam = (id, date, endDate = '') => ({
  id,
  courseCode: id,
  courseName: id,
  component: 'Final exam',
  kind: 'final',
  date,
  endDate,
  startTime: '09:00',
  endTime: '13:00',
  selected: true,
  source: 'manual',
});
test('schedule does not show revision gaps inside a multi-day exam', () => {
  const html = examScheduleMarkup({
    library: {
      courses: [],
      examPlan: [
        exam('LONG1000', '2026-12-01', '2026-12-10'),
        exam('MID1000', '2026-12-05'),
        exam('END1000', '2026-12-12'),
      ],
    },
  }, '2026-09-01');
  assert.match(html, /1 day between exams/);
  assert.doesNotMatch(html, /3 days between exams|6 days between exams/);
  assert.match(html, /ends 10 Dec 2026/);
  assert.doesNotMatch(html, /type="date"|<dialog/);
});

test('oral timing is flexible by default, keeps its reference date and can be made fixed', () => {
  const written = exam('WRITTEN1000', '2026-12-01');
  const oral = { ...exam('ORAL1000', '2026-12-01'), component: 'Oral exam' };
  const render = (row) => parseHTML(examScheduleMarkup({
    library: { courses: [], examPlan: [written, row] },
  }, '2026-09-01')).document;
  const flexible = render(oral);
  assert.equal(flexible.querySelectorAll('.exam-schedule-row').length, 2);
  assert.equal(flexible.querySelectorAll('.exam-comparison').length, 0);
  const row = flexible.querySelector('.exam-schedule-row.flexible');
  assert.match(row.textContent, /ORAL1000.*09:00–13:00.*Date kept for reference.*arrange with professor/s);
  assert.match(flexible.querySelector('.exam-day').textContent, /Dec 2026.*01/s);
  assert.equal(row.querySelector('[data-schedule-action="flexible"]').dataset.examId, oral.id);
  assert.equal(row.querySelector('[data-schedule-action="flexible"]').dataset.flexible, 'false');
  assert.match(flexible.querySelector('.exam-overview').textContent, /no fixed-time overlaps/);

  const fixed = render({ ...oral, flexible: false });
  assert.equal(fixed.querySelectorAll('.exam-comparison.collision').length, 1);
  assert.equal(fixed.querySelectorAll('.exam-schedule-row.flexible').length, 0);
  assert.deepEqual(
    [...fixed.querySelectorAll('.exam-comparison [data-schedule-action="flexible"]')]
      .map((button) => [button.dataset.examId, button.dataset.flexible]),
    [[written.id, 'true'], [oral.id, 'true']]
  );
});

test('possible overlaps offer flexible timing while course selection includes every component', () => {
  const rows = [
    exam('COURSE1000', '2026-12-01'),
    { ...exam('midterm', '2026-10-01'), courseCode: 'COURSE1000', component: 'Midterm' },
    { ...exam('OTHER1000', '2026-12-01'), startTime: '', endTime: '' },
  ];
  const render = (examPlan) => parseHTML(examScheduleMarkup({
    library: { courses: [], examPlan },
  }, '2026-09-01')).document;
  const all = render(rows);
  assert.equal(all.querySelectorAll('.exam-comparison.possible').length, 1);
  assert.equal(all.querySelectorAll('.exam-comparison.possible [data-schedule-action="flexible"]').length, 2);
  assert.equal(all.querySelectorAll('[data-schedule-course]').length, 2);
  assert.match(all.querySelector('[data-schedule-course="COURSE1000"]').closest('label').textContent, /2\/2 exams selected/);
  assert.equal(all.querySelector('.exam-course-selection [data-schedule-action="selectAll"]').hasAttribute('disabled'), true);
  assert.equal(all.querySelector('.exam-course-selection [data-schedule-action="clearAll"]').hasAttribute('disabled'), false);

  const none = render(rows.map((row) => ({ ...row, selected: false })));
  assert.equal(none.querySelector('[data-schedule-action="selectAll"]').hasAttribute('disabled'), false);
  assert.equal(none.querySelector('[data-schedule-action="clearAll"]').hasAttribute('disabled'), true);
  assert.equal(none.querySelector('.exam-course-selection').hasAttribute('open'), true);
});

test('past exams are collapsed at the top, while today, ongoing and undated exams stay active', () => {
  const rows = [
    exam('PAST1000', '2026-10-08'),
    { ...exam('PAST2000', '2026-10-09'), selected: false },
    exam('TODAY1000', '2026-10-10'),
    exam('ONGOING1000', '2026-10-08', '2026-10-11'),
    { ...exam('UNKNOWN1000', ''), startTime: '', endTime: '' },
  ];
  const before = structuredClone(rows);
  const doc = parseHTML(examScheduleMarkup({ library: { courses: [], examPlan: rows } }, '2026-10-10')).document;
  const past = doc.querySelector('.exam-past');
  assert.equal(past.hasAttribute('open'), false);
  assert.equal(past.previousElementSibling.className, 'exam-view-heading');
  assert.equal(past.querySelectorAll('.exam-past-row').length, 2);
  assert.match(past.querySelector('.exam-past-row').textContent, /PAST2000/);
  assert.doesNotMatch(doc.querySelector('.exam-timeline').textContent, /PAST1000|PAST2000/);
  assert.match(doc.querySelector('.exam-timeline').textContent, /TODAY1000/);
  assert.match(doc.querySelector('.exam-timeline').textContent, /ONGOING1000/);
  assert.match(doc.querySelector('.exam-timeline').textContent, /UNKNOWN1000/);
  assert.match(doc.querySelector('.exam-overview').textContent, /3upcoming exams selected/);
  assert.deepEqual(rows, before);
  assert.equal(isPastExam(exam('ends-today', '2026-10-08', '2026-10-10'), '2026-10-10'), false);
  assert.equal(examToday(new Date('2026-10-09T22:30:00Z')), '2026-10-10', 'Use the Oslo calendar day');
});

test('ready-to-focus courses are ordered by their next selected exam, with unknown dates last', () => {
  const rows = [
    exam('LATE1000', '2026-12-10'),
    exam('EARLY1000', '2026-11-01'),
    { ...exam('EARLY-OLD', '2026-09-01'), courseCode: 'LATE1000' },
    { ...exam('EARLY-UNSELECTED', '2026-10-15'), courseCode: 'LATE1000', selected: false },
    { ...exam('UNKNOWN1000', ''), startTime: '', endTime: '', flexible: true },
    exam('PAST1000', '2026-09-03'),
  ];
  const courses = ['PAST1000', 'LATE1000', 'UNKNOWN1000', 'EARLY1000'].map((code) => ({ code, id: code, name: code }));
  const doc = parseHTML(examScheduleMarkup({ library: { courses, examPlan: rows } }, '2026-10-10')).document;
  assert.deepEqual([...doc.querySelectorAll('.exam-favorites button')].map((button) => button.dataset.id),
    ['EARLY1000', 'LATE1000', 'UNKNOWN1000']);
});
