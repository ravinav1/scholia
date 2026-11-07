# Workspace search

Open **Search files** or press **⌘K** on Mac / **Ctrl+K** in the browser.
Search defaults to **File names** across **All workspaces**. It matches file titles,
names, course codes and course names directly from the catalog, without waiting
for text indexing. Switch to names and contents or contents only to look inside
documents, or restrict the search to the current workspace. Selecting a content result opens its
page, notebook cell, or document section. The Mac app, its loopback website,
and hosted accounts support the same search contract.

Choose **Semantic · by meaning** to describe an idea in your own words, including
English or Norwegian questions. This optional mode ranks related files and opens
their best passage. The existing filename and literal search paths remain separate.

- In File names mode, words are case-insensitive and combined with AND on each
  file's metadata. Exact matches rank first. Words of at least five letters or
  digits can also match a single-character typo against a name-word prefix;
  approximate results are labeled **Similar name**. Camel-case file names are
  split into words too. For example, `ttk4100 kybtintro kompendium` finds
  `KybintroKompendium.pdf` in TTK4100.
- In names-and-contents and contents-only modes, words are literal,
  case-insensitive substrings, combined with AND on one
  page or one file's title/name record. `matrix inverse` finds both on the same
  page; it does not combine unrelated pages to manufacture a match.
- In literal modes, double quotes preserve a phrase: `"change of basis"`. An unfinished quoted
  phrase works while typing. Punctuation such as `C++`, `x.y`, and `[a-z]`
  stays literal. There is no regex, fuzzy matching, stemming, or synonym expansion.
- Text is normalized with Unicode NFKC, lowercasing, and collapsed whitespace.
  A phrase can cross a line break within a page. Snippets show that normalized
  searchable text. Matching names come first, followed by content matches;
  each file appears once with its earliest matching page. The UI shows up to
  60 files and reports the full count.
- Cloud materials are searchable by name. Download them to search inside.
  Literal search reads existing extracted text and OCR indexes; it does not start OCR,
  download files, call a model, or send text to a search provider. Files without
  readable text remain discoverable by name. Original-preview placeholder text
  is excluded from evidence.

This file-finding path does not replace the tutor's existing
context selection, and it does not provide semantic question answering.

## Semantic search

Semantic search uses the quantized
[multilingual E5 small model](https://huggingface.co/Xenova/multilingual-e5-small)
on the same machine that owns the library: the Mac for native/loopback search,
or the server for hosted accounts. No document text is sent to an AI provider.
The first use downloads pinned model assets; the weights are about 113 MiB.
They are verified by SHA-256, cached under `~/.cache/scholia/models`, and reused
offline. Set `SCHOLIA_MODEL_CACHE` to place this shared model cache elsewhere.
Preparing a library takes longer than a query; the interface shows progress and
partial results while it works. This mode does not download cloud documents or
start OCR. Their metadata remains searchable by meaning.

The index is `semantic-v1.sqlite` beside the existing literal cache. Its layout
separates ownership from reusable inference work:

| Table | Stores |
| --- | --- |
| `files` | Workspace ownership, document metadata, source revision, preparation status |
| `chunks` | File, page/cell/section, chunk ordinal, vector ID |
| `vectors` | Unique text hash, chunk text, normalized 384-dimensional float vector |
| `meta` | Pinned model/chunking version and committed index generation |

Pages are split into 192-token passages with 32-token overlap, preserving source
locations. Identical passages share one embedding across files. A rename, edit,
download or OCR update invalidates that file's references; unchanged passages
reuse their vectors. Removed or replaced evidence is excluded immediately, even
while replacement passages are being prepared. Committed embeddings survive
interruptions. Model/chunking version changes rebuild only this derived cache.

Global retrieval uses a rebuildable [USearch HNSW graph](https://github.com/unum-cloud/USearch)
with float16 vectors, connectivity 16 and search expansion 128. SQLite retains
the float32 source vectors, so a missing, stale or damaged graph can be rebuilt
without inference. Graph checkpoints are tied to the committed generation and
are not rewritten by unchanged queries. Workspace searches rank vectors inside
that workspace using exact similarity; they never filter a global top-k afterward.
One scoped matrix is cached up to 32 MiB; larger scopes use bounded 2,048-vector
batches. Up to 60 files are returned, each with its strongest passage. Global
nearest-neighbor retrieval is approximate, and semantic similarity does not
guarantee relevance or an exhaustive match count.

One lazy worker and warm CPU model handle semantic requests independently of
literal search. Background inference uses four passages per batch and two CPU
threads; queries run before the next batch. Up to 64 query vectors are reused
while polling and revisiting searches. The worker keeps one account's database
open at a time, with separate files and query caches per account, and exits
after five minutes without requests once preparation is complete. The Mac talks
to this worker over private pipes and requires Node.js 24 or newer. The bundled
runtime includes the CPU dependencies; model weights are cached separately.

The API adds `mode=semantic` to `GET /api/search`, retaining the same account and
workspace checks. Queries are at most 512 characters. A `semantic` progress
object accompanies results; `total` is the displayed related-file count, not an
exhaustive count of matches. Both interfaces refresh partial results every 700 ms
and discard replies for superseded queries.

Reproduce relevance, persistence, interrupted preparation, scope isolation and
the real-model browser/native checks:

```sh
SCHOLIA_TEST_EMBEDDINGS=1 node --test tests/semantic-search.test.js
SCHOLIA_TEST_EMBEDDINGS=1 npm run smoke:chromium:search
npm run smoke:macos:search -- --semantic
SEMANTIC_BENCH_OUTPUT=dist/verification/semantic-benchmark.json npm run benchmark:search:semantic
# Optional: vary the synthetic library and number of timed queries.
SEMANTIC_BENCH_FILES=3000 SEMANTIC_BENCH_ROUNDS=31 npm run benchmark:search:semantic
```

On an M2 Max, the 600-file / 1,200-page synthetic benchmark prepared 1,800 vectors
in 14.2 seconds after loading cached model assets in 1.2 seconds. Warm-model
searches with uncached query embeddings measured 7.3 ms median / 8.6 ms p95;
reused queries measured 3.6 / 7.6 ms, and workspace queries 1.9 / 2.0 ms.
SQLite used 4.1 MiB and the graph 1.6 MiB. Peak process RSS was 775 MiB, including
model loading and indexing. These are service timings, excluding worker IPC,
HTTP, input debounce and rendering. The corpus is synthetic with short pages;
this is not a full-library latency promise or a provider comparison.

## How the retrieval path works

File names mode uses cached normalized metadata, invalidated by renames and
removals. It never reads document contents or creates a text index. On a local
catalog of 89 workspaces and 6,099 deduplicated files/materials, the hosted service's
filename lookup for the example above measured 34 ms cold and 5.6 ms warm median
(31 queries). The native debug build measured 395 ms cold and 89 ms warm median
on that catalog. These are search-service timings; the UI also debounces typing for 35 ms.

For text searches, Needle combines name records, page evidence, workspace ownership, and adaptive
fragment selection. Its indexing primitives are established SQLite features;
this is a Scholia-specific composition, not a claim to have invented trigrams.

1. Save each file's metadata and each nonempty page in a persistent SQLite
   index. Use an external-content FTS5 trigram table with `detail=none`, avoiding
   duplicate source text and per-occurrence position storage. SQLite documents
   [trigram indexing and reduced-detail storage](https://www.sqlite.org/fts5.html#the_trigram_tokenizer).
2. Sample at most 24 three-code-point fragments from the query. Consult
   `fts5vocab` for their passage frequencies and select up to three rarest
   sampled fragments. An absent fragment proves there is no match.
3. Intersect their posting lists when the rarest list covers fewer than half
   the passages in scope. Otherwise scan; one- and two-character queries also
   use a scan. This threshold is a heuristic, not an optimality guarantee.
4. Apply workspace and name/content filters and verify **every complete query
   term** using literal substring checks. Fragment collisions or terms in the
   wrong order never become results.
5. Group verified passages by file and return a bounded snippet and navigable
   source, plus coverage and timing information. `candidateUpperBound` reports
   an upper bound on candidate passages, not CPU work or disk reads.

The hosted engine uses up to two lazy workers off the HTTP thread, with a
16-request queue limit and separate index files per account. Each account is
pinned to one worker so its writes stay ordered. A worker retains one hot
account's connection, evicts it when switching accounts, and closes it after
two idle minutes. The Mac implementation owns its connection on a Swift actor
off the UI actor. Authentication, CSRF, and workspace ownership checks apply
to `GET /api/search?q=…&courseID=…&mode=all|files|content`.

The first text search prepares text in its scope. Subsequent text searches compare file
metadata, index paths, and modification stamps, update only changed files, and
remove records no longer in the library. Scoped searches prepare only that
workspace. Updates are committed in batches of at most 64 files; an interrupted
batch rolls back. Edits, downloads,
renames, and OCR sidecars become visible on the next search; a query already in
flight uses its captured library snapshot. Browser request generations prevent
old query results from replacing newer ones. Disconnects cancel queued work
and cooperatively interrupt active refreshes between files/pages. Native tasks
also check cancellation during indexing. Both search inputs debounce for 35 ms.

## Apple Silicon and memory use

Connections reuse up to 128 prepared statements and cache fragment frequencies
and scope counts. Writes invalidate these caches; `PRAGMA data_version` also
detects other connections' commits. No complete search responses are cached.
WAL, `synchronous=NORMAL`, a 4 MiB SQLite page-cache target, and up to 256 MiB
of memory mapping reduce repeated opening, allocation, and I/O work. The mmap
limit reserves address space, not 256 MiB of pinned RAM. The index is rebuildable
derived data, so loss of a recent cache transaction after a power failure does
not lose original documents.

On Apple Silicon, `ScholiaSearch.c` uses baseline **128-bit ARM NEON** to check
16 possible byte offsets together. It checks first, interior, and last bytes,
then verifies surviving candidates exactly. A SQLite function reads SQLite's
UTF-8 buffers directly; it does not copy each page into Swift. Loads stay within
the supplied lengths. Very repetitive candidates and short tails fall back to
libc; Intel builds use libc. This is a CPU implementation with no GPU setup or
new runtime dependency. The SIMD filtering technique is established; its
integration with the adaptive literal planner is specific to this search path.

The hosted Node path uses built-in substring search over a lazily materialized
text snapshot for broad queries. Estimated retained text is capped at 64 MiB
per worker, reduced according to available process memory. The estimate charges
twice the UTF-8 byte length plus per-row overhead; it is not a bound on total
process RSS. Only one snapshot is retained per worker, and larger scopes fall
back to a SQLite scan. Native search uses the NEON SQLite predicate instead of
retaining a second text snapshot. Changes invalidate snapshots and absent-gram
caches before the next query.

The worker cap limits competing memory scans and leaves CPU capacity for the
app and document extraction. Scheduling stays with macOS rather than binding
work to particular performance or efficiency cores. More threads are not
automatically faster: the included engine benchmark measures two- and
four-thread Tantivy builds separately.

The index is a disposable cache named `needle-v1.sqlite`: beside `library.json`
on Mac, or under `files/<account>/<account>/` in hosted storage. It contains
searchable document text, has owner-only file permissions, and stays in the
same storage environment as the library. Removing this cache while Scholia is
stopped causes the next search to rebuild it. Keep it in mind when provisioning
hosted disk space: it is additional to original-file quotas.

## What is provable

Let a normalized passage contain every query term. Every three-character
fragment chosen from those terms must also occur in that passage. Therefore
the passage belongs to every chosen fragment's posting list, so their
intersection cannot exclude it. Sampling fragments changes candidate counts,
not this property. The final literal verification accepts precisely the
passages that a full scan accepts. Short-query and common-query scans apply
that same predicate directly.

Thus, given the same readable index snapshot, the candidate step has no false
negatives and the returned matches have no fragment-induced false positives.
The result limit affects display only, not the reported match count. This says
nothing about OCR accuracy, semantic relevance, unavailable files, or universal
latency superiority. For selective queries, the engine verifies fewer passage
texts; actual speed is an empirical result.

## Reproduce the measurements

```sh
npm run benchmark:search
# Optional: change corpus size/repetitions or save the JSON report.
SEARCH_BENCH_FILES=1200 SEARCH_BENCH_ROUNDS=31 \
  SEARCH_BENCH_OUTPUT=/tmp/needle-benchmark.json npm run benchmark:search

node --test tests/server/workspace-search.test.js tests/server/hosted-server.test.js
npm run smoke:macos:search
npm run smoke:chromium:search
npm run test:search:native       # ASan + UBSan, 60,000 matcher comparisons
npm run benchmark:search:native  # SQLite instr / NEON / libc scan kernels

# Optional, isolated SQLite / Tantivy prototype comparison.
mkdir -p dist/verification
SEARCH_BENCH_CORPUS=dist/verification/needle-corpus.json npm run benchmark:search
uv venv --python 3.11 dist/needle-bench-venv
uv pip install --python dist/needle-bench-venv/bin/python \
  -r scripts/performance/search-benchmark-requirements.txt
dist/needle-bench-venv/bin/python scripts/performance/benchmark-search-engines.py \
  --corpus dist/verification/needle-corpus.json \
  --output dist/verification/needle-engine-comparison.json
```

The benchmark creates a deterministic temporary corpus and removes it afterward.
It compares the index with an independent, already-normalized in-memory substring
scan, the same SQLite query forced to scan, and ripgrep where literal queries
are directly comparable. Every timed run checks result identities, page numbers,
and counts against the oracle; ripgrep checks file identities. Timings report
medians and p95 for engine and service calls. Warm service calls include worker
messaging, modification checks, and result construction with a reused SQLite
connection, but exclude HTTP, the UI's 35 ms input debounce, and rendering.
First-query cache fills, fresh-worker startup, and edit visibility are reported
separately. Disk size is measured after checkpointing the WAL. Ripgrep timings
include process startup; its output contains file names rather than page evidence.

The engine comparison uses independent Python processes, the same normalized
corpus, rare-fragment selection, and exact final verification. It checks file
identities, first pages, passage counts, Unicode, and replacement visibility.
It records build time/CPU, index size, process peak RSS, warm p50/p95, and
process-cold startup with a warm filesystem cache. Tantivy's Python API uses
constant-score TopDocs and stored-document decoding; this does not measure an
optimized Rust collector. Neither engine can use token relevance as a substitute
for the literal query contract. The app does not depend on Python or Tantivy.

See [the measured literal-search example](SEARCH_BENCHMARK.md) for results including indexing
time, disk usage, and cases where scans win. Those comparisons do not pit
literal matching against embeddings, RAG pipelines or turbopuffer, and make
no general speed or relevance claim against them.
