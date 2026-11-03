import { COMPACT_PACKED_CONTEXT_CHARS } from '../../../packages/core/src/context.js';
import { FULL_CONTEXT_CHARS } from './context-mode.js';
import { formatPdfContext } from './pdf-context.js';

export const LARGE_PDF_PAGE_COUNT = 50;
export const LARGE_PDF_CONTEXT_CHARACTERS = 100_000;

function pageExcerpt(text, selection, budget, fromEnd = false) {
  if (text.length <= budget) return text;
  // PDF selection whitespace can differ from extracted line breaks.
  const compact = text.replace(/\s+/g, ' ');
  if (compact.length <= budget) return compact;
  const needle = String(selection || '').replace(/\s+/g, ' ').trim().slice(0, 180);
  const match = needle ? compact.toLowerCase().indexOf(needle.toLowerCase()) : -1;
  const room = Math.max(0, budget - 4);
  const start = match >= 0
    ? Math.max(0, Math.min(compact.length - room, match - Math.floor(room * 0.35)))
    : fromEnd ? Math.max(0, compact.length - room) : 0;
  return `${start ? '… ' : ''}${compact.slice(start, start + room)}${start + room < compact.length ? ' …' : ''}`;
}

export function pdfSelectionPages(range, fallbackPage = 1) {
  const pageNumber = (node) => {
    const element = node?.nodeType === 1 ? node : node?.parentElement;
    return Number(element?.closest?.('.pdf-page')?.dataset?.pageNumber) || 0;
  };
  const start = pageNumber(range?.startContainer);
  const end = pageNumber(range?.endContainer);
  return [...new Set([start, end].filter((page) => page > 0))].sort((a, b) => a - b)
    .concat(start || end ? [] : [fallbackPage]);
}

/** Keep article-sized PDFs whole in Full mode; bound reads for larger documents. */
export async function pdfSelectionMetadata({
  metadata, pageCount, selectedPages = [1], selection = '', readPage, fullContext = false, ...source
}) {
  const complete = metadata && !metadata.pdfLocalContext && !metadata.truncated
    && String(metadata.context || '').trim()
    && (metadata.extractedPageCount == null || metadata.extractedPageCount === pageCount);
  if (fullContext && complete && metadata.context.length <= FULL_CONTEXT_CHARS) return metadata;
  if (!fullContext && complete && pageCount < LARGE_PDF_PAGE_COUNT
      && String(metadata.context || '').length <= LARGE_PDF_CONTEXT_CHARACTERS) return metadata;

  // A selection can arrive before background indexing finishes. Read a short
  // document on demand, stopping as soon as it exceeds the full-context budget.
  // Reuse these reads if we need to fall back to the selected page neighborhood.
  const pageReads = new Map();
  const readText = (page) => {
    if (!pageReads.has(page)) pageReads.set(page, Promise.resolve().then(() => readPage(page)));
    return pageReads.get(page);
  };
  if (fullContext && !complete && pageCount > 0 && pageCount < LARGE_PDF_PAGE_COUNT) {
    const texts = [];
    let characters = 0;
    for (let page = 1; page <= pageCount; page += 1) {
      let text;
      try { text = String(await readText(page) || '').trim(); } catch { break; }
      characters += `[PDF page ${page} of ${pageCount}]\n`.length
        + (text || '(No extractable text on this page.)').length + (page > 1 ? 2 : 0);
      if (characters > FULL_CONTEXT_CHARS) break;
      texts.push(text);
    }
    if (texts.length === pageCount) {
      return { ...metadata, ...source, ...formatPdfContext(texts, pageCount), pdfLocalContext: false, truncated: false };
    }
  }

  const validPage = (page) => Number.isInteger(page) && page >= 1 && page <= pageCount;
  const anchors = [...new Set(selectedPages.filter(validPage))].slice(0, 2);
  if (!anchors.length) anchors.push(1);
  const candidates = [...anchors];
  // Include pages between selection endpoints before expanding outward.
  if (anchors.length === 2 && anchors[1] - anchors[0] === 2) candidates.push(anchors[0] + 1);
  for (const page of anchors) candidates.push(page - 1, page + 1);
  const pages = [...new Set(candidates.filter(validPage))].slice(0, 5).sort((a, b) => a - b);
  const heading = `Local PDF context: selected page(s) ${anchors.join(', ')} and nearby pages. The rest of the document is not included.`;
  const labels = pages.map((page) => `[PDF page ${page} of ${pageCount}]\n`);
  const available = COMPACT_PACKED_CONTEXT_CHARS - heading.length
    - labels.reduce((sum, label) => sum + label.length + 2, 0);
  const neighborCount = pages.length - anchors.length;
  const anchorBudget = Math.floor(available * (neighborCount ? 0.8 : 1) / anchors.length);
  const neighborBudget = neighborCount ? Math.floor(available * 0.2 / neighborCount) : 0;
  const excerpts = [];
  for (const page of pages) {
    let text;
    try {
      text = String(await readText(page) || '').trim() || '(No extractable text on this page.)';
    } catch {
      text = '(Text could not be extracted from this page.)';
    }
    const isAnchor = anchors.includes(page);
    excerpts.push(`[PDF page ${page} of ${pageCount}]\n${pageExcerpt(
      text, isAnchor ? selection : '', isAnchor ? anchorBudget : neighborBudget, page < anchors[0]
    )}`);
  }
  const context = `${heading}\n\n${excerpts.join('\n\n')}`;
  return {
    ...source,
    context,
    outline: pages.map((page) => `- PDF page ${page} of ${pageCount}`).join('\n'),
    pageCount,
    extractedPageCount: pages.length,
    extractedCharacters: context.length,
    pdfLocalContext: true
  };
}
