import test from 'node:test';
import assert from 'node:assert/strict';
import { assignmentDetails, Canvas } from '../apps/server/canvas.js';

const details = (submission = {}, assignment = {}) =>
  assignmentDetails(
    {
      grading_type: 'points',
      points_possible: 10,
      ...assignment,
      submission: { workflow_state: 'graded', score: 0, grade: '0', ...submission },
    },
    'https://canvas.example',
    1
  );

test('Canvas grades preserve zero, grading schemes and scores on missing assignments', () => {
  const zero = details({ missing: true });
  assert.equal(zero.status, 'notSubmitted');
  assert.equal(zero.grade, '0');
  assert.equal(zero.score, 0);
  assert.equal(zero.pointsPossible, 10);
  assert.equal(zero.gradeVisible, true);
  assert.equal(details({ grade: 'A-', score: 9 }, { grading_type: 'letter_grade' }).grade, 'A-');
  assert.equal(details({ grade: 'complete' }, { grading_type: 'pass_fail' }).grade, 'complete');
  assert.equal(details({ score: null, grade: null }).score, null);
  assert.equal(details({ score: '' }).score, null);
  assert.equal(details({ score: false }).score, null);
  assert.equal(details({ score: '0' }).score, 0);
  assert.equal(details({}, { points_possible: 0 }).pointsPossible, 0);
});

test('Canvas grades are removed when hidden, excused, unposted or manually withheld', () => {
  for (const [submission, assignment] of [
    [{ grade_hidden: true }, {}],
    [{ posted_at: null }, {}],
    [{ excused: true }, {}],
    [{ assignment_visible: false }, {}],
    [{}, { muted: true }],
    [{}, { hide_in_gradebook: true }],
    [{}, { post_manually: true }],
  ]) {
    const value = details(submission, assignment);
    assert.equal(value.gradeVisible, false);
    assert.equal(value.grade, null);
    assert.equal(value.score, null);
  }
  const posted = details(
    { posted_at: '2026-09-27T12:00:00Z', grade_matches_current_submission: false },
    { post_manually: true }
  );
  assert.equal(posted.grade, '0');
  assert.equal(posted.gradeMatchesCurrentSubmission, false);
});

test('a grade-only Canvas change refreshes assignment metadata without a file version change', async () => {
  const canvas = new Canvas('https://canvas.example', 'fixture-token', {
    hosts: ['canvas.example'],
  });
  let score = 6;
  canvas.list = async (path) =>
    path.includes('/assignments')
      ? [
          {
            id: 1,
            name: 'Problem set',
            updated_at: 'unchanged',
            submission_types: ['online_upload'],
            grading_type: 'points',
            points_possible: 10,
            submission: {
              workflow_state: 'graded',
              grade: String(score),
              score,
              posted_at: '2026-09-27T12:00:00Z',
            },
          },
        ]
      : [];
  const course = { canvasID: 1 };
  const first = await canvas.catalog(course);
  course.canvasMaterials = first.items;
  score = 9;
  const second = await canvas.catalog(course);
  assert.deepEqual(second.changes.updated, ['assignments:1']);
  assert.equal(second.items[0].version, first.items[0].version);
  assert.equal(second.items[0].assignment.score, 9);
});
