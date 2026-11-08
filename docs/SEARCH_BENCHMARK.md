# Needle performance and engine comparison

Measured on 2026-09-27 on an **Apple M2 Max, 32 GiB RAM, 8 performance and
4 efficiency cores**, macOS arm64. These are synthetic workload measurements,
not universal speed guarantees. The final benchmark suites ran serially,
without other benchmark or test processes competing for the CPU.

The application keeps SQLite and adds persistent connections, prepared
statements, batched writes, mmap, bounded caches, cooperative cancellation,
and an Apple Silicon NEON verifier. Tantivy was benchmarked separately;
it is not a new application dependency.

## Apple Silicon scan kernel

The native C benchmark uses 9,600 synthetic 2,400-byte pages (23.04 MB),
31 interleaved rounds, and the system SQLite library. It **forces a full scan**
to isolate verification cost. The adaptive index normally avoids these scans
for selective or absent queries.

| Query          | SQLite `instr` median | SQLite NEON median | NEON p95 | Speedup |
| -------------- | --------------------: | -----------------: | -------: | ------: |
| Common prefix  |              2.405 ms |           2.421 ms | 6.210 ms |   0.99× |
| Two characters |              6.233 ms |           2.987 ms | 4.068 ms |   2.09× |
| Rare literal   |             23.706 ms |           3.993 ms | 4.320 ms |   5.94× |
| Exact phrase   |             23.341 ms |           3.812 ms | 4.289 ms |   6.12× |
| Absent literal |             22.939 ms |           3.683 ms | 4.067 ms |   6.23× |

The common-prefix case is effectively unchanged and has a noisy p95. Reading
SQLite rows dominates once the match is found immediately. Direct NEON scans
without SQLite took 1.266–1.324 ms for the long selective/absent patterns,
versus 19.3–19.4 ms for libc `memmem` on this synthetic byte distribution.
Those kernel-only numbers are not application latency.

AddressSanitizer and UndefinedBehaviorSanitizer pass **60,000 differential
checks**, including exact allocation boundaries, binary bytes, and repetitive
near-miss tails. The native application smoke test passes **144 NEON/index
versus SQLite `instr` comparisons**, including Unicode, phrases, modes, scopes,
edits, deletion, missing text, and persistence. These are recorded results from
the dated run, not a claim that the current checkout has repeated them.

## Archived SQLite FTS5 versus Tantivy experiment

These are separate **Python engine prototypes**, using Python 3.11.15,
SQLite 3.53.1 and tantivy-py 0.26.2. They use the same exported normalized
corpus, sampled rare-trigram strategy, exact substring verification, grouping,
and 200-result cap. They exclude application refreshes and snippets; their
timings must not be compared directly with application latency. The corpus
exporter belonged to the retired web backend, so this is historical evidence
rather than a supported current reproduction workflow.

Tantivy stores character trigrams with document IDs only. Literal checks
preserve Needle's contract. It uses mmap and multithreaded indexing, both
supported by the [Tantivy library](https://github.com/quickwit-oss/tantivy).
The writer heap target is **64 MB total** for each configuration. Build time
includes commit and waiting for merge threads to finish.

| Metric                                     |  SQLite FTS5 | Tantivy, 2 threads | Tantivy, 4 threads |
| ------------------------------------------ | -----------: | -----------------: | -----------------: |
| Build wall time                            |     6,750 ms |         **688 ms** |           1,340 ms |
| Build CPU time, user + system              |     6,684 ms |       **1,193 ms** |           1,714 ms |
| Index bytes                                |   60,882,944 |     **30,363,631** |         30,091,427 |
| Process peak RSS, build through updates    |   158.48 MiB |     **157.70 MiB** |         171.33 MiB |
| Process peak RSS, reopen/query only        |    29.42 MiB |          29.16 MiB |          28.89 MiB |
| Open existing index, median                |     0.580 ms |           0.955 ms |           0.791 ms |
| First selective query after reopen, median |     2.178 ms |       **0.207 ms** |           0.192 ms |
| Process launch through exit, median        |    42.841 ms |          46.527 ms |          42.619 ms |
| Edit-to-search visibility, median          | **2.413 ms** |         146.785 ms |         161.800 ms |
| Edit-to-search visibility, p95             | **5.245 ms** |         162.311 ms |         164.162 ms |

The processes already used about 96–98 MiB peak RSS after loading Python and
the corpus, before building the index; total peaks are not engine-only memory.
Reopen measurements use seven fresh processes without loading the corpus but
retain OS page caches. Update measurements replace one existing file seven
times with a **retained writer**; writer startup is separate (0.452 ms for the
two-thread Tantivy writer). Commit and reader reload make replacements visible;
the old reader snapshot is checked too. Metadata schemas differ slightly,
so index sizes are indicative rather than isolated compression ratios.

Warm exact query timings, **median / p95**, over 31 rounds:

| Query              |            SQLite FTS5 |   Tantivy, 2 threads |
| ------------------ | ---------------------: | -------------------: |
| Rare literal       |       0.043 / 0.061 ms | **0.024 / 0.033 ms** |
| Absent literal     |       0.002 / 0.003 ms |     0.002 / 0.003 ms |
| Exact phrase       |       0.045 / 0.053 ms | **0.025 / 0.027 ms** |
| Multiple terms     |       0.121 / 0.136 ms | **0.080 / 0.096 ms** |
| One workspace      |       0.077 / 0.086 ms | **0.014 / 0.018 ms** |
| Common term        |   **5.233 / 6.007 ms** |   27.819 / 31.554 ms |
| Two-character term | **11.845 / 13.446 ms** |   36.219 / 38.108 ms |

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
for search-engine experiments. The application gains do not require a new
Rust/Python runtime or changes to library metadata storage.

## Reproduction and raw evidence

Current native reproduction commands and the recall argument are in
[SEARCH.md](SEARCH.md). The [native scan benchmark](../scripts/performance/benchmark-needle-native.c)
remains runnable. The [engine comparison](../scripts/performance/benchmark-search-engines.py)
requires an existing exported corpus from the historical experiment.

The original measured JSON files were stored in ignored build output:

- `dist/verification/needle-native-benchmark.json`
- `dist/verification/needle-engine-comparison.json`

The September run reported native search smoke, native ASan/UBSan checks, and
benchmark-oracle passes. Swift XCTest was unavailable in that Command Line
Tools environment. Current release verification and application measurements
are tracked separately in the [performance review](performance/IMPLEMENTATION.md).
