import { escapeHtml as esc } from '../../chrome/src/html-escape.js';
import {
  normalizeExamPlan,
  parseExamImport,
  mergeExamImports,
  groupExams,
  analyzeExamCollisions,
  examFavoriteCourseIDs,
  resolveExamConflict,
  compareExamDates,
  setExamFlexibleTiming,
  isOralExam,
  examToday,
  isPastExam,
} from '../../../packages/core/src/exam-planner.js';

import { examScheduleMarkup } from './exam-schedule.js';
import { installExamRecommendation } from './exam-recommendation.js';

const labels = {
  collision: 'Time collision',
  possible: 'Possible collision',
  unknown: 'Check date / time',
  clear: 'No time overlap',
  unselected: 'Not taking',
  flexible: 'Flexible · arrange with professor',
};
const clone = (value) => JSON.parse(JSON.stringify(value));
const plan = (state) => state?.library.examPlan || [];
function summaryText(exams, analysis = analyzeExamCollisions(exams)) {
  const { summary: s } = analysis;
  if (!s.selected) return 'Choose the exams you intend to take.';
  return [
    `${s.selected} ${s.selected === 1 ? 'exam' : 'exams'} selected`,
    s.collision ? `${s.collision} with time collisions` : '',
    s.possible ? `${s.possible} with possible collisions` : '',
    s.unknown ? `${s.unknown} need date / time` : '',
    s.flexible ? `${s.flexible} flexible · arrange with professor` : '',
    !s.collision && !s.possible && !s.unknown ? (s.flexible ? 'No fixed-time overlaps' : 'No time overlaps') : '',
  ]
    .filter(Boolean)
    .join(' · ');
}
export function examDashboardMarkup(state) {
  const exams = plan(state),
    selected = exams.filter((exam) => exam.selected);
  return `<button class="exam-dashboard" data-action="exams"><span class="exam-dashboard-icon" aria-hidden="true">▦</span><span><strong>Exam dates</strong><small>${esc(exams.length ? summaryText(exams) : 'Bring dates from Studentweb. Choose your exams and check for collisions.')}</small></span><span>${selected.length ? 'View schedule' : 'Plan exams'} →</span></button>`;
}

export function installExamPlanner({ getState, save, reload, notify, signIn, recommend, selectModel }) {
  const main = document.querySelector('#main-content');
  const surface = document.createElement('section');
  surface.id = 'exam-planner';
  surface.className = 'exam-planner-surface';
  surface.hidden = true;
  const schedule = document.createElement('div');
  schedule.className = 'exam-schedule';
  const dialog = document.createElement('section');
  dialog.id = 'exam-planner-editor';
  dialog.className = 'exam-planner-editor';
  dialog.hidden = true;
  dialog.setAttribute('aria-labelledby', 'exam-planner-title');
  dialog.innerHTML = `<header class="exam-heading"><div><span class="eyebrow">MAKE ROOM FOR YOUR EXAMS</span><h2 id="exam-planner-title">Your exam plan</h2><p>Choose your exams. See how the dates fit together.</p></div><button type="button" data-exam-action="close" aria-label="Back to exam dates">← Dates</button></header>
    <div class="exam-body">${signIn ? '<div class="exam-sign-in"><button type="button" data-exam-action="studentweb">Sign in to Studentweb in the Mac app ↗</button><p class="exam-privacy">A temporary login window reads visible exam dates from Studentweb’s opening page. Review and save in the Mac app, then reload this plan. Scholia does not send login details or the Studentweb page to an AI provider.</p></div>' : '<p class="exam-privacy">Direct Studentweb sign-in is available in the Mac app. On this website, copy only exam details using the import below; saved exam fields are stored in your Scholia account.</p>'}<details class="exam-import"><summary>Paste dates from Studentweb</summary><p class="exam-privacy">Import only exam details from Studentweb. Your selections are a personal plan; Scholia does not change exam registrations.</p><ol><li>Sign in to Studentweb and stay on the opening page, under Kommende hendelser / Upcoming events.</li><li>Copy the course codes, exam names, dates and times below. Leave out personal details.</li><li>Preview and correct the dates, then add them to your plan.</li></ol>
      <label for="exam-import-text">Exam details</label><textarea id="exam-import-text" rows="5" maxlength="200000" placeholder="TDT4100 Object-oriented programming\nMidterm 14.10.2026 09:00–11:00\nFinal exam 10.12.2026 09:00–13:00" spellcheck="false" autocomplete="off"></textarea>
      <div class="exam-import-actions"><button type="button" data-exam-action="preview">Preview dates</button><label class="exam-file-button">Choose text, CSV or calendar file<input id="exam-import-file" type="file" accept=".txt,.csv,.tsv,.ics,text/plain,text/csv,text/calendar"></label></div>
      <p class="exam-help">Pasted text and files are read on this device. Only the reviewed exam fields are saved in your Scholia library. Check that every imported date is an exam date.</p>
      <div class="exam-preview" hidden><h3>Review imported dates</h3><p class="exam-help">Check each course, exam type and date against Studentweb. Remove anything you do not want to import.</p><div class="exam-import-warnings" role="status"></div><div class="exam-preview-rows"></div><button type="button" data-exam-action="accept">Add reviewed dates to plan</button><button type="button" data-exam-action="cancelPreview">Discard preview</button></div>
    </details>
    <div class="exam-plan-toolbar"><div><h3>Your exam dates</h3><p class="exam-help">Earliest first, with missing dates last. Select each exam you intend to take.</p></div><label>Show exams <select id="exam-order"><option value="date">Date order</option><option value="course">By course</option></select></label><button type="button" data-exam-action="add">＋ Add exam manually</button></div>
    <p class="exam-summary" role="status" aria-live="polite"></p><div class="exam-groups"></div>
    <p class="exam-help">All dates and times use Europe/Oslo. Missing times stay uncertain; known intervals that overlap are collisions. “No time overlap” does not check travel time or exam registration rules. Verify your final schedule in Studentweb.</p></div>
    <footer class="exam-footer"><p class="exam-feedback" role="status" aria-live="polite"></p><button type="button" data-exam-action="reload">Reload saved plan</button><button type="button" class="primary" data-exam-action="save">Save plan</button></footer>`;
  surface.append(schedule, dialog);
  main.append(surface);
  const $ = (selector) => dialog.querySelector(selector);
  let baseline,
    draft,
    preview = [],
    saving = false;
  const dirty = () => draft && JSON.stringify(draft) !== JSON.stringify(baseline);
  const feedback = (text, error = false) => {
    $('.exam-feedback').textContent = text;
    $('.exam-feedback').classList.toggle('error', error);
  };
  function input(exam, key, title, type = 'text') {
    return `<label>${title}<input data-exam-field="${key}" type="${type}" value="${esc(exam[key] || '')}" ${type === 'text' ? `maxlength="${key === 'courseCode' ? 40 : key === 'component' ? 120 : 180}"` : ''} ${key === 'courseCode' ? 'list="exam-course-codes"' : ''}></label>`;
  }
  function row(exam, isPreview, analysis) {
    const status = analysis?.byId[exam.id] || {
      status: exam.selected ? 'unknown' : 'unselected',
      conflicts: [],
    };
    const peers = status.conflicts
      .map((conflict) => ({ ...conflict, exam: draft.find((item) => item.id === conflict.id) }))
      .filter((peer) => peer.exam);
    return `<article class="exam-row" data-exam-id="${esc(exam.id)}" data-exam-preview="${isPreview}"><div class="exam-row-heading">${!isPreview ? `<label class="exam-intent"><input type="checkbox" data-exam-field="selected" ${exam.selected ? 'checked' : ''}> I intend to take this exam</label><span class="exam-status ${status.status}">${labels[status.status]}</span>` : '<strong>Imported exam</strong>'}<button type="button" data-exam-action="remove" aria-label="Remove ${esc(exam.courseCode)} ${esc(exam.component)}">Remove</button></div>
      <div class="exam-fields">${input(exam, 'courseCode', 'Course code')}${input(exam, 'courseName', 'Course name')}<label>Exam type<select data-exam-field="kind">${[
        ['midterm', 'Midterm'],
        ['final', 'Final'],
        ['other', 'Other'],
      ]
        .map(
          ([value, name]) =>
            `<option value="${value}" ${exam.kind === value ? 'selected' : ''}>${name}</option>`
        )
        .join(
          ''
        )}</select></label>${input(exam, 'component', 'Exam name')}${input(exam, 'date', 'Exam date', 'date')}${input(exam, 'startTime', 'Start (optional)', 'time')}${input(exam, 'endTime', 'End (optional)', 'time')}${input(exam, 'endDate', 'End date (if later)', 'date')}</div>
      <label class="exam-intent exam-flexible"><input type="checkbox" data-exam-field="flexible" ${exam.flexible ? 'checked' : ''}> Flexible timing · agree with professor</label>
      <p class="exam-help">Oral exams default to flexible timing. When enabled, the date stays for reference and this exam is excluded from overlap checks. Turn it off for fixed timing.</p>
      ${peers.length ? `<p class="exam-conflicts">${peers.map(({ status, exam: item }) => `${status === 'collision' ? 'Overlaps with' : 'Possible overlap with'} ${esc(`${item.courseCode || item.courseName} · ${item.component || item.kind} · ${item.date}`)}`).join('; ')}.</p>` : ''}</article>`;
  }
  function render() {
    let analysis;
    try {
      analysis = analyzeExamCollisions(draft);
    } catch {
      analysis = null;
    }
    $('.exam-summary').textContent = analysis
      ? summaryText(draft, analysis)
      : 'Correct the exam dates and times before checking collisions.';
    $('.exam-groups').innerHTML = draft.length
      ? $('#exam-order').value === 'date'
        ? [...draft].sort(compareExamDates).map((exam) => row(exam, false, analysis)).join('')
        : groupExams(draft)
          .map(
            (group) =>
              `<section class="exam-course" data-exam-group="${esc(group.key)}"><div class="exam-course-heading"><h4>${esc(group.courseCode || group.courseName || 'New course')} ${group.courseCode && group.courseName ? `<span>${esc(group.courseName)}</span>` : ''}</h4><button type="button" data-exam-action="selectCourse">Select course</button><button type="button" data-exam-action="clearCourse">Clear selection</button></div>${group.exams.map((exam) => row(exam, false, analysis)).join('')}</section>`
          )
          .join('')
      : '<div class="exam-empty"><strong>A clearer exam season starts here.</strong><p>Import dates from Studentweb or add an exam manually. Nothing is selected until you choose it.</p></div>';
    $('.exam-preview').hidden = !preview.length;
    $('.exam-preview-rows').innerHTML = [...preview].sort(compareExamDates).map((exam) => row(exam, true)).join('');
    $('[data-exam-action="save"]').disabled = saving || !dirty();
    if (!saving) feedback(dirty() ? 'Unsaved changes' : 'Your plan is saved.');
  }
  function refreshAnalysis() {
    let analysis;
    try {
      analysis = analyzeExamCollisions(draft);
    } catch {
      analysis = null;
    }
    $('.exam-summary').textContent = analysis
      ? summaryText(draft, analysis)
      : 'Correct the exam dates and times before checking collisions.';
    const rowsByID = new Map(draft.map((exam) => [exam.id, exam]));
    for (const container of dialog.querySelectorAll('.exam-groups [data-exam-id]')) {
      const exam = rowsByID.get(container.dataset.examId);
      const status = analysis?.byId[exam.id] || {
        status: exam.selected ? 'unknown' : 'unselected',
        conflicts: [],
      };
      const badge = container.querySelector('.exam-status');
      if (badge.className !== `exam-status ${status.status}`) badge.className = `exam-status ${status.status}`;
      if (badge.textContent !== labels[status.status]) badge.textContent = labels[status.status];
      const peers = status.conflicts
        .map((peer) => ({ ...peer, exam: rowsByID.get(peer.id) }))
        .filter((peer) => peer.exam);
      const existingDetail = container.querySelector('.exam-conflicts');
      if (peers.length) {
        const detail = existingDetail || document.createElement('p');
        detail.className = 'exam-conflicts';
        const text =
          peers
            .map(
              ({ status, exam }) =>
                `${status === 'collision' ? 'Overlaps with' : 'Possible overlap with'} ${exam.courseCode || exam.courseName} · ${exam.component || exam.kind} · ${exam.date}`
            )
            .join('; ') + '.';
        if (detail.textContent !== text) detail.textContent = text;
        if (!existingDetail) container.append(detail);
      } else existingDetail?.remove();
    }
  }
  function reset() {
    baseline = normalizeExamPlan(plan(getState()));
    draft = clone(baseline);
    preview = [];
    $('#exam-import-text').value = '';
    $('#exam-import-file').value = '';
    $('.exam-import-warnings').textContent = '';
    render();
  }
  function edit() {
    if (!getState()) return;
    if (!draft || (!dirty() && !preview.length && !$('#exam-import-text').value)) reset();
    let codes = $('#exam-course-codes');
    if (!codes) {
      codes = document.createElement('datalist');
      codes.id = 'exam-course-codes';
      dialog.append(codes);
    }
    codes.innerHTML = (getState().library.courses || [])
      .map(
        (course) =>
          `<option value="${esc((course.code || '').replace(/-(?:\d{2}[HV])(?:-\d{2}[HV])*$/i, ''))}">${esc(course.name)}</option>`
      )
      .join('');
    schedule.hidden = true;
    dialog.hidden = false;
    surface.scrollTop = 0;
    $('[data-exam-action="close"]').focus();
  }
  function parse(text) {
    const result = parseExamImport(text);
    if (!result.exams.length)
      throw new Error(
        result.warnings.join(' ') ||
          'No exam dates recognized. Add an exam manually, or paste course codes with exam dates including the year.'
      );
    preview = result.exams.map((exam) => ({ ...exam, selected: false }));
    $('#exam-import-text').value = '';
    $('.exam-import-warnings').textContent = result.warnings.join(' ');
    render();
  }
  dialog.addEventListener('input', (event) => {
    const field = event.target.dataset.examField;
    if (!field || saving) return;
    const container = event.target.closest('[data-exam-id]');
    const rows = container.dataset.examPreview === 'true' ? preview : draft;
    const exam = rows.find((item) => item.id === container.dataset.examId);
    const wasOral = isOralExam(exam);
    exam[field] = ['selected', 'flexible'].includes(field) ? event.target.checked : event.target.value;
    if (field === 'component' && !wasOral && isOralExam(exam)) {
      exam.flexible = true;
      container.querySelector('[data-exam-field="flexible"]').checked = true;
    }
    if (field === 'courseCode') {
      const course = getState().library.courses.find(
        (item) =>
          (item.code || '').replace(/-(?:\d{2}[HV])(?:-\d{2}[HV])*$/i, '').toUpperCase() ===
          exam.courseCode.trim().toUpperCase()
      );
      if (course && !exam.courseName) {
        exam.courseName = course.name;
        container.querySelector('[data-exam-field="courseName"]').value = course.name;
      }
    }
    feedback('Unsaved changes');
    $('[data-exam-action="save"]').disabled = false;
    refreshAnalysis();
  });
  dialog.addEventListener('change', (event) => {
    if (event.target.id === 'exam-order') { render(); return; }
    if (!event.target.dataset.examField) return;
    // Keep input nodes stable for clicks, Tab and native date pickers. Course
    // groups are rebuilt by explicit planner actions, including saving.
    refreshAnalysis();
  });
  dialog.addEventListener('focusout', (event) => {
    if (!['date', 'startTime'].includes(event.target.dataset.examField)) return;
    setTimeout(() => {
      if ($('#exam-order').value !== 'date') return;
      const active = document.activeElement;
      const container = $('.exam-groups');
      const nodes = new Map([...container.querySelectorAll('[data-exam-id]')].map((node) => [node.dataset.examId, node]));
      for (const exam of [...draft].sort(compareExamDates)) {
        const node = nodes.get(exam.id);
        if (node) container.append(node);
      }
      if (active && container.contains(active)) active.focus({ preventScroll: true });
    }, 0);
  });
  $('#exam-import-file').addEventListener('change', async (event) => {
    const file = event.target.files?.[0];
    if (!file) return;
    try {
      if (file.size > 200000) throw new Error('Choose an exam file smaller than 200 KB.');
      parse(await file.text());
    } catch (error) {
      feedback(error.message, true);
    } finally {
      event.target.value = '';
    }
  });
  dialog.addEventListener('click', async (event) => {
    const button = event.target.closest('[data-exam-action]');
    if (!button || saving) return;
    const action = button.dataset.examAction;
    try {
      if (action === 'studentweb' && signIn) {
        if (dirty() || preview.length || $('#exam-import-text').value.trim()) {
          feedback(
            'Save your changes or reload the saved plan before continuing in the Mac app.',
            true
          );
          return;
        }
        await signIn();
        feedback('Continue in the Mac app. After saving there, choose Reload saved plan here.');
      }
      if (action === 'close') {
        dialog.hidden = true;
        schedule.hidden = false;
        refresh();
        schedule.querySelector('[data-schedule-action=edit]').focus();
      }
      if (action === 'reload') {
        saving = true;
        dialog.querySelectorAll('button, input, select, textarea').forEach((input) => {
          input.disabled = true;
        });
        feedback('Reloading your saved plan…');
        try {
          if (reload) await reload();
          reset();
        } finally {
          saving = false;
          dialog.querySelectorAll('button, input, select, textarea').forEach((input) => {
            input.disabled = false;
          });
          render();
        }
      }
      if (action === 'selectCourse' || action === 'clearCourse') {
        const ids = new Set(
          [...button.closest('[data-exam-group]').querySelectorAll('[data-exam-id]')].map(
            (row) => row.dataset.examId
          )
        );
        for (const exam of draft) if (ids.has(exam.id)) exam.selected = action === 'selectCourse';
        render();
      }
      if (action === 'preview') parse($('#exam-import-text').value);
      if (action === 'cancelPreview') {
        preview = [];
        render();
      }
      if (action === 'accept') {
        const merged = mergeExamImports(normalizeExamPlan(draft), normalizeExamPlan(preview));
        const added = merged.length - draft.length;
        draft = merged;
        preview = [];
        render();
        feedback(
          `${added} exam${added === 1 ? '' : 's'} added to your draft. Existing dates were kept. Select the exams you intend to take, then save.`
        );
      }
      if (action === 'add') {
        draft.push({
          id: crypto.randomUUID(),
          courseCode: '',
          courseName: '',
          component: 'Final exam',
          kind: 'final',
          date: '',
          startTime: '',
          endTime: '',
          endDate: '',
          selected: false,
          source: 'manual',
        });
        render();
        $(
          '.exam-groups [data-exam-id="' +
            draft.at(-1).id +
            '"] input[data-exam-field="courseCode"]'
        ).focus();
      }
      if (action === 'remove') {
        const container = button.closest('[data-exam-id]');
        if (container.dataset.examPreview === 'true')
          preview = preview.filter((exam) => exam.id !== container.dataset.examId);
        else draft = draft.filter((exam) => exam.id !== container.dataset.examId);
        render();
      }
      if (action === 'save') {
        const exams = normalizeExamPlan(draft);
        saving = true;
        dialog.querySelectorAll('button, input, select, textarea').forEach((input) => {
          input.disabled = true;
        });
        feedback('Saving your exam plan…');
        try {
          await save({ exams, baseExams: baseline });
          baseline = clone(exams);
          draft = clone(exams);
          notify('Exam plan saved.');
        } finally {
          saving = false;
          dialog.querySelectorAll('button, input, select, textarea').forEach((input) => {
            input.disabled = false;
          });
          render();
        }
      }
    } catch (error) {
      feedback(error.message, true);
    }
  });
  let scheduleSaving = false,
    undo = null,
    undoBase = null,
    scheduleKey;
  const advice = recommend ? installExamRecommendation({ getState, recommend, selectModel, apply: (exams) => persistSelection(exams) }) : null;
  function refresh() {
    if (surface.hidden || !getState() || scheduleSaving) return;
    const key = JSON.stringify([
      examToday(),
      plan(getState()),
      getState().library.courses.map(({ id, code, name, favorite }) => [id, code, name, favorite]),
    ]);
    if (scheduleKey === key) { advice?.refresh(); return; }
    scheduleKey = key;
    const selectionOpen = schedule.querySelector('.exam-course-selection')?.open;
    const pastOpen = schedule.querySelector('.exam-past')?.open;
    const top = surface.scrollTop;
    schedule.innerHTML = examScheduleMarkup(getState());
    if (advice) {
      schedule.querySelector('.exam-schedule-layout').before(advice.element);
      advice.refresh();
    }
    if (selectionOpen && schedule.querySelector('.exam-course-selection'))
      schedule.querySelector('.exam-course-selection').open = true;
    if (pastOpen && schedule.querySelector('.exam-past')) schedule.querySelector('.exam-past').open = true;
    schedule.querySelectorAll('[data-partial]').forEach((input) => {
      input.indeterminate = true;
    });
    if (undo && JSON.stringify(plan(getState())) !== JSON.stringify(undoBase)) undo = null;
    if (undo) {
      const button = document.createElement('button');
      button.type = 'button';
      button.dataset.scheduleAction = 'undo';
      button.textContent = 'Undo last change';
      schedule.querySelector('.exam-schedule-feedback').append(button);
    }
    surface.scrollTop = top;
  }
  function scheduleFeedback(message, error = false) {
    const node = schedule.querySelector('.exam-schedule-feedback');
    node.replaceChildren();
    node.textContent = message;
    node.classList.toggle('error', error);
  }
  async function persistSelection(exams, remember = true) {
    if (scheduleSaving) return;
    if (dirty() || preview.length || $('#exam-import-text').value.trim()) {
      scheduleFeedback(
        'You have unsaved date edits. Open Manage dates to save or reload them first.',
        true
      );
      return;
    }
    const baseExams = clone(plan(getState()));
    scheduleSaving = true;
    schedule.querySelectorAll('button, input, select').forEach((node) => {
      node.disabled = true;
    });
    scheduleFeedback('Saving your choices…');
    try {
      await save({ exams, baseExams });
      undo = remember ? baseExams : null;
      undoBase = clone(plan(getState()));
      draft = baseline = undefined;
    } catch (error) {
      scheduleSaving = false;
      scheduleKey = null;
      refresh();
      scheduleFeedback(error.message, true);
      return;
    } finally {
      scheduleSaving = false;
    }
    scheduleKey = null;
    refresh();
    schedule
      .querySelector('.exam-schedule-feedback')
      .prepend('Saved. Conflict-free selected courses are favorited. ');
  }
  function open() {
    if (!getState()) return;
    surface.hidden = false;
    main.classList.add('exam-view-open');
    document.querySelector('#breadcrumb').textContent = 'Exam dates';
    document.querySelector('[data-action=library]')?.removeAttribute('aria-current');
    dialog.hidden = true;
    schedule.hidden = false;
    document.querySelector('[data-action=exams]')?.setAttribute('aria-current', 'page');
    refresh();
    const heading = schedule.querySelector('h1');
    heading.tabIndex = -1;
    heading.focus({ preventScroll: true });
    // Apply the same favorite rule to plans saved before this view existed.
    const ids = new Set(examFavoriteCourseIDs(plan(getState()), getState().library.courses));
    if (getState().library.courses.some((course) => ids.has(course.id) && !course.favorite))
      void persistSelection(clone(plan(getState())), false);
  }
  function close() {
    advice?.cancel();
    surface.hidden = true;
    main.classList.remove('exam-view-open');
    document.querySelector('[data-action=exams]')?.removeAttribute('aria-current');
    if (getState()?.showingLibrary)
      document.querySelector('[data-action=library]')?.setAttribute('aria-current', 'page');
    if (location.hash === '#exams')
      history.replaceState(null, '', location.pathname + location.search);
  }
  schedule.addEventListener('click', async (event) => {
    const button = event.target.closest('[data-schedule-action]');
    if (!button || scheduleSaving) return;
    if (button.dataset.scheduleAction === 'edit') edit();
    if (button.dataset.scheduleAction === 'undo' && undo) await persistSelection(undo, false);
    if (['selectAll', 'clearAll'].includes(button.dataset.scheduleAction)) {
      const today = examToday();
      await persistSelection(plan(getState()).map((exam) => isPastExam(exam, today) ? exam
        : { ...exam, selected: button.dataset.scheduleAction === 'selectAll' }));
    }
    if (button.dataset.scheduleAction === 'flexible') {
      try {
        await persistSelection(setExamFlexibleTiming(plan(getState()), button.dataset.examId, button.dataset.flexible === 'true'));
      } catch (error) {
        scheduleFeedback(error.message, true);
      }
    }
    if (button.dataset.scheduleAction === 'choose') {
      try {
        await persistSelection(
          resolveExamConflict(plan(getState()), button.dataset.keep, button.dataset.drop)
        );
      } catch (error) {
        scheduleFeedback(error.message, true);
      }
    }
  });
  schedule.addEventListener('change', async (event) => {
    const key = event.target.dataset.scheduleCourse;
    if (!key || scheduleSaving) return;
    const ids = new Set(
      groupExams(plan(getState()).filter((exam) => !isPastExam(exam)))
        .find((group) => group.key === key)
        .exams.map((exam) => exam.id)
    );
    await persistSelection(
      plan(getState()).map((exam) => ({
        ...exam,
        selected: ids.has(exam.id) ? event.target.checked : exam.selected,
      }))
    );
  });
  return {
    open,
    close,
    refresh,
    isOpen: () => !surface.hidden,
    dirty: () => dirty() || preview.length > 0 || !!$('#exam-import-text').value,
  };
}
