import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { NeedleIndex, normalizeSearch, searchTerms } from '../apps/server/needle.js';
import { Documents } from '../apps/server/documents.js';
import { WorkspaceSearch } from '../apps/server/workspace-search.js';

const signature = (result) =>
  result.results.map(({ id, page, passages }) => ({ id, page, passages }));

test('Needle verifies literal terms, phrases, Unicode, scopes and file/content modes against a scan oracle', () => {
  const index = new NeedleIndex(),
    records = [];
  const texts = [
    'Eigenvectors and a change\nof basis.',
    'C++ x.y [a-z] 100% _id',
    'CAFÉ cafe\u0301 ＡＢＣ naïve',
    '日本語の資料 😀🐈🐕 Ångström İSTANBUL',
    'repeat repeat common ordinary',
    'a ab xy',
    'needle unrelated haystack',
    'Invalid UTF-16 becomes \uD800 a replacement character',
  ];
  for (let i = 0; i < 84; i++) {
    const file = {
      id: `doc${String(i).padStart(3, '0')}`,
      courseID: `course${i % 3}`,
      title: `Lecture ${i}.pdf`,
    };
    const pages = Array.from({ length: 4 }, (_, j) => ({
      number: j + 1,
      text: texts[(i + j) % texts.length],
    }));
    index.put(file, pages, 'v1');
    records.push({
      file,
      rows: [
        { number: 0, text: normalizeSearch(`${file.title}\n`) },
        ...pages.map((page) => ({ ...page, text: normalizeSearch(page.text) })),
      ],
    });
  }
  const queries = [
    'basis',
    'Eigenvectors basis',
    '"change of basis"',
    '"change of basis',
    'a',
    'xy',
    'common',
    'absent',
    'C++',
    'x.y',
    '[a-z]',
    '100%',
    '_id',
    'CAFE\u0301',
    'ＡＢＣ',
    '日本語',
    '😀🐈🐕',
    'ångström',
    'İSTANBUL',
    'needle haystack',
    '"repeat repeat"',
    'lect',
    'Lecture 31',
    'OR',
    '""',
    '',
    "x'); DROP TABLE files; --",
    'a needle',
    '\uD800',
  ];
  // Every substring of a multilingual passage also exercises the candidate recall guarantee.
  const chars = [...normalizeSearch(texts.join(' '))];
  for (let i = 0; i < chars.length - 5; i += 3) queries.push(`"${chars.slice(i, i + 5).join('')}"`);
  for (const query of queries)
    for (const courseID of ['', 'course1'])
      for (const mode of ['all', 'files', 'content']) {
        const terms = searchTerms(query);
        const expected = terms.length
          ? records
              .filter(({ file }) => !courseID || file.courseID === courseID)
              .flatMap(({ file, rows }) => {
                const matches = rows.filter(
                  (row) =>
                    (mode !== 'files' || row.number === 0) &&
                    (mode !== 'content' || row.number > 0) &&
                    terms.every((term) => row.text.includes(term))
                );
                return matches.length
                  ? [{ id: file.id, page: matches[0].number, passages: matches.length }]
                  : [];
              })
              .sort(
                (a, b) => Number(b.page === 0) - Number(a.page === 0) || a.id.localeCompare(b.id)
              )
          : [];
        const actual = index.search(query, { courseID, mode, limit: 200 });
        assert.deepEqual(signature(actual), expected, JSON.stringify({ query, courseID, mode }));
        assert.equal(actual.total, expected.length);
      }
  assert.equal(index.search('ab').strategy, 'memory-scan');
  assert.equal(index.search('basis').strategy, 'trigram');
  assert.throws(() => index.search('x'.repeat(513)), /512/);
  assert.throws(() => index.search('a\0b'), /512/);
  assert.throws(() => index.search('x', { mode: 'sql' }), /mode/);
  index.close();
});

test('persistent index replaces edits, removes postings, preserves page evidence and survives reopening', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'needle-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const path = join(root, 'index.sqlite'),
    file = { id: 'a', courseID: 'a', title: 'name.txt' };
  let index = new NeedleIndex(path);
  index.put(file, [{ number: 7, text: 'old evidence' }], 'old');
  index.close();
  index = new NeedleIndex(path);
  assert.equal(index.search('evidence').results[0].page, 7);
  index.put({ ...file, title: 'new.txt' }, [{ number: 3, text: 'new contents' }], 'new');
  assert.equal(index.search('old').total, 0);
  assert.equal(index.search('name.txt').total, 0);
  assert.equal(index.search('contents').results[0].page, 3);
  index.remove(file.id);
  assert.equal(index.search('contents').total, 0);
  assert.equal(index.search('new.txt').total, 0);
  index.close();
});

test('bounded scan caches invalidate on external commits and rolled-back batches preserve the old snapshot', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'needle-cache-'));
  const path = join(root, 'index.sqlite');
  const index = new NeedleIndex(path),
    writer = new NeedleIndex(path);
  t.after(async () => {
    writer.close();
    index.close();
    await rm(root, { recursive: true, force: true });
  });
  const file = { id: 'a', courseID: 'a', title: 'Original' };
  writer.put(file, [{ number: 1, text: 'ab old evidence' }], 'old');
  const cached = index.search('ab');
  assert.equal(cached.strategy, 'memory-scan');
  assert.ok(cached.textCacheBytes > 0);
  assert.equal(index.search('replacement').total, 0); // Cache an absent gram too.
  assert.equal(index.revisions().get('a'), 'old');
  writer.put({ ...file, title: 'Renamed' }, [{ number: 7, text: 'ab replacement' }], 'new');
  const fresh = index.search('ab');
  assert.equal(fresh.results[0].page, 7);
  assert.equal(fresh.results[0].title, 'Renamed');
  assert.equal(index.search('replacement').total, 1);
  assert.equal(index.search('original').total, 0);
  assert.equal(index.revisions().get('a'), 'new');
  assert.throws(
    () =>
      index.batch(() => {
        index.put(file, [{ number: 9, text: 'ab cancelled text' }], 'cancelled');
        throw new Error('cancel');
      }),
    /cancel/
  );
  assert.equal(index.search('cancelled').total, 0);
  assert.equal(index.search('replacement').results[0].page, 7);
  let pagesChecked = 0;
  assert.throws(
    () =>
      index.put(
        file,
        [
          { number: 1, text: 'first' },
          { number: 2, text: 'second' },
        ],
        'cancelled',
        'ready',
        () => {
          if (++pagesChecked === 2) throw new Error('cancel');
        }
      ),
    /cancel/
  );
  assert.equal(index.search('replacement').results[0].page, 7);
  const bounded = new NeedleIndex(path, { maxTextBytes: 1 });
  try {
    const fallback = bounded.search('ab');
    assert.equal(fallback.strategy, 'scan');
    assert.equal(fallback.textCacheBytes, 0);
    assert.deepEqual(signature(fallback), signature(fresh));
  } finally {
    bounded.close();
  }
  writer.remove(file.id);
  assert.equal(index.search('ab').total, 0);
  assert.equal(index.search('replacement').coverage.files, 0);
});

test('aborted active and queued searches reject promptly and the worker remains usable', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'needle-cancel-'));
  const service = new WorkspaceSearch(new Documents(root), { workerCount: 1 });
  t.after(async () => {
    await service.close();
    await rm(root, { recursive: true, force: true });
  });
  const account = {
    id: randomUUID(),
    library: {
      courses: [
        {
          id: 'a',
          name: 'A',
          documents: [],
          canvasMaterials: [{ id: 'files:1', title: 'Visible after cancellation', kind: 'files' }],
        },
      ],
    },
  };
  const active = new AbortController(),
    queued = new AbortController();
  const first = service.search(account, 'visible', { signal: active.signal });
  const second = service.search(account, 'visible', { signal: queued.signal });
  const rejected = Promise.all([
    assert.rejects(first, { name: 'AbortError' }),
    assert.rejects(second, { name: 'AbortError' }),
  ]);
  active.abort();
  queued.abort();
  await rejected;
  assert.throws(() => service.search(account, 'visible', { signal: active.signal }), {
    name: 'AbortError',
  });
  const result = await service.search(account, 'visible');
  assert.equal(result.total, 1);
  assert.equal(result.results[0].materialID, 'files:1');
  // Evict the hot account, then reopen its index without leaking either cache.
  const other = {
    id: randomUUID(),
    library: { courses: [{ id: 'b', name: 'B', documents: [], canvasMaterials: [] }] },
  };
  assert.equal((await service.search(other, 'visible')).total, 0);
  assert.equal((await service.search(account, 'visible')).updatedFiles, 0);
  assert.equal(service.pending.size, 0);
});

test('idle workers release their isolate, reopen persisted indexes, and never retire in-flight requests', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'needle-idle-'));
  const service = new WorkspaceSearch(new Documents(root), { workerCount: 1, idleTimeoutMs: 30 });
  t.after(async () => {
    await service.close();
    await rm(root, { recursive: true, force: true });
  });
  const account = {
    id: randomUUID(),
    library: { courses: [{ id: 'a', name: 'A', documents: [],
      canvasMaterials: [{ id: 'files:1', title: 'Persistent evidence', kind: 'files' }] }] },
  };
  assert.equal((await service.search(account, 'evidence')).total, 1);
  const slot = service.slots[0], firstWorker = slot.worker;
  const exited = once(firstWorker, 'exit');
  firstWorker.ref(); // Keep the test alive while the service deliberately unrefs idle workers.
  await exited;
  assert.equal(slot.worker, null, 'Retire the V8 isolate, not just its SQLite connection');

  const next = service.search(account, 'evidence');
  const secondWorker = slot.worker;
  assert.notEqual(secondWorker, firstWorker);
  // Reproduce an idle notification already in transit when a new job is posted.
  secondWorker.emit('message', { type: 'idle' });
  assert.equal(slot.worker, secondWorker, 'An active request owns this worker');
  const result = await next;
  assert.equal(result.total, 1);
  assert.equal(result.updatedFiles, 0, 'Reopening reuses the persisted index');
  assert.equal(service.pending.size, 0);
});

test('worker refreshes only changed files and isolates accounts, cloud names and missing indexes', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'needle-worker-'));
  const documents = new Documents(root),
    search = new WorkspaceSearch(documents);
  t.after(async () => {
    await search.close();
    await rm(root, { recursive: true, force: true });
  });
  const doc = { id: randomUUID(), title: 'Notes', fileName: 'notes.txt', kind: 'text' };
  const a = {
    id: randomUUID(),
    library: {
      courses: [
        {
          id: 'a',
          name: 'A',
          documents: [doc],
          canvasMaterials: [
            { id: 'files:1', title: 'Cloud lecture', fileName: 'lecture.pdf', kind: 'files' },
          ],
        },
      ],
    },
  };
  const b = {
    id: randomUUID(),
    library: { courses: [{ id: 'b', name: 'B', documents: [{ ...doc }], canvasMaterials: [] }] },
  };
  const path = documents.directory(a.id, doc.id);
  await mkdir(path, { recursive: true });
  const write = (text) =>
    writeFile(join(path, 'index.json'), JSON.stringify({ pages: [{ number: 4, text }] }));
  await write('private alice text');
  const first = await search.search(a, 'private');
  assert.equal(first.results[0].page, 4);
  assert.equal(first.updatedFiles, 2);
  assert.equal((await search.search(a, 'alice')).updatedFiles, 0);
  assert.equal((await search.search(b, 'alice')).total, 0);
  assert.equal((await search.search(b, 'notes')).coverage.unavailableFiles, 1);
  assert.equal((await search.search(a, 'cloud')).results[0].materialID, 'files:1');
  assert.equal((await search.search(a, 'cloud', { mode: 'content' })).total, 0);
  assert.throws(() => search.search(a, 'text', { courseID: 'b' }), /not found/);
  await write('replacement evidence');
  assert.equal((await search.search(a, 'private')).total, 0);
  assert.equal((await search.search(a, 'replacement')).results[0].page, 4);
  doc.title = 'Renamed';
  assert.equal((await search.search(a, 'renamed')).updatedFiles, 1);
  await rm(join(path, 'index.json'));
  assert.equal((await search.search(a, 'replacement')).total, 0);
  assert.equal((await search.search(a, 'renamed')).coverage.unavailableFiles, 1);
  a.library.courses[0].documents = [];
  assert.equal((await search.search(a, 'renamed')).total, 0);
});

test('a scoped search prepares only that workspace and preview placeholders never become evidence', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'needle-scope-'));
  const documents = new Documents(root),
    search = new WorkspaceSearch(documents);
  t.after(async () => {
    await search.close();
    await rm(root, { recursive: true, force: true });
  });
  const account = {
    id: randomUUID(),
    library: {
      courses: ['a', 'b'].map((id) => ({
        id,
        name: id,
        documents: [
          {
            id: randomUUID(),
            title: `Notes ${id}`,
            fileName: 'notes.txt',
            kind: id === 'a' ? 'text' : 'preview',
          },
        ],
      })),
    },
  };
  for (const course of account.library.courses) {
    const path = documents.directory(account.id, course.documents[0].id);
    await mkdir(path, { recursive: true });
    await writeFile(
      join(path, 'index.json'),
      JSON.stringify({ pages: [{ number: 1, text: 'needle evidence' }] })
    );
  }
  const first = await search.search(account, 'needle', { courseID: 'a' });
  assert.equal(first.updatedFiles, 1);
  assert.equal(first.coverage.files, 1);
  const other = await search.search(account, 'needle', { courseID: 'b' });
  assert.equal(other.updatedFiles, 1);
  assert.equal(other.total, 0);
  assert.equal(other.coverage.unavailableFiles, 1);
  assert.equal((await search.search(account, 'needle')).updatedFiles, 0);
  assert.equal((await search.search(account, 'notes')).total, 2);
  account.library.courses.pop();
  await search.search(account, 'needle', { courseID: 'a' });
  assert.equal((await search.search(account, 'notes')).total, 1);
});
