import { escapeHtml as esc } from '../chrome/src/html-escape.js';

// Native JSON object keys have no ordering guarantee. Equivalent responses must
// produce the same render key, or idle polling would disturb text selections.
export function studyRenderKey(value) {
  return JSON.stringify(value, (_key, item) =>
    item && typeof item === 'object' && !Array.isArray(item)
      ? Object.fromEntries(
          Object.keys(item)
            .sort()
            .map((key) => [key, item[key]])
        )
      : item
  );
}

export const teachingModes = [
  {
    mode: 'Explain',
    title: 'Explain the key idea',
    summary: 'Clear explanations and step-by-step help when you need it.',
  },
  {
    mode: 'Practice',
    title: 'Check my understanding',
    summary: 'Try a question, then get feedback on your answer.',
  },
  {
    mode: 'General',
    title: 'Talk through an idea',
    summary: 'Direct answers and open conversation, with your course as context.',
  },
];

export const coursePrompts = [
  {
    id: 'overview',
    title: 'Give me a course overview',
    question:
      'Give me an overview of this course: its main topics, available materials, and how the topics connect. Distinguish saved content from catalog-only information.',
  },
  {
    id: 'deadlines',
    title: 'What’s due next?',
    question:
      "What's due next in this course? Use the saved submission status; flag dates that need a Canvas refresh.",
  },
  {
    id: 'plan',
    title: 'Help me plan my studying',
    question:
      'Help me make a study plan for this course using the available topics, readings, and deadlines. Suggest an order and ask what you need to know about my goals.',
  },
];

export function conversationScope(state) {
  if (state.contextScope) return state.contextScope;
  const course = state.library.courses.find(
    (course) => course.id === state.library.selectedCourseID
  );
  const thread = course?.threads.find((thread) => thread.id === state.library.selectedThreadID);
  if (thread) return thread.assignmentID ? 'assignment' : thread.documentID ? 'document' : 'course';
  return state.library.selectedAssignmentID
    ? 'assignment'
    : state.library.selectedDocumentID
      ? 'document'
      : 'course';
}

export function courseCoverage(course) {
  if (!course) return '';
  const saved = new Set(course.documents.map((document) => document.sourceKey));
  const remote = (course.canvasMaterials || []).filter(
    (material) => !saved.has(material.id)
  ).length;
  const readable = course.documents.filter(
    (document) =>
      document.kind !== 'preview' &&
      !document.indexUnavailable &&
      (document.unreadablePages || 0) < (document.pageCount || 1)
  ).length;
  return `${readable} saved reading${readable === 1 ? '' : 's'} with text${remote ? ` · ${remote} material${remote === 1 ? '' : 's'} with titles only until opened` : ''}.`;
}

export function readingSourceSummary(sources = []) {
  const groups = new Map();
  for (const source of sources) {
    if (!source?.title || !Number.isInteger(source.page) || source.page < 1) continue;
    const key = source.documentID || source.title;
    if (!groups.has(key)) groups.set(key, { title: source.title, pages: new Set() });
    groups.get(key).pages.add(source.page);
  }
  return [...groups.values()].map(({ title, pages }) => {
    const ordered = [...pages].sort((a, b) => a - b), ranges = [];
    for (let index = 0; index < ordered.length; index++) {
      const first = ordered[index];
      let last = first;
      while (ordered[index + 1] === last + 1) last = ordered[++index];
      ranges.push(first === last ? String(first) : `${first}–${last}`);
    }
    return `${title} · ${pages.size === 1 ? 'p.' : 'pp.'} ${ranges.join(', ')}`;
  }).join('; ');
}

export function studyPrompt(mode, document) {
  if (mode === 'General' || mode === 'Chat') return 'Help me brainstorm and talk through an idea.';
  const scope = !document
    ? 'the downloaded course materials'
    : document.kind === 'notebook'
      ? 'this notebook cell'
      : ['code', 'office'].includes(document.kind)
        ? 'this section'
        : 'this page';
  if (mode === 'Guide me')
    return `Help me work through an example from ${scope}, one step at a time. Start with a hint and wait for my attempt.`;
  if (mode === 'Practice')
    return `Ask me one question to test my understanding of ${scope}. Wait for my answer before giving feedback or a solution.`;
  return `Explain the key idea in ${scope}, with an intuitive example.`;
}

export function appendStudyPrompt(draft, prompt) {
  if (!draft.trim()) return prompt;
  return draft.includes(prompt) ? draft : `${draft}\n\n${prompt}`;
}

export function recentReadings(courses, limit = 3) {
  const count = Math.max(0, Math.floor(limit));
  if (!count) return [];
  // The dashboard needs only a few readings. Keep that small ordered window
  // instead of allocating and sorting every saved document on each poll.
  const recent = [];
  const compare = (a, b) => b.lastOpenedAt - a.lastOpenedAt || a.id.localeCompare(b.id);
  for (const course of courses) {
    for (const document of course.documents) {
      if (!Number.isFinite(document.lastOpenedAt)) continue;
      if (recent.length === count && compare(document, recent.at(-1).document) >= 0) continue;
      const position = recent.findIndex((item) => compare(document, item.document) < 0);
      recent.splice(position < 0 ? recent.length : position, 0, { course, document });
      if (recent.length > count) recent.pop();
    }
  }
  return recent;
}

export function readingPosition(document) {
  const count = Math.max(1, document.pageCount || 1),
    page = Math.min(count, Math.max(1, document.lastPage || 1));
  const unit =
    document.kind === 'notebook'
      ? 'Cell'
      : ['code', 'office'].includes(document.kind)
        ? 'Section'
        : 'Page';
  return `${unit} ${page} of ${count}`;
}

export function continueReadingMarkup(readings) {
  if (!readings.length) return '';
  return `<section class="continue-reading" aria-label="Continue reading"><div class="continue-heading"><h2>Continue reading</h2><span>Your place is saved</span></div>
    <div class="recent-readings">${readings
      .map(
        ({
          course,
          document,
        }) => `<button class="recent-reading" data-action="resume" data-id="${esc(document.id)}" aria-label="Resume ${esc(document.title)}, ${esc(readingPosition(document).toLowerCase())}">
      <span class="recent-course">${esc(course.code || course.name)}<span aria-hidden="true">↗</span></span>
      <strong>${esc(document.title)}</strong><span class="recent-position">${esc(readingPosition(document))}</span>
    </button>`
      )
      .join('')}</div></section>`;
}

// Reading surfaces depend on their content, not on chat drafts, tokens, or last-open times.
export function readerRenderKey(state) {
  const course = state.library.courses.find((c) => c.id === state.library.selectedCourseID);
  const document = course?.documents.find((d) => d.id === state.library.selectedDocumentID);
  if (!document)
    return studyRenderKey([
      false,
      course?.id,
      course?.name,
      course?.code,
      course?.canvasID,
      course?.catalogUpdatedAt,
      course?.catalogChanges,
      course?.hiddenAssignmentIDs,
      course?.documents,
      state.materialGroups,
      state.materialFiles,
      state.busy,
      state.library.selectedAssignmentID,
      course?.canvasID
        ? [
            course.canvasMaterials?.filter((m) => m.kind === 'assignments'),
            Math.floor(Date.now() / 60000),
          ]
        : null,
    ]);
  const { lastOpenedAt, lastPage, classification, materialAnalysis, ...content } = document;
  return studyRenderKey([
    false,
    course.id,
    content,
    state.page,
    state.pageText,
    !!state.loadingDocument,
  ]);
}

export function studyPollDelay(state, hidden = false, failed = false) {
  if (hidden) return 15000;
  if (failed) return 6000;
  if (state?.loadingDocument) return 450;
  return state?.streaming ? 650 : (state?.busy || state?.assignmentPreparing) ? 1200 : 3500;
}
