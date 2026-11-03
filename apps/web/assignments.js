import { escapeHtml as esc } from '../chrome/src/html-escape.js';

export function selectedAssignment(state) {
  const course = state.library.courses.find((c) => c.id === state.library.selectedCourseID);
  return course?.canvasMaterials?.find(
    (m) => m.kind === 'assignments' && m.id === state.library.selectedAssignmentID
  );
}


export const isHandedIn = (status) => ['submitted', 'graded'].includes(status);
const gradeNumber = new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 });
export function assignmentGrade(details) {
  if (
    !details ||
    details.gradeVisible === false ||
    details.status === 'excused' ||
    details.gradingType === 'not_graded'
  )
    return '';
  const grade = details.grade == null ? '' : String(details.grade).trim();
  const score = Number.isFinite(details.score) ? details.score : null;
  const points = Number.isFinite(details.pointsPossible) ? details.pointsPossible : null;
  let label = grade;
  if (details.gradingType === 'pass_fail') {
    label =
      { complete: 'Complete', pass: 'Pass', incomplete: 'Incomplete', fail: 'Fail' }[
        grade.toLowerCase()
      ] || grade;
  } else if (details.gradingType === 'points' || (!grade && details.gradingType !== 'percent')) {
    label =
      score === null
        ? grade
        : `${gradeNumber.format(score)}${points === null ? ' points' : ` / ${gradeNumber.format(points)}`}`;
  } else if (details.gradingType === 'percent' && !grade && score !== null && points > 0) {
    label = `${gradeNumber.format((score / points) * 100)}%`;
  }
  return label && details.gradeMatchesCurrentSubmission === false
    ? `${label} (previous attempt)`
    : label;
}
export function submissionBadgeMarkup(status, details) {
  const label =
    {
      submitted: 'Handed in',
      graded: 'Handed in · graded',
      excused: 'Excused',
      notSubmitted: 'Not handed in',
    }[status] || 'Status not synced';
  const handedIn = isHandedIn(status);
  const grade = assignmentGrade(details);
  return `<span class="submission-badge ${handedIn ? 'handed-in' : 'pending'}"><span aria-hidden="true">${handedIn ? '✓' : status === 'excused' ? '−' : status === 'notSubmitted' ? '○' : '?'}</span>${label}${grade ? ` · Grade: ${esc(grade)}` : ''}</span>`;
}

const complete = (details) => ['submitted', 'graded', 'excused'].includes(details?.status);
export function assignmentDate(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isFinite(date.getTime()) ? date : null;
}

export function assignmentList(
  courses,
  {
    query = '',
    includeCompleted = false,
    dueOnly = false,
    hiddenOnly = false,
    includeHidden = false,
    includeNonSubmission = false,
  } = {}
) {
  const needle = query.trim().toLocaleLowerCase();
  return courses
    .flatMap((course) =>
      (course.canvasMaterials || [])
        .filter(
          (material) =>
            material.kind === 'assignments' &&
            (hiddenOnly
              ? course.hiddenAssignmentIDs?.includes(material.id)
              : includeHidden || !course.hiddenAssignmentIDs?.includes(material.id)) &&
            (includeNonSubmission || complete(material.assignment) || !material.assignment ||
              material.assignment.submissionTypes?.some(
                (type) => !['none', 'not_graded'].includes(type)
              )) &&
            (includeCompleted || !complete(material.assignment)) &&
            (!dueOnly || assignmentDate(material.assignment?.dueAt)) &&
            `${course.name} ${course.code} ${material.title}`.toLocaleLowerCase().includes(needle)
        )
        .map((material) => ({ course, material, details: material.assignment }))
    )
    .sort(
      (a, b) =>
        (assignmentDate(a.details?.dueAt)?.getTime() ?? Infinity) -
          (assignmentDate(b.details?.dueAt)?.getTime() ?? Infinity) ||
        a.material.title.localeCompare(b.material.title, undefined, { numeric: true }) ||
        `${a.course.id}:${a.material.id}`.localeCompare(`${b.course.id}:${b.material.id}`)
    );
}

export function assignmentStatus(details, now = new Date()) {
  if (!details || !details.status || details.status === 'unknown') return 'Status not synced';
  const label = { submitted: 'Handed in', graded: 'Handed in · graded', excused: 'Excused' }[
    details.status
  ];
  if (label) return label;
  const due = assignmentDate(details.dueAt);
  if (due && due < now) return 'Overdue';
  if (details.missing) return 'Missing';
  if (due && due.toDateString() === now.toDateString()) return 'Due today';
  return 'To submit';
}

export function assignmentAvailability(details, now = new Date()) {
  const lock = assignmentDate(details?.lockAt),
    unlock = assignmentDate(details?.unlockAt);
  if (lock && lock <= now) return 'Closed';
  if (unlock && unlock > now) return 'Not open yet';
  return details?.locked ? 'Locked in Canvas' : '';
}

export function assignmentGroups(
  courses,
  { query = '', filter = 'due', semesters = [], now = new Date() } = {}
) {
  const groups = new Map();
  for (const item of assignmentList(courses, {
    query,
    includeCompleted: true,
    hiddenOnly: filter === 'hidden',
    includeHidden: filter === 'all',
    includeNonSubmission: ['all', 'archive', 'hidden'].includes(filter),
  })) {
    const date = assignmentDate(item.details?.dueAt);
    const hasDeadline = !!date && !complete(item.details);
    if (
      (filter === 'due' && !hasDeadline) ||
      (filter === 'archive' && hasDeadline) ||
      (filter === 'handedIn' && !isHandedIn(item.details?.status))
    )
      continue;
    const timeframe =
      filter === 'archive'
        ? 'archive'
        : isHandedIn(item.details?.status)
          ? 'handedIn'
          : item.details?.status === 'excused'
            ? 'excused'
            : !date
              ? 'undated'
              : date > now
                ? 'upcoming'
                : 'overdue';
    const terms = semesters.filter((semester) => semester.courseIDs.includes(item.course.id));
    const dueSemester = date
      ? `${date.getFullYear()}-${date.getMonth() >= 7 ? 'autumn' : 'spring'}`
      : null;
    // Keep year-long courses in the deadline's semester without duplicating assignments.
    const semester = terms.find((term) => term.id === dueSemester) ||
      terms[0] || {
        id: item.course.term ? `term:${item.course.term}` : 'unassigned',
        title: item.course.term || 'No semester',
      };
    const id = `${timeframe}:${semester.id}`;
    if (!groups.has(id))
      groups.set(id, { id, semesterID: semester.id, timeframe, title: semester.title, items: [] });
    groups.get(id).items.push(item);
  }
  const rank = new Map(semesters.map((semester, i) => [semester.id, i]));
  for (const group of groups.values()) {
    if (!['overdue', 'upcoming'].includes(group.timeframe))
      group.items.sort(
        (a, b) =>
          (assignmentDate(b.details?.dueAt)?.getTime() ?? -Infinity) -
            (assignmentDate(a.details?.dueAt)?.getTime() ?? -Infinity) ||
          a.material.title.localeCompare(b.material.title, undefined, { numeric: true })
      );
  }
  const timeframes = { overdue: 0, upcoming: 1, undated: 2, handedIn: 3, excused: 4, archive: 5 };
  return [...groups.values()].sort(
    (a, b) =>
      timeframes[a.timeframe] - timeframes[b.timeframe] ||
      (['overdue', 'upcoming'].includes(a.timeframe)
        ? assignmentDate(a.items[0].details.dueAt) - assignmentDate(b.items[0].details.dueAt)
        : 0) ||
      (rank.get(a.semesterID) ?? Infinity) - (rank.get(b.semesterID) ?? Infinity) ||
      Number(a.semesterID === 'unassigned') - Number(b.semesterID === 'unassigned') ||
      a.title.localeCompare(b.title)
  );
}

export function assignmentDateGroups(items) {
  const groups = new Map();
  const format = new Intl.DateTimeFormat(undefined, {
    weekday: 'short',
    year: 'numeric',
    month: 'short',
    day: 'numeric',
  });
  for (const item of items) {
    const date = assignmentDate(item.details?.dueAt);
    const id = date
      ? `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`
      : 'undated';
    if (!groups.has(id))
      groups.set(id, { id, title: date ? format.format(date) : 'No due date', items: [] });
    groups.get(id).items.push(item);
  }
  return [...groups.values()];
}

export function assignmentTimeline(groups) {
  const days = (timeframe) =>
    assignmentDateGroups(
      groups
        .filter((group) => group.timeframe === timeframe)
        .flatMap((group) => group.items)
        .sort(
          (a, b) =>
            assignmentDate(a.details.dueAt) - assignmentDate(b.details.dueAt) ||
            a.material.title.localeCompare(b.material.title, undefined, { numeric: true }) ||
            `${a.course.id}:${a.material.id}`.localeCompare(`${b.course.id}:${b.material.id}`)
        )
    );
  return { past: days('overdue'), upcoming: days('upcoming') };
}

function assignmentVisibilityButton(course, material) {
  const hidden = course.hiddenAssignmentIDs?.includes(material.id) === true;
  return `<button class="assignment-visibility text-button" data-action="assignmentVisibility" data-id="${esc(material.id)}" data-course-id="${esc(course.id)}" data-hidden="${!hidden}" title="${hidden ? 'Show this assignment in your lists again' : 'Hide this assignment. Find it again in All assignments or Hidden.'}" aria-label="${hidden ? 'Unhide' : 'Hide'} ${esc(material.title)}">${hidden ? 'Unhide' : 'Hide'}</button>`;
}

function assignmentAgendaDaysMarkup(days, now) {
  const format = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit' });
  return days
    .map(
      (day) => `<section class="agenda-day">
    <h4 class="agenda-date" data-due-date="${esc(day.id)}">${esc(day.title)}</h4><ol>${day.items
      .map(({ course, material, details }) => {
        const date = assignmentDate(details?.dueAt),
          availability = assignmentAvailability(details, now);
        let link = '';
        try {
          const url = new URL(material.sourceURL);
          if (url.protocol === 'https:' && !url.username && !url.password) link = url.href;
        } catch {}
        return `<li class="agenda-item" data-assignment-id="${esc(material.id)}" data-course-id="${esc(course.id)}">
        <button class="agenda-open" data-action="assignment" data-id="${esc(material.id)}" data-course-id="${esc(course.id)}" aria-label="Read assignment: ${esc(material.title)}">
          <span class="agenda-title">${esc(material.title)}</span>
          <span class="agenda-item-meta"><span class="assignment-course">${esc((course.code || '').replace(/-(?:\d{2}[HV])(?:-\d{2}[HV])*$/i, '') || course.name)}</span>
            ${date ? `<time datetime="${esc(details.dueAt)}">${esc(format.format(date))}</time>` : `<small>${!details ? 'Deadline not synced' : 'No due date'}</small>`}</span>
          ${submissionBadgeMarkup(details?.status, details)}
          ${course.hiddenAssignmentIDs?.includes(material.id) ? '<small class="assignment-hidden">Hidden</small>' : ''}
          ${availability ? `<small>${esc(availability)}</small>` : ''}
        </button>
        ${link ? `<a class="agenda-canvas" href="${esc(link)}" target="_blank" rel="noreferrer" aria-label="Open ${esc(material.title)} in Canvas">↗</a>` : ''}
        ${assignmentVisibilityButton(course, material)}
      </li>`;
      })
      .join('')}</ol></section>`
    )
    .join('');
}

export function assignmentAgendaMarkup(
  courses,
  { query = '', filter = 'due', semesters = [], busy = false, refreshError = '', dedicated = false, now = new Date() } = {}
) {
  const groups = assignmentGroups(courses, { query, filter, semesters, now });
  const timeline = assignmentTimeline(groups);
  const showTimeline = filter !== 'all' && (filter === 'due' || timeline.past.length > 0 || timeline.upcoming.length > 0);
  const allOrder = ['upcoming', 'overdue', 'handedIn', 'excused', 'undated'];
  const otherGroups = filter === 'all'
    ? [...groups].sort((a, b) => allOrder.indexOf(a.timeframe) - allOrder.indexOf(b.timeframe))
    : groups.filter((group) => !['overdue', 'upcoming'].includes(group.timeframe));
  const count = groups.reduce((sum, group) => sum + group.items.length, 0);
  const handedIn = assignmentList(courses, { includeCompleted: true }).filter(({ details }) =>
    isHandedIn(details?.status)
  ).length;
  const incomplete = courses.some(
    (c) =>
      c.canvasID &&
      (!c.catalogUpdatedAt ||
        c.catalogWarnings?.some((warning) => /assignments:/i.test(warning)) ||
        c.canvasMaterials?.some(
          (m) => m.kind === 'assignments' && (!m.assignment || m.assignment.status === 'unknown')
        ))
  );
  const today = new Intl.DateTimeFormat(undefined, {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  }).format(now);
  return `<aside class="assignment-agenda" aria-label="Assignments">
    <div class="dashboard-section-heading"><h2>${dedicated ? 'Your assignments' : 'Assignments'} <span>${count}</span></h2>${!dedicated ? '<button class="text-button" data-action="assignments">View all</button>' : ''}${showTimeline ? '<button class="agenda-today-button text-button" data-action="agendaToday" aria-label="Jump to today in assignments">Today</button>' : ''}</div>
    <div class="agenda-scope"><span>All workspaces</span><select id="agenda-filter" aria-label="Assignment filter">
      ${[
        ['due', 'Due & overdue'],
        ['handedIn', 'Handed in'],
        ['all', 'All assignments'],
        ['archive', 'Archive'],
        ['hidden', 'Hidden'],
      ]
        .map(
          ([value, title]) =>
            `<option value="${value}" ${filter === value ? 'selected' : ''}>${title}</option>`
        )
        .join('')}</select></div>
    <button class="agenda-handed-in text-button" data-action="agendaHandedIn" aria-pressed="${filter === 'handedIn'}">✓ ${handedIn} handed in</button>
    <label class="dashboard-search"><span class="sr-only">Find an assignment</span><input id="assignment-search" placeholder="Find an assignment…" value="${esc(query)}"></label>
    ${incomplete ? '<div class="agenda-notice"><span>Sync Canvas to refresh deadlines and submission status.</span><button class="text-button" data-action="canvas">Connect</button></div>' : ''}
    ${refreshError ? `<p class="agenda-notice" role="status">${esc(refreshError)} <button class="text-button" data-action="canvas">Connect Canvas</button></p>` : ''}
    <div class="agenda-scroll" data-agenda-view="${esc(filter)}:${esc(query)}" tabindex="0" role="region" aria-label="Assignment timeline">
      ${
        showTimeline
          ? `<section class="agenda-timeline" aria-label="Deadlines in chronological order">
        ${timeline.past.length ? `<section class="agenda-past" aria-label="Overdue assignments">${assignmentAgendaDaysMarkup(timeline.past, now)}</section>` : ''}
        <div class="agenda-today" id="agenda-today" tabindex="-1"><strong>Today</strong><time datetime="${esc(now.toISOString())}">${esc(today)}</time></div>
        ${assignmentAgendaDaysMarkup(timeline.upcoming, now)}
        ${!timeline.upcoming.length && count ? '<p class="agenda-no-upcoming">No upcoming deadlines.</p>' : ''}
      </section>`
          : ''
      }
      ${otherGroups
        .map(
          (
            group,
            index
          ) => `${index === 0 || group.timeframe !== otherGroups[index - 1].timeframe ? `<h3 class="agenda-timeframe ${group.timeframe}">${{ overdue: 'Overdue', upcoming: 'Upcoming', undated: 'No deadline', handedIn: 'Finished · handed in', excused: 'Excused', archive: 'Archive' }[group.timeframe]} <span>${otherGroups.filter((g) => g.timeframe === group.timeframe).reduce((sum, g) => sum + g.items.length, 0)}</span></h3>` : ''}<section class="agenda-group" data-assignment-group="${esc(group.id)}" aria-label="${esc(group.title)}">
        <h3><span>${esc(group.title)}</span><span>${group.items.length}</span></h3>
        <section class="agenda-dates">${assignmentAgendaDaysMarkup(assignmentDateGroups(group.items), now)}</section></section>`
        )
        .join('')}
      ${!count ? `<div class="agenda-empty"><h3>${query.trim() ? 'No matching assignments.' : filter === 'hidden' ? 'No hidden assignments.' : filter === 'handedIn' ? 'No handed-in assignments yet.' : filter === 'all' ? 'No assignments yet.' : filter === 'archive' ? 'Nothing in the archive.' : 'No outstanding deadlines.'}</h3><p>${query.trim() ? 'Try an assignment title or course code.' : filter === 'hidden' ? 'Assignments you hide stay here. Choose Unhide to show them in your lists again.' : filter === 'handedIn' || filter === 'all' ? 'Sync Canvas to refresh submission status.' : filter === 'archive' ? 'Undated and completed assignments will be kept here.' : 'Use Handed in for submitted work, or All assignments to see everything.'}</p></div>` : ''}
    </div><p class="agenda-timezone">${filter === 'hidden' ? 'Unhide assignments to show them in your lists again' : filter === 'due' ? 'Earlier deadlines above · Upcoming below' : filter === 'handedIn' ? 'Submitted &amp; graded in Canvas' : filter === 'all' ? 'Includes hidden assignments' : 'Undated &amp; completed'} · ${esc(Intl.DateTimeFormat().resolvedOptions().timeZone)}${courses.some((course) => course.canvasID) ? ' · Canvas status refreshes every 2 minutes' : ''}</p>
  </aside>`;
}

export function assignmentsMarkup(
  courses,
  {
    query = '',
    includeCompleted = false,
    showCourse = true,
    dashboard = false,
    busy = false,
    now = new Date(),
  } = {}
) {
  const assignments = assignmentList(courses, {
    query,
    includeCompleted: !dashboard && includeCompleted,
    includeHidden: !dashboard && includeCompleted,
    includeNonSubmission: !dashboard && includeCompleted,
    dueOnly: dashboard,
  });
  const incomplete = courses.some(
    (c) =>
      c.canvasID &&
      (!c.catalogUpdatedAt ||
        c.catalogWarnings?.length ||
        c.canvasMaterials?.some(
          (m) => m.kind === 'assignments' && (!m.assignment || m.assignment.status === 'unknown')
        ))
  );
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const dateFormat = new Intl.DateTimeFormat(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
  const title = dashboard ? 'Due across your workspaces' : 'Assignment due dates';
  return `<section class="assignments${dashboard ? ' assignment-dashboard' : ''}" aria-label="${title}">
    <div class="assignments-heading"><h2>${title} <span>${assignments.length}</span></h2>
      ${
        dashboard
          ? ''
          : `<div class="tabs assignment-filters" role="group" aria-label="Assignments">
        <button data-action="assignmentFilter" data-id="pending" aria-pressed="${!includeCompleted}" class="${includeCompleted ? '' : 'active'}">To submit</button>
        <button data-action="assignmentFilter" data-id="all" aria-pressed="${includeCompleted}" class="${includeCompleted ? 'active' : ''}">All assignments</button>
      </div>`
      }</div>
    <p class="assignment-note">${dashboard ? 'Upcoming and overdue assignments from all workspaces' : 'Exercises and assignments'}, earliest deadline first. Times in ${esc(zone)}.</p>
    ${incomplete ? '<p class="assignment-notice">Some deadlines may be missing or out of date. Check for changes to refresh the list.</p>' : ''}
    ${
      assignments.length
        ? `<ol class="assignment-list">${assignments
            .map(({ course, material, details }) => {
              const date = assignmentDate(details?.dueAt),
                status = assignmentStatus(details, now),
                availability = assignmentAvailability(details, now);
              let link = '';
              try {
                const url = new URL(material.sourceURL);
                if (url.protocol === 'https:' && !url.username && !url.password) link = url.href;
              } catch {}
              return `<li class="assignment-row" data-assignment-id="${esc(material.id)}" data-course-id="${esc(course.id)}">
        <div class="assignment-main"><strong>${esc(material.title)}</strong>
          ${showCourse ? `<button class="assignment-course" data-action="course" data-id="${esc(course.id)}">${esc(course.code || course.name)}</button>` : ''}
          <div class="assignment-due">${date ? `Due <time datetime="${esc(details.dueAt)}">${esc(dateFormat.format(date))}</time>` : !details ? 'Refresh to load due date' : details.dueAt ? 'Due date unavailable' : 'No due date'}</div></div>
        <div class="assignment-state">${submissionBadgeMarkup(details?.status, details)}${course.hiddenAssignmentIDs?.includes(material.id) ? '<small class="assignment-hidden">Hidden</small>' : ''}${['Overdue', 'Missing'].includes(status) ? `<small class="assignment-overdue">${esc(status)}</small>` : ''}${availability ? `<small>${esc(availability)}</small>` : ''}</div>
        <div class="assignment-actions">${assignmentVisibilityButton(course, material)}<button data-action="assignment" data-id="${esc(material.id)}" data-course-id="${esc(course.id)}">Read assignment</button>
          ${link ? `<a href="${esc(link)}" target="_blank" rel="noreferrer" aria-label="Open ${esc(material.title)} in Canvas">Open Canvas ↗</a>` : ''}</div>
      </li>`;
            })
            .join('')}</ol>`
        : `<p class="assignment-empty">${query.trim() ? 'No matching assignments.' : dashboard ? 'No upcoming or overdue assignments in your indexed workspaces.' : `No ${includeCompleted ? 'assignments' : 'assignments to submit'} in the indexed materials for these courses.`}</p>`
    }
  </section>`;
}
