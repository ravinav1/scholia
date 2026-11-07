import { escapeHtml as esc } from '../../chrome/src/html-escape.js';
import { analyzeExamCollisions, compareExamDates, normalizeExamPlan } from '../../../packages/core/src/exam-planner.js';
import { checkedExamAdvice } from '../../../packages/core/src/exam-recommendations.js';
import { studyModelPickerMarkup } from '../chat/model-picker.js';
import { installStudyPlanSelection } from '../study-plan-selection.js';

export function installExamRecommendation({ getState, recommend, apply, selectModel }) {
  const element = document.createElement('section');
  element.className = 'exam-recommendation';
  element.setAttribute('aria-labelledby', 'exam-recommendation-title');
  element.innerHTML = `<h2 id="exam-recommendation-title">A plan that fits you</h2>
    <fieldset class="exam-recommendation-modes"><legend>How can I help?</legend><label><input type="radio" name="exam-recommendation-mode" value="selection" checked> Build a selection</label><label><input type="radio" name="exam-recommendation-mode" value="advice"> Get advice</label></fieldset>
    <div class="exam-initial-question"><label for="exam-interests">Your interests and study goals</label>
    <p id="exam-recommendation-help"></p>
    <textarea id="exam-interests" rows="5" maxlength="4000" aria-describedby="exam-recommendation-help"></textarea></div>
    <div class="exam-model-control"><label for="exam-model-picker">Model</label><select id="exam-model-picker" aria-label="Exam planner model"></select></div>
    <p class="exam-help exam-recommendation-model"></p>
    <div class="exam-recommendation-actions"><button type="button" data-recommend="generate">Recommend exams</button><button type="button" data-recommend="cancel" hidden>Cancel</button></div>
    <div class="exam-recommendation-result"></div>
    <div class="exam-follow-up" hidden><label for="exam-follow-up">Continue the conversation</label>
      <textarea id="exam-follow-up" rows="3" maxlength="4000" placeholder="Ask a follow-up or add more about your goals…"></textarea>
      <div class="exam-recommendation-actions"><button type="button" data-recommend="followUp">Send follow-up</button><button type="button" data-recommend="cancelFollowUp" hidden>Cancel</button><button type="button" data-recommend="newConversation">New conversation</button></div>
    </div><p class="exam-recommendation-status" role="status" aria-live="polite"></p>`;
  const $ = (selector) => element.querySelector(selector);
  const input = $('#exam-interests'), status = $('.exam-recommendation-status'), output = $('.exam-recommendation-result');
  const followUp = $('#exam-follow-up');
  let controller = null, generation = 0, baseline = null, result = null, changingModel = false, modelKey, history = [];
  const mode = () => $('[name=exam-recommendation-mode]:checked').value;
  const isAdvice = () => mode() === 'advice';
  const exams = () => getState()?.library.examPlan || [];
  const signature = () => JSON.stringify(exams());
  const degreePicker = installStudyPlanSelection({ onChange: () => {
    cancel();
    status.classList.remove('error');
    status.textContent = history.length ? 'Degree choices changed. Your next reply will use the selected plan, year and specialisation.' : '';
  } });
  $('.exam-model-control').before(degreePicker.element);
  function controls() {
    const chatting = isAdvice() && history.length > 0;
    $('.exam-initial-question').hidden = chatting;
    $('.exam-follow-up').hidden = !chatting;
    input.disabled = Boolean(controller);
    followUp.disabled = Boolean(controller);
    degreePicker.element.hidden = !isAdvice();
    degreePicker.setDisabled(Boolean(controller));
    $('#exam-model-picker').disabled = Boolean(controller) || changingModel || !selectModel || !getState()?.models?.length;
    for (const option of element.querySelectorAll('[name=exam-recommendation-mode]')) option.disabled = Boolean(controller);
    $('[data-recommend=generate]').disabled = Boolean(controller) || changingModel || !input.value.trim() || (!isAdvice() && !exams().length);
    $('[data-recommend=generate]').hidden = chatting;
    $('[data-recommend=generate]').textContent = isAdvice()
      ? (controller ? 'Considering your exams…' : 'Get advice')
      : (controller ? 'Finding a selection…' : 'Recommend exams');
    $('[data-recommend=cancel]').hidden = !controller || chatting;
    $('[data-recommend=cancel]').disabled = !controller;
    $('[data-recommend=followUp]').disabled = Boolean(controller) || changingModel || !followUp.value.trim();
    $('[data-recommend=followUp]').textContent = controller ? 'Thinking…' : 'Send follow-up';
    $('[data-recommend=cancelFollowUp]').hidden = !controller;
    $('[data-recommend=cancelFollowUp]').disabled = !controller;
    $('[data-recommend=newConversation]').disabled = Boolean(controller) || changingModel;
  }
  function clear() { result = null; history = []; followUp.value = ''; output.replaceChildren(); }
  function renderAdvice(renderMarkdown) {
    output.innerHTML = `<div class="exam-advice-chat" aria-label="Exam advice conversation">${history.map((message) =>
      `<article class="exam-advice-turn ${message.role}"><div class="exam-advice-speaker">${message.role === 'user' ? 'You' : 'Scholia'}</div>${message.role === 'user'
        ? `<p class="exam-advice-question">${esc(message.content)}</p>`
        : `<div class="exam-advice">${renderMarkdown(message.content)}</div>`}</article>`).join('')}</div>`;
  }
  function cancel() {
    generation++;
    controller?.abort(); controller = null;
    controls();
  }
  function refresh() {
    const state = getState();
    const models = state?.models || [];
    const nextModelKey = JSON.stringify([models, state?.providerID, state?.modelID]);
    if (nextModelKey !== modelKey) {
      $('#exam-model-picker').innerHTML = studyModelPickerMarkup(models, state?.providerID, state?.modelID);
      if (!models.length) $('#exam-model-picker').innerHTML = '<option disabled selected>Set up a model in Settings</option>';
      else if (!models.some((model) => model.id === state.modelID && model.providerID === state.providerID))
        $('#exam-model-picker').insertAdjacentHTML('afterbegin', '<option disabled selected>Choose a verified model</option>');
      modelKey = nextModelKey;
    }
    $('label[for=exam-interests]').textContent = isAdvice() ? 'Your exam question' : 'Your interests and study goals';
    $('#exam-recommendation-help').textContent = isAdvice()
      ? 'Ask about exam preparation, priorities, or which exam to take when dates overlap. Include your goals, how prepared you feel, and any courses you must keep.'
      : 'Tell me what interests you, what you want to use it for, and how many courses you want to take. Mention any courses you must keep.';
    input.placeholder = isAdvice()
      ? 'For example: Two of my exams overlap. Which should I take, and why? I enjoy programming and want to build robots.'
      : 'For example: I enjoy programming and physics, want to build robots, and would like three useful courses.';
    $('.exam-recommendation-model').textContent = `Uses ${getState()?.modelID || 'your selected model'}, your ${isAdvice() ? 'question' : 'interests'}, exam dates and course titles. ${isAdvice() ? 'Degree questions also use available NTNU admission-year plans. Advice leaves your exam selection unchanged. You can ask even if dates or times are missing.' : 'Review the suggestion before applying it.'}`;
    if (baseline !== null && baseline !== signature()) {
      cancel(); baseline = null;
      if (isAdvice() && history.length) status.textContent = 'Your plan changed. Your next reply will use the updated dates.';
      else { clear(); status.textContent = 'Your plan changed. Ask again for an updated response.'; }
    }
    controls();
  }
  input.addEventListener('input', () => { clear(); status.textContent = ''; controls(); });
  followUp.addEventListener('input', controls);
  followUp.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) { event.preventDefault(); void submit(true); }
  });
  $('#exam-model-picker').addEventListener('change', async (event) => {
    if (controller || changingModel || !selectModel) return;
    changingModel = true; if (!isAdvice() || !history.length) clear(); controls();
    status.classList.remove('error'); status.textContent = 'Switching model…';
    try {
      const [providerID, id] = JSON.parse(event.target.value);
      await selectModel({ providerID, id });
      status.textContent = '';
    } catch (error) {
      status.classList.add('error'); status.textContent = error.message;
    } finally {
      changingModel = false; modelKey = null; refresh();
    }
  });
  for (const option of element.querySelectorAll('[name=exam-recommendation-mode]')) option.addEventListener('change', () => {
    cancel(); clear(); baseline = null; status.textContent = ''; status.classList.remove('error'); refresh();
  });
  for (const name of ['cancel', 'cancelFollowUp']) $('[data-recommend=' + name + ']').addEventListener('click', () => {
    cancel(); status.textContent = isAdvice() ? 'Advice canceled.' : 'Recommendation canceled.';
  });
  $('[data-recommend=newConversation]').addEventListener('click', () => {
    cancel(); clear(); baseline = null; input.value = ''; status.textContent = ''; status.classList.remove('error'); controls(); input.focus();
  });
  $('[data-recommend=generate]').addEventListener('click', () => void submit());
  $('[data-recommend=followUp]').addEventListener('click', () => void submit(true));
  async function submit(followingUp = false) {
    const question = (followingUp ? followUp : input).value.trim();
    if (controller || changingModel || !question || question.length > 4000 || (!isAdvice() && !exams().length)
        || (followingUp && (!isAdvice() || !history.length))) return;
    if (!followingUp) clear();
    baseline = signature();
    const requestHistory = history.map((message) => ({ ...message }));
    const requestDegrees = degreePicker.value;
    const requestExams = JSON.parse(baseline), ticket = ++generation;
    controller = new AbortController(); controls();
    status.classList.remove('error'); status.textContent = isAdvice()
      ? 'Considering your question, exam priorities and overlapping dates…'
      : 'Considering your interests and checking every exam component…';
    try {
      const [response, renderer] = await Promise.all([
        recommend({ exams: requestExams, interests: question, mode: mode(),
          ...(isAdvice() ? { history: requestHistory, degreeSelections: requestDegrees } : {}) }, controller.signal),
        isAdvice() ? import('../../chrome/src/render.js') : null,
      ]);
      if (ticket !== generation) return;
      if (baseline !== signature()) throw new Error('Your plan changed. Ask again for an updated response.');
      if (isAdvice() && JSON.stringify(requestDegrees) !== JSON.stringify(degreePicker.value))
        throw new Error('Your degree choices changed. Ask again for an updated response.');
      if (isAdvice()) {
        result = checkedExamAdvice(response.advice);
        history = [...requestHistory, { role: 'user', content: question }, { role: 'assistant', content: result.advice }];
        followUp.value = '';
        status.textContent = 'Advice ready · your exam selection is unchanged.';
        renderAdvice(renderer.renderMarkdown);
        return;
      }
      result = response;
      const selected = new Set(result.selectedExamIDs);
      const checked = normalizeExamPlan(requestExams).filter((exam) => selected.has(exam.id)).map((exam) => ({ ...exam, selected: true }));
      if (checked.length !== selected.size || checked.some((exam) => !exam.flexible && (!exam.date || !exam.startTime || !exam.endTime)) || analyzeExamCollisions(checked).collisions.length)
        throw new Error('The suggested exams could not be verified. Request a fresh recommendation.');
      status.textContent = result.choices.length ? `${result.choices.length} courses · ${selected.size} exams · no fixed-time clashes` : 'No complete selection found. Review the details below or adjust your goals.';
      output.innerHTML = result.choices.map((choice) => {
        const rows = checked.filter((exam) => (exam.courseCode.replace(/[\s-]+/g, '').toUpperCase() || exam.courseName.toLowerCase()) === choice.courseKey).sort(compareExamDates);
        return `<article><h3>${esc(choice.courseCode || choice.courseName)}${choice.courseCode && choice.courseName ? ` · ${esc(choice.courseName)}` : ''}</h3><p>${esc(choice.reason)}</p><ul>${rows.map((exam) => `<li>${esc(exam.date)} · ${esc(exam.startTime)}–${esc(exam.endTime)} · ${esc(exam.component)}${exam.endDate ? ` · ends ${esc(exam.endDate)}` : ''}${exam.flexible ? ' · Flexible timing: arrange with professor' : ''}</li>`).join('')}</ul></article>`;
      }).join('') + (result.excluded.length ? `<details><summary>Why other courses were left out</summary>${result.excluded.map((choice) => `<p><strong>${esc(choice.courseCode || choice.courseName)}:</strong> ${esc(choice.reason)}</p>`).join('')}</details>` : '')
        + (selected.size ? '<button type="button" class="primary" data-recommend="apply">Use this selection</button><p class="exam-help">Replaces your current exam selection. You can undo this afterwards.</p>' : '');
    } catch (error) {
      if (ticket !== generation) return;
      if (!history.length) clear();
      status.classList.add('error'); status.textContent = error.message;
    } finally {
      if (ticket === generation) {
        controller = null; controls();
        if (isAdvice() && history.length) followUp.focus({ preventScroll: true });
      }
    }
  }
  output.addEventListener('click', async (event) => {
    if (!event.target.closest('[data-recommend=apply]') || !result || isAdvice()) return;
    if (baseline !== signature()) { refresh(); return; }
    const ids = new Set(result.selectedExamIDs);
    await apply(exams().map((exam) => ({ ...exam, selected: ids.has(exam.id) })));
  });
  refresh();
  return { element, refresh, cancel };
}
