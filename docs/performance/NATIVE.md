# Native responsiveness and correctness

The native product is the macOS workspace. There is no local HTTP workspace server, browser-open command, or `--serve-study` mode. The app bundles only PDF search, code highlighting and public study-plan data under `NativeResources`; semantic search stays in a private child-process pipe.

## Measurement boundary

Measurements use an Apple M2 Max (12 cores), 32 GB, macOS 27.2, Swift 6.4.2, optimized release objects and the installed macOS 26.5 SDK. The 27 SDK in this Command Line Tools installation lacks its SwiftUI macro plugin. The runner selects 26.5 only when that specific condition holds; an explicit `SDKROOT` wins.

`benchmark-native.swift` hosts the **production dashboard component** in a visible AppKit window. Its alternate reading branch is a text placeholder. Timing begins at a model transition or a native text-field change and ends after a main-run-loop yield, layout and `displayIfNeeded`. It measures neither compositor scanout nor the complete app shell. Each fixture targets 30 samples after three warmups, with a 60-second fixture budget. Baseline 89-workspace data has only six samples, and the 500-workspace baseline has no warm samples because its initial paint exceeded the budget. Its zero-valued percentile fields mean “unmeasured,” not zero latency.

`benchmark-native-workspace.swift` separately hosts the actual `StudyWorkspaceView` through its production window controller, with real native reader, sidebar, tutor and composer. It inserts text through AppKit while the real provider streaming, import and Canvas-refresh state machines run with isolated deterministic transport. Provider output and Canvas requests are injected; no external provider is called. Each fixture records active/background stream overlap, import/sync overlap, cancellation, provider restart and library reload. Full-shell timings have no corresponding before series and must not be substituted into the component before/after comparison.

Its `coldWorkspaceMs` starts at window/controller construction, after model creation. It is not process-startup latency. Its six return-navigation samples have no warmup exclusion. The component series includes model creation in initial paint but also starts inside an already-running measurement process.

Both harnesses use temporary libraries and disabled window autosave. `AppModel.shared` reads existing application preferences and saved conversation metadata for normal UI configuration; the harness does not start application services, install an app, replace the user's library or persist global settings. Resource/build scripts do not launch a browser. Raw timings, CPU seconds, resident memory and heartbeat delays are under `results/performance/native-*.json`. Resident memory is the measurement process after a fixture's navigation/workload, not an independently isolated per-window allocation. Heartbeat samples estimate main-actor scheduling delay; they are not profiler-confirmed frame drops.

## Architecture changes

- Course ordering caches only locale-sensitive metadata and resolves indices against the current library, so a cached order cannot retain stale conversations or documents. Quick Jump shares the order. Rename, code, favorite, semester, locale and membership changes invalidate it; typing does not.
- Dashboard and assignment observers compare only their displayed projections. Chat tokens, composer drafts and sync progress do not publish new dashboard/agenda values. Canvas authentication, eligibility and update-title changes remain observed. Deadline grouping and submission counts survive dashboard reopening, with a four-entry cache invalidated by assignment input and minute boundaries.
- Recent readings retain only the top few entries. The dashboard shows the nearest twelve assignment deadlines with an explicit total and “View all”; the full assignment view exposes every match through 100-row pages and native buttons. Material and search results use lazy stacks. Search retains its matching total and explicit result limit. Keyboard navigation and accessibility identifiers are retained.
- `openReading` validates course/document ownership against current state, preserves the outgoing draft and commits ownership, assignment and conversation selection as one library snapshot. Search, recent reading, practice and citations use it. Back/forward and course selection also publish coherent selections. Citation navigation keeps its conversation. A single opening records one history entry.
- Index and OCR completion requires the active load ticket and full document identity, including file name, source version and local edit revision. An old load cannot replace a newer navigation, deletion or same-ID replacement. A late downloaded material may open only if no newer reading navigation occurred.
- Editing drafts encode/write on a utility queue. Pending writes coalesce per document; in-flight writes finish before tombstones; recovery reads the ordered queue. Retry preserves failed operations, and successful writes to another document cannot erase an error. Navigation queues drafts; termination flushes a durability barrier. Save failures and backup failures remain distinct.

## Verification and reproduction

```sh
npm run build:native-resources
zsh scripts/macos/run-release-check.sh scripts/performance/native-focused-regressions.swift
zsh scripts/macos/run-release-check.sh --skip-build scripts/performance/native-review-regressions.swift
zsh scripts/macos/run-release-check.sh --skip-build scripts/macos-reading-context-smoke.swift
zsh scripts/smoke/macos/run.sh workspace --skip-build --assignment-opening-only
zsh scripts/smoke/macos/run.sh workspace --skip-build --course-ui-only
zsh scripts/smoke/macos/run.sh search --skip-build
SCHOLIA_BUILD_ID="$(git rev-parse HEAD)" zsh scripts/macos/run-release-check.sh --skip-build \
  scripts/performance/benchmark-native.swift results/performance/native-after.json
SCHOLIA_BUILD_ID="$(git rev-parse HEAD)" zsh scripts/macos/run-release-check.sh --skip-build \
  scripts/performance/benchmark-native-workspace.swift results/performance/native-workspace-after.json
```

Avoid builds and other heavy jobs during timing collection. The release runner links only the current SwiftPM output map: incremental build directories may still contain object files for removed sources. Ordinary macOS build/install scripts default to release; `debug`/`--debug` remains available explicitly. Packaging and installing are separate actions.

Local XCTest is unavailable because this machine has Command Line Tools without the XCTest module/full Xcode. Standalone checks link the actual optimized app objects; they do not replace a claimed XCTest pass. The full-Xcode CI job compiles release, runs XCTest and runs the standalone focused regressions. CI status is recorded in the final delivery report.

The pre-existing adaptive current-page context smoke passed on baseline and after the changes (approximately 0.45 ms and 0.51 ms warm median respectively, twelve cache hits, zero additional source-file reads). It was not a reproduced navigation bug. Navigation improvements are supported by the new ownership, history, draft, replacement and deletion checks instead.

## Initial measured stage

The first optimized stage is retained in `native-intermediate.json` and `native-workspace-intermediate.json`, built from `4d08424`. Later agenda-cache and persistence changes require a separate final measurement rather than relabeling this run.

| Workspaces | Baseline component return p95 | Intermediate return p95 | Baseline filter p95 | Intermediate filter p95 | Baseline initial paint | Intermediate initial paint |
|---:|---:|---:|---:|---:|---:|---:|
| 6 | 348 ms | 111 ms | 71 ms | 18 ms | 532 ms | 333 ms |
| 89 | 5,046 ms (n=6) | 162 ms (n=30) | 927 ms | 29 ms | 5,451 ms | 266 ms |
| 500 | unmeasured | 424 ms (n=30) | unmeasured | 59 ms | 61,630 ms | 717 ms |

Intermediate component resident memory after the workload was approximately 143/205/341 MB at 6/89/500 workspaces, versus baseline 224/1,453/5,265 MB. Full-workspace return p95 was 203/230/479 ms; typing during background work was 49/41/43 ms. The initial full run had only 2/4/4 samples with all three operations overlapping and followed import navigation away from the streaming conversation; the final harness includes a separate active-visible-stream typing series.

## Final measured release

The final app objects are built from `c4492b5`, including retained agenda grouping, atomic navigation, granular SQLite persistence and the 32-pixel minimum compact composer. `native-after.json` and `native-workspace-after.json` contain the raw samples and CPU/memory/scheduling measurements. All component cases completed 30 measured samples after three warmups.

| Workspaces | Component return p50 / p95 | Filter p50 / p95 | Initial component paint | Process RSS after workload |
|---:|---:|---:|---:|---:|
| 6 | 89.6 / 94.7 ms | 8.1 / 14.0 ms | 266.9 ms | 141 MB |
| 89 | 104.7 / 109.6 ms | 8.5 / 24.5 ms | 254.0 ms | 189 MB |
| 500 | 122.6 / 125.0 ms | 8.5 / 47.1 ms | 707.4 ms | 294 MB |

The component meets the 150 ms return and 50 ms filtering targets in this run. Those results do **not** establish the same target for the full workspace:

| Workspaces | Full-workspace return p95, n=6 | Typing with background work p95, n=30 | Visible streaming typing p95, n=10 | Samples overlapping stream + import + sync |
|---:|---:|---:|---:|---:|
| 6 | 199.3 ms | 36.2 ms | 29.0 ms | 3 |
| 89 | 202.3 ms | 38.9 ms | 25.2 ms | 5 |
| 500 | 245.5 ms | 48.9 ms | 25.9 ms | 5 |

Full-workspace return remains above 150 ms. The full shell, sidebar, actual reader and tutor transition add work beyond the isolated dashboard. No before series at this boundary was captured, so a full-app speedup percentage is not supported. All three full-workspace cases canceled an active provider stream, completed a new provider request, and reloaded the typed drafts from disk successfully. Process RSS after that workload was approximately 277/300/335 MB. The explicit sample overlap counts prevent treating the entire typing series as simultaneous three-operation load.

`native-downloads-after.jsonl` also covers the retained Canvas transport: 1/10/50 MB chunked downloads took 2.1/4.8/18.2 ms and 0.0027/0.0087/0.0359 CPU seconds in a local URLProtocol fixture. Two concurrent 50 MB downloads completed in 26.7 ms and 0.057 CPU seconds. The two main-actor heartbeat delays during that short operation were 1.12 and 5.07 ms. Process peak RSS was 325 MB across the entire sequential/bulk/concurrent audit, including fixture generation and earlier retained baseline buffers. These are single samples of the isolated transport, not internet throughput or per-transfer allocation limits.

Local release checks passed for atomic ownership/history/citations/search page selection, rapid navigation, replacement/deletion, draft ordering/recovery/retry, dashboard work counts and Canvas eligibility, assignment pagination, writer failure durability, active-stream cancellation/restart, and native Quick Jump/search keyboard actions. The full course UI smoke passed wide/standard/compact/light/dark layouts, draft preservation, filtering, attachment/error behavior, and accessible controls. Search also passed 144 indexed-versus-scan comparisons, including Unicode, scope, edits, deletion and missing content. The keyboard fixture uses the UI's actual file-name mode and two saved year-specific readings, so cloud-first results cannot change the expected selected row.

Granular persistence work, lossless migration, crash/rollback tests and rollback/export procedures are documented in [NATIVE_STORAGE.md](NATIVE_STORAGE.md).

A separate [fresh-process startup measurement](NATIVE_STARTUP.md) records five distinct process launches per size: launch-to-useful native display p50/p95 was 414/431 ms (6), 495/500 ms (89), and 968/976 ms (500). These runs use prepared databases and a warm filesystem cache, omit background app services, and exclude compositor scanout. They have no before-series comparison.
