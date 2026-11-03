import { DatabaseSync } from 'node:sqlite';

// Needle is a literal retrieval index, not a semantic approximation. The FTS
// trigram index only selects candidates; literal checks verify every term.
export const normalizeSearch = (text) =>
  String(text ?? '')
    .toWellFormed()
    .normalize('NFKC')
    .toLowerCase()
    .replace(/[\s\0]+/gu, ' ')
    .trim();

export function searchTerms(query) {
  if (typeof query !== 'string' || query.length > 512 || query.includes('\0'))
    throw new Error('Use a search of at most 512 characters.');
  const terms = [
    ...new Set(
      [...query.matchAll(/"([^"]*)"|"([^"]*)$|([^\s"]+)/gu)]
        .map((m) => normalizeSearch(m[1] ?? m[2] ?? m[3]))
        .filter(Boolean)
    ),
  ];
  if (terms.length > 32) throw new Error('Use at most 32 search terms.');
  return terms;
}

export class NeedleIndex {
  constructor(path = ':memory:', { maxTextBytes = 64 * 1024 * 1024 } = {}) {
    this.db = new DatabaseSync(path);
    this.maxTextBytes = maxTextBytes;
    this.statements = new Map();
    this.inBatch = false;
    this.invalidate();
    try {
      this.db.exec(`
      PRAGMA foreign_keys=ON;
      PRAGMA busy_timeout=5000;
      PRAGMA journal_mode=WAL;
      PRAGMA synchronous=NORMAL;
      PRAGMA cache_size=-4096;
      PRAGMA mmap_size=268435456;
      CREATE TABLE IF NOT EXISTS files (
        id TEXT PRIMARY KEY, course TEXT NOT NULL, revision TEXT NOT NULL,
        data TEXT NOT NULL, coverage TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS files_course ON files(course);
      CREATE TABLE IF NOT EXISTS passages (
        id INTEGER PRIMARY KEY, file TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        page INTEGER NOT NULL, text TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS passages_file ON passages(file, page);
      CREATE VIRTUAL TABLE IF NOT EXISTS fragments USING fts5(
        text, content='passages', content_rowid='id', tokenize='trigram case_sensitive 1', detail=none
      );
      CREATE VIRTUAL TABLE IF NOT EXISTS fragment_counts USING fts5vocab(fragments,'row');
      CREATE TRIGGER IF NOT EXISTS passages_add AFTER INSERT ON passages BEGIN
        INSERT INTO fragments(rowid,text) VALUES(new.id,new.text);
      END;
      CREATE TRIGGER IF NOT EXISTS passages_remove AFTER DELETE ON passages BEGIN
        INSERT INTO fragments(fragments,rowid,text) VALUES('delete',old.id,old.text);
      END;
    `);
    } catch (error) {
      this.db.close();
      throw error;
    }
    this.dataVersion = this.prepare('PRAGMA data_version').get().data_version;
  }
  prepare(sql) {
    let statement = this.statements.get(sql);
    if (!statement) {
      if (this.statements.size >= 128) this.statements.delete(this.statements.keys().next().value);
      statement = this.db.prepare(sql);
      this.statements.set(sql, statement);
    }
    return statement;
  }
  invalidate() {
    this.stats = new Map();
    this.frequencies = new Map();
    this.metadata = new Map();
    this.snapshot = null;
    this.snapshotBytes = 0;
    this.revisionCache = null;
  }
  checkExternalChanges() {
    const version = this.prepare('PRAGMA data_version').get().data_version;
    if (version !== this.dataVersion) {
      this.invalidate();
      this.dataVersion = version;
    }
  }
  batch(work) {
    if (this.inBatch) return work();
    this.checkExternalChanges();
    this.db.exec('BEGIN IMMEDIATE');
    this.inBatch = true;
    this.dirty = false;
    try {
      const value = work();
      this.db.exec('COMMIT');
      return value;
    } catch (error) {
      this.db.exec('ROLLBACK');
      this.invalidate();
      throw error;
    } finally {
      this.inBatch = false;
      if (this.dirty) this.invalidate();
    }
  }
  changed() {
    if (!this.inBatch || !this.dirty) {
      this.invalidate();
      this.dirty = true;
    }
  }
  revisions() {
    this.checkExternalChanges();
    return (this.revisionCache ??= new Map(
      this.prepare('SELECT id, revision FROM files')
        .all()
        .map((r) => [r.id, r.revision])
    ));
  }
  remove(id) {
    this.changed();
    this.prepare('DELETE FROM files WHERE id=?').run(id);
  }
  put(file, pages, revision, coverage = 'ready', checkCancelled = () => {}) {
    return this.batch(() => {
      this.remove(file.id);
      this.prepare('INSERT INTO files VALUES(?,?,?,?,?)').run(
        file.id,
        file.courseID,
        revision,
        JSON.stringify(file),
        coverage
      );
      const insert = this.prepare('INSERT INTO passages(file,page,text) VALUES(?,?,?)');
      insert.run(file.id, 0, normalizeSearch(`${file.title}\n${file.fileName || ''}\n${file.courseName || ''}`));
      for (const page of pages) {
        checkCancelled();
        const text = normalizeSearch(page.text);
        if (text) insert.run(file.id, page.number, text);
      }
    });
  }
  scopeStats(courseID) {
    if (this.stats.has(courseID)) return this.stats.get(courseID);
    const args = courseID ? [courseID] : [];
    const coverage = this.prepare(
      `SELECT count(*) AS files,
      coalesce(sum(coverage='ready'),0) AS contentFiles,
      coalesce(sum(coverage='remote'),0) AS remoteFiles,
      coalesce(sum(coverage='unavailable'),0) AS unavailableFiles FROM files ${courseID ? 'WHERE course=?' : ''}`
    ).get(...args);
    const rows = this.prepare(
      courseID
        ? 'SELECT count(*) AS n FROM passages p JOIN files f ON f.id=p.file WHERE f.course=?'
        : 'SELECT count(*) AS n FROM passages'
    ).get(...args).n;
    const value = { coverage, rows };
    if (this.stats.size >= 128) this.stats.delete(this.stats.keys().next().value);
    this.stats.set(courseID, value);
    return value;
  }
  scanSnapshot(courseID, checkCancelled) {
    if (this.snapshot && (!this.snapshot.scope || this.snapshot.scope === courseID))
      return this.snapshot.files;
    const where = courseID ? 'WHERE f.course=?' : '',
      args = courseID ? [courseID] : [];
    const stats = this.scopeStats(courseID);
    const size = (stats.textBytes ??= this.prepare(
      `SELECT coalesce(sum(length(cast(p.text AS BLOB))*2+128),0) AS bytes
      FROM passages p JOIN files f ON f.id=p.file ${where}`
    ).get(...args).bytes);
    if (size > this.maxTextBytes) return null;
    // Flat page arrays and built-in substring search avoid SQL row conversion
    // on each broad query. The UTF-16 + row-overhead estimate bounds retention.
    this.snapshot = null;
    this.snapshotBytes = 0;
    const files = [];
    let current;
    for (const row of this.prepare(
      `SELECT p.file,p.page,p.text,f.course FROM passages p
      JOIN files f ON f.id=p.file ${where} ORDER BY p.file,p.page`
    ).iterate(...args)) {
      if (!current || current.id !== row.file) {
        checkCancelled();
        current = { id: row.file, course: row.course, pages: [] };
        files.push(current);
      }
      current.pages.push({ page: row.page, text: row.text });
    }
    this.snapshot = { scope: courseID, files };
    this.snapshotBytes = size;
    return files;
  }
  search(
    query,
    { courseID = '', mode = 'all', limit = 60, scan = false, checkCancelled = () => {} } = {}
  ) {
    const start = performance.now(),
      terms = searchTerms(query);
    if (!['all', 'files', 'content'].includes(mode)) throw new Error('Unknown search mode.');
    checkCancelled();
    this.checkExternalChanges();
    const { coverage, rows: scopedRows } = this.scopeStats(courseID);
    // Positions are unnecessary: select up to three rare fragments, then verify
    // the complete literals. Sampling affects selectivity, never recall.
    const grams = [
      ...new Set(
        terms.flatMap((term) => {
          const chars = [...term];
          return chars.slice(2).map((_, i) => chars.slice(i, i + 3).join(''));
        })
      ),
    ];
    const frequency = this.prepare('SELECT doc FROM fragment_counts WHERE term=?');
    let anchors = [];
    if (!scan)
      for (let i = 0, n = Math.min(24, grams.length); i < n; i++) {
        const gram = grams[Math.floor((i * grams.length) / n)];
        let rows = this.frequencies.get(gram);
        if (rows === undefined) {
          rows = frequency.get(gram)?.doc || 0;
          if (this.frequencies.size >= 512)
            this.frequencies.delete(this.frequencies.keys().next().value);
          this.frequencies.set(gram, rows);
        }
        anchors.push({ gram, rows });
        if (!rows) break;
      }
    anchors.sort((a, b) => a.rows - b.rows);
    anchors = anchors.slice(0, 3);
    const missing = anchors.length > 0 && anchors[0].rows === 0;
    const useIndex = anchors.length > 0 && anchors[0].rows < scopedRows / 2;
    const params = [],
      conditions = [];
    if (useIndex && !missing) {
      conditions.push('p.id IN (SELECT rowid FROM fragments WHERE fragments MATCH ?)');
      params.push(anchors.map(({ gram }) => `"${gram.replaceAll('"', '""')}"`).join(' AND '));
    }
    if (courseID) {
      conditions.push('f.course=?');
      params.push(courseID);
    }
    if (mode === 'files') conditions.push('p.page=0');
    if (mode === 'content') conditions.push('p.page>0');
    const verificationTerms = [...terms].sort((a, b) => b.length - a.length);
    for (const term of verificationTerms) {
      conditions.push('instr(p.text,?)>0');
      params.push(term);
    }
    let hits = [],
      memoryScan = false;
    if (terms.length && !missing) {
      const snapshot = !scan && !useIndex ? this.scanSnapshot(courseID, checkCancelled) : null;
      if (snapshot) {
        memoryScan = true;
        for (const file of snapshot) {
          if (courseID && file.course !== courseID) continue;
          checkCancelled();
          let first,
            count = 0;
          for (const page of file.pages) {
            if ((mode === 'files' && page.page !== 0) || (mode === 'content' && page.page === 0))
              continue;
            let matches = true;
            for (const term of verificationTerms)
              if (!page.text.includes(term)) {
                matches = false;
                break;
              }
            if (matches) {
              first ??= page;
              count++;
            }
          }
          if (first)
            hits.push({ file: file.id, page: first.page, passages: count, text: first.text });
        }
        hits.sort(
          (a, b) =>
            Number(b.page === 0) - Number(a.page === 0) ||
            (a.file < b.file ? -1 : a.file > b.file ? 1 : 0)
        );
      } else
        hits = this.prepare(
          `
      SELECT p.file, min(p.page) AS page, count(*) AS passages
      FROM passages p JOIN files f ON f.id=p.file
      WHERE ${conditions.join(' AND ')} GROUP BY p.file
      ORDER BY (min(p.page)=0) DESC, p.file
    `
        ).all(...params);
    }
    const read = this.prepare(`SELECT f.data,p.text FROM files f JOIN passages p ON p.file=f.id
      WHERE f.id=? AND p.page=? LIMIT 1`);
    const results = hits
      .slice(0, Math.max(1, Math.min(200, Math.floor(Number(limit) || 60))))
      .map((hit) => {
        let data = this.metadata.get(hit.file),
          text = hit.text;
        if (!data || text === undefined) {
          const row = read.get(hit.file, hit.page);
          data ??= JSON.parse(row.data);
          text ??= row.text;
          if (this.metadata.size >= 512) this.metadata.delete(this.metadata.keys().next().value);
          this.metadata.set(hit.file, data);
        }
        const first = Math.min(...terms.map((term) => text.indexOf(term)).filter((at) => at >= 0));
        const offset = Math.max(0, first - 70);
        return {
          ...data,
          page: hit.page,
          passages: hit.passages,
          snippet: `${offset ? '…' : ''}${text.slice(offset, offset + 260)}${text.length > offset + 260 ? '…' : ''}`,
        };
      });
    return {
      results,
      total: hits.length,
      terms,
      coverage,
      strategy: missing ? 'absent' : useIndex ? 'trigram' : memoryScan ? 'memory-scan' : 'scan',
      textCacheBytes: this.snapshotBytes,
      candidateUpperBound: missing
        ? 0
        : useIndex
          ? Math.min(scopedRows, anchors[0].rows)
          : scopedRows,
      queryMs: performance.now() - start,
    };
  }
  close() {
    this.invalidate();
    this.statements.clear();
    this.db.close();
  }
}
