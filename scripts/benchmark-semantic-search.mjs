import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm, stat, mkdir } from 'node:fs/promises';
import { tmpdir, cpus } from 'node:os';
import { join, dirname } from 'node:path';
import { setTimeout as wait } from 'node:timers/promises';
import { SemanticIndex } from '../packages/search/semantic-index.js';
import { LocalSemanticEmbedder } from '../packages/search/semantic-embedding.js';

// Real local embeddings, deterministic disposable documents. Service timings
// include file stamps, embedding, ranking and evidence, excluding HTTP and UI.
const count = Math.max(12, Number(process.env.SEMANTIC_BENCH_FILES) || 600);
const rounds = Math.max(3, Number(process.env.SEMANTIC_BENCH_ROUNDS) || 21);
const root = await mkdtemp(join(tmpdir(), 'scholia-semantic-bench-'));
const topics = [
  ['Control systems', 'Negative feedback compares measurements with a reference. A PID regulator corrects error and stabilizes a closed loop.', 'How can I keep a motor stable?'],
  ['Genetic ethics', 'Editing the DNA of embryos raises ethical concerns about consent, inherited disorders, unequal access, and future generations.', 'Is it right to change a baby’s genes?'],
  ['Baking', 'Bread is made using flour, yeast and water. Fermentation releases gas and helps dough rise before baking.', 'Why does dough expand before going into the oven?'],
  ['Linear algebra', 'Eigenvectors preserve their direction under a linear transformation. Eigenvalues describe the factor by which these vectors scale.', 'Which vectors keep pointing the same way after a transformation?'],
  ['Networking', 'TCP reliably delivers packets between computers. Acknowledgments and retransmission recover lost data on unreliable network connections.', 'How does a computer recover information that never arrived?'],
  ['Ecology', 'Pollinating insects transfer pollen between flowering plants. Diverse habitats support bees and help agricultural crops reproduce.', 'Why do farms need bees?'],
];
const embedder = new LocalSemanticEmbedder();
let index;
const summarize = values => {
  values.sort((a, b) => a - b);
  return { medianMs: values[Math.floor(values.length / 2)], p95Ms: values[Math.ceil(values.length * 0.95) - 1] };
};
try {
  const files = [];
  for (let i = 0; i < count; i++) {
    const topic = topics[i % topics.length];
    const indexPath = join(root, `${i}.json`);
    await writeFile(indexPath, JSON.stringify({ pages: [1, 2].map(number => ({ number,
      text: `${topic[1]} Tutorial ${i}, section ${number}. ${number === 1 ? 'Discuss the mechanism and illustrate it with an example.' : 'Explain the assumptions and limitations of this approach.'}` })) }));
    files.push({ id: `doc${i}`, documentID: `doc${i}`, courseID: `course${i % topics.length}`,
      courseName: topic[0], title: `Lecture ${i}`, fileName: `${i}.txt`, kind: 'text', indexPath });
  }
  const modelStart = performance.now();
  await embedder.ready();
  const modelMs = performance.now() - modelStart;
  const indexingStart = performance.now();
  index = new SemanticIndex(join(root, 'semantic.sqlite'), { embedder });
  while (true) {
    const response = await index.search(files, '');
    assert.notEqual(response.semantic.state, 'error', response.semantic.message);
    if (response.semantic.state === 'ready') break;
    assert.ok(performance.now() - indexingStart < 600_000, 'Indexing deadline');
    await wait(50);
  }
  await index.indexing;
  const indexingMs = performance.now() - indexingStart;
  const timings = {};
  for (const [name, courseID, cached] of [['newQuery', '', false], ['cachedQuery', '', true], ['workspace', 'course0', true]]) {
    const values = [];
    for (let i = 0; i <= rounds; i++) {
      const topic = courseID ? 0 : i % topics.length;
      const query = topics[topic][2];
      // Evict only the query vector to time inference without adding artificial
      // document numbers or other extra search intent to the question.
      if (!cached) index.queryCache.clear();
      const result = await index.search(files, query, { courseID });
      assert.equal(result.results[0].courseID, `course${topic}`, `Relevance in ${name}: ${JSON.stringify({ query, hits: result.results.slice(0, 3) })}`);
      if (courseID) assert.ok(result.results.every(hit => hit.courseID === courseID));
      if (i) values.push(result.totalMs);
    }
    timings[name] = summarize(values);
  }
  index.db.exec('PRAGMA wal_checkpoint(TRUNCATE)');
  const report = { machine: cpus()[0].model, files: count, pages: count * 2, dimensions: embedder.dimensions,
    uniqueVectors: index.index.size(), modelMs, indexingMs,
    sqliteBytes: (await stat(index.path)).size, graphBytes: (await stat(`${index.path}.usearch`)).size,
    rounds, timings, peakRSSMiB: process.resourceUsage().maxRSS / 1024,
    limits: 'Synthetic library; model assets already cached; service time excludes worker IPC, HTTP, debounce and rendering. Relevance assertions cover six topics; this is not a broad relevance evaluation or provider comparison.' };
  if (process.env.SEMANTIC_BENCH_OUTPUT) {
    await mkdir(dirname(process.env.SEMANTIC_BENCH_OUTPUT), { recursive: true });
    await writeFile(process.env.SEMANTIC_BENCH_OUTPUT, `${JSON.stringify(report, null, 2)}\n`);
  }
  console.log(JSON.stringify(report, null, 2));
} finally {
  await index?.close();
  await rm(root, { recursive: true, force: true });
}
