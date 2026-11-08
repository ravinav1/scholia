# Workspace search

Open **Search files** or press **⌘K** in the Mac workspace.
Search defaults to **File names** across **All workspaces**. It matches file titles,
names, course codes and course names directly from the catalog, without waiting
for text indexing. Switch to names and contents or contents only to look inside
documents, or restrict the search to the current workspace. Selecting a content result opens its
page, notebook cell, or document section.

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
locally on your Mac. No document text is sent to an AI provider.
The first use downloads pinned model assets; the weights are about 113 MiB.
They are verified by SHA-256, cached under `~/.cache/scholia/models`, and reused
offline. Set `SCHOLIA_MODEL_CACHE` to place this shared model cache elsewhere.
Preparing a library takes longer than a query; the interface shows progress and
partial results while it works. This mode does not download cloud documents or
start OCR. Their metadata remains searchable by meaning.

The index is `semantic-v1.sqlite` beside the existing literal cache. Its layout
separates ownership from reusable inference work:

| Table     | Stores                                                                      |
| --------- | --------------------------------------------------------------------------- |
| `files`   | Workspace ownership, document metadata, source revision, preparation status |
| `chunks`  | File, page/cell/section, chunk ordinal, vector ID                           |
| `vectors` | Unique text hash, chunk text, normalized 384-dimensional float vector       |
| `meta`    | Pinned model/chunking version and committed index generation                |

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
while polling and revisiting searches. The worker keeps one library database
open at a time, with separate files and query caches per library, and exits
after five minutes without requests once preparation is complete. The Mac talks
to this `packages/search` worker over private pipes and requires Node.js 24 or
newer. The bundled runtime includes the CPU dependencies; model weights are cached separately.

Queries are at most 512 characters. Results report preparation progress and a
displayed related-file count, not an exhaustive count of matches. The search
view refreshes partial results every 700 ms and discards superseded replies.

Reproduce relevance, persistence, interrupted preparation, scope isolation and
the real-model native checks:

```sh
SCHOLIA_TEST_EMBEDDINGS=1 node --test tests/semantic-search.test.js
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
model loading and indexing. These historical worker timings exclude IPC, input
debounce, and rendering. The corpus is synthetic with short pages; this is not a
full-library latency promise or a provider comparison.

## How the retrieval path works

File names mode uses cached normalized metadata, invalidated by renames and
removals. It never reads document contents or creates a text index. The search
input debounces typing for 35 ms. Current application measurements and limits
are tracked in the [performance review](performance/IMPLEMENTATION.md).

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

The native implementation owns its SQLite connection on a Swift actor off the
UI actor. Workspace scoping is applied before results are returned.

The first text search prepares text in its scope. Subsequent text searches compare file
metadata, index paths, and modification stamps, update only changed files, and
remove records no longer in the library. Scoped searches prepare only that
workspace. Updates are committed in batches of at most 64 files; an interrupted
batch rolls back. Edits, downloads,
renames, and OCR sidecars become visible on the next search; a query already in
flight uses its captured library snapshot. Request generations prevent old
query results from replacing newer ones, and native tasks check cancellation
during indexing.

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

Native search uses the NEON SQLite predicate without retaining a second full
text snapshot. Scheduling stays with macOS rather than binding work to
particular performance or efficiency cores.

The index is a disposable cache named `needle-v1.sqlite` beside `library.sqlite`
on your Mac. It contains searchable document text and has owner-only file
permissions. Removing it while Scholia is stopped causes the next search to
rebuild it; original documents are unaffected.

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
npm run smoke:macos:search
npm run test:search:native        # ASan + UBSan, 60,000 matcher comparisons
npm run benchmark:search         # SQLite instr / NEON / libc scan kernels
npm run benchmark:search:native  # Alias for the same native benchmark
```

The native benchmark compiles the application's C verifier with optimization,
checks it against an independent matcher, then compares forced SQLite and raw
buffer scans. It uses a deterministic synthetic corpus with 9,600 pages and
31 rounds. These kernel timings exclude document indexing, input debounce,
source loading, and rendering; they are not end-to-end application latency.

See [the dated search measurements](SEARCH_BENCHMARK.md) for native scan results
and an archived SQLite/Tantivy prototype comparison. The current
[performance review](performance/IMPLEMENTATION.md) tracks broader app work.
