import { setTimeout as delay } from 'node:timers/promises';
import { DOMParser } from 'linkedom';
import { courseHTMLDocument } from '../../packages/core/src/course-documents.js';
import { remoteRequest } from './network.js';
import { MathWiki, isMathWikiMaterial } from './math-wiki.js';
import { CourseWebsites, courseWebsiteSeeds } from './course-websites.js';
import { isCourseWebsiteMaterial } from '../../packages/core/src/course-websites.js';
import { canvasContentLink, canvasContentLinks, canvasModuleFields, canvasLinkFields,
  canvasFolderTitle, inheritCanvasGrouping } from './canvas-content.js';
export const htmlText = (html) => {
  const doc = new DOMParser().parseFromString(
    `<html><body>${html || ''}</body></html>`,
    'text/html'
  );
  doc.querySelectorAll('script,style,iframe').forEach((node) => node.remove());
  doc
    .querySelectorAll('p,div,li,br,h1,h2,h3,tr')
    .forEach((node) => node.appendChild(doc.createTextNode('\n')));
  return doc.body.textContent.trim();
};
export function assignmentDetails(record, origin, courseID) {
  const submission = record.submission || {},
    workflow = submission.workflow_state;
  const status = submission.excused
    ? 'excused'
    : workflow === 'graded' && !submission.missing
      ? 'graded'
      : submission.submitted_at || ['submitted', 'pending_review'].includes(workflow)
        ? 'submitted'
        : workflow === 'unsubmitted' || submission.missing
          ? 'notSubmitted'
          : 'unknown';
  // Canvas may return a score before it is posted. Never expose unpublished
  // grades, and do not mistake a legitimate zero for missing metadata.
  const gradeVisible =
    !submission.excused &&
    !submission.grade_hidden &&
    !record.muted &&
    !record.hide_in_gradebook &&
    submission.assignment_visible !== false &&
    !(Object.hasOwn(submission, 'posted_at') && !submission.posted_at) &&
    !(record.post_manually && !submission.posted_at);
  const number = (value) =>
    (typeof value === 'number' || (typeof value === 'string' && value.trim())) &&
    Number.isFinite(Number(value))
      ? Number(value)
      : null;
  const linkedFileIDs = [];
  const doc = new DOMParser().parseFromString(
    `<html>${record.description || ''}</html>`,
    'text/html'
  );
  for (const node of doc.querySelectorAll('[href],[src],[data-api-endpoint]'))
    for (const attribute of ['href', 'src', 'data-api-endpoint']) {
      try {
        const url = new URL(node.getAttribute(attribute), origin);
        const match = url.pathname.match(
          /^\/(?:api\/v1\/)?(?:courses\/(\d+)\/)?files\/(\d+)(?:\/(?:download|preview))?\/?$/
        );
        if (
          url.origin === origin &&
          match &&
          (!match[1] || Number(match[1]) === Number(courseID)) &&
          !linkedFileIDs.includes(match[2])
        )
          linkedFileIDs.push(match[2]);
      } catch {}
    }
  return {
    dueAt: record.due_at || null,
    unlockAt: record.unlock_at || null,
    lockAt: record.lock_at || null,
    submissionTypes: record.submission_types || [],
    status,
    grade: gradeVisible && submission.grade != null ? String(submission.grade) : null,
    score: gradeVisible ? number(submission.score) : null,
    pointsPossible: number(record.points_possible),
    gradingType: record.grading_type || null,
    gradeVisible,
    gradeMatchesCurrentSubmission: submission.grade_matches_current_submission ?? null,
    missing: !!submission.missing,
    locked: !!record.locked_for_user,
    linkedFileIDs,
  };
}
export class Canvas {
  constructor(origin, token, { hosts = ['canvas.ntnu.no'], request = remoteRequest, signal } = {}) {
    const url = new URL(origin);
    if (
      url.protocol !== 'https:' ||
      url.port ||
      url.username ||
      url.password ||
      !hosts.includes(url.hostname)
    )
      throw new Error('This Canvas host is not enabled on the server.');
    this.origin = url.origin;
    this.token = token;
    this.request = request;
    this.signal = signal;
    this.mathWiki = new MathWiki({ request, signal });
    this.courseWebsites = new CourseWebsites({ request, signal });
  }
  async api(path, attempt = 0) {
    const url = new URL(path, this.origin);
    if (url.origin !== this.origin || !url.pathname.startsWith('/api/v1/'))
      throw new Error('Invalid Canvas API address.');
    const result = await this.request(url, {
      headers: { Authorization: `Bearer ${this.token}`, Accept: 'application/json' },
      limit: 8_000_000,
      signal: this.signal,
    });
    if (result.status === 429 && attempt < 2) {
      const wait = Math.min(60, Math.max(1, Number(result.headers['retry-after']) || 2 ** attempt));
      await delay(wait * 1000, undefined, { signal: this.signal });
      return this.api(path, attempt + 1);
    }
    if (result.status < 200 || result.status >= 300)
      throw Object.assign(new Error(
        result.status === 401
          ? 'Your Canvas token has expired. Reconnect Canvas.'
          : `Canvas returned HTTP ${result.status}.`
      ), { canvasStatus: result.status });
    return { value: JSON.parse(result.data), headers: result.headers };
  }
  async list(path) {
    let next = new URL(path, this.origin);
    next.searchParams.set('per_page', '100');
    const originalPath = next.pathname,
      seen = new Set(),
      items = [];
    while (next) {
      if (
        seen.has(next.href) ||
        seen.size >= 50 ||
        next.origin !== this.origin ||
        next.pathname !== originalPath
      )
        throw new Error('Invalid Canvas pagination.');
      seen.add(next.href);
      const { value, headers } = await this.api(next.href);
      if (!Array.isArray(value)) throw new Error('Canvas returned an invalid list.');
      items.push(...value);
      const match = String(headers.link || '').match(/<([^>]+)>;\s*rel="?next"?/);
      next = match ? new URL(match[1], next) : null;
    }
    return items;
  }
  async account() {
    return (await this.api('/api/v1/users/self/profile')).value;
  }
  async courses() {
    return this.list('/api/v1/courses?include[]=term');
  }
  reference(kind, item, courseID) {
    const remoteID = String(kind === 'pages' ? item.url : item.id);
    const fileName = kind === 'files' ? item.filename || item.display_name : undefined;
    return {
      id: `${kind}:${remoteID}`,
      kind,
      remoteID,
      title: item.name || item.title || item.display_name || fileName || remoteID,
      fileName,
      sourceURL: `${this.origin}/courses/${courseID}/${kind}/${encodeURIComponent(remoteID)}`,
      version:
        String(item.updated_at || item.modified_at || '') +
        (kind === 'assignments' ? `|due:${item.due_at || 'none'}` : ''),
      byteCount: item.size,
      ...(kind === 'files' && item.folder_id != null ? { folderID: item.folder_id } : {}),
      ...(kind === 'assignments'
        ? { assignment: assignmentDetails(item, this.origin, courseID) }
        : {}),
    };
  }
  async catalog(course, { includePublic = true } = {}) {
    const previous = course.canvasMaterials || [],
      candidates = new Map(),
      bodies = new Map(),
      warnings = [],
      complete = new Set();
    const prefix = `/api/v1/courses/${course.canvasID}`;
    const websiteSources = [];
    const accessible = (item, linkedFile = false) => item.published !== false &&
      !item.locked_for_user && (linkedFile || !item.hidden_for_user);
    const add = (kind, item, linkedFile = false) => {
      if (!accessible(item, linkedFile) && !(kind === 'assignments' && item.published !== false && !item.hidden_for_user)) return null;
      const ref = this.reference(kind, item, course.canvasID);
      if (!candidates.has(ref.id)) candidates.set(ref.id, ref);
      if (kind === 'pages' && typeof item.body === 'string') bodies.set(ref.id, item.body);
      if (kind === 'assignments') bodies.set(ref.id, item.locked_for_user ? '' : item.description || '');
      return candidates.get(ref.id);
    };
    let moduleOrderComplete = false, linkedContentComplete = true, foldersComplete = false;
    for (const kind of ['files', 'pages', 'assignments']) {
      try {
        const records = await this.list(
          `/api/v1/courses/${course.canvasID}/${kind}${kind === 'assignments' ? '?include[]=submission' : ''}`
        );
        for (const item of records) add(kind, item);
        complete.add(kind);
      } catch (error) {
        this.signal?.throwIfAborted();
        warnings.push(`${kind}: ${error.message}`);
        if (kind === 'pages' || kind === 'assignments') linkedContentComplete = false;
      }
    }
    try {
      const modules = await this.list(`${prefix}/modules?include[]=items&include[]=content_details`);
      moduleOrderComplete = true;
      for (const [moduleIndex, module] of modules.sort((a, b) => (a.position || 0) - (b.position || 0)).entries()) {
        if (!accessible(module) || module.state === 'locked') continue;
        let entries;
        try {
          entries = Array.isArray(module.items) && module.items.length >= (module.items_count ?? Infinity)
            ? module.items : await this.list(`${prefix}/modules/${module.id}/items?include[]=content_details`);
        } catch (error) {
          this.signal?.throwIfAborted();
          moduleOrderComplete = false;
          warnings.push(`Module ${module.id}: ${error.message}`);
          continue;
        }
        let section;
        for (const [itemIndex, entry] of entries.sort((a, b) => (a.position || 0) - (b.position || 0)).entries()) {
          if (!accessible(entry) || entry.content_details?.locked_for_user) continue;
          if (entry.type === 'SubHeader') { section = entry.title?.trim() || undefined; continue; }
          if (entry.type === 'ExternalUrl' && entry.external_url)
            websiteSources.push({ html: courseHTMLDocument(entry.title || '', `<a href="${String(entry.external_url).replaceAll('&', '&amp;').replaceAll('"', '&quot;')}">${htmlText(entry.title || '').replaceAll('<', '&lt;')}</a>`, ''), url: `${this.origin}/courses/${course.canvasID}/modules` });
          const kind = { File: 'files', Assignment: 'assignments', Page: 'pages' }[entry.type];
          const remoteID = kind === 'pages' ? entry.page_url : entry.content_id;
          const link = kind && remoteID != null ? { kind, remoteID: String(remoteID), id: `${kind}:${remoteID}` }
            : canvasContentLink(entry.external_url, this.origin, course.canvasID);
          if (!link) continue;
          let ref = candidates.get(link.id);
          if (!ref) {
            try {
              const record = link.kind === 'files' ? await this.fileMetadata(link.remoteID, course.canvasID)
                : (await this.api(`${prefix}/${link.kind}/${encodeURIComponent(link.remoteID)}${link.kind === 'assignments' ? '?include[]=submission' : ''}`)).value;
              ref = add(link.kind, record, link.kind === 'files');
            } catch (error) {
              this.signal?.throwIfAborted();
              moduleOrderComplete = false;
              linkedContentComplete = false;
              warnings.push(`${link.id}: ${error.message}`);
              continue;
            }
          }
          if (ref && ref.moduleID == null)
            Object.assign(ref, {
              moduleID: module.id,
              moduleTitle: module.name?.trim() || `Module ${module.id}`,
              modulePosition: module.position ?? moduleIndex,
              moduleItemPosition: entry.position ?? itemIndex,
              moduleSection: section,
            });
        }
      }
    } catch (error) {
      this.signal?.throwIfAborted();
      warnings.push(`modules: ${error.message}`);
    }
    // Page bodies are not included in the Pages listing. Crawl each accessible
    // page once, including pages linked from other pages, before downloading.
    const queue = [...candidates.values()].filter((ref) => ['pages', 'assignments'].includes(ref.kind))
      .sort((a, b) => (a.modulePosition ?? Infinity) - (b.modulePosition ?? Infinity) ||
        (a.moduleItemPosition ?? Infinity) - (b.moduleItemPosition ?? Infinity));
    const visited = new Set(), failed = new Set();
    for (let index = 0; index < queue.length; index++) {
      this.signal?.throwIfAborted();
      const parent = queue[index];
      if (visited.has(parent.id)) continue;
      visited.add(parent.id);
      try {
        if (!bodies.has(parent.id)) {
          const record = (await this.api(`${prefix}/${parent.kind}/${encodeURIComponent(parent.remoteID)}`)).value;
          if (!accessible(record)) { candidates.delete(parent.id); continue; }
          Object.assign(parent, this.reference(parent.kind, record, course.canvasID));
          bodies.set(parent.id, record.body || record.description || '');
        }
        const links = canvasContentLinks(bodies.get(parent.id), this.origin, course.canvasID, parent.sourceURL);
        for (const [position, link] of links.entries()) {
          if (link.id === parent.id || visited.has(link.id) || failed.has(link.id)) continue;
          let ref = candidates.get(link.id);
          if (!ref) {
            try {
              const record = link.kind === 'files' ? await this.fileMetadata(link.remoteID, course.canvasID)
                : (await this.api(`${prefix}/${link.kind}/${encodeURIComponent(link.remoteID)}`)).value;
              ref = add(link.kind, record, link.kind === 'files');
            } catch (error) {
              this.signal?.throwIfAborted();
              failed.add(link.id);
              linkedContentComplete = false;
              warnings.push(`${parent.title} → ${link.id}: ${error.message}`);
              continue;
            }
          }
          if (!ref) continue;
          inheritCanvasGrouping(ref, parent, position, link.section);
          if (ref.kind !== 'files') queue.push(ref);
        }
      } catch (error) {
        this.signal?.throwIfAborted();
        linkedContentComplete = false;
        warnings.push(`${parent.title}: ${error.message}`);
      }
    }
    try {
      const folders = new Map((await this.list(`${prefix}/folders`)).map((folder) => [String(folder.id), folder]));
      for (const ref of candidates.values()) {
        const title = canvasFolderTitle(ref.folderID, folders);
        if (title) ref.folderTitle = title;
      }
      foldersComplete = true;
    } catch (error) {
      this.signal?.throwIfAborted();
      // Folder metadata is optional; module/page grouping still works when Files is disabled.
      if (![403, 404].includes(error.canvasStatus)) warnings.push(`folders: ${error.message}`);
    }
    // An incomplete page/module crawl cannot establish that a link-only file was removed.
    if (!linkedContentComplete || !moduleOrderComplete)
      for (const kind of ['files', 'pages', 'assignments']) complete.delete(kind);
    const wiki = includePublic ? await this.mathWiki.catalog({ ...course, canvasOrigin: this.origin }) : { items: [], warnings: [], complete: false };
    for (const item of wiki.items) candidates.set(item.id, item);
    warnings.push(...wiki.warnings);
    let websiteDiscoveryComplete = true;
    if (includePublic && (course.code || course.name)) {
      for (const [id, html] of bodies) websiteSources.push({ html, url: candidates.get(id)?.sourceURL });
      for (const path of [`${prefix}?include[]=syllabus_body`, `${prefix}/discussion_topics?only_announcements=true`]) {
        try {
          if (path.includes('discussion_topics')) {
            for (const item of await this.list(path)) if (accessible(item)) websiteSources.push({ html: item.message, url: item.html_url });
          } else {
            const { value } = await this.api(path);
            websiteSources.push({ html: value.syllabus_body, url: `${this.origin}/courses/${course.canvasID}/assignments/syllabus` });
          }
        } catch (error) {
          this.signal?.throwIfAborted(); websiteDiscoveryComplete = false;
          if (![403, 404].includes(error.canvasStatus)) warnings.push(`Course website discovery: ${error.message}`);
        }
      }
    }
    const sites = includePublic ? await this.courseWebsites.catalog(course, courseWebsiteSeeds([...websiteSources, ...(wiki.websiteSources || [])], { ...course, canvasOrigin: this.origin })) : { items: [], warnings: [], complete: false };
    const wikiURLs = new Set(wiki.items.map(item => item.sourceURL));
    for (const item of sites.items) if (!wikiURLs.has(item.sourceURL)) candidates.set(item.id, item);
    warnings.push(...sites.warnings);
    const isComplete = (item) => isMathWikiMaterial(item) ? wiki.complete
      : isCourseWebsiteMaterial(item) ? sites.complete && websiteDiscoveryComplete : complete.has(item.kind);
    for (const item of previous)
      if (!isComplete(item) && !candidates.has(item.id)) candidates.set(item.id, item);
    const before = new Map(previous.map((item) => [item.id, item]));
    const items = [...candidates.values()];
    for (const item of items) {
      const prior = before.get(item.id);
      if (!prior) continue;
      if ((!moduleOrderComplete || !linkedContentComplete) && item.moduleID == null)
        for (const field of canvasModuleFields) if (prior[field] != null) item[field] = prior[field];
      if ((!moduleOrderComplete || !linkedContentComplete) && !item.linkedFromID)
        for (const field of canvasLinkFields) if (prior[field] != null) item[field] = prior[field];
      if (!foldersComplete && item.folderID === prior.folderID && prior.folderTitle) item.folderTitle = prior.folderTitle;
    }
    return {
      items,
      warnings,
      canvasComplete: ['files', 'pages', 'assignments'].every(kind => complete.has(kind)),
      mathWikiComplete: wiki.complete,
      changes: {
        added: items.filter((i) => !before.has(i.id)).map((i) => i.id),
        updated: items
          .filter((i) => before.has(i.id) && JSON.stringify(i) !== JSON.stringify(before.get(i.id)))
          .map((i) => i.id),
        removed: previous
          .filter((i) => isComplete(i) && !items.some((r) => r.id === i.id))
          .map((i) => i.id),
      },
    };
  }
  async material(ref, course, { limit = 100_000_000 } = {}) {
    if (isMathWikiMaterial(ref)) return this.mathWiki.material(ref, { limit });
    if (isCourseWebsiteMaterial(ref)) return this.courseWebsites.material(ref, { limit });
    const item = ref.kind === 'files' ? await this.fileMetadata(ref.remoteID, course.canvasID) : (
      await this.api(
        `/api/v1/courses/${course.canvasID}/${ref.kind}/${encodeURIComponent(ref.remoteID)}${ref.kind === 'assignments' ? '?include[]=submission' : ''}`
      )
    ).value;
    if (item.locked_for_user || (ref.kind !== 'files' && item.hidden_for_user) || item.published === false)
      throw new Error('Locked in Canvas.');
    const reference = this.reference(ref.kind, item, course.canvasID);
    if (ref.kind !== 'files')
      return {
        reference,
        name: `${reference.title}.html`,
        data: Buffer.from(courseHTMLDocument(reference.title, item.description || item.body, reference.sourceURL)),
      };
    if (Number(item.size) > limit) throw new Error('The file exceeds the download limit.');
    const url = new URL(item.url);
    const result = await this.request(url, {
      redirects: true,
      signal: this.signal,
      headers: url.origin === this.origin ? { Authorization: `Bearer ${this.token}` } : {},
      limit,
    }).catch((error) => {
      // An interrupted transfer may already have consumed its full allowance.
      error.downloadedBytes = limit;
      throw error;
    });
    if (result.status < 200 || result.status >= 300)
      throw Object.assign(new Error(`Download returned HTTP ${result.status}.`), {
        downloadedBytes: result.data.length,
      });
    return { reference, name: reference.fileName, data: result.data };
  }
  async fileMetadata(id, courseID) {
    if (!/^[1-9]\d*$/.test(String(id))) throw new Error('Invalid Canvas file.');
    try {
      return (await this.api(`/api/v1/courses/${courseID}/files/${id}`)).value;
    } catch (error) {
      if (![403, 404].includes(error.canvasStatus)) throw error;
      return (await this.api(`/api/v1/files/${id}`)).value;
    }
  }
}
