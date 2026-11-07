# Responsive architecture implementation record

## Baseline / reconciliation
- Isolated branch: `perf/responsive-architecture`, worktree `/private/tmp/scholia-performance`.
- Clean original checkout and fetched origin/main: `92a8e1689b20d30ba6c95cba9b332bece17c12ca`.
- Prior implementation `9d1ac29cb7077e48b5316f6c35ea35aa576f2e22` is absent. No patch/review/APPLY artifacts found in Downloads, programming directories, or accessible temporary files. Reconstruct from current source.
- No open PRs on ravinav1/scholia or configured origin heaps0rt/scholia. Preserve configured remote; publication destination will be explicit.
- MacBook Pro Mac14,6, Apple M2 Max (12 CPU cores), 32 GB, macOS 27.2 (26B123), Node 26.4.0, npm 11.17.0, Swift 6.4.2. Chromium only. Native measurements must identify release configuration.
- Baseline architecture already has reader generations, conditional full-state ETags, material caching, coalesced native library writes, hosted document streaming and extraction workers. Verify rather than duplicate.

## Shared contracts before parallel implementation
- Atomic action: `{ action: 'openReading', id: documentID, courseID?: workspaceID, page?: positiveInteger, conversationPolicy?: 'document' | 'preserve', navigationID?: string }`.
- Default policy `document`: select the most recent conversation for the target document, excluding assignment conversations. `preserve`: keep the currently selected conversation only within the same workspace; used by citations/practice where source reading must not replace the discussion. Validate the complete destination before mutation. Omitted page restores saved position; explicit page clamps to document bounds; malformed page is rejected. Selected draft stays with its thread. Reading history updates once per accepted destination.
- Legacy course/document/page actions remain supported. New clients prefer atomic navigation; responses carry the accepted navigation ID. Client navigation generations reject obsolete results and cancellation does not report an error.
- Revision transport is opt-in via `/api/state?surfaces=1`. Versioned envelope `{ protocol: 1, epoch, revisions, snapshot?, patches? }`; no client merges across epochs. Surface names: catalog, dashboard, reader, conversation, activity, settings. Initially compatibility snapshots remain accepted. A full snapshot is mandatory on missing/conflicting revisions, restart, and reconnect; partial responses must identify their base revisions. Root owns server transport; web owner coordinates integration after schema is finalized.
- Account/session ownership is mandatory for every cache. Native loopback intentionally shares active navigation; hosted sessions remain independent. Hidden dashboard projection retains destination and full draft ownership/attachments but excludes active reader indexes, source excerpts and message bodies.
- Persistence remains SQLite for hosted service; native retains its existing file library unless measurement justifies migration. New hosted actions default to durable persistence; session-only actions use an explicit allowlist. Native draft operations serialize saves/removals and flush on lifecycle boundaries.

## Ownership
- Native agent: apps/macos, scripts/macos, native smoke scripts/tests; no web/server edits.
- Web agent: apps/web and web tests; browser navigation/dashboard benchmark and Chromium regression.
- Extension agent: apps/chrome, extension build/package scripts and extension tests; packaged Chromium verification.
- Root: apps/server, server tests, shared contracts, CI, integration and delivery docs. Agents must send interface changes before crossing ownership.

## Stages
1. Inspection/reconciliation: complete.
2. Baseline capture: underway; raw results in results/performance.
3. Focused fixes: pending.
4. Atomic navigation: contract above, pending.
5. Revisioned state + notifications: pending, conditional fallback required.
6. Targeted persistence + recovery: pending.
7. Narrow native observation / large lists: pending measurement.
8. Uploads, document serving, extension loading: pending.
9. Shared behavior / usability: pending.
10. Integration and checks: pending; never classify unrun as passed.
11. Review, commits, branch/PR or patch delivery: pending.
