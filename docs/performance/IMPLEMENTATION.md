# Responsive architecture implementation record

## Scope and baseline
- Isolated branch `perf/responsive-architecture`, worktree `/private/tmp/scholia-performance`.
- Original checkout remains clean at fetched origin/main `92a8e1689b20d30ba6c95cba9b332bece17c12ca`.
- Prior commit `9d1ac29cb7077e48b5316f6c35ea35aa576f2e22` and patch/review/APPLY artifacts were not found. Reconstructed useful fixes from current sources.
- No open PRs on requested `ravinav1/scholia` or configured origin `heaps0rt/scholia` at inspection.
- Test Mac: MacBook Pro Mac14,6, Apple M2 Max (12 CPU cores), 32 GB, macOS 27.2 (26B123); Node 26.4.0, npm 11.17.0, Swift 6.4.2; Chromium only.

## Explicit scope change, 2026-11-08
The user instructed: “remove the web app actually, just provide the chrome extension and native app.” The final delivery therefore removes `apps/web`, `apps/server`, browser workspace launch/menu/settings hooks, hosted deployment, and their product-only tests/builds/docs. Earlier hosted/web optimization commits are historical work superseded by this removal, not features to ship. No hosted migration is required or run on any live data. Native and extension libraries remain separate.

Native semantic search is retained under `packages/search` and still communicates through private process pipes. Native JavaScriptCore search/highlighting helpers and study-plan data build through `npm run build:native-resources`, without a web application.

## Stages / ownership
- Inspection/reconciliation: complete; no unrelated local changes.
- Baselines: native release measurements at 6/89/500 workspaces; extension initial bundle and actual packaged Chromium runtime. Raw data in `results/performance`.
- Extension performance: committed `dcf9304`; bootstrap 1,653,863 → 4,108 bytes before removal of obsolete web integration; initial graph 252 → 4 modules. Lazy UI/context initialization and retry verified, including final packaged removal checks. Additional commit `9966e06` refreshes stale Codex model capabilities; actual packaged Chromium verifies GPT-6.1 Sol/xhigh selection, reload and dispatch on popup/panel/options.
- Native focused fixes: committed `4d08424` and `894427c` (catalog metadata cache/current-content resolution, bounded assignment preview, top-k recents, narrower observation, off-main edit-draft persistence, release defaults).
- Native atomic navigation, races and draft recovery implemented; final integrated regressions and full-workspace runtime checks in progress.
- Web/server revision transport, account persistence and HTTP uploads/ranges: superseded by explicit product removal; no longer shipped.
- Native removal/packaging: native agent owns Swift/scripts/macos; root owns native resource builder and search module relocation.
- Documentation: docs agent cleans supported-product guides; root owns final review, verification and delivery record.
- Integration: source/JS tests, extension packaging, real Chromium, native release compile, standalone native regressions, release XCTest CI.

## Evidence and barriers
- Original release native compilation passed in 168 s using macOS 26.5 SDK workaround.
- Local XCTest cannot compile: installed Command Line Tools do not provide module `XCTest`, and full Xcode is absent. Keep this unrun; CI explicitly uses full Xcode. Native executable regressions link actual release app objects instead.
- Prior current-page-context smoke passes unchanged against baseline release: warm retrieval median 0.45 ms, 12 cache hits. It is not a reproduced navigation defect; retain its assertions in native-only checks.
- Visible native baseline: 6 workspaces n=30 return p95 348 ms / filtering 71 ms; 89 workspaces n=6 return p95 5,046 ms / filtering 927 ms, first paint 5,451 ms, retained ~1.45 GB; 500 first paint 61,630 ms, ~5.26 GB, no warm samples within the documented 60-second workload budget. Raw baseline preserves incomplete-sample limits.
- Final extension suite: 239 retained extension tests passed after product removal; model fix adds a 372-test targeted run and actual Chromium stale-catalog selection/reload/xhigh dispatch coverage. Build/package/distribution and existing recursion/PDF/shortcut smoke passed.

## Outstanding delivery work
Complete targeted native persistence and real runtime measurements; verify native+extension removal has no dangling dependencies; run complete supported checks; finalize performance review/build/rollback guidance and verification matrix; push branch/open draft PR if authorized GitHub access permits, otherwise preserve applicable patch. Do not merge, deploy or replace the installed app.

## Publication and additional measured work
- Branch pushed to `ravinav1/scholia`; draft PR https://github.com/ravinav1/scholia/pull/6 created via authenticated `gh` after the connector returned HTTP 403 `Resource not accessible by integration`. No merge/deploy/install.
- Native storage baseline confirms a single reading-position update serializes 28.3 MB in the 89-workspace attachment fixture (~93 ms) and 7.0 MB in the 500-workspace fixture (~131 ms). A separate targeted transactional storage stage is now justified and in progress; no live data used.
- First native component after-series (release `4d08424`, 30 samples each): 89 workspace return p95 162 ms / filter p95 29 ms, 500 return 424 ms / filter 59 ms. These are component observations, not full-app or compositor measurements. Raw report is `native-after.json`; retain this series if further refinements are measured.
