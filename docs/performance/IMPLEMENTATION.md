# Responsive architecture implementation record

## Baseline and scope

- Isolated branch `perf/responsive-architecture`, worktree `/private/tmp/scholia-performance`; original checkout remains clean at `92a8e1689b20d30ba6c95cba9b332bece17c12ca`.
- The earlier patch, `PERFORMANCE_REVIEW.md`, `APPLY.md`, hosted reports and local commit `9d1ac29cb7077e48b5316f6c35ea35aa576f2e22` were unavailable. Useful fixes were reconstructed from current sources. Neither the requested repository nor configured origin had an open PR at initial inspection.
- User correction: ship only macOS and the Chrome extension. The hosted service, web application, loopback HTTP interface, launch hooks and deployment paths are removed. Earlier hosted optimization commits are superseded; they are not shipped capabilities. No hosted migration or deployment was performed.
- Native semantic search remains a private pipe worker in `packages/search`; JavaScriptCore helpers and study-plan data build as `NativeResources`. Libraries remain separate; cross-device synchronization is outside scope.
- Measurements: M2 Max, 12 CPU cores, 32 GB, macOS 27.2; Node 26.4.0, npm 11.17.0, Swift 6.4.2; optimized native release and Chromium 153. Synthetic temporary libraries and browser profiles only. Full UI fixtures read existing preference metadata but do not write the installed library or global settings.

## Completed stages and decisions

| Stage | Implementation and evidence |
|---|---|
| Reconciliation and baseline | Repository instructions, scripts, architecture, history and PRs inspected. Raw 6/89/500-workspace native and extension series retained under `results/performance`. Original checkout preserved. |
| Focused native performance | Metadata-only ordering/search cache; current-data resolution; bounded assignment previews and filtered full view; top-k recents; retained agenda grouping; shared Quick Jump catalog; narrow display observation. Work-count and visible UI checks pass. |
| Drafts and navigation | Off-main ordered/coalescing draft persistence, recovery/tombstones/retries, isolated errors and lifecycle barrier; atomic reading ownership/history/conversation selection; asynchronous identity and cancellation guards. Rapid navigation, deletion, replacement, exact page selection and restart checks pass. |
| Persistence | Transactional SQLite rows for navigation, courses, documents, materials, threads and messages; versioned migration, revision conflicts, per-root ownership and export recovery. Actual interrupted child processes, repeated/concurrent migration, restart, ordering, failures and rollback are tested against isolated legacy copies. |
| Native rendering and transport | Retained projections, bounded assignment paging and existing lazy material/search stacks. Actual typing during sync/import/streaming and concurrent 50 MB transfers measured; cancellation and restart verified. HTTP uploads/ranges and revisioned snapshots are removed with their products. |
| Extension startup | Four-module lazy bootstrap; independent context load; captured provider/selection state; shared initialization and retry. Packaged Chromium checks cover CSP, nested frames, first answer, concurrent triggers and failed loading. |
| GPT-6.1 Sol / Extra High | Stale model capabilities refresh in popup and Settings without losing unsaved edits. Packaged Chromium verifies popup, side panel, Settings, reload, xhigh request dispatch, bounded refresh and offline retention. No paid inference. |
| Packaging | Native helpers and semantic dependency closure work outside the repository. A guarded patch to pinned SwiftMath 1.7.3 fixes standalone signed-app font lookup; all 12 fonts, legacy rendering and strict signatures pass with development fallback hidden. Native and extension ZIPs built without installation. |
| Documentation and delivery | Performance review, raw measurements, storage migration/export/rollback, build/install instructions and verification matrix in this directory. Draft PR #6; final CI status tracked in DELIVERY.md. |

## Measurements and boundaries

Final native application-source revision: `c4492b5`. Packaging subsequently repairs SwiftMath resource lookup without changing application sources. Final comparable component series has 30 samples after three warmups. At 89/500 workspaces, filtering p95 is 24.5/47.1 ms and dashboard return is 109.6/125.0 ms. Baseline 89-workspace return was 5,046 ms with six samples; the 500-workspace baseline exceeded its warm-sample budget after a 61,630 ms initial paint. Unmeasured baseline values are not zero latency.

The complete production-window series is separate: p95 return 202/245 ms (six samples, no warmup exclusion) still exceeds 150 ms. Typing under background work is 39/49 ms; active visible streaming is 25/26 ms. Fresh-process launch-to-display p95 is 500/976 ms (five children per size, warm filesystem cache, no before series or background AppDelegate services). Native timings end at AppKit display, not compositor scanout.

A reading-position update now encodes 181–182 bytes and changes one payload row plus the transaction revision. Median targeted/reproduced-legacy save time is 0.450/94.918 ms for the 89-workspace attachment fixture and 1.375/127.967 ms at 500. These are encoded bytes and logical writes, not physical WAL/disk traffic.

Extension bootstrap falls from 1,653,863 bytes / 252 modules to 4,108 bytes / four modules. Page-load p95 is 59.2→28.6 ms in the documented Mac run. First answer has only one sample per version and increased 137.1→179.8 ms; no first-answer speedup is claimed.

## Verification and known limitations

- Local source checks, packaged Chromium, native release compilation, actual native UI, 144 search comparisons, atomic navigation, draft recovery, targeted SQLite migration/crash tests and isolated packaging pass. See DELIVERY.md for exact totals and CI links.
- The original current-page-context smoke passes unchanged at baseline and after; the previous failure was not reproduced. Its assertion remains. New navigation regressions separately cover ownership and stale loads.
- Local Command Line Tools lack XCTest. Full-Xcode CI is required; standalone release regressions are not labeled XCTest. Older Swift 6.3 CI compiles did not finish; CI now uses the official `xcode-27` runner / Xcode 27.2 with a Swift 6.4 version assertion and bounded compiler diagnostics.
- Full-window return remains above the 150 ms target; library startup still decodes the full snapshot; changed large rows encode their own payloads. Details and measurement limits are in REVIEW.md and NATIVE.md.
- No merge, deployment, installed-app replacement, paid inference, or live-data migration.

## Publication

The branch and draft PR [ravinav1/scholia#6](https://github.com/ravinav1/scholia/pull/6) are published. The GitHub connector returned HTTP 403 `Resource not accessible by integration` for PR creation; authenticated `gh` created the draft successfully. Delivery retains reviewable commits and an applicable binary patch against the baseline. Final CI and patch validation outcomes belong in DELIVERY.md and `results/performance/delivery-verification.json`.
