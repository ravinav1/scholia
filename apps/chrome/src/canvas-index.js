import { buildCanvasCourseIndex, canvasCourseContext, canvasCourseFromUrl, canvasIndexKey, canvasNextPage, CANVAS_INDEX_MAX_AGE, MAX_COURSE_ITEMS } from './canvas-course.js';
import { readCanvasIndex, saveCanvasIndex, deleteCanvasIndex } from './canvas-index-store.js';
import { extractPdfContext } from './pdf/pdf-context.js';
import { readChatFile, MAX_FILE_BYTES } from './file-input.js';
import { extractOfficeText } from './office-text.js';
import { canvasDocumentLinks } from '../../../packages/core/src/canvas-links.js';
import { researchLinksFromDocument } from './research-links.js';

function htmlToText(html) {
  const doc = new DOMParser().parseFromString(String(html), 'text/html');
  for (const node of doc.querySelectorAll('script,style,iframe,form')) node.remove();
  for (const node of doc.querySelectorAll('p,div,li,br,h1,h2,h3,h4,tr')) node.append('\n');
  return doc.body.textContent.replace(/\n[ \t]+/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}

async function boundedBlob(response, limit) {
  if (!response.ok) throw Object.assign(new Error(`Canvas returned HTTP ${response.status}.`), { status: response.status });
  if (Number(response.headers.get('content-length')) > limit) throw new Error('Course file exceeds the size limit.');
  const reader = response.body.getReader();
  const chunks = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) { await reader.cancel(); throw new Error('Course file exceeds the size limit.'); }
    chunks.push(value);
  }
  return new Blob(chunks, { type: response.headers.get('content-type') || '' });
}

export async function loadCanvasCourseIndex(url, { force = false, clear = false, signal, onProgress = () => {}, approveFile } = {}) {
  signal?.throwIfAborted();
  const course = canvasCourseFromUrl(url);
  if (!course) throw new Error('Open a Canvas course page first.');
  const requestSignal = () => signal
    ? AbortSignal.any([signal, AbortSignal.timeout(20_000)]) : AbortSignal.timeout(20_000);
  // Verify the current account and course access even when reading a fresh cache.
  const request = async (path) => {
    const target = new URL(path, course.origin);
    if (target.origin !== course.origin || !target.pathname.startsWith('/api/v1/')) throw new Error('Invalid Canvas API address.');
    const response = await fetch(target.href, { credentials: 'include', signal: requestSignal(), headers: { Accept: 'application/json' }, redirect: 'error' });
    if (!response.ok) throw Object.assign(new Error(`Canvas access failed (HTTP ${response.status}). Open the course and sign in, then retry.`), { status: response.status });
    if (!String(response.headers.get('content-type')).includes('json')) throw new Error('Canvas returned a sign-in page. Open the course and sign in, then retry.');
    const blob = await boundedBlob(response, 4 * 1024 * 1024);
    const data = JSON.parse(await blob.text());
    return { data, next: canvasNextPage(response.headers.get('link'), target.href, course) };
  };
  const get = async (path) => (await request(path)).data;
  const [user, info] = await Promise.all([
    get('/api/v1/users/self'), get(`/api/v1/courses/${course.courseId}?include[]=syllabus_body`)
  ]);
  if (!user.id || String(info.id) !== course.courseId) throw new Error('Canvas could not verify access to this course.');
  const key = canvasIndexKey(course, user.id);
  if (clear) { await deleteCanvasIndex(key); return null; }
  const previous = await readCanvasIndex(key).catch(() => null);
  signal?.throwIfAborted();
  if (!force && previous?.version === 2 && Date.now() - previous.updatedAt < CANVAS_INDEX_MAX_AGE) return { ...previous, cached: true };
  onProgress(previous ? 'Checking for updated course materials…' : 'Indexing Canvas course materials…');
  let listingTruncated = false;
  const list = async (path) => {
    let next = `${path}${path.includes('?') ? '&' : '?'}per_page=100`;
    const items = [];
    const visited = new Set();
    while (next && items.length < MAX_COURSE_ITEMS && !visited.has(next)) {
      visited.add(next);
      const page = await request(next);
      if (!Array.isArray(page.data)) throw new Error('Canvas returned an invalid course list.');
      items.push(...page.data);
      next = page.next;
    }
    if (next || items.length > MAX_COURSE_ITEMS) listingTruncated = true;
    const result = items.slice(0, MAX_COURSE_ITEMS); result.complete = !next && items.length <= MAX_COURSE_ITEMS; return result;
  };
  const readFile = async (item) => {
    if (Number(item.size) > MAX_FILE_BYTES) throw new Error('File too large.');
    const type = String(item['content-type'] || '');
    const name = String(item.display_name || item.filename || 'Course file');
    if (!/^(text\/|application\/(pdf|json|xml))/.test(type) && !/\.(pdf|docx|pptx|xlsx|ipynb|txt|md|csv|json|xml|tex|py|js|java|c|cpp|h|html)$/i.test(name)) return '';
    const download = new URL(item.url);
    if (download.protocol !== 'https:' && download.origin !== course.origin) throw new Error('Invalid course file URL.');
    if (approveFile && !await approveFile(download.href, name)) throw new Error('File site was not approved.');
    signal?.throwIfAborted();
    const response = await fetch(download.href, { credentials: 'include', signal: requestSignal(), ...(approveFile ? { redirect: 'error' } : {}) });
    const blob = await boundedBlob(response, MAX_FILE_BYTES);
    if (/pdf/i.test(type) || /\.pdf$/i.test(name)) {
      const pdf = await extractPdfContext(blob, { signal, maxCharacters: 120_000 });
      return pdf.extractedCharacters ? { text: pdf.context, truncated: pdf.truncated } : '';
    }
    const file = new File([blob], name, { type });
    if (/\.(docx|pptx|xlsx)$/i.test(name)) return extractOfficeText(file, 120_000);
    const result = await readChatFile(file, { signal });
    return { text: type.includes('html') ? htmlToText(result.text) : result.text, truncated: result.truncated };
  };
  const htmlToLinks = (html, sourceURL) => canvasDocumentLinks(
    new DOMParser().parseFromString(String(html), 'text/html'), course.origin, course.courseId, sourceURL);
  const htmlToResearchLinks = (html, sourceURL) => researchLinksFromDocument(
    new DOMParser().parseFromString(String(html), 'text/html'), sourceURL);
  const index = await buildCanvasCourseIndex({ course, userId: user.id, courseInfo: info, previous, get, list, readFile, htmlToText, htmlToLinks, htmlToResearchLinks, onProgress, signal });
  signal?.throwIfAborted();
  index.partial ||= listingTruncated;
  if (!index.documents.length) throw new Error('No readable course materials were found. Check course access and try again.');
  try { await saveCanvasIndex(index); } catch { index.storageUnavailable = true; }
  return index;
}

export async function getCanvasCourseContext(url, options = {}) {
  const index = await loadCanvasCourseIndex(url, options);
  const date = new Date(index.updatedAt).toLocaleString();
  return {
    context: canvasCourseContext(index, options),
    contextNotice: `${index.title} · ${index.documents.length} course sources · ${index.cached ? 'cached' : 'updated'} ${date}${index.partial ? ` · Partial index (${index.skipped} unavailable or unsupported sources)` : ''}${index.storageUnavailable ? ' · Could not save locally' : ''}`,
    contextState: 'Canvas course context',
    canvasCourse: index.course
  };
}
