# Native and extension performance review

## Scope and reconciliation

Baseline: `92a8e1689b20d30ba6c95cba9b332bece17c12ca`. The supplied prior implementation commit was not present, and the earlier patch, review, application instructions, and hosted benchmark attachments were unavailable in the inspected locations. This branch reconstructs the relevant fixes from the baseline. The original checkout is preserved; implementation and tests use an isolated worktree and synthetic temporary data.

The user subsequently requested removal of the web application. This delivery keeps the native macOS app and Chrome extension. The hosted service, browser workspace, native loopback server, website launch settings, and their deployment/build paths are removed. Native document helpers remain bundled JavaScriptCore resources; native semantic search remains a local worker. No deployment, account migration, installed-app replacement, or cross-device synchronization is performed.

## Confirmed causes

- The native dashboard eagerly laid out large assignment collections. The original 89-workspace component benchmark took approximately five seconds to return to the dashboard. The 500-workspace fixture exceeded the warm-sample time budget after its first paint.
- Workspace filtering repeatedly normalized and sorted metadata. Broad workspace observation also tied dashboard work to unrelated reader and conversation changes.
- Document draft recovery and encoding performed UI-thread work. Navigation composed several mutations, allowing asynchronous index loads or downloaded materials to outlive their destination.
- Frequent native library saves serialize the complete JSON snapshot, including unrelated materials and conversations. Moving the writer off the main thread avoids a direct UI block but does not reduce serialization or disk work.
- Every extension content script initially loaded rich rendering dependencies and mounted UI, including idle nested frames. The initial script was 1,653,863 bytes across 252 modules.
- A stale saved Codex model catalog can hide Extra High for GPT-6.1 Sol. Opening the extension popup did not refresh model discovery, even when the local bridge advertised that capability.

## Measurement boundaries

Service work, rendered component timings, and complete application interaction are separate evidence. The comparable native baseline measures the production dashboard in an AppKit-hosted component, with a simplified reader. Its timing ends after layout and `displayIfNeeded`; it excludes compositor scanout and does not establish full application input-to-paint latency. The extension reports page-load and main-thread counters, not native dashboard timing.

The proposed p95 targets remain 50 ms for warm workspace filtering and 150 ms for warm reader-to-dashboard useful paint. Report actual sample counts and whether the fixture budget completed. Do not infer UI latency from a faster store or search operation. Absolute timings are diagnostic; CI asserts behavior and bounded work.

Hardware and raw native baseline are recorded in [IMPLEMENTATION.md](IMPLEMENTATION.md) and `results/performance/native-before.json`. Extension before/after methods, raw reports, and limitations are in [EXTENSION.md](EXTENSION.md). Native UI methods and measurements are in [NATIVE.md](NATIVE.md); migration, work counts, and storage measurements are in [NATIVE_STORAGE.md](NATIVE_STORAGE.md).

## Requirements mapped to the retained products

| Requested area | Retained implementation / verification boundary |
|---|---|
| Release native builds | Ordinary build/install defaults are release; debug is explicit. Native measurements use release objects. |
| Workspace search and previews | Prepared metadata with invalidation, current-library contents, bounded assignment preview with totals and filtered full view, top-k recent readings. |
| Draft lifecycle | Off-main ordered draft writer, coalescing, tombstones, recovery ownership, retry and independent errors. |
| Atomic navigation | One validated reading operation for search, recents, citations and practice; load tickets and revision checks reject obsolete results. |
| Smaller revisioned surfaces | Native dashboard has narrower display observation. Hosted conditional snapshots, polling and SSE are removed with their product. Native uses in-process observation rather than a replacement HTTP state protocol. |
| Persistence granularity | Native navigation, documents, catalogs, threads and messages use targeted transactional SQLite rows. Crash/restart, migration, ordering, conflict and exact payload-row tests pass. Hosted SQLite migration work is superseded by product removal. |
| Large lists | Bounded dashboard assignment preview and paged complete assignment views; existing lazy material/search lists retain stable identities. |
| Uploads / document HTTP serving | Hosted uploads and native loopback document responses no longer ship. Native imports and Canvas downloads continue through their existing bounded, cancelable local paths. |
| Extension startup | Four-module bootstrap; lazy rich UI and independent context module; shared initialization, captured selection, retry, nested frames and CSP tested in packaged Chromium. |
| Shared behavior | Native and extension retain separate libraries. Provider capabilities, prompts and reference rules remain shared where meaningful. Removed hosted navigation/revision contracts are no longer compatibility surfaces. |
| Delivery | Source commits, raw results, migration/rollback instructions, supported-platform CI, and an explicit passed/failed/unrun matrix. No merge or deployment. |

## Verification record

See [IMPLEMENTATION.md](IMPLEMENTATION.md) for the current stage record. Final integration results and exact barriers are consolidated in [DELIVERY.md](DELIVERY.md). A successful asset build or syntax parse is never reported as a native or browser runtime pass.

## Confirmed storage and extension results

The native 89-workspace fixture with a 20 MB image payload changed from 94.918 ms median for reproduced full-JSON saving to 0.450 ms for targeted saving. The 500-workspace fixture changed from 127.967 ms to 1.375 ms. A reading-position update encodes a 181–182-byte document payload and updates one payload row plus the transaction revision; these are encoded bytes and logical rows, not physical disk/WAL bytes. Migration and multi-row transactions survived actual child-process termination in isolated copied fixtures.

The extension's initial script is 4,108 bytes across four modules, down from 1,653,863 bytes and 252 modules. In the documented Mac series, page-load p95 fell from 59.2 ms to 28.6 ms. First use still loads the rich UI: the single first-answer observation increased from 137.1 ms to 179.8 ms, so no first-answer speedup is claimed. Packaged Chromium verifies CSP, nested frames, provider initialization, blocked-load retry and concurrent initialization. A reproduced stale Codex catalog now refreshes without discarding unsaved settings, and GPT-6.1 Sol/xhigh selection survives reload and reaches transport correctly.

## Remaining cost and intentional boundaries

- Full native startup still reconstructs the complete library. SQLite reduces frequent write work; it does not make initial decoding or one-time migration constant-time.
- Native dashboard return still creates SwiftUI/AppKit view/layout work. Full-workspace return p95 is 202/245 ms at 89/500 workspaces (six samples, no excluded warmup), above 150 ms. Component return is 109.6/125.0 ms (30 samples, three warmups); that narrower result does not establish a full-window target pass. Warm component filtering is 24.5/47.1 ms p95, below 50 ms.
- Large changed message/draft rows still encode their own contents. Native captured-chat history is a separate coalesced store; the normalized SQLite change covers the study workspace library.
- Rich Markdown, math and code rendering remain deferred extension dependencies. Total package size and first-use latency are not reduced by the same percentage as the bootstrap.
- Full-Xcode CI executes the 300-case suite: 298 pass, one opt-in case skips, and accurate OCR fails on that runner. A direct Vision probe independently reproduces the error, including CPU-only accurate recognition; the physical Mac passes all probe modes and real production OCR. See [VISION_CI.md](VISION_CI.md).
- Quick Jump keyboard behavior passed, but the separate percentile benchmark was blocked before warmup by a locked desktop. Its runnable harness and exact barrier are recorded in [NATIVE_QUICK_JUMP.md](NATIVE_QUICK_JUMP.md).
- Resident memory samples and heartbeat delays are diagnostic observations, not proof of zero retained objects or compositor frame timing. No absolute timing gate is imposed on shared CI runners.
- The removed web/hosted product has no new HTTP uploads, ranges, polling, SSE or account-migration surface. Its removal is the reason those original stages do not ship; native imports/downloads and extension transports remain supported and separately tested.
