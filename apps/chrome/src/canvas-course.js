import { packSiteContext } from '../../../packages/core/src/context.js';
import { canvasContentLink } from '../../../packages/core/src/canvas-links.js';
import { researchUrl } from './research-links.js';

export const CANVAS_INDEX_MAX_AGE = 15 * 60_000;
export const MAX_COURSE_ITEMS = 300;
export const MAX_COURSE_CHARACTERS = 2_000_000;

export function canvasCourseFromUrl(value) {
  try {
    const url = new URL(value);
    const courseId = /^\/courses\/(\d+)(?:\/|$)/.exec(url.pathname)?.[1];
    if (!courseId || !['https:', 'http:'].includes(url.protocol)) return null;
    return { origin: url.origin, courseId, url: `${url.origin}/courses/${courseId}` };
  } catch { return null; }
}

export function isCanvasCoursePage(url, documentValue) {
  const course = canvasCourseFromUrl(url);
  if (!course) return false;
  return /(?:\.instructure\.com|\/\/canvas\.)/i.test(course.origin)
    || Boolean(documentValue?.querySelector?.('#global_nav.ic-app-header__main-navigation, .ic-app, meta[name="canvas-version"]'));
}

export function canvasIndexKey(course, userId) {
  return `v1:${course.origin}:${String(userId)}:${course.courseId}`;
}

export function canvasNextPage(header, currentUrl, course) {
  const next = String(header || '').split(',').find((part) => /;\s*rel="?next"?/.test(part));
  const href = /<([^>]+)>/.exec(next || '')?.[1];
  if (!href) return '';
  try {
    const url = new URL(href, currentUrl);
    const current = new URL(currentUrl);
    return url.origin === course.origin && url.pathname === current.pathname ? url.href : '';
  } catch { return ''; }
}

function accessible(item, linkedFile = false) {
  return item && item.published !== false && !item.locked_for_user && (linkedFile || !item.hidden_for_user);
}

// All API reads are scoped to this course. A denied collection does not prevent
// accessible module items from being indexed (Canvas may hide its Files tab).
export async function buildCanvasCourseIndex({ course, userId, courseInfo, list, get, readFile, htmlToText, htmlToLinks = () => [], htmlToResearchLinks = () => [], previous, onProgress = () => {}, signal }) {
  const prefix = `/api/v1/courses/${course.courseId}`;
  const failures = [], incomplete = new Set(), denied = new Set();
  const safeList = async (path) => {
    const route = path.split('?')[0];
    try { const items = await list(path); if (items.complete === false) incomplete.add(route); return items; }
    catch (error) { if (signal?.aborted) throw error; failures.push(route); if (![401, 403, 404].includes(error.status)) incomplete.add(route); return []; }
  };
  const [pages, files, assignments, modules] = await Promise.all([
    safeList(`${prefix}/pages`), safeList(`${prefix}/files`),
    safeList(`${prefix}/assignments`), safeList(`${prefix}/modules?include[]=items`)
  ]);
  const candidates = new Map();
  const researchLinks = [];
  const add = (kind, id, item) => {
    const key = `${kind}:${id}`;
    if (!accessible(item, kind === 'file' && item.linked)) { denied.add(key); return; }
    if (!id || candidates.size >= MAX_COURSE_ITEMS) return;
    if (!candidates.has(key)) candidates.set(key, { ...item, kind, id: String(id) });
    else if (item.linked) candidates.get(key).linked = true;
  };
  for (const page of pages) add('page', page.url, page);
  for (const file of files) add('file', file.id, file);
  for (const assignment of assignments) add('assignment', assignment.id, assignment);
  for (const module of modules.slice(0, 100)) {
    if (!accessible(module) || module.state === 'locked') continue;
    const items = Array.isArray(module.items) && module.items.length >= Number(module.items_count || 0)
      ? module.items : await safeList(`${prefix}/modules/${encodeURIComponent(module.id)}/items`);
    for (const item of items) {
      if (!accessible(item) || item.content_details?.locked_for_user) continue;
      const kind = { Page: 'page', File: 'file', Assignment: 'assignment' }[item.type];
      if (kind) add(kind, kind === 'page' ? item.page_url : item.content_id, {
        title: item.title, moduleTitle: module.name, linked: true
      });
      else if (item.type === 'ExternalUrl') {
        const link = canvasContentLink(item.external_url, course.origin, course.courseId);
        if (link) add({ pages: 'page', files: 'file', assignments: 'assignment' }[link.kind], link.remoteID, { title: item.title, linked: true });
        else if (researchUrl(item.external_url, course.origin)) researchLinks.push({ url: researchUrl(item.external_url, course.origin), title: item.title || module.name });
      }
    }
  }
  const old = new Map((previous?.documents || []).map((doc) => [doc.key, doc]));
  const documents = [];
  let characters = 0;
  let reused = 0;
  let skipped = 0;
  let partial = candidates.size >= MAX_COURSE_ITEMS;
  let linkedContentIncomplete = false;
  const discover = (links) => {
    for (const link of links) add({ pages: 'page', files: 'file', assignments: 'assignment' }[link.kind], link.remoteID, { linked: true });
    if (candidates.size >= MAX_COURSE_ITEMS) partial = true;
  };
  const append = (doc) => {
    const text = String(doc.text || '').slice(0, Math.min(120_000, MAX_COURSE_CHARACTERS - characters));
    if (!text.trim()) return;
    if (doc.truncated || text.length < String(doc.text).length) partial = true;
    documents.push({ ...doc, text });
    characters += text.length;
  };
  if (courseInfo.syllabus_body) {
    discover(htmlToLinks(courseInfo.syllabus_body, `${course.url}/assignments/syllabus`));
    append({ key: 'syllabus', title: `${courseInfo.name} — Syllabus`, url: `${course.url}/assignments/syllabus`, text: htmlToText(courseInfo.syllabus_body), version: courseInfo.updated_at || '', researchLinks: htmlToResearchLinks(courseInfo.syllabus_body, `${course.url}/assignments/syllabus`) });
  }
  for (const [key, candidate] of candidates) {
    if (signal?.aborted) throw new DOMException('Course indexing cancelled.', 'AbortError');
    if (characters >= MAX_COURSE_CHARACTERS) { partial = true; break; }
    onProgress(`Indexing course · ${documents.length} sources · ${candidate.title || candidate.display_name || candidate.id}`);
    try {
      const route = { page: 'pages', file: 'files', assignment: 'assignments' }[candidate.kind];
      // Link-only attachments may be readable even when the course Files tab is disabled.
      const resolve = async () => {
        try { return await get(`${prefix}/${route}/${encodeURIComponent(candidate.id)}`); }
        catch (error) {
          if (candidate.kind !== 'file' || !candidate.linked || ![403, 404].includes(error.status)) throw error;
          return get(`/api/v1/files/${encodeURIComponent(candidate.id)}`);
        }
      };
      const item = candidate.updated_at ? candidate
        : await resolve();
      if (!accessible(item, candidate.kind === 'file' && candidate.linked)) { skipped += 1; continue; }
      const version = candidate.kind === 'assignment'
        ? JSON.stringify([item.updated_at || '', item.due_at || '', item.description || '', item.name || ''])
        : item.updated_at || item.modified_at ? [item.updated_at || '', item.modified_at || '', item.size || ''].join('|') : '';
      const cached = old.get(key);
      const url = `${course.url}/${route}/${encodeURIComponent(candidate.id)}`;
      const title = String(item.title || item.display_name || item.name || candidate.title || candidate.id).slice(0, 300);
      if (version && cached?.version === version && !cached.stale && (candidate.kind === 'file' || (Array.isArray(cached.links) && Array.isArray(cached.researchLinks)))) {
        discover(cached.links || []);
        append({ ...cached, title, url, stale: false }); reused += 1; continue;
      }
      let text;
      let links = [];
      let documentResearchLinks = [];
      let truncated = false;
      if (candidate.kind === 'file') {
        const result = await readFile(item);
        text = typeof result === 'string' ? result : result?.text;
        truncated = Boolean(result?.truncated);
      }
      else if (candidate.kind === 'page') {
        const full = typeof item.body === 'string' ? item : await get(`${prefix}/pages/${encodeURIComponent(candidate.id)}`);
        if (!accessible(full)) { skipped += 1; continue; }
        links = htmlToLinks(full.body || '', url);
        documentResearchLinks = htmlToResearchLinks(full.body || '', url);
        discover(links);
        text = htmlToText(full.body || '');
      } else {
        links = htmlToLinks(item.description || '', url);
        documentResearchLinks = htmlToResearchLinks(item.description || '', url);
        discover(links);
        text = [htmlToText(item.description || ''), item.due_at ? `Due: ${item.due_at}` : ''].filter(Boolean).join('\n');
      }
      if (!text?.trim()) { skipped += 1; continue; }
      append({ key, title, url, text, version, truncated, stale: false, links, researchLinks: documentResearchLinks });
    } catch (error) {
      if (signal?.aborted) throw error;
      skipped += 1;
      if (candidate.kind !== 'file' && ![401, 403, 404].includes(error.status)) linkedContentIncomplete = true;
      const cached = old.get(key);
      if (cached && ![401, 403, 404].includes(error.status)) append({ ...cached, stale: true, staleReason: 'Refresh failed; saved source retained' });
    }
  }
  // Only a complete authoritative listing establishes removal. Failed or
  // truncated collections retain the last readable version with a stale label.
  const retained = new Set(documents.map((doc) => doc.key));
  for (const cached of old.values()) {
    if (retained.has(cached.key) || candidates.has(cached.key) || denied.has(cached.key) || cached.key === 'syllabus') continue;
    const route = { page: 'pages', file: 'files', assignment: 'assignments' }[cached.key.split(':')[0]];
    if (linkedContentIncomplete || incomplete.has(`${prefix}/${route}`) || [...incomplete].some((path) => path.startsWith(`${prefix}/modules`))) {
      append({ ...cached, stale: true, staleReason: 'Collection incomplete; saved source retained' }); skipped += 1;
    }
  }
  return {
    key: canvasIndexKey(course, userId), version: 2, course, userId: String(userId),
    title: String(courseInfo.name || 'Canvas course').slice(0, 300),
    documents, researchLinks, characters, updatedAt: Date.now(), reused, skipped,
    partial: partial || skipped > 0 || failures.length > 0,
    failedCollections: failures.length, failedCollectionNames: failures, incompleteCollections: [...incomplete]
  };
}

export function canvasCourseContext(index, { question = '', selection = '', maxChars = 6_000 } = {}) {
  return packSiteContext(index.documents.map((doc) => doc.stale ? { ...doc, text: `[Saved source; refresh failed and content may be stale]\n${doc.text}` } : doc), {
    question, selection, maxChars, discoveredPages: index.documents.length + index.skipped,
    truncated: index.partial
  });
}
