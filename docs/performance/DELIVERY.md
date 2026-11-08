# Build, verification and delivery

This change ships two independent products: the macOS app and Chrome extension. Their libraries do not synchronize. The removed hosted/browser app is no longer built or served. Existing deployments are not automatically changed.

## Build without installing

Use Node.js 24 or newer and the lockfile:

```sh
npm ci
npm run check
npm run build:native-resources
npm run package:chrome
npm run build:macos
```

The extension ZIP is `dist/scholia-chrome-0.2.2.zip`; its unpacked directory is `dist/chrome`. The native bundle is `dist/macos/Scholia.app`. `build:macos` packages an optimized release and does not install it. `npm run build:macos -- debug` is an explicit development build. Full Xcode is required for XCTest; the release smoke runner also supports the installed Command Line Tools configuration described in the native report.

For a local ad hoc package without certificate provisioning:

```sh
SCHOLIA_CODESIGN_IDENTITY=- SCHOLIA_AUTO_LOCAL_SIGNING=0 npm run build:macos
```

## Installation is a user action

Quit Scholia and back up its application support directory before upgrading persistent storage. See [native storage migration and export](NATIVE_STORAGE.md) before rolling back. To install after review, run `npm run install:macos`; to install and launch, run `npm run update:macos`. Neither command is part of the automated delivery.

For a new extension installation, use Chromium or Chrome's extensions page to load `dist/chrome` as an unpacked extension or use the packaged release process. To update an existing unpacked installation while preserving its identity and storage, rebuild/copy the new files into its existing loaded directory and choose Reload for that same extension; loading a different directory can create a separate extension identity. This work uses temporary Chromium profiles and does not reload the user's installed extension. Extension settings and history formats remain compatible; selecting a model and reasoning effort persists through the existing settings store.

## Reproduce runtime checks

```sh
node scripts/performance/benchmark-extension.mjs --packaged --after-removal
npm run smoke:chromium:recursion
zsh scripts/macos/run-release-check.sh scripts/performance/native-focused-regressions.swift
zsh scripts/macos/run-release-check.sh --skip-build scripts/performance/native-review-regressions.swift
zsh scripts/macos/run-release-check.sh --skip-build scripts/performance/native-persistence-regressions.swift
SCHOLIA_BUILD_ID=$(git rev-parse HEAD) zsh scripts/macos/run-release-check.sh --skip-build scripts/performance/benchmark-native.swift /tmp/scholia-native-after.json
```

Keep raw reports from each run; stage-specific report filenames are overwritten by repeat runs. Fixtures are synthetic and stored in temporary directories. Never point migration tests at the live library. Use Chromium, not Brave. For the baseline, use an isolated checkout at `92a8e16` and the baseline-compatible measurement harness.

## Verification matrix

| Check | Result / boundary |
|---|---|
| Complete JavaScript/source checks | **Passed:** 440 tests, zero failures, 2 opt-in skips. |
| Extension build, ZIP and distribution checks | **Passed**, including initial bootstrap budget and named lazy resources. |
| Actual packaged Chromium, Mac | **Passed:** CSP, nested frames, first answer, retry, concurrent initialization, popup/settings, recursion, keyboard and PDF interactions. |
| GPT-6.1 Sol / Extra High | **Passed:** popup, side panel and Settings, stale discovery, reload persistence, xhigh dispatch, unsaved settings, bounded refresh and offline retention. |
| Native release compilation | **Passed:** final application sources at `c4492b5`, Swift 6.4.2, macOS 26.5 SDK. |
| Native atomic navigation and context | **Passed:** draft/conversation ownership, one history entry, exact search page, rapid navigation, replacement/deletion, current-page context and 144 search comparisons. |
| Actual native UI | **Passed:** Quick Jump rapid typing and keyboard selection, assignments, wide/compact layout, light/dark, drafts, attachments and error states. |
| Native persistence and recovery | **Passed:** exact changed payload rows, legacy migration, simultaneous first launch, actual process-crash recovery, conflicts, ordered tombstones, retry, Unicode/NUL IDs, rollback export and root isolation. |
| Native timing collection | **Completed:** raw component, full window, fresh process, storage and transfer series; see target results below. |
| Native app package | **Passed:** production app built, ad hoc signed and deep/strict verified; isolated semantic runtime and all 12 bundled math fonts work with development fallbacks unavailable. No installed app was replaced. |
| Local release XCTest | **Unrun:** Command Line Tools do not provide `XCTest`; full Xcode is absent. |
| Linux source/package/Chromium CI | **Passed:** [run 42434768150](https://github.com/ravinav1/scholia/actions/runs/42434768150), including actual packaged extension and GPT-6.1 Sol/xhigh smoke. |
| Full-Xcode release XCTest CI | [Swift 6.4 run 42435124350](https://github.com/ravinav1/scholia/actions/runs/42435124350) in progress. Previous Swift 6.3 runs did not finish compilation; no XCTest pass is inferred. |
| Optional live embedding-model test | **Skipped:** not enabled; deterministic semantic-index tests passed. |
| Optional Terminal-window updater test | **Skipped:** desktop Terminal opt-in not enabled; disposable app replacement tests passed. |
| Merge, deployment, installation | **Not performed**, as requested. |

The previous Xcode 26.5 compiler sample was entirely in `ClosureLifetimeFixup` / `computeDominatedBoundaryBlocks` at the sampled instant, with a 1.2 GB footprint. That is compiler-side evidence, not an application runtime stall or a completed diagnosis of the source trigger. Raw sample and process counters are retained in `results/performance/ci-swift-6.3`. CI now uses the official `xcode-27` runner and Xcode 27.2, with a Swift 6.4 assertion matching local verification and bounded diagnostic collection.

The prior current-page-context smoke passed both before and after this change, unchanged. It was not a reproduced navigation defect. New ownership/race regressions independently cover actual navigation faults. Two additional native UI smoke assumptions were corrected with retained behavior assertions: keyboard prediction now uses the UI's file-search scope, and useful composer height measures its editing viewport. The compact control was raised to the existing 32-point minimum assertion.

The supported checks above distinguish real application/browser execution from compilation and syntax validation. Standalone native checks link optimized application objects; they are not reported as XCTest. Fixtures use temporary libraries and profiles. No live account migration, paid inference, or installed-profile changes are part of verification.

## Performance targets and limits

On the documented M2 Max, the final comparable dashboard component series (30 samples after three warmups) gives p95 filtering **24.5 ms at 89 workspaces** and **47.1 ms at 500**. Its return p95 is **109.6 / 125.0 ms**, down from 5,046 ms for the six-sample 89-workspace baseline. The 500-workspace baseline did not complete warm samples; its unmeasured fields are not zero latency.

The actual full-workspace return series remains **202 / 245 ms p95** at 89/500 workspaces (six samples, no excluded warmup), above the proposed 150 ms target. It includes the complete window/reader/sidebar transition, which is excluded from the component comparison. This residual view/layout path remains measurable work; no storage or component speedup is presented as meeting the full-window target. Typing during overlapping background work is **39 / 49 ms p95**; active-visible-stream typing is **25 / 26 ms**.

Fresh-process first-dashboard display is **500 / 976 ms p95** at 89/500 workspaces. Each child is new, while filesystem caches are warm. This starts at process launch and ends at AppKit display; compositor scanout and external AppDelegate services are excluded. There is no prechange fresh-process baseline.

See [NATIVE.md](NATIVE.md), [NATIVE_STARTUP.md](NATIVE_STARTUP.md), [NATIVE_STORAGE.md](NATIVE_STORAGE.md), [EXTENSION.md](EXTENSION.md), and `results/performance/environment.json` for fixtures, raw samples, CPU/memory observations, encoding counts, methods and limitations.

## Review and patch application

The implementation is published as draft PR [ravinav1/scholia#6](https://github.com/ravinav1/scholia/pull/6), branch `perf/responsive-architecture`. Review the final tree: early hosted/web optimization commits in its history were superseded by the explicit product removal. The original checkout remains on its original branch.

An applicable binary patch is generated against `92a8e1689b20d30ba6c95cba9b332bece17c12ca`. Apply it to an isolated checkout of that baseline, not over unrelated local edits:

```sh
git worktree add --detach /tmp/scholia-review 92a8e1689b20d30ba6c95cba9b332bece17c12ca
cd /tmp/scholia-review
git apply --check /path/to/scholia-performance.patch
git apply /path/to/scholia-performance.patch
npm ci
```

To undo an uninstalled review, remove only that isolated worktree. After installation, rebuilding an earlier native version requires the current SQLite-to-JSON export described in [NATIVE_STORAGE.md](NATIVE_STORAGE.md). Returning to the untouched migration JSON alone would lose subsequent edits. Keep the complete data backup before any rollback. Extension rollback uses the previous package in the same extension identity; this change does not migrate its storage schema.
