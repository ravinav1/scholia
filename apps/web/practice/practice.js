import { escapeHtml as esc } from '../../chrome/src/html-escape.js';
import { studyRenderKey } from '../workspace/study-session.js';
import { practiceQuestionMarkup, practiceRecapMarkup } from './practice-view.js';
import { coursePracticeSetupMarkup } from './course-practice.js';
import '../styles/practice.css';
const date = (value) => new Date((value + 978307200) * 1000).toLocaleString();
const button = (text, action, attrs = '') =>
  `<button type="button" data-practice="${action}" ${attrs}>${text}</button>`;

export class StudyPractice {
  constructor({ dialog, request, getState, getSelection, notify, onExplain, onSource, accountID = 'local' }) {
    Object.assign(this, { dialog, request, getState, getSelection, notify, onExplain, onSource });
    this.storagePrefix = accountID === 'local' ? 'scholia.practice.' : `scholia.practice.account.${accountID}.`;
    this.outboxPrefix = this.storagePrefix + 'outbox.';
    this.clientID = sessionStorage.getItem(this.storagePrefix + 'client') || crypto.randomUUID();
    sessionStorage.setItem(this.storagePrefix + 'client', this.clientID);
    this.outboxConflicts = new Set();
    this.screen = 'setup';
    this.view = null;
    this.key = '';
    this.pending = false;
    dialog.addEventListener('click', (e) => {
      const b = e.target.closest('[data-practice]');
      if (b) {
        e.preventDefault();
        e.stopPropagation();
        this.click(b).catch((error) => notify(error.message));
      }
    });
    dialog.addEventListener('submit', (e) => {
      e.preventDefault();
      this.submit(e.target).catch((error) => notify(error.message));
    });
    dialog.addEventListener('input', (e) => {
      if (e.target.id === 'practice-answer' || e.target.id === 'practice-confidence')
        this.saveDraft();
    });
    dialog.addEventListener('close', () => {
      clearTimeout(this.timer);
      this.saveDraft();
    });
  }
  async open(screen = 'setup') {
    this.sourceScope = screen === 'course' || !this.getState().library.selectedDocumentID ? 'course' : 'reading';
    this.screen = screen === 'course' ? 'setup' : screen;
    if (!this.dialog.open) this.dialog.replaceChildren();
    this.key = '';
    if (!this.dialog.open) this.dialog.showModal();
    await this.refresh();
  }
  async refresh() {
    clearTimeout(this.timer);
    try {
      if (!this.pending) {
        const view = await this.request('/api/learning');
        if (
          this.generating &&
          view.revision > this.generationStart &&
          view.session?.id !== this.generationSession
        ) {
          this.generating = false;
          this.screen = 'session';
        }
        if (view.error) this.generating = false;
        this.view = view;
        this.render();
        await this.flushOutbox();
      }
    } catch {
      this.notify(
        this.getState().hosted
          ? 'Reconnect to continue practice. Unsent answers remain in this browser.'
          : 'Practice is saved locally. Reconnect to the Mac to continue; unsent answers remain in this browser.'
      );
    } finally {
      if (this.dialog.open)
        this.timer = setTimeout(
          () => this.refresh(),
          this.view?.busy || this.generating ? 600 : 3500
        );
    }
  }
  storageKey() {
    const s = this.view?.session;
    return s
      ? `${this.storagePrefix}draft.${this.clientID}.${s.id}.${s.currentQuestionID || s.questionIDs[s.position]}`
      : '';
  }
  saveDraft() {
    const input = this.dialog.querySelector('#practice-answer');
    if (!input || !this.renderedDraftKey) return;
    try {
      localStorage.setItem(
        this.renderedDraftKey,
        JSON.stringify({
          text: input.value,
          confidence: this.dialog.querySelector('#practice-confidence').value,
        })
      );
    } catch {
      this.notify('Browser storage is full. Keep this window open until your answer is saved.');
    }
  }
  restoreDraft() {
    try {
      const saved = JSON.parse(localStorage.getItem(this.storageKey()) || '{}');
      const input = this.dialog.querySelector('#practice-answer');
      if (input) {
        input.value = saved.text || '';
        this.dialog.querySelector('#practice-confidence').value = saved.confidence || '';
      }
    } catch {}
  }
  command(action, extra = {}) {
    const s = this.view?.session;
    return {
      id: crypto.randomUUID(),
      action,
      sessionID: s?.id,
      questionID: s?.questionIDs[s.position],
      expectedVersion: s?.version,
      ...extra,
    };
  }
  async act(command) {
    this.saveDraft();
    this.pending = true;
    this.setDisabled();
    try {
      this.view = await this.request('/api/learning', { action: 'practice', learning: command });
      this.key = '';
      this.render();
      return this.view;
    } finally {
      this.pending = false;
      this.setDisabled();
    }
  }
  async flushOutbox() {
    const keys = Object.keys(localStorage).filter((key) =>
      key.startsWith(this.outboxPrefix)
    );
    for (const key of keys) {
      if (this.outboxConflicts.has(key)) continue;
      const raw = localStorage.getItem(key);
      if (!raw) continue;
      let command;
      try {
        command = JSON.parse(raw);
      } catch {
        continue;
      }
      try {
        await this.act(command);
        localStorage.removeItem(key);
      } catch (error) {
        if (error.status) this.outboxConflicts.add(key);
        this.notify(
          `Saved offline answer needs attention: ${error.message} Your answer remains in the draft for this session.`
        );
        break;
      }
    }
  }
  async submit(form) {
    if (this.pending) return;
    if (form.id === 'practice-setup') {
      const state = this.getState(),
        data = new FormData(form);
      this.sourceScope = data.get('sourceScope');
      this.practiceStyle = data.get('practiceStyle');
      this.pending = true;
      this.generating = true;
      this.generationStart = this.view.revision;
      this.generationSession = this.view.session?.id;
      this.setDisabled();
      try {
        this.view = await this.request('/api/learning', {
          action: 'practiceGenerate',
          owner: state.draftOwner,
          text: data.get('scope'),
          count: Number(data.get('count')),
          sourceScope: data.get('sourceScope'),
          practiceStyle: data.get('practiceStyle'),
          enabled: data.get('openBook') === 'on',
          selection: this.getSelection(),
        });
        this.key = '';
        this.render();
      } catch (e) {
        this.generating = false;
        throw e;
      } finally {
        this.pending = false;
        this.setDisabled();
      }
    } else if (form.id === 'practice-answer-form') {
      const text = this.dialog.querySelector('#practice-answer').value.trim();
      if (!text) return;
      const confidence =
        Number(this.dialog.querySelector('#practice-confidence').value) || undefined;
      const command = this.command('attempt', { text, confidence });
      this.saveDraft();
      const outboxKey = `${this.outboxPrefix}${command.id}`;
      try {
        localStorage.setItem(outboxKey, JSON.stringify(command));
      } catch {
        this.notify(
          'Could not save an offline copy; keep this window open until submission succeeds.'
        );
      }
      try {
        await this.act(command);
      } catch (error) {
        if (error.status) this.outboxConflicts.add(outboxKey);
        throw error;
      }
      localStorage.removeItem(outboxKey);
      localStorage.removeItem(this.storageKey());
    }
  }
  async click(buttonValue) {
    const action = buttonValue.dataset.practice;
    if (action === 'close') {
      this.dialog.close();
      return;
    }
    if (action === 'downloadCourse') {
      this.dialog.close();
      await this.request('/api/action', { action: 'downloadAll', id: this.getState().library.selectedCourseID });
      this.notify('Downloading course materials. Reopen practice when the downloads finish.');
      return;
    }
    if (['setup', 'reviewQueue'].includes(action)) {
      this.saveDraft();
      if (this.generating) {
        await this.act(this.command('cancel'));
        this.generating = false;
      }
      this.screen = action === 'setup' ? 'setup' : 'review';
      this.key = '';
      this.render();
      return;
    }
    if (this.pending) return;
    if (action === 'dismissRecovery') {
      localStorage.removeItem(buttonValue.dataset.key);
      this.key = '';
      this.render();
      return;
    }
    if (action === 'resume' || action === 'review') {
      this.saveDraft();
      await this.act(
        this.command(action, {
          sessionID: buttonValue.dataset.session,
          questionID: buttonValue.dataset.question,
        })
      );
      this.screen = 'session';
      this.key = '';
      this.render();
      return;
    }
    if (action === 'reader') {
      const result = await this.act(this.command('source'));
      await this.onSource(result.question);
      this.dialog.close();
      return;
    }
    if (action === 'explain') {
      // Tutor access is assistance, but must not reveal the private answer.
      const result = await this.act(this.command('source'));
      await this.onExplain(result.question, result.attempts);
      this.dialog.close();
      return;
    }
    if (action === 'limit') {
      await this.act(
        this.command('limit', { days: Number(this.dialog.querySelector('#practice-limit').value) })
      );
      return;
    }
    const attemptID = buttonValue.dataset.attempt;
    const text =
      action === 'selfAssess'
        ? buttonValue.dataset.verdict
        : attemptID
          ? this.dialog.querySelector(`[data-correction="${CSS.escape(attemptID)}"]`)?.value
          : undefined;
    await this.act(
      this.command(action, {
        ...(buttonValue.dataset.question ? { questionID: buttonValue.dataset.question } : {}),
        ...(buttonValue.dataset.version
          ? { expectedVersion: Number(buttonValue.dataset.version) }
          : {}),
        ...(action === 'snooze' ? { days: 1 } : {}),
        ...(attemptID ? { attemptID, text } : {}),
      })
    );
    if (action === 'cancel') this.generating = false;
    if (action === 'saveReview') this.notify('Saved for a delayed review.');
  }
  setDisabled() {
    for (const input of this.dialog.querySelectorAll(
      '#practice-setup input, #practice-setup select'
    ))
      input.disabled = this.pending || !!this.view?.busy || this.generating;
    for (const b of this.dialog.querySelectorAll('button')) {
      if (['close', 'setup', 'reviewQueue', 'cancel'].includes(b.dataset.practice)) continue;
      b.disabled =
        this.pending ||
        b.dataset.unavailable === 'true' ||
        ((this.view?.busy || this.generating) &&
          ['next', 'finish', 'feedback', 'revise'].includes(b.dataset.practice)) ||
        ((this.view?.busy || this.generating) && b.type === 'submit');
    }
  }
  render() {
    if (!this.view || !this.dialog.open) return;
    const key = studyRenderKey([this.view, this.screen, this.generating]);
    if (this.key === key) return;
    this.saveDraft();
    const focus = this.dialog.contains(document.activeElement) ? document.activeElement.id : '',
      caret = document.activeElement?.selectionStart;
    const scroll = this.dialog.querySelector('.practice-body')?.scrollTop || 0;
    const fields = [
      ...this.dialog.querySelectorAll(
        '#practice-setup input, #practice-setup select, [data-correction]'
      ),
    ].map((node) => ({
      selector: node.dataset.correction
        ? `[data-correction="${CSS.escape(node.dataset.correction)}"]`
        : `[name="${node.name}"]`,
      value: node.value,
      checked: node.checked,
    }));
    const { view } = this,
      state = this.getState();
    const course = state.library.courses.find((c) => c.id === state.library.selectedCourseID),
      documentValue = course?.documents.find((d) => d.id === state.library.selectedDocumentID);
    let body;
    const recoveries = Object.keys(localStorage)
      .filter((key) => key.startsWith(this.outboxPrefix))
      .map((key) => {
        try {
          const item = JSON.parse(localStorage.getItem(key));
          return `<details><summary>Unsent answer · original session ${esc(item.sessionID)}</summary><p>Waiting to sync, or needs review after a change in another window. Copy your answer before dismissing this recovery.</p><textarea readonly aria-label="Recovered practice answer">${esc(item.text)}</textarea>${button('Dismiss recovery', 'dismissRecovery', `data-key="${esc(key)}"`)}</details>`;
        } catch {
          return '';
        }
      })
      .join('');
    const sessions = `${recoveries}<h3>Recent sessions</h3><div class="practice-sessions">${view.sessions.filter((s) => s.courseID === course?.id).map((s) => button(`${esc(s.title)} · ${s.finished ? 'Recap' : 'Resume'}`, 'resume', `data-session="${esc(s.id)}"`)).join('')}</div>`;
    if (this.screen === 'setup') {
      body = coursePracticeSetupMarkup({ course, document: documentValue, sourceScope: this.sourceScope,
        practiceStyle: this.practiceStyle, selection: this.getSelection(), page: state.page, coverage: view.coverage }) +
        `<p class="fineprint">Untimed · ${state.hosted ? 'Saved to your account' : 'Saved locally'} · Generated questions can be imperfect</p>${sessions}`;
    } else if (this.screen === 'review') {
      // Server dueCount applies the workload limit. Only the earliest due items are offered today.
      const now = Date.now() / 1000 - 978307200;
      const due = new Set(
        view.reviews
          .filter((r) => r.dueAt <= now)
          .slice(0, view.dueCount)
          .map((r) => r.id)
      );
      body = `<h2>Today · ${view.dueCount} available</h2><p>Initial intervals: 1, 3, 6… days, capped at 30. Independent recall extends the interval. Assistance brings a short follow-up; unresolved feedback keeps the interval. No penalties for missed days.</p><div class="practice-actions"><label>Daily workload <input type="number" id="practice-limit" min="1" max="30" value="${view.dailyLimit}"></label>${button('Save limit', 'limit')}</div>${!view.reviews.length ? '<p>Save a question after practice to bring it back here after a delay.</p>' : ''}${view.reviews.map((r) => `<article class="practice-attempt"><h3>${esc(r.concept)}</h3><p>${esc(r.title)} · ${esc(date(r.dueAt))}</p><p>${esc(r.reason)}</p>${r.stale ? '<p class="practice-warning">Source changed · needs revalidation</p>' : ''}<div class="practice-actions">${button('Review', 'review', `data-question="${r.id}" ${!due.has(r.id) ? 'data-unavailable="true"' : ''}`)}${button('Snooze 1 day', 'snooze', `data-question="${r.id}" data-version="${r.version}"`)}${button('Remove', 'removeReview', `data-question="${r.id}" data-version="${r.version}"`)}</div></article>`).join('')}${sessions}`;
    } else body = view.session?.finished ? practiceRecapMarkup(view) : practiceQuestionMarkup(view);
    this.dialog.innerHTML = `<header class="practice-heading"><strong>Practice & review</strong><div>${button('New practice', 'setup')}${button(`Review due (${view.dueCount})`, 'reviewQueue')}${button('Close', 'close', 'aria-label="Close practice"')}</div></header><div class="practice-status" role="status">${view.busy || this.generating ? `${esc(view.busy || 'Preparing your sources…')}${button('Cancel', 'cancel')}` : ''}</div>${view.error ? `<p class="practice-warning" role="alert">${esc(view.error)}</p>` : ''}<div class="practice-body">${body}</div>`;
    for (const field of fields) {
      const node = this.dialog.querySelector(field.selector);
      if (node) {
        node.value = field.value;
        node.checked = field.checked;
      }
    }
    this.key = key;
    this.renderedDraftKey = this.storageKey();
    this.restoreDraft();
    this.setDisabled();
    const node = focus && this.dialog.querySelector(`#${CSS.escape(focus)}`);
    if (node) {
      node.focus({ preventScroll: true });
      if (
        caret !== null &&
        node.setSelectionRange &&
        node.tagName !== 'SELECT' &&
        node.type !== 'number'
      )
        node.setSelectionRange(caret, caret);
    }
    this.dialog.querySelector('.practice-body').scrollTop = scroll;
  }
}
