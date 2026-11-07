import test from 'node:test';
import assert from 'node:assert/strict';
import { libraryCourses, librarySemesterGroups, courseLibraryMarkup, courseLibraryRenderKey, courseDisplayCode } from '../../apps/web/workspace/course-library.js';

function fixture() {
  return {
    library: { courseLibraryView: 'semesters', courses: [
      { id: 'year', name: 'Year course', code: 'BIO1000', term: '2026 HØST|2027 VÅR', documents: [] },
      { id: 'fall', name: 'Zoology', code: 'BIO1001', term: '2026 HØST', favorite: true, documents: [] },
      { id: 'spring', name: 'Ecology', code: 'BIO1002', term: '2026 VÅR', documents: [] }
    ] },
    selectedSemesterID: 'all', semesters: [
      { id: '2027-spring', title: 'Spring 2027', courseIDs: ['year'], isCurrent: false },
      { id: '2026-autumn', title: 'Autumn 2026', courseIDs: ['year', 'fall'], isCurrent: true },
      { id: '2026-spring', title: 'Spring 2026', courseIDs: ['spring'], isCurrent: false }
    ]
  };
}

test('semester sections preserve courses spanning terms and favorite ordering', () => {
  const state = fixture();
  const groups = librarySemesterGroups(state, libraryCourses(state));
  assert.deepEqual(groups.map((g) => g.courses.map((c) => c.id)), [['year'], ['fall', 'year'], ['spring']]);
});

test('semester selection intersects with search without leaking other courses', () => {
  const state = fixture(); state.selectedSemesterID = '2026-autumn';
  assert.deepEqual(librarySemesterGroups(state, libraryCourses(state, 'BIO1000')).map((g) => g.courses.map((c) => c.id)), [['year']]);
  assert.deepEqual(librarySemesterGroups(state, libraryCourses(state, 'Ecology')), []);
  assert.match(courseLibraryMarkup(state, 'Ecology'), /No matching workspaces/);
  assert.doesNotMatch(courseLibraryMarkup(state, 'Ecology'), /class="course-card"/);
});

test('workspace filters combine semester and favorites without hiding the assignment panel', () => {
  const state = fixture(); state.selectedSemesterID = '2026-spring'; state.library.courseLibraryView = 'favorites';
  assert.deepEqual(libraryCourses(state), []);
  state.selectedSemesterID = '2026-autumn';
  assert.deepEqual(libraryCourses(state).map((c) => c.id), ['fall']);
  state.library.courseLibraryView = 'all';
  assert.deepEqual(libraryCourses(state).map((c) => c.id), ['fall', 'year']);
  const html = courseLibraryMarkup(state);
  assert.match(html, /class="workspace-panel"/);
  assert.match(html, /class="assignment-agenda"/);
  assert.doesNotMatch(html, /aria-label="Course view"|data-action="semesters"/);
  assert.match(html, /data-action="assignments">View all/);
});

test('semester labels and course metadata are escaped and the current shortcut uses the correct term', () => {
  const state = fixture(); state.semesters[1].title = '<img src=x>';
  const html = courseLibraryMarkup(state, '" onfocus="alert(1)');
  assert.ok(!html.includes('<img src=x>'));
  assert.match(html, /&lt;img src=x&gt;/);
  assert.match(html, /data-action="semester" data-id="2026-autumn"/);
  assert.match(html, /value="&quot; onfocus=&quot;alert\(1\)"/);
});

test('course cards have neutral identifiers and avoid redraws for unchanged metadata checks', () => {
  const state = fixture(); state.library.courses[0].catalogUpdatedAt = 1;
  const before = courseLibraryRenderKey(state);
  state.library.courses[0].catalogUpdatedAt = 100;
  assert.equal(courseLibraryRenderKey(state), before);
  state.library.courses[0].catalogChanges = { added: ['files:1'], updated: [], removed: [] };
  assert.notEqual(courseLibraryRenderKey(state), before);
  assert.equal(courseDisplayCode({ code: 'BBAN4040-26H-27V' }), 'BBAN4040');
  assert.doesNotMatch(courseLibraryMarkup(state), /course-glyph|Σ|⚡/);
  assert.match(courseLibraryMarkup(state), /1 new/);
});
