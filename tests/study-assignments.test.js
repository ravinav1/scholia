import { assignmentPageMarkup } from '../apps/web/assignment-page.js';
import test from 'node:test';
import assert from 'node:assert/strict';
import { parseHTML } from 'linkedom';
import {
  assignmentList,
  assignmentStatus,
  assignmentAvailability,
  assignmentDate,
  assignmentsMarkup,
  assignmentAgendaMarkup,
  assignmentGroups,
  selectedAssignment,
  submissionBadgeMarkup,
} from '../apps/web/assignments.js';
import { courseLibraryMarkup, courseLibraryRenderKey } from '../apps/web/course-library.js';
import { readerRenderKey } from '../apps/web/study-session.js';
import { assignmentDateGroups, assignmentTimeline } from '../apps/web/assignments.js';

test('date headers collect deadlines on the same local calendar day without merging different dates', () => {
  const due = new Date(2026, 9, 2, 9),
    evening = new Date(2026, 9, 2, 18),
    next = new Date(2026, 9, 3, 9);
  const course = {
    id: 'dates',
    name: 'Dates',
    canvasMaterials: [
      material('am', due.toISOString()),
      material('pm', evening.toISOString()),
      material('next', next.toISOString()),
      material('none', null),
    ],
  };
  const groups = assignmentDateGroups(assignmentList([course]));
  assert.deepEqual(
    groups.map((g) => g.items.map((i) => i.material.id)),
    [['am', 'pm'], ['next'], ['none']]
  );
  assert.deepEqual(
    groups.map((g) => g.id),
    ['2026-10-02', '2026-10-03', 'undated']
  );
  assert.match(
    assignmentAgendaMarkup([course], { filter: 'all', now }),
    /class="agenda-date" data-due-date="2026-10-02"/
  );
});

test('hidden assignments leave ordinary lists, stay accessible and do not change other workspaces', () => {
  const state = fixture(),
    course = state.library.courses[0];
  const before = courseLibraryRenderKey(state),
    readerBefore = readerRenderKey(state);
  course.hiddenAssignmentIDs = ['later', 'submitted'];
  assert.notEqual(courseLibraryRenderKey(state), before);
  assert.notEqual(readerRenderKey(state), readerBefore);
  assert.equal(
    assignmentList([course], { includeCompleted: true }).some((i) => i.material.id === 'later'),
    false
  );
  const hidden = assignmentAgendaMarkup([course], { filter: 'hidden', now });
  assert.match(hidden, /Unhide Exercise later/);
  assert.match(hidden, /data-hidden="false"/);
  assert.doesNotMatch(hidden, /data-assignment-id="locked"/);
  const other = { ...course, id: 'other', hiddenAssignmentIDs: [] };
  assert.equal(assignmentList([course, other]).filter((i) => i.material.id === 'later').length, 1);
});

test('All assignments includes hidden work and offers the correct visibility action in both lists', () => {
  const course = fixture().library.courses[0];
  const expected = assignmentList([course], { includeCompleted: true }).map((i) => i.material.id);
  course.hiddenAssignmentIDs = ['later', 'submitted'];
  assert.deepEqual(
    assignmentList([course], { includeCompleted: true, includeHidden: true }).map(
      (i) => i.material.id
    ),
    expected
  );
  assert.deepEqual(
    assignmentList([course], { includeCompleted: true, includeHidden: true, hiddenOnly: true }).map(
      (i) => i.material.id
    ),
    ['submitted', 'later']
  );
  for (const html of [
    assignmentAgendaMarkup([course], { filter: 'all', now }),
    assignmentsMarkup([course], { includeCompleted: true, now }),
  ]) {
    const { document } = parseHTML(html);
    const rows = [...document.querySelectorAll('[data-assignment-id]')];
    assert.deepEqual(rows.map((row) => row.dataset.assignmentId).sort(), [...expected, 'none', 'optional'].sort());
    for (const row of rows) {
      const hidden = course.hiddenAssignmentIDs.includes(row.dataset.assignmentId);
      const button = row.querySelector('[data-action="assignmentVisibility"]');
      assert.equal(button.textContent, hidden ? 'Unhide' : 'Hide');
      assert.equal(button.dataset.hidden, String(!hidden));
      assert.equal(!!row.querySelector('.assignment-hidden'), hidden);
    }
    assert.doesNotMatch(html, /Remove from list|Restore/);
  }
  const search = assignmentGroups([course], { filter: 'all', query: 'later', now });
  assert.deepEqual(
    search.flatMap((group) => group.items.map((i) => i.material.id)),
    ['later']
  );
  course.hiddenAssignmentIDs = [];
  assert.ok(assignmentList([course]).some((i) => i.material.id === 'later'));
  assert.equal(assignmentGroups([course], { filter: 'hidden', now }).length, 0);
});

const now = new Date('2026-09-27T10:00:00Z');
function material(id, dueAt, overrides = {}) {
  return {
    id,
    title: `Exercise ${id}`,
    kind: 'assignments',
    sourceURL: `https://canvas.example/courses/1/assignments/${id}`,
    assignment: {
      dueAt,
      submissionTypes: ['online_upload'],
      status: 'notSubmitted',
      locked: false,
      missing: false,
      ...overrides,
    },
  };
}
function fixture() {
  const course = {
    id: 'c1',
    canvasID: 1,
    name: 'Algebra',
    code: 'MATH101',
    documents: [],
    catalogUpdatedAt: 1,
    canvasMaterials: [
      material('later', '2026-10-02T18:00:00Z'),
      material('overdue', '2026-09-26T12:00:00Z'),
      material('undated', null),
      material('submitted', '2026-09-28T08:00:00Z', { status: 'submitted' }),
      material('excused', null, { status: 'excused' }),
      material('graded', null, { status: 'graded' }),
      material('optional', null, { submissionTypes: ['not_graded'] }),
      material('none', null, { submissionTypes: ['none'] }),
      material('locked', '2026-10-05T08:00:00Z', {
        locked: true,
        unlockAt: '2026-10-01T10:00:00Z',
      }),
      { id: 'pdf', kind: 'files', title: 'exercise.pdf' },
      { id: 'legacy', kind: 'assignments', title: 'Old assignment' },
    ],
  };
  return {
    library: { courses: [course], selectedCourseID: 'c1', courseLibraryView: 'all' },
    selectedSemesterID: 'all',
    semesters: [],
    materialGroups: [],
  };
}

test('outstanding list orders deadlines, keeps locked and undated work, excludes completed and non-submission materials', () => {
  const courses = fixture().library.courses;
  assert.deepEqual(
    assignmentList(courses).map((row) => row.material.id),
    ['overdue', 'later', 'locked', 'undated', 'legacy']
  );
  assert.equal(assignmentList(courses, { includeCompleted: true }).length, 8);
  assert.equal(assignmentList(courses, { query: 'math101' }).length, 5);
  assert.deepEqual(
    assignmentList(courses, { query: 'later' }).map((row) => row.material.id),
    ['later']
  );
});

test('dashboard orders past and future deadlines independently of workspace filters', () => {
  const state = fixture();
  state.library.courseLibraryView = 'all';
  state.selectedSemesterID = 'autumn';
  state.semesters = [{ id: 'autumn', title: 'Autumn 2026', courseIDs: ['c1'] }];
  state.library.courses.push({
    id: 'c2',
    canvasID: 2,
    name: 'Programming',
    code: 'CS101',
    documents: [],
    catalogUpdatedAt: 1,
    canvasMaterials: [
      material('other-workspace', '2026-09-28T12:00:00Z'),
      material('invalid-date', 'invalid'),
    ],
  });
  const due = assignmentList(state.library.courses, { dueOnly: true });
  assert.deepEqual(
    due.map(({ material }) => material.id),
    ['overdue', 'other-workspace', 'later', 'locked']
  );
  const html = courseLibraryMarkup(state, 'Algebra', { now });
  assert.match(html, /All workspaces/);
  assert.match(html, /data-assignment-id="other-workspace" data-course-id="c2"/);
  assert.match(html, /data-assignment-id="overdue"/);
  assert.ok(
    html.indexOf('data-assignment-id="other-workspace"') >
      html.indexOf('data-assignment-id="overdue"')
  );
  assert.doesNotMatch(
    html,
    /data-assignment-id="(?:submitted|excused|graded|undated|legacy|invalid-date)"/
  );
  assert.doesNotMatch(html, /data-action="assignmentFilter"/);
  assert.match(html, /class="dashboard-columns"/);
  assert.match(html, /class="workspace-panel"/);
  state.library.courses[1].canvasMaterials = Array.from({ length: 15 }, (_, i) =>
    material(`extra-${i}`, '2026-10-06T10:00:00Z')
  );
  assert.equal(
    (courseLibraryMarkup(state, '', { now }).match(/data-assignment-id=/g) || []).length,
    18,
    'no arbitrary preview limit hides due work'
  );
});

test('dashboard has an honest empty state and changes when deadlines or submission statuses change', () => {
  const state = fixture();
  state.library.courseLibraryView = 'all';
  let before = courseLibraryRenderKey(state);
  state.library.courses[0].canvasMaterials[0].assignment.dueAt = '2026-10-03T18:00:00Z';
  assert.notEqual(courseLibraryRenderKey(state), before);
  before = courseLibraryRenderKey(state);
  state.library.courses[0].canvasMaterials[0].assignment.status = 'submitted';
  assert.notEqual(courseLibraryRenderKey(state), before);
  state.library.courses[0].canvasMaterials = [
    material('undated', null),
    material('done', now.toISOString(), { status: 'submitted' }),
  ];
  assert.match(courseLibraryMarkup(state, '', { now }), /No outstanding deadlines/);
  assert.doesNotMatch(courseLibraryMarkup(state, '', { now }), /data-assignment-id=/);
});

test('deadline and availability use absolute instants, and completed statuses never become overdue', () => {
  assert.equal(
    assignmentStatus(material('a', '2026-09-27T12:00:00+02:00').assignment, now),
    'Due today'
  );
  assert.equal(
    assignmentStatus(material('a', '2026-09-27T11:59:59.999+02:00').assignment, now),
    'Overdue'
  );
  assert.equal(
    assignmentStatus(
      material('a', '2026-09-01T00:00:00Z', { status: 'submitted' }).assignment,
      now
    ),
    'Handed in'
  );
  assert.equal(assignmentStatus(undefined, now), 'Status not synced');
  assert.equal(assignmentStatus(material('a', null, { missing: true }).assignment, now), 'Missing');
  assert.equal(
    assignmentAvailability({ locked: true, unlockAt: '2026-10-01T00:00:00Z' }, now),
    'Not open yet'
  );
  assert.equal(assignmentAvailability({ lockAt: now.toISOString() }, now), 'Closed');
  assert.equal(assignmentDate('invalid'), null);
});

test('assignment search and filters work independently of the workspace and semester filters', () => {
  const state = fixture();
  state.library.courses.push({
    ...state.library.courses[0],
    id: 'past',
    code: 'OLD',
    canvasMaterials: [material('past-only', '2025-01-01T00:00:00Z')],
  });
  state.semesters = [
    { id: 'autumn', title: 'Autumn 2026', courseIDs: ['c1'] },
    { id: 'spring', title: 'Spring 2027', courseIDs: ['c1'] },
  ];
  state.selectedSemesterID = 'autumn';
  const html = courseLibraryMarkup(state, 'no matching course', { query: 'later', now });
  assert.match(html, /No matching workspaces/);
  assert.match(html, /Exercise later/);
  assert.doesNotMatch(html, /Exercise past-only|Exercise overdue/);
  assert.match(courseLibraryMarkup(state, '', { now }), /Exercise past-only/);
  assert.doesNotMatch(
    courseLibraryMarkup(state, '', { filter: 'archive', now }),
    /Exercise past-only/
  );
  assert.equal(
    (courseLibraryMarkup(state, '', { now }).match(/data-assignment-id="later"/g) || []).length,
    1
  );
});

test('agenda puts older overdue dates first and archives undated and completed work', () => {
  const state = fixture();
  state.library.courses[0].canvasMaterials.push(
    material('exact-now', '2026-09-27T12:00:00+02:00'),
    material('invalid', 'invalid')
  );
  const groups = assignmentGroups(state.library.courses, { now });
  const upcoming = groups.filter((g) => g.timeframe === 'upcoming').flatMap((g) => g.items);
  const overdue = groups.filter((g) => g.timeframe === 'overdue').flatMap((g) => g.items);
  const archived = assignmentGroups(state.library.courses, { now, filter: 'archive' }).flatMap(
    (g) => g.items
  );
  assert.deepEqual(
    upcoming.map((i) => i.material.id),
    ['later', 'locked']
  );
  assert.deepEqual(
    groups.map((g) => g.timeframe),
    ['overdue', 'upcoming']
  );
  assert.deepEqual(
    overdue.map((i) => i.material.id),
    ['overdue', 'exact-now']
  );
  assert.deepEqual(
    archived.map((i) => i.material.id),
    ['submitted', 'excused', 'graded', 'invalid', 'none', 'optional', 'undated', 'legacy']
  );
  assert.equal(
    upcoming.length + overdue.length + archived.length,
    assignmentList(state.library.courses, { includeCompleted: true, includeNonSubmission: true }).length
  );
  assert.match(courseLibraryMarkup(state, '', { filter: 'archive', now }), /Deadline not synced/);
  assert.doesNotMatch(courseLibraryMarkup(state, '', { now }), /Deadline not synced/);
});

test('the timeline interleaves courses and semesters chronologically around the current date', () => {
  const courses = [
    {
      id: 'one',
      name: 'One',
      term: 'Autumn 2026',
      canvasMaterials: [
        material('oldest', '2025-10-01T12:00:00Z'),
        material('recent', '2026-09-26T12:00:00Z'),
        material('exact-now', now.toISOString()),
        material('later', '2026-10-03T12:00:00Z'),
      ],
    },
    {
      id: 'two',
      name: 'Two',
      term: 'Spring 2026',
      canvasMaterials: [
        material('middle', '2026-08-10T12:00:00Z'),
        material('today-later', '2026-09-27T12:00:00Z'),
        material('soon', '2026-10-01T12:00:00Z'),
      ],
    },
  ];
  const timeline = assignmentTimeline(assignmentGroups(courses, { now }));
  assert.deepEqual(
    timeline.past.flatMap((day) => day.items.map((item) => item.material.id)),
    ['oldest', 'middle', 'recent', 'exact-now']
  );
  assert.deepEqual(
    timeline.upcoming.flatMap((day) => day.items.map((item) => item.material.id)),
    ['today-later', 'soon', 'later']
  );
  const { document } = parseHTML(assignmentAgendaMarkup(courses, { now }));
  assert.deepEqual(
    [...document.querySelectorAll('[data-assignment-id], #agenda-today')].map(
      (node) => node.dataset.assignmentId || 'today'
    ),
    ['oldest', 'middle', 'recent', 'exact-now', 'today', 'today-later', 'soon', 'later']
  );
  assert.equal(
    document.querySelector('#agenda-today time').getAttribute('datetime'),
    now.toISOString()
  );
  assert.ok(document.querySelector('[data-action="agendaToday"]'));
});

test('today remains a timeline anchor with only overdue, only future, or no deadlines', () => {
  for (const materials of [
    [],
    [material('past', '2026-09-01T12:00:00Z')],
    [material('future', '2026-10-01T12:00:00Z')],
  ]) {
    const { document } = parseHTML(
      assignmentAgendaMarkup([{ id: 'one', name: 'One', canvasMaterials: materials }], { now })
    );
    assert.equal(document.querySelectorAll('#agenda-today').length, 1);
    assert.equal(document.querySelectorAll('[data-assignment-id]').length, materials.length);
  }
});

test('multi-term courses use the deadline semester once and preserve deadline order within each group', () => {
  const courses = [
    {
      id: 'year',
      name: 'Year course',
      code: 'YEAR',
      canvasMaterials: [
        material('autumn-late', '2026-11-01T12:00:00Z'),
        material('spring', '2027-02-01T12:00:00Z'),
        material('autumn-early', '2026-10-01T12:00:00Z'),
      ],
    },
    {
      id: 'past',
      name: 'Older course',
      code: 'OLD',
      canvasMaterials: [material('resit', '2026-10-01T12:00:00Z')],
    },
  ];
  const semesters = [
    { id: '2027-spring', title: 'Spring 2027', courseIDs: ['year'] },
    { id: '2026-autumn', title: 'Autumn 2026', courseIDs: ['year'] },
    { id: '2025-autumn', title: 'Autumn 2025', courseIDs: ['past'] },
  ];
  const groups = assignmentGroups(courses, { now, semesters });
  assert.deepEqual(
    groups.map((g) => g.title),
    ['Autumn 2026', 'Autumn 2025', 'Spring 2027']
  );
  assert.deepEqual(
    groups.map((g) => g.items.map((i) => i.material.id)),
    [['autumn-early', 'autumn-late'], ['resit'], ['spring']]
  );
});

test('list shows dates, unknown metadata and safe links, escaping Canvas content', () => {
  const state = fixture(),
    course = state.library.courses[0];
  course.canvasMaterials[0].title = '<img src=x onerror=alert(1)>';
  course.canvasMaterials[0].sourceURL = 'javascript:alert(1)';
  const html = assignmentsMarkup([course], { now });
  assert.match(html, /datetime="2026-09-26T12:00:00Z"/);
  assert.match(html, /No due date/);
  assert.match(html, /Refresh to load due date/);
  assert.match(html, /Some deadlines may be missing/);
  assert.match(html, /&lt;img/);
  assert.doesNotMatch(html, /javascript:|<img/);
  assert.match(
    html,
    /data-action="assignment" data-id="locked" data-course-id="c1">Read assignment/
  );
  assert.match(html, /Open Canvas/);
  assert.match(assignmentsMarkup([], { now }), /in the indexed materials/);
});

test('the assignment agenda uses one assignment target for the title, course and deadline', () => {
  const html = assignmentAgendaMarkup(fixture().library.courses, { now });
  assert.match(
    html,
    /<button class="agenda-open" data-action="assignment"[^>]*>[\s\S]*class="agenda-title"[\s\S]*class="assignment-course"[\s\S]*<time[^>]*>[\s\S]*<\/button>/
  );
  assert.doesNotMatch(html, /data-action="course"/);
  for (const [button] of html.matchAll(/<button\b[^>]*>[\s\S]*?<\/button>/g)) {
    assert.equal((button.match(/<button\b/g) || []).length, 1);
    assert.doesNotMatch(button, /<a\b/);
  }
});

test('assignment page lists included files and their companion availability inside the workspace', () => {
  const state = fixture();
  state.library.selectedAssignmentID = 'later';
  state.library.selectedDocumentID = 'pdf-doc';
  state.library.courses[0].documents.push(
    { id: 'pdf-doc', sourceKey: 'files:12', kind: 'pdf', pageCount: 2 },
    { id: 'input-doc', sourceKey: 'files:14', kind: 'code', pageCount: 1 },
    { id: 'binary-doc', sourceKey: 'files:15', kind: 'preview', pageCount: 1 }
  );
  state.assignmentText = 'Solve **both problems**. <script>alert(1)</script>';
  state.assignmentFiles = [
    { id: 'files:12', title: 'Exercises.pdf' },
    { id: 'files:13', title: '<img src=x>.pdf' },
    { id: 'files:14', title: 'in.nanowire' },
    { id: 'files:15', title: 'data.bin' },
    { id: 'files:16', title: 'Ni.eam' },
    { id: 'files:17', title: 'oversized.pdf', byteCount: 100_000_001 },
  ];
  state.assignmentFileNotices = { 'files:16': 'Could not download <file>' };
  const html = assignmentPageMarkup(state);
  assert.match(html, /Exercise later/);
  assert.match(html, /Due /);
  assert.match(html, /<strong>both problems<\/strong>/);
  assert.match(
    html,
    /data-action="assignmentFile" data-id="files:12" data-assignment-id="later" data-course-id="c1" aria-pressed="true"/
  );
  assert.match(html, /data-id="files:13"[^>]+aria-pressed="false"/);
  assert.doesNotMatch(html, /<script|<img|target="_blank"|<iframe/);
  assert.match(html, /&lt;img/);
  const { document } = parseHTML(html);
  assert.equal(document.querySelectorAll('.assignment-file-list button').length, 6);
  assert.match(
    document.querySelector('[data-id="files:14"]').textContent,
    /in.nanowire.*Ready for companion/
  );
  assert.match(document.querySelector('[data-id="files:15"]').textContent, /No readable text/);
  assert.match(
    document.querySelector('[data-id="files:13"]').textContent,
    /Open to add to companion/
  );
  assert.match(
    document.querySelector('[data-id="files:16"]').textContent,
    /Could not download <file>/
  );
  assert.ok(document.querySelector('[data-id="files:17"]').hasAttribute('disabled'));
  state.busy = true;
  let syncing = parseHTML(assignmentPageMarkup(state)).document;
  assert.equal(syncing.querySelectorAll('.assignment-file-list button[disabled]').length, 1,
    'Bulk Canvas sync must not disable included files');
  assert.doesNotMatch(syncing.querySelector('[data-id="files:13"]').textContent, /Preparing/);
  state.assignmentPreparing = true;
  state.assignmentPreparingFileID = 'files:13';
  syncing = parseHTML(assignmentPageMarkup(state)).document;
  assert.match(syncing.querySelector('[data-id="files:13"]').textContent, /Preparing/);
  assert.equal(syncing.querySelectorAll('.assignment-file-list button[disabled]').length, 1,
    'Another file can be opened to reprioritize assignment preparation');
  state.library.selectedCourseID = 'missing';
  assert.equal(selectedAssignment(state), undefined);
  assert.equal(assignmentPageMarkup(state), '');
});

test('assignment page distinguishes no attachment, loading, locked and failed download states', () => {
  const state = fixture();
  state.library.selectedAssignmentID = 'later';
  state.library.courses[0].canvasMaterials[0].assignment.linkedFileIDs = [];
  assert.match(assignmentPageMarkup(state), /No files are linked/);
  state.busy = true;
  assert.match(assignmentPageMarkup(state), /No files are linked/);
  assert.doesNotMatch(assignmentPageMarkup(state), /Opening assignment files/);
  state.assignmentPreparing = true;
  assert.match(assignmentPageMarkup(state), /Opening assignment files/);
  assert.doesNotMatch(assignmentPageMarkup(state), /No files are linked/);
  state.assignmentPreparing = false;
  state.assignmentNotice = 'Could not load all assignment files.';
  assert.match(
    assignmentPageMarkup(state),
    /data-action="assignment" data-id="later" data-course-id="c1" >Retry/
  );
  state.library.selectedAssignmentID = 'locked';
  assert.match(assignmentPageMarkup(state), /Locked in Canvas/);
  assert.doesNotMatch(assignmentPageMarkup(state), />Retry/);
});

test('a deadline or submission change repaints the library and course even if assignment count and version stay unchanged', () => {
  const state = fixture(),
    beforeLibrary = courseLibraryRenderKey(state),
    beforeReader = readerRenderKey(state);
  state.library.courses[0].canvasMaterials[0].assignment.dueAt = null;
  assert.notEqual(courseLibraryRenderKey(state), beforeLibrary);
  assert.notEqual(readerRenderKey(state), beforeReader);
  const beforeStatus = courseLibraryRenderKey(state);
  state.library.courses[0].canvasMaterials[0].assignment.status = 'submitted';
  assert.notEqual(courseLibraryRenderKey(state), beforeStatus);
});

test('handed-in filter shows submitted and graded work, separately from excused or unknown work', () => {
  const courses = fixture().library.courses;
  courses[0].canvasMaterials.push(material('unknown', null, { status: 'unknown' }));
  const groups = assignmentGroups(courses, { now, filter: 'handedIn' });
  assert.deepEqual(
    groups.flatMap((g) => g.items.map((i) => i.material.id)),
    ['submitted', 'graded']
  );
  assert.ok(groups.every((g) => g.timeframe === 'handedIn'));
  const all = assignmentGroups(courses, { now, filter: 'all' }).flatMap((g) => g.items);
  assert.equal(all.length, assignmentList(courses, { includeCompleted: true, includeNonSubmission: true }).length);
  assert.equal(new Set(all.map((i) => i.material.id)).size, all.length);
  const html = assignmentAgendaMarkup(courses, { now, filter: 'handedIn' });
  assert.match(html, /2 handed in/);
  assert.match(html, /Handed in · graded/);
  assert.doesNotMatch(html, /data-assignment-id="(?:excused|unknown|overdue)"/);
  assert.match(submissionBadgeMarkup('notSubmitted'), /Not handed in/);
  assert.match(submissionBadgeMarkup('unknown'), /Status not synced/);
  assert.doesNotMatch(submissionBadgeMarkup('excused'), /handed-in|✓/);
  assert.equal(
    assignmentStatus({ status: 'unknown', dueAt: '2020-01-01' }, now),
    'Status not synced'
  );
});

test('All assignments shows upcoming work first and retains overdue, finished, hidden and non-upload work', () => {
  const state = fixture();
  state.library.courseLibraryView = 'assignments';
  const course = state.library.courses[0];
  course.canvasMaterials.push(
    material('paper-grade', '2026-09-01T00:00:00Z', { status: 'graded', submissionTypes: ['none'] }),
    material('external-complete', '2026-09-02T00:00:00Z', { status: 'graded', submissionTypes: [] }),
  );
  course.hiddenAssignmentIDs = ['submitted'];
  const { document } = parseHTML(courseLibraryMarkup(state, 'unrelated course search', { now }));
  assert.ok(document.querySelector('.assignments-overview'));
  assert.equal(document.querySelector('.workspace-panel'), null);
  assert.equal(document.querySelector('#agenda-filter option[selected]').value, 'all');
  const rows = [...document.querySelectorAll('[data-assignment-id]')];
  assert.equal(rows.length, course.canvasMaterials.filter((m) => m.kind === 'assignments').length);
  assert.deepEqual(rows.slice(0, 2).map((row) => row.dataset.assignmentId), ['later', 'locked']);
  assert.equal(rows[2].dataset.assignmentId, 'overdue');
  assert.match(rows[1].textContent, /Not open yet/);
  for (const id of ['submitted', 'graded', 'paper-grade', 'external-complete']) {
    assert.ok(document.querySelector(`[data-assignment-id="${id}"] .submission-badge.handed-in`));
    assert.equal(assignmentList([course]).some((row) => row.material.id === id), false);
  }
  assert.match(document.querySelector('.agenda-timeframe').textContent, /Upcoming/);
  assert.match(document.querySelector('.agenda-timeframe.handedIn').textContent, /Finished/);
  assert.ok(document.querySelector('[data-action="refreshAssignments"]'));
  assert.match(courseLibraryMarkup(state, '', { query: 'paper-grade', now }), /Exercise paper-grade/);
  assert.doesNotMatch(courseLibraryMarkup(state, '', { query: 'paper-grade', now }), /Exercise overdue/);
});
