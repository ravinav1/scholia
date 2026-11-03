import { canvasContentLink } from './canvas-links.js';
import { mathWikiLink } from './math-wiki.js';
import { courseWebsiteLink } from './course-websites.js';

export function safeDocumentURL(value, base) {
  if (typeof value !== 'string' || !value.trim()) return '';
  try {
    const url = new URL(value, base || undefined);
    return ['http:', 'https:', 'mailto:'].includes(url.protocol) && !url.username && !url.password
      ? url.href
      : '';
  } catch {
    return '';
  }
}

// Keep source addresses intact: truncating a long URL can silently link to a
// different resource. These are reference locations, not evidence of contents.
export function courseSourceURL(value) {
  if (typeof value !== 'string' || value.length > 2000 || /[\u0000-\u0020\u007f]/.test(value)) return '';
  const url = safeDocumentURL(value);
  return /^https?:/.test(url) ? url : '';
}

export function documentSourceContext(document, course) {
  const reference = document.sourceKey && course?.canvasMaterials?.find((ref) => ref.id === document.sourceKey);
  const url = courseSourceURL(document.sourceURL) || courseSourceURL(reference?.sourceURL);
  return url ? `Source URL (this document): ${url}\n` : '';
}
const escape = (value) =>
  String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

// Keep the original body and its base address. The reader displays this in a
// script-free sandbox; the text index is a separate, link-preserving projection.
export function courseHTMLDocument(title, body, sourceURL) {
  return `<!doctype html><html><head><meta charset="utf-8"><base href="${escape(sourceURL)}"><title>${escape(title)}</title></head><body><h1>${escape(title)}</h1>${body || ''}</body></html>`;
}

export function htmlReadingText(doc, base = '') {
  base = base || doc.querySelector('base[href]')?.getAttribute('href') || '';
  const walk = (node) => {
    if (node.nodeType === 3) return node.textContent;
    const tag = node.tagName?.toLowerCase();
    if (['script', 'style', 'head', 'form'].includes(tag)) return '';
    if (['iframe', 'object', 'embed'].includes(tag)) {
      const url = safeDocumentURL(node.getAttribute('src') || node.getAttribute('data'), base);
      return url ? `\n\n[Open embedded document](${url})\n\n` : '';
    }
    const content = [...(node.childNodes || [])].map(walk).join('');
    if (tag === 'a') {
      const url = safeDocumentURL(node.getAttribute('href'), base);
      return url
        ? `[${content.trim().replace(/[\[\]\\]/g, '\\$&') || 'Open source'}](${url.replaceAll('(', '%28').replaceAll(')', '%29')})`
        : content;
    }
    if (tag === 'br') return '\n';
    if (/^h[1-6]$/.test(tag)) return `\n\n${'#'.repeat(Number(tag[1]))} ${content.trim()}\n\n`;
    if (tag === 'li') return `\n- ${content.trim()}\n`;
    if (['p', 'div', 'section', 'ul', 'ol', 'table', 'tr', 'blockquote'].includes(tag))
      return `\n\n${content}\n\n`;
    if (['td', 'th'].includes(tag)) return `${content}\t`;
    return content;
  };
  return walk(doc.body || doc)
    .replace(/\n[\t ]+/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

export const isHTMLDocument = (doc) => /\.html?$/i.test(doc?.fileName || '');
export const needsCanvasHTMLUpgrade = (doc) =>
  !!doc?.sourceKey &&
  !!doc.fileName &&
  /^(?:pages:|assignments:|syllabus(?::|$))/.test(doc.sourceKey) &&
  !isHTMLDocument(doc);

export function courseLinkTarget(url, course) {
  if (!course) return null;
  const canvas = course.canvasOrigin && course.canvasID && canvasContentLink(url, course.canvasOrigin, course.canvasID);
  const wiki = mathWikiLink(url);
  const site = courseWebsiteLink(url);
  for (const id of [canvas?.id, wiki && `math-wiki:${wiki.url}`, site && `course-web:${site.url}`].filter(Boolean)) {
    const document = course.documents.find((d) => d.sourceKey === id);
    const material = course.canvasMaterials?.find((m) => m.id === id);
    if (document || material) return { document, material, id };
  }
  return null;
}

// Older imports discarded hrefs. Restore only unambiguous, exact labels using
// catalog evidence, without changing the saved original or a student's edits.
export function restoreCourseLinks(text, course, doc) {
  if (!doc?.sourceKey || !course) return text;
  const labels = new Map();
  for (const ref of course.canvasMaterials || []) {
    if (ref.linkedFromID !== doc.sourceKey) continue;
    const url = safeDocumentURL(ref.sourceURL);
    if (!url) continue;
    for (const label of new Set([ref.title, ref.fileName].filter(Boolean))) {
      if (!labels.has(label)) labels.set(label, url);
      else if (labels.get(label) !== url) labels.set(label, null);
    }
  }
  return text
    .split('\n')
    .map((line) => {
      const label = line.trim(),
        url = labels.get(label);
      return url ? `[${label.replace(/[\[\]\\]/g, '\\$&')}](${url})` : line;
    })
    .join('\n');
}

// Use an allowlist inside a sandbox as well as disabling scripts. Course HTML
// must never introduce application controls, forms, frames or active content.
export function originalDocumentHTML(doc, base) {
  base = base || doc.querySelector('base[href]')?.getAttribute('href') || '';
  const allowed = new Set(
    'p div span section article h1 h2 h3 h4 h5 h6 a img table thead tbody tfoot tr td th caption ul ol li blockquote pre code strong b em i u s sub sup br hr figure figcaption dl dt dd'.split(
      ' '
    )
  );
  const clean = (node) => {
    if (node.nodeType === 3) return escape(node.textContent);
    const tag = node.tagName?.toLowerCase();
    if (['iframe', 'object', 'embed'].includes(tag)) {
      const url = safeDocumentURL(node.getAttribute('src') || node.getAttribute('data'), base);
      return url
        ? `<p><a href="${escape(url)}" target="_blank" rel="noopener noreferrer">Open embedded document ↗</a></p>`
        : '';
    }
    if (!allowed.has(tag)) return '';
    let attrs = '';
    if (tag === 'a') {
      const url = safeDocumentURL(node.getAttribute('href'), base);
      if (url) attrs = ` href="${escape(url)}" target="_blank" rel="noopener noreferrer"`;
    }
    if (tag === 'img') {
      const url = safeDocumentURL(node.getAttribute('src'), base);
      if (url && /^https?:/.test(url))
        attrs = ` src="${escape(url)}" alt="${escape(node.getAttribute('alt') || '')}" loading="lazy" referrerpolicy="no-referrer"`;
    }
    for (const key of ['colspan', 'rowspan', 'start']) {
      const value = node.getAttribute(key);
      if (/^\d{1,3}$/.test(value || '')) attrs += ` ${key}="${value}"`;
    }
    return `<${tag}${attrs}>${[...(node.childNodes || [])].map(clean).join('')}</${tag}>`;
  };
  return `<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"><style>body{font:17px/1.65 Georgia,serif;color:#282b28;background:#fffdf8;max-width:880px;margin:32px auto;padding:0 28px}a{color:#246850}img{max-width:100%;height:auto}table{border-collapse:collapse;max-width:100%}td,th{border:1px solid #ddd;padding:8px}pre{white-space:pre-wrap}h1,h2,h3{line-height:1.2}</style></head><body>${[...(doc.body?.childNodes || [])].map(clean).join('')}</body></html>`;
}
