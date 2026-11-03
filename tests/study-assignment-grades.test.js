import { assignmentPageMarkup } from '../apps/web/assignment-page.js';
import test from 'node:test';
import assert from 'node:assert/strict';
import { parseHTML } from 'linkedom';
import {
  assignmentGrade,
  assignmentAgendaMarkup,
  assignmentsMarkup,
} from '../apps/web/assignments.js';
import { courseLibraryRenderKey } from '../apps/web/course-library.js';
import { readerRenderKey } from '../apps/web/study-session.js';
import { materialGroupsMarkup } from '../apps/web/materials.js';

const details = {
  status: 'graded',
  submissionTypes: ['online_upload'],
  grade: '0',
  score: 0,
  pointsPossible: 10,
  gradingType: 'points',
  gradeVisible: true,
};
const fixture = () => ({
  library: {
    selectedCourseID: 'c1',
    selectedAssignmentID: 'a1',
    courses: [
      {
        id: 'c1',
        canvasID: 1,
        name: 'Algebra',
        code: 'MATH',
        documents: [],
        canvasMaterials: [
          { id: 'a1', kind: 'assignments', title: 'Problem set', assignment: { ...details } },
        ],
      },
    ],
  },
  assignmentFiles: [{ id: 'f1', title: 'Problems.pdf' }],
});

test('grade formatting respects Canvas grading schemes and does not hide zero', () => {
  assert.equal(assignmentGrade(details), '0 / 10');
  assert.equal(assignmentGrade({ ...details, score: 0, pointsPossible: 0 }), '0 / 0');
  assert.equal(assignmentGrade({ ...details, score: 12 }), '12 / 10');
  assert.equal(
    assignmentGrade({ ...details, score: 9.5, grade: 'A-', gradingType: 'letter_grade' }),
    'A-'
  );
  assert.equal(assignmentGrade({ ...details, grade: '95%', gradingType: 'percent' }), '95%');
  assert.equal(
    assignmentGrade({ ...details, grade: null, score: 5, gradingType: 'percent' }),
    '50%'
  );
  assert.equal(
    assignmentGrade({ ...details, grade: 'complete', gradingType: 'pass_fail' }),
    'Complete'
  );
  assert.equal(
    assignmentGrade({ ...details, grade: 'incomplete', gradingType: 'pass_fail' }),
    'Incomplete'
  );
  assert.equal(assignmentGrade({ ...details, grade: '4.0', gradingType: 'gpa_scale' }), '4.0');
  assert.equal(
    assignmentGrade({ ...details, gradeMatchesCurrentSubmission: false }),
    '0 / 10 (previous attempt)'
  );
  assert.equal(assignmentGrade({ ...details, gradeVisible: false }), '');
  assert.equal(assignmentGrade({ ...details, status: 'excused' }), '');
  assert.equal(assignmentGrade({ ...details, gradingType: 'not_graded' }), '');
  assert.equal(assignmentGrade({ status: 'graded' }), '');
});

test('grades appear on the assignment page, agenda and workspace list and refresh on changes', () => {
  const state = fixture();
  for (const html of [
    assignmentPageMarkup(state),
    assignmentAgendaMarkup(state.library.courses, { filter: 'all' }),
    assignmentsMarkup(state.library.courses, { includeCompleted: true }),
  ]) {
    assert.match(
      parseHTML(html).document.querySelector('.submission-badge').textContent,
      /Grade: 0 \/ 10/
    );
  }
  const libraryKey = courseLibraryRenderKey(state),
    readerKey = readerRenderKey(state);
  state.library.courses[0].canvasMaterials[0].assignment.score = 8;
  assert.notEqual(courseLibraryRenderKey(state), libraryKey);
  assert.notEqual(readerRenderKey(state), readerKey);
  Object.assign(state.library.courses[0].canvasMaterials[0].assignment, {
    gradingType: 'letter_grade',
    grade: '<img src=x>',
  });
  const html = assignmentPageMarkup(state);
  assert.match(html, /Grade: &lt;img src=x&gt;/);
  assert.doesNotMatch(html, /<img/);
});

test('assignment files use an accessible disclosure whose preference is scoped per workspace and assignment', () => {
  const state = fixture();
  let disclosure = parseHTML(assignmentPageMarkup(state)).document.querySelector(
    'details.assignment-files'
  );
  assert.ok(disclosure.hasAttribute('open'));
  assert.match(disclosure.querySelector('summary').textContent, /Included files 1/);
  const key = disclosure.dataset.collapseKey;
  const closed = new Set([key]);
  disclosure = parseHTML(assignmentPageMarkup(state, { closed })).document.querySelector(
    'details.assignment-files'
  );
  assert.equal(disclosure.hasAttribute('open'), false);
  state.busy = true;
  assert.equal(
    parseHTML(assignmentPageMarkup(state, { closed }))
      .document.querySelector('details.assignment-files')
      .hasAttribute('open'),
    false
  );
  state.library.courses[0].id = state.library.selectedCourseID = 'c2';
  assert.ok(
    parseHTML(assignmentPageMarkup(state, { closed }))
      .document.querySelector('details.assignment-files')
      .hasAttribute('open')
  );
});

test('assignment grades are also visible in organized workspace material rows', () => {
  const html = materialGroupsMarkup([
    {
      id: 'assignments',
      title: 'Assignments',
      items: [
        {
          materialID: 'assignments:1',
          title: 'Problem set',
          submissionStatus: 'graded',
          assignment: details,
        },
      ],
    },
  ]);
  assert.match(
    parseHTML(html).document.querySelector('.submission-badge').textContent,
    /Grade: 0 \/ 10/
  );
});
