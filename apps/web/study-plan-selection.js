import { escapeHtml as esc } from '../chrome/src/html-escape.js';

export function installStudyPlanSelection({ onChange }) {
  const element = document.createElement('section');
  element.className = 'exam-degree-plans';
  let options, selections = null, previous = null, disabled = false, error = false;
  const option = (value, label, chosen) => `<option value="${esc(String(value))}"${String(value) === String(chosen) ? ' selected' : ''}>${esc(label)}</option>`;
  const field = (name, label, contents, code) => `<label>${esc(label)}<select data-degree="${name}" data-programme="${esc(code)}" aria-label="${esc(code + ' ' + label)}">${contents}</select></label>`;
  const defaults = () => options.programmes.map(p => ({ programmeCode: p.programmeCode, admissionYear: p.defaultAdmissionYear, branchPath: [] }));
  function render() {
    const focusOpen = element.querySelector('.exam-degree-focus')?.open;
    const current = options ? selections ?? defaults() : [];
    element.innerHTML = options ? `<label class="exam-degree-enabled"><input type="checkbox" data-degree="enabled"${current.length ? ' checked' : ''}> Use degree plans for advice</label>
      ${current.length ? `<div class="exam-degree-cohorts">${current.map(s => {
        const p = options.programmes.find(p => p.programmeCode === s.programmeCode);
        return field('admission', `${p.programmeCode} admission year`, p.plans.map(y => option(y.admissionYear, String(y.admissionYear), s.admissionYear)).join(''), p.programmeCode);
      }).join('')}</div><p class="exam-help">Scholia looks up the relevant degree, study year and specialisation from your question.</p>
      <details class="exam-degree-focus"${focusOpen ? ' open' : ''}><summary>Optional study focus</summary>${current.map(selection => {
        const entry = options.programmes.find(p => p.programmeCode === selection.programmeCode), code = entry.programmeCode;
        const plan = entry.plans.find(p => p.admissionYear === selection.admissionYear);
        return `<fieldset class="exam-degree-card"><legend>${esc(code)} · ${esc(plan.name)}</legend><div class="exam-degree-fields">
          ${field('year', 'Study year', option('', 'Let Scholia choose', selection.studyYear ?? '') + Array.from({ length: plan.studyYears }, (_, i) => option(i + 1, `Year ${i + 1}`, selection.studyYear)).join(''), code)}
          ${field('term', 'Semester', option('', 'Let Scholia choose', selection.term ?? '') + option('autumn', 'Autumn', selection.term) + option('spring', 'Spring', selection.term), code)}
          ${field('branch', 'Specialisation / profile', option('[]', 'Let Scholia choose', JSON.stringify(selection.branchPath ?? [])) + plan.branches.map(b => option(JSON.stringify(b.path), b.name, JSON.stringify(selection.branchPath))).join(''), code)}
        </div><a href="${esc(plan.sourceURL)}" target="_blank" rel="noreferrer">View this admission-year plan at NTNU</a></fieldset>`;
      }).join('')}<p class="exam-help">A focus guides the lookup; Scholia can still check relevant foundations in other years.</p></details>` : ''}`
      : `<p>${error ? 'Degree choices could not load. Default admission years will be used.' : 'Loading public degree choices…'}</p>${error ? '<button type="button" data-degree="retry">Retry</button>' : ''}`;
    setDisabled(disabled);
  }
  function setDisabled(value) { disabled = value; for (const control of element.querySelectorAll('input, select, button')) control.disabled = value; }
  element.addEventListener('change', event => {
    const field = event.target.dataset.degree;
    if (disabled || !options || !field) return;
    const value = event.target.value, code = event.target.dataset.programme;
    if (field === 'enabled') {
      if (event.target.checked) selections = previous ?? defaults();
      else { previous = selections ?? defaults(); selections = []; }
    } else {
      selections ??= defaults();
      const selection = selections.find(s => s.programmeCode === code);
      if (field === 'admission') { selection.admissionYear = Number(value); selection.branchPath = []; }
      if (field === 'year') selection.studyYear = value ? Number(value) : null;
      if (field === 'term') selection.term = value || null;
      if (field === 'branch') selection.branchPath = JSON.parse(value);
    }
    render(); onChange();
    [...element.querySelectorAll('input, select')].find(s => s.dataset.degree === field && s.dataset.programme === code)?.focus();
  });
  async function load() {
    error = false; render();
    try {
      const response = await fetch('/ntnu-study-plan-options.json', { credentials: 'same-origin', signal: AbortSignal.timeout(15_000) });
      if (!response.ok) throw new Error('Unavailable');
      const data = await response.json();
      if (data.schemaVersion !== 1 || !Array.isArray(data.programmes) || !data.programmes.length) throw new Error('Invalid catalog');
      options = data;
    } catch { error = true; }
    render();
  }
  element.addEventListener('click', event => { if (event.target.dataset.degree === 'retry') void load(); });
  void load();
  return { element, setDisabled, get value() { return structuredClone(selections); } };
}
