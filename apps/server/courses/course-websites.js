import { createHash } from 'node:crypto';
import { DOMParser } from 'linkedom';
import { MathWiki, mathWikiCourse } from './math-wiki.js';
import { courseHTMLDocument } from '../../../packages/core/src/course-documents.js';
import { courseWebsiteLink, isCourseWebsiteHint, isCourseWebsiteMaterial, knownCourseWebsiteSeeds, withinWebsite } from '../../../packages/core/src/course-websites.js';

const hash = (value) => createHash('sha256').update(value).digest('hex');
export function courseWebsiteSeeds(sources, course) {
  const seeds = new Map();
  for (const source of sources) {
    const doc = new DOMParser().parseFromString(`<html><body>${source.html || ''}</body></html>`, 'text/html');
    doc.querySelectorAll('script,style,form').forEach(n => n.remove());
    for (const node of doc.querySelectorAll('a[href]')) {
      const link = courseWebsiteLink(node.getAttribute('href'), source.url || course.canvasOrigin);
      if (!isCourseWebsiteHint(link, node.textContent + ' ' + (node.parentElement?.textContent || '').slice(0, 1500), course)) continue;
      seeds.set(link.url, { url: link.url, evidenceURL: source.url,
        filesOnly: /(?:old|past|previous|tidligere|gamle).{0,25}(?:exam|eksamen)|exam sets|eksamensoppgaver/i.test(node.textContent) });
    }
  }
  return [...seeds.values()];
}

export function parseCourseWebsite(html) {
  const doc = new DOMParser().parseFromString(html, 'text/html');
  if (doc.querySelector('input[type=password]')) throw new Error('This course website requires a separate sign-in.');
  if (/^\s*(?:JupyterHub|Shorty)(?:\s|·|$)/i.test(doc.querySelector('title')?.textContent || ''))
    throw new Error('The website returned a sign-in or link-shortener page instead of course content.');
  doc.querySelectorAll('script,style,form,iframe,noscript').forEach(n => n.remove());
  const content = doc.querySelector('main,article,[role=main]') || doc.body;
  if (!content?.textContent.trim()) throw new Error('The course website has no readable content. It may require sign-in or JavaScript.');
  const links = []; let section;
  for (const node of doc.querySelectorAll('h1,h2,h3,h4,h5,h6,a[href]')) {
    if (node.tagName !== 'A') { section = node.textContent.trim(); continue; }
    links.push({ href: node.getAttribute('href'), title: node.textContent.trim(), section });
  }
  return { body: content.innerHTML, title: content.querySelector('h1')?.textContent.trim() || doc.querySelector('title')?.textContent.trim() || 'Course website', links };
}

// Jekyll aliases (such as ovinger.html → øvinger.html) use an inert HTML
// redirect. Follow immediate meta refreshes without executing page scripts.
export function courseWebsiteRedirect(html, base) {
  const doc = new DOMParser().parseFromString(html, 'text/html');
  const meta = [...doc.querySelectorAll('meta[http-equiv]')]
    .find(node => node.getAttribute('http-equiv').toLowerCase() === 'refresh');
  const target = meta?.getAttribute('content')?.match(/^\s*0(?:\.0+)?\s*;\s*url\s*=\s*(.*?)\s*$/i)?.[1];
  if (!target) return null;
  const link = courseWebsiteLink(target.replace(/^["']|["']$/g, ''), base);
  if (link?.kind !== 'pages') throw new Error('The course website redirects to a sign-in service or unsupported resource.');
  return link.url;
}

export function websiteSemesterMatches(value, course) {
  const terms = mathWikiCourse({ ...course, code: 'MA0000', canvasOrigin: undefined })?.terms || [];
  if (!terms.length) return true;
  const found = mathWikiCourse({ code: 'MA0000', term: decodeURI(value).replaceAll('+', ' ') })?.terms || [];
  return !found.length || found.some(term => terms.includes(term));
}

export class CourseWebsites extends MathWiki {
  async page(url, options) {
    for (let hop = 0; hop < 4; hop++) {
      const response = await this.fetch(url, options);
      const redirect = courseWebsiteRedirect(response.data.toString(), response.url);
      if (!redirect) return response;
      url = redirect;
    }
    throw new Error('The course website redirected too many times.');
  }

  async entry(seed, course) {
    let url = seed.url;
    for (let hop = 0; hop < 4; hop++) {
      const response = await this.page(url, { pageScope: value => courseWebsiteLink(value)?.kind === 'pages' &&
        (seed.filesOnly || websiteSemesterMatches(value, course)) });
      if (new URL(response.url).hostname !== 's.ntnu.no') return { seed: { ...seed, url: response.url }, response };
      // NTNU short links show a confirmation page instead of an HTTP redirect.
      // Resolve its explicit destination without executing scripts or signing in.
      const doc = new DOMParser().parseFromString(response.data.toString(), 'text/html');
      const destination = doc.querySelector('a.action-button[href]')?.getAttribute('href');
      const link = destination && courseWebsiteLink(destination, response.url);
      if (link?.kind !== 'pages') throw new Error('The course short link points to a sign-in service or unsupported resource.');
      url = link.url;
    }
    throw new Error('The course short link redirected too many times.');
  }

  async catalog(course, discovered = []) {
    // Remember confirmed roots when old announcements scroll away or a Canvas
    // collection fails. They remain tied to the same Canvas course/semester.
    const seeds = new Map(discovered.map(seed => [seed.url, seed]));
    for (const ref of course.canvasMaterials || []) if (ref.websiteRootURL && isCourseWebsiteMaterial(ref))
      seeds.set(ref.websiteRootURL, { url: ref.websiteRootURL, evidenceURL: ref.websiteEvidenceURL, filesOnly: ref.websiteFilesOnly });
    // Prefer course-provided and previously confirmed sites. A known official
    // homepage fills the gap when Canvas has no teaching-site link (or only an
    // old-exam archive). It uses the same crawler and download path as discoveries.
    if (![...seeds.values()].some(seed => !seed.filesOnly && websiteSemesterMatches(seed.url, course)))
      for (const seed of knownCourseWebsiteSeeds(course)) seeds.set(seed.url, seed);
    const items = new Map(), warnings = [], roots = new Set();
    for (const discoveredSeed of seeds.values()) {
      if (!discoveredSeed.filesOnly && !websiteSemesterMatches(discoveredSeed.url, course)) {
        warnings.push(`Course website: skipped a different semester: ${discoveredSeed.url}`); continue;
      }
      let entry;
      try { entry = await this.entry(discoveredSeed, course); }
      catch (error) { this.signal?.throwIfAborted(); warnings.push(`Course website ${discoveredSeed.url}: ${error.message}`); continue; }
      const { seed } = entry;
      if (roots.has(seed.url)) continue;
      roots.add(seed.url);
      const queue = [seed.url], visited = new Set();
      const permitted = (url) => withinWebsite(url, seed.url) && (seed.filesOnly || websiteSemesterMatches(url, course));
      for (let i = 0; i < queue.length; i++) {
        this.signal?.throwIfAborted();
        const url = queue[i];
        if (visited.has(url)) continue;
        if (visited.size >= 100 || items.size >= 1500) { warnings.push(`Course website: crawl limit reached for ${seed.url}`); break; }
        visited.add(url);
        try {
          const response = i === 0 ? entry.response : await this.page(url, { pageScope: permitted });
          visited.add(response.url);
          const page = parseCourseWebsite(response.data.toString());
          if (!seed.filesOnly && !websiteSemesterMatches(page.title, course)) throw new Error('The page title names a different semester.');
          const id = `course-web:${response.url}`;
          const common = { websiteRootURL: seed.url, websiteEvidenceURL: seed.evidenceURL, websiteFilesOnly: seed.filesOnly || undefined,
            folderID: -2, folderTitle: `Course website · ${new URL(seed.url).hostname}` };
          items.set(id, { ...common, id, kind: 'pages', remoteID: response.url, title: page.title,
            sourceURL: response.url, version: hash(page.body) });
          for (const [position, raw] of page.links.entries()) {
            const link = courseWebsiteLink(raw.href, response.url);
            if (!link) continue;
            if (link.kind === 'pages') {
              if (!seed.filesOnly && permitted(link.url) && !visited.has(link.url) && !queue.includes(link.url)) queue.push(link.url);
            } else {
              const fileID = `course-web:${link.url}`;
              if (!items.has(fileID)) items.set(fileID, { ...common, id: fileID, kind: 'files', remoteID: link.url,
                title: raw.title && raw.title !== link.fileName ? `${raw.title} · ${link.fileName}` : link.fileName,
                fileName: link.fileName, sourceURL: link.url, version: '', linkedFromID: id,
                linkedFromTitle: page.title, linkedPosition: position, linkedOrder: [position], linkedSection: raw.section });
            }
          }
        } catch (error) { this.signal?.throwIfAborted(); warnings.push(`Course website ${url}: ${error.message}`); }
      }
    }
    const files = [...items.values()].filter(ref => ref.kind === 'files');
    let next = 0;
    await Promise.all(Array.from({ length: Math.min(6, files.length) }, async () => {
      while (next < files.length) {
        const ref = files[next++];
        try {
          const { headers } = await this.fetch(ref.sourceURL, { method: 'HEAD', limit: 100_000_000 });
          ref.version = headers.etag || headers['last-modified'] || '';
          if (headers['content-length']) ref.byteCount = Number(headers['content-length']);
        } catch { this.signal?.throwIfAborted(); }
        if (!ref.version) ref.version = `unvalidated:${Date.now()}`;
      }
    }));
    return { items: [...items.values()], warnings, complete: !warnings.length };
  }

  async material(ref, { limit = 100_000_000 } = {}) {
    if (!isCourseWebsiteMaterial(ref) || courseWebsiteLink(ref.sourceURL)?.kind !== ref.kind) throw new Error('Invalid course website material.');
    const fetch = ref.kind === 'pages' ? this.page.bind(this) : this.fetch.bind(this);
    const response = await fetch(ref.sourceURL, { limit: ref.kind === 'pages' ? Math.min(limit, 8_000_000) : limit,
      pageScope: ref.kind === 'pages' ? url => withinWebsite(url, ref.websiteRootURL || ref.sourceURL) : undefined });
    if (ref.kind === 'pages') {
      const page = parseCourseWebsite(response.data.toString());
      return { reference: { ...ref, version: hash(page.body) }, name: ref.title + '.html',
        data: Buffer.from(courseHTMLDocument(ref.title, page.body, response.url)) };
    }
    if (/text\/html/i.test(response.headers['content-type'] || '')) throw new Error('The website file returned a sign-in or error page.');
    return { reference: ref, name: ref.fileName, data: response.data };
  }
}
