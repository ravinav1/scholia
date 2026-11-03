import { siteIsEnabled } from '../../../packages/core/src/providers.js';
import { loadCanvasCourseIndex } from './canvas-index.js';
import { canvasCourseFromUrl, isCanvasCoursePage } from './canvas-course.js';
import { extractPdfContext } from './pdf-context.js';
import { extractOfficeText } from './office-text.js';
import { parseSiteHtml } from './site-context.js';
import { researchUrl, researchLinksFromDocument } from './research-links.js';
import { crawlResearch, packResearchContext } from './research-crawl.js';

export function createResearchAccess({ settings, yolo = false, review, signal } = {}) {
  const approved = new Set(), denied = new Set();
  const canRead = (url) => Boolean(researchUrl(url) && siteIsEnabled(settings, url));
  const approve = async (links) => {
    signal?.throwIfAborted();
    const sites = new Map();
    for (const link of links) {
      if (!canRead(link.url)) continue;
      const origin = new URL(link.url).origin;
      if (!approved.has(origin) && !denied.has(origin)) sites.set(origin, { origin, url: link.url, title: link.title || '' });
    }
    if (sites.size) {
      const selected = yolo ? [...sites.keys()] : await review?.([...sites.values()]);
      signal?.throwIfAborted();
      for (const origin of sites.keys()) (selected?.includes(origin) ? approved : denied).add(origin);
    }
    return new Set([...approved].filter(canRead));
  };
  return { canRead, approve };
}

async function responseBlob(response, maxBytes) {
  if (Number(response.headers.get('content-length')) > maxBytes) throw new Error('Document exceeds the reading size limit');
  const chunks = [];
  let size = 0;
  const reader = response.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) throw new Error('Document exceeds the reading size limit');
      chunks.push(value);
    }
  } finally { await reader.cancel().catch(() => {}); }
  return new Blob(chunks, { type: response.headers.get('content-type') || '' });
}

export async function fetchResearchPage(url, { signal, canRead = () => true, fetchImpl = fetch } = {}) {
  const target = researchUrl(url);
  if (!target || !canRead(target)) throw new Error('Site is outside your allowed scope');
  const requestSignal = signal ? AbortSignal.any([signal, AbortSignal.timeout(12_000)]) : AbortSignal.timeout(12_000);
  // A redirect can leave an approved site or reach a state-changing URL. Do
  // not follow it invisibly; the user can open the final page and ask there.
  const response = await fetchImpl(target, { method: 'GET', credentials: 'include', redirect: 'error', signal: requestSignal });
  if (!response.ok) throw new Error(`HTTP ${response.status}${[401, 403].includes(response.status) ? ' — sign in or check access' : ''}`);
  const finalUrl = researchUrl(response.url || target);
  if (!finalUrl || !canRead(finalUrl) || new URL(finalUrl).origin !== new URL(target).origin) throw new Error('Page left the approved site');
  const type = String(response.headers.get('content-type') || '').toLowerCase();
  const name = decodeURIComponent(new URL(finalUrl).pathname.split('/').at(-1) || 'Document');
  const pdf = type.includes('application/pdf') || /\.pdf$/i.test(name);
  const office = /\.(docx|pptx|xlsx)$/i.test(name);
  if (!pdf && !office && !/^(?:text\/|application\/(?:xhtml\+xml|json|xml))/.test(type)) throw new Error('Unsupported document type');
  const blob = await responseBlob(response, pdf || office ? 25 * 1024 * 1024 : 3 * 1024 * 1024);
  signal?.throwIfAborted();
  if (pdf) {
    const result = await extractPdfContext(blob, { signal, maxCharacters: 120_000 });
    return { url: finalUrl, title: result.title || name, text: result.context, truncated: result.truncated, links: [] };
  }
  if (office) {
    const result = await extractOfficeText(new File([blob], name, { type }), 120_000);
    signal?.throwIfAborted();
    return { url: finalUrl, title: name, text: result.text, truncated: result.truncated, links: [] };
  }
  const text = await blob.text();
  if (!/html/.test(type)) return { url: finalUrl, title: name, text, links: [] };
  const doc = new DOMParser().parseFromString(text, 'text/html');
  if (doc.querySelector('input[type="password"]')) throw new Error('Sign-in page — open this site and sign in');
  const links = researchLinksFromDocument(doc, finalUrl);
  return { ...parseSiteHtml(text, finalUrl), links,
    ...(isCanvasCoursePage(finalUrl, doc) ? { canvasCourse: canvasCourseFromUrl(finalUrl) } : {}) };
}

export async function getBrowserResearchContext(source, {
  question, selection = '', maxChars = 6000, settings, yolo = false, signal,
  review, readLivePage, onProgress = () => {}
} = {}) {
  const access = createResearchAccess({ settings, yolo, review, signal });
  const url = researchUrl(source.researchUrl || source.url);
  if (!url || !access.canRead(url)) throw new Error('Enable Scholia on the source site before following links.');
  const permission = await access.approve([{ url, title: source.pageTitle }]);
  signal?.throwIfAborted();
  if (!permission.has(new URL(url).origin)) throw new Error('Research cancelled: the source site was not approved.');
  onProgress('Reading the source page and discovering links…');
  let seed = readLivePage ? await readLivePage().catch(() => null) : null;
  signal?.throwIfAborted();
  if (researchUrl(seed?.url) !== url) seed = null;
  const initialPages = [], links = [], failures = [];
  if (!seed) {
    try { seed = await fetchResearchPage(url, { signal, canRead: access.canRead }); }
    catch (error) { signal?.throwIfAborted(); failures.push({ url, reason: error.message }); }
  }
  const canvasCourse = source.canvasCourse || seed?.canvasCourse;
  if (canvasCourse) {
    try {
      const index = await loadCanvasCourseIndex(url, { signal, onProgress, approveFile: async (target, title) => {
        // Signed download parameters stay inside Canvas's file reader. Review
        // the storage origin without exposing those parameters to chat/history.
        const origin = new URL(target).origin;
        const allowed = await access.approve([{ url: `${origin}/`, title: `Course file: ${title}` }]);
        return allowed.has(origin);
      } });
      for (const doc of index.documents) initialPages.push({ ...doc,
        text: doc.stale ? `[Saved source; may be stale]\n${doc.text}` : doc.text, links: doc.researchLinks || [] });
      links.push(...(index.researchLinks || []));
      if (index.partial) failures.push({ url, reason: 'Some Canvas materials were unavailable' });
    } catch (error) { signal?.throwIfAborted(); failures.push({ url, reason: error.message }); }
  }
  if (seed?.text) initialPages.push(seed);
  const result = await crawlResearch({ question, selection, initialPages, links,
    signal, onProgress, maxCharacters: 3_200_000,
    canRead: access.canRead, approve: access.approve,
    readPage: (target, options) => fetchResearchPage(target, { ...options, canRead: access.canRead })
  });
  signal?.throwIfAborted();
  result.failures.push(...failures);
  if (!result.pages.length) throw new Error('No readable sources were found. Open the source, check sign-in, or adjust the approved sites.');
  return {
    context: packResearchContext(result, { question, selection, maxChars }),
    contextState: `Research · ${result.pages.length} sources${result.truncated || result.failures.length ? ' · partial' : ''}`,
    contextNotice: `Followed links for this question · ${result.requests} page reads${yolo ? ' · YOLO' : ' · approved sites'}${result.failures.length ? ` · ${result.failures.length} skipped or unavailable` : ''}${result.truncated ? ' · reading limit reached' : ''}`,
    researchSources: result.pages.map(({ title, url }) => ({ title, url })).slice(0, 300),
    ...(canvasCourse ? { canvasCourse } : {})
  };
}
