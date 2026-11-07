import { escapeHtml as esc } from '../../chrome/src/html-escape.js';
import { recentReadings, continueReadingMarkup, studyRenderKey } from './study-session.js';
import { assignmentAgendaMarkup } from './assignments.js';
import { examDashboardMarkup } from '../exams/exam-planner.js';

const button = (label, action, id = '', cls = '') =>
  `<button class="${cls}" data-action="${action}" data-id="${esc(id)}">${label}</button>`;

export function courseDisplayName(course) {
  const prefix = `${course.code} :: `;
  return course.code && course.name.startsWith(prefix)
    ? course.name.slice(prefix.length).trim() || course.name
    : course.name;
}
export function courseDisplayCode(course) {
  return (course.code || '').replace(/-(?:\d{2}[HV])(?:-\d{2}[HV])*$/i, '');
}
export function catalogChangeSummary(changes) {
  return [
    ['added', 'new'],
    ['updated', 'updated'],
    ['removed', 'removed'],
  ]
    .filter(([key]) => changes?.[key]?.length)
    .map(([key, label]) => `${changes[key].length} ${label}`)
    .join(' · ');
}

// Checking timestamps and unchanged metadata must not recreate every card.
export function courseLibraryRenderKey(state) {
  return studyRenderKey([
    state.library.courses.map((c) => [
      c.id,
      c.name,
      c.code,
      c.term,
      c.favorite,
      c.canvasID,
      c.hiddenAssignmentIDs,
      c.canvasOrigin,
      c.canvasAvailable,
      !!c.catalogUpdatedAt,
      c.canvasMaterials?.length || 0,
      c.documents.length,
      c.catalogChanges?.added,
      c.catalogChanges?.updated,
      c.catalogChanges?.removed,
      !!c.catalogWarnings?.length,
    ]),
    state.library.courseLibraryView,
    state.library.examPlan,
    state.selectedSemesterID,
    state.semesters,
    state.busy,
    state.assignmentRefreshBusy,
    state.library.canvasCheckedAt,
    state.library.canvasAssignmentsError,
    state.library.canvasRefreshSummary,
    [
      Math.floor(Date.now() / 60000),
      state.library.courses.map((c) => c.canvasMaterials?.filter((m) => m.kind === 'assignments')),
    ],
    recentReadings(state.library.courses).map(({ course, document }) => [
      course.id,
      document.id,
      document.title,
      document.kind,
      document.lastPage,
      document.pageCount,
    ]),
  ]);
}

export function libraryCourses(state, query = '') {
  const favorites = state.library.courseLibraryView === 'favorites';
  const semester = state.selectedSemesterID || 'all';
  const courseIDs = state.semesters?.find((group) => group.id === semester)?.courseIDs || [];
  return [...state.library.courses]
    .filter(
      (c) =>
        (!favorites || c.favorite) &&
        (semester === 'all' || courseIDs.includes(c.id)) &&
        `${c.name} ${c.code} ${c.term || ''}`
          .toLocaleLowerCase()
          .includes(query.trim().toLocaleLowerCase())
    )
    .sort((a, b) => Number(!!b.favorite) - Number(!!a.favorite) || a.name.localeCompare(b.name));
}

export function librarySemesterGroups(state, courses) {
  return (state.semesters || [])
    .filter((group) => state.selectedSemesterID === 'all' || group.id === state.selectedSemesterID)
    .map((group) => ({ ...group, courses: courses.filter((c) => group.courseIDs.includes(c.id)) }))
    .filter((group) => group.courses.length);
}

function courseCard(c, terms) {
  let origin = 'Canvas';
  try {
    origin += ` · ${new URL(c.canvasOrigin).hostname}`;
  } catch {}
  const changes = catalogChangeSummary(c.catalogChanges);
  return `<article class="course-card">
    <div class="card-top"><div class="card-code">${esc(courseDisplayCode(c) || (c.canvasID ? 'CANVAS COURSE' : 'PERSONAL WORKSPACE'))}</div>
      <button class="favorite" data-action="favorite" data-id="${esc(c.id)}" aria-pressed="${!!c.favorite}" aria-label="Favorite ${esc(c.name)}">${c.favorite ? '★' : '☆'}</button></div>
    <button class="card-open" data-action="course" data-id="${esc(c.id)}" title="${esc(courseDisplayName(c))}">
      <h3>${esc(courseDisplayName(c))}</h3><div class="card-term">${esc(terms.get(c.id) || c.term || (c.canvasID ? origin : 'Your own pace'))}</div>
      <div class="card-update ${changes ? 'has-changes' : ''}">${esc(c.canvasAvailable === false ? 'No longer listed in Canvas' : changes || (c.catalogWarnings?.length ? 'Some sections unavailable' : ''))}</div>
      <div class="card-footer"><span>${c.canvasID ? (c.catalogUpdatedAt ? `${c.canvasMaterials?.length || 0} materials · ${c.documents.length} saved` : 'Ready to index') : `${c.documents.length} documents`}</span><b>↗</b></div>
    </button><button class="course-practice-entry" data-action="practiceCourse" data-id="${esc(c.id)}">Practice course →</button></article>`;
}
const courseGrid = (courses, terms) =>
  `<div class="cards">${courses.map((c) => courseCard(c, terms)).join('')}</div>`;

export function workspacePanelMarkup(state, query = '') {
  const courses = libraryCourses(state, query);
  const favorites = state.library.courseLibraryView === 'favorites';
  const terms = new Map();
  for (const group of state.semesters || []) {
    if (group.id === 'unassigned') continue;
    for (const id of group.courseIDs)
      terms.set(id, [terms.get(id), group.title].filter(Boolean).join(' · '));
  }
  const current = state.semesters?.find((group) => group.isCurrent);
  const workspaceFilters = `<div class="workspace-filters">
    <label class="dashboard-search"><span class="sr-only">Find a workspace</span><input id="course-search" placeholder="Find a workspace…" value="${esc(query)}"></label>
    <div class="workspace-semester"><label><span class="sr-only">Semester</span><select id="semester-picker" aria-label="Semester">
      <option value="all" ${!state.selectedSemesterID || state.selectedSemesterID === 'all' ? 'selected' : ''}>All semesters</option>
      ${(state.semesters || []).map((group) => `<option value="${esc(group.id)}" ${group.id === state.selectedSemesterID ? 'selected' : ''}>${esc(group.title)}</option>`).join('')}</select></label>
      ${current && state.selectedSemesterID !== current.id ? button('This semester', 'semester', current.id, 'text-button') : ''}
    </div></div>`;
  const emptyState = `<div class="empty-library"><h2>${state.library.courses.length ? 'No matching workspaces.' : 'Make room for a course.'}</h2>
    <p>${state.library.courses.length ? 'Try another name, semester, or workspace filter.' : 'Connect Canvas or create a workspace for your readings.'}</p>
    ${!state.library.courses.length ? button('Create workspace', 'create') : ''}</div>`;
  return `<section class="workspace-panel" aria-label="Workspaces">
        <div class="dashboard-section-heading"><h2>Workspaces <span>${courses.length}</span></h2>
          <select id="workspace-filter" aria-label="Workspace filter"><option value="all" ${!favorites ? 'selected' : ''}>All workspaces</option><option value="favorites" ${favorites ? 'selected' : ''}>Favorites</option></select></div>
        ${workspaceFilters}
        <div class="workspace-scroll">
          ${!query.trim() && !favorites ? continueReadingMarkup(recentReadings(state.library.courses, 2)) : ''}
          ${courses.length ? courseGrid(courses, terms) : emptyState}
          <p class="library-footnote">☆ Canvas favorites and your pinned workspaces stay first.</p>
        </div>
      </section>`;
}

export function courseLibraryMarkup(state, query = '', assignmentOptions = {}) {
  if (state.library.courseLibraryView === 'assignments') {
    return `<div class="library-inner assignments-overview">
      <header class="dashboard-heading"><div><h1>Assignments</h1><p>Every workspace. Upcoming work and everything you have finished.</p></div>
      <button class="refresh-courses" data-action="refreshAssignments" ${state.busy || state.assignmentRefreshBusy ? 'disabled' : ''}>${state.assignmentRefreshBusy ? 'Refreshing…' : '↻ Refresh status'}</button></header>
      ${assignmentAgendaMarkup(state.library.courses, { filter: 'all', ...assignmentOptions, dedicated: true, semesters: state.semesters, busy: state.busy, refreshError: state.library.canvasAssignmentsError })}
      </div>`;
  }
  return `<div class="library-inner study-dashboard">
    <header class="dashboard-heading"><div><h1>Your study workspace</h1><p>Pick up a reading. Keep your next deadline in sight.</p></div>
      <button class="refresh-courses" data-action="index" ${state.busy ? 'disabled' : ''}>${state.busy ? 'Refreshing…' : '↻ Refresh Canvas'}</button></header>
    ${examDashboardMarkup(state)}
    <div class="dashboard-panel-switch" role="group" aria-label="Dashboard view">
      <button data-action="dashboardPanel" data-id="workspaces" aria-pressed="true">Workspaces</button>
      <button data-action="dashboardPanel" data-id="assignments" aria-pressed="false">Assignments</button>
    </div>
    <div class="dashboard-columns">
      ${workspacePanelMarkup(state, query)}
      ${assignmentAgendaMarkup(state.library.courses, { ...assignmentOptions, semesters: state.semesters, busy: state.busy, refreshError: state.library.canvasAssignmentsError })}
    </div></div>`;
}
