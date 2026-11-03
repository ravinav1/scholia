import { documentDownloadFilename } from '../../packages/core/src/document-download.js';
import { ENTIRE_PDF_QUESTION } from '../../packages/core/src/entire-pdf.js';
import { studyModelPickerMarkup } from './model-picker.js';
import { StudyDocumentEditor, canEditDocument } from './document-editor.js';
import { escapeHtml as esc } from '../chrome/src/html-escape.js';
import {
  courseLibraryMarkup,
  workspacePanelMarkup,
  courseDisplayName,
  courseLibraryRenderKey,
  catalogChangeSummary,
} from './course-library.js';
import { installHostedAccount } from './hosted-account.js';
import { installTutorResize } from './workspace-resize.js';
import { materialGroupsMarkup, materialsViewMarkup, materialViewPicker } from './materials.js';
import {
  assignmentsMarkup,
  selectedAssignment,
  assignmentAgendaMarkup,
} from './assignments.js';
import {
  teachingModes,
  coursePrompts,
  conversationScope,
  courseCoverage,
  readingSourceSummary,
  studyPrompt,
  appendStudyPrompt,
  recentReadings,
  continueReadingMarkup,
  readerRenderKey,
  studyPollDelay,
  studyRenderKey,
} from './study-session.js';
import { StudyConversation } from './study-conversation.js';
import { mountFileComposer } from '../chrome/src/file-composer.js';
import { readChatFile } from '../chrome/src/file-input.js';
import { normalizeFileAttachments } from '../../packages/core/src/file-attachments.js';
import '../chrome/file-attachments.css';
import { courseLinkTarget, isHTMLDocument, safeDocumentURL, restoreCourseLinks, originalDocumentHTML } from '../../packages/core/src/course-documents.js';
import { installWorkspaceSearch } from './workspace-search.js';
import { installWorkspaceMemory } from './workspace-memory.js';
import { installWorkspaceShortcuts } from './workspace-shortcuts.js';
import { installExamPlanner } from './exam-planner.js';
import './style.css';
import './dashboard.css';
import './assignment-page.css';
import './exam-planner.css';
import './navigation.css';
import './practice.css';

const $ = (selector) => document.querySelector(selector);
const compactNavigation = window.matchMedia('(max-width: 850px)');
let navigationOpener;
function setSidebarOpen(open, { restoreFocus = true } = {}) {
  open = !!open && compactNavigation.matches;
  const sidebar = $('#course-navigation');
  const wasOpen = $('.app').classList.contains('sidebar-open');
  if (open && !wasOpen) navigationOpener = document.activeElement;
  $('.app').classList.toggle('sidebar-open', open);
  $('.sidebar-scrim').hidden = !open;
  $('#main-content').inert = open;
  $('.mobile-menu').setAttribute('aria-expanded', String(open));
  $('.mobile-menu').setAttribute('aria-label', open ? 'Close navigation' : 'Open navigation');
  if (open) {
    sidebar.setAttribute('role', 'dialog');
    sidebar.setAttribute('aria-modal', 'true');
    $('.sidebar-close').focus({ preventScroll: true });
  } else {
    sidebar.removeAttribute('role');
    sidebar.removeAttribute('aria-modal');
    if (wasOpen && restoreFocus) {
      const target = navigationOpener?.isConnected ? navigationOpener : $('.mobile-menu');
      target.focus({ preventScroll: true });
    }
  }
}
compactNavigation.addEventListener('change', () => {
  const focused = document.activeElement;
  setSidebarOpen(false, { restoreFocus: false });
  if (focused === $('.sidebar-close') && !compactNavigation.matches)
    $('.sidebar .nav-all').focus({ preventScroll: true });
  else if (compactNavigation.matches && $('#course-navigation').contains(focused))
    $('.mobile-menu').focus({ preventScroll: true });
});
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && $('#sync-status').open && !$('dialog[open]')) {
    event.preventDefault();
    $('#sync-status').open = false;
    $('#sync-status summary').focus();
    return;
  }
  if (!$('.app').classList.contains('sidebar-open') || $('dialog[open]')) return;
  if (event.key === 'Escape') {
    event.preventDefault();
    setSidebarOpen(false);
  } else if (event.key === 'Tab') {
    const items = [
      ...$('#course-navigation').querySelectorAll(
        'a[href], button:not(:disabled), input:not(:disabled), select:not(:disabled), summary, [tabindex="0"]'
      ),
    ].filter((item) => item.getClientRects().length);
    const first = items[0],
      last = items.at(-1);
    if (
      event.shiftKey &&
      (document.activeElement === first ||
        !$('#course-navigation').contains(document.activeElement))
    ) {
      event.preventDefault();
      last?.focus();
    } else if (
      !event.shiftKey &&
      (document.activeElement === last || !$('#course-navigation').contains(document.activeElement))
    ) {
      event.preventDefault();
      first?.focus();
    }
  }
});
if (!/Mac|iPhone|iPad/.test(navigator.platform)) $('.action-search kbd').textContent = 'Ctrl K';
if (!/Mac|iPhone|iPad/.test(navigator.platform)) $('.action-switch kbd').textContent = 'Ctrl ⇧ K';
installTutorResize($('#workspace'), $('#tutor-divider'));
const hosted = !!document.querySelector('meta[name="scholia-hosted"]');
const accountID = document.querySelector('meta[name="scholia-account"]')?.content || 'local';
const preferenceKey = (name) => (hosted ? `${name}:${accountID}` : name);
const token = $('meta[name="scholia-token"]').content;
const conversation = new StudyConversation($('#messages'));
const tutorPanel = $('.tutor');
const courseChatStates = new Map();
let state,
  lastLayout = '',
  lastNavigation = '',
  lastMessages = '',
  lastModels = '';
let lastReasoning = '';
let lastAssignment = '';
let lastClockMinute = -1;
let stateETag = '';
const stateResponseTags = new WeakMap();
let closedSections;
try {
  closedSections = new Set(
    JSON.parse(localStorage.getItem(preferenceKey('scholia.collapsedSections')) || '[]')
  );
} catch {
  closedSections = new Set();
}
function persistSections() {
  try {
    localStorage.setItem(
      preferenceKey('scholia.collapsedSections'),
      JSON.stringify([...closedSections])
    );
  } catch {}
}
let materialViews;
const readingViews = new Set();
try {
  materialViews =
    JSON.parse(localStorage.getItem(preferenceKey('scholia.materialViews')) || '{}') || {};
} catch {
  materialViews = {};
}
function selectMaterialView(view) {
  materialViews[course().id] = view === 'files' ? 'files' : 'organized';
  try {
    localStorage.setItem(preferenceKey('scholia.materialViews'), JSON.stringify(materialViews));
  } catch {}
  renderMaterials();
}
let courseQuery = '',
  materialQuery = '',
  selectedText = '',
  imageData = null;
let includeCompletedAssignments = true;
let agendaQuery = '',
  agendaFilter = 'due';
let assignmentsPageFilter = 'all';
const showingAssignments = () => state?.showingLibrary && state.library.courseLibraryView === 'assignments';
let agendaNeedsTodayFocus = true;
let dashboardPanel = 'workspaces';
let pdfReader,
  notebookReader,
  readerGeneration = 0,
  readerURLs = [];
let documentEditor;
const editDocuments = new Map();
let actionQueue = Promise.resolve(),
  draftTimer,
  toastTimer,
  pollActive = false,
  revision = 0,
  pendingActions = 0;
let draftDirty = false,
  previousContext = '',
  localError = '',
  draftOwner = null,
  draftRecovered = false;
const ownDraftUpdates = new Map();
function latestOwnOwner(owner) {
  const seen = new Set();
  while (owner && ownDraftUpdates.has(studyRenderKey(owner)) && !seen.has(studyRenderKey(owner))) {
    const key = studyRenderKey(owner);
    seen.add(key);
    owner = ownDraftUpdates.get(key);
  }
  return owner;
}
let pollTimer,
  pollFailed = false,
  sendPending = false;
let lastComposerText, lastComposerWidth;
const course = () =>
  state?.library.courses.find((item) => item.id === state.library.selectedCourseID);
const doc = () => course()?.documents.find((item) => item.id === state.library.selectedDocumentID);
const examPlanner = installExamPlanner({
  getState: () => state,
  save: (values) => action('examPlan', values),
  recommend: (values, signal) => request('/api/exam-recommendation', values, signal),
  selectModel: (values) => action('model', values),
  reload: async () => { await actionQueue; update(await request('/api/state')); },
  signIn: hosted ? null : () => action('studentweb'),
  notify,
});
const workspaceSearch = installWorkspaceSearch({
  request,
  getState: () => state,
  notify,
  onOpen: async (hit) => {
    await navigate('course', { id: hit.courseID });
    if (hit.documentID) {
      await navigate('document', { id: hit.documentID });
      await navigate('source', { id: hit.documentID, page: hit.page || 1 });
    }
    else if (hit.kind === 'assignments')
      await navigate('assignment', { id: hit.materialID, courseID: hit.courseID });
    else await action('material', { id: hit.materialID, courseID: hit.courseID });
  },
});
const practiceOptions = {
  accountID,
  dialog: $('#practice-dialog'),
  request,
  getState: () => state,
  getSelection: () => selectedText,
  notify,
  onSource: async (question) => {
    await navigate('course', { id: question.source.courseID });
    await navigate('document', { id: question.source.documentID });
    await navigate('source', { id: question.source.documentID, page: question.source.page });
  },
  onExplain: async (question, attempts = []) => {
    await navigate('course', { id: question.source.courseID });
    await navigate('document', { id: question.source.documentID });
    await navigate('source', { id: question.source.documentID, page: question.source.page });
    await navigate('newThread');
    const attempt = attempts.filter((item) => item.questionID === question.id).at(-1);
    $('#question').value = `Help me understand this practice question without giving away the solution:\n${question.prompt}`
      + (attempt ? `\n\nMy attempt:\n${attempt.answer}\n\nHelp me find the first gap in my reasoning.` : '\n\nExplain the relevant concept and give me one starting hint.');
    draftDirty = true;
    draftOwner = state.draftOwner;
    persistBrowserDraft();
    await saveDraft('Explain');
  },
};
let practice;
async function openPractice(screen) {
  const { StudyPractice } = await import('./practice.js');
  practice ||= new StudyPractice(practiceOptions);
  await practice.open(screen);
}
const workspaceShortcuts = installWorkspaceShortcuts({
  getState: () => state,
  notify,
  beforeOpen: () => setSidebarOpen(false),
  onRun: async (item) => {
    switch (item.action) {
      case 'keyboardShortcuts': workspaceShortcuts.openHelp(); break;
      case 'search': workspaceSearch.open(); break;
      case 'searchAll': workspaceSearch.open({ allWorkspaces: true }); break;
      case 'course': await navigate('course', { id: item.courseID }); break;
      case 'library':
      case 'assignments':
      case 'materials': await navigate(item.action); break;
      case 'newThread':
        if (state.streaming || sendPending) return;
        await navigate('newThread');
        focusTutor();
        break;
      case 'exams': examPlanner.open(); break;
      case 'reviewDue': await openPractice('review'); break;
      case 'upload': $('#document-upload').click(); break;
      case 'create':
        $('#create-dialog').showModal();
        $('#create-form input').focus();
        break;
    }
  },
});
function persistBrowserDraft() {
  try {
    if (draftDirty)
      sessionStorage.setItem(
        preferenceKey('scholia.study.draft'),
        JSON.stringify({ ...draftValues(), owner: draftOwner })
      );
    else sessionStorage.removeItem(preferenceKey('scholia.study.draft'));
  } catch {
    notify('Could not keep a browser recovery copy. Keep this tab open until your draft is saved.');
  }
}

const button = (label, action, id = '', cls = '', accessibleLabel = '') =>
  `<button class="${cls}" data-action="${action}" data-id="${esc(id)}"${accessibleLabel ? ` aria-label="${esc(accessibleLabel)}"` : ''}>${label}</button>`;
const safeURL = (value) => {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' ? esc(url.href) : '';
  } catch {
    return '';
  }
};
const courseURL = (item) =>
  item.canvasID ? safeURL(`${item.canvasOrigin}/courses/${item.canvasID}`) : '';

async function request(path, payload, signal) {
  const conditionalState = path === '/api/state' && !payload;
  const response = await fetch(path, {
    method: payload ? 'POST' : 'GET',
    headers: {
      'X-Scholia-Token': token,
      ...(conditionalState && stateETag ? { 'If-None-Match': stateETag } : {}),
      ...(payload ? { 'Content-Type': 'application/json' } : {}),
    },
    body: payload ? JSON.stringify(payload) : undefined,
    signal,
  });
  if (hosted && response.status === 401) {
    location.replace('/login');
    throw new Error('Sign in to continue.');
  }
  if (conditionalState && response.status === 304) return null;
  const result = await response.json();
  if (!response.ok)
    throw Object.assign(new Error(result.error || `Scholia returned ${response.status}.`), {
      status: response.status,
    });
  if (conditionalState) stateResponseTags.set(result, response.headers.get('ETag') || '');
  return result;
}
function notify(message) {
  $('#toast').textContent = message;
  $('#toast').hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => {
    $('#toast').hidden = true;
  }, 6000);
}
function action(actionName, values = {}) {
  revision++;
  pendingActions++;
  const owned = ['draft', 'send', 'page'].includes(actionName);
  if (owned && !values.owner)
    values = {
      ...values,
      owner: ['draft', 'send'].includes(actionName)
        ? draftOwner || state.draftOwner
        : state.draftOwner,
    };
  const job = actionQueue
    .catch(() => {})
    .then(async () => {
      const owner = owned ? latestOwnOwner(values.owner) : undefined;
      const contextOwner = ['automaticContext', 'context'].includes(actionName) ? state.draftOwner : null;
      const next = await request('/api/action', {
        action: actionName,
        ...values,
        ...(owned ? { owner } : {}),
      });
      $('#connection-error').hidden = true;
      if (owned || contextOwner) {
        const previousOwner = owner || contextOwner;
        if (studyRenderKey(latestOwnOwner(draftOwner)) === studyRenderKey(previousOwner))
          draftOwner = next.draftOwner;
        if (studyRenderKey(previousOwner) !== studyRenderKey(next.draftOwner)) {
          ownDraftUpdates.delete(studyRenderKey(next.draftOwner));
          ownDraftUpdates.set(studyRenderKey(previousOwner), next.draftOwner);
        }
        if (ownDraftUpdates.size > 100) ownDraftUpdates.delete(ownDraftUpdates.keys().next().value);
      }
      update(next);
      schedulePoll();
      return next;
    });
  job
    .finally(() => {
      pendingActions--;
    })
    .catch(() => {});
  actionQueue = job.catch((error) => {
    notify(error.message);
  });
  return job;
}
async function poll() {
  clearTimeout(pollTimer);
  if (pendingActions || pollActive || (document.hidden && state)) {
    schedulePoll();
    return;
  }
  pollActive = true;
  const before = revision;
  try {
    const next = await request('/api/state', null, AbortSignal.timeout(6000));
    if (revision === before) {
      if (next) update(next);
      // Deadlines and answer timers still advance when the payload is unchanged.
      else if (state && Math.floor(Date.now() / 60000) !== lastClockMinute) update(state);
      else if (state?.streaming) renderMessages();
    }
    $('#connection-error').hidden = true;
    pollFailed = false;
  } catch (error) {
    pollFailed = true;
    $('#connection-error').hidden = false;
    $('#connection-error').textContent = hosted
      ? 'The server is unavailable. Retrying… Your draft is kept in this tab.'
      : 'The Mac connection is unavailable. Keep Scholia running, then reopen this website from its Open in Browser menu.';
  } finally {
    pollActive = false;
    schedulePoll();
  }
}
function schedulePoll() {
  clearTimeout(pollTimer);
  pollTimer = setTimeout(poll, studyPollDelay(state, document.hidden, pollFailed));
}
const updateAccount = installHostedAccount({ request, notify, update });
function update(next) {
  if (!next) return;
  // Only acknowledge accepted responses: an obsolete poll may finish after a
  // navigation action and must never replace the current state's validator.
  stateETag = stateResponseTags.get(next) || '';
  state = next;
  lastClockMinute = Math.floor(Date.now() / 60000);
  if (!draftRecovered) {
    draftRecovered = true;
    try {
      const saved = JSON.parse(
        sessionStorage.getItem(preferenceKey('scholia.study.draft')) || 'null'
      );
      if (saved?.owner && (saved.text || saved.image || saved.files?.length)) {
        $('#question').value = saved.text || '';
        imageData = saved.image || null;
        restoreChatFiles(saved.files || []);
        selectedText = saved.selection || '';
        draftOwner = saved.owner;
        draftDirty = true;
      }
    } catch {}
  }
  if (!draftDirty) draftOwner = state.draftOwner;
  $('#review-due').textContent = `Review due${state.reviewDue ? ` (${state.reviewDue})` : ''}`;
  $('#practice-this').hidden = state.showingLibrary || !course();
  $('.sidebar-review').textContent = $('#review-due').textContent;
  $('.sidebar-review').hidden = false;
  $('.sidebar-practice').hidden = state.showingLibrary || !course();
  const context = `${state.library.selectedCourseID}:${state.library.selectedAssignmentID}:${state.library.selectedDocumentID}:${state.library.selectedThreadID}`;
  if (context !== previousContext) {
    // Native navigation takes effect in this view too; unsaved browser typing is
    // sent before browser-initiated navigation by navigate().
    if (!draftDirty) {
      $('#question').value = state.draft;
      imageData = state.draftImage || null;
      restoreChatFiles(state.draftFiles || []);
    }
    if (!draftDirty) selectedText = '';
    previousContext = context;
  }
  if (!draftDirty && document.activeElement !== $('#question')) {
    $('#question').value = state.draft;
    imageData = state.draftImage || null;
    restoreChatFiles(state.draftFiles || []);
  }
  const navigation = studyRenderKey([
    state.library.courses.map((c) => [c.id, c.name, c.code, c.favorite, c.documents.length]),
    state.showingLibrary
      ? null
      : [state.materialGroups, course()?.threads.map((t) => [t.id, t.title])],
    state.library.selectedCourseID,
    state.library.selectedDocumentID,
    state.library.selectedAssignmentID,
    state.library.selectedThreadID,
    state.showingLibrary,
    state.library.courseLibraryView,
    state.busy,
  ]);
  if (navigation !== lastNavigation) {
    renderNavigation();
    lastNavigation = navigation;
  }
  examPlanner.refresh();
  $('#library').hidden = !state.showingLibrary;
  $('#workspace').hidden = state.showingLibrary;
  $('#add-document').hidden = state.showingLibrary;
  const assignment = state.showingLibrary ? null : selectedAssignment(state);
  const assignmentKey = studyRenderKey([
    assignment,
    state.assignmentText,
    state.assignmentPDFs,
    state.assignmentFiles,
    state.assignmentFileNotices,
    course()?.documents.map((document) => [
      document.sourceKey,
      document.kind,
      document.pageCount,
      document.unreadablePages,
    ]),
    state.assignmentNotice,
    state.assignmentPreparing,
    state.assignmentPreparingFileID,
    doc()?.sourceKey,
  ]);
  if (assignmentKey !== lastAssignment) {
    lastAssignment = assignmentKey;
    renderAssignment(assignment, assignmentKey).catch((error) => {
      if (lastAssignment !== assignmentKey) return;
      lastAssignment = '';
      $('#assignment-page').innerHTML =
        `<div class="reader-loading" role="status">Could not open this assignment. ${button('Try again', 'retryAssignmentView')}</div>`;
      notify(error.message);
    });
  }
  $('#assignment-page').hidden = !assignment;
  $('#assignment-page').classList.toggle('without-pdf', !!assignment && !doc());
  for (const id of ['reader-content', 'reader-toolbar', 'reader-footer'])
    $(`#${id}`).hidden = !!assignment && !doc();
  renderTutorPlacement();
  if (state.showingLibrary && pdfReader) {
    pdfReader.destroy();
    pdfReader = null;
  }
  if (state.showingLibrary && notebookReader) {
    notebookReader.destroy();
    notebookReader = null;
  }
  if (state.showingLibrary && documentEditor) {
    documentEditor.destroy();
    documentEditor = null;
  }
  const layout = state.showingLibrary ? courseLibraryRenderKey(state) : readerRenderKey(state);
  // Chat bodies aren't part of course() in the API: streaming doesn't recreate the PDF.
  if (layout !== lastLayout) {
    if (state.showingLibrary) {
      // Also invalidate pending module, image and document requests.
      readerGeneration++;
      renderLibrary();
    }
    else {
      const rendering = renderReader();
      const generation = readerGeneration;
      rendering.catch((error) => {
        if (generation !== readerGeneration) return;
        lastLayout = '';
        $('#reader-content').innerHTML =
          `<div class="reader-loading" role="status">Could not open this reading. ${button('Try again', 'retryReading')}</div>`;
        notify(error.message);
      });
    }
    lastLayout = layout;
  }
  const title = examPlanner.isOpen() ? 'Exam dates' : showingAssignments() ? 'Assignments' : state.showingLibrary
    ? 'Dashboard'
    : course()?.code || course()?.name || 'Your study space';
  const currentTitle = !examPlanner.isOpen() && (assignment?.title || (!state.showingLibrary && doc()?.title));
  $('#breadcrumb').innerHTML =
    `${button(esc(title), showingAssignments() ? 'assignments' : state.showingLibrary ? 'library' : 'materials', '', 'breadcrumb-parent')}${currentTitle ? `<span class="breadcrumb-separator" aria-hidden="true">/</span><span class="breadcrumb-current" aria-current="page" title="${esc(currentTitle)}">${esc(currentTitle)}</span>` : ''}`;
  if (!currentTitle) $('#breadcrumb .breadcrumb-parent').setAttribute('aria-current', 'page');
  const messages = studyRenderKey([
    state.messages,
    state.sources,
    state.streaming,
    state.answerStartedAt,
    state.streaming ? Math.floor(Date.now() / 1000) : null,
    state.library.selectedThreadID,
    conversationScope(state),
    state.mode,
  ]);
  if (messages !== lastMessages) {
    renderMessages();
    lastMessages = messages;
  }
  const modelMode = state.studyModelMode || 'manual';
  const activeModel = state.models.find(
    (model) => model.id === state.modelID && model.providerID === state.providerID
  );
  const models = studyRenderKey([state.models, state.providerID, state.modelID, modelMode]);
  if (models !== lastModels) {
    $('#model-picker').innerHTML = studyModelPickerMarkup(state.models, state.providerID, state.modelID);
    if (!state.models.length)
      $('#model-picker').innerHTML = '<option>Set up a model in the Mac app</option>';
    if (
      state.models.length &&
      !state.models.some((m) => m.id === state.modelID && m.providerID === state.providerID)
    )
      $('#model-picker').insertAdjacentHTML(
        'afterbegin',
        '<option selected disabled>Choose a verified model</option>'
      );
    if (activeModel && modelMode !== 'manual') {
      const summary = document.createElement('option');
      summary.value = JSON.stringify([state.providerID, state.modelID]);
      summary.textContent = `${activeModel.provider} · ${{ auto: 'Auto study', fast: 'Fast', deep: 'Deep' }[modelMode]}`;
      summary.selected = true;
      summary.disabled = true;
      $('#model-picker').prepend(summary);
    }
    lastModels = models;
  }
  $('#study-model-mode').value = modelMode;
  $('#study-model-mode').disabled = sendPending || state.streaming;
  $('#model-picker').title = modelMode === 'manual'
    ? 'Choose the model for your questions'
    : `Choose a provider and fallback model. Study mode selects an available model within that provider. Current fallback: ${activeModel?.label || state.modelID}.`;
  $('#model-picker').setAttribute('aria-label', modelMode === 'manual' ? 'Model' : 'Provider and fallback model');
  const reasoning = studyRenderKey([activeModel, state.reasoningEffort, modelMode]);
  if (reasoning !== lastReasoning) {
    const efforts = activeModel?.reasoningEfforts || [];
    $('#reasoning-control').hidden = !efforts.length || modelMode !== 'manual';
    $('#reasoning-picker').disabled = modelMode !== 'manual';
    $('#reasoning-picker').innerHTML = efforts
      .map(
        (effort) =>
          `<option value="${esc(effort)}">${esc(effort === 'xhigh' ? 'Extra high' : effort[0].toUpperCase() + effort.slice(1))}</option>`
      )
      .join('');
    $('#reasoning-picker').value =
      state.reasoningEffort || activeModel?.defaultReasoningEffort || efforts[0] || '';
    lastReasoning = reasoning;
  }
  document.querySelectorAll('[data-mode]').forEach((el) => {
    el.classList.toggle('active', el.dataset.mode === state.mode);
    el.setAttribute('aria-pressed', el.dataset.mode === state.mode);
    el.disabled = sendPending || state.streaming;
  });
  $('#mode-description').textContent =
    teachingModes.find((item) => item.mode === state.mode)?.summary || '';
  const courseScope = conversationScope(state) === 'course';
  $('#conversation-scope').textContent = courseScope
    ? 'Course conversation'
    : conversationScope(state) === 'assignment'
      ? 'Assignment conversation'
      : 'Reading conversation';
  $('#change-scope').hidden = courseScope && !doc();
  $('#change-scope').textContent = courseScope ? 'Ask about this reading' : 'Ask about this course';
  $('#change-scope').dataset.action = courseScope ? 'askReading' : 'askCourse';
  $('#question').placeholder = state.mode === 'General'
    ? 'Ask anything, or talk through an idea…' : courseScope
    ? 'Ask about this course, its topics or deadlines…'
    : 'Ask about what you’re reading…';
  $('#include-course').checked = courseScope || state.includeCourse === true;
  $('#include-course-option').hidden = courseScope;
  $('#context-description').textContent = state.entirePDF && !courseScope
    ? 'Every page’s extracted text is included with each question, in document order. Images and diagrams are included only when attached. Unreadable pages are reported.'
    : courseScope
    ? 'Your course details, material titles, and saved assignment deadlines and status are included, together with relevant passages from saved readings. Unopened materials provide titles and metadata only.'
    : 'Start with the current page and your selected text. Scholia searches the indexed text across the whole document for your question and adds relevant pages, including distant pages. Assignment conversations also include their instructions and readable project files. Inspect the sources below each answer to see which pages were actually provided.';
  $('#context-coverage').textContent = courseScope
    ? `${courseCoverage(course())} Refresh Canvas when you need the latest course information.`
    : state.includeCourse === true
      ? 'Other saved course materials may also supply relevant passages. Open cloud materials to make their contents available.'
      : selectedAssignment(state)
        ? 'Project instructions and included files are available. Enable other course materials to search beyond this project.'
        : 'Only the open document is searched. Enable other course materials to connect it with saved readings from this course.';
  $('#context-label').textContent = state.entirePDF && !courseScope
    ? `Whole document · all ${doc()?.pageCount || ''} pages of text`
    : courseScope
    ? `Course context${course()?.code ? ` · ${course().code}` : ''}`
    : selectedAssignment(state)
      ? 'Assignment instructions + included files'
      : doc()?.kind === 'notebook'
        ? `Cell ${state.page} + search all cells`
        : doc()
          ? `${['code', 'office'].includes(doc().kind) ? 'Section' : 'Page'} ${state.page} + search all pages`
          : 'Course information + saved readings';
  const latestEvidence = [...state.messages].reverse().find((message) => message.role === 'assistant' && state.sources?.[message.id]?.length);
  $('#context-summary').textContent = latestEvidence
    ? `${latestEvidence.isStreaming ? 'This answer uses' : 'Last answer used'}: ${readingSourceSummary(state.sources[latestEvidence.id])}`
    : state.context || '';
  const automaticContextEnabled = state.automaticContextEnabled !== false;
  const contextName = courseScope ? 'Course' : !doc() && selectedAssignment(state) ? 'Project' : 'Reading';
  $('#automatic-context-label').textContent = doc() && !courseScope
    ? `${contextName} context · ${doc().title || doc().fileName || 'Open document'}`
    : `${contextName} context`;
  $('#automatic-context-summary').textContent = !automaticContextEnabled
    ? 'Only your question, selected text, enabled attachments, and chat history'
    : state.entirePDF && !courseScope ? 'Whole document · all indexed text'
    : courseScope ? 'Course information + relevant passages found across saved materials'
    : doc() ? 'Current page + relevant pages found across the document'
    : 'Project instructions + relevant pages from included files';
  $('#automatic-context').checked = automaticContextEnabled;
  $('#automatic-context').disabled = state.streaming || sendPending;
  $('#include-course').disabled = !automaticContextEnabled || state.streaming || sendPending;
  if (!automaticContextEnabled) {
    $('#context-label').textContent = `${contextName} context off`;
    $('#context-description').textContent = 'The next message includes your question, selected passage, enabled attachments, and conversation history. Reading pages, course materials, and saved project memory are not added automatically.';
    $('#context-coverage').textContent = 'Check each attachment below to include it. Expand its context preview to see exactly what was read.';
    $('#context-summary').textContent = '';
  }
  $('#canvas-account').textContent = state.library.canvasUserName || 'Bring your courses along';
  updateAccount(state);
  $('#canvas-origin').value =
    document.activeElement === $('#canvas-origin')
      ? $('#canvas-origin').value
      : state.library.canvasOrigin || 'https://canvas.ntnu.no';
  $('#canvas-connection-status').textContent = state.canvasConnectionStatus || (hosted ? '' : 'Your saved login is checked first. A sign-in window opens only if Canvas needs you to sign in again.');
  $('#canvas-dialog [data-action=signIn]').disabled = state.busy || state.canvasChecking;
  $('#canvas-notices').innerHTML = [state.status, ...state.warnings]
    .filter(Boolean)
    .map((line) => `<p>${esc(line)}</p>`)
    .join('');
  const sync = state.sync || {
    active: state.busy || state.canvasChecking || state.assignmentRefreshBusy,
    messages: [state.status, state.canvasChecking ? state.canvasConnectionStatus : '',
      state.assignmentRefreshBusy ? 'Checking for assignment updates…' : ''].filter(Boolean),
    warnings: state.warnings || [], canStop: state.busy,
  };
  const syncLabel = `Sync activity — ${sync.active ? 'in progress' : sync.needsAuthentication || sync.warnings.length ? 'needs attention' : 'idle'}`;
  $('#sync-status').classList.toggle('busy', !!sync.active);
  $('#sync-status summary').setAttribute('aria-label', syncLabel);
  $('#sync-status summary').title = syncLabel;
  $('#sync-status .sync-attention').hidden = !sync.needsAuthentication && !sync.warnings.length;
  const syncMarkup = `<header><strong>Sync activity</strong><span>${sync.active ? 'In progress' : 'Idle'}</span></header>
    <div class="sync-messages" role="status">${sync.messages.length
      ? sync.messages.map((message) => `<p>${esc(message)}</p>`).join('')
      : `<p>${sync.active ? 'Syncing your coursework…' : 'No sync in progress.'}</p>`}</div>
    ${sync.warnings.length ? `<div class="sync-notices"><strong>Notices</strong>${sync.warnings.map((message) => `<p>${esc(message)}</p>`).join('')}</div>` : ''}
    <div class="sync-actions">${sync.canStop ? button('Stop', 'cancelSync') : ''}
      ${sync.canStopPreloading ? button('Stop preloading', 'stopPreloading') : ''}
      ${sync.canReconnect ? button(sync.reconnectTitle, 'reconnectSync') : ''}
      ${button('Details', 'canvas')}
      ${state.sync && !sync.active && state.status ? button('Clear status', 'clearSyncStatus') : ''}</div>`;
  if ($('#status').syncMarkup !== syncMarkup) {
    $('#status').innerHTML = syncMarkup;
    $('#status').syncMarkup = syncMarkup;
  }
  document.querySelectorAll('#canvas-dialog [data-action^=connect]').forEach((el) => {
    el.disabled = state.busy;
  });
  if (state.error && state.error !== localError) notify(state.error);
  localError = state.error || '';
  renderComposer();
}
async function renderAssignment(assignment, key) {
  const markup = assignment ? (await import('./assignment-page.js')).assignmentPageMarkup : null;
  if (key !== lastAssignment) return;
  const sameAssignment =
    $('#assignment-page').dataset.assignment === `${course()?.id}:${assignment?.id}`;
  const expanded = $('.assignment-instructions')?.open;
  $('#assignment-page').innerHTML = markup ? markup(state, { closed: closedSections }) : '';
  $('#assignment-page').dataset.assignment = `${course()?.id}:${assignment?.id}`;
  if (sameAssignment && expanded !== undefined && $('.assignment-instructions'))
    $('.assignment-instructions').open = expanded;
}
function renderNavigation() {
  const searchFocused = document.activeElement?.id === 'sidebar-material-search';
  const caret = searchFocused
    ? [document.activeElement.selectionStart, document.activeElement.selectionEnd]
    : null;
  $('#course-count').textContent = state.library.courses.length;
  $('#course-count').hidden = !state.showingLibrary;
  $('#workspace-heading').hidden = !state.showingLibrary;
  $('#workspace-heading').innerHTML =
    `${button(`${closedSections.has('workspaces') ? '›' : '⌄'} YOUR WORKSPACES`, 'collapseWorkspaces', '', 'section-toggle')}${button('+', 'create', '', '', 'Create workspace')}`;
  $('#workspace-heading .section-toggle').setAttribute(
    'aria-expanded',
    !closedSections.has('workspaces')
  );
  $('#course-nav').hidden = state.showingLibrary && closedSections.has('workspaces');
  $('.nav-all').classList.toggle('workspace-back', !state.showingLibrary);
  if (state.showingLibrary && !showingAssignments() && !examPlanner.isOpen()) $('.nav-all').setAttribute('aria-current', 'page');
  else $('.nav-all').removeAttribute('aria-current');
  const assignmentsNav = $('.sidebar [data-action=assignments]');
  if (showingAssignments() && !examPlanner.isOpen()) assignmentsNav.setAttribute('aria-current', 'page');
  else assignmentsNav.removeAttribute('aria-current');
  $('.nav-all > span:first-child').textContent = state.showingLibrary ? '▦' : '←';
  const sorted = [...state.library.courses].sort(
    (a, b) => Number(!!b.favorite) - Number(!!a.favorite) || a.name.localeCompare(b.name)
  );
  const visible = sorted.slice(0, 7);
  if (course() && !visible.some((c) => c.id === course().id)) visible.push(course());
  $('#course-nav').innerHTML = visible
    .map(
      (c) =>
        `<button class="course-nav-item ${course()?.id === c.id && !state.showingLibrary ? 'active' : ''}" data-action="course" data-id="${c.id}"><span>${c.favorite ? '★' : '▤'}</span><span><strong>${esc(c.code || c.name)}</strong><small>${esc(c.code ? courseDisplayName(c) : `${c.documents.length} documents`)}</small></span></button>`
    )
    .join('');
  if (sorted.length > 7)
    $('#course-nav').insertAdjacentHTML(
      'beforeend',
      button(`Browse all ${sorted.length} courses`, 'library', '', 'thread-nav-item')
    );
  if (!state.showingLibrary && course()) {
    $('#course-nav').innerHTML =
      `<div class="workspace-identity"><span class="eyebrow">${esc(course().code || 'YOUR WORKSPACE')}</span><h2>${esc(courseDisplayName(course()))}</h2><small>${esc(course().term || 'Your own pace')}</small>${button('Course overview', 'materials', '', 'workspace-overview')}</div>`;
    if (!doc() && !selectedAssignment(state))
      $('.workspace-overview').setAttribute('aria-current', 'page');
  }
  $('#material-nav').innerHTML =
    !state.showingLibrary && course()
      ? `<div class="section-label">${button(`${closedSections.has('materials') ? '›' : '⌄'} MATERIALS`, 'collapseMaterials', '', 'section-toggle')}${button('+', 'upload', '', '', 'Add documents')}</div>${closedSections.has('materials') ? '' : `<input id="sidebar-material-search" class="sidebar-material-search" placeholder="Find a reading…" aria-label="Find a course material" value="${esc(materialQuery)}">${materialGroupsMarkup(state.materialGroups || [], { compact: true, savedLabel: hosted ? 'Saved to your account' : 'Saved offline', courseID: course().id, selectedID: doc()?.id, selectedAssignmentID: state.library.selectedAssignmentID, query: materialQuery, closed: closedSections, busy: state.busy })}`}`
      : '';
  $('#material-nav .section-toggle')?.setAttribute(
    'aria-expanded',
    !closedSections.has('materials')
  );
  document.querySelectorAll('#material-nav .material-row.active > button').forEach((item) => {
    item.setAttribute('aria-current', 'page');
  });
  $('#thread-nav').innerHTML =
    !state.showingLibrary && course()?.threads.length
      ? `<div class="section-label">CONVERSATIONS ${button('+', 'newThread', '', '', 'New conversation')}</div>${[
          ...course().threads,
        ]
          .reverse()
          .map(
            (thread) =>
              `<button class="thread-nav-item ${thread.id === state.library.selectedThreadID ? 'active' : ''}" ${thread.id === state.library.selectedThreadID ? 'aria-current="true"' : ''} data-action="thread" data-id="${thread.id}">◌ &nbsp; ${esc(thread.title)}</button>`
          )
          .join('')}`
      : '';
  if (searchFocused && $('#sidebar-material-search')) {
    $('#sidebar-material-search').focus({ preventScroll: true });
    $('#sidebar-material-search').setSelectionRange(...caret);
  }
}
function renderLibrary(panel) {
  const previousAgendaView = $('.agenda-scroll')?.dataset.agendaView;
  const focused = [
    'course-search',
    'assignment-search',
    'workspace-filter',
    'semester-picker',
    'agenda-filter',
  ].includes(document.activeElement?.id)
    ? document.activeElement
    : null;
  const selection =
    focused?.tagName === 'INPUT' ? [focused.selectionStart, focused.selectionEnd] : null;
  const scroll = ['.workspace-scroll', '.agenda-scroll'].map((selector) => [
    selector,
    $(selector)?.scrollTop || 0,
  ]);
  const assignmentOptions = {
    refreshError: state.library.canvasAssignmentsError,
    query: agendaQuery,
    filter: showingAssignments() ? assignmentsPageFilter : agendaFilter,
    dedicated: showingAssignments(),
  };
  if (panel === 'workspaces' && $('.workspace-panel')) {
    $('.workspace-panel').outerHTML = workspacePanelMarkup(state, courseQuery);
  } else if (panel === 'assignments' && $('.assignment-agenda')) {
    $('.assignment-agenda').outerHTML = assignmentAgendaMarkup(state.library.courses, {
      ...assignmentOptions,
      semesters: state.semesters,
      busy: state.busy,
    });
  } else {
    $('#library').innerHTML = courseLibraryMarkup(state, courseQuery, assignmentOptions);
  }
  if ($('.agenda-scroll')?.dataset.agendaView !== previousAgendaView) {
    agendaNeedsTodayFocus = assignmentOptions.filter === 'due' && !agendaQuery.trim();
    const savedAgendaScroll = scroll.find(([selector]) => selector === '.agenda-scroll');
    if (savedAgendaScroll) savedAgendaScroll[1] = 0;
  }
  renderDashboardPanel();
  for (const [selector, top] of scroll) if ($(selector)) $(selector).scrollTop = top;
  if (focused && $(`#${focused.id}`)) {
    $(`#${focused.id}`).focus({ preventScroll: true });
    if (selection) $(`#${focused.id}`).setSelectionRange(...selection);
  }
}
function renderDashboardPanel() {
  const dashboard = $('.study-dashboard');
  if (!dashboard) return;
  dashboard.dataset.panel = dashboardPanel;
  dashboard.querySelectorAll('[data-action="dashboardPanel"]').forEach((control) => {
    control.setAttribute('aria-pressed', String(control.dataset.id === dashboardPanel));
  });
  if (agendaNeedsTodayFocus) requestAnimationFrame(() => scrollAgendaToToday());
}
function scrollAgendaToToday(focus = false) {
  const scroll = $('.agenda-scroll'),
    today = $('#agenda-today');
  if (!scroll?.clientHeight || !today) return;
  if (getComputedStyle(scroll).overflowY === 'visible') {
    today.scrollIntoView({ block: 'center' });
  } else {
    scroll.scrollTop +=
      today.getBoundingClientRect().top -
      scroll.getBoundingClientRect().top -
      scroll.clientHeight * 0.18;
  }
  if (focus) today.focus({ preventScroll: true });
  agendaNeedsTodayFocus = false;
}

async function renderReader() {
  const generation = ++readerGeneration;
  const item = doc(),
    c = course();
  const savedLabel = hosted ? 'Saved to your account' : 'Saved offline';
  if (!c) return;
  const edit = editDocuments.get(item?.id);
  if (documentEditor && (documentEditor.id !== item?.id || !edit)) {
    documentEditor.destroy();
    documentEditor = null;
  }
  if (
    pdfReader &&
    (pdfReader.id !== item?.id ||
      pdfReader.item.addedAt !== item?.addedAt ||
      pdfReader.item.sourceVersion !== item?.sourceVersion)
  ) {
    pdfReader.destroy();
    pdfReader = null;
  }
  if (
    notebookReader &&
    (notebookReader.id !== item?.id ||
      notebookReader.item.addedAt !== item?.addedAt ||
      notebookReader.item.sourceVersion !== item?.sourceVersion)
  ) {
    notebookReader.destroy();
    notebookReader = null;
  }
  if (!item && selectedAssignment(state)) {
    $('#reader-content').replaceChildren();
    return;
  }
  if (item && $('#reader-content').dataset.document !== item.id) {
    $('#reader-content').dataset.document = item.id;
    $('#reader-content').innerHTML = '<div class="reader-loading" role="status">Opening your reading…</div>';
  } else if (!item) delete $('#reader-content').dataset.document;
  if (edit) {
    if (pdfReader) {
      pdfReader.destroy();
      pdfReader = null;
    }
    if (notebookReader) {
      notebookReader.destroy();
      notebookReader = null;
    }
    for (const url of readerURLs) URL.revokeObjectURL(url);
    readerURLs = [];
    $('#reader-content').classList.remove('pdf-active', 'pdf-dark');
    $('#reader-toolbar').innerHTML =
      `<span class="eyebrow">EDIT ${item.kind === 'notebook' ? 'NOTEBOOK' : 'DOCUMENT'}</span><div class="tools"><small>${savedLabel}</small>${button('Cancel', 'cancelDocumentEdit')}${button(edit.busy ? 'Saving…' : 'Save changes', 'saveDocument', '', 'primary')}</div>`;
    $('#reader-footer').innerHTML =
      `<span>${edit.dirty ? 'Unsaved changes' : hosted ? 'Editing account copy' : 'Editing local copy'}</span><span>${item.kind === 'notebook' ? 'Saved outputs are not rerun · ' : ''}Save to update tutor context</span>`;
    if (!documentEditor)
      documentEditor = new StudyDocumentEditor({
        host: $('#reader-content'),
        record: edit,
        onSave: () => saveDocument().catch((e) => notify(e.message)),
        onChange: () => {
          $('#reader-footer > span').textContent = 'Unsaved changes';
        },
      });
    documentEditor.setBusy(edit.busy);
    $('#reader-toolbar [data-action=cancelDocumentEdit]').disabled = edit.busy;
    $('#reader-toolbar [data-action=saveDocument]').disabled = edit.busy;
    return;
  }
  const sections = ['code', 'notebook', 'office'].includes(item?.kind);
  $('#reader-footer').innerHTML =
    item?.kind === 'notebook'
      ? `<span>${item.pageCount} cells · ${savedLabel}</span><span>Scroll to read</span>`
      : item
        ? `<span>${item.kind === 'preview' ? `Original file · ${savedLabel}` : `${item.pageCount} ${sections ? 'sections' : 'pages'} indexed · ${savedLabel}`}</span><div><button data-action="previous" aria-label="Previous page" title="Previous page" ${state.page <= 1 ? 'disabled' : ''}>‹</button><input id="page-input" type="number" aria-label="${sections ? 'Section' : 'Page'} number" min="1" max="${item.pageCount}" value="${state.page}"> / ${item.pageCount} <button data-action="next" aria-label="Next page" title="Next page" ${state.page >= item.pageCount ? 'disabled' : ''}>›</button></div>`
        : `<span>${c.documents.length} ${hosted ? 'saved files' : 'saved offline'}</span><span>Downloaded readings inform your tutor</span>`;
  if (item?.kind === 'pdf') {
    if (pdfReader) {
      pdfReader.setPage(state.page);
      return;
    }
    const { StudyPDFReader } = await import('./pdf-reader.js');
    if (generation !== readerGeneration) return;
    pdfReader = new StudyPDFReader({
      host: $('#reader-content'),
      toolbar: $('#reader-toolbar'),
      document: item,
      course: c,
      token,
      request,
      page: state.page,
      onPage: (page) => {
        action('page', { page }).catch(() => {});
      },
      onImage: (data) => {
        imageData = data;
        selectedText = '';
        draftDirty = true;
        renderComposer();
        saveDraft().catch(() => {});
      },
      onSelection: (...args) => explainSelection(...args, item.id),
      onChat: toggleChat,
      onEntirePDF: async () => {
        if (state.streaming || sendPending) return;
        focusTutor();
        if (!$('#question').value.trim()) $('#question').value = ENTIRE_PDF_QUESTION;
        draftDirty = true;
        await action('draft', { ...draftValues(), entirePDF: true });
        await send();
      },
      onGuide: async () => {
        $('.workspace').classList.remove('chat-hidden');
        await saveDraft();
        await action('draft', { ...draftValues(), mode: 'Explain' });
        $('#question').focus();
      },
      notify,
    });
    await pdfReader.opened;
    return;
  }
  if (notebookReader) {
    notebookReader.setPage(state.page);
    return;
  }
  for (const url of readerURLs) URL.revokeObjectURL(url);
  readerURLs = [];
  $('#reader-content').classList.remove('pdf-active', 'pdf-dark');
  $('#reader-toolbar').innerHTML = item
    ? `<span class="eyebrow">${esc({ text: 'READING', image: 'IMAGE', code: 'SOURCE CODE', notebook: 'NOTEBOOK', office: 'OFFICE DOCUMENT', preview: 'ORIGINAL FILE' }[item.kind] || 'READING')}</span><div class="tools">${isHTMLDocument(item) ? button(readingViews.has(item.id) ? 'Original page' : 'Reading view', 'toggleOriginalPage') : ''}${safeDocumentURL(item.sourceURL) ? `<a href="${esc(safeDocumentURL(item.sourceURL))}" target="_blank" rel="noopener noreferrer">Open source ↗</a>` : ''}${canEditDocument(item) ? button('Edit', 'editDocument') : ''}${button('Download original', 'downloadOriginal')}${!hosted && (item.kind === 'office' || item.kind === 'preview') ? button('Original layout ↗', 'native') : ''}${button('Chat', 'toggleChat')}${button('Materials', 'materials')}</div>`
    : `<span class="eyebrow">COURSE MATERIALS</span><div class="tools">${button('＋ Add', 'upload')}</div>`;
  if (!item) {
    renderMaterials();
    return;
  }
  const notice = item.contentNotice
    ? `<p class="document-notice">${esc(item.contentNotice.replace('Use Original layout', 'Open Original layout in the Mac app'))}</p>`
    : '';
  if (isHTMLDocument(item) && !readingViews.has(item.id)) {
    const response = await fetch(`/api/document/${item.id}`, { headers: { 'X-Scholia-Token': token } });
    if (!response.ok) throw new Error('The original page is unavailable.');
    const html = await response.text();
    if (generation !== readerGeneration) return;
    const frame = document.createElement('iframe');
    frame.className = 'original-document-frame';
    frame.title = `Original page · ${item.title}`;
    frame.setAttribute('sandbox', 'allow-same-origin allow-popups allow-popups-to-escape-sandbox');
    frame.srcdoc = originalDocumentHTML(new DOMParser().parseFromString(html, 'text/html'), item.sourceURL);
    frame.addEventListener('load', () => frame.contentDocument?.addEventListener('click', followCourseLink));
    $('#reader-content').replaceChildren(frame);
    return;
  }
  if (item.kind === 'notebook') {
    const { StudyNotebookReader } = await import('./notebook-reader.js');
    if (generation !== readerGeneration) return;
    notebookReader = new StudyNotebookReader({
      host: $('#reader-content'),
      document: item,
      token,
      request,
      page: state.page,
      onPage: (page) => action('page', { page }).catch(() => {}),
      onImage: async (blob, page) => {
        await action('page', { page });
        await attach(blob);
      },
      notify,
    });
    await notebookReader.opened;
    if (generation === readerGeneration && notice)
      $('#reader-content').insertAdjacentHTML('afterbegin', notice);
    return;
  }
  if (['text', 'code', 'office'].includes(item.kind)) {
    if (state.loadingDocument) {
      $('#reader-content').innerHTML =
        '<div class="reader-loading" role="status">Opening your reading…</div>';
      return;
    }
    const { renderMarkdown } = await import('../chrome/src/render.js');
    if (generation !== readerGeneration) return;
    $('#reader-content').innerHTML =
      `${notice}<article class="paper ${item.kind === 'code' ? 'source-code' : ''}">${renderMarkdown(restoreCourseLinks(state.pageText || '*This section has no saved text.*', c, item))}<div class="embedded-images"></div></article>`;
    if (item.kind === 'office') {
      const index = await request(`/api/index/${item.id}`);
      if (generation !== readerGeneration) return;
      for (const name of index.pages.find((p) => p.number === state.page)?.images || []) {
        const response = await fetch(`/api/image/${item.id}/${encodeURIComponent(name)}`, {
          headers: { 'X-Scholia-Token': token },
        });
        if (!response.ok) continue;
        const blob = await response.blob();
        if (generation !== readerGeneration) return;
        const url = URL.createObjectURL(blob);
        readerURLs.push(url);
        const figure = window.document.createElement('figure');
        figure.innerHTML = `<img src="${url}" alt="Embedded document image">${button('Ask about this image', 'askImage', url)}`;
        $('.embedded-images').append(figure);
      }
    }
    return;
  }
  if (item.kind === 'preview') {
    $('#reader-content').innerHTML =
      `${notice}<article class="paper original-file"><span class="eyebrow">SAVED ORIGINAL</span><h2>${esc(item.title)}</h2><p>${hosted ? 'Download the original to open it in a compatible application.' : 'Open this file’s preview inside the Mac app, or download the original.'}</p>${hosted ? '' : button('Preview in Scholia ↗', 'native')}${button('Download original', 'downloadOriginal')}</article>`;
    return;
  }
  if (item.kind === 'image') {
    const blob = await (
      await fetch(`/api/document/${item.id}`, { headers: { 'X-Scholia-Token': token } })
    ).blob();
    if (generation !== readerGeneration) return;
    const url = URL.createObjectURL(blob);
    readerURLs.push(url);
    $('#reader-content').innerHTML =
      `<img class="document-image" alt="${esc(item.title)}" src="${url}">`;
  }
}
async function explainSelection(text, page, explain, question = '', documentID = doc()?.id) {
  if (explain && (state.assignmentPreparing ?? (selectedAssignment(state) && state.busy))) {
    notify('Preparing the assignment files. Try explaining this passage once they are ready.');
    return false;
  }
  if (explain && state.streaming) {
    notify('Wait for the current answer to finish, then ask your follow-up.');
    return false;
  }
  const saved = $('#question').value,
    savedImage = imageData,
    savedFiles = chatFiles.files;
  if (draftDirty) await saveDraft();
  if (doc()?.id !== documentID) throw new Error('The document changed. Select the passage again.');
  await action('page', { page });
  if (doc()?.id !== documentID) throw new Error('The document changed. Select the passage again.');
  selectedText = text;
  $('.workspace').classList.remove('chat-hidden');
  if (explain) {
    await action('send', {
      text: question.trim(),
      selection: text,
      mode: 'Explain',
      clearImage: true,
      files: [],
    });
    $('#question').value = saved;
    imageData = savedImage;
    restoreChatFiles(savedFiles);
    selectedText = '';
    draftDirty = !!saved || !!savedImage || !!savedFiles.length;
    if (draftDirty) await saveDraft();
  }
  if (!explain) {
    if (question.trim()) $('#question').value = [$('#question').value, question.trim()].filter(Boolean).join('\n\n');
    draftDirty = true;
    await saveDraft();
  }
  renderComposer();
  if (!explain) focusTutor();
  return true;
}
async function beginDocumentEdit() {
  const item = doc();
  if (!canEditDocument(item) || editDocuments.has(item.id)) return;
  const draft = await request(`/api/edit/${item.id}`);
  if (!editDocuments.has(item.id)) editDocuments.set(item.id, { draft, dirty: false, busy: false });
  if (doc()?.id === item.id && !state.showingLibrary) await renderReader();
}
async function saveDocument() {
  const id = doc()?.id,
    edit = editDocuments.get(id);
  if (!edit || edit.busy) return;
  edit.busy = true;
  await renderReader();
  try {
    await action('saveDocument', { edit: edit.draft });
    editDocuments.delete(id);
    notify('Changes saved locally. Your tutor now has the updated document.');
  } finally {
    edit.busy = false;
    if (doc()?.id === id && !state.showingLibrary) await renderReader();
  }
}
function toggleChat() {
  $('.workspace').classList.toggle('chat-hidden');
}
function isCourseOverview() {
  return !state?.showingLibrary && !!course() && !doc() && !selectedAssignment(state);
}
function parkTutor() {
  if (tutorPanel.parentElement !== $('#workspace')) $('#workspace').append(tutorPanel);
}
function renderTutorPlacement() {
  const inline = isCourseOverview();
  $('#workspace').classList.toggle('course-overview', inline);
  const slot = inline ? $('#course-chat-slot') : null;
  const expanded = courseChatStates.get(course()?.id);
  if (slot) {
    if (tutorPanel.parentElement !== slot) slot.append(tutorPanel);
    slot.hidden = expanded === undefined;
  } else parkTutor();
  tutorPanel.classList.toggle('course-chat-collapsed', inline && expanded === false);
  $('#course-chat-toggle').hidden = !inline;
  $('#course-chat-toggle').textContent = expanded === false ? 'Expand' : 'Collapse';
  $('#course-chat-toggle').setAttribute('aria-expanded', String(expanded === true));
  $('.tutor-title strong').textContent = state?.mode === 'General' ? 'Chat' : inline ? 'Course conversation' : 'A little understanding';
  const opener = $('#ask-course-button');
  if (opener) opener.setAttribute('aria-expanded', String(expanded === true));
}
function expandCourseChat() {
  if (!isCourseOverview()) return;
  const firstOpen = !courseChatStates.has(course().id);
  courseChatStates.set(course().id, true);
  renderTutorPlacement();
  if (firstOpen) $('#messages').scrollTop = $('#messages').scrollHeight;
  updateLatestAnswer();
  renderComposer();
}
async function downloadOriginal() {
  const item = doc();
  if (!item) return;
  const filename = documentDownloadFilename(item, course());
  const response = await fetch(`/api/document/${item.id}`, {
    headers: { 'X-Scholia-Token': token },
  });
  if (!response.ok) throw new Error('The original file is unavailable.');
  const url = URL.createObjectURL(await response.blob());
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}
function renderMaterials() {
  const c = course();
  if (!c) return;
  const search = document.activeElement?.id === 'material-search' ? document.activeElement : null;
  const caret = search ? [search.selectionStart, search.selectionEnd] : null;
  const hasAssignments = c.canvasMaterials?.some((material) => material.kind === 'assignments');
  // Preserve the live composer and message nodes when filters rebuild the materials list.
  const focusedTutorControl = tutorPanel.contains(document.activeElement) ? document.activeElement : null;
  const messageScroll = $('#messages').scrollTop;
  parkTutor();
  $('#reader-content').innerHTML =
    `<div class="course-materials"><span class="eyebrow">${esc(c.code || 'YOUR WORKSPACE')}</span><h2>${esc(courseDisplayName(c))}</h2><p>${c.canvasID ? (hosted ? 'Open a reading to save it to your account and discuss it with your tutor.' : 'Open a reading to save it offline and discuss it with your tutor.') : 'Add readings, notebooks, or code, then explore them with your tutor.'}</p>
    <div class="course-tools"><button id="ask-course-button" data-action="askCourse" class="primary" aria-controls="course-chat-slot" aria-expanded="false">Ask about this course</button>${button('Practice course', 'practiceCourse', c.id)}${c.canvasID ? `${button(c.catalogUpdatedAt ? 'Check for changes' : 'Index materials', 'index', c.id)}${button('Download all', 'downloadAll', c.id)}<a href="${courseURL(c)}" target="_blank" rel="noreferrer">Open Canvas ↗</a>` : button('＋ Add documents', 'upload', '', 'primary')}</div>
    <div id="course-chat-slot" class="course-chat-slot" hidden></div>
    ${catalogChangeSummary(c.catalogChanges) ? `<p class="material-changes">Latest check: ${esc(catalogChangeSummary(c.catalogChanges))}</p>` : ''}
    <div class="materials-toolbar"><input class="material-search" id="material-search" placeholder="Search materials…" aria-label="Search materials" value="${esc(materialQuery)}">${materialViewPicker(materialViews[c.id])}</div>
    ${c.canvasID && hasAssignments && materialViews[c.id] !== 'files' ? assignmentsMarkup([c], { query: materialQuery, includeCompleted: includeCompletedAssignments, showCourse: false, busy: state.busy }) : ''}
    ${!materialQuery && materialViews[c.id] !== 'files' ? continueReadingMarkup(recentReadings([c], 1)) : ''}${materialsViewMarkup(state.materialGroups || [], state.materialFiles || [], { savedLabel: hosted ? 'Saved to your account' : 'Saved offline', view: materialViews[c.id], picker: false, courseID: c.id, query: materialQuery, closed: closedSections, busy: state.busy })}</div>`;
  renderTutorPlacement();
  $('#messages').scrollTop = messageScroll;
  if (focusedTutorControl?.isConnected) focusedTutorControl.focus({ preventScroll: true });
  if (search) {
    $('#material-search').focus({ preventScroll: true });
    $('#material-search').setSelectionRange(...caret);
  }
}
function renderMessages() {
  conversation.render(state);
  updateLatestAnswer();
}
function updateLatestAnswer() {
  const box = $('#messages');
  $('#latest-answer').hidden =
    !state?.messages.length || box.scrollHeight - box.scrollTop - box.clientHeight < 100;
}
function renderComposer() {
  $('#response-language').value = state.language || 'auto';
  $('#response-language').disabled = !course() || sendPending;
  $('#entire-pdf-control').hidden = !doc() || ['image', 'preview'].includes(doc().kind) || conversationScope(state) === 'course';
  $('#entire-pdf').checked = state.entirePDF === true;
  $('#entire-pdf').disabled = state.streaming || sendPending || state.automaticContextEnabled === false;
  const question = $('#question'),
    width = question.clientWidth;
  if (width && (question.value !== lastComposerText || width !== lastComposerWidth)) {
    question.style.height = 'auto';
    question.style.height = `${Math.max(65, Math.min(180, question.scrollHeight))}px`;
    lastComposerText = question.value;
    lastComposerWidth = width;
  }
  $('#edit-notice').hidden = !state.editing;
  $('#send').textContent = state.streaming ? '■' : '↑';
  $('#send').setAttribute('aria-label', state.streaming ? 'Stop answer' : 'Send question');
  $('#send').disabled =
    sendPending ||
    (!state.streaming &&
      (state.loadingDocument ||
        (state.assignmentPreparing ?? (selectedAssignment(state) && state.busy)) ||
        !course() ||
        chatFiles?.busy ||
        (!$('#question').value.trim() && !imageData && !selectedText.trim() && !chatFiles?.options.files.length)));
  $('#question-image').hidden = !imageData;
  $('#question-image').innerHTML = imageData
    ? `<img alt="Attached question image" src="data:image/jpeg;base64,${imageData}"><span>Image attached</span>${button('×', 'removeImage')}`
    : '';
  const conflict =
    draftDirty && draftOwner && studyRenderKey(draftOwner) !== studyRenderKey(state.draftOwner);
  $('#draft-conflict').hidden = !conflict;
  $('#selection-note').hidden = !selectedText;
  $('#selection-note').innerHTML = selectedText
    ? `<span><strong>Selected passage</strong><q>${esc(selectedText.slice(0, 180))}${selectedText.length > 180 ? '…' : ''}</q></span><button data-action="clearSelection" aria-label="Remove selected passage" title="Remove selected passage">×</button>`
    : '';
}
async function prepareStudyPrompt(mode) {
  if (!course() || sendPending || state.streaming) return;
  if (mode === 'Practice') {
    await saveDraft('Practice');
    await openPractice('setup');
    return;
  }
  $('#question').value = appendStudyPrompt(
    $('#question').value,
    studyPrompt(mode, conversationScope(state) === 'course' ? null : doc())
  );
  draftDirty = true;
  $('.workspace').classList.remove('chat-hidden');
  $('#question').focus();
  renderComposer();
  await saveDraft(mode);
}
function draftValues() {
  return {
    text: $('#question').value,
    mode: state.mode,
    entirePDF: state.entirePDF === true,
    automaticContextEnabled: state.automaticContextEnabled !== false,
    selection: selectedText,
    files: chatFiles?.files || [],
    ...(imageData ? { image: imageData } : { clearImage: true }),
  };
}
async function saveDraft(mode = state?.mode) {
  clearTimeout(draftTimer);
  if (!state || !course() || sendPending) return;
  const values = { ...draftValues(), mode };
  persistBrowserDraft();
  await action('draft', values);
  const current = draftValues();
  if (
    current.text === values.text &&
    current.image === values.image &&
    current.selection === values.selection &&
    JSON.stringify(current.files) === JSON.stringify(values.files)
  ) {
    draftDirty = false;
    restoreChatFiles(state.draftFiles || []);
  }
  persistBrowserDraft();
  renderComposer();
}
async function navigate(name, values = {}) {
  examPlanner.close();
  if (draftDirty) {
    if (studyRenderKey(draftOwner) === studyRenderKey(state.draftOwner)) await saveDraft();
    else persistBrowserDraft();
  }
  if (!draftDirty) selectedText = '';
  materialQuery = '';
  await action(name, values);
  if (['thread', 'newThread'].includes(name)) expandCourseChat();
  setSidebarOpen(false);
}
function focusTutor() {
  expandCourseChat();
  $('.workspace').classList.remove('chat-hidden');
  $('#question').focus({ preventScroll: true });
  if (window.matchMedia('(max-width: 640px)').matches)
    $('.tutor').scrollIntoView({ block: 'start', behavior: 'smooth' });
}
async function askCourse(promptID) {
  if (!course() || sendPending) return;
  if (!isCourseOverview() || conversationScope(state) !== 'course') await navigate('askCourse');
  const prompt = coursePrompts.find((prompt) => prompt.id === promptID);
  if (prompt && !state.streaming) {
    $('#question').value = appendStudyPrompt($('#question').value, prompt.question);
    draftDirty = true;
    await saveDraft();
  }
  focusTutor();
  renderComposer();
}
async function send() {
  if (sendPending) return;
  if (!state.streaming && (state.assignmentPreparing ?? (selectedAssignment(state) && state.busy))) {
    notify('Preparing the assignment files. Your question is kept here.');
    return;
  }
  if (state.streaming) return action('stop');
  if (state.loadingDocument) {
    notify('Your reading is opening. Your question is saved here.');
    return;
  }
  if (chatFiles?.busy) return;
  if (!$('#question').value.trim() && !imageData && !selectedText.trim() && !chatFiles?.options.files.length) return;
  clearTimeout(draftTimer);
  const values = draftValues();
  const sentImage = imageData,
    previousMessageIDs = new Set(state.messages.map((message) => message.id));
  sendPending = true;
  draftDirty = true;
  renderComposer();
  try {
    await action('send', { ...values, files: chatFiles.options.files });
    if (
      state.messages.some(
        (message) => message.role === 'user' && !previousMessageIDs.has(message.id)
      )
    ) {
      if ($('#question').value === values.text) $('#question').value = '';
      if (imageData === sentImage) imageData = null;
      if (JSON.stringify(chatFiles.files) === JSON.stringify(values.files)) restoreChatFiles([]);
      draftDirty = !!$('#question').value || !!imageData || !!chatFiles.files.length;
      selectedText = '';
    }
  } finally {
    sendPending = false;
    persistBrowserDraft();
    renderComposer();
    if (draftDirty) {
      clearTimeout(draftTimer);
      draftTimer = setTimeout(() => saveDraft().catch(() => {}), 600);
    }
  }
}
async function attach(file) {
  if (!file?.type.startsWith('image/')) return;
  if (file.size > 25_000_000) throw new Error('Choose an image smaller than 25 MB.');
  const bitmap = await createImageBitmap(file),
    scale = Math.min(1, 1800 / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.ceil(bitmap.width * scale);
  canvas.height = Math.ceil(bitmap.height * scale);
  canvas.getContext('2d').drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  imageData = canvas.toDataURL('image/jpeg', 0.87).split(',')[1];
  draftDirty = true;
  renderComposer();
  await saveDraft();
}
async function importFiles(files) {
  if (!course()) {
    notify('Open or create a course before adding documents.');
    return;
  }
  for (const file of files) {
    if (file.size > 100_000_000) {
      notify(`${file.name} exceeds 100 MB.`);
      continue;
    }
    const data = await new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(String(reader.result).split(',')[1]);
      reader.onerror = reject;
      reader.readAsDataURL(file);
    });
    await action('import', { name: file.name, data });
    while (state.busy) {
      await new Promise((resolve) => setTimeout(resolve, 250));
      await poll();
    }
  }
}

document.addEventListener('click', async (event) => {
  if (!$('#sync-status').contains(event.target)) $('#sync-status').open = false;
  const target = event.target.closest(
    '[data-action],[data-study-prompt],[data-course-prompt],[data-mode],[data-source]'
  );
  if (!target) return;
  event.preventDefault();
  try {
    if (target.dataset.coursePrompt) {
      await askCourse(target.dataset.coursePrompt);
      return;
    }
    if (target.dataset.studyPrompt) {
      await prepareStudyPrompt(target.dataset.studyPrompt);
      return;
    }
    if (target.dataset.mode === 'Practice') {
      await prepareStudyPrompt('Practice');
      return;
    }
    if (target.dataset.mode) {
      await saveDraft();
      await action('draft', { ...draftValues(), mode: target.dataset.mode });
      return;
    }
    if (target.dataset.source) {
      await navigate('source', { id: target.dataset.source, page: Number(target.dataset.page) });
      return;
    }
    const name = target.dataset.action,
      id = target.dataset.id;
    if (
      $('#course-navigation').contains(target) &&
      !['collapseWorkspaces', 'collapseMaterials'].includes(name)
    )
      setSidebarOpen(false);
    if (
      ['library', 'assignments', 'course', 'document', 'thread', 'materials', 'newThread', 'resume'].includes(name)
    ) {
      await navigate(name, { id });
      return;
    }
    switch (name) {
      case 'retryReading':
        pdfReader?.destroy();
        pdfReader = null;
        notebookReader?.destroy();
        notebookReader = null;
        lastLayout = '';
        update(state);
        break;
      case 'retryAssignmentView':
        lastAssignment = '';
        update(state);
        break;
      case 'askCourse':
        await askCourse();
        break;
      case 'toggleCourseChat':
        if (isCourseOverview()) {
          const expanded = courseChatStates.get(course().id) !== true;
          courseChatStates.set(course().id, expanded);
          renderTutorPlacement();
          if (expanded) focusTutor();
        }
        break;
      case 'askReading':
        if (doc()) await navigate('document', { id: doc().id });
        focusTutor();
        break;
      case 'dashboardPanel':
        dashboardPanel = id === 'assignments' ? 'assignments' : 'workspaces';
        renderDashboardPanel();
        break;
      case 'agendaToday':
        scrollAgendaToToday(true);
        break;
      case 'exams':
        examPlanner.open();
        setSidebarOpen(false);
        break;
      case 'search':
        workspaceSearch.open();
        break;
      case 'switchWorkspace':
        workspaceShortcuts.open();
        break;
      case 'keyboardShortcuts':
        workspaceShortcuts.openHelp();
        break;
      case 'practiceThis':
        await saveDraft();
        await openPractice('setup');
        break;
      case 'practiceCourse':
        if (id && id !== course()?.id) await navigate('course', { id });
        await saveDraft();
        await openPractice('course');
        break;
      case 'reviewDue':
        await openPractice('review');
        break;
      case 'copyDraft':
        await navigator.clipboard.writeText($('#question').value);
        notify('Recovered draft copied.');
        break;
      case 'loadCurrentDraft':
        clearTimeout(draftTimer);
        draftDirty = false;
        draftOwner = state.draftOwner;
        $('#question').value = state.draft;
        imageData = state.draftImage || null;
        restoreChatFiles(state.draftFiles || []);
        selectedText = '';
        persistBrowserDraft();
        renderComposer();
        break;
      case 'collapseWorkspaces':
      case 'collapseMaterials': {
        const key = name === 'collapseWorkspaces' ? 'workspaces' : 'materials';
        if (closedSections.has(key)) closedSections.delete(key);
        else closedSections.add(key);
        persistSections();
        renderNavigation();
        break;
      }
      case 'create':
        $('#create-dialog').showModal();
        $('#create-form input').focus();
        break;
      case 'closeCreate':
        $('#create-dialog').close();
        break;
      case 'canvas':
        $('#sync-status').open = false;
        $('#canvas-dialog').showModal();
        break;
      case 'sidebar':
        setSidebarOpen(!$('.app').classList.contains('sidebar-open'));
        break;
      case 'closeSidebar':
        setSidebarOpen(false);
        break;
      case 'all':
      case 'favorites':
      case 'semesters':
        await action('libraryView', { id: name });
        break;
      case 'materialView':
        selectMaterialView(id);
        break;
      case 'agendaHandedIn':
        if (showingAssignments()) assignmentsPageFilter = 'handedIn';
        else agendaFilter = 'handedIn';
        renderLibrary('assignments');
        break;
      case 'assignmentFilter':
        includeCompletedAssignments = id === 'all';
        if (state.showingLibrary) renderLibrary();
        else renderMaterials();
        break;
      case 'assignmentVisibility':
        await action(name, {
          id,
          courseID: target.dataset.courseId,
          enabled: target.dataset.hidden === 'true',
        });
        break;
      case 'assignment':
        await navigate(name, { id, courseID: target.dataset.courseId });
        break;
      case 'assignmentPDF':
      case 'assignmentFile':
        if (!state.busy)
          await navigate(name, {
            id,
            courseID: target.dataset.courseId,
            assignmentID: target.dataset.assignmentId,
          });
        break;
      case 'semester':
        await action('semester', { id });
        $('#library').scrollTop = 0;
        break;
      case 'upload':
        $('#document-upload').click();
        break;
      case 'attach':
        $('#image-upload').click();
        break;
      case 'removeImage':
        imageData = null;
        draftDirty = true;
        await saveDraft();
        renderComposer();
        break;
      case 'clearSelection':
        selectedText = '';
        window.getSelection()?.removeAllRanges();
        draftDirty = true;
        renderComposer();
        await saveDraft();
        break;
      case 'copy':
        await navigator.clipboard.writeText(state.messages.find((m) => m.id === id)?.content || '');
        notify('Copied.');
        break;
      case 'cancelEdit':
        await action('cancelEdit');
        draftDirty = false;
        $('#question').value = '';
        imageData = null;
        restoreChatFiles(state.draftFiles || []);
        renderComposer();
        break;
      case 'edit':
        await action('edit', { id });
        draftDirty = false;
        $('#question').value = state.draft;
        imageData = state.draftImage || null;
        restoreChatFiles(state.draftFiles || []);
        $('#question').focus();
        renderComposer();
        break;
      case 'connect':
      case 'connectToken':
        await action('connect', {
          origin: $('#canvas-origin').value,
          enabled: $('input[name=sync-mode]:checked').value === 'all',
          ...(name === 'connectToken' ? { token: $('#canvas-token').value } : {}),
        });
        $('#canvas-token').value = '';
        break;
      case 'signIn':
        $('#canvas-dialog [data-action=signIn]').disabled = true;
        $('#canvas-connection-status').textContent = 'Checking saved connection…';
        await action('signIn', { origin: $('#canvas-origin').value });
        break;
      case 'previous':
        if (pdfReader) pdfReader.navigate(-1);
        else await action('page', { page: state.page - 1 });
        break;
      case 'next':
        if (pdfReader) pdfReader.navigate(1);
        else await action('page', { page: state.page + 1 });
        break;
      case 'toggleChat':
        toggleChat();
        break;
      case 'latestAnswer':
        $('#messages').scrollTop = $('#messages').scrollHeight;
        break;
      case 'downloadOriginal':
        await downloadOriginal();
        break;
      case 'toggleOriginalPage':
        if (readingViews.has(doc().id)) readingViews.delete(doc().id);
        else readingViews.add(doc().id);
        await renderReader();
        break;
      case 'editDocument':
        await beginDocumentEdit();
        break;
      case 'saveDocument':
        await saveDocument();
        break;
      case 'cancelDocumentEdit':
        if (!editDocuments.get(doc()?.id)?.busy) {
          editDocuments.delete(doc()?.id);
          await renderReader();
        }
        break;
      case 'askImage':
        await attach(await (await fetch(id)).blob());
        break;
      case 'material':
        if (state.busy) notify('Wait for the current download, or stop it first.');
        else await navigate(name, { id });
        break;
      default:
        await action(name, id ? { id } : {});
    }
  } catch (error) {
    notify(error.message);
  }
});
$('#create-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const form = new FormData(event.target);
  try {
    await navigate('create', { name: form.get('name'), code: form.get('code') });
    $('#create-dialog').close();
    event.target.reset();
  } catch {}
});
$('#composer').addEventListener('submit', (event) => {
  event.preventDefault();
  send().catch(() => {});
});
$('#question').addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    send().catch(() => {});
  }
});
$('#messages').addEventListener('scroll', updateLatestAnswer, { passive: true });
$('#question').addEventListener('input', () => {
  draftDirty = true;
  persistBrowserDraft();
  renderComposer();
  clearTimeout(draftTimer);
  draftTimer = setTimeout(() => saveDraft().catch(() => {}), 600);
});
let chatFiles, restoringChatFiles = false;
function restoreChatFiles(files) {
  if (!chatFiles || JSON.stringify(chatFiles.files) === JSON.stringify(files)) return;
  restoringChatFiles = true;
  try { chatFiles.set(files); } finally { restoringChatFiles = false; }
}
chatFiles = mountFileComposer({
  button: $('#attach-chat-files'), container: $('#question-files'),
  dropTarget: document.body, pasteTarget: $('#question'),
  normalizeFiles: (files) => hosted ? normalizeFileAttachments(files) : files,
  disabled: () => !state || !course() || state.streaming || sendPending,
  readFile: async (file, options) => {
    if (file.type === 'application/pdf' || /\.pdf$/i.test(file.name)) {
      const { extractChatPDF } = await import('./chat-pdf.js');
      return readChatFile(file, { ...options, pdfReader: extractChatPDF });
    }
    const attachment = await readChatFile(file, options);
    if (attachment.imageDataUrl && imageData) {
      delete attachment.imageDataUrl;
      attachment.text = '';
      attachment.status = 'unavailable';
      attachment.notice = 'Attached, but this message already contains an image. Send this image in another message for visual inspection.';
    }
    return attachment;
  },
  onChange: () => {
    if (!chatFiles || restoringChatFiles || !state) return;
    const image = chatFiles.options.imageDataUrl;
    if (image) {
      imageData = image.split(',')[1];
      restoreChatFiles(chatFiles.files.filter((file) => !file.imageDataUrl));
    }
    draftDirty = true;
    focusTutor();
    renderComposer();
    persistBrowserDraft();
    clearTimeout(draftTimer);
    if (!chatFiles.busy) draftTimer = setTimeout(() => saveDraft().catch(() => {}), 600);
  }
});
$('#model-picker').addEventListener('change', (event) => {
  try {
    const [providerID, id] = JSON.parse(event.target.value);
    action('model', { providerID, id }).catch(() => {});
  } catch {}
});
$('#response-language').addEventListener('change', async (event) => {
  try {
    await action('language', { text: event.target.value });
  } catch (error) {
    renderComposer();
    notify(error.message);
  }
});
$('#entire-pdf').addEventListener('change', async (event) => {
  try {
    await action('draft', { ...draftValues(), entirePDF: event.target.checked });
  } catch (error) {
    renderComposer();
    notify(error.message);
  }
});
$('#study-model-mode').addEventListener('change', async (event) => {
  try {
    await action('studyModelMode', { text: event.target.value });
  } catch (error) {
    update(state);
    notify(error.message);
  }
});
$('#include-course').addEventListener('change', (event) =>
  action('context', { enabled: event.target.checked }).catch(() => {})
);
$('#automatic-context').addEventListener('change', (event) =>
  action('automaticContext', { enabled: event.target.checked }).catch(() => {})
);
installWorkspaceMemory({ getState: () => state, action });
$('#reasoning-picker').addEventListener('change', async (event) => {
  try {
    await action('reasoning', {
      text: event.target.value,
      id: state.modelID,
      providerID: state.providerID,
    });
  } catch (error) {
    lastReasoning = '';
    update(state);
    notify(error.message);
  }
});
$('#document-upload').addEventListener('change', (event) => {
  importFiles([...event.target.files]).catch((e) => notify(e.message));
  event.target.value = '';
});
$('#image-upload').addEventListener('change', (event) => {
  attach(event.target.files[0]).catch((e) => notify(e.message));
  event.target.value = '';
});
function followCourseLink(event) {
  const anchor = event.target.closest?.('a[href]');
  if (!anchor || event.button || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  const target = courseLinkTarget(anchor.href, course());
  if (!target) return;
  event.preventDefault();
  event.stopPropagation();
  const name = target.id.startsWith('assignments:') ? 'assignment' : target.document ? 'document' : 'material';
  navigate(name, { id: name === 'document' ? target.document.id : target.id, courseID: course().id })
    .catch((error) => notify(error.message));
}
$('#reader-content').addEventListener('click', followCourseLink);
$('#reader-content').addEventListener('mouseup', () => {
  const selection = window.getSelection();
  if (selection?.anchorNode && tutorPanel.contains(selection.anchorNode)) return;
  if (selection?.anchorNode && $('#reader-content').contains(selection.anchorNode)) {
    selectedText = selection.toString().slice(0, 16000);
    renderComposer();
  }
});
document.addEventListener('input', (event) => {
  if (event.target.id === 'assignment-search') {
    agendaQuery = event.target.value;
    renderLibrary('assignments');
  }
  if (event.target.id === 'course-search') {
    const position = event.target.selectionStart;
    courseQuery = event.target.value;
    renderLibrary('workspaces');
    $('#course-search').focus();
    $('#course-search').setSelectionRange(position, position);
  }
  if (['material-search', 'sidebar-material-search'].includes(event.target.id)) {
    const id = event.target.id,
      position = event.target.selectionStart;
    materialQuery = event.target.value;
    if (!doc()) renderMaterials();
    renderNavigation();
    $(`#${id}`).focus({ preventScroll: true });
    $(`#${id}`).setSelectionRange(position, position);
  }
});
document.addEventListener('change', (event) => {
  if (event.target.id === 'workspace-filter')
    action('libraryView', { id: event.target.value }).catch(() => {});
  if (event.target.id === 'agenda-filter') {
    if (showingAssignments()) assignmentsPageFilter = event.target.value;
    else agendaFilter = event.target.value;
    renderLibrary('assignments');
  }
  if (event.target.id === 'semester-picker')
    action('semester', { id: event.target.value }).catch(() => {});
  if (event.target.id === 'page-input')
    action('page', { page: Number(event.target.value) || 1 }).catch(() => {});
  if (event.target.name === 'sync-mode')
    $('#canvas-dialog [data-action=connect]').textContent =
      event.target.value === 'all' ? 'Download everything' : 'Index all courses';
});
document.addEventListener(
  'toggle',
  (event) => {
    const key = event.target.dataset?.collapseKey;
    if (
      !key ||
      !event.target.isConnected ||
      (materialQuery && event.target.classList.contains('material-group'))
    )
      return;
    if (event.target.open) {
      closedSections.delete(key);
      closedSections.add(`open:${key}`);
    } else {
      closedSections.add(key);
      closedSections.delete(`open:${key}`);
    }
    persistSections();
  },
  true
);
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) poll();
});
window.addEventListener('beforeunload', (event) => {
  if (
    draftDirty ||
    examPlanner.dirty() ||
    [...editDocuments.values()].some((edit) => edit.dirty || edit.busy)
  ) {
    event.preventDefault();
    event.returnValue = '';
  }
});
await poll();
if (location.hash === '#exams') examPlanner.open();
window.addEventListener('hashchange', () => {
  if (location.hash === '#exams') examPlanner.open();
});
