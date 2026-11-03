import { normalizeSearch, searchTerms } from './needle.js';

// Metadata only: finding a book must never wait for PDF extraction or a disk scan.
// Cache normalized names, not results, so renamed/removed files appear immediately.
export class FileNameSearch {
  constructor() { this.names = new Map(); }
  search(files, query, { courseID = '', limit = 60, signal } = {}) {
    const start = performance.now(), terms = searchTerms(query), hits = [];
    const active = new Set();
    let count = 0, remote = 0;
    for (const file of files) {
      signal?.throwIfAborted();
      active.add(file.id);
      if (courseID && file.courseID !== courseID) continue;
      count++;
      if (!file.documentID) remote++;
      const raw = `${file.title}\n${file.fileName || ''}\n${file.courseName || ''}`;
      let name = this.names.get(file.id);
      if (name?.raw !== raw) {
        name = { raw, text: normalizeSearch(raw), words: normalizeSearch(raw.replace(/([a-z])([A-Z])/g, '$1 $2')).split(/[^\p{L}\p{N}]+/u) };
        this.names.set(file.id, name);
      }
      if (!terms.length) continue;
      let approximate = false;
      if (!terms.every((term) => {
        if (name.text.includes(term)) return true;
        // Long single words tolerate one typo; phrases and short codes stay literal.
        if (term.length >= 5 && /^[\p{L}\p{N}]+$/u.test(term) && name.words.some((word) => oneEditPrefix(term, word))) {
          approximate = true;
          return true;
        }
        return false;
      })) continue;
      const { indexPath: _indexPath, ...metadata } = file;
      hits.push({ ...metadata, page: 0, passages: 1, approximate, snippet: name.text.slice(0, 260) });
    }
    for (const id of this.names.keys()) if (!active.has(id)) this.names.delete(id);
    hits.sort((a, b) => Number(a.approximate) - Number(b.approximate) || a.title.localeCompare(b.title) || a.id.localeCompare(b.id));
    return { results: hits.slice(0, limit), total: hits.length, terms,
      coverage: { files: count, remoteFiles: remote, contentFiles: 0, unavailableFiles: 0 },
      strategy: 'names', queryMs: performance.now() - start, totalMs: performance.now() - start,
      updatedFiles: 0, candidateUpperBound: count };
  }
}

function oneEditPrefix(term, word) {
  for (const size of [term.length - 1, term.length, term.length + 1]) {
    if (word.length < size) continue;
    const prefix = word.slice(0, size);
    let i = 0, j = 0, edits = 0;
    while (i < term.length && j < prefix.length) {
      if (term[i] === prefix[j]) { i++; j++; continue; }
      if (++edits > 1) break;
      if (term.length >= prefix.length) i++;
      if (prefix.length >= term.length) j++;
    }
    if (edits + (term.length - i) + (prefix.length - j) <= 1) return true;
  }
  return false;
}
