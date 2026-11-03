import { escapeHtml as esc, renderMarkdown } from '../chrome/src/render.js';

const date = (value) => new Date((value + 978307200) * 1000).toLocaleString(); // Foundation Date
const button = (text, action, attrs = '') =>
  `<button type="button" data-practice="${action}" ${attrs}>${text}</button>`;
const labels = ['Conceptual cue', 'Method cue', 'Partial step'];
export function practiceAttemptLabel(attempt) {
  const independent =
    !attempt.hintCount && !attempt.revealed && !attempt.openBook && !attempt.previousAttemptID;
  return `${attempt.previousAttemptID ? 'Revision' : 'Original attempt'} · ${independent ? 'Independent' : 'Assisted / open book'}`;
}
export function practiceQuestionMarkup(view) {
  const { session: s, question: q } = view;
  if (!s || !q) return '<p>Choose a passage or resume a saved session.</p>';
  const attempts = view.attempts.filter((a) => a.questionID === q.id);
  const source = `<div class="practice-source"><strong>${esc(q.source.title)} · page/section ${q.source.page}</strong><small>${esc(q.validation)}</small>
    ${q.stale ? '<p role="status">Source changed or is unavailable. This question needs revalidation; feedback uses its saved source revision.</p>' : ''}
    ${!s.openBook && !s.revealed ? button('Open saved source', 'source') : ''}${button('Go to source page', 'reader')}
    ${q.source.excerpt ? `<details><summary>Saved source excerpt</summary><p>${esc(q.source.excerpt)}</p></details>` : ''}
    ${q.source.image ? `${q.requiresVisual ? '' : '<details><summary>Saved page image</summary>'}<img src="data:image/jpeg;base64,${esc(q.source.image)}" alt="${q.requiresVisual ? 'Question figure' : 'Saved source figure'}">${q.requiresVisual ? '' : '</details>'}` : ''}</div>`;
  return `<p class="eyebrow">${s.review ? 'DELAYED REVIEW' : 'PRACTICE'} · ${s.position + 1} OF ${s.questionIDs.length}</p><h2>${esc(q.concept)}</h2>${source}
    <div class="practice-prompt">${renderMarkdown(q.prompt)}</div>
    ${q.hints.map((hint, i) => `<div class="practice-hint"><strong>${labels[i]}</strong>${renderMarkdown(hint)}</div>`).join('')}
    ${attempts
      .map(
        (
          a
        ) => `<article class="practice-attempt"><strong>${practiceAttemptLabel(a)}</strong><small>${esc(date(a.createdAt))}${a.confidence ? ` · Confidence ${a.confidence}/5` : ''}${a.hintCount ? ` · ${a.hintCount} hint(s)` : ''}${a.revealed ? ' · Solution revealed' : ''}</small><p class="practice-answer-text">${esc(a.answer)}</p>
      ${
        a.assessment
          ? `<h3>${esc(a.assessment.verdict)} · ${a.assessment.origin === 'model' ? 'Model judgment' : 'Self-assessment'}</h3><dl><dt>What was correct</dt><dd>${renderMarkdown(a.assessment.correct)}</dd><dt>First issue</dt><dd>${renderMarkdown(a.assessment.issue)}</dd><dt>Next step</dt><dd>${renderMarkdown(a.assessment.nextStep)}</dd></dl><p class="fineprint">Evidence: ${esc(q.source.title)}, page/section ${q.source.page}</p>
        ${a.dispute ? `<p class="practice-warning">Unresolved: ${esc(a.dispute)}</p>` : `<label>Correction or concern (optional)<input data-correction="${esc(a.id)}" maxlength="4000"></label>${button('This feedback seems wrong', 'dispute', `data-attempt="${esc(a.id)}"`)}`}
      `
          : `<p>Saved · awaiting feedback</p>${button('Retry feedback', 'feedback', `data-attempt="${esc(a.id)}"`)}`
      }${a.selfAssessment ? `<p>Self-assessment: ${esc(a.selfAssessment)} (separate from model feedback)</p>` : ''}${s.revealed ? `<div class="practice-actions"><span>My self-check:</span>${['correct', 'partial', 'incorrect', 'uncertain'].map((v) => button(v, 'selfAssess', `data-attempt="${a.id}" data-verdict="${v}"`)).join('')}</div>` : ''}</article>`
      )
      .join('')}
    ${['question', 'revision'].includes(s.stage) ? `<form id="practice-answer-form"><label for="practice-answer">Your answer</label><textarea id="practice-answer" rows="4" maxlength="20000" required></textarea><label for="practice-confidence">Confidence (optional)</label><select id="practice-confidence"><option value="">Not recorded</option>${[1, 2, 3, 4, 5].map((n) => `<option value="${n}">${n} / 5</option>`).join('')}</select><button class="primary" type="submit">Save answer & get feedback</button></form>` : button('Try again', 'revise')}
    <div class="practice-actions">${s.hintCount < q.hintCount ? button('Next hint', 'hint') : ''}${!s.revealed ? button('Show solution / worked example', 'reveal', attempts.length ? '' : 'disabled title="Save an attempt first. You can describe where you are stuck."') : ''}${button('Save for review', 'saveReview')}</div>
    ${!attempts.length && !s.revealed ? '<p>Save an attempt to unlock the solution. If you are stuck, describe what you tried or where you need help.</p>' : ''}
    ${q.referenceAnswer ? `<section class="practice-solution"><h3>Reference solution</h3>${renderMarkdown(q.referenceAnswer)}<ul>${(q.rubric || []).map((r) => `<li>${esc(r)}</li>`).join('')}</ul><p>Revealing the solution is recorded as assistance.</p></section>` : ''}
    <div class="practice-actions">${button(s.position + 1 < s.questionIDs.length ? 'Next question / skip' : 'Finish session', 'next')}${button('Finish now', 'finish')}${button('Explain in tutor', 'explain')}</div>`;
}
export function practiceRecapMarkup(view) {
  return `<h2>Session recap</h2><p>Use dated attempts as evidence. A completed session alone does not establish mastery.</p>${view.recap
    .map((q) => {
      const attempts = view.attempts.filter((a) => a.questionID === q.id);
      const success = attempts.some(
        (a) =>
          !a.hintCount &&
          !a.openBook &&
          !a.revealed &&
          !a.previousAttemptID &&
          !a.dispute &&
          !a.sourceStale &&
          a.assessment?.origin === 'model' &&
          a.assessment.verdict === 'correct'
      );
      return `<article class="practice-attempt"><h3>${esc(q.concept)}</h3><p>${!attempts.length ? 'Skipped · untested' : success ? 'Answered independently' : 'Revisit after assistance, revision or unresolved feedback'}</p><p>${esc(q.source.title)} · page/section ${q.source.page}${q.stale ? ' · Source changed; needs revalidation' : ''}</p>
      ${attempts.map((a) => `<details><summary>${esc(date(a.createdAt))} · ${practiceAttemptLabel(a)}</summary><p>${esc(a.answer)}</p>${a.assessment ? `<strong>${esc(a.assessment.verdict)} · Model judgment</strong>${renderMarkdown(a.assessment.correct)}${renderMarkdown(a.assessment.issue)}${renderMarkdown(a.assessment.nextStep)}${a.dispute ? `<p>Unresolved: ${esc(a.dispute)}</p>` : `${button('This feedback seems wrong', 'dispute', `data-attempt="${a.id}" data-question="${q.id}"`)}`}` : button('Retry feedback', 'feedback', `data-attempt="${a.id}" data-question="${q.id}"`)}${a.selfAssessment ? `<p>Self-assessment: ${esc(a.selfAssessment)}</p>` : ''}</details>`).join('')}
      ${q.referenceAnswer ? `<details><summary>Reference solution</summary>${renderMarkdown(q.referenceAnswer)}</details>` : attempts.length ? button('Show solution', 'revealSaved', `data-question="${q.id}"`) : '<p>Skipped without an attempt. Practise this question again to unlock its solution.</p>'}
      ${button('Save for review', 'saveReview', `data-question="${esc(q.id)}"`)}</article>`;
    })
    .join('')}`;
}
