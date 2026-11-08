# Native responsiveness and correctness

The native product is the macOS workspace. There is no local HTTP workspace server, browser-open command, or `--serve-study` mode. The app bundles only PDF search, code highlighting and public study-plan data under `NativeResources`; semantic search stays in a private child-process pipe.

## Measurement boundary

Measurements use an Apple M2 Max (12 cores), 32 GB, macOS 27.2, Swift 6.4.2, optimized release objects and the installed macOS 26.5 SDK. The 27 SDK in this Command Line Tools installation lacks its SwiftUI macro plugin. The runner selects 26.5 only when that specific condition holds; an explicit `SDKROOT` wins.

`benchmark-native.swift` hosts the **production dashboard component** in a visible AppKit window. Its alternate reading branch is a text placeholder. Timing begins at a model transition or a native text-field change and ends after a main-run-loop yield, layout and `displayIfNeeded`. It measures neither compositor scanout nor the complete app shell. Each fixture targets 30 samples after three warmups, with a 60-second fixture budget. Baseline 89-workspace data has only six samples, and the 500-workspace baseline has no warm samples because its initial paint exceeded the budget. Its zero-valued percentile fields mean “unmeasured,” not zero latency.

`benchmark-native-workspace.swift` separately hosts the actual `StudyWorkspaceView` through its production window controller, with real native reader, sidebar, tutor and composer. It inserts text through AppKit while the real provider streaming, import and Canvas-refresh state machines run with isolated deterministic transport. Provider output and Canvas requests are injected; no external provider is called. Each fixture records active/background stream overlap, import/sync overlap, cancellation, provider restart and library reload. Full-shell timings have no corresponding before series and must not be substituted into the component before/after comparison.

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
