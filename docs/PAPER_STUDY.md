# Study on Paper

Scholia's native Mac app can watch a selected notebook region through an iPhone
Continuity Camera, the Mac's built-in camera, or a USB webcam, keep a temporary visual conversation,
and offer requested or proactive tutoring. Open **Study on Paper** from the
Scholia menu, the workspace's **Paper** button, or **⌘3**.

This first version is native macOS only. It uses the existing provider settings
and vision transport, with a model mode for this session. It does not require a phone app, manual photo uploads, a browser,
or a new server. The browser workspace and Chrome extension have not gained
camera capture.

## Install and connect

1. Run `npm run build:macos` to build the signed application in
   `dist/macos/Scholia.app`. Open that application, or use `npm run install:macos`
   to install it. Use the packaged app for camera testing: its Info.plist and
   signing entitlement are required for macOS camera authorization.
2. In Scholia Settings, choose and verify an image-capable provider/model.
   Existing API credentials or an authenticated local Codex bridge are reused;
   no credentials are entered in the paper window. Text-only models fail with
   a visible error. Local file tools are disabled for paper requests.
3. For the MacBook camera, choose **Use Mac camera** or select **FaceTime HD Camera · This Mac**
   in the camera picker. Face the notebook toward the camera above the screen,
   then select its region in the preview. The preview is deliberately unmirrored
   so mathematical notation reads correctly. No iPhone is needed for this path.
4. For iPhone, use a Mac running macOS 14 or newer (Scholia's minimum), an iPhone XR or newer
   with iOS 16 or newer, and the same Apple Account with two-factor
   authentication. Enable iPhone **Settings → General → AirPlay & Continuity →
   Continuity Camera**. Keep Bluetooth and Wi-Fi enabled and devices nearby.
5. Mount the locked iPhone securely above the paper. Landscape orientation can
   help discovery. A USB cable and trusting the Mac can improve reliability.
   Scholia turns off Center Stage during paper capture. Turn off Portrait and
   other background effects in the Mac's video-effects controls if they blur the notebook.
   The normal rear-camera view is preferable to relying on Desk View's altered
   perspective for small mathematical notation.
6. Choose **Use iPhone**, or choose the iPhone in the camera picker and press **Connect**. Grant Scholia
   camera permission. A blocked permission has a button opening **System
   Settings → Privacy & Security → Camera**. Refresh the list if necessary.
7. Drag over the live preview to choose the notebook region. Inspect the exact
   local crop at full pixel size before sending it; check minus signs,
   superscripts, fractions and strike-throughs. Good lighting, a stable mount,
   and a tighter region matter more than frame rate.
8. Enter the problem or include it in the first crop. **Auto-check as I write**
   is selected initially, with analysis paused. Press **Start auto-check** after
   checking the region to enable automatic checking. Alternatively choose
   **Only when I ask**. Use **Capture & ask for a hint**, **Small hint**, or type
   a question for deliberate help. **More help** builds on the previous hint;
   **Full solution** explicitly requests a complete worked explanation.

Apple documents AVFoundation Continuity Camera support directly:
[Supporting Continuity Camera in your macOS app](https://developer.apple.com/documentation/avfoundation/supporting-continuity-camera-in-your-macos-app).
Scholia discovers `.continuityCamera` devices and declares
`NSCameraUsageDescription`, `NSCameraUseContinuityCameraDeviceType`, and the
[hardened-runtime camera entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.camera).
Apple's [setup and troubleshooting requirements](https://support.apple.com/en-us/102546)
include restrictions on hotspot/internet sharing and simultaneous wireless
AirPlay/Sidecar use. Unlocking the iPhone pauses Continuity Camera; Scholia cannot
override that system behavior. Lock and mount it again, then reconnect. If you
tap **Disconnect** on the iPhone, plug it into the Mac and refresh cameras to
make it available again. Calls and the iPhone's Pause control can also interrupt capture.

The built-in Mac camera and USB webcams work while the phone is unlocked.
Using the iPhone itself unlocked would require a separate phone capture app or
streaming transport, which this version does not implement.
Browser `getUserMedia` would add browser
and origin permissions and depend on device enumeration; it is feasible but
unnecessary for the chosen native interface. A separate iPhone streaming app
would require pairing, networking and another privacy boundary, so it is not
part of this version.

## Camera framing and rotation

Use the normal **iPhone** camera for paper. **Desk View** is a separate virtual
camera with an altered perspective; Scholia labels it separately. Keep the
phone mounted parallel to the page rather than changing its tilt to straighten
the preview.

Scholia disables [Center Stage](https://developer.apple.com/documentation/avfoundation/avcapturedevice/centerstagecontrolmode)
while a supported camera is capturing paper, preventing its automatic people
framing from panning or zooming the notebook. When capture stops, Scholia restores
the previous Center Stage mode and enablement only if its own settings are still
applied; it does not overwrite a later change. Normal application quit waits for
that restoration; a crash or force quit cannot guarantee it. Portrait and other
system video effects remain under the user's control.

Use **Rotate 90°** to turn the notebook clockwise or **Reset rotation** to return
to the native view. Rotation pauses analysis; inspect the crop and resume
checks when it is upright. The selection remains the same part of the notebook.
The data-output connection stays unmirrored at zero rotation; the preview uses
the chosen fixed angle. Preview coordinates map back to the native sensor
region, which is cropped first and then rotated for the model and local crop
preview. Nothing outside the selected region is added by rotating it.

Scholia applies no automatic horizon leveling, perspective/trapezoid correction,
or 3D display transform. **Continuity itself can rotate and reframe the source as
the phone turns.** Apple documents that its portrait field of view is narrower
than landscape in [Bring Continuity Camera to your macOS app](https://developer.apple.com/videos/play/wwdc2022/10018/).
The physical retest showed sideways writing in both the live preview and captured
pixels while the app's manual angle remained zero. Center Stage was inactive.
No public macOS API was found that locks Continuity's upstream orientation or
physical lens. A native iPhone capture sender would be required for direct control;
this version does not implement one. The Mac camera and a standard USB webcam
avoid this particular Continuity behavior.

Mount the iPhone in landscape before lowering it over the notebook, keep its
orientation stable, and use the app's manual rotation if needed. **Camera effects…**
opens Apple's controls for checking system framing/effects. If the delivered
pixel dimensions change, Scholia pauses analysis and requires a crop review while
the preview stays live. This guard cannot detect orientation or zoom changes
already rendered inside an unchanged 1920×1080 source.

### Direct iPhone source alternative (not yet device-verified)

A direct phone-camera sender bypasses Continuity's orientation behavior. One
candidate is **Camo Camera on iPhone + Camo Studio on Mac**, connected directly
over USB. Use the phone app as the source, not Camo's optional Continuity input.
Its [setup guide](https://camo.com/support/camo/camo-getting-started) describes the
direct USB connection, and its [FAQ](https://camo.com/support/camo/camo-faq) describes
iOS orientation lock together with manual rotation. Turn off automatic framing,
set the angle once, then refresh Scholia's camera list and select Camo's output.
Retest flat → lift → tilt before treating the rotation issue as fixed.

This requires installing separate camera software on both devices; it is not
installed or required by Scholia. The [free edition](https://camo.com/support/camo/camo-overview)
includes framing controls; 1080p and higher require Pro. Start with a tight,
readable crop in the free edition before considering any purchase.

A custom Scholia iPhone sender would use a fixed capture angle and physical lens,
then a paired encrypted connection into the existing Mac crop/tutor pipeline.
It is not implemented. This development Mac currently has Command Line Tools
only, without full Xcode/iOS SDK or Apple development provisioning, so it cannot
build, install, or physically verify that companion yet.

## Controls and behavior

- **Pause auto-check** cancels pending analysis and stops automatic retention/model requests;
  the local camera preview stays active. Manual capture/questions remain
  deliberate requests. **Stop camera** releases the camera, cancels pending
  analysis and preserves existing session evidence for historical follow-ups.
- **Only when I ask** makes no automatic model requests. **Keep steps locally**
  retains changed, readable steps for later questions; **Pause local observation**
  stops that retention while keeping the preview available.
- **Auto-check as I write** only shows a new, high-confidence mistake with an identifiable
  expression and issue key. Correct, unfinished and obstructed work stays quiet.
  Ambiguous writing prompts clarification when the student asks. A repeated
  issue is suppressed for that page even if its location changes. Connecting
  the camera alone does not start automatic model requests.
- Responses link to the exact crop, page and revision that produced them. Old
  captures are labeled as earlier work. An explicit question freezes a readable
  capture immediately, without waiting for pixel-perfect stillness. You can keep
  writing while it is answered; if the view changes, the reply concerns the
  earlier capture and does not become current feedback. Automatic checks also
  finish reading their snapshot while you write. If that snapshot is no longer
  current, only its interpreted working is retained for the next comparison;
  its feedback is not shown as a cue.
- **Discuss this step** selects a retained capture for the next question, hint
  or correction. The selected step stays visible above the composer; its discussion
  can continue while the live page changes or the camera is interrupted.
  **Use live page** returns questions to current work. **Capture & ask for a hint**
  also returns to the live page. A new page needs a fresh capture before a live
  question can use it; previous-page evidence requires explicit selection.
- Editing the problem, correcting a symbol, changing the region, pausing,
  stopping the camera or pressing **Cancel** cancels the pending question.
  A cancelled or failed explicit question remains available as **Retry with
  current page**; retry is deliberate and uses the latest readable work.
  Dismiss removes that saved question. Clear and Close remove it with the session.
  Cancelled late transport responses cannot become current feedback.
- **Correct a symbol or explain my approach** records the student's interpretation
  alongside the images. Crossed-out work, valid alternatives and unfinished
  lines are distinguished in the tutor's instructions. Model confidence is not
  treated as a measure of the student's ability.
- A substantial visual change or model-detected page transition asks for
  **New page** / **Still the same page**. New page retains the discussion and
  problem, retaining the initial crop as an explicitly historical problem
  reference while excluding other previous-page working images. Use it
  explicitly when turning to a similar-looking sheet; visual detection is
  heuristic.
- One request can be pending at a time. An explicit question or hint takes
  priority over a background automatic check; another explicit question waits
  until the pending question finishes or is cancelled. Cancel is available. Requests time out
  after two minutes. Provider/network/schema errors pause automatic analysis
  with no automatic retry; use the saved question or start auto-check again
  after fixing the problem.

## Model modes

The **Automatic**, **Fast**, and **Thorough** picker controls which model reads a
capture. It is separate from **Start auto-check**, which controls when automatic
requests may be sent. Changing model mode affects this paper session; it does
not change the model selected in Scholia Settings.

- **Automatic** starts with a fast model and requests an independent stronger
  review of the same images when the first response suggests a mistake, unclear
  notation, incomplete work, a page change, low confidence, invalid output, or
  leaves an explicit student question unanswered.
  The first model's proposed correction is withheld until review finishes.
  Incomplete work is reviewed even at high reported confidence because the
  handwriting evaluation found confident missed errors. A complete-solution or
  proof request goes directly to the stronger model. An obstructed image does
  not trigger an extra call; the writing must become visible.
- **Fast** uses one fast model, accepting a greater risk of misreading or missing
  mistakes. **Thorough** uses one stronger model for every request.
- Routes use the active provider's verified, image-capable model catalog.
  With the verified Codex pair, the preferred routes are Luna and Astra.
  A missing route falls back to the stronger available or selected model and
  reports that choice. Verify additional models in Settings to make them
  eligible. Credentials and the provider endpoint stay the same throughout a
  two-stage request.

The routing status identifies the model and explains stronger review. Automatic
uses at most two model calls per logical request; the window counts checks,
model calls, and total check latency separately. Cancellation and freshness
checks cover both stages. A failed provider call is not automatically retried.
Routing reduces unnecessary stronger-model calls but cannot guarantee that a
confident fast-model judgment is correct.

## Sampling, latency and usage

The preview is an AVFoundation video preview, independent of AI sampling. It
negotiates the camera's video format (preferring 1920×1080), not a model stream.
Local cropped frames are inspected at most twice per second on a serial
background queue. Only cropped JPEGs, maximum 1920 pixels on the long edge at
quality 0.85, are eligible for model requests.

Local checks reject small, dark, faint/blurred or apparently hand-covered crops.
Vision hand detection and image statistics are heuristics; the student still
checks legibility and the model must state uncertainty. Automatic observation
requires frames to settle for 1.5 seconds after the first unchanged comparison
(roughly two seconds total). Explicit capture skips the settling delay while
retaining the image-quality and hand checks; selected historical discussion
uses its retained image and does not require a clear live camera view.
A 256×192 luminance fingerprint detects both broad changes and small, strong
local changes such as a sign or exponent. Comparison against retained/requested
frames catches accumulated edits rather than only adjacent-frame differences.

Defaults are a **5-second minimum interval between changed-work checks** and
**30 seconds between visible cues**. The intervals are independent: quiet cue
spacing does not stop the tutor from checking a revision. Local observation
continues at 2 Hz, sends only readable settled changes, and keeps at most one
request in flight. Model latency therefore limits throughput without adding an
extra waiting period after completion. There is no queue of old frames. The
unchanged-page path sends no requests.

Continuous local observation does not mean instant model feedback. A background
check finishes reading its captured snapshot while the student keeps writing or
briefly covers the page. If that snapshot is no longer current, a readable result
is retained as interpreted history for the next comparison, without displaying
its feedback or marking an old error as current. The next settled, readable
view is checked against that history; intermediate frames are not queued.
Current cues still depend on a clear view and model response time. An explicit
question can interrupt a background check and return an answer tied to its own
snapshot while writing continues.

Each automatic check compares the current crop with the last successfully checked
state and assesses added, revised, erased, or crossed-out work. Cancelled requests
and transient motion do not become the comparison baseline. Correct and unfinished
work stays quiet. A warranted cue held by the notification interval is delivered
only while the same evidence remains current and readable; a revision discards it.

At default settings continuous changed work can produce at most **12 logical
checks per minute**, with up to three images each; actual usage is
usually lower because of stability, change and quality gates. Manual requests
add to this. Automatic model routing can make two calls for one request, up to
24 automatic model calls per minute at these defaults, each with the
same bounded evidence. The window displays check count, model calls,
and last check latency. These are usage
indicators, not billing estimates: model image/token pricing and bridge plans
vary, and this transport does not expose reliable token cost for every provider.

Synthetic local pipeline calibration on this Mac measured warm 1080p crop,
JPEG and Vision processing at approximately **32–36 ms** per inspected frame;
first-use Vision initialization measured **167–998 ms**. A sparse synthetic
frame encoded to about 46 KB. A small added 8×18-pixel stroke was detected at
25/25 tested grid alignments at 256×192; deterministic ±3-level pixel noise and
one-pixel translations did not trigger the localized change rule. These are
synthetic measurements, not claims about optical performance on an iPhone.
The conservative thresholds can still discard useful responses under lighting
changes or camera movement, and cannot guarantee detection of every tiny edit.

On the actual human-ink 1200×500 fixture, the exact pipeline including Vision
measured 100.1 ms median (94.4–133.7 ms across ten warm runs), with 577.8 ms cold
initialization. This fits the 500 ms inspection interval; first-use work can
skip an interval. The verified Astra/low model's median response was 7.81 seconds.
These measurements support a local 2 Hz inspection rate. Continuous observation
now uses a 5-second minimum check interval with one request in flight, so the
measured total latency naturally slows checks when two models are needed. The
30-second cue interval controls interruptions separately. See the verification report
for the faster model's accuracy failures and cost limitations.

## Privacy and retention

The video stays on the Mac. A model request sends the current selected crop
(or an explicitly selected historical capture),
up to two relevant earlier crops (initial problem and previous revision), bounded
transcriptions, problem text, recent questions/answers and student corrections.
Images remain available alongside transcriptions; OCR text never replaces them.
No audio is requested and no video is recorded.

The paper session has **no Scholia disk persistence or chat-history save**.
It retains at most 24 crops and approximately 20 MB of encoded image data,
60 discussion turns and 80 trail events in memory. Older visual evidence is
pruned and the interface identifies unavailable crops. Provider context is
smaller: up to three images, bounded earlier step summaries, recent discussion
and corrections. This is a bounded working context, not an unlimited memory.

**Clear session** stops the camera and removes the problem, crops, corrections,
conversation and trail. Closing the window does the same and releases its view
and draft state. The existing model provider's retention policy still applies;
clearing Scholia cannot delete already processed remote requests. Local CLI
bridges may materialize images temporarily while a request runs and remove them
on completion/cancellation. This is disclosed in the interface and is distinct
from saving a session in Scholia's library.

## Verification

Run:

```sh
npm run check
zsh scripts/smoke-macos-paper.sh
SCHOLIA_PAPER_SKIP_BUILD=1 zsh scripts/smoke-macos-paper-ui.sh
zsh scripts/smoke-macos-paper-live.sh --skip-build
```

The last command makes real model requests and requires a working Codex sign-in
(or the explicitly configured test endpoint described in its script). It does
not change saved Scholia provider settings. Human handwriting fixtures are
downloaded into `output/paper-study`; their source and noncommercial/share-alike
license are recorded with the artifacts. They are validation data, not bundled
product assets. UI fixtures are synthetic and labeled separately.

`smoke-macos-paper.sh` executes the actual four `Paper*Tests.swift` suites in a
native assertion runner on Command Line Tools installations without XCTest.
With full Xcode, the same test bodies can run using `swift test --package-path
apps/macos --filter Paper` with a compatible SDK. The tests cover image-only
crop bounds, quality gates, visual/prompt context, strict response parsing,
request-only behavior, slow/late requests, timeout, cancellation, revision and
page changes, deduplication, corrections, errors/recovery and memory clearing.
Routing tests cover verified catalog fallbacks, escalation decisions, independent
review, call limits, and cancellation before and during the stronger review.

See [verification results](PAPER_STUDY_VERIFICATION.md) for measured live-model
outcomes and the remaining device checklist.
