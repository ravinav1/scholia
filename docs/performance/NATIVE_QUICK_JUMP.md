# Native Quick Jump measurement

This reproducible after-only harness measures the production Quick Jump sheet inside the production `StudyWorkspaceView` and window controller. **Percentile collection is unrun because the desktop was locked.** It has no baseline latency series and supports no before/after speedup claim. Application source remains `c4492b5`; the standalone harness links optimized release objects with test visibility enabled.

The unchanged application rebuilt successfully in release with test visibility in **105.26 seconds**, using Swift 6.4.2 and the macOS 26.5 SDK on the Apple M2 Max / 32 GB / macOS 27.2 test Mac. The harness compiled and launched. Its initial focus assertion failed before any warmup or measurement: AppKit reported the window visible, but the process inactive and the window not key; a read-only `ioreg` check confirmed `CGSSessionScreenIsLocked = Yes`. The assertion was preserved, the desktop was not unlocked, and no unfocused-window timings were substituted. `results/performance/native-quick-jump-after.json` records this exact barrier with empty results, not zero-valued latency percentiles.

Earlier native course-UI behavior checks passed while the desktop was available, including Quick Jump rapid queries, temporary no-match results, arrow keys, Enter/Escape, workspace selection, and draft preservation. Those checks establish behavior, not the missing latency percentiles.

## Boundary and fixture

The measurement is configured to use a visible 1280 × 900 AppKit workspace with a light appearance. Each library contains 89 or 500 workspaces, 20 document metadata records and 70 Canvas material references per workspace (12 assignments, 58 files), plus 50 saved conversation messages in each of the two destination workspaces. Document contents are not opened by this course-switching task. All libraries, draft writes and reloads use disposable temporary directories. No AppDelegate, provider request, import or sync workload runs. The production environment object reads existing app preferences and saved conversation metadata, but this harness does not save global preferences/history, start app services, or launch the installed app. A URLProtocol guard rejects requests and checks for zero attempted network requests in a completed run.

Each fixture is configured for 33 iterations, discarding the first three as warmups. Every measured iteration:

1. Dispatches the actual Command-Shift-K shortcut and waits for the production sheet's visible, focused native search field.
2. Replaces text through the field's `NSTextView` editor with five adjacent-turn queries: `T`, `TEST4`, `zz-no-match`, `TEST4`, and the exact destination course code. There are no deliberate pauses between those edits. The broad prefixes match the fixture's large workspace list.
3. Checks the accessibility tree for the expected final result, then dispatches an actual Enter key event. It waits for the native sheet to finish closing, the parent window to regain key status, the correct workspace to be selected, and AppKit layout/display to complete. It verifies the destination's saved draft was restored.

Opening and selection include the native sheet lifecycle and readiness polling at 5 ms intervals. Per-edit typing and five-edit-burst measurements end after a main-actor yield, layout and `displayIfNeeded`. These timings exclude compositor scanout, physical keyboard delivery and human inter-key delays. They are not raw model-filter microbenchmarks. The final-result accessibility assertion occurs outside the typing timing. Each fixture has 30 opening/selection/burst samples and 150 individual query-edit samples. CPU and resident memory span the measured iteration workload; the 10 ms heartbeat samples are taken between iterations.

## Reproduction

On the same quiet Mac with an **unlocked, visible desktop**:

```sh
SCHOLIA_BUILD_ID=c4492b5 zsh scripts/macos/run-release-check.sh \
  scripts/performance/benchmark-native-quick-jump.swift \
  results/performance/native-quick-jump-after.json
```

Use `--skip-build` after `run-release-check.sh` only if current release objects were built with test visibility. A normal packaged build does not guarantee that setting. Do not run other builds, benchmarks, or interact with the measurement window during timing collection. The script neither installs nor launches Scholia.app.
