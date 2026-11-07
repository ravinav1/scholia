// Normalized SQLite library storage. Legacy users.library is retained as the migration backup.
// All write batches are transactional; row comparisons suppress unchanged SQL writes.
const parse = value => JSON.parse(value);
const encode = value => JSON.stringify(value);
const without = (value, keys) => Object.fromEntries(Object.entries(value).filter(([key]) => !keys.includes(key)));
const tables = {
  roots: 'library_roots', courses: 'library_courses', documents: 'library_documents',
  progress: 'reading_progress', threads: 'library_threads', drafts: 'composer_drafts', messages: 'conversation_messages',
};
const draftFields = ['draft', 'draftImage', 'draftFiles', 'entirePDF'];
export class LibraryPersistence {
  constructor(db) {
    this.db = db;
    this.statements = new Map();
    this.metrics = { writes: 0, serializedBytes: 0, rows: {} };
    const version = db.prepare('PRAGMA user_version').get().user_version;
    if (version > 2) throw new Error('This library uses a newer schema. Use a newer Scholia build.');
    db.exec(`BEGIN IMMEDIATE;
      CREATE TABLE IF NOT EXISTS library_roots(user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,data TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS library_courses(user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,id TEXT NOT NULL,position INTEGER NOT NULL,data TEXT NOT NULL,PRIMARY KEY(user_id,id));
      CREATE TABLE IF NOT EXISTS library_documents(user_id TEXT NOT NULL,course_id TEXT NOT NULL,id TEXT NOT NULL,position INTEGER NOT NULL,data TEXT NOT NULL,PRIMARY KEY(user_id,id),FOREIGN KEY(user_id,course_id) REFERENCES library_courses(user_id,id) ON DELETE CASCADE);
      CREATE TABLE IF NOT EXISTS reading_progress(user_id TEXT NOT NULL,id TEXT NOT NULL,data TEXT NOT NULL,PRIMARY KEY(user_id,id),FOREIGN KEY(user_id,id) REFERENCES library_documents(user_id,id) ON DELETE CASCADE);
      CREATE TABLE IF NOT EXISTS library_threads(user_id TEXT NOT NULL,course_id TEXT NOT NULL,id TEXT NOT NULL,position INTEGER NOT NULL,data TEXT NOT NULL,PRIMARY KEY(user_id,id),FOREIGN KEY(user_id,course_id) REFERENCES library_courses(user_id,id) ON DELETE CASCADE);
      CREATE TABLE IF NOT EXISTS composer_drafts(user_id TEXT NOT NULL,id TEXT NOT NULL,data TEXT NOT NULL,PRIMARY KEY(user_id,id),FOREIGN KEY(user_id,id) REFERENCES library_threads(user_id,id) ON DELETE CASCADE);
      CREATE TABLE IF NOT EXISTS conversation_messages(user_id TEXT NOT NULL,thread_id TEXT NOT NULL,id TEXT NOT NULL,position INTEGER NOT NULL,data TEXT NOT NULL,PRIMARY KEY(user_id,thread_id,id),FOREIGN KEY(user_id,thread_id) REFERENCES library_threads(user_id,id) ON DELETE CASCADE);`);
    try {
      // The presence of a root is the per-account completion marker; commit publishes it atomically.
      for (const row of db.prepare('SELECT id,library FROM users WHERE id NOT IN (SELECT user_id FROM library_roots)').all())
        this.writeLibrary(row.id, parse(row.library));
      db.exec('PRAGMA user_version=2; COMMIT;');
    } catch (error) { db.exec('ROLLBACK'); throw error; }
    this.resetMetrics();
  }
  statement(sql) {
    if (!this.statements.has(sql)) this.statements.set(sql, this.db.prepare(sql));
    return this.statements.get(sql);
  }
  resetMetrics() { this.metrics = { writes: 0, serializedBytes: 0, rows: {} }; }
  transaction(work) {
    if (this.inTransaction) return work();
    this.db.exec('BEGIN IMMEDIATE');
    this.inTransaction = true;
    try { const result = work(); this.db.exec('COMMIT'); return result; }
    catch (error) { this.db.exec('ROLLBACK'); throw error; }
    finally { this.inTransaction = false; }
  }
  write(kind, identity, data, columns = {}) {
    const table = tables[kind], value = encode(data);
    this.metrics.serializedBytes += Buffer.byteLength(value);
    const where = Object.keys(identity).map(key => `${key}=?`).join(' AND ');
    const current = this.statement(`SELECT * FROM ${table} WHERE ${where}`).get(...Object.values(identity));
    if (current?.data === value && Object.entries(columns).every(([key, item]) => current[key] === item)) return false;
    const row = { ...identity, ...columns, data: value }, keys = Object.keys(row);
    this.statement(`INSERT INTO ${table}(${keys.join(',')}) VALUES(${keys.map(() => '?').join(',')})
      ON CONFLICT(${Object.keys(identity).join(',')}) DO UPDATE SET ${Object.keys({ ...columns, data: value }).map(key => `${key}=excluded.${key}`).join(',')}`).run(...Object.values(row));
    this.metrics.writes++; this.metrics.rows[kind] = (this.metrics.rows[kind] || 0) + 1;
    return true;
  }
  prune(kind, user, ids, parent = {}) {
    const table = tables[kind], where = { user_id: user, ...parent };
    const clause = Object.keys(where).map(key => `${key}=?`).join(' AND ');
    for (const row of this.statement(`SELECT id FROM ${table} WHERE ${clause}`).all(...Object.values(where)))
      if (!ids.has(row.id)) {
        this.statement(`DELETE FROM ${table} WHERE ${clause} AND id=?`).run(...Object.values(where), row.id);
        this.metrics.writes++; this.metrics.rows[kind] = (this.metrics.rows[kind] || 0) + 1;
      }
  }
  writeProgress(user, document) {
    return this.write('progress', { user_id: user, id: document.id },
      Object.fromEntries(['lastPage','lastOpenedAt'].filter(key => key in document).map(key => [key, document[key]])));
  }
  writeDraft(user, thread) {
    return this.write('drafts', { user_id: user, id: thread.id },
      Object.fromEntries(draftFields.filter(key => key in thread).map(key => [key, thread[key]])));
  }
  writeThread(user, course, thread, position, { messages = true } = {}) {
    this.write('threads', { user_id: user, id: thread.id }, without(thread, ['messages', ...draftFields]), { course_id: course.id, position });
    this.writeDraft(user, thread);
    if (messages) {
      const ids = new Set();
      for (const [index, message] of (thread.messages || []).entries()) {
        const id = message.id || `legacy:${index}`; ids.add(id);
        this.write('messages', { user_id: user, thread_id: thread.id, id }, message, { position: index });
      }
      this.prune('messages', user, ids, { thread_id: thread.id });
    }
  }
  writeLibrary(user, library) {
    this.write('roots', { user_id: user }, without(library, ['courses']));
    const courses = library.courses || [];
    for (const [position, course] of courses.entries()) {
      this.write('courses', { user_id: user, id: course.id }, without(course, ['documents','threads']), { position });
      for (const [index, doc] of (course.documents || []).entries()) {
        this.write('documents', { user_id: user, id: doc.id }, without(doc, ['lastPage','lastOpenedAt']), { course_id: course.id, position: index });
        this.writeProgress(user, doc);
      }
      this.prune('documents', user, new Set((course.documents || []).map(d => d.id)), { course_id: course.id });
      for (const [index, thread] of (course.threads || []).entries()) this.writeThread(user, course, thread, index);
      this.prune('threads', user, new Set((course.threads || []).map(t => t.id)), { course_id: course.id });
    }
    this.prune('courses', user, new Set(courses.map(course => course.id)));
  }
  save(account, scope) {
    return this.transaction(() => {
      const course = scope?.courseID && account.library.courses.find(c => c.id === scope.courseID);
      if (course && !this.statement('SELECT 1 FROM library_courses WHERE user_id=? AND id=?').get(account.id, course.id)) {
        this.writeLibrary(account.id, account.library);
      }
      if (scope?.kind === 'progress' && course) {
        const document = course.documents.find(d => d.id === scope.documentID);
        if (!document) throw new Error('The reading was deleted before it could be saved.');
        if (!this.statement('SELECT 1 FROM library_documents WHERE user_id=? AND id=?').get(account.id, document.id))
          this.write('documents', {user_id:account.id,id:document.id}, without(document, ['lastPage','lastOpenedAt']), {course_id:course.id,position:course.documents.indexOf(document)});
        this.writeProgress(account.id, document);
      } else if (['draft','thread'].includes(scope?.kind) && course) {
        const thread = course.threads.find(t => t.id === scope.threadID);
        if (!thread) throw new Error('The conversation was deleted before it could be saved.');
        const stored = this.statement('SELECT data FROM library_threads WHERE user_id=? AND id=?').get(account.id, thread.id);
        if (scope.kind === 'draft' && stored) {
          this.writeDraft(account.id, thread);
          const metadata = parse(stored.data);
          if (metadata.mode !== thread.mode) this.write('threads', {user_id:account.id,id:thread.id},
            {...metadata, mode:thread.mode}, {course_id:course.id,position:course.threads.indexOf(thread)});
        } else this.writeThread(account.id, course, thread, course.threads.indexOf(thread), { messages: scope.kind === 'thread' });
      } else if (scope?.kind === 'course' && course) {
        this.write('courses', { user_id: account.id, id: course.id }, without(course, ['documents','threads']), { position: account.library.courses.indexOf(course) });
      } else if (scope?.kind !== 'settings') this.writeLibrary(account.id, account.library);
      const settings = encode(account.settings);
      this.metrics.serializedBytes += Buffer.byteLength(settings);
      const result = this.statement('UPDATE users SET settings=? WHERE id=? AND settings<>?').run(settings, account.id, settings);
      this.metrics.writes += Number(result.changes);
    });
  }
  read(user) {
    const root = this.statement('SELECT data FROM library_roots WHERE user_id=?').get(user);
    if (!root) return null;
    const courses = this.statement('SELECT * FROM library_courses WHERE user_id=? ORDER BY position').all(user);
    const documents = this.statement('SELECT d.*,p.data AS progress FROM library_documents d LEFT JOIN reading_progress p ON p.user_id=d.user_id AND p.id=d.id WHERE d.user_id=? ORDER BY d.position').all(user);
    const threads = this.statement('SELECT t.*,d.data AS draft FROM library_threads t LEFT JOIN composer_drafts d ON d.user_id=t.user_id AND d.id=t.id WHERE t.user_id=? ORDER BY t.position').all(user);
    const messages = this.statement('SELECT * FROM conversation_messages WHERE user_id=? ORDER BY position').all(user);
    const byCourse = new Map(courses.map(row => [row.id, { ...parse(row.data), documents: [], threads: [] }]));
    for (const row of documents) byCourse.get(row.course_id)?.documents.push({ ...parse(row.data), ...parse(row.progress || '{}') });
    const byThread = new Map();
    for (const row of threads) {
      const thread = { ...parse(row.data), ...parse(row.draft || '{}'), messages: [] };
      byThread.set(row.id, thread); byCourse.get(row.course_id)?.threads.push(thread);
    }
    for (const row of messages) byThread.get(row.thread_id)?.messages.push(parse(row.data));
    return { ...parse(root.data), courses: [...byCourse.values()] };
  }
}
