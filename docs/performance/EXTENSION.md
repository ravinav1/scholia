# Extension loading and verification

Implemented on the isolated performance branch, from baseline `92a8e1689b20d30ba6c95cba9b332bece17c12ca`. No installed extension, user profile, or external provider was used.

## Architecture

`content.js` installs one per-frame bootstrap. It detects selection, math interaction, keyboard shortcuts, document replacement, and extension runtime messages. It creates no rich interface on idle pages. `content-bootstrap.js` shares the initialization promise across simultaneous triggers, copies the original selection range/text before asynchronous work, rejects queued commands after a PDF replacement, and resets failed imports with a fresh extension-owned retry URL.

- `content-ui.js` owns the existing closed-shadow explanation UI, attachment composer, provider controls, Markdown, math, and code rendering. Initial commands wait for settings, including a newer settings refresh arriving during initialization. The UI and its listeners mount once.
- `content-context.js` handles page/tab/site/research and deep-page requests without loading or mounting the rich interface. It retains the original site policy checks and bounded context extraction. Its site cache is bounded to four entries.
- Only the two named lazy modules are added to web-accessible resources. There is no wildcard JavaScript exposure or remote code. Browser credentials remain in the service worker. Existing extension-owned PDF pages use the same bootstrap; automatic content-script injection still covers nested and origin-inherited frames.
- A failed import reports a retryable error and does not mount a partial interface. User retries share one new import. Keyboard Quick Chat remains available before rich loading.

## Measurements

MacBook Pro Mac14,6, Apple M2 Max, 12 CPU cores, 32 GB; macOS 27.2 (26B123); Node 26.4.0; Chromium 153.0.7999.0. Both builds are minified production bundles. Browser fixtures use a temporary profile, one top-level page plus two nested frames, a restrictive `script-src 'none'` page CSP, and a deterministic local streamed provider. One warmup followed by ten navigations; each sample waits a fixed 150 ms after document completion before reading Chromium performance counters. These are extension page-load observations, not Scholia dashboard input-to-paint measurements. Other implementation checks ran on this Mac, so timings are diagnostic rather than CI limits.

| Measurement | Before | After lazy loading | After web removal |
|---|---:|---:|---:|
| Initial content script | 1,653,863 B | 4,108 B | 4,108 B |
| Initial gzip bytes | 495,157 B | 1,942 B | 1,942 B |
| Initial module graph | 252 modules | 4 modules | 4 modules |
| Rich module, loaded on use | included above | 1,638,841 B | 1,638,841 B |
| Context-only module | included above | 42,385 B | 42,385 B |
| Idle rich hosts across three frames | 3 | 0 | 0 |
| Page load end p50 / p95 | 45.8 / 59.2 ms | 24.0 / 26.2 ms | 23.7 / 28.6 ms |
| Main-thread task duration p50 / p95 | 46.3 / 56.1 ms | 15.0 / 19.2 ms | 14.8 / 18.2 ms |
| First answer observed by CDP, one sample | 137.1 ms | 171.3 ms | 179.8 ms |

Initial JavaScript bytes decrease 99.75%. First-use latency includes import, rendering and CDP observation overhead; the single answer observation is not a latency percentile. Rich rendering remains a substantial deferred dependency. The extra module increases total distribution bytes slightly through duplicated capture helpers; no total-size reduction is claimed. Raw heap/node counters are retained in the runtime JSON, but no forced GC was performed, so they do not establish retained-memory or leak improvements.

Raw results: `results/performance/extension-bundle-{before,after,after-removal}.json` and `extension-runtime-{before,after,after-removal}.json`. Both after runtimes use the ZIP extracted into a fresh temporary directory. The baseline came from the unmodified minified distribution before the split. The original before/after measurements are preserved separately from final product-scope verification.

## Verification

- 241 extension tests passed after lazy loading; all 239 retained extension tests passed after web removal (`node --test tests/chrome/*.test.js`). Only the two tests of the removed website launcher were deleted. New behavioral cases cover concurrent initialization, provider readiness, captured selection, import retry, independent context routing, resource boundaries, and cancellation after document replacement.
- `npm run package:chrome` passed, including `check:dist`. Distribution checks enforce a 16 KiB initial-script budget, named module availability, provider completeness in the deferred UI, and absence of remote/dynamic executable code.
- Real Chromium packaged-ZIP check passed: no idle host in top-level or nested frames, context requests leave UI unloaded, first answer uses actual persisted provider configuration, nested-frame provider transport, a deliberately blocked module download, successful concurrent retry, exactly one mounted interface, and zero uncaught runtime exceptions.
- Existing Chromium interaction regression passed: Quick Chat shortcut, recursive explanations, contained model picker, bridge recovery, in-reader PDF chat, PDF selection/page restoration/print/search/navigation, and chat handoff. Its existing simulated frame-blocking case still runs in Chromium; no Brave browser was launched. Eager-host readiness waits were replaced with actual selection/message triggers while retaining the interaction assertions.

## Reproduction and rollback

```sh
npm run package:chrome
node scripts/performance/measure-extension-bundle.mjs --after-removal
node scripts/performance/benchmark-extension.mjs --packaged --after-removal
node --test tests/chrome/*.test.js
node scripts/smoke/browser/smoke-chromium-panel-recursion.mjs
```

For a baseline, build `92a8e16` in a separate checkout, then run the benchmark scripts from this change against that checkout with `--baseline` (copy the scripts and their existing Chromium helper or set up an equivalent checkout-relative invocation). Reports overwrite their stage-specific filenames; copy an existing report before another run when retaining multiple trials. Override `CHROMIUM_BIN` with a Chromium binary on other supported systems. `SCHOLIA_BENCHMARK_SAMPLES` changes sample count. Tests create isolated storage/profiles and clean them up. No extension storage schema changed; rollback requires rebuilding/loading the previous package. Replacing or reloading an installed extension remains a user action.

## Final product scope

The user subsequently removed the web application from scope and requested only
the native app and extension. The extension's website-address settings, popup
exam-planner launcher, and their launch-only module/tests were removed. Browser
tab context ranking is retained: it reads ordinary browser tabs, independently
of the removed application. Canvas link tests now call the existing shared DOM
helper directly and preserve all their assertions. The final packaged Chromium
check also opens actual extension settings and popup pages, verifies that provider
controls still initialize, and checks that removed website launch controls are absent.

Final verification is recorded in `results/performance/extension-verification-after-removal.json`:

| Check | Final result |
|---|---|
| Extension unit and behavioral tests | 239 passed, zero failures/skips |
| Production build, package and distribution checks | Passed |
| Packaged Chromium CSP, lazy context, first answer, nested frames | Passed |
| Failed module download and simultaneous retry | Passed, exactly one interface mounted |
| Packaged options and popup | Provider controls initialize; chat/PDF controls remain; website controls absent |
| Existing Chromium recursion, shortcut, bridge and PDF interactions | Passed |
| Extension source, tests, build scripts and shipped JS/HTML | No web/server imports, website launch controls or workspace URLs |
| Uncaught packaged Chromium exceptions | Zero |

The generic `browser-workspace-context.js` remains part of the service worker:
it ranks ordinary browser tabs and has no dependency on either removed application.

## Codex model selection regression

The follow-up report that GPT-6.1 Sol / Extra High could not be selected exposed
two reproducible stale-catalog paths. A saved live catalog can narrow the built-in
model's reasoning choices. The popup never requested a fresh catalog, while
Settings ignored the storage update produced by asynchronous bridge discovery.
With an expired cached entry containing only `low` and `high`, both packaged
surfaces failed to show `xhigh` even though the fixture bridge advertised it.

The popup now checks bridge catalogs when it opens or its model picker opens.
The service worker's existing two-minute cache and in-flight discovery sharing
bound those requests. Settings updates model capabilities when discovery arrives
without replacing unsaved model, credential or language edits. It no longer
re-renders the whole form using the older health reply. GPT-6.1 Sol is also
included in the bridge's offline fallback catalog.

The actual packaged Chromium regression starts with another selected model and
stale GPT-6.1 Sol capabilities, selects GPT-6.1 Sol during discovery, chooses
Extra High, and verifies persistence after reload in popup, sidebar and Settings.
It then submits from the real popup through the real service worker to a local
fixture and asserts `model: "gpt-6.1-sol"` and `reasoning_effort: "xhigh"`.
Repeated picker opens reuse the catalog cache; failed discovery preserves the
last working models, chosen effort and credentials. Zero browser exceptions
occurred. No real Codex inference or installed browser profile was used.

```sh
npm run package:chrome
node scripts/smoke/browser/smoke-codex-model-selection.mjs
node --test tests/chrome/*.test.js tests/core/*.test.js tests/tooling/codex*.test.js
```

All 372 targeted JavaScript tests passed, including a real bridge subprocess
driven by a fake Codex executable. That test verifies offline catalog availability
and that the bridge passes GPT-6.1 Sol / `xhigh` to the CLI unchanged. Before/after
results and package identity are retained in
`results/performance/codex-model-selection-verification.json`.
