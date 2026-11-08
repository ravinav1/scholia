# Native fresh-process startup

`benchmark-native-startup.swift` adds process-launch evidence to the component
and full-workspace measurements described in [NATIVE.md](NATIVE.md). It links the
production optimized release objects from app-source commit `c4492b5` through the
existing standalone release runner. It does not launch the installed application.

The parent creates isolated SQLite libraries before any measured launch. Each
fixture has 20 document records and 70 material records per workspace, including
12 assignments, plus 200 conversation messages in the first workspace. It starts
five fresh child processes per size, without a warmup or discarded sample. The
OS filesystem cache remains warm, including from fixture creation and earlier
processes; “fresh process” does not mean a cold filesystem or reboot.

Timing starts at the parent's `ProcessInfo.systemUptime` sample immediately
before `Process.run`. The child loads the isolated library and constructs the
production `StudyWindowController(AppModel.shared, workspace: ..., autosave:
false)`. It orders the real window front, waits for visibility, yields the main
actor, lays out its content, and calls `displayIfNeeded`. The timestamp immediately
after that call ends the measurement. Each sample verifies that the production
dashboard's workspace search field exists in the visible window.

This boundary includes process/runtime startup, library decoding, model setup,
and the production window's first AppKit display. It excludes compositor scanout
and application services/AppDelegate startup outside that window. `AppModel.shared`
reads existing preferences and saved conversation metadata for UI configuration;
the harness does not start application services or save global settings.
Classification is canceled, the Canvas factory fails locally, and HTTP(S) requests
are blocked. All 15 samples recorded zero network attempts. No import or provider
inference runs during these measurements.

## Observed results

The same Apple M2 Max / 32 GB / macOS 27.2 machine and release toolchain described
in the main native report were used. Measurement collection ran separately from
other benchmarks and builds.

| Workspaces | Fresh processes | Launch to useful AppKit display p50 | p95 | Resident memory at display |
|---:|---:|---:|---:|---:|
| 6 | 5 | 414 ms | 431 ms | 139 MB |
| 89 | 5 | 495 ms | 500 ms | 153–157 MB |
| 500 | 5 | 968 ms | 976 ms | 228–233 MB |

With only five samples, the nearest-rank p95 is the largest observed sample;
it is not a robust estimate of the population tail. Memory is each fresh child
process's resident size at the display boundary, expressed in decimal MB.
No pre-change fresh-process series was collected, so this table does not establish
a startup improvement relative to the baseline.

Raw data in `results/performance/native-startup-after.json` includes all launch
durations, distinct child PIDs, parent launch and child entry/model/display uptime
timestamps, visible-control checks, and resident memory. All 15 phase sequences
were checked for monotonic ordering and all 15 child PIDs were distinct.

## Reproduction

Build the release objects first, then reserve a quiet measurement window:

```sh
npm run build:native-resources
SCHOLIA_BUILD_ID="$(git rev-parse HEAD)" zsh scripts/macos/run-release-check.sh \
  scripts/performance/benchmark-native-startup.swift results/performance/native-startup-after.json
```

When the current release objects already exist with testing enabled, use
`--skip-build` before the Swift source path. Fixture creation and helper linking
remain outside the measured launch intervals. The helper and every temporary
library are removed after the run; no installed app or existing library is replaced.
