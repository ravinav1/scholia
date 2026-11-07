import { teachingModeLabel } from '../../packages/core/src/tutoring.js';
import { normalizeFileAttachments } from '../../packages/core/src/file-attachments.js';
import { AttachmentCorpus } from './attachment-corpus.js';
import { entirePdfContext } from '../../packages/core/src/entire-pdf.js';
import { workspaceMemory, saveWorkspaceMemory, buildWorkspaceMemory } from './workspace-memory.js';
import { randomUUID } from 'node:crypto';
import { normalizeRecentModels, recordRecentModel } from '../../packages/core/src/recent-models.js';
import { needsCanvasHTMLUpgrade } from '../../packages/core/src/course-documents.js';
import { HostedLearning } from './learning.js';
import { normalizeExamPlan, examFavoriteCourseIDs } from '../../packages/core/src/exam-planner.js';
import { EXAM_RECOMMENDATION_INSTRUCTIONS, EXAM_ADVICE_INSTRUCTIONS, EXAM_ADVICE_CONVERSATION_INSTRUCTIONS, examRecommendationMode, examRecommendationInput, checkedExamRecommendation, checkedExamAdvice } from '../../packages/core/src/exam-recommendations.js';
import { ntnuStudyPlans, STUDY_PLAN_INSTRUCTIONS } from '../../packages/core/src/study-plans.js';
import { degreeCatalogue, retrieveDegreeInformation, STUDY_PLAN_RETRIEVAL_INSTRUCTIONS } from '../../packages/core/src/study-plan-retrieval.js';
import { PROVIDERS, modelReasoning } from '../../packages/core/src/providers.js';
import { STUDY_MODEL_MODES, normalizeStudyModelMode, routeStudyModel, studyRouteDescription } from '../../packages/core/src/study-model-routing.js';
import { runCompletion } from '../chrome/src/provider-runtime.js';
import { Canvas } from './courses/canvas.js';
import { MathWiki, mathWikiCourse, isMathWikiMaterial } from './courses/math-wiki.js';
import { beginPoll, observeCatalog, observePoll, pollDecision } from './courses/content-polling.js';
import { WorkspaceSearch } from './search/workspace-search.js';
import { buildCourseContext, courseContextScope, courseContextSummary } from './courses/course-context.js';
import { hash } from './store.js';
import { needsTextIndexUpgrade, unreadablePageCount } from './documents/document-formats.js';
import {
  analyzeMaterial,
  materialAnalysisVersion,
  materialCategories,
  materialClassification,
} from './documents/material-analysis.js';
export const hostedProviders = PROVIDERS.filter((p) =>
  ['openai', 'anthropic', 'openrouter', 'groq', 'together', 'mistral', 'cohere', 'ntnu'].includes(
    p.id
  )
);
const fail = (message, status = 400) => {
  throw Object.assign(new Error(message), { status });
};
const now = () => Date.now() / 1000;
// New actions remain durable unless explicitly classified as session-only.
const sessionOnlyActions = new Set(['library', 'assignments', 'libraryView', 'semester',
  'course', 'askCourse', 'materials', 'thread', 'automaticContext', 'context', 'cancelEdit',
  'clearError', 'stop', 'cancelSync', 'refreshAssignments']);
const reasoningEffort = (provider, model, settings) => {
  const reasoning = modelReasoning(provider, model);
  if (!reasoning?.efforts.length) return null;
  const selected = settings.reasoningEfforts?.[provider.id];
  return reasoning.efforts.includes(selected)
    ? selected
    : reasoning.default || reasoning.efforts[0];
};
const sortNames = (a, b) => a.title.localeCompare(b.title, undefined, { numeric: true });
const sortCanvasLinks = (a, b) => {
  const left = a.linkedOrder || [], right = b.linkedOrder || [];
  for (let i = 0; i < Math.min(left.length, right.length); i++)
    if (left[i] !== right[i]) return left[i] - right[i];
  return left.length - right.length;
};
const newCourse = (name, code = '') => ({
  id: randomUUID(),
  name,
  code,
  documents: [],
  threads: [],
  canvasMaterials: [],
});
export function assignmentFileReferences(course, assignment) {
  if (!assignment) return [];
  const known = new Map(
    (course.canvasMaterials || [])
      .filter((ref) => ref.kind === 'files')
      .map((ref) => [String(ref.remoteID), ref])
  );
  return [...new Set(assignment.assignment?.linkedFileIDs || [])]
    .filter((id) => /^\d+$/.test(id))
    .map((id) => {
      if (known.has(String(id))) return known.get(String(id));
      const saved = course.documents.find((document) => document.sourceKey === `files:${id}`);
      return {
        id: `files:${id}`,
        kind: 'files',
        remoteID: String(id),
        title: saved?.title || `File ${id}`,
        fileName: saved?.originalFileName || saved?.fileName,
        version: saved?.sourceVersion || '',
        sourceURL: `${course.canvasOrigin}/courses/${course.canvasID}/files/${id}`,
      };
    });
}
export function materialInventory(course) {
  if (!course) return { groups: [], files: [] };
  const groups = new Map(),
    files = [],
    references = new Set(),
    savedBySource = new Map(course.documents.map((doc) => [doc.sourceKey, doc]));
  const add = (ref, doc) => {
    const title = doc?.title || ref?.title || 'Untitled';
    const id = doc ? `saved:${doc.id}` : `canvas:${ref.id}`;
    const classification = materialClassification(doc, ref);
    const entry = {
      id,
      title,
      documentID: doc?.id,
      materialID: ref?.id,
      sourceURL: ref?.sourceURL || doc?.sourceURL,
      detail: doc
        ? `${doc.pageCount} pages · Saved to your account`
        : ref?.assignment?.locked
          ? 'Locked in Canvas'
          : ref?.byteCount > 100_000_000
            ? 'Larger than 100 MB'
            : 'Download to read',
      submissionStatus: ref?.assignment?.status,
      assignment: ref?.assignment,
      requiresSubmission:
        !ref?.assignment ||
        ref.assignment.submissionTypes?.some((type) => !['none', 'not_graded'].includes(type)) !==
          false,
      updateAvailable: !!(doc && ref?.version && doc.sourceVersion !== ref.version),
      ...classification,
      canvasHeading: ref?.linkedFromTitle || ref?.moduleSection,
      canvasSubheading: ref?.linkedSection,
      linkedPosition: ref?.linkedPosition,
      linkedOrder: ref?.linkedOrder,
      canvasGroupTitle: ref?.moduleTitle || ref?.linkedFromTitle || ref?.folderTitle,
    };
    let groupID, groupTitle, basis, order;
    if (ref?.moduleID != null && ref.moduleTitle?.trim()) {
      groupID = `module:${ref.moduleID}`;
      groupTitle = ref.moduleTitle;
      basis = 'Canvas module order';
      order = ref.modulePosition ?? 0;
    } else if (ref?.linkedFromID && ref.linkedFromTitle?.trim()) {
      groupID = `canvas-page:${ref.linkedFromID}`;
      groupTitle = ref.linkedFromTitle;
      basis = 'Linked from Canvas';
      order = 5000;
    } else if (ref?.folderID != null && ref.folderTitle?.trim()) {
      groupID = `folder:${ref.folderID}`;
      groupTitle = ref.folderTitle;
      basis = 'Canvas folder';
      order = 7500;
    } else {
      groupID = classification.categoryID;
      groupTitle = classification.categoryTitle;
      basis = 'Document content and file metadata';
      order = 10000 + materialCategories.findIndex(([id]) => id === groupID);
    }
    if (!groups.has(groupID))
      groups.set(groupID, {
        id: groupID,
        title: groupTitle,
        basis,
        order,
        items: [],
      });
    groups.get(groupID).items.push({ ...entry, order: ref?.moduleItemPosition ?? 10000 });
    if (ref?.kind === 'files' || (!ref && (!doc?.sourceKey || doc.sourceKey.startsWith('files:'))))
      files.push({
        ...entry,
        title: ref?.fileName || doc?.originalFileName || doc?.fileName || title,
      });
  };
  for (const ref of course.canvasMaterials || []) {
    references.add(ref.id);
    add(ref, savedBySource.get(ref.id));
  }
  for (const doc of course.documents) if (!references.has(doc.sourceKey)) add(null, doc);
  return {
    groups: [...groups.values()]
      .sort((a, b) => a.order - b.order || sortNames(a, b))
      .map((g) => ({ ...g, items: g.items.sort((a, b) => a.order - b.order ||
        sortCanvasLinks(a, b) || (a.linkedPosition ?? -1) - (b.linkedPosition ?? -1) || sortNames(a, b)) })),
    files: files.sort(sortNames),
  };
}
export class Workspaces {
  constructor(store, documents, options = {}) {
    this.store = store;
    this.documents = documents;
    this.attachmentCorpus = new AttachmentCorpus(store.root, options);
    this.options = options;
    this.accounts = new Map();
    this.queues = new Map();
    this.navigationRequests = new Map();
    this.analysisJobs = new Map();
    this.materialCatalogs = new WeakMap();
    this.search = new WorkspaceSearch(documents);
    this.learning = new HostedLearning(this);
  }
  account(id) {
    const time = Date.now(),
      limit = this.options.maxCachedAccounts || 128;
    for (const [key, account] of this.accounts) {
      if (
        key !== id &&
        !account.job &&
        !account.assignmentRefresh &&
        !account.analysisPending &&
        !account.examRecommendationBusy &&
        !this.queues.has(key) &&
        time - account.lastAccess > 30 * 60_000
      )
        this.accounts.delete(key);
    }
    if (!this.accounts.has(id)) {
      if (this.accounts.size >= limit) {
        const idle = [...this.accounts]
          .filter(
            ([key, account]) => !account.job && !account.assignmentRefresh && !account.analysisPending && !account.examRecommendationBusy && !this.queues.has(key)
          )
          .sort((a, b) => a[1].lastAccess - b[1].lastAccess);
        if (!idle.length) fail('The server is busy. Try again shortly.', 503);
        this.accounts.delete(idle[0][0]);
      }
      this.accounts.set(id, {
        ...this.store.account(id),
        busy: false,
        streaming: false,
        error: null,
        status: null,
        controller: null,
      });
    }
    const account = this.accounts.get(id);
    account.lastAccess = time;
    return account;
  }
  assertAvailable(account) {
    if (account.busy || account.streaming) fail('Wait for the current task to finish.', 409);
  }
  practiceCompletion(account, purpose = 'practice-generation') {
    const provider = hostedProviders.find((p) => p.id === account.settings.providerID) || hostedProviders[0];
    const model = account.settings.modelID || provider.defaultModel;
    const key = this.store.credential(account.id, `provider:${provider.id}`);
    if (!key && !this.options.complete) fail('Add your provider API key in Account settings.');
    return async (prompt, signal) => {
      const result = await (this.options.complete || runCompletion)({ provider: provider.id, model,
        reasoningEffort: reasoningEffort(provider, model, account.settings), kind: 'text', selection: '', context: '',
        messages: [{ role: 'user', content: prompt }] },
      { provider: provider.id, apiKeys: { [provider.id]: key } }, () => {},
      AbortSignal.any([signal, AbortSignal.timeout(300_000)]), undefined, undefined, { purpose });
      if (result.text?.trim() && !signal.aborted) {
        account.settings.recentModels = recordRecentModel(account.settings.recentModels, provider.id, model);
        this.store.save(account);
      }
      return { ...result, model: result.model || model };
    };
  }
  async learningAction(session, command) {
    return this.serial(session.user_id, async () => {
      this.store.refreshNavigation(session);
      const account = this.account(session.user_id);
      if (command.action === 'practiceGenerate') this.learning.generate(account, session.navigation, command);
      else if (command.action === 'practice') this.learning.command(account, command.learning);
      else fail('Unknown practice action.');
      return this.learning.view(account, session.navigation);
    });
  }
  async serial(id, work) {
    if (this.stopping) fail('The server is restarting. Try again shortly.', 503);
    const previous = this.queues.get(id) || Promise.resolve();
    const next = previous.catch(() => {}).then(work);
    this.queues.set(id, next);
    try {
      return await next;
    } finally {
      if (this.queues.get(id) === next) this.queues.delete(id);
    }
  }
  course(account, navigation) {
    return account.library.courses.find((c) => c.id === navigation.selectedCourseID);
  }
  doc(account, id) {
    return (
      account.library.courses.flatMap((c) => c.documents).find((d) => d.id === id) ||
      fail('Document not found.', 404)
    );
  }
  thread(course, navigation, create = false) {
    let thread = course?.threads.find((t) => t.id === navigation.selectedThreadID);
    if (!thread && create) {
      if (!course) fail('Open a workspace first.');
      if (course.threads.length >= 200) fail('This workspace has reached its conversation limit.');
      thread = {
        id: randomUUID(),
        title: 'New conversation',
        documentID: navigation.selectedDocumentID,
        assignmentID: navigation.selectedAssignmentID || null,
        messages: [],
        sources: {},
        draft: '',
        mode: navigation.mode || 'Explain',
      };
      course.threads.push(thread);
      navigation.selectedThreadID = thread.id;
    }
    return thread;
  }
  owner(account, nav) {
    const thread = this.thread(this.course(account, nav), nav);
    return {
      courseID: nav.selectedCourseID || null,
      documentID: nav.selectedDocumentID || null,
      threadID: thread?.id || null,
      page: nav.page || 1,
      revision: hash(
        `${nav.selectedAssignmentID || ''}\0${thread?.draft || ''}\0${nav.mode || 'Explain'}\0${nav.selection || ''}\0${thread?.draftImage || ''}\0${JSON.stringify(thread?.draftFiles || [])}\0${nav.automaticContextEnabled !== false}\0${nav.includeCourse === true}\0${thread?.entirePDF === true}`
      ),
    };
  }
  validateOwner(account, nav, owner) {
    const current = this.owner(account, nav);
    if (!owner || Object.keys(current).some((key) => (owner[key] ?? null) !== current[key]))
      fail(
        'The reading or draft changed. Your browser draft is retained; reopen its original reading or copy it first.',
        409
      );
  }
  async state(session) {
    const account = this.account(session.user_id),
      nav = session.navigation;
    void this.refreshMathWiki(account, nav.selectedCourseID);
    void this.refreshCanvasContent(account, nav.selectedCourseID);
    void this.refreshCanvasAssignments(account);
    const course = this.course(account, nav),
      doc = course?.documents.find((d) => d.id === nav.selectedDocumentID),
      thread = this.thread(course, nav);
    const showingLibrary = nav.showingCourseLibrary !== false;
    const contextScope = courseContextScope(thread, nav);
    if (!showingLibrary) void this.analyzeStoredMaterials(account, course);
    const index = !showingLibrary && doc ? await this.documents.index(account.id, doc).catch(() => null) : null;
    const assignment = !showingLibrary && nav.selectedAssignmentID
      ? course?.canvasMaterials?.find((m) => m.id === nav.selectedAssignmentID) : null,
      instructions = assignment?.id
        ? course?.documents.find((d) => d.sourceKey === assignment.id) : null;
    const assignmentText = instructions
      ? (await this.documents.index(account.id, instructions).catch(() => ({ pages: [] }))).pages
          .map((p) => p.text)
          .join('\n\n')
      : '';
    if (assignment) await this.normalizeAssignmentIndexes(account, course, assignment, doc, index);
    const files = assignmentFileReferences(course, assignment);
    const inventory = showingLibrary ? { groups: [], files: [] } : this.materialInventory(course),
      provider =
        hostedProviders.find((p) => p.id === account.settings.providerID) || hostedProviders[0];
    const semesters = new Map();
    for (const c of account.library.courses) {
      const title = c.term || 'No semester',
        id = c.term ? `term:${c.term}` : 'unassigned';
      if (!semesters.has(id)) semesters.set(id, { id, title, courseIDs: [], isCurrent: false });
      semesters.get(id).courseIDs.push(c.id);
    }
    const page = Math.max(1, Math.min(nav.page || 1, doc?.pageCount || 1));
    return {
      hosted: true,
      account: { email: account.email },
      capabilities: { practiceReview: true },
      library: {
        ...account.library,
        ...nav,
        courses: account.library.courses.map((c) => ({
          ...c,
          threads: c.threads.map((t) => ({
            id: t.id,
            title: t.title,
            documentID: t.documentID,
            assignmentID: t.assignmentID,
          })),
        })),
      },
      showingLibrary,
      assignmentRefreshBusy: !!account.assignmentRefresh,
      selectedSemesterID: nav.selectedSemesterID || 'all',
      semesters: [...semesters.values()].sort((a, b) => b.title.localeCompare(a.title)),
      materialGroups: inventory.groups,
      materialFiles: inventory.files,
      messages: showingLibrary ? [] : thread?.messages || [],
      sources: showingLibrary ? {} : thread?.sources || {},
      page,
      pageText: index?.pages[page - 1]?.text || '',
      draft: thread?.draft || '',
      draftImage: thread?.draftImage || null,
      draftFiles: thread?.draftFiles || [],
      automaticContextEnabled: nav.automaticContextEnabled !== false,
      mode: teachingModeLabel(nav.mode),
      language: account.settings.language || 'auto',
      entirePDF: !!doc && !['image', 'preview'].includes(doc.kind) && thread?.entirePDF === true,
      editing: nav.editing || null,
      models: hostedProviders.flatMap((p) =>
        p.models.map((m) => ({
          id: typeof m === 'string' ? m : m.id,
          label: typeof m === 'string' ? m : m.label,
          providerID: p.id,
          provider: p.name,
          lastUsedAt: normalizeRecentModels(account.settings.recentModels).find((item) =>
            item.providerID === p.id && item.modelID === (typeof m === 'string' ? m : m.id))?.lastUsedAt,
          reasoningEfforts: m.reasoning?.efforts || [],
          defaultReasoningEffort: m.reasoning?.default || null,
        }))
      ),
      providerID: provider.id,
      modelID: account.settings.modelID || provider.defaultModel,
      studyModelMode: normalizeStudyModelMode(account.settings.studyModelMode),
      reasoningEffort: reasoningEffort(
        provider,
        account.settings.modelID || provider.defaultModel,
        account.settings
      ),
      canSend:
        !!course &&
        !account.busy &&
        !account.streaming &&
        !!(thread?.draft?.trim() || thread?.draftImage || thread?.draftFiles?.some((file) => file.enabled !== false) || nav.selection?.trim()),
      streaming: account.streaming,
      answerStartedAt: thread?.messages.find((message) => message.isStreaming)?.createdAt || null,
      busy: account.busy,
      loadingDocument: false,
      status: account.status,
      warnings: account.library.courses.flatMap((c) => c.catalogWarnings || []),
      error: account.error,
      contextScope,
      workspaceMemory: { courseID: course?.id || null,
        assignmentID: contextScope === 'assignment' ? thread?.assignmentID || nav.selectedAssignmentID : null,
        ...workspaceMemory(course, contextScope === 'assignment' ? thread?.assignmentID || nav.selectedAssignmentID : null) },
      context:
        contextScope === 'course'
          ? courseContextSummary(course)
          : assignment
            ? `${assignment.title} · ${files.filter((ref) => course.documents.some((document) => document.sourceKey === ref.id && document.kind !== 'preview' && (document.unreadablePages || 0) < document.pageCount)).length} of ${files.length} files indexed for the companion`
            : doc
              ? `Page ${page} · ${doc.pageCount} pages indexed`
              : 'Your private course materials',
      includeCourse: contextScope === 'course' || nav.includeCourse === true,
      assignmentText,
      assignmentFiles: files,
      assignmentPDFs: files.filter((ref) => /\.pdf$/i.test(ref.fileName || '')),
      assignmentFileNotices: assignment ? this.assignmentNotices(course, assignment) : {},
      assignmentNotice: nav.assignmentNotice || null,
      draftOwner: this.owner(account, nav),
      learningRevision: this.learning.state(account).revision,
      reviewDue: this.learning.due(this.learning.state(account)).length,
    };
  }
  materialInventory(course) {
    if (!course) return { groups: [], files: [] };
    // Threads and navigation change on every chat/page interaction. They do
    // not change material classification or sort order. In-place catalog
    // mutations still invalidate this cache, including background downloads.
    const key = JSON.stringify([
      course.documents.map(({ lastPage, lastOpenedAt, ...metadata }) => metadata),
      course.canvasMaterials,
    ]);
    const cached = this.materialCatalogs.get(course);
    if (cached?.key === key) return cached.value;
    const value = materialInventory(course);
    this.materialCatalogs.set(course, { key, value });
    return value;
  }
  canvas(account, signal) {
    const origin = account.library.canvasOrigin,
      credential = this.store.credential(account.id, `canvas:${origin}`);
    if (!credential) fail('Connect Canvas with your personal access token first.');
    return new Canvas(origin, credential, {
      hosts: this.options.canvasHosts,
      request: this.options.remoteRequest,
      signal,
    });
  }
  refreshMathWiki(account, selectedCourseID, time = Date.now()) {
    if (account.mathWikiRefresh) return account.mathWikiRefresh;
    if (this.stopping || account.busy || account.assignmentRefresh || account.streaming || account.settings.automaticallyUpdateMathWiki === false)
      return Promise.resolve();
    const date = new Date(time), term = `${date.getFullYear()}${date.getMonth() >= 7 ? 'h' : 'v'}`;
    const targets = account.library.courses.filter(course => {
      const scope = mathWikiCourse(course);
      return scope?.terms.length && course.canvasID && course.canvasAvailable !== false &&
        course.canvasOrigin === account.library.canvasOrigin && course.canvasUserID === account.library.canvasUserID &&
        (course.id === selectedCourseID || (course.favorite ?? course.canvasFavorite) || scope.terms.includes(term)) &&
        pollDecision(account, course, 'mathWiki', time);
    });
    if (!targets.length) return Promise.resolve();
    const previousStatus = account.status, origin = account.library.canvasOrigin, userID = account.library.canvasUserID;
    this.job(account, 'Checking math wiki…', async signal => {
      const wiki = account.mathWikiClient ||= new MathWiki({ request: this.options.remoteRequest });
      wiki.signal = signal;
      const check = () => {
        signal.throwIfAborted();
        if (account.library.canvasOrigin !== origin || account.library.canvasUserID !== userID)
          throw new DOMException('The course account changed.', 'AbortError');
      };
      let downloaded = 0;
      for (const target of targets) {
        check();
        const course = account.library.courses.find(c => c.id === target.id);
        if (!course) continue;
        const reason = pollDecision(account, course, 'mathWiki', time);
        if (!reason) continue;
        beginPoll(course, 'mathWiki', time, reason);
        this.store.save(account);
        let result;
        try { result = await wiki.catalog(course, { fileRecheckInterval: MathWiki.fileCheckInterval }); }
        catch (error) { check(); observePoll(course, 'mathWiki', [], false, time); throw error; }
        check();
        if (!account.library.courses.includes(course)) continue;
        observePoll(course, 'mathWiki', result.items, result.complete, time);
        const previous = new Map((course.canvasMaterials || []).map(ref => [ref.id, ref]));
        const latest = new Map(result.items.map(ref => [ref.id, ref]));
        const changes = { added: [], updated: [], removed: [], retained: [] };
        for (const ref of result.items) {
          const old = previous.get(ref.id);
          if (!old) changes.added.push(ref.id);
          else if (ref.version !== old.version || ref.title !== old.title) changes.updated.push(ref.id);
        }
        for (const ref of previous.values()) if (!latest.has(ref.id)) {
          if (isMathWikiMaterial(ref) && result.complete) changes.removed.push(ref.id);
          else latest.set(ref.id, ref);
        }
        course.canvasMaterials = [...latest.values()];
        if (changes.added.length + changes.updated.length + changes.removed.length) {
          course.catalogChanges = changes;
          course.catalogChangedAt = time / 1000;
        }
        if (result.complete) course.mathWikiCheckedAt = time / 1000;
        const warnings = [...result.warnings];
        const publicClient = { origin, signal, material: (ref, _course, options) => wiki.material(ref, options) };
        for (const ref of result.items) {
          check();
          if (ref.unavailableReason || (ref.byteCount || 0) > 100_000_000) continue;
          if (course.documents.some(doc => doc.sourceKey === ref.id && doc.sourceVersion === ref.version && !doc.indexUnavailable)) continue;
          try { await this.fetchMaterial(account, course, ref, publicClient); downloaded++; }
          catch (error) { check(); warnings.push(`Math wiki ${ref.title}: ${error.message}`); }
        }
        const oldWarnings = new Set(course.mathWikiWarnings || []);
        course.catalogWarnings = (course.catalogWarnings || []).filter(warning => !oldWarnings.has(warning)).concat(warnings);
        course.mathWikiWarnings = warnings;
        this.store.save(account);
      }
      account.status = downloaded ? `Math wiki: ${downloaded} materials downloaded or updated.` : previousStatus;
    });
    account.mathWikiRefresh = account.job.finally(() => { account.mathWikiRefresh = null; });
    return account.mathWikiRefresh;
  }

  refreshCanvasContent(account, selectedCourseID, time = Date.now()) {
    if (account.contentRefresh) return account.contentRefresh;
    if (this.stopping || account.busy || account.assignmentRefresh || account.streaming || account.settings.automaticallyUpdateCanvasContent !== true)
      return Promise.resolve();
    const date = new Date(time), year = date.getFullYear(), autumn = date.getMonth() >= 7;
    const targets = account.library.courses.filter(course => course.canvasID && course.canvasAvailable !== false &&
      course.canvasOrigin === account.library.canvasOrigin && course.canvasUserID === account.library.canvasUserID &&
      (course.id === selectedCourseID || (course.favorite ?? course.canvasFavorite) ||
        // Match an explicit semester; an undated course isn't assumed current.
        new RegExp(`${String(year).slice(-2)}${autumn ? 'h' : 'v'}(?:\\b|-)`, 'i').test(course.code || '') ||
        (String(course.term || '').includes(String(year)) && (autumn ? /høst|autumn|fall/i : /vår|spring/i).test(course.term))) &&
      pollDecision(account, course, 'canvas', time));
    if (!targets.length) return Promise.resolve();
    const origin = account.library.canvasOrigin, userID = account.library.canvasUserID;
    this.job(account, 'Checking course content…', async signal => {
      const check = () => {
        signal.throwIfAborted();
        if (account.settings.automaticallyUpdateCanvasContent !== true || account.library.canvasOrigin !== origin || account.library.canvasUserID !== userID)
          throw new DOMException('Course updates stopped.', 'AbortError');
      };
      let canvas, downloaded = 0;
      for (const target of targets) {
        check();
        const course = account.library.courses.find(c => c.id === target.id);
        if (!course) continue;
        const reason = pollDecision(account, course, 'canvas', time);
        if (!reason) continue;
        beginPoll(course, 'canvas', time, reason);
        this.store.save(account);
        let observed = false;
        try {
          canvas ||= this.canvas(account, signal);
          const catalog = await canvas.catalog(course, { includePublic: reason !== 'predicted' });
          check();
          if (!account.library.courses.includes(course)) continue;
          observeCatalog(course, catalog, time, reason !== 'predicted');
          observed = true;
          course.canvasMaterials = catalog.items;
          course.catalogWarnings = catalog.warnings;
          course.catalogChanges = catalog.changes;
          course.catalogUpdatedAt = time / 1000;
          for (const ref of catalog.items) {
            check();
            if (reason === 'predicted' && /^(math-wiki|course-web):/.test(ref.id)) continue;
            if (ref.assignment?.locked || (ref.byteCount || 0) > 100_000_000 ||
              course.documents.some(doc => doc.sourceKey === ref.id && doc.sourceVersion === ref.version && !doc.indexUnavailable)) continue;
            try { await this.fetchMaterial(account, course, ref, canvas); downloaded++; }
            catch (error) { check(); course.catalogWarnings.push(`${ref.title}: ${error.message}`); }
          }
        } catch (error) {
          check();
          if (!observed) observePoll(course, 'canvas', [], false, time);
          course.catalogWarnings = [`Course content: ${error.message}`];
        }
        this.store.save(account);
      }
      account.status = downloaded ? `${downloaded} course materials downloaded or updated.` : 'Course content checked.';
    });
    account.contentRefresh = account.job.finally(() => { account.contentRefresh = null; });
    return account.contentRefresh;
  }

  refreshCanvasAssignments(account, time = Date.now(), force = false) {
    if (account.assignmentRefresh) return account.assignmentRefresh;
    if (this.stopping || account.busy || !account.library.canvasOrigin ||
        (!force && time - (account.assignmentRefreshAttempt || 0) < 120_000)) return Promise.resolve();
    const targets = account.library.courses.filter((course) => course.canvasID &&
      course.canvasOrigin === account.library.canvasOrigin && course.canvasUserID === account.library.canvasUserID &&
      course.canvasAvailable !== false);
    if (!targets.length) return Promise.resolve();
    account.assignmentRefreshAttempt = time;
    const controller = new AbortController();
    account.assignmentRefreshController = controller;
    const origin = account.library.canvasOrigin, userID = account.library.canvasUserID;
    account.assignmentRefresh = (async () => {
      const canvas = this.canvas(account, controller.signal);
      let failures = 0;
      for (const target of targets) {
        if (account.busy || this.stopping) return;
        try {
          const records = await canvas.list(`/api/v1/courses/${target.canvasID}/assignments?include[]=submission`);
          controller.signal.throwIfAborted();
          await this.serial(account.id, () => {
            if (account.busy || account.library.canvasOrigin !== origin || account.library.canvasUserID !== userID) return;
            const course = account.library.courses.find((course) => course.id === target.id);
            if (!course) return;
            course.canvasMaterials ||= [];
            for (const record of records) {
              if (record.published === false || record.hidden_for_user) continue;
              const update = canvas.reference('assignments', record, target.canvasID);
              const existing = course.canvasMaterials.find((item) => item.id === update.id);
              // Keep module placement and downloaded files; only metadata changes.
              if (existing) Object.assign(existing, update);
              else course.canvasMaterials.push(update);
            }
            this.store.save(account);
          });
        } catch (error) {
          controller.signal.throwIfAborted();
          failures++;
        }
      }
      if (account.library.canvasOrigin !== origin || account.library.canvasUserID !== userID) return;
      if (!failures) account.library.canvasAssignmentsCheckedAt = time / 1000;
      account.library.canvasAssignmentsError = failures ? 'Some Canvas statuses could not be refreshed. Retrying automatically.' : null;
      this.store.save(account);
    })().catch((error) => {
      if (!controller.signal.aborted && !this.stopping)
        account.library.canvasAssignmentsError = error.message;
    }).finally(() => {
      account.assignmentRefresh = null;
      account.assignmentRefreshController = null;
    });
    return account.assignmentRefresh;
  }
  job(account, label, work, streaming = false) {
    this.assertAvailable(account);
    account[streaming ? 'streaming' : 'busy'] = true;
    account.status = label;
    account.error = null;
    const controller = new AbortController();
    account.controller = controller;
    const job = Promise.resolve()
      .then(() => work(controller.signal))
      .catch((error) => {
        account.error = error.name === 'AbortError' ? null : error.message;
        account.status =
          error.name === 'AbortError' ? 'Stopped. Completed work is saved.' : error.message;
      })
      .finally(() => {
        account.busy = false;
        account.streaming = false;
        account.controller = null;
        this.store.save(account);
        account.job = null;
      });
    account.job = job;
  }
  async importFile(account, course, name, data) {
    if (account.library.courses.reduce((sum, c) => sum + c.documents.length, 0) >= 2000)
      fail('This account has reached its document limit.');
    const used =
      account.settings.storageBytes ||
      account.library.courses
        .flatMap((c) => c.documents)
        .reduce((sum, d) => sum + (d.byteCount || 0), 0);
    if (used + data.length > (this.options.quotaBytes || 2_000_000_000))
      fail('This account has reached its file storage limit.');
    const document = await this.documents.import(account.id, name, data);
    document.byteCount = data.length;
    account.settings.storageBytes = used + data.length;
    course.documents.push(document);
    return document;
  }
  async fetchMaterial(account, course, ref, canvas, options = {}) {
    if (
      course.canvasOrigin !== canvas.origin ||
      course.canvasUserID !== account.library.canvasUserID
    )
      fail('Reconnect the Canvas account that owns this workspace.');
    const existing = course.documents.find((d) => d.sourceKey === ref.id);
    if (existing && existing.sourceVersion === ref.version && !existing.indexUnavailable && !needsCanvasHTMLUpgrade(existing))
      return existing;
    const item = await canvas.material(ref, course, options);
    canvas.signal?.throwIfAborted();
    if (item.data.length > (options.limit || 100_000_000))
      throw Object.assign(new Error('The file exceeds the download limit.'), {
        downloadedBytes: item.data.length,
      });
    Object.assign(ref, item.reference);
    if (!course.canvasMaterials.some((material) => material.id === ref.id))
      course.canvasMaterials.push(ref);
    const doc = await this.importFile(
      account,
      course,
      item.name,
      item.data.length || ref.kind === 'files'
        ? item.data
        : Buffer.from('No instructions provided.')
    );
    if (existing?.locallyEditedAt) {
      existing.sourceKey = null;
      existing.title += ' (local edits)';
    }
    Object.assign(doc, {
      title: ref.title,
      sourceKey: ref.id,
      sourceURL: ref.sourceURL,
      sourceVersion: ref.version,
    });
    if (existing && !existing.locallyEditedAt) {
      // Keep citations, conversations and learning history attached to the same
      // document while atomically switching to the newly imported original.
      course.documents = course.documents.filter((d) => d.id !== doc.id);
      Object.assign(existing, doc, { id: existing.id, storageID: doc.id,
        lastPage: Math.min(existing.lastPage || 1, doc.pageCount), lastOpenedAt: existing.lastOpenedAt });
      return existing;
    }
    return doc;
  }
  assignmentNotices(course, assignment) {
    course.assignmentFileNotices ||= {};
    return (course.assignmentFileNotices[assignment.id] ||= {});
  }
  cachedMaterial(course, ref) {
    return course.documents.find(
      (document) =>
        document.sourceKey === ref.id &&
        document.sourceVersion === ref.version &&
        !needsCanvasHTMLUpgrade(document) &&
        !document.indexUnavailable
    );
  }
  async normalizeAssignmentIndexes(account, course, assignment, selectedDocument, selectedIndex) {
    const notices = this.assignmentNotices(course, assignment);
    for (const ref of assignmentFileReferences(course, assignment)) {
      const document = course.documents.find((doc) => doc.sourceKey === ref.id);
      if (!document || Number.isInteger(document.unreadablePages)) continue;
      try {
        const index =
          document.id === selectedDocument?.id
            ? selectedIndex
            : await this.documents.index(account.id, document);
        document.unreadablePages = unreadablePageCount(index.pages);
      } catch {
        document.unreadablePages = document.pageCount;
        document.indexUnavailable = true;
        notices[ref.id] = 'The saved file could not be indexed. Open it to retry.';
      }
    }
  }
  async upgradeCachedDocument(account, document, signal) {
    const indexed = await this.documents.reindex(account.id, document, { signal });
    signal?.throwIfAborted();
    for (const key of [
      'kind',
      'pageCount',
      'unreadablePages',
      'contentNotice',
      'contentHash',
      'indexVersion',
      'materialAnalysis',
    ])
      document[key] = indexed[key];
    document.indexUnavailable = false;
    this.store.save(account);
  }
  async analyzeStoredMaterials(account, course) {
    if (!course) return;
    const key = `${account.id}:${course.id}`;
    if (this.analysisJobs.has(key)) return this.analysisJobs.get(key);
    const missing = course.documents
      .filter((doc) => doc.materialAnalysis?.version !== materialAnalysisVersion)
      .slice(0, 6);
    if (!missing.length) return;
    // Upgrade existing libraries a bounded batch at a time using their saved text.
    // OCR runs only on import/open, never on a state poll.
    account.analysisPending = (account.analysisPending || 0) + 1;
    const revision = (doc) =>
      JSON.stringify([doc.contentHash, doc.indexVersion, doc.storageID, doc.fileName, doc.title]);
    const task = (async () => {
      let changed = false;
      for (const doc of missing) {
        const before = revision(doc);
        const index = await this.documents.index(account.id, doc).catch(() => ({ pages: [] }));
        if (
          !course.documents.includes(doc) ||
          revision(doc) !== before ||
          doc.materialAnalysis?.version === materialAnalysisVersion
        )
          continue;
        doc.materialAnalysis = analyzeMaterial({
          name: doc.fileName,
          title: doc.title,
          kind: doc.kind,
          pages: index.pages,
        });
        changed = true;
      }
      if (changed) this.store.save(account);
    })()
      .catch(() => {})
      .finally(() => {
        account.analysisPending--;
        this.analysisJobs.delete(key);
      });
    this.analysisJobs.set(key, task);
    return task;
  }
  upgradeOpenedDocument(account, document) {
    if (needsCanvasHTMLUpgrade(document) && !account.busy && !account.streaming) {
      const course = account.library.courses.find((c) => c.documents.includes(document));
      const ref = course?.canvasMaterials?.find((m) => m.id === document.sourceKey);
      if (ref) {
        this.job(account, 'Restoring the original course page and links…', async (signal) => {
          await this.fetchMaterial(account, course, ref, this.canvas(account, signal));
          account.status = 'Original course page and links restored.';
        });
        return;
      }
    }
    if (needsTextIndexUpgrade(document) && !account.busy && !account.streaming)
      this.job(account, 'Improving the document text index…', (signal) =>
        this.upgradeCachedDocument(account, document, signal)
      );
  }
  async openAssignment(account, nav, command) {
    const course =
      account.library.courses.find((entry) => entry.id === command.courseID) ||
      fail('Workspace not found.', 404);
    const assignment =
      course.canvasMaterials.find(
        (ref) => ref.kind === 'assignments' && ref.id === (command.assignmentID || command.id)
      ) || fail('Assignment not found.', 404);
    const attachmentAction = command.action !== 'assignment';
    if (attachmentAction) {
      if (nav.selectedCourseID !== course.id || nav.selectedAssignmentID !== assignment.id)
        fail('The assignment changed. Open the file from the current assignment.', 409);
      if (!assignmentFileReferences(course, assignment).some((ref) => ref.id === command.id))
        fail('File not linked to this assignment.', 404);
    } else {
      this.selectCourse(account, nav, course.id);
      nav.selectedAssignmentID = assignment.id;
      nav.selectedThreadID =
        course.threads.findLast((thread) => thread.assignmentID === assignment.id)?.id || null;
      nav.mode = teachingModeLabel(this.thread(course, nav)?.mode);
    }
    nav.assignmentNotice = null;
    const notices = this.assignmentNotices(course, assignment);
    let canvas,
      downloadedBytes = 0;
    const attemptedFiles = [];
    const connected = () => {
      this.assertAvailable(account);
      canvas ||= this.canvas(account);
      if (
        course.canvasOrigin !== canvas.origin ||
        course.canvasUserID !== account.library.canvasUserID
      )
        fail('Reconnect the Canvas account that owns this workspace.');
      return canvas;
    };
    try {
      const client = connected();
      const { value } = await client.api(`/api/v1/courses/${course.canvasID}/assignments/${encodeURIComponent(assignment.remoteID)}?include[]=submission`);
      if (value.published === false || value.hidden_for_user)
        fail('This assignment is no longer available in Canvas.');
      Object.assign(assignment, client.reference('assignments', value, course.canvasID));
      this.store.save(account);
    } catch (error) {
      nav.assignmentNotice = `Deadline may be out of date. Could not refresh Canvas: ${error.message}`;
    }
    if (assignment.assignment?.locked) {
      nav.assignmentNotice = [nav.assignmentNotice, 'Locked in Canvas.'].filter(Boolean).join(' ');
      return;
    }
    if (!this.cachedMaterial(course, assignment)) {
      try {
        await this.fetchMaterial(account, course, assignment, connected());
      } catch (error) {
        nav.assignmentNotice = error.message;
      }
    }
    const files = assignmentFileReferences(course, assignment);
    if (attachmentAction && !files.some((ref) => ref.id === command.id))
      fail('File no longer linked to this assignment.', 404);
    let selected = attachmentAction
      ? files.find((ref) => ref.id === command.id)
      : files.find((ref) => /\.pdf$/i.test(ref.fileName || ''));
    // Older catalogs may omit files linked directly from an assignment. Resolve those
    // individually; one inaccessible attachment must not conceal the remaining files.
    if (!selected && !attachmentAction) {
      for (const ref of files.slice(0, 50).filter((file) => !file.fileName)) {
        try {
          const client = connected();
          const item = await client.fileMetadata(ref.remoteID, course.canvasID);
          const resolved = client.reference('files', item, course.canvasID);
          course.canvasMaterials.push(resolved);
          delete notices[ref.id];
          if (/\.pdf$/i.test(resolved.fileName || '')) {
            selected = resolved;
            break;
          }
        } catch (error) {
          notices[ref.id] = error.message;
        }
      }
    }
    if (selected) {
      try {
        let document = this.cachedMaterial(course, selected);
        if (!document) {
          const limit = attachmentAction ? 100_000_000 : 20_000_000;
          if (Number(selected.byteCount) > limit)
            throw new Error(
              attachmentAction
                ? 'The file exceeds the 100 MB download limit.'
                : 'Open this file to add it; it exceeds the 20 MB automatic download limit.'
            );
          document = await this.fetchMaterial(account, course, selected, connected(), { limit });
          downloadedBytes = document.byteCount || 0;
        }
        if (needsTextIndexUpgrade(document) && !account.busy && !account.streaming)
          await this.upgradeCachedDocument(account, document);
        delete notices[selected.id];
        this.selectDocument(course, nav, document.id, true);
      } catch (error) {
        downloadedBytes += error.downloadedBytes || 0;
        attemptedFiles.push(selected.id);
        notices[selected.id] = error.message;
      }
    }
    this.prepareAssignmentFiles(account, course, assignment, downloadedBytes, attemptedFiles);
  }
  prepareAssignmentFiles(account, course, assignment, downloadedBytes = 0, attemptedFiles = []) {
    if (account.busy || account.streaming) return;
    const files = assignmentFileReferences(course, assignment),
      notices = this.assignmentNotices(course, assignment);
    for (const ref of files.slice(50))
      if (!this.cachedMaterial(course, ref))
        notices[ref.id] = 'Open this file to add it; automatic preparation is limited to 50 files.';
    const pending = files
      .slice(0, 50)
      .filter(
        (ref) =>
          !attemptedFiles.includes(ref.id) &&
          (!this.cachedMaterial(course, ref) ||
            needsTextIndexUpgrade(this.cachedMaterial(course, ref)))
      );
    if (!pending.length) return;
    this.job(account, 'Preparing assignment files…', async (signal) => {
      let remaining = Math.max(0, 50_000_000 - downloadedBytes),
        canvas;
      for (const ref of pending) {
        signal.throwIfAborted();
        const cached = this.cachedMaterial(course, ref);
        if (cached) {
          try {
            await this.upgradeCachedDocument(account, cached, signal);
            delete notices[ref.id];
          } catch (error) {
            signal.throwIfAborted();
            notices[ref.id] = `${error.message} Open this file to retry.`;
          }
          continue;
        }
        const limit = Math.min(20_000_000, remaining);
        if (!limit || Number(ref.byteCount) > limit) {
          notices[ref.id] =
            Number(ref.byteCount) > 20_000_000
              ? 'Open this file to add it; it exceeds the 20 MB automatic download limit.'
              : 'Open this file to add it; the 50 MB automatic download budget was reached.';
          continue;
        }
        try {
          canvas ||= this.canvas(account, signal);
          if (
            course.canvasOrigin !== canvas.origin ||
            course.canvasUserID !== account.library.canvasUserID
          )
            fail('Reconnect the Canvas account that owns this workspace.');
          account.status = `Preparing ${ref.fileName || ref.title}…`;
          const document = await this.fetchMaterial(account, course, ref, canvas, { limit });
          remaining -= document.byteCount || 0;
          delete notices[ref.id];
          this.store.save(account);
        } catch (error) {
          signal.throwIfAborted();
          remaining -= Math.min(limit, error.downloadedBytes || 0);
          notices[ref.id] = `${error.message} Open this file to retry.`;
        }
      }
      account.status = Object.keys(notices).length
        ? 'Assignment opened. Some files need attention.'
        : 'Assignment files are ready.';
    });
  }
  async assignmentContext(account, course, assignment, question, selectedDocument, selectedPage, previousQuestions = [], signal) {
    const files = assignmentFileReferences(course, assignment),
      documents = [];
    const instructions = course.documents.find((document) => document.sourceKey === assignment.id);
    if (instructions) documents.push({ document: instructions, label: 'Assignment instructions' });
    const manifest = [
      `Assignment: ${assignment.title}`,
      'The following file list describes availability. Only the indexed excerpts below are available to you. Do not infer contents from a filename.',
    ];
    for (const ref of files) {
      const document = course.documents.find((doc) => doc.sourceKey === ref.id);
      const readable =
        document &&
        document.kind !== 'preview' &&
        (document.unreadablePages || 0) < document.pageCount &&
        !document.indexUnavailable;
      const status = !document
        ? 'not downloaded; contents unavailable'
        : readable
          ? 'saved and text indexed'
          : 'saved original; no readable text available';
      manifest.push(`- ${ref.fileName || ref.title}: ${status}`);
      if (readable) documents.push({ document, label: ref.fileName || ref.title });
    }
    if (!instructions) manifest.push('Assignment instructions have not been downloaded.');
    const manifestText = manifest.join('\n').slice(0, 8000) + '\n\n';
    const projectDocuments = documents.map(({ document, label }) => ({ ...document, title: label }));
    const packed = await buildCourseContext({
      course: { ...course, documents: projectDocuments }, question, previousQuestions,
      selectedDocument: projectDocuments.find((document) => document.id === selectedDocument?.id),
      selectedPage, includeCourse: true, includeMetadata: false,
      requiredDocumentIDs: new Set(projectDocuments.map((document) => document.id)),
      readIndex: (document) => this.documents.index(account.id, document), signal,
      maxChars: 48_000 - manifestText.length,
    });
    return {
      context: manifestText + packed.context,
      sources: packed.sources,
      documentIDs: new Set(documents.map(({ document }) => document.id)),
    };
  }
  selectCourse(account, nav, id) {
    const course =
      account.library.courses.find((c) => c.id === id) || fail('Workspace not found.', 404);
    Object.assign(nav, {
      selectedCourseID: id,
      selectedDocumentID: null,
      selectedAssignmentID: null,
      selectedThreadID:
        course.threads.findLast((t) => !t.documentID && !t.assignmentID)?.id || null,
      showingCourseLibrary: false,
      page: 1,
      selection: '',
      assignmentNotice: null,
    });
    nav.mode = teachingModeLabel(this.thread(course, nav)?.mode);
    return course;
  }
  selectDocument(course, nav, id, keepAssignment = false) {
    const doc =
      course?.documents.find((d) => d.id === id) ||
      fail('Document not found in this workspace.', 404);
    Object.assign(nav, {
      selectedDocumentID: id,
      selectedAssignmentID: keepAssignment ? nav.selectedAssignmentID : null,
      showingCourseLibrary: false,
      selectedThreadID:
        course.threads.findLast((t) =>
          keepAssignment
            ? t.assignmentID === nav.selectedAssignmentID
            : t.documentID === id && !t.assignmentID
        )?.id || null,
      page: doc.lastPage || 1,
      selection: '',
    });
    doc.lastOpenedAt = now();
    nav.mode = teachingModeLabel(this.thread(course, nav)?.mode);
    return doc;
  }
  async openReading(account, nav, command, current = () => true) {
    const course = account.library.courses.find(c => (!command.courseID || c.id === command.courseID)
      && c.documents.some(d => d.id === command.id));
    if (!course) fail('Document not found in this workspace.', 404);
    const document = course.documents.find(d => d.id === command.id);
    const policy = command.conversationPolicy || 'document';
    if (!['document', 'preserve'].includes(policy)) fail('Unknown conversation policy.');
    if (policy === 'preserve' && course.id !== nav.selectedCourseID)
      fail('The conversation belongs to another workspace.', 409);
    if (command.page !== undefined && (!Number.isSafeInteger(command.page) || command.page < 1))
      fail('Choose a positive whole page number.');
    if (document.indexUnavailable) fail('This document is unavailable. Download it again.', 409);
    if (this.documents.available && !await this.documents.available(account.id, document))
      fail('The document file is unavailable. Download it again.', 404);
    // A background replacement/deletion may finish while file availability is checked.
    if (!account.library.courses.includes(course) || !course.documents.includes(document))
      fail('The document changed while opening it. Try again.', 409);
    if (!current()) fail('This navigation was superseded.', 409);
    const page = Math.max(1, Math.min(command.page ?? document.lastPage ?? 1, document.pageCount || 1));
    const thread = policy === 'preserve' ? this.thread(course, nav)
      : course.threads.findLast(t => t.documentID === document.id && !t.assignmentID);
    const assignment = policy === 'preserve' && course.canvasMaterials?.find(ref => ref.id === nav.selectedAssignmentID);
    const related = assignment && (document.sourceKey === assignment.id ||
      assignmentFileReferences(course, assignment).some(ref => ref.id === document.sourceKey));
    Object.assign(nav, { selectedCourseID: course.id, selectedDocumentID: document.id,
      selectedThreadID: thread?.id || null, selectedAssignmentID: related ? assignment.id : null,
      showingCourseLibrary: false, page, selection: '', assignmentNotice: null,
      mode: policy === 'preserve' ? nav.mode : teachingModeLabel(thread?.mode),
      navigationID: command.navigationID || null });
    document.lastPage = page;
    document.lastOpenedAt = now();
    this.upgradeOpenedDocument(account, document);
    return document;
  }
  registerNavigation(session, command) {
    if (command?.navigationGeneration === undefined) return () => true;
    if (!Number.isSafeInteger(command.navigationGeneration) || command.navigationGeneration < 1 ||
      typeof command.navigationClientID !== 'string' || !/^[a-zA-Z0-9-]{1,80}$/.test(command.navigationClientID))
      fail('Invalid navigation generation.');
    const key = `${session.token}:${command.navigationClientID}`;
    const current = this.navigationRequests.get(key) || 0;
    if (command.navigationGeneration <= current) fail('This navigation was superseded.', 409);
    this.navigationRequests.delete(key);
    this.navigationRequests.set(key, command.navigationGeneration);
    // At most 16 clients per cached account; stale clients recover through a snapshot.
    while (this.navigationRequests.size > (this.options.maxCachedAccounts || 128) * 16)
      this.navigationRequests.delete(this.navigationRequests.keys().next().value);
    return () => this.navigationRequests.get(key) === command.navigationGeneration;
  }
  async recommendExams(session, command, signal) {
    const account = this.account(session.user_id);
    if (account.examRecommendationBusy) fail('An exam recommendation is already running.', 409);
    const exams = normalizeExamPlan(command?.exams);
    const baseline = JSON.stringify(exams);
    const current = () => JSON.stringify(normalizeExamPlan(account.library.examPlan || []));
    if (baseline !== current()) fail('Your exam plan changed. Reload it before requesting a recommendation.', 409);
    const mode = examRecommendationMode(command.mode);
    let input = examRecommendationInput(exams, command.interests, account.library.courses, mode, command.history);
    const catalogue = mode === 'advice' ? degreeCatalogue(ntnuStudyPlans, command.degreeSelections) : null;
    const provider = hostedProviders.find((p) => p.id === account.settings.providerID) || hostedProviders[0];
    const model = account.settings.modelID || provider.defaultModel;
    const key = this.store.credential(account.id, `provider:${provider.id}`);
    if (!key && !this.options.complete) fail('Add your provider API key in Account settings.');
    const timeout = AbortSignal.timeout(300_000);
    const responseSignal = signal ? AbortSignal.any([signal, timeout]) : timeout;
    account.examRecommendationBusy = true;
    try {
      const reply = async (instructions, context) => {
        responseSignal.throwIfAborted();
        if (baseline !== current()) fail('Your exam dates or selections changed. Request a fresh recommendation.', 409);
        let streamed = '';
        const result = await (this.options.complete || runCompletion)({
        provider: provider.id, model, reasoningEffort: reasoningEffort(provider, model, account.settings),
        // Structured plan data must bypass the 12,000-character chat-message
        // limit. Keep the student's request in the question, with the complete
        // validated plan in the provider's reference-context channel.
        kind: 'text', includeContext: true, compactContext: false, context,
        messages: [{ role: 'user', content: `${instructions}\n\nStudent ${mode === 'advice' ? 'question' : 'interests and goals'}:\n${command.interests.trim()}\n\nUse the supplied exam plan as reference data.` }],
      }, { provider: provider.id, apiKeys: { [provider.id]: key } },
      (text) => { if (streamed.length <= 200000) streamed += text; }, responseSignal, () => {});
        responseSignal.throwIfAborted();
        if (baseline !== current()) fail('Your exam dates or selections changed. Request a fresh recommendation.', 409);
        return result.text || streamed;
      };
      let degreePlans = null;
      if (catalogue) {
        let correction = '';
        for (let attempt = 0; attempt < 2; attempt++) {
          const selection = await reply(STUDY_PLAN_RETRIEVAL_INSTRUCTIONS + correction,
            JSON.stringify({ ...JSON.parse(input), degreeCatalogue: catalogue }));
          try { degreePlans = retrieveDegreeInformation(ntnuStudyPlans, selection, command.degreeSelections); break; }
          catch (error) {
            if (attempt) throw error;
            correction = '\nThe previous lookup was rejected: ' + error.message;
          }
        }
        input = JSON.stringify({ ...JSON.parse(input), degreePlans });
      }
      const instructions = (mode === 'advice' ? EXAM_ADVICE_INSTRUCTIONS + '\n' + EXAM_ADVICE_CONVERSATION_INSTRUCTIONS : EXAM_RECOMMENDATION_INSTRUCTIONS)
        + (degreePlans ? '\n' + STUDY_PLAN_INSTRUCTIONS : '');
      const result = await reply(instructions, input);
      return mode === 'advice' ? checkedExamAdvice(result) : checkedExamRecommendation(exams, result);
    } finally { account.examRecommendationBusy = false; }
  }

  async action(session, command) {
    const currentNavigation = this.registerNavigation(session, command);
    return this.serial(session.user_id, async () => {
      this.store.refreshNavigation(session);
      if (!currentNavigation()) fail('This navigation was superseded.', 409);
      const account = this.account(session.user_id),
        nav = session.navigation;
      if (['connect', 'index', 'downloadAll', 'import', 'saveDocument'].includes(command?.action))
        this.assertAvailable(account);
      if (!command || typeof command !== 'object' || Array.isArray(command))
        fail('Invalid action.');
      let course = this.course(account, nav);
      if (['draft', 'send', 'page'].includes(command.action))
        this.validateOwner(account, nav, command.owner);
      switch (command.action) {
        case 'examPlan': {
          let exams, baseline;
          try {
            exams = normalizeExamPlan(command.exams);
            baseline = normalizeExamPlan(command.baseExams);
          } catch (error) {
            fail(error.message);
          }
          if (
            JSON.stringify(baseline) !==
            JSON.stringify(normalizeExamPlan(account.library.examPlan || []))
          )
            fail('Your exam plan changed elsewhere. Reload the saved plan before saving.', 409);
          account.library.examPlan = exams;
          const favorites = new Set(examFavoriteCourseIDs(exams, account.library.courses));
          for (const course of account.library.courses) {
            if (favorites.has(course.id) && !course.favorite) {
              course.favorite = true;
              course.examFavorite = true;
            } else if (!favorites.has(course.id) && course.examFavorite) {
              course.favorite = false;
              course.examFavorite = false;
            }
          }
          break;
        }
        case 'create': {
          if (!String(command.name || '').trim()) fail('Enter a workspace name.');
          if (account.library.courses.length >= 500)
            fail('This account has reached its workspace limit.');
          const created = newCourse(
            String(command.name).trim().slice(0, 180),
            String(command.code || '').slice(0, 40)
          );
          account.library.courses.push(created);
          this.selectCourse(account, nav, created.id);
          break;
        }
        case 'library':
          nav.showingCourseLibrary = true;
          if (nav.courseLibraryView === 'assignments') nav.courseLibraryView = 'all';
          nav.selectedAssignmentID = null;
          break;
        case 'assignments':
          nav.showingCourseLibrary = true;
          nav.courseLibraryView = 'assignments';
          nav.selectedAssignmentID = null;
          break;
        case 'refreshAssignments':
          void this.refreshCanvasAssignments(account, Date.now(), true);
          break;
        case 'libraryView':
          nav.courseLibraryView = command.id === 'favorites' ? 'favorites' : 'all';
          break;
        case 'semester':
          nav.selectedSemesterID = String(command.id || 'all');
          break;
        case 'course':
          this.selectCourse(account, nav, command.id);
          break;
        case 'favorite': {
          const c =
            account.library.courses.find((c) => c.id === command.id) ||
            fail('Workspace not found.', 404);
          c.favorite = !c.favorite;
          c.examFavorite = false;
          break;
        }
        case 'askCourse':
        case 'materials':
          this.selectCourse(account, nav, nav.selectedCourseID);
          break;
        case 'openReading':
          await this.openReading(account, nav, command, currentNavigation);
          break;
        case 'document':
          await this.openReading(account, nav, { ...command, courseID: nav.selectedCourseID }, currentNavigation);
          break;
        case 'resume':
          await this.openReading(account, nav, command, currentNavigation);
          break;
        case 'page': {
          const doc =
            course?.documents.find((d) => d.id === nav.selectedDocumentID) ||
            fail('Open a document first.');
          nav.page = Math.max(1, Math.min(doc.pageCount, Math.floor(Number(command.page) || 1)));
          doc.lastPage = nav.page;
          doc.lastOpenedAt = now();
          nav.selection = '';
          break;
        }
        case 'source':
          await this.openReading(account, nav, { ...command, courseID: nav.selectedCourseID,
            page: Math.max(1, Math.floor(Number(command.page) || 1)), conversationPolicy: 'preserve' }, currentNavigation);
          break;
        case 'thread': {
          const thread =
            course?.threads.find((t) => t.id === command.id) ||
            fail('Conversation not found.', 404);
          nav.selectedThreadID = thread.id;
          nav.selectedDocumentID = thread.documentID;
          nav.selectedAssignmentID = thread.assignmentID || null;
          nav.mode = teachingModeLabel(thread.mode);
          break;
        }
        case 'newThread': {
          const scope = courseContextScope(this.thread(course, nav), nav);
          nav.selectedThreadID = null;
          const thread = this.thread(course, nav, true);
          if (scope === 'course') thread.documentID = thread.assignmentID = null;
          break;
        }
        case 'automaticContext':
          nav.automaticContextEnabled = command.enabled !== false;
          break;
        case 'context':
          nav.includeCourse = !!command.enabled;
          break;
        case 'studyModelMode':
          if (!STUDY_MODEL_MODES.includes(command.text)) fail('Unknown study model mode.');
          account.settings.studyModelMode = command.text;
          break;
        case 'reasoning': {
          const provider =
            hostedProviders.find((provider) => provider.id === account.settings.providerID) ||
            hostedProviders[0];
          const model = account.settings.modelID || provider.defaultModel;
          if (command.providerID !== provider.id || command.id !== model)
            fail('The model changed. Select a reasoning mode for the current model.', 409);
          if (!modelReasoning(provider, model)?.efforts.includes(command.text))
            fail('This reasoning mode is unavailable for the selected model.');
          account.settings.reasoningEfforts = {
            ...account.settings.reasoningEfforts,
            [provider.id]: command.text,
          };
          break;
        }
        case 'model': {
          const provider =
            hostedProviders.find((p) => p.id === command.providerID) ||
            fail('Provider unavailable.');
          if (!provider.models.some((m) => (typeof m === 'string' ? m : m.id) === command.id))
            fail('Unknown model.');
          account.settings.providerID = provider.id;
          account.settings.modelID = command.id;
          break;
        }
        case 'credentials': {
          const provider =
            hostedProviders.find((p) => p.id === command.providerID) ||
            fail('Provider unavailable.');
          if (typeof command.key !== 'string' || command.key.length > 4096)
            fail('Invalid API key.');
          this.store.credential(account.id, `provider:${provider.id}`, command.key.trim());
          account.settings.providerID = provider.id;
          account.settings.modelID = provider.defaultModel;
          account.status = `${provider.name} settings saved.`;
          break;
        }
        case 'clearError':
          account.error = null;
          break;
        case 'stop':
        case 'cancelSync':
          account.controller?.abort();
          break;
        case 'import': {
          if (!course || typeof command.data !== 'string')
            fail('Open a workspace before importing.');
          const data = Buffer.from(command.data, 'base64');
          this.job(account, 'Importing document…', async () => {
            await this.importFile(account, course, command.name, data);
            account.status = 'Document saved to your workspace.';
          });
          break;
        }
        case 'connect':
        case 'index':
        case 'downloadAll': {
          if (command.action === 'connect') {
            if (
              typeof command.token !== 'string' ||
              !command.token.trim() ||
              command.token.length > 4096
            )
              fail('Enter a valid Canvas access token.');
            const candidate = new Canvas(command.origin, command.token.trim(), {
              hosts: this.options.canvasHosts,
              request: this.options.remoteRequest,
            });
            const user = await candidate.account();
            this.store.credential(account.id, `canvas:${candidate.origin}`, command.token.trim());
            account.library.canvasOrigin = candidate.origin;
            account.library.canvasUserID = user.id;
            account.library.canvasUserName = user.name;
          }
          const requested = command.id;
          this.job(account, 'Checking Canvas…', async (signal) => {
            const canvas = this.canvas(account, signal),
              user = await canvas.account();
            for (const remote of await canvas.courses()) {
              if (remote.access_restricted_by_date) continue;
              let c = account.library.courses.find(
                (c) =>
                  c.canvasID === remote.id &&
                  c.canvasOrigin === canvas.origin &&
                  c.canvasUserID === user.id
              );
              if (!c) {
                if (account.library.courses.length >= 500)
                  fail('This account has reached its workspace limit.');
                c = newCourse(remote.name || `Course ${remote.id}`, remote.course_code || '');
                account.library.courses.push(c);
              }
              Object.assign(c, {
                canvasID: remote.id,
                canvasOrigin: canvas.origin,
                canvasUserID: user.id,
                term: remote.term?.name,
              });
              if (requested && requested !== c.id) continue;
              signal.throwIfAborted();
              account.status = `Checking ${c.code || c.name}…`;
              const checkedAt = Date.now();
              beginPoll(c, 'canvas', checkedAt, 'regular');
              this.store.save(account);
              let catalog;
              try { catalog = await canvas.catalog(c); }
              catch (error) { signal.throwIfAborted(); observePoll(c, 'canvas', [], false, checkedAt); throw error; }
              observeCatalog(c, catalog, checkedAt);
              c.canvasMaterials = catalog.items;
              c.catalogWarnings = catalog.warnings;
              c.catalogChanges = catalog.changes;
              c.catalogUpdatedAt = now();
              if (command.action === 'downloadAll' || command.enabled)
                for (const ref of c.canvasMaterials) {
                  signal.throwIfAborted();
                  if (!ref.assignment?.locked && (ref.byteCount || 0) <= 100_000_000) {
                    try {
                      await this.fetchMaterial(account, c, ref, canvas);
                    } catch (error) {
                      signal.throwIfAborted();
                      c.catalogWarnings.push(`${ref.title}: ${error.message}`);
                    }
                  }
                }
              this.store.save(account);
            }
            account.library.canvasCheckedAt = now();
            account.status = 'Canvas is up to date.';
          });
          break;
        }
        case 'material': {
          const ref =
            course?.canvasMaterials.find((r) => r.id === command.id) ||
            fail('Material not found.', 404);
          const cached = course.documents.find(
            (d) => d.sourceKey === ref.id && d.sourceVersion === ref.version && !needsCanvasHTMLUpgrade(d)
          );
          if (!cached) this.assertAvailable(account);
          const doc =
            cached || (await this.fetchMaterial(account, course, ref, this.canvas(account)));
          this.selectDocument(course, nav, doc.id);
          break;
        }
        case 'assignmentVisibility': {
          const c =
            account.library.courses.find((c) => c.id === command.courseID) ||
            fail('Workspace not found.', 404);
          if (!c.canvasMaterials.some((m) => m.id === command.id && m.kind === 'assignments'))
            fail('Assignment not found.', 404);
          const hidden = new Set(c.hiddenAssignmentIDs || []);
          if (command.enabled) hidden.add(command.id);
          else hidden.delete(command.id);
          c.hiddenAssignmentIDs = [...hidden];
          break;
        }
        case 'assignment':
        case 'assignmentPDF':
        case 'assignmentFile':
          await this.openAssignment(account, nav, command);
          break;
        case 'edit': {
          const thread = this.thread(course, nav),
            index =
              thread?.messages.findIndex((m) => m.id === command.id && m.role === 'user') ?? -1;
          if (index < 0 || account.streaming) fail('Message cannot be edited.');
          nav.editing = command.id;
          thread.draft = thread.messages[index].content;
          thread.draftImage = thread.messages[index].imageData || null;
          thread.draftFiles = normalizeFileAttachments(thread.messages[index].files);
          break;
        }
        case 'cancelEdit':
          nav.editing = null;
          break;
        case 'workspaceMemory': {
          const target = account.library.courses.find((item) => item.id === command.courseID);
          if (!target) fail('Workspace not found.', 404);
          saveWorkspaceMemory(target, command.assignmentID || null, command.text, command.documentIDs);
          break;
        }
        case 'language': {
          if (!['auto', 'en', 'no'].includes(command.text)) fail('Unknown response language.');
          account.settings.language = command.text;
          break;
        }
        case 'draft':
        case 'send': {
          if (!course) fail('Open a workspace first.');
          const thread = this.thread(course, nav, true);
          thread.draft = String(command.text || '').slice(0, 200000);
          if (Array.isArray(command.files)) thread.draftFiles = await this.attachmentCorpus.retain(account, command.files,
            [...thread.messages.flatMap((message) => message.files || []), ...(thread.draftFiles || [])]);
          if (typeof command.automaticContextEnabled === 'boolean') nav.automaticContextEnabled = command.automaticContextEnabled;
          nav.selection = String(command.selection || '').slice(0, 16000);
          if (command.mode) nav.mode = teachingModeLabel(command.mode);
          thread.mode = nav.mode || 'Explain';
          if (typeof command.entirePDF === 'boolean') thread.entirePDF = command.entirePDF;
          if (command.image) {
            if (command.image.length > 14_000_000 || !/^[A-Za-z0-9+/=\s]+$/.test(command.image))
              fail('Invalid question image.');
            thread.draftImage = command.image;
          } else if (command.clearImage) thread.draftImage = null;
          if (command.action === 'send') {
            if (!thread.draft.trim() && !thread.draftImage && !thread.draftFiles?.some((file) => file.enabled) && !nav.selection.trim()) fail('Enter a question, attach a file, or select a passage.');
            this.assertAvailable(account);
            if (thread.messages.length >= 400) fail('Start a new conversation to continue.');
            const provider =
              hostedProviders.find((p) => p.id === account.settings.providerID) ||
              hostedProviders[0];
            const selectedModel = account.settings.modelID || provider.defaultModel;
            const selectedEffort = reasoningEffort(provider, selectedModel, account.settings);
            const studyMode = normalizeStudyModelMode(account.settings.studyModelMode);
            const key = this.store.credential(account.id, `provider:${provider.id}`);
            if (!key && !this.options.complete)
              fail('Add your provider API key in Account settings.');
            if (nav.editing) {
              const at = thread.messages.findIndex((m) => m.id === nav.editing);
              if (at < 0) fail('Edited message no longer exists.');
              thread.messages.splice(at);
              nav.editing = null;
            }
            const question = thread.draft.trim() || (nav.selection.trim()
                ? `Explain this passage in its document context:\n\n> ${nav.selection.replaceAll('\n', '\n> ')}`
                : thread.draftFiles?.some((file) => file.enabled) ? 'Help me understand the attached files. Ask for any missing information needed to explain the project accurately.' : 'Explain this image in its document context.'),
              image = thread.draftImage,
              files = normalizeFileAttachments((thread.draftFiles || []).filter((file) => file.enabled !== false)),
              automaticContextEnabled = nav.automaticContextEnabled !== false,
              selection = nav.selection,
              page = nav.page || 1,
              contextScope = courseContextScope(thread, nav),
              includeCourse = contextScope === 'course' || nav.includeCourse === true,
              mode = nav.mode,
              language = account.settings.language || 'auto',
              entirePDF = automaticContextEnabled && thread.entirePDF === true,
              doc = course.documents.find((d) => d.id === nav.selectedDocumentID),
              assignment = course.canvasMaterials.find(
                (ref) =>
                  ref.kind === 'assignments' &&
                  ref.id === (thread.assignmentID || nav.selectedAssignmentID)
              );
            if (entirePDF && (!doc || ['image', 'preview'].includes(doc.kind) || contextScope === 'course')) fail('Open a readable document conversation to send the whole document.');
            thread.messages.push({
              id: randomUUID(),
              role: 'user',
              content: question,
              imageData: image,
              files,
              createdAt: now(),
            });
            if (thread.messages.length === 1)
              thread.title = question.slice(0, 60) || 'Image question';
            thread.draft = '';
            thread.draftImage = null;
            thread.draftFiles = [];
            const reply = {
              id: randomUUID(),
              role: 'assistant',
              content: '',
              isStreaming: true,
              metadata: 'Finding relevant course sources…',
              createdAt: now(),
              activity: [],
            };
            const activity = (title, detail) => {
              if (reply.activity.at(-1)?.title === title && reply.activity.at(-1)?.detail === detail) return;
              reply.activity.push({ id: randomUUID(), timestamp: now(), title: String(title).slice(0, 180), ...(detail ? { detail: String(detail).slice(0, 2000) } : {}) });
              if (reply.activity.length > 80) reply.activity.shift();
            };
            activity('Finding relevant course sources…');
            thread.messages.push(reply);
            this.job(
              account,
              'Finding relevant course sources…',
              async (signal) => {
                try {
                  const assigned =
                    automaticContextEnabled && contextScope === 'assignment' && assignment && !entirePDF
                      ? await this.assignmentContext(
                          account,
                          course,
                          assignment,
                          question,
                          doc,
                          page,
                          thread.messages.filter((message) => message.role === 'user').slice(0, -1).map((message) => message.content),
                          signal
                        )
                      : { context: '', sources: [], documentIDs: new Set() };
                  const memory = automaticContextEnabled && (includeCourse || contextScope === 'assignment') ? await buildWorkspaceMemory({ course, assignmentID: contextScope === 'assignment' ? assignment?.id : null,
                    question, readIndex: (document) => this.documents.index(account.id, document), signal }) : { context: '', sources: [] };
                  let fullPDF;
                  if (entirePDF) {
                    activity('Reading whole document', `${doc.title} · ${doc.pageCount} pages`);
                    const index = await this.documents.index(account.id, doc);
                    const pages = new Map(index.pages.map((page) => [page.number, page.text]));
                    fullPDF = entirePdfContext({ title: doc.title, kind: doc.kind, pageCount: doc.pageCount,
                      pages: Array.from({ length: doc.pageCount }, (_, index) => pages.get(index + 1)) });
                    fullPDF.sources = index.pages.map((page) => ({ documentID: doc.id, title: doc.title, page: page.number }));
                    activity(fullPDF.summary);
                  }
                  const supplemental = fullPDF || (
                    automaticContextEnabled && (includeCourse || (doc && !assigned.documentIDs.has(doc.id)))
                      ? await buildCourseContext({
                          course,
                          question,
                          previousQuestions: thread.messages.filter((message) => message.role === 'user').slice(0, -1).map((message) => message.content),
                          readIndex: (document) => this.documents.index(account.id, document),
                          selectedDocument: contextScope === 'course' ? null : doc,
                          selectedPage: page,
                          includeCourse,
                          includeMetadata: includeCourse,
                          excludedIDs: assigned.documentIDs,
                          signal,
                          maxChars: assigned.context ? 24_000 : 48_000,
                        })
                      : { context: '', sources: [] });
                  const context = memory.context + assigned.context + supplemental.context,
                    sources = [...new Map([...memory.sources, ...assigned.sources, ...supplemental.sources]
                      .map((source) => [`${source.documentID}:${source.page}`, source])).values()];
                  signal.throwIfAborted();
                  const route = routeStudyModel({
                    mode: studyMode, providerID: provider.id, selectedModel,
                    reasoningEffort: selectedEffort, availableModels: provider.models,
                    question, previousQuestions: thread.messages.filter((m) => m.role === 'user').slice(0, -1).map((m) => m.content),
                    contextCharacters: context.length + thread.messages.reduce((total, message) => total + message.content.length, 0),
                    hasImages: thread.messages.some((m) => !!m.imageData),
                  });
                  const model = route.modelID, effort = route.reasoningEffort;
                  if (studyMode !== 'manual') {
                    reply.modelRouting = route;
                    activity('Study model selected', studyRouteDescription(route));
                  }
                  thread.sources[reply.id] = sources;
                  for (const source of sources) activity('Read saved file', `${source.title} · page ${source.page}`);
                  const requestMessages = [];
                  let attachmentBudget = 96_000;
                  const previousQuestions = thread.messages.filter((message) => message.role === 'user').slice(0, -1).map((message) => message.content);
                  for (const message of [...thread.messages].reverse()) {
                    if (message === reply) continue;
                    const selectedFiles = message.files?.length
                      ? await this.attachmentCorpus.select(account.id, message.files, { question, previousQuestions, budget: attachmentBudget }) : [];
                    attachmentBudget = Math.max(0, attachmentBudget - selectedFiles.reduce((sum, file) => sum + file.text.length, 0));
                    for (const file of selectedFiles) activity('Read attached file', `${file.name} · ${file.contextCoverage || `All ${file.text.length} saved text characters supplied.`}`);
                    requestMessages.unshift({ role: message.role, content: message.content,
                      ...(selectedFiles.length ? { files: selectedFiles } : {}),
                      ...(message.imageData ? { imageDataUrl: `data:image/jpeg;base64,${message.imageData}` } : {}) });
                  }
                  reply.metadata = `Sources ready · Waiting for ${model}…`;
                  activity(reply.metadata);
                  const payload = {
                    provider: provider.id,
                    model,
                    reasoningEffort: effort,
                    kind: image ? 'image' : 'text',
                    selection,
                    context,
                    pageTitle: automaticContextEnabled ? contextScope === 'course' ? course.name : doc?.title || course.name : '',
                    learningMode: mode,
                    language,
                    entirePDF,
                    entireDocument: entirePDF && doc?.kind !== 'pdf',
                    messages: requestMessages,
                  };
                  const responseSignal = AbortSignal.any([signal, AbortSignal.timeout(300_000)]);
                  const result = await (this.options.complete || runCompletion)(
                    payload,
                    { provider: provider.id, apiKeys: { [provider.id]: key } },
                    (text) => {
                      if (responseSignal.aborted) return;
                      reply.content += text;
                      reply.metadata = 'Writing answer…';
                      activity(reply.metadata);
                    },
                    responseSignal,
                    () => {
                      if (!responseSignal.aborted && !reply.content) { reply.metadata = 'Model is reasoning…'; activity(reply.metadata); }
                    },
                    (event) => { if (!responseSignal.aborted) activity(event.title, event.detail); }
                  );
                  responseSignal.throwIfAborted();
                  reply.content = result.text || reply.content;
                  if (!reply.content.trim())
                    throw new Error(
                      'The model returned an empty response. Try again or select another model.'
                    );
                  reply.reasoning = result.reasoning || undefined;
                  account.settings.recentModels = recordRecentModel(account.settings.recentModels, provider.id, model);
                  reply.metadata = `${model} · ${sources.length} source pages`;
                  account.status = 'Answer saved.';
                  activity('Answer complete', model);
                } catch (error) {
                  reply.metadata = signal.aborted ? 'Stopped' : 'Response interrupted';
                  activity(reply.metadata);
                  if (error.name === 'TimeoutError')
                    throw new Error('The model timed out after 5 minutes. Try again, reduce reasoning effort, or choose another model.');
                  throw error;
                } finally {
                  reply.isStreaming = false;
                }
              },
              true
            );
          }
          break;
        }
        case 'saveDocument':
          await this.saveEdit(account, course, command.edit, nav);
          break;
        default:
          fail('This action is unavailable on the hosted service.');
      }
      if (!sessionOnlyActions.has(command.action)) this.store.save(account);
      this.store.navigate(session);
      return this.state(session);
    });
  }
  async edit(account, id) {
    const doc = this.doc(account, id),
      data = await this.documents.data(account.id, doc),
      revision = hash(data);
    if (!['text', 'code', 'notebook'].includes(doc.kind)) fail('This file cannot be edited.');
    if (doc.kind === 'notebook')
      return {
        documentID: id,
        revision,
        cells: JSON.parse(data).cells.map((c, i) => ({
          id: i,
          kind: c.cell_type,
          source: Array.isArray(c.source) ? c.source.join('') : c.source || '',
        })),
      };
    return { documentID: id, revision, source: data.toString('utf8') };
  }
  async saveEdit(account, course, draft, nav) {
    const doc =
      course?.documents.find((d) => d.id === draft?.documentID) || fail('Document not found.', 404);
    const original = await this.documents.data(account.id, doc);
    if (hash(original) !== draft.revision)
      fail('The document changed. Copy your edits before reloading.', 409);
    let data;
    if (doc.kind === 'notebook') {
      const notebook = JSON.parse(original);
      if (
        draft.cells?.length !== notebook.cells.length ||
        draft.cells.some((c, i) => c.id !== i || typeof c.source !== 'string')
      )
        fail('Notebook cells changed.');
      draft.cells.forEach((c, i) => {
        notebook.cells[i].source = c.source;
      });
      data = Buffer.from(JSON.stringify(notebook));
    } else if (['text', 'code'].includes(doc.kind) && typeof draft.source === 'string')
      data = Buffer.from(draft.source);
    else fail('Unsupported edit.');
    if (
      (account.settings.storageBytes || 0) + data.length >
      (this.options.quotaBytes || 2_000_000_000)
    )
      fail('This account has reached its file storage limit.');
    const changed = await this.documents.import(account.id, doc.fileName, data, {
      allowEmpty: true,
    });
    // Keep document identity stable; atomically switch its storage pointer after indexing.
    // Previous originals remain on disk as revisions and count toward the account quota.
    Object.assign(doc, {
      ...changed,
      id: doc.id,
      storageID: changed.id,
      title: doc.title,
      sourceKey: doc.sourceKey,
      sourceURL: doc.sourceURL,
      sourceVersion: doc.sourceVersion,
      locallyEditedAt: now(),
      byteCount: data.length,
    });
    account.settings.storageBytes = (account.settings.storageBytes || 0) + data.length;
  }
  async stop() {
    this.stopping = true;
    for (const account of this.accounts.values()) account.assignmentRefreshController?.abort();
    await Promise.allSettled([...this.accounts.values()].map((account) => account.assignmentRefresh));
    for (const account of this.accounts.values()) account.controller?.abort();
    await Promise.allSettled([...this.queues.values()]);
    for (const account of this.accounts.values()) account.controller?.abort();
    await Promise.allSettled([...this.accounts.values()].map((account) => account.job));
    await Promise.allSettled([...this.analysisJobs.values()]);
    await this.search.close();
  }
}
