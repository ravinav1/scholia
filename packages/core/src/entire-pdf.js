export const MAX_ENTIRE_PDF_CHARS = 750_000;
export const ENTIRE_PDF_QUESTION = 'Read the entire PDF and explain its main ideas, structure, and conclusions, with page references.';
export const ENTIRE_PDF_INSTRUCTIONS = 'Read every supplied PDF page before answering. Explain the document as a whole when asked for an overview, including its later sections and conclusion; do not limit the answer to the current page. Cite page numbers. The supplied PDF contains extracted text, including OCR when available. Images and diagrams are visible only when separately attached. Disclose unreadable pages and uncertain OCR; do not claim to have seen unprovided visuals.';
const sizeError = (format = 'PDF') => new Error(`This ${format} is too large to send in full (750,000 characters). Split it into smaller files or use the regular page context. No partial ${format} was sent.`);

export function entirePdfContext({ title = 'PDF', pages, pageCount = pages?.length, truncated = false, kind = 'pdf' }) {
  const format = kind === 'pdf' ? 'PDF' : 'document';
  const label = kind === 'pdf' ? 'Entire PDF' : 'Whole document';
  if (!Number.isInteger(pageCount) || pageCount < 1 || !Array.isArray(pages)
    || pages.length !== pageCount || truncated) {
    throw new Error(`The entire ${format} is not ready: some pages are missing or shortened. Wait for indexing to finish and try again.`);
  }
  const unreadable = [];
  const sections = Array.from(pages, (page, index) => {
    if (typeof page !== 'string') throw new Error(`${format} page ${index + 1} could not be read. Try opening the ${format} again.`);
    if (!page.trim()) unreadable.push(index + 1);
    return `[${format} page ${index + 1} of ${pageCount}]\n${page.trim() || '[No readable text on this page.]'}`;
  });
  if (unreadable.length === pageCount) throw new Error(`This ${format} has no readable text. Finish OCR or attach images of the pages.`);
  const coverage = `${label}: ${title}\nAll ${pageCount} pages of extracted text are included, in order.`;
  const notice = unreadable.length
    ? `\nNo readable text on pages ${unreadable.join(', ')}. Their visual content is not included.` : '';
  const context = `${coverage}${notice}\n\n${sections.join('\n\n')}`;
  if (context.length > MAX_ENTIRE_PDF_CHARS) throw sizeError(format);
  return { context, pageCount, unreadablePages: unreadable, summary: `${label} · ${pageCount} pages of text${unreadable.length ? ` · ${unreadable.length} unreadable` : ''}` };
}

export async function readEntirePdf({ pageCount, readPage, title, signal, onProgress = () => {} }) {
  if (!Number.isInteger(pageCount) || pageCount < 1) throw new Error('Open a readable PDF before sending it in full.');
  const pages = [];
  let size = 0;
  for (let page = 1; page <= pageCount; page += 1) {
    signal?.throwIfAborted();
    const text = await readPage(page);
    if (typeof text !== 'string') throw new Error(`PDF page ${page} could not be read.`);
    size += text.length;
    if (size > MAX_ENTIRE_PDF_CHARS) throw sizeError();
    pages.push(text);
    onProgress(page, pageCount);
  }
  signal?.throwIfAborted();
  return entirePdfContext({ title, pageCount, pages });
}
