import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm, stat } from 'node:fs/promises';
import { tmpdir, platform, arch, cpus } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { NeedleIndex, normalizeSearch, searchTerms } from '../../apps/server/search/needle.js';
import { Documents } from '../../apps/server/documents/documents.js';
import { WorkspaceSearch } from '../../apps/server/search/workspace-search.js';

// Deterministic synthetic corpus, no provider credentials or personal library.
// All paths return one hit per file with the first matching page; warm timings
// exclude setup. rg includes process startup; the in-memory oracle does not.
const root = await mkdtemp(join(tmpdir(), 'scholia-search-bench-'));
const count = Math.max(100, Number(process.env.SEARCH_BENCH_FILES) || 1200);
const rounds = Math.max(3, Number(process.env.SEARCH_BENCH_ROUNDS) || 31);
const corpus = [],
  disk = join(root, 'corpus');
const documents = new Documents(root),
  service = new WorkspaceSearch(documents);
const account = {
  id: '11111111-1111-4111-8111-111111111111',
  library: {
    courses: Array.from({ length: 20 }, (_, i) => ({
      id: `course${i}`,
      name: `Workspace ${i}`,
      documents: [],
      canvasMaterials: [],
    })),
  },
};
let index;
const median = (values) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];
const percentile = (values, fraction) =>
  [...values].sort((a, b) => a - b)[Math.ceil(values.length * fraction) - 1];
const signature = (value) => value.results.map((hit) => `${hit.id}:${hit.page}:${hit.passages}`);
try {
  await mkdir(disk);
  let seed = 4729;
  const random = () => (seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0) / 4294967296;
  const words = Array.from({ length: 1500 }, () =>
    Array.from({ length: 8 }, () => String.fromCharCode(97 + Math.floor(random() * 26))).join('')
  );
  let bytes = 0;
  for (let i = 0; i < count; i++) {
    const file = {
      id: `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`,
      courseID: `course${i % 20}`,
      title: `Lecture ${i}.txt`,
    };
    const pages = Array.from({ length: 8 }, (_, p) => ({
      number: p + 1,
      text: `common introduction ${Array.from({ length: 260 }, () => words[Math.floor(random() * words.length)]).join(' ')}${i % 317 === 0 && p === 5 ? ' eigenvector needlemarker change of basis' : ''}${i % 71 === 0 && p === 2 ? ' diagonalization spectral theorem' : ''}`,
    }));
    bytes += pages.reduce((sum, page) => sum + Buffer.byteLength(page.text), 0);
    corpus.push({
      file,
      pages,
      rows: [{ number: 0, text: normalizeSearch(file.title) }, ...pages],
    });
    await writeFile(join(disk, `${file.id}.txt`), pages.map((p) => p.text).join('\n\n'));
    const path = documents.directory(account.id, file.id);
    await mkdir(path, { recursive: true });
    await writeFile(join(path, 'index.json'), JSON.stringify({ pages }));
    account.library.courses[i % 20].documents.push({
      id: file.id,
      title: file.title,
      fileName: file.title,
      kind: 'text',
    });
  }
  if (process.env.SEARCH_BENCH_CORPUS) {
    await writeFile(
      process.env.SEARCH_BENCH_CORPUS,
      JSON.stringify(corpus.map(({ file, rows }) => ({ file, rows })))
    );
  }
  const start = performance.now();
  await service.search(account, 'needlemarker');
  const buildMs = performance.now() - start;
  const indexPath = join(documents.directory(account.id, account.id), 'needle-v1.sqlite');
  index = new NeedleIndex(indexPath);
  // Include all committed index pages in disk size, even with hot connections.
  index.db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
  const indexBytes = (await stat(indexPath)).size;
  const scan = (query, courseID = '') => {
    const terms = searchTerms(query),
      results = [];
    for (const { file, rows } of corpus) {
      if (courseID && file.courseID !== courseID) continue;
      const hits = rows.filter((row) => terms.every((term) => row.text.includes(term)));
      if (hits.length) results.push({ id: file.id, page: hits[0].number, passages: hits.length });
    }
    results.sort((a, b) => Number(b.page === 0) - Number(a.page === 0) || a.id.localeCompare(b.id));
    return { total: results.length, results: results.slice(0, 200) };
  };
  const rgAvailable = spawnSync('rg', ['--version']).status === 0;
  const cases = [
    { name: 'rare literal', query: 'needlemarker', rg: 'needlemarker' },
    { name: 'absent literal', query: 'unfindablequartz', rg: 'unfindablequartz' },
    { name: 'phrase', query: '"change of basis"', rg: 'change of basis' },
    { name: 'multiple terms', query: 'spectral diagonalization' },
    { name: 'workspace scope', query: 'needlemarker', courseID: 'course0' },
    { name: 'common term', query: 'common', rg: 'common' },
    { name: 'short term', query: 'ab', rg: 'ab' },
  ];
  const results = [];
  for (const entry of cases) {
    const options = { courseID: entry.courseID, limit: 200 };
    const oracle = scan(entry.query, entry.courseID);
    const indexed = [],
      linear = [],
      sqliteScan = [],
      ripgrep = [],
      serviceTimes = [],
      refreshTimes = [];
    // Warm all methods before interleaved timed runs.
    const firstStart = performance.now();
    const firstService = await service.search(account, entry.query, options);
    const firstServiceMs = performance.now() - firstStart;
    assert.deepEqual(signature(firstService), signature(oracle));
    index.search(entry.query, options);
    scan(entry.query, entry.courseID);
    index.search(entry.query, { ...options, scan: true });
    for (let round = 0; round < rounds; round++) {
      let start = performance.now();
      const found = index.search(entry.query, options);
      indexed.push(performance.now() - start);
      assert.equal(found.total, oracle.total);
      assert.deepEqual(signature(found), signature(oracle));
      start = performance.now();
      const plain = scan(entry.query, entry.courseID);
      linear.push(performance.now() - start);
      assert.deepEqual(signature(plain), signature(oracle));
      start = performance.now();
      const sql = index.search(entry.query, { ...options, scan: true });
      sqliteScan.push(performance.now() - start);
      assert.equal(sql.total, oracle.total);
      assert.deepEqual(signature(sql), signature(oracle));
      start = performance.now();
      const complete = await service.search(account, entry.query, options);
      serviceTimes.push(performance.now() - start);
      refreshTimes.push(complete.refreshMs);
      assert.equal(complete.updatedFiles, 0);
      assert.equal(complete.total, oracle.total);
      assert.deepEqual(signature(complete), signature(oracle));
      if (rgAvailable && entry.rg) {
        start = performance.now();
        const run = spawnSync('rg', ['-F', '-l', '--', entry.rg, disk], { encoding: 'utf8' });
        ripgrep.push(performance.now() - start);
        assert.ok([0, 1].includes(run.status), run.stderr);
        const names = run.stdout
          .trim()
          .split('\n')
          .filter(Boolean)
          .map((p) =>
            p
              .split('/')
              .at(-1)
              .replace(/\.txt$/, '')
          )
          .sort();
        assert.equal(names.length, oracle.total);
        assert.deepEqual(
          names.slice(0, 200),
          oracle.results.map((hit) => hit.id)
        );
      }
    }
    const plan = index.search(entry.query, options);
    results.push({
      case: entry.name,
      matches: oracle.total,
      strategy: plan.strategy,
      candidateUpperBound: plan.candidateUpperBound,
      needleP50Ms: +median(indexed).toFixed(3),
      needleP95Ms: +percentile(indexed, 0.95).toFixed(3),
      memoryScanP50Ms: +median(linear).toFixed(3),
      sqliteScanP50Ms: +median(sqliteScan).toFixed(3),
      serviceP50Ms: +median(serviceTimes).toFixed(3),
      serviceP95Ms: +percentile(serviceTimes, 0.95).toFixed(3),
      firstServiceMs: +firstServiceMs.toFixed(3),
      refreshP50Ms: +median(refreshTimes).toFixed(3),
      textCacheBytes: plan.textCacheBytes,
      rgP50Ms: ripgrep.length ? +median(ripgrep).toFixed(3) : null,
      speedupVsMemoryScan: +(median(linear) / median(indexed)).toFixed(2),
    });
  }
  const reopenTimes = [];
  for (let attempt = 0; attempt < 5; attempt++) {
    const freshService = new WorkspaceSearch(documents);
    const start = performance.now();
    try {
      const found = await freshService.search(account, 'needlemarker', { limit: 200 });
      reopenTimes.push(performance.now() - start);
      assert.equal(found.updatedFiles, 0);
      assert.deepEqual(signature(found), signature(scan('needlemarker')));
    } finally {
      await freshService.close();
    }
  }
  const edited = account.library.courses[0].documents[0];
  const updateStart = performance.now();
  await writeFile(
    join(documents.directory(account.id, edited.id), 'index.json'),
    JSON.stringify({ pages: [{ number: 7, text: 'freshvisibilitytoken' }] })
  );
  const updated = await service.search(account, 'freshvisibilitytoken');
  const updateVisibilityMs = performance.now() - updateStart;
  assert.equal(updated.updatedFiles, 1);
  assert.equal(updated.total, 1);
  assert.equal(updated.results[0].page, 7);
  assert.equal(
    (await service.search(account, 'needlemarker')).total,
    scan('needlemarker').total - 1
  );
  const report = {
    environment: {
      node: process.version,
      platform: platform(),
      arch: arch(),
      cpu: cpus()[0]?.model,
    },
    files: count,
    pages: count * 8,
    workspaces: 20,
    corpusBytes: bytes,
    indexBytes,
    buildMs: +buildMs.toFixed(2),
    rounds,
    reopenService: {
      p50Ms: +median(reopenTimes).toFixed(3),
      p95Ms: +percentile(reopenTimes, 0.95).toFixed(3),
      condition: 'New worker and connection; OS filesystem cache remains warm; 5 runs.',
    },
    updateVisibilityMs: +updateVisibilityMs.toFixed(3),
    correctness:
      'All indexed results equal the independent literal scan oracle; rg file IDs also equal where comparable.',
    limits:
      'Synthetic corpus, warm queries. Service timings include worker messaging, file-stat refresh and result construction; reuse the connection; exclude HTTP, the 35 ms UI debounce and rendering. Engine timings exclude refresh. FirstServiceMs is the first service call for each case after initial preparation (and preceding cases); broad queries can pay a text-cache fill. Reopen starts fresh workers without dropping OS page caches. Update visibility includes writing one extracted-text JSON file and the next service search. Index bytes are checkpointed before the update. rg includes process startup and returns file names without page evidence. No RAG or turbopuffer comparison.',
    results,
  };
  console.log(JSON.stringify(report, null, 2));
  if (process.env.SEARCH_BENCH_OUTPUT)
    await writeFile(process.env.SEARCH_BENCH_OUTPUT, JSON.stringify(report, null, 2) + '\n');
} finally {
  index?.close();
  await service.close();
  await rm(root, { recursive: true, force: true });
}
