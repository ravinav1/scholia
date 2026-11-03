import { escapeHtml as esc } from '../chrome/src/html-escape.js';
import {
  analyzeExamCollisions,
  groupExams,
  examCourseKey,
  examFocusCourses,
  examToday,
  isPastExam,
  compareExamDates,
  normalizeExamPlan,
} from '../../packages/core/src/exam-planner.js';

const dateText = (date, options = { day: 'numeric', month: 'short', year: 'numeric' }) =>
  date
    ? new Intl.DateTimeFormat('en-GB', { ...options, timeZone: 'UTC' }).format(
        new Date(`${date}T12:00:00Z`)
      )
    : 'Date to be confirmed';
const courseTitle = (exam) => exam.courseCode || exam.courseName;
const timeText = (exam) =>
  `${exam.startTime || 'Time TBC'}${exam.endTime ? `–${exam.endTime}` : exam.startTime ? ' · end TBC' : ''}${exam.endDate && exam.endDate !== exam.date ? ` · ends ${dateText(exam.endDate)}` : ''}`;
const statusLabels = {
  clear: 'No overlap',
  collision: 'Overlaps',
  possible: 'Possible overlap',
  unknown: 'Time / date TBC',
  unselected: 'Set aside',
  flexible: 'Flexible timing',
};
const plural = (n, noun) => `${n} ${noun}${n === 1 ? '' : 's'}`;

export function examScheduleMarkup(state, today = examToday()) {
  const exams = normalizeExamPlan(state.library.examPlan || []),
    courses = state.library.courses || [];
  const upcoming = exams.filter((exam) => !isPastExam(exam, today));
  const past = exams.filter((exam) => isPastExam(exam, today)).sort((a, b) => compareExamDates(b, a));
  const analysis = analyzeExamCollisions(upcoming),
    groups = groupExams(upcoming);
  const selected = upcoming
    .filter((exam) => exam.selected)
    .sort(compareExamDates);
  const incomplete = selected.filter(
    (exam) => !exam.flexible && (!exam.date || !exam.startTime || !exam.endTime)
  ).length;
  const flexibleCount = selected.filter((exam) => exam.flexible).length;
  const readyCourses = examFocusCourses(exams, courses, today);
  const byId = new Map(exams.map((exam) => [exam.id, exam]));
  const days = new Map();
  for (const exam of selected) {
    if (!days.has(exam.date)) days.set(exam.date, []);
    days.get(exam.date).push(exam);
  }
  let occupiedThrough = '';
  const conflicts = [...analysis.collisions].sort((a, b) =>
    (byId.get(a.firstId).date || '').localeCompare(byId.get(b.firstId).date || '')
  );
  function option(keep, drop) {
    const sameCourse = examCourseKey(keep) === examCourseKey(drop);
    const removed = selected.filter((exam) => sameCourse ? exam.id === drop.id : examCourseKey(exam) === examCourseKey(drop));
    const removedIDs = new Set(removed.map((exam) => exam.id));
    const remaining = analysis.collisions.filter((pair) => !removedIDs.has(pair.firstId) && !removedIDs.has(pair.secondId)).length;
    const favorite = courses.some(
      (course) => course.favorite && examCourseKey(course) === examCourseKey(keep)
    );
    return `<div class="exam-option"><div class="exam-option-code">${esc(courseTitle(keep))}${favorite ? '<span title="Favorite course">★</span>' : ''}</div><h4>${esc(keep.courseName || keep.component)}</h4><p>${esc(keep.component)} · ${esc(dateText(keep.date))}<br><strong>${esc(timeText(keep))}</strong></p><div class="exam-choice-impact">Sets aside ${esc(courseTitle(drop))}${removed.length > 1 ? ` · all ${removed.length} selected exams` : ` · ${esc(drop.component)}`}<small>${remaining ? `${plural(remaining, 'conflict')} still to review` : 'Resolves all current overlaps'}</small></div><button type="button" data-schedule-action="choose" data-keep="${esc(keep.id)}" data-drop="${esc(drop.id)}">Keep ${esc(examCourseKey(keep) === examCourseKey(drop) ? keep.component : courseTitle(keep))}</button><button type="button" data-schedule-action="flexible" data-exam-id="${esc(keep.id)}" data-flexible="true">Mark timing flexible</button></div>`;
  }
  return `<header class="exam-view-heading"><div><span class="eyebrow">YOUR SEMESTER, AT A GLANCE</span><h1>Exam dates</h1><p>A little space to see what fits.</p></div><button type="button" data-schedule-action="edit">${exams.length ? 'Manage dates' : 'Add exam dates'}</button></header>
    ${past.length ? `<details class="exam-past"><summary>Past exams <span>${plural(past.length, 'exam')}</span></summary><div class="exam-past-rows">${past.map((exam) =>
      `<article class="exam-past-row"><div><strong>${esc(courseTitle(exam))}${exam.courseCode && exam.courseName ? ` · ${esc(exam.courseName)}` : ''}</strong><p>${esc(exam.component)} · ${esc(dateText(exam.date))} · ${esc(timeText(exam))}</p>${exam.flexible ? '<p>Flexible timing · date kept for reference</p>' : ''}</div><span>${exam.selected ? 'Selected' : 'Set aside'}</span></article>`).join('')}</div></details>` : ''}
    <div class="exam-overview" aria-label="Exam plan summary"><div><strong>${selected.length}</strong><span>upcoming exams selected</span></div><div class="${conflicts.length ? 'needs-attention' : ''}"><strong>${conflicts.length ? conflicts.length : '✓'}</strong><span>${conflicts.length ? 'overlaps to review' : flexibleCount ? 'no fixed-time overlaps' : 'no overlaps found'}</span></div><div><strong>${incomplete}</strong><span>dates / times to check</span></div>${flexibleCount ? `<div><strong>${flexibleCount}</strong><span>flexible · to arrange</span></div>` : ''}<p>Europe/Oslo<br>Selected, conflict-free courses are saved to favorites.</p></div>
    <div class="exam-schedule-feedback" role="status" aria-live="polite"></div>
    <div class="exam-schedule-layout"><section class="exam-timeline" aria-labelledby="exam-timeline-title"><div class="exam-section-title"><h2 id="exam-timeline-title">Your schedule</h2><span>${plural(days.size, 'exam day')}</span></div>
      ${
        selected.length
          ? [...days]
              .map(([date, rows]) => {
                const previous = occupiedThrough;
                const gap =
                  date && previous
                    ? Math.round((Date.parse(date) - Date.parse(previous)) / 86400000) - 1
                    : 0;
                for (const exam of rows) {
                  const lastDay = exam.endDate || exam.date;
                  if (lastDay > occupiedThrough) occupiedThrough = lastDay;
                }
                return `${gap > 0 ? `<div class="exam-day-gap">${plural(gap, 'day')} between exams</div>` : ''}<section class="exam-day"><div class="exam-date-block">${date ? `<span>${esc(dateText(date, { month: 'short', year: 'numeric' }))}</span><strong>${date.slice(8)}</strong><small>${esc(dateText(date, { weekday: 'long' }))}</small>` : '<span>DATE</span><strong>?</strong><small>To confirm</small>'}</div><div class="exam-day-rows">${rows
                  .map((exam) => {
                    const status = analysis.byId[exam.id].status;
                    return `<article class="exam-schedule-row ${status}"><div><span class="exam-row-code">${esc(courseTitle(exam))}</span><h3>${esc(exam.courseName || exam.component)}</h3><p>${esc(exam.component)} <span>·</span> ${esc(timeText(exam))}</p>${exam.flexible ? '<p>Date kept for reference · arrange with professor</p>' : ''}</div><div><span class="exam-status ${status}">${statusLabels[status]}</span>${exam.flexible ? `<button type="button" data-schedule-action="flexible" data-exam-id="${esc(exam.id)}" data-flexible="false">Use fixed timing</button>` : ''}</div></article>`;
                  })
                  .join('')}</div></section>`;
              })
              .join('')
          : `<div class="exam-schedule-empty"><span aria-hidden="true">▦</span><h3>${!upcoming.length && past.length ? 'No upcoming exams.' : exams.length ? 'Make room for your exams.' : 'Your exam season starts here.'}</h3><p>${!upcoming.length && past.length ? 'Your earlier dates are in Past exams above. Add new dates in Manage dates.' : exams.length ? 'Select a course below to see its dates and check how it fits.' : 'Add your dates from Studentweb, then see your semester in one place.'}</p>${!exams.length ? '<button type="button" data-schedule-action="edit">Add exam dates</button>' : ''}</div>`
      }
      ${
        groups.length
          ? `<details class="exam-course-selection" ${!selected.length ? 'open' : ''}><summary>Course selection <span>${plural(groups.length, 'course')}</span></summary><div class="exam-course-selection-actions"><button type="button" data-schedule-action="selectAll" ${selected.length === upcoming.length ? 'disabled' : ''}>Select all</button><button type="button" data-schedule-action="clearAll" ${selected.length ? '' : 'disabled'}>Clear selection</button></div><div>${groups
              .map((group) => {
                const count = group.exams.filter((exam) => exam.selected).length;
                return `<label><input type="checkbox" data-schedule-course="${esc(group.key)}" ${count === group.exams.length ? 'checked' : ''} ${count && count !== group.exams.length ? 'data-partial="true"' : ''}><span><strong>${esc(courseTitle(group))}</strong><small>${esc(group.courseName)} · ${count}/${group.exams.length} exams selected</small></span></label>`;
              })
              .join('')}</div></details>`
          : ''
      }
      <p class="exam-schedule-note">Only selected exams with fixed timing are compared. Arrange flexible exams with your professor. Missing times remain uncertain. Back-to-back exams may still need travel time.</p>
    </section><aside class="exam-decisions" aria-label="Exam choices"><div class="exam-section-title"><h2>${conflicts.length ? 'Make a choice' : 'Looking good'}</h2>${conflicts.length ? `<span>${plural(conflicts.length, 'pair')}</span>` : ''}</div>
      ${
        conflicts.length
          ? `<p class="exam-decision-intro">Keep one course, or mark an exam’s timing as flexible when it can be agreed with your professor. Flexible timing keeps both exams selected.</p>${conflicts
              .slice(0, 12)
              .map((pair) => {
                const a = byId.get(pair.firstId),
                  b = byId.get(pair.secondId);
                return `<article class="exam-comparison ${pair.status}"><div class="exam-comparison-heading"><span>${pair.status === 'collision' ? 'Overlapping exams' : 'Possible overlap'}</span><strong>${esc(dateText(a.date))}</strong></div>${pair.status === 'possible' ? '<p class="exam-uncertain">A time is missing. Check the details before setting a course aside.</p>' : ''}<div class="exam-options">${option(a, b)}${option(b, a)}</div></article>`;
              })
              .join(
                ''
              )}${conflicts.length > 12 ? `<p class="exam-schedule-note">${conflicts.length - 12} more pairs. Resolve these choices to narrow the remaining overlaps.</p>` : ''}`
          : `<div class="exam-clear-panel"><span aria-hidden="true">${selected.length && !incomplete ? '✓' : '◷'}</span><h3>${!selected.length ? 'Your choices, together.' : incomplete ? 'A few details to confirm.' : flexibleCount ? 'Flexible exams to arrange.' : 'Room for every selected exam.'}</h3><p>${!selected.length ? 'Conflicting exams will appear here, with a clear comparison of your options.' : incomplete ? 'Add the missing dates or times to complete your conflict check.' : flexibleCount ? 'Your fixed exam times fit together. Agree the flexible exams with your professor; their displayed dates are kept for reference.' : 'Your selected exam times fit together. Keep an eye on the gaps for revision and travel.'}</p></div>`
      }
      ${readyCourses.length ? `<div class="exam-favorites"><span class="eyebrow">★ READY TO FOCUS ON</span><p>Selected courses with complete or flexible timing and no fixed-time overlaps.</p><div>${readyCourses.map((course) => `<button type="button" data-action="course" data-id="${esc(course.id)}">${esc((course.code || course.name).replace(/-(?:\d{2}[HV])(?:-\d{2}[HV])*$/i, ''))}<span>↗</span></button>`).join('')}</div></div>` : ''}
    </aside></div><p class="exam-schedule-note">Your personal plan · verify final dates in Studentweb. Choices here do not change exam registrations.</p>`;
}
