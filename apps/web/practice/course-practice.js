import { escapeHtml as esc } from '../../chrome/src/html-escape.js';

export function coursePracticeCoverageMarkup(coverage) {
  if (!coverage) return '';
  const total = coverage.materials.reduce((n, d) => n + d.pages, 0);
  const attempted = coverage.materials.reduce((n, d) => n + d.attempted, 0);
  const independent = coverage.materials.reduce((n, d) => n + d.independent, 0);
  return `<section class="course-practice-coverage" aria-label="Course practice coverage"><h3>${esc(coverage.title)}</h3>
    <progress value="${attempted}" max="${Math.max(1, total)}" aria-label="Readable pages attempted"></progress>
    <p>${attempted} of ${total} readable pages attempted · ${independent} last answered independently</p>
    <p class="fineprint">Course sessions move across saved readings and pages. Coverage records practice, not mastery of every concept.</p>
    ${coverage.missing ? `<p>${coverage.missing} materials still need downloading. <button type="button" data-practice="downloadCourse">Download course materials</button></p>` : ''}
    <details><summary>Material coverage · ${coverage.saved} saved</summary><ul>${coverage.materials.map((d) => `<li><span>${esc(d.title)}</span><small>${d.attempted}/${d.pages} attempted · ${d.needsReview} to revisit</small></li>`).join('')}</ul></details>
    ${coverage.concepts.length ? `<details><summary>Concept progress · ${coverage.concepts.length}</summary><ul>${coverage.concepts.map((c) => `<li><span>${esc(c.title)}</span><small>${c.independent ? 'Answered independently' : c.needsReview ? 'Revisit' : 'Not attempted'}</small></li>`).join('')}</ul></details>` : ''}</section>`;
}

export function coursePracticeSetupMarkup({
  course,
  document,
  sourceScope = 'course',
  practiceStyle = 'concepts',
  selection = '',
  page = 1,
  coverage,
}) {
  return `<h2>Practice your course</h2>${coursePracticeCoverageMarkup(coverage)}<form id="practice-setup">
    <label>Material<select name="sourceScope"><option value="course" ${sourceScope === 'course' ? 'selected' : ''}>Cover the whole course</option><option value="weak" ${sourceScope === 'weak' ? 'selected' : ''}>Revisit weak areas</option>${document ? `<option value="reading" ${sourceScope === 'reading' ? 'selected' : ''}>${esc(selection ? 'Selected passage' : `${document.title} · page/section ${page}`)}</option>` : ''}</select></label>
    <label>Practice mode<select name="practiceStyle">${Object.entries({
      concepts: 'Understand concepts',
      recall: 'Active recall',
      application: 'Apply & solve',
      exam: 'Exam practice',
    })
      .map(
        ([id, title]) =>
          `<option value="${id}" ${practiceStyle === id ? 'selected' : ''}>${title}</option>`
      )
      .join('')}</select></label>
    <label>Topic or focus (optional)<input name="scope" maxlength="1000" placeholder="All topics, or name a topic to focus on"></label>
    <label>Session length<select name="count">${[1, 2, 3, 4, 5, 8, 12].map((n) => `<option value="${n}" ${n === 3 ? 'selected' : ''}>Up to ${n} question${n === 1 ? '' : 's'}</option>`).join('')}</select></label>
    <label class="practice-toggle"><input type="checkbox" name="openBook"> Open-book practice</label><p>Try recall with the source hidden, or choose open-book practice. Hints, worked solutions and feedback are available in every mode.</p>
    <button type="submit" class="primary" ${!course || !course.documents.length ? 'data-unavailable="true"' : ''}>Prepare questions</button></form>`;
}
