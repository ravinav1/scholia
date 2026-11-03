import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';
import { mkdirSync, chmodSync, readFileSync, statSync, writeFileSync, renameSync, openSync, readSync, closeSync } from 'node:fs';
import { dirname } from 'node:path';
import { setImmediate as yieldTurn } from 'node:timers/promises';
import { Index, exactSearch } from 'usearch';
import { LocalSemanticEmbedder } from './semantic-embedding.js';

const digest = text => createHash('sha256').update(text).digest('hex');
const vectorFromBlob = blob => new Float32Array(Uint8Array.from(blob).buffer);
const vectorBlob = vector => Buffer.from(vector.buffer, vector.byteOffset, vector.byteLength);
const fileDigest = path => {
  const hash = createHash('sha256'), buffer = Buffer.allocUnsafe(1024 * 1024), fd = openSync(path, 'r');
  try { let count; while ((count = readSync(fd, buffer))) hash.update(buffer.subarray(0, count)); }
  finally { closeSync(fd); }
  return hash.digest('hex');
};

// SQLite owns metadata, page locations, revisions, and deduplicated embeddings.
// HNSW is a rebuildable acceleration structure; it never owns document identity.
export class SemanticIndex {
  constructor(path, { embedder = new LocalSemanticEmbedder(), scopeCacheBytes = 32 * 1024 * 1024 } = {}) {
    this.path = path; this.embedder = embedder; this.scopeCacheBytes = scopeCacheBytes;
    this.statements = new Map(); this.files = new Map(); this.scopes = new Set();
    this.queryCache = new Map(); this.coverageCache = new Map(); this.completedScopes = new Map();
    this.generation = 0; this.closed = false; this.indexReady = false;
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(path); chmodSync(path, 0o600);
    this.db.exec(`PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
      PRAGMA busy_timeout=5000; PRAGMA cache_size=-4096; PRAGMA mmap_size=268435456;
      CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS files(id TEXT PRIMARY KEY,course TEXT NOT NULL,data TEXT NOT NULL,
        revision TEXT NOT NULL,status TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS files_course ON files(course);
      CREATE INDEX IF NOT EXISTS files_pending ON files(id) WHERE status='pending';
      CREATE TABLE IF NOT EXISTS vectors(id INTEGER PRIMARY KEY AUTOINCREMENT,hash TEXT NOT NULL UNIQUE,
        text TEXT NOT NULL,embedding BLOB);
      CREATE INDEX IF NOT EXISTS vectors_pending ON vectors(id) WHERE embedding IS NULL;
      CREATE TABLE IF NOT EXISTS chunks(file TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        page INTEGER NOT NULL,ordinal INTEGER NOT NULL,vector INTEGER NOT NULL REFERENCES vectors(id),
        PRIMARY KEY(file,page,ordinal));
      CREATE INDEX IF NOT EXISTS chunks_vector ON chunks(vector);`);
    if (this.statement("SELECT value FROM meta WHERE key='model'").get()?.value !== embedder.signature) {
      this.db.exec('BEGIN IMMEDIATE; DELETE FROM chunks; DELETE FROM files; DELETE FROM vectors; DELETE FROM meta;');
      this.statement('INSERT INTO meta VALUES(?,?)').run('model', embedder.signature);
      this.statement('INSERT INTO meta VALUES(?,?)').run('generation', '0');
      this.db.exec('COMMIT');
    }
    this.generation = Number(this.statement("SELECT value FROM meta WHERE key='generation'").get()?.value || 0);
    this.revisions = new Map(this.statement('SELECT id,revision FROM files').all().map(row => [row.id, row.revision]));
    this.index = this.createIndex();
    this.beginRestore();
  }
  createIndex() {
    return new Index({ dimensions: this.embedder.dimensions, metric: 'cos', quantization: 'f16',
      connectivity: 16, expansion_add: 128, expansion_search: 128 });
  }
  beginRestore() {
    this.restoring = this.restore().catch(error => { this.lastError = error.message; this.failedAt = Date.now(); });
  }
  statement(sql) {
    if (!this.statements.has(sql)) this.statements.set(sql, this.db.prepare(sql));
    return this.statements.get(sql);
  }
  changed() {
    this.generation++; this.scopeCache = null; this.coverageCache.clear();
    this.statement("INSERT OR REPLACE INTO meta VALUES('generation',?)").run(String(this.generation));
  }
  transaction(action) {
    this.db.exec('BEGIN IMMEDIATE');
    try { action(); this.db.exec('COMMIT'); }
    catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  async restore() {
    try {
      const saved = JSON.parse(readFileSync(`${this.path}.usearch.json`, 'utf8'));
      if (saved.model === this.embedder.signature && saved.generation === this.generation &&
        saved.bytes === statSync(`${this.path}.usearch`).size && saved.sha256 === fileDigest(`${this.path}.usearch`)) {
        this.index.load(`${this.path}.usearch`); this.savedGeneration = this.generation;
        this.indexReady = true; return;
      }
    } catch {}
    // A damaged snapshot can leave a partially loaded graph. SQLite is the
    // authoritative copy, so rebuild into a fresh graph before serving queries.
    this.index = this.createIndex();
    let after = 0;
    while (!this.closed) {
      const rows = this.statement('SELECT id,embedding FROM vectors WHERE id>? AND embedding IS NOT NULL ORDER BY id LIMIT 256').all(after);
      if (!rows.length) break;
      for (const row of rows) this.index.add(BigInt(row.id), vectorFromBlob(row.embedding));
      after = rows.at(-1).id;
      await yieldTurn();
    }
    this.indexReady = !this.closed;
  }
  saveSnapshot() {
    if (!this.indexReady || this.closed || this.savedGeneration === this.generation) return;
    const snapshot = `${this.path}.usearch`;
    this.index.save(`${snapshot}.tmp`); chmodSync(`${snapshot}.tmp`, 0o600);
    renameSync(`${snapshot}.tmp`, snapshot);
    writeFileSync(`${snapshot}.json.tmp`, JSON.stringify({ model: this.embedder.signature,
      generation: this.generation, bytes: statSync(snapshot).size, sha256: fileDigest(snapshot) }), { mode: 0o600 });
    renameSync(`${snapshot}.json.tmp`, `${snapshot}.json`);
    this.savedGeneration = this.generation;
  }
  reconcile(files, courseID, checkCancelled) {
    const active = new Set(files.map(file => file.id));
    for (const id of this.files.keys()) if (!active.has(id)) this.files.delete(id);
    const removed = [...this.revisions.keys()].filter(id => !active.has(id));
    const changes = [];
    for (const entry of files) {
      checkCancelled?.();
      const { indexPath } = entry;
      // Swift/JSON encoders may emit keys in a different order on each request.
      // Canonicalize the schema before comparing revisions, not the wire order.
      const file = { id: entry.id, courseID: entry.courseID, courseName: entry.courseName,
        documentID: entry.documentID, materialID: entry.materialID, title: entry.title,
        fileName: entry.fileName || '', kind: entry.kind };
      this.files.set(file.id, entry);
      if (courseID && file.courseID !== courseID) continue;
      let stamp = 'missing';
      if (indexPath) {
        try { const s = statSync(indexPath); stamp = `${s.mtimeMs}:${s.ctimeMs}:${s.size}:${s.ino}`; } catch {}
      }
      const revision = JSON.stringify([file, indexPath, stamp]);
      if (this.revisions.get(file.id) !== revision) changes.push({ file, revision });
    }
    if (removed.length || changes.length) this.transaction(() => {
      for (const id of removed) {
        this.statement('DELETE FROM files WHERE id=?').run(id);
        this.revisions.delete(id); this.files.delete(id);
      }
      for (const { file, revision } of changes) {
        this.statement('DELETE FROM files WHERE id=?').run(file.id);
        this.statement('INSERT INTO files VALUES(?,?,?,?,?)').run(file.id, file.courseID, JSON.stringify(file), revision, 'pending');
        this.revisions.set(file.id, revision);
      }
      this.changed();
    });
    return changes.length;
  }
  wanted(file) { return this.scopes.has('') || this.scopes.has(file.courseID); }
  async prepareFile(file) {
    const revision = this.revisions.get(file.id);
    let pages = [], status = file.indexPath ? 'unavailable' : 'remote';
    if (file.indexPath && file.kind !== 'preview') {
      try { pages = JSON.parse(readFileSync(file.indexPath, 'utf8')).pages || []; } catch {}
    }
    const records = [];
    const names = `${file.title}\n${file.fileName || ''}\n${file.courseName || ''}`;
    const add = (text, page) => this.embedder.chunks(text).forEach((chunk, ordinal) => {
      records.push({ text: chunk, hash: digest(chunk), page, ordinal });
    });
    add(names, 0);
    for (let index = 0; index < pages.length; index++) {
      const page = pages[index];
      if (page.text?.trim() && Number.isSafeInteger(page.number) && page.number > 0) {
        add(page.text, page.number); status = 'ready';
      }
      if (index % 8 === 0) await yieldTurn();
      if (this.closed || revision !== this.revisions.get(file.id)) return;
    }
    if (this.closed || revision !== this.revisions.get(file.id)) return;
    this.transaction(() => {
      for (const row of records) {
        this.statement('INSERT OR IGNORE INTO vectors(hash,text) VALUES(?,?)').run(row.hash, row.text);
        const vector = this.statement('SELECT id FROM vectors WHERE hash=?').get(row.hash).id;
        this.statement('INSERT INTO chunks VALUES(?,?,?,?)').run(file.id, row.page, row.ordinal, vector);
      }
      this.statement('UPDATE files SET status=? WHERE id=?').run(status, file.id);
      this.changed();
    });
  }
  startIndexing() {
    if (this.indexing || this.closed || this.lastError) return;
    if (this.completedScopes.get(this.priorityScope || '') === this.generation) return;
    this.indexing = (async () => {
      await this.restoring;
      if (!this.indexReady || this.closed) return;
      await this.embedder.ready();
      let prepared = 0;
      while (!this.closed) {
        const pending = this.statement("SELECT id FROM files WHERE status='pending'").all()
          .map(row => this.files.get(row.id)).find(file => file && this.wanted(file));
        if (pending && prepared < 2) {
          await this.prepareFile(pending); prepared++; await yieldTurn(); continue;
        }
        const rows = this.statement(`SELECT DISTINCT v.id,v.text FROM vectors v JOIN chunks c ON c.vector=v.id
          JOIN files f ON f.id=c.file WHERE v.embedding IS NULL AND (?='' OR f.course=?) LIMIT 4`)
          .all(this.priorityScope || '', this.priorityScope || '');
        // A scoped request must not start indexing unrelated workspaces.
        const wantedRows = this.scopes.has('') ? rows : rows.filter(row =>
          this.statement('SELECT DISTINCT f.course FROM files f JOIN chunks c ON c.file=f.id WHERE c.vector=?').all(row.id)
            .some(file => this.scopes.has(file.course)));
        if (!wantedRows.length) {
          if (pending) { prepared = 0; continue; }
          break;
        }
        const vectors = await this.embedder.embed(wantedRows.map(row => row.text));
        if (this.closed) break;
        this.transaction(() => {
          wantedRows.forEach((row, index) => {
            const vector = vectors[index];
            if (vector.length !== this.embedder.dimensions || !vector.every(Number.isFinite)) throw new Error('Invalid semantic embedding.');
            this.statement('UPDATE vectors SET embedding=? WHERE id=?').run(vectorBlob(vector), row.id);
            if (!this.index.contains(BigInt(row.id))) this.index.add(BigInt(row.id), vector);
          });
          this.changed();
        });
        prepared = 0;
        await yieldTurn();
      }
      if (!this.closed) {
        const orphans = this.statement('SELECT id FROM vectors WHERE NOT EXISTS(SELECT 1 FROM chunks WHERE vector=vectors.id)').all();
        if (orphans.length) this.transaction(() => {
          for (const { id } of orphans) {
            this.index.remove(BigInt(id)); this.statement('DELETE FROM vectors WHERE id=?').run(id);
          }
          this.changed();
        });
        this.saveSnapshot();
        this.completedScopes.set(this.priorityScope || '', this.generation);
      }
    })().catch(error => { this.lastError = error.message; this.failedAt = Date.now(); })
      .finally(() => { this.indexing = null; });
  }
  coverage(courseID) {
    if (this.coverageCache.has(courseID)) return this.coverageCache.get(courseID);
    const row = this.statement(`SELECT count(*) AS files,coalesce(sum(status='ready'),0) AS contentFiles,
      coalesce(sum(status='remote'),0) AS remoteFiles,coalesce(sum(status='unavailable'),0) AS unavailableFiles,
      coalesce(sum(status!='pending' AND NOT EXISTS(SELECT 1 FROM chunks c JOIN vectors v ON v.id=c.vector
        WHERE c.file=f.id AND v.embedding IS NULL)),0) AS indexedFiles
      FROM files f WHERE ?='' OR course=?`).get(courseID, courseID);
    const chunks = this.statement(`SELECT count(*) AS chunks,coalesce(sum(v.embedding IS NOT NULL),0) AS indexedChunks
      FROM chunks c JOIN files f ON f.id=c.file JOIN vectors v ON v.id=c.vector WHERE ?='' OR f.course=?`).get(courseID, courseID);
    const result = { ...row, ...chunks }; this.coverageCache.set(courseID, result); return result;
  }
  scopedCandidates(query, courseID, count) {
    if (this.scopeCache?.courseID !== courseID) {
      const size = this.statement(`SELECT count(DISTINCT v.id) AS n FROM vectors v JOIN chunks c ON c.vector=v.id
        JOIN files f ON f.id=c.file WHERE f.course=? AND v.embedding IS NOT NULL`).get(courseID).n;
      if (size * this.embedder.dimensions * 4 > this.scopeCacheBytes) {
        // Large scopes use bounded exact batches, retaining the best candidates
        // across every batch instead of filtering a global ANN result afterward.
        const selected = [];
        let batch = [], after = 0;
        do {
          batch = this.statement(`SELECT DISTINCT v.id,v.embedding FROM vectors v JOIN chunks c ON c.vector=v.id
            JOIN files f ON f.id=c.file WHERE f.course=? AND v.embedding IS NOT NULL AND v.id>?
            ORDER BY v.id LIMIT 2048`).all(courseID, after);
          if (!batch.length) break;
          const matrix = new Float32Array(batch.length * this.embedder.dimensions);
          batch.forEach((row, i) => matrix.set(vectorFromBlob(row.embedding), i * this.embedder.dimensions));
          selected.push(...this.exactCandidates(query, { matrix, ids: batch.map(row => row.id) }, count));
          selected.sort((a, b) => b.score - a.score || a.id - b.id); selected.length = Math.min(count, selected.length);
          after = batch.at(-1).id;
        } while (batch.length === 2048);
        return selected;
      }
      const rows = this.statement(`SELECT DISTINCT v.id,v.embedding FROM vectors v JOIN chunks c ON c.vector=v.id
        JOIN files f ON f.id=c.file WHERE f.course=? AND v.embedding IS NOT NULL ORDER BY v.id`).all(courseID);
      const matrix = new Float32Array(rows.length * this.embedder.dimensions);
      rows.forEach((row, i) => matrix.set(vectorFromBlob(row.embedding), i * this.embedder.dimensions));
      const scope = { courseID, matrix, ids: rows.map(row => row.id) };
      if (matrix.byteLength <= this.scopeCacheBytes) this.scopeCache = scope;
      return this.exactCandidates(query, scope, count);
    }
    return this.exactCandidates(query, this.scopeCache, count);
  }
  exactCandidates(query, scope, count) {
    if (!scope.ids.length) return [];
    const matches = exactSearch(scope.matrix, query, this.embedder.dimensions, Math.min(count, scope.ids.length), 'cos', 1);
    return Array.from(matches.keys, (key, i) => ({ id: scope.ids[Number(key)], score: 1 - matches.distances[i] }));
  }
  async search(files, query, { courseID = '', checkCancelled } = {}) {
    const start = performance.now();
    checkCancelled?.();
    if (this.closed) throw new Error('Semantic search stopped.');
    if (this.lastError && Date.now() - (this.failedAt || 0) > 5000) {
      this.lastError = null;
      if (!this.indexReady) this.beginRestore();
    }
    this.scopes.add(courseID); this.priorityScope = courseID;
    const updatedFiles = this.reconcile(files, courseID, checkCancelled);
    this.startIndexing();
    const coverage = this.coverage(courseID);
    const semantic = { state: this.lastError ? 'error' : !this.indexReady ? 'loading_index' :
      this.embedder.status !== 'ready' ? 'loading_model' : coverage.indexedFiles < coverage.files ? 'indexing' : 'ready',
      indexedFiles: coverage.indexedFiles, totalFiles: coverage.files, indexedChunks: coverage.indexedChunks,
      totalChunks: coverage.chunks, model: 'Multilingual E5 small', progress: this.embedder.progress || 0,
      ...(this.lastError ? { message: this.lastError } : {}) };
    const base = { results: [], total: 0, terms: [], coverage, strategy: 'semantic',
      queryMs: 0, totalMs: performance.now() - start, updatedFiles, candidateUpperBound: 0, semantic };
    if (!query.trim() || !this.indexReady || this.embedder.status !== 'ready' || this.lastError) return base;
    const queryStart = performance.now();
    const key = query.trim();
    if (!this.queryCache.has(key)) {
      const [vector] = await this.embedder.embed([key], 'query');
      if (this.queryCache.size >= 64) this.queryCache.delete(this.queryCache.keys().next().value);
      this.queryCache.set(key, vector);
    }
    checkCancelled?.();
    if (this.closed) throw new Error('Semantic search stopped.');
    const vector = this.queryCache.get(key);
    const hits = new Map();
    let candidates = [];
    for (const count of [256, 1024, 4096]) {
      if (courseID) candidates = this.scopedCandidates(vector, courseID, count);
      else if (this.index.size()) {
        const matches = this.index.search(vector, Math.min(count, this.index.size()), 1);
        candidates = Array.from(matches.keys, (id, i) => ({ id: Number(id), score: 1 - matches.distances[i] }));
      }
      for (const candidate of candidates) {
        const sources = this.statement(`SELECT f.data,min(c.page) AS page,v.text FROM chunks c JOIN files f ON f.id=c.file
          JOIN vectors v ON v.id=c.vector WHERE c.vector=? AND (?='' OR f.course=?) GROUP BY f.id ORDER BY f.id LIMIT 60`)
          .all(candidate.id, courseID, courseID);
        for (const source of sources) {
          const file = JSON.parse(source.data);
          if (hits.has(file.id) && hits.get(file.id).score >= candidate.score) continue;
          hits.set(file.id, { ...file, page: source.page, passages: 1, semantic: true,
            score: candidate.score, snippet: source.text.slice(0, 320) + (source.text.length > 320 ? '…' : '') });
        }
      }
      if (hits.size >= 60 || candidates.length < count) break;
    }
    const results = [...hits.values()].sort((a, b) => b.score - a.score || a.id.localeCompare(b.id)).slice(0, 60);
    return { ...base, results, total: results.length, candidateUpperBound: candidates.length,
      queryMs: performance.now() - queryStart, totalMs: performance.now() - start };
  }
  async close() {
    this.closed = true;
    await this.restoring;
    // In-flight inference checks closed before touching the database. Do not
    // make an account switch wait for a model download or a background batch.
    this.db.close(); this.statements.clear(); this.scopeCache = null; this.queryCache.clear();
    this.files.clear(); this.revisions.clear(); this.index = null;
  }
}
