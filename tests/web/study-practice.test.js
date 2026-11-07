import test from 'node:test';
import assert from 'node:assert/strict';
import { practiceAttemptLabel, practiceQuestionMarkup, practiceRecapMarkup } from '../../apps/web/practice/practice-view.js';
const view = () => ({
  session: { id:'session', questionIDs:['question'], position:0, stage:'question', hintCount:0, revealed:false, openBook:false },
  question: { id:'question', concept:'Eigenvectors', prompt:'Which property is preserved?', hints:[], hintCount:3, source:{ title:'Algebra <script>', page:2, excerpt:'' }, validation:'Generated' },
  attempts:[], recap:[]
});
test('practice displays the question, graduated controls and optional confidence without inventing a solution', () => {
  const html = practiceQuestionMarkup(view());
  assert.match(html, /practice-answer/); assert.match(html, /Confidence \(optional\)/);
  assert.match(html, /Next hint/); assert.match(html, /Show solution/);
  assert.doesNotMatch(html, /class="practice-solution"/);
  assert.match(html, /Algebra &lt;script&gt;/);
});
test('assistance, revisions and self-checks stay distinguishable from an independent answer', () => {
  for (const assistance of [{ hintCount:1 }, { openBook:true }, { revealed:true }, { previousAttemptID:'first' }]) {
    assert.match(practiceAttemptLabel(assistance), /Assisted/);
  }
  assert.match(practiceAttemptLabel({}), /Independent/);
  const state = view(); state.session.stage = 'feedback';
  state.attempts = [{ id:'a', questionID:'question', answer:'<img src=x onerror=alert(1)>', createdAt:1, assessment:{ verdict:'uncertain', origin:'model', correct:'A possible interpretation', issue:'OCR is ambiguous', nextStep:'Check the source' }, dispute:'Alternative valid reasoning', selfAssessment:'correct' }];
  const html = practiceQuestionMarkup(state);
  assert.match(html, /Unresolved: Alternative valid reasoning/); assert.match(html, /Self-assessment: correct/);
  assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;/);
  assert.match(html, /First issue/); assert.match(html, /Next step/);
});
test('recap does not present disputed, assisted or stale-source results as independent success', () => {
  for (const limitation of [{ dispute:'Check this' }, { hintCount:1 }, { sourceStale:true }, { previousAttemptID:'first' }]) {
    const state = view(); state.recap = [state.question];
    state.attempts = [{ id:'a', questionID:'question', createdAt:1, answer:'Line', assessment:{ verdict:'correct', origin:'model', correct:'Yes', issue:'', nextStep:'Try a variant' }, ...limitation }];
    assert.doesNotMatch(practiceRecapMarkup(state), /Answered independently/);
  }
});
