import { mathWikiLink, publicTeachingURL } from '../../packages/core/src/math-wiki.js';
export { mathWikiLink } from '../../packages/core/src/math-wiki.js';
import { createHash } from 'node:crypto';
import { DOMParser } from 'linkedom';
import { courseHTMLDocument } from '../../packages/core/src/course-documents.js';
import { remoteRequest } from './network.js';

const origin = 'https://wiki.math.ntnu.no';
const digest = (value) => createHash('sha256').update(value).digest('hex');
export const isMathWikiMaterial = (ref) => !!ref.id?.startsWith('math-wiki:');

// Never infer an archive from today's date. Canvas sometimes supplies only a
// semester suffix in the course code, and sometimes supplies multiple terms.
export function mathWikiCourse(course) {
  if (course.canvasOrigin && course.canvasOrigin !== 'https://canvas.ntnu.no') return null;
  const code = `${course.code || ''} ${course.name || ''}`.match(/\b(?:TMA|MA)\d{4}\b/i)?.[0].toLowerCase();
  if (!code) return null;
  const parse = (value) => {
    const text = String(value || '').normalize('NFD').replace(/\p{M}/gu, '').replace(/ø/gi, 'o').toUpperCase();
    const found = new Set();
    for (const [regex, reversed] of [
      [/(?<![A-Z0-9])((?:19|20)\d{2})[\s_/-]*(HOST|AUTUMN|FALL|VAR|SPRING|[HV])(?=$|[^A-Z0-9])/g, false],
      [/(?<![A-Z0-9])(HOST|AUTUMN|FALL|VAR|SPRING|[HV])[\s_/-]*((?:19|20)\d{2})(?=$|[^A-Z0-9])/g, true],
      [/(?<![A-Z0-9])(\d{2})([HV])(?=$|[^A-Z0-9])/g, false],
    ]) for (const match of text.matchAll(regex)) {
      let year = Number(match[reversed ? 2 : 1]);
      if (year < 100) year += year >= 80 ? 1900 : 2000;
      found.add(`${year}${['H', 'HOST', 'AUTUMN', 'FALL'].includes(match[reversed ? 1 : 2]) ? 'h' : 'v'}`);
    }
    return [...found].sort();
  };
  const explicit = parse(course.term);
  return { code, terms: explicit.length ? explicit : parse(`${course.code || ''} ${course.name || ''}`) };
}


function allowedPage(url, code, term) {
  const parts = new URL(url).pathname.split('/').filter(Boolean);
  if (parts[0] !== code || parts.length < 2 || ['sidebar', 'menu', 'start'].includes(parts.at(-1)) && parts.length === 2) return false;
  if (parts.some((part) => /^(?:19|20)\d{2}[hv]$/.test(part) && part !== term)) return false;
  return !parts.some((part) => /^(?:19|20)\d{2}$/.test(part));
}

export function parseMathWikiPage(html) {
  const doc = new DOMParser().parseFromString(html, 'text/html');
  doc.querySelectorAll('script,style,form,iframe').forEach((node) => node.remove());
  const content = doc.querySelector('article .content, .page .content, #dokuwiki__content .page, .dokuwiki .page, main') || doc.querySelector('.content');
  if (!content || /(?:does not exist yet|doesn't exist yet|finnes ikke ennå|finnes ikke enda)/i.test(content.textContent))
    throw new Error('The wiki page is missing or unavailable.');
  const links = [], seen = new Set();
  // The semester menu is outside the article in NTNU's DokuWiki template.
  for (const scope of [content, ...doc.querySelectorAll('#menuframe, .menuframe, nav')]) {
    let section;
    for (const node of scope.querySelectorAll('h1,h2,h3,h4,h5,h6,a[href]')) {
      if (node.tagName !== 'A') { section = node.textContent.trim(); continue; }
      if (node.classList.contains('wikilink2')) continue;
      const href = node.getAttribute('href');
      if (seen.has(href)) continue;
      seen.add(href);
      links.push({ href, title: node.textContent.trim(), section });
    }
  }
  return { body: content.innerHTML, title: content.querySelector('h1')?.textContent.trim() || doc.querySelector('title')?.textContent.replace(/ - wiki\.math\.ntnu\.no$/, '').trim() || content.querySelector('h2,h3,h4')?.textContent.trim(), links };
}

export class MathWiki {
  static checkInterval = 120_000;
  static fileCheckInterval = 300_000;
  constructor({ request = remoteRequest, signal, clock = Date.now } = {}) {
    this.request = request; this.signal = signal; this.clock = clock;
    this.pages = new Map(); this.files = new Map();
  }

  async fetch(value, { method = 'GET', limit = 8_000_000, pageScope, conditional = false } = {}) {
    let url = publicTeachingURL(value);
    for (let hop = 0; url && hop < 6; hop++) {
      this.signal?.throwIfAborted();
      if (pageScope && !pageScope(url.href)) throw new Error('The wiki redirected to a different course or semester.');
      // Wiki and staff requests never receive Canvas cookies or bearer tokens.
      const cached = conditional && method === 'GET' ? this.pages.get(url.href) : undefined;
      const headers = {};
      if (cached?.headers.etag) headers['If-None-Match'] = cached.headers.etag;
      if (cached?.headers['last-modified']) headers['If-Modified-Since'] = cached.headers['last-modified'];
      const result = await this.request(url, { method, headers, limit, signal: this.signal });
      if (result.status === 304 && cached && cached.data.length <= limit) return cached;
      if ([301, 302, 303, 307, 308].includes(result.status) && result.headers.location) {
        url = publicTeachingURL(result.headers.location, url);
        continue;
      }
      if (result.status < 200 || result.status >= 300)
        throw new Error(`Math wiki returned HTTP ${result.status}: ${url.href}`);
      const response = { ...result, url: url.href };
      if (conditional && method === 'GET') {
        this.pages.set(url.href, response);
        while (this.pages.size > 200 || [...this.pages.values()].reduce((size, page) => size + page.data.length, 0) > 32_000_000)
          this.pages.delete(this.pages.keys().next().value);
      }
      return response;
    }
    throw new Error('Invalid math wiki resource address or redirect.');
  }

  async catalog(course, { fileRecheckInterval = 0 } = {}) {
    const scope = mathWikiCourse(course), items = new Map(), warnings = [], websiteSources = [];
    if (!scope) return { items: [], warnings, complete: true };
    if (!scope.terms.length) return { items: [], warnings: ['Math wiki: no unambiguous course semester was found.'], complete: false };
    const { code, terms } = scope;
    for (const term of terms) {
      const prefix = `${origin}/${code}/${term}`;
      const pageScope = (url) => new URL(url).origin === origin && allowedPage(url, code, term);
      try {
        // Read the archive index so courses with a named entry page work too.
        const archive = parseMathWikiPage((await this.fetch(`${origin}/${code}`, {
          conditional: true,
          pageScope: (url) => url === `${origin}/${code}` || url === `${origin}/${code}/start`,
        })).data.toString());
        const linked = archive.links.map((link) => mathWikiLink(link.href, `${origin}/${code}`))
          .find((link) => link?.kind === 'pages' && (link.url === prefix || link.url.startsWith(prefix + '/')));
        const queue = [linked?.url || `${prefix}/start`], visited = new Set();
        for (let i = 0; i < queue.length; i++) {
          this.signal?.throwIfAborted();
          const url = queue[i];
          if (visited.has(url)) continue;
          if (visited.size >= 100 || items.size >= 1500) { warnings.push(`Math wiki ${term}: the course crawl reached its limit.`); break; }
          visited.add(url);
          try {
            const response = await this.fetch(url, { pageScope, conditional: true });
            visited.add(response.url);
            const page = parseMathWikiPage(response.data.toString());
            websiteSources.push({ html: page.body + page.links.map(link => `<p><a href="${link.href.replaceAll('&', '&amp;').replaceAll('"', '&quot;')}">${link.title.replaceAll('<', '&lt;')}</a></p>`).join(''), url: response.url });
            const id = `math-wiki:${response.url}`, title = page.title || `${code.toUpperCase()} ${term}`;
            const ref = { id, kind: 'pages', remoteID: response.url, title,
              sourceURL: response.url, version: digest(page.body), folderID: -1, folderTitle: 'Math wiki' };
            items.set(id, ref);
            for (const [position, raw] of page.links.entries()) {
              const link = mathWikiLink(raw.href, response.url);
              if (!link) continue;
              if (link.kind === 'pages') {
                if (pageScope(link.url) && !visited.has(link.url) && !queue.includes(link.url)) queue.push(link.url);
              } else {
                const fileID = `math-wiki:${link.url}`;
                if (!items.has(fileID)) items.set(fileID, { id: fileID, kind: 'files', remoteID: link.url,
                  title: raw.title && raw.title !== link.fileName ? `${raw.title} · ${link.fileName}` : link.fileName,
                  fileName: link.fileName, sourceURL: link.url, version: '',
                  linkedFromID: id, linkedFromTitle: title, linkedPosition: position,
                  linkedOrder: [position], linkedSection: raw.section, folderID: -1, folderTitle: 'Math wiki' });
              }
            }
          } catch (error) { this.signal?.throwIfAborted(); warnings.push(`Math wiki ${term}: ${error.message}`); }
        }
      } catch (error) { this.signal?.throwIfAborted(); warnings.push(`Math wiki ${term}: ${error.message}`); }
    }
    const files = [...items.values()].filter((ref) => ref.kind === 'files');
    const previous = new Map((course.canvasMaterials || []).map(ref => [ref.id, ref.version]));
    let next = 0;
    await Promise.all(Array.from({ length: Math.min(6, files.length) }, async () => {
      while (next < files.length) {
        const ref = files[next++];
        const unchangedPage = ref.linkedFromID && previous.get(ref.linkedFromID) === items.get(ref.linkedFromID)?.version;
        await this.fileMetadata(ref, unchangedPage ? fileRecheckInterval : 0);
      }
    }));
    return { items: [...items.values()], warnings, websiteSources, complete: warnings.length === 0 };
  }

  async fileMetadata(ref, recheckInterval = 0) {
    const cached = this.files.get(ref.id);
    if (cached && this.clock() - cached.checkedAt < recheckInterval) {
      ref.version = cached.version; ref.byteCount = cached.byteCount;
      return ref;
    }
    try {
      const { headers } = await this.fetch(ref.sourceURL, { method: 'HEAD', limit: 100_000_000 });
      ref.version = headers.etag || headers['last-modified'] || '';
      if (headers['content-length']) ref.byteCount = Number(headers['content-length']);
    } catch { this.signal?.throwIfAborted(); }
    // Servers without validators still get a periodic GET, never an empty cached version.
    if (!ref.version) ref.version = `unvalidated:${this.clock()}`;
    this.files.delete(ref.id);
    this.files.set(ref.id, { checkedAt: this.clock(), version: ref.version, byteCount: ref.byteCount });
    if (this.files.size > 2000) this.files.delete(this.files.keys().next().value);
    return ref;
  }

  async material(ref, { limit = 100_000_000 } = {}) {
    if (!isMathWikiMaterial(ref) || mathWikiLink(ref.sourceURL)?.kind !== ref.kind)
      throw new Error('Invalid math wiki material.');
    const response = await this.fetch(ref.sourceURL, { limit: ref.kind === 'pages' ? Math.min(limit, 8_000_000) : limit,
      conditional: ref.kind === 'pages',
      pageScope: ref.kind === 'pages' ? (url) => url === ref.sourceURL || url === ref.sourceURL + '/start' : undefined });
    if (ref.kind === 'pages') {
      const page = parseMathWikiPage(response.data.toString());
      return { reference: { ...ref, version: digest(page.body) }, name: `${ref.title}.html`,
        data: Buffer.from(courseHTMLDocument(ref.title, page.body, response.url)) };
    }
    if (/text\/html/i.test(response.headers['content-type'] || '')) throw new Error('The wiki file returned a sign-in or error page.');
    return { reference: ref, name: ref.fileName, data: response.data };
  }
}
