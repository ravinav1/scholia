import test from 'node:test';
import assert from 'node:assert/strict';
import {
  coursePracticeSources,
  practiceCoverage,
  checkedPracticeQuestions,
} from '../../apps/server/learning.js';
import { coursePracticeSetupMarkup } from '../../apps/web/practice/course-practice.js';

const course = {
  id: 'course',
  name: 'Bionano',
  documents: Array.from({ length: 36 }, (_, i) => ({
    id: `doc-${String(i).padStart(2, '0')}`,
    title: `Lecture ${i}`,
    pageCount: 2,
    contentHash: `hash-${i}`,
  })),
  canvasMaterials: [{ id: 'files:missing' }],
};
const indexes = {
  index: async (_u, d) => ({
    pages: [1, 2].map((number) => ({ number, text: `${d.title}: concept on page ${number}` })),
  }),
};
const state = () => ({ questions: {}, attempts: [] });

test('repeated course practice reaches every readable page, including courses with more than thirty documents', async () => {
  const learning = state(),
    visited = new Set();
  for (let round = 0; round < 6; round++) {
    const sources = await coursePracticeSources(course, indexes, '', learning, { count: 12 });
    assert.equal(sources.length, 12);
    assert.equal(
      new Set(sources.map((s) => s.documentID)).size,
      12,
      'Distribute a session across readings'
    );
    for (const source of sources) {
      const id = `${source.documentID}:${source.page}`;
      assert.ok(!visited.has(id), 'No repetition before all pages have been offered');
      visited.add(id);
      learning.questions[id] = { id, source, concept: source.title };
    }
  }
  assert.equal(visited.size, 72);
  assert.equal(
    practiceCoverage(course, learning).materials.reduce((n, m) => n + m.attempted, 0),
    0,
    'Generated questions are not completed practice'
  );
});

test('coverage respects assistance, disputes and changed sources; gap practice targets weak evidence', async () => {
  const learning = state(),
    sources = await coursePracticeSources(course, indexes, '', learning, { count: 3 });
  sources.forEach((source, i) => {
    learning.questions[i] = { id: String(i), source, concept: `Concept ${i}` };
    learning.attempts.push({
      questionID: String(i),
      createdAt: i,
      assessment: { verdict: 'correct', origin: 'model' },
      ...(i === 1 ? { hintCount: 1 } : i === 2 ? { dispute: 'Wrong interpretation' } : {}),
    });
  });
  let coverage = practiceCoverage(course, learning);
  assert.equal(
    coverage.materials.reduce((n, m) => n + m.independent, 0),
    1
  );
  assert.equal(
    coverage.materials.reduce((n, m) => n + m.needsReview, 0),
    2
  );
  assert.equal(coverage.missing, 1);
  const gaps = await coursePracticeSources(course, indexes, '', learning, { count: 2, weak: true });
  assert.deepEqual(
    new Set(gaps.map((s) => s.documentID)),
    new Set([sources[1].documentID, sources[2].documentID])
  );
  learning.questions[0].source = { ...sources[0], contentHash: 'old' };
  coverage = practiceCoverage(course, learning);
  assert.equal(
    coverage.materials.reduce((n, m) => n + m.independent, 0),
    0
  );
});

test('course generation rejects source concentration and setup offers full-course exam and concept practice', () => {
  const question = (i) => ({
    concept: `Concept ${i}`,
    prompt: `Why does process ${i} occur?`,
    referenceAnswer: 'A justified explanation using the source.',
    rubric: ['Explains cause'],
    hints: ['Consider causes', 'Apply the relationship', 'Write the first step'],
    sourceIndex: 0,
  });
  assert.throws(
    () =>
      checkedPracticeQuestions(
        JSON.stringify({ questions: [question(1), question(2)] }),
        [{ excerpt: 'A' }, { excerpt: 'B' }],
        2,
        true,
        'fixture'
      ),
    /cover/
  );
  const html = coursePracticeSetupMarkup({ course, coverage: practiceCoverage(course, state()) });
  assert.match(html, /Cover the whole course/);
  assert.match(html, /Revisit weak areas/);
  assert.match(html, /Understand concepts/);
  assert.match(html, /Exam practice/);
  assert.match(html, /0 of 72 readable pages attempted/);
});
