# Needle performance and engine comparison

Measured on 2026-09-27 on an **Apple M2 Max, 32 GiB RAM, 8 performance and
4 efficiency cores**, macOS arm64. These are synthetic workload measurements,
not universal speed guarantees. The final benchmark suites ran serially,
without other benchmark or test processes competing for the CPU.

The application keeps SQLite and adds persistent connections, prepared
statements, batched writes, mmap, bounded caches, cooperative cancellation,
and an Apple Silicon NEON verifier. Tantivy was benchmarked separately;
it is not a new application dependency.

## Application before and after

Node v26.4.0; 1,200 files, 9,600 pages, 20 workspaces, 22,647,125 bytes of
page text. The baseline has nine rounds; the optimized run has 31 rounds per
case. Medians below are milliseconds. Every measured result is checked against
an independent normalized literal-scan oracle, including file ID, first page,
passage count, and total count.

| Query | Engine before | Engine after | Service before | Service after | Service p95 after |
| --- | ---: | ---: | ---: | ---: | ---: |
| Rare literal | 1.384 | **0.185** | 11.676 | **8.994** | 10.539 |
| Absent literal | 1.315 | **0.061** | 11.178 | **8.621** | 8.945 |
| Exact phrase | 1.565 | **0.218** | 11.058 | **8.671** | 9.455 |
| Multiple terms | 2.087 | **0.479** | 11.460 | **8.595** | 9.696 |
| One workspace | 0.707 | **0.125** | 4.978 | **3.398** | 3.615 |
| Common term | 16.487 | **0.934** | 26.987 | **10.051** | 11.537 |
| Two-character term | 23.888 | **5.963** | 35.597 | **14.439** | 14.930 |

The rare-literal engine path improved **7.5×**; its complete service call
improved **1.3×**. Common and short service queries improved **2.7×** and
**2.5×**. File-stat refresh alone still takes about 5.4–5.7 ms across the full
corpus, followed by manifest transfer and result construction. Replacing the
index cannot remove this freshness cost.

The rare-literal query verifies at most **4 of 10,800 passages** including
name records. Absent fragments avoid passage verification. Selective engine
queries were 4.7–196× faster than the independent memory scan in this run.
Plain memory scanning slightly wins the common and short cases: 0.889 versus
0.934 ms, and 5.815 versus 5.963 ms. The adaptive engine adds grouping,
snippets, and metadata to those scans.

Ripgrep returned identical file IDs for comparable fixed-string queries.
Its medians were 18.0–18.6 ms for rare/absent/phrase queries and 21.8–22.0 ms
for common/short queries. These runs include spawning `rg` and return file
names without page evidence. Neither RAG nor turbopuffer was benchmarked.

First preparation, including the first query, took **7.602 seconds**, down
from 8.841 seconds in the baseline. The checkpointed index is **61,616,128
bytes**; WAL contents are included by checkpointing before measuring. There
is no disk-size reduction claim from the application optimizations.

The first common-term service call took **42.492 ms** to materialize its text
snapshot; subsequent calls are the warm figures above. Its retained-text
estimate is **44.6 MiB**, within the 64 MiB per-worker cap on this machine.
This is an allocation estimate, not process RSS. Larger scopes use a SQLite
scan instead. Cache fills can recur after edits or account eviction.

A new worker and connection with an existing index took **28.609 ms median /
31.511 ms p95** over five runs, with warm filesystem caches. Replacing one
extracted-text file and finding its new content took **15.230 ms** in one
measured update; the old content disappeared. Both include refresh work.
Warm service measurements exclude HTTP, the **35 ms** input debounce, and
rendering. No disk-cache purge or battery-energy measurement was performed.

## Apple Silicon scan kernel

The native C benchmark uses 9,600 synthetic 2,400-byte pages (23.04 MB),
31 interleaved rounds, and the system SQLite library. It **forces a full scan**
to isolate verification cost. The adaptive index normally avoids these scans
for selective or absent queries.

| Query | SQLite `instr` median | SQLite NEON median | NEON p95 | Speedup |
| --- | ---: | ---: | ---: | ---: |
| Common prefix | 2.405 ms | 2.421 ms | 6.210 ms | 0.99× |
| Two characters | 6.233 ms | 2.987 ms | 4.068 ms | 2.09× |
| Rare literal | 23.706 ms | 3.993 ms | 4.320 ms | 5.94× |
| Exact phrase | 23.341 ms | 3.812 ms | 4.289 ms | 6.12× |
| Absent literal | 22.939 ms | 3.683 ms | 4.067 ms | 6.23× |

The common-prefix case is effectively unchanged and has a noisy p95. Reading
SQLite rows dominates once the match is found immediately. Direct NEON scans
without SQLite took 1.266–1.324 ms for the long selective/absent patterns,
versus 19.3–19.4 ms for libc `memmem` on this synthetic byte distribution.
Those kernel-only numbers are not application latency.

AddressSanitizer and UndefinedBehaviorSanitizer pass **60,000 differential
checks**, including exact allocation boundaries, binary bytes, and repetitive
near-miss tails. The native application smoke test passes **144 NEON/index
versus SQLite `instr` comparisons**, including Unicode, phrases, modes, scopes,
edits, deletion, missing text, and persistence. Node tests also cover external
cache invalidation, rollback, memory-limit fallback, cancellation, and account
isolation after connection eviction.

## SQLite FTS5 versus Tantivy

These are separate **Python engine prototypes**, using Python 3.11.15,
SQLite 3.53.1 and tantivy-py 0.26.2. They use the same exported normalized
corpus, sampled rare-trigram strategy, exact substring verification, grouping,
and 200-result cap. They exclude application refreshes and snippets; their
timings must not be compared directly with the Node service timings.

Tantivy stores character trigrams with document IDs only. Literal checks
preserve Needle's contract. It uses mmap and multithreaded indexing, both
supported by the [Tantivy library](https://github.com/quickwit-oss/tantivy).
The writer heap target is **64 MB total** for each configuration. Build time
includes commit and waiting for merge threads to finish.

| Metric | SQLite FTS5 | Tantivy, 2 threads | Tantivy, 4 threads |
| --- | ---: | ---: | ---: |
| Build wall time | 6,750 ms | **688 ms** | 1,340 ms |
| Build CPU time, user + system | 6,684 ms | **1,193 ms** | 1,714 ms |
| Index bytes | 60,882,944 | **30,363,631** | 30,091,427 |
| Process peak RSS, build through updates | 158.48 MiB | **157.70 MiB** | 171.33 MiB |
| Process peak RSS, reopen/query only | 29.42 MiB | 29.16 MiB | 28.89 MiB |
| Open existing index, median | 0.580 ms | 0.955 ms | 0.791 ms |
| First selective query after reopen, median | 2.178 ms | **0.207 ms** | 0.192 ms |
| Process launch through exit, median | 42.841 ms | 46.527 ms | 42.619 ms |
| Edit-to-search visibility, median | **2.413 ms** | 146.785 ms | 161.800 ms |
| Edit-to-search visibility, p95 | **5.245 ms** | 162.311 ms | 164.162 ms |

The processes already used about 96–98 MiB peak RSS after loading Python and
the corpus, before building the index; total peaks are not engine-only memory.
Reopen measurements use seven fresh processes without loading the corpus but
retain OS page caches. Update measurements replace one existing file seven
times with a **retained writer**; writer startup is separate (0.452 ms for the
two-thread Tantivy writer). Commit and reader reload make replacements visible;
the old reader snapshot is checked too. Metadata schemas differ slightly,
so index sizes are indicative rather than isolated compression ratios.

Warm exact query timings, **median / p95**, over 31 rounds:

| Query | SQLite FTS5 | Tantivy, 2 threads |
| --- | ---: | ---: |
| Rare literal | 0.043 / 0.061 ms | **0.024 / 0.033 ms** |
| Absent literal | 0.002 / 0.003 ms | 0.002 / 0.003 ms |
| Exact phrase | 0.045 / 0.053 ms | **0.025 / 0.027 ms** |
| Multiple terms | 0.121 / 0.136 ms | **0.080 / 0.096 ms** |
| One workspace | 0.077 / 0.086 ms | **0.014 / 0.018 ms** |
| Common term | **5.233 / 6.007 ms** | 27.819 / 31.554 ms |
| Two-character term | **11.845 / 13.446 ms** | 36.219 / 38.108 ms |

Tantivy built this corpus **9.8× faster** with roughly half the index size and
lower CPU time. Four threads were slower than two at the same total heap
budget; per-thread heap and merge behavior change with this setting. This
does not establish an optimal thread count for other budgets or corpora.

The broad-query disadvantage is specific to this prototype: the Python API
uses constant-score TopDocs and decompresses stored documents for exact
verification in Python. SQLite verifies inside SQL. A native Rust
[DocSetCollector](https://docs.rs/tantivy/latest/tantivy/collector/struct.DocSetCollector.html)
and a bounded text cache could change that comparison. These measurements do
not prove SQLite is intrinsically faster for all broad queries, or that
150 ms is a lower bound on Tantivy update latency.

**Decision:** keep SQLite for the current interactive path, where changes
must appear on the next search and most selective-query latency is outside
retrieval. Tantivy is a credible faster alternative for bulk indexing and
selective retrieval. Its benchmark adapter and correctness checks are available
for backend work. The application gains do not require a new Rust/Python
runtime or changes to library metadata storage.

DuckDB and PostgreSQL were considered but not benchmarked here. DuckDB's
[vectorized execution](https://duckdb.org/docs/current/internals/overview#execution)
is relevant to bulk analysis; it does not establish lower interactive literal
search latency. PostgreSQL's
[`pg_trgm` indexes](https://www.postgresql.org/docs/current/pgtrgm.html#PGTRGM-INDEX)
support `LIKE`, `ILIKE`, and regex candidates, making it a candidate for a
shared hosted service. Its trigram extraction ignores non-word characters,
and queries without usable trigrams can require full-index scans; Needle's
punctuation and short-query semantics would still need verification.

## Reproduction and raw evidence

Commands and the recall argument are in [SEARCH.md](SEARCH.md). Sources:
[application benchmark](../scripts/benchmark-workspace-search.mjs),
[native scan benchmark](../scripts/benchmark-needle-native.c), and
[engine comparison](../scripts/benchmark-search-engines.py).

Measured JSON files are kept locally in ignored build output:

- `dist/verification/needle-before-optimization.json`
- `dist/verification/needle-after-optimization.json`
- `dist/verification/needle-native-benchmark.json`
- `dist/verification/needle-engine-comparison.json`

Validation: `npm run check` (381 tests), native search smoke, Chromium search
smoke, focused cancellation tests, native ASan/UBSan checks, and all three
benchmark oracles passed. Swift XCTest is unavailable in this command-line-tools
environment; the native smoke executable links and exercises actual application
objects.
