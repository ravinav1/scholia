# Paper study verification

Verified on 15 October 2026 on the development Mac. The requested implementation
is present in the native app. The initial verification used handwriting fixtures
because an iPhone was unavailable. During the follow-up, the user connected an
iPhone successfully and the native app showed live notebook frames. The first
physical tutoring attempt exposed an overly strict stability gate; its follow-up
fixes and additional results are recorded below. A complete sustained-device
check remains distinct from the initial model and fixture checks.

## Software checks

| Check | Result |
| --- | --- |
| Signed native application build | Passed; camera usage descriptions, Continuity opt-in and camera entitlement included |
| `npm run check` | Passed: JavaScript/source checks and Swift parsing; 582 tests passed, 2 skipped, 0 failed |
| Native paper test suites | Latest run passed all 58 tests, including crop privacy, all-angle preview geometry, source-format review, image quality, camera drift/tiny edits, before/after context, background completion during writing, question priority, routing/cancellation, stale rejection, cue spacing/dedup, interruptions, clear/close, page changes, error recovery and timeout |
| Native UI verification | Original injected-frame smoke passed in light/dark and minimum-window layouts. Updated harness compiles and links; current controls were tested directly with native UI automation, including model modes, Mac camera, rotated crop selection, local crop inspection, and quit. The updated scripted UI harness was not executed. |
| Actual handwritten input through image pipeline | Human digital-pen strokes rasterized from MathWriting; readable/revised/incomplete/crossed-out examples pass, faint/unclear example blocked, unchanged frame skipped and revisions detected |
| Real model transport | Native `PaperTutor` → `ProviderClient` → authenticated Codex bridge; existing sign-in worked; saved model settings unchanged |

Native tests use the same `Paper*Tests.swift` test bodies through a small native
assertion runner because this Command Line Tools installation does not include
XCTest. Full-Xcode users can run the XCTest suites directly. Slow/failing/cancelled
providers are deterministic fixtures, including an intentionally uncancellable
completion to check that stale work cannot appear after a revision.

The original UI fixture checks use synthetic mathematical strokes and injected frames, not an
emulated claim of iPhone capture. No browser was needed for the native feature;
no Brave process was launched. Existing browser checks remain Chromium-only.

An additional context regression check confirms that an image-only initial
problem survives a confirmed new page. It is labeled as a historical problem
reference, so its superseded working is not presented as current. Other earlier
working pages are excluded; at most three images still reach the model.

## Real handwriting and real-model results

Handwriting comes from Google's [MathWriting research dataset](https://github.com/google-research/google-research/blob/master/mathwriting/README.md).
The [dataset format](https://github.com/google-research/google-research/blob/master/mathwriting/archive_readme.md)
distinguishes human digital-pen strokes from synthetic expressions. The tests
rasterize the **human** samples, retaining original notation and spatial layout.
The original sample IDs, archive SHA-256, source URL and CC BY-NC-SA 4.0 license
are written to `output/paper-study/handwriting-provenance.json`. These are
noncommercial local validation assets, excluded from application bundles and
ignored by Git.

The staged session asks about the inverse of `f(x) = x²`, `x ≥ 0`, first showing
a handwritten reciprocal confusion and later a handwritten square-root inverse.
Different writers' examples are staged as revisions. Partial strokes, masking,
blur and strike-through are explicitly simulated transformations; they are not
photos of erasing, hands, or one student's continuous work.

| Scenario | GPT-6 Astra / low | GPT-6 Luna / low |
| --- | --- | --- |
| New visible inverse/reciprocal error: short focused proactive hint | Passed | Failed: classified as incomplete |
| Contextual question about prior hint | Passed | Passed |
| Revised correct inverse with a different variable | Passed | Failed: remained quiet but classified correct work as incomplete |
| Valid polynomial with terms in a different order | Passed | Failed: misread a coefficient and classified as incomplete; did accept term order |
| Incomplete handwriting: no premature correction | Passed | Passed |
| Simulated obstruction: no mathematical error claim | Passed | Passed |
| Unclear notation: clarification | Passed | Passed |
| New problem/page: do not combine contexts | Passed | Failed: did not mark the page transition |
| Explicit full-solution request | Passed | Passed |
| Crossed-out old expression, active correct expression | Passed (additional targeted run) | Not run |
| Image-only problem retained across confirmed pages | Passed (final-build targeted run) | Not run |
| Follow-up recovers the domain from the first-page image | Passed (final-build targeted run) | Not run |

Astra passed **12/12** checks across the nine-case baseline, targeted
strikeout check and two final-build cross-page checks. Luna passed **5/9**. These small, inspected scenario checks are
not a handwriting accuracy benchmark or a guarantee for unfamiliar subjects.
The pass predicates and raw outputs are available in the live runner/artifacts.

The Astra baseline took **4.85–12.10 seconds**, median **7.81 s**, mean **7.85 s**.
The additional strikeout check took **7.19 s**. Luna's baseline median was
**4.52 s**, range **3.52–5.94 s**. The faster model's missed error and misread
notation make speed alone an unsuitable default criterion. The original baseline
used Astra/low; the new session modes use verified models from the active provider
without changing the model saved in Settings. The baseline live runner still
defaults to Astra.

The final cross-page checks took **6.78 s** and **7.96 s**. They used an empty
typed problem, a clearly attributed synthetic printed problem header above
human handwriting on page 1, and human square-root work on page 2. The model
accepted the confirmed page transition without correcting superseded work,
then recovered the original nonnegative domain from the earlier image to
answer why the inverse uses the positive square root. This verifies visual
problem continuity without restating it in the typed follow-up.

One Astra response correctly asked whether taking a reciprocal undoes squaring,
and the follow-up used the input/output relationship without immediately
revealing the whole solution. Revised and crossed-out work produced quiet `ok`
observations. Explicit solution mode returned the square-root inverse, its
domain/range and a composition check. No API keys had to be added: the existing
Codex login supported this test. Other providers remain transport-compatible
but were not live-tested for this feature.

The bridge does not expose reliable per-request billing/token usage to this
transport. Monetary cost is **unmeasured**, not zero. Simple fixtures sent an
average of **26,136 encoded JPEG bytes per request** across one to three images;
full notebook pages may be much larger and provider image billing is not based
solely on compressed file size.

## Follow-up: physical cameras and adaptive tutoring

The user connected an iPhone through Continuity Camera and the installed native
app displayed real notebook video. A requested check read the handwritten lines
`1 + 1 + x = 2y`, `2 + x = 2y`, and the intentional error `x = 2y + 2`. It asked:
“Which operation should you apply to both sides to cancel the +2 on the left?”
The first check took **27.4 seconds**. A second manual check again identified
the incorrect line and gave a minimal question. Camera movement caused the
answer to remain attached to its earlier capture, rather than labeling it as
current work. These were **manual requests**, not a successful physical automatic
intervention. A selected-historical-step real-model regression also passed in
**6.53 seconds**, discussing superseded work without claiming the mistake remained.

The **Use Mac camera** shortcut connected the real FaceTime HD Camera and showed
live frames. The preview and local cropped thumbnail were inspected with AI
paused; those camera frames were not sent to the model. Stop camera released the
preview. The iPhone later disconnected; the app paused analysis and preserved
the previous conversation with reconnection instructions.

The user's report of drifting/flipping prompted a further framing fix. The app
now fixes capture orientation, disables supported Center Stage during capture,
prefers a normal camera over virtual Desk View, and offers explicit clockwise
rotation/reset. A physical Mac-camera retest caught a mismatch between AppKit
coordinates and AVFoundation's rotated metadata rectangles. The final preview
uses native layer geometry and an explicit invertible crop transform. **0°, 90°,
180°, and 270°** preserved the selected subject in the preview; a full-size 90°
crop matched its outline, and a newly dragged 270° selection captured the exact
selected region. The size-quality gate was also made rotation invariant, so a
readable landscape crop does not become too small merely by turning it upright;
both orientations are covered by the passing native tests. Rotation pauses analysis.
Normal application quit with an active
Mac camera completed successfully. Center Stage's saved setting is restored on
stop or normal quit if the app's override is still active.

The iPhone was unavailable by this final retest. Its original drift/lens symptom
and Center Stage restoration still require a physical iPhone check; the cause
cannot be identified conclusively from the description. A sustained automatic
handwriting session on that device also remains unverified. The Mac framing
check establishes preview/crop behavior, not iPhone optical stability.

Automatic checking initially struggled to settle because exposure noise and tiny
camera shifts were classified as new writing. Numeric-only diagnostics from the
real camera showed a representative raw mean difference of 0.02709 dropping to
0.00574 after alignment, with strong changed pixels falling from 1299 to 0.
The revised comparator compensates for small exposure drift and translations,
then checks for locally added or removed ink. Deterministic exposure ±8 levels,
noise ±3, and quarter/half/one/two-pixel drift pass without false revisions;
isolated single-pixel signs at 25 positions, a small minus, and a plus-to-minus
erasure still trigger changes. Broad motion and substantial lighting changes
remain changes. Temporary diagnostic logging was removed from the source.
This is measured calibration and deterministic validation, not proof that every
camera movement or small handwritten edit will be recognized correctly. The
registered comparison measured roughly 45–55 ms in an isolated debug run; up to
three comparisons can run during a local observation. Sustained responsiveness
under device motion and heavier Mac workloads remains a field check.

The real session router was then exercised with human handwriting and the
authenticated Codex transport, without manual `captureNow()` calls. The test
injects a stationary fixture into local observation; it is not a physical-camera
run. All three routing/control expectations passed:

| Mode | Route | First run / replay | Observed result |
| --- | --- | --- | --- |
| Automatic | Luna/low → Astra/low | 11.14 / 16.50 s | Luna called the error incomplete; independent Astra review identified the mistake and produced one minimal cue |
| Fast | Luna/low | 3.63 / 9.32 s | One fast call, but missed this error as incomplete; routing passed, tutoring accuracy failed on this example |
| Thorough | Astra/low | 6.73 / 7.20 s | One stronger call identified the error and produced one minimal cue |

The Automatic first-stage output was withheld. Its stronger review saw the same
original evidence without the first model's verdict. Saved stage responses and
timings for the latest replay are in `output/paper-study/live-routing.json`.
The replay included the additional final-response freshness guard. All three
routes passed again, with latency varying under concurrent system work.
Two-stage review can take
longer than choosing Thorough directly, and a confidently incorrect `ok` from
the fast model can still evade escalation. The modes expose that tradeoff.

The final signed build is installed at `/Applications/Scholia.app`; its executable
was checked against `dist/macos/Scholia.app`. The final native rerun passed all
47 tests. The repository check passed 582 tests with 2 skips and no failures.

## Continuous observation and Continuity orientation follow-up

The user reproduced rotation while lowering an upright iPhone toward the notebook.
The live preview turned sideways, and the local cropped pixels also contained the
rotation while Scholia's angle remained zero. Read-only device inspection found
the normal iPhone source at 1920×1080 with Center Stage and Portrait inactive;
Desk View was a separate 1920×1440 source. No second capture session was started.
Apple's [Continuity Camera presentation](https://developer.apple.com/videos/play/wwdc2022/10018/)
documents orientation-dependent field of view. This is consistent with source-side
rotation; it is not evidence that the app can lock that behavior.

SDK and live capability inspection found no public macOS upstream orientation,
physical-lens, or zoom lock for this Continuity device. The app now exposes Apple's
video-effects controls, explains the limitation, and gates analysis on explicit
crop review if source pixel dimensions change. This dimension gate does **not**
claim to fix rotation or zoom rendered inside an unchanged 1920×1080 frame.
The manual app rotation and native crop mapping remain unchanged.

Continuous checking now separates the 5-second minimum check interval from
30-second cue spacing. BEFORE evidence is the last successfully checked state,
not a transient or cancelled image. A pending cue can be delivered when its
interval expires only while its page/revision remains current and readable;
revision, pause, crop change and source-geometry change invalidate it. Existing
single-request and stale-response guards remain in force. When writing continues
during a check, that snapshot can finish as historical context; it cannot emit a
current correction. The next settled view is compared with that checked state.
Explicit student questions take priority over automatic background checks.

The first real-model progression run used actual human-ink fixture images through the
native session router, with a controlled clock and synthetic motion fingerprints
(not a physical-camera simulation). It passed unfinished → mistake → correction
in **11.43 s / 12.46 s / 4.81 s**. Automatic used two calls for the unfinished
reading, two for the suspected error, then one for the accepted correction.
The minimal error cue was: “An inverse function undoes $f$. Does taking the
reciprocal undo squaring?” The corrected and unchanged states produced no cue;
an additional unchanged observation period produced no model request.
The final rerun additionally supplied newer writing while the first real request
was in flight. It passed all three states again in **10.89 s / 9.83 s / 8.97 s**,
using two model calls for each state. The first result became historical context
without a cue; the newer mistake produced one hint, and the correction stayed
quiet. No unchanged-frame polling followed. Latest results are in
`output/paper-study/live-continuous.json`.

Final packaging and signature verification passed; the installed executable
matches the built application. All **58 native tests** passed and the native UI
harness compiled and linked. Actual UI checks confirmed the 5-second/30-second
controls, current camera status, successful iPhone reconnect, and new framing
guidance. The Camera effects button invoked Apple's API, but the system panel is
outside the captured app window and was not visually verified. The iPhone view
was dark/covered after the update and subsequently disconnected; refreshing then
showed only the Mac camera. Analysis paused and the session remained available.
A new physical automatic handwriting cue has not yet been verified.
Earlier physical manual-model checks and the optical
rotation reproduction are documented separately above.

## Local responsiveness and initial settings

The exact crop/JPEG/quality/Vision pipeline on the 1200×500 human-ink inverse
fixture measured **100.1 ms median**, **94.4–133.7 ms** over ten warm runs, with
**577.8 ms** cold initialization. This fits the 500 ms local inspection budget;
AVFoundation discards late output frames. During concurrent work, varied fixtures
measured 128–494 ms, so device/system load matters.

A synthetic 1080p sparse-stroke test measured 32–36 ms warm and 167–998 ms cold.
The 256×192 fingerprint caught an 8×18-pixel added stroke in all 25 tested
alignments, where whole-page mean differences alone missed it. Deterministic
low-amplitude noise and one-pixel shifts did not trigger the localized rule.
The follow-up comparison calibration above addresses measured sensor drift;
autofocus, glare and broader paper movement still need sustained device testing.

Earlier builds used 15-second/60-second, then 10-second/30-second check/cue
intervals and additional latency backpressure. The continuous-check follow-up
uses **5 seconds between eligible checks / 30 seconds between cues**. One request
in flight supplies latency backpressure; cue spacing no longer prevents checking
revised work. The theoretical limit is 12 logical checks/minute, each potentially
using two models, with actual throughput reduced by inference, stability and
quality gates. Unchanged or unreadable work sends no request. Monetary cost
remains unmeasured.

This is not continuous video inference or instantaneous teacher-level perception.
Automatic cues still require current, readable evidence. An earlier snapshot can
finish while writing continues and become comparison context without showing a
stale cue. A stable readable view is still needed for a current cue. Manual
contextual questions remain available while writing continues.

A gray-rectangle occlusion passed local quality/hand detection because it was
sharp and not a hand. It did invalidate the previous frame, and the real model
identified the obstruction and stayed quiet. **Arbitrary obstruction is not
fully detectable locally.** Vision hand detection was exercised, but recognition
of real hands remains a physical check.

## Remaining physical-device checklist

Use the signed build with a real notebook and iPhone, recording model, lighting,
mounting distance, crop size, latency and any missed/repeated intervention:

- First camera permission prompt; deny, open Settings, allow and reconnect.
- Wireless Continuity discovery and trusted USB connection; select the intended
  rear camera rather than the Mac's webcam or Desk View.
- Verify the dragged region matches the uploaded crop under letterboxing,
  rotations, camera switching and resizing. Confirm small signs, exponents,
  fractions, matrices and diagrams remain readable.
- With an iPhone, confirm the fixed view does not drift when the device tilts or
  moves closer; check normal camera versus Desk View, and verify Center Stage's
  prior setting is restored after Stop, window close, and normal Quit.
- Write a problem over multiple minutes; ask a contextual follow-up, revise a
  single sign, erase/cross out a line, turn pages, and continue without restating
  the problem. Check that late answers remain attached only to earlier evidence.
- Put a hand over the work, cast shadows, blur the page, and change lighting.
  Check recovery, battery/thermal load and acceptable false-positive discard rate.
- Test iPhone Pause/Disconnect, unlocking, incoming call, unplugging USB,
  wireless range loss and camera ownership by another app. The UI should pause
  analysis and offer reconnection while keeping the current discussion.
- Stop camera, close the paper window, and Clear session. Confirm the system
  camera indicator turns off and the next session has no retained content.

## Reproduce and inspect

```sh
npm run check
npm run smoke:macos:paper
npm run smoke:macos:paper:ui
# Compile/link the UI harness without launching its scripted UI run:
SCHOLIA_PAPER_SKIP_BUILD=1 zsh scripts/smoke-macos-paper-ui.sh --compile-only
# Real inference; requires the existing Codex login and may consume usage:
npm run smoke:macos:paper:live
# Optional targeted replay/comparison:
PAPER_LIVE_MODEL=gpt-6-astra PAPER_LIVE_CASE=crossed-out-revision \
  zsh scripts/smoke-macos-paper-live.sh --skip-build
# Exercises all three real-model routes through automatic session observation:
PAPER_LIVE_CASE=routing zsh scripts/smoke-macos-paper-live.sh --skip-build
```

Generated artifacts are under `output/paper-study/`: the Astra/Luna JSON reports,
raw model JSON, handwriting provenance and JPEGs, optical pipeline/timing reports,
and native setup/session/evidence screenshots. The live scripts regenerate their
fixtures and reports. The one-off optical calibration JSON describes the
measurements above; deterministic quality/crop checks remain in the test suite.
