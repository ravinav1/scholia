// Synthetic audit: no accounts, live Canvas endpoints, or user storage are used.
// Measurements are diagnostic observations, not regression-test assertions.
import { performance } from 'node:perf_hooks';
import { buildCanvasCourseIndex } from '../../apps/chrome/src/canvas-course.js';
import { saveChat, listChats, pruneChatHistory } from '../../apps/chrome/src/chat/chat-history.js';
import { courseLibraryRenderKey, courseLibraryMarkup } from '../../apps/web/workspace/course-library.js';
import { renderMarkdown } from '../../apps/chrome/src/render.js';
import { buildPdfSemanticIndex, findPdfMatches, findPdfSemanticMatches } from '../../apps/chrome/src/pdf/pdf-search.js';
import { packPageContext } from '../../packages/core/src/context.js';

const results = [];
function record(name, values) { results.push({ name, ...values }); }
function measure(name, work, iterations = 15) {
  work();
  const times = [];
  let output;
  for (let i = 0; i < iterations; i++) { const start = performance.now(); output = work(); times.push(performance.now() - start); }
  times.sort((a, b) => a - b);
  record(name, { medianMs: times[Math.floor(times.length / 2)], p95Ms: times[Math.ceil(times.length * .95) - 1], outputCharacters: typeof output === 'string' ? output.length : undefined });
}
const course = { origin: 'https://canvas.example.test', courseId: '42', url: 'https://canvas.example.test/courses/42' };
let filesFail = false, changedFileFails = false, fileVersion = 'v1', due = '2026-10-01T12:00:00Z';
const options = {
  course, userId: 'fixture', courseInfo: { name: 'Synthetic course', syllabus_body: 'A syllabus' },
  htmlToText: (html) => html,
  list: async (path) => {
    if (path.endsWith('/pages')) return [{ url: 'lecture', title: 'Lecture', updated_at: 'v1' }];
    if (path.endsWith('/files')) { if (filesFail) throw new Error('HTTP 503'); return [{ id: 1, display_name: 'Reading.txt', updated_at: fileVersion }]; }
    if (path.endsWith('/assignments')) return [{ id: 2, name: 'Exercise', description: 'Solve the exercise', updated_at: 'v1', due_at: due }];
    return [];
  },
  get: async () => ({ body: 'Lecture body' }),
  readFile: async () => { if (changedFileFails) throw new Error('Temporary download failure'); return 'A previously available reading'; }
};
const initial = await buildCanvasCourseIndex(options);
filesFail = true;
const partial = await buildCanvasCourseIndex({ ...options, previous: initial });
record('canvas.failedCollection', { initialKeys: initial.documents.map((d) => d.key), refreshedKeys: partial.documents.map((d) => d.key), partial: partial.partial, failedCollections: partial.failedCollections });
filesFail = false; changedFileFails = true; fileVersion = 'v2';
const changed = await buildCanvasCourseIndex({ ...options, previous: initial });
record('canvas.failedChangedDownload', { previousReadingRetained: changed.documents.some((d) => d.key === 'file:1'), skipped: changed.skipped });
changedFileFails = false; fileVersion = 'v1'; due = '2026-10-08T12:00:00Z';
const moved = await buildCanvasCourseIndex({ ...options, previous: initial });
record('canvas.deadlineOnlyChange', { requestedDue: due, indexedText: moved.documents.find((d) => d.key === 'assignment:2').text, reused: moved.reused });

let storageValues = {};
const area = {
  async get(key) { return structuredClone({ [key]: storageValues[key] }); },
  async set(value) { Object.assign(storageValues, structuredClone(value)); },
};
function chat(id, updatedAt = 1, content = 'A response') {
  return { id, createdAt: 1, updatedAt, capture: { context: 'A source', pageTitle: 'Synthetic reading' }, messages: [{ role: 'user', content: 'Question' }, { role: 'assistant', content }] };
}
await Promise.all([saveChat(chat('first'), area), saveChat(chat('second'), area)]);
record('chat.concurrentSaves', { attempted: 2, retained: (await listChats(area)).map((c) => c.id) });
storageValues = {};
await saveChat(chat('same', 20, 'New response'), area);
await saveChat(chat('same', 10, 'Old response'), area);
record('chat.staleWriter', { retainedUpdatedAt: (await listChats(area))[0].updatedAt, retainedResponse: (await listChats(area))[0].messages.at(-1).content });

const history = Array.from({ length: 24 }, (_, i) => chat(String(i), i + 1, 'A long response. '.repeat(1400)));
measure('chat.normalize24Histories', () => pruneChatHistory(history));
for (const size of [2000, 12000, 24000]) {
  const markdown = ('## Explanation\n\nA useful equation $x^2+y^2=z^2$.\n\n```js\nconst answer = 42;\n```\n\n').repeat(Math.ceil(size / 82)).slice(0, size);
  measure(`markdown.${size}characters`, () => renderMarkdown(markdown), 10);
}
for (const count of [250, 1000]) {
  const pages = Array.from({ length: count }, (_, i) => `Page ${i + 1}. ` + 'Eigenvectors preserve directions. Matrix decomposition transforms a basis. Orthogonal vectors and eigenvalues explain the linear map. '.repeat(15));
  record(`pdf.${count}pages.size`, { characters: pages.reduce((sum, page) => sum + page.length, 0) });
  measure(`pdf.${count}pages.semanticIndex`, () => buildPdfSemanticIndex(pages), 3);
  const index = buildPdfSemanticIndex(pages);
  measure(`pdf.${count}pages.exactSearch`, () => findPdfMatches(pages, 'Eigenvectors preserve'), 10);
  measure(`pdf.${count}pages.semanticSearch`, () => findPdfSemanticMatches(pages, 'How do eigenvalues explain a linear map?', index), 10);
  measure(`pdf.${count}pages.contextPacking`, () => packPageContext(pages.join('\n\n'), { question: 'How do eigenvectors preserve directions?', maxChars: 6000 }), 5);
}
for (const count of [6, 89, 300]) {
  const courses = Array.from({ length: count }, (_, i) => ({ id: `c${i}`, name: `Course ${i}`, code: `TEST${i}`, term: '2026 HØST', favorite: i < 4, documents: [], threads: [], canvasID: i + 1, canvasOrigin: course.origin, canvasMaterials: Array.from({ length: 32 }, (_, j) => ({ id: `pages:${j}`, kind: 'pages', remoteID: String(j), title: `Reading ${j}`, sourceURL: `${course.url}/pages/${j}`, version: 'v1' })), catalogUpdatedAt: 800000000 }));
  const state = { library: { courses, courseLibraryView: 'all' }, selectedSemesterID: 'all', semesters: [{ id: '2026-autumn', title: 'Autumn 2026', courseIDs: courses.map((c) => c.id) }], showingLibrary: true, messages: [], sources: {}, models: [], warnings: [], mode: 'Explain' };
  record(`web.${count}courses.payload`, { bytes: Buffer.byteLength(JSON.stringify(state)) });
  measure(`web.${count}courses.renderKey`, () => courseLibraryRenderKey(state));
  measure(`web.${count}courses.markup`, () => courseLibraryMarkup(state));
}
console.log(JSON.stringify({ environment: { node: process.version, platform: process.platform, arch: process.arch }, results }, null, 2));
