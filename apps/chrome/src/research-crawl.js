import { packPageContext } from '../../../packages/core/src/context.js';
import { researchUrl, promptResearchLinks } from './research-links.js';

const STOP_WORDS = new Set('the and for that this with from have what which where when about please find search scour through relevant information could would given also canvas website sites links explain show meg og til det som med fra hva hvordan finn om'.split(' '));
function terms(value) {
  return [...new Set((String(value || '').toLowerCase().match(/[\p{L}\p{N}]{2,}/gu) || [])
    .filter((term) => !STOP_WORDS.has(term)))].slice(0, 80);
}
function score(value, query) {
  const text = String(value || '').toLowerCase();
  return query.reduce((total, term) => total + (text.includes(term) ? 1 : 0), 0);
}

// The reader is injected: this graph walker cannot click, submit, or execute
// instructions from a page. Budgets count attempts, including failed requests.
export async function crawlResearch({
  question = '', selection = '', initialPages = [], links = [], readPage,
  canRead = () => true, approve = async () => false, signal, onProgress = () => {},
  maxRequests = 36, maxDepth = 3, maxCharacters = 2_000_000, maxDurationMs = 45_000
} = {}) {
  signal?.throwIfAborted();
  const query = terms(`${question}\n${selection}`), queue = new Map(), visited = new Set(), pages = [];
  const failures = [];
  let totalCharacters = 0, requests = 0, truncated = false, elapsed = 0;
  const enqueue = (link, base, depth) => {
    const item = typeof link === 'string' ? { url: link } : link;
    const url = researchUrl(item?.url, base);
    if (!url || visited.has(url) || depth > maxDepth || !canRead(url)) return;
    const priority = (item.explicit ? 1000 : 0) + score(`${item.title || ''} ${url}`, query) * 20 - depth * 2;
    if (queue.has(url) && queue.get(url).priority >= priority) return;
    if (queue.size >= 2000) { truncated = true; return; }
    queue.set(url, { ...item, url, depth, priority });
  };
  const append = (page, depth) => {
    const url = researchUrl(page?.url);
    if (!url || !canRead(url)) return;
    visited.add(url); queue.delete(url);
    for (const link of page.links || []) {
      if (depth >= maxDepth) { if (researchUrl(link?.url || link, url)) truncated = true; }
      else enqueue(link, url, depth + 1);
    }
    const text = String(page.text || '').slice(0, Math.max(0, Math.min(120_000, maxCharacters - totalCharacters))).trim();
    if (text.length < String(page.text || '').trim().length || page.truncated) truncated = true;
    if (!text || pages.some((entry) => entry.url === url)) return;
    pages.push({ url, title: String(page.title || url).slice(0, 300), text });
    totalCharacters += text.length;
  };
  // Explicit URLs are queued first; a new question always builds a new frontier.
  for (const link of promptResearchLinks(question)) enqueue(link, undefined, 0);
  for (const page of initialPages) append(page, 0);
  for (const link of links) enqueue(link, undefined, 1);

  while (queue.size && requests < maxRequests && totalCharacters < maxCharacters && elapsed < maxDurationMs) {
    signal?.throwIfAborted();
    const batch = [...queue.values()].sort((a, b) => b.priority - a.priority)
      .slice(0, Math.min(3, maxRequests - requests));
    // Review time does not consume the network time budget.
    const allowed = await approve(batch);
    signal?.throwIfAborted();
    const started = Date.now();
    const deadline = AbortSignal.timeout(Math.max(1, Math.ceil(maxDurationMs - elapsed)));
    const batchSignal = signal ? AbortSignal.any([signal, deadline]) : deadline;
    const results = await Promise.all(batch.map(async (item) => {
      queue.delete(item.url); visited.add(item.url);
      if (allowed !== true && !allowed?.has?.(new URL(item.url).origin)) {
        failures.push({ url: item.url, reason: 'Skipped by you' }); return null;
      }
      requests++;
      onProgress(`Reading ${requests}/${maxRequests} · ${item.title || item.url}`);
      try {
        const page = await readPage(item.url, { signal: batchSignal });
        if (!page?.text) throw new Error('No readable text');
        return { page, depth: item.depth };
      } catch (error) {
        signal?.throwIfAborted();
        failures.push({ url: item.url, reason: String(error.message || 'Unavailable').slice(0, 160) });
        return null;
      }
    }));
    elapsed += Date.now() - started;
    if (deadline.aborted) truncated = true;
    signal?.throwIfAborted();
    for (const result of results) if (result) append(result.page, result.depth);
  }
  return { pages, failures, requests, totalCharacters, truncated: truncated || queue.size > 0 };
}

// Keep the source URL with every excerpt, including excerpts cut from a long
// document. A global pack of concatenated pages can lose that association.
export function packResearchContext(result, { question = '', selection = '', maxChars = 6000 } = {}) {
  const limit = Math.max(1000, Math.min(120_000, Number(maxChars) || 6000));
  const query = terms(`${question}\n${selection}`);
  const ranked = result.pages.map((page) => ({ page, rank: score(`${page.title} ${page.url}`, query) * 4 + score(page.text, query) }))
    .sort((a, b) => b.rank - a.rank);
  const status = [
    `Browser research: ${result.pages.length} readable sources.`,
    result.truncated ? 'Partial coverage: the reading budget was reached.' : '',
    result.failures.length ? `${result.failures.length} links were skipped or unavailable.` : '',
    'Only the excerpts below are evidence; unread links have not been verified.'
  ].filter(Boolean).join(' ');
  let context = status;
  const count = Math.min(ranked.length, Math.max(1, Math.floor((limit - status.length) / 1400)));
  for (const { page } of ranked.slice(0, count)) {
    const heading = `\n\n[Source]\nTitle: ${page.title}\nURL: ${page.url}\n`;
    const budget = Math.floor((limit - status.length) / count) - heading.length;
    if (budget < 100) continue;
    const text = packPageContext(page.text, { question, selection, maxChars: Math.max(1000, budget) }).slice(0, budget);
    context += heading + text;
  }
  return context.slice(0, limit);
}
