# Scholia for macOS

Scholia is a native SwiftUI and AppKit study workspace with PDFKit, local Vision
OCR, Quick Look, a resizable tutor pane, and a menu-bar companion. It requires
macOS 14 or newer. Reading, indexing, navigation, and saved files work without a
web server. Provider requests still require the selected service or local model.

See the [workspace guide](../../docs/STUDY_WORKSPACE.md) for Canvas, assignments,
file views, document editing, and practice.

Press **⌘K**, then choose **Semantic · by meaning** under **Look for** to find
related ideas in English or Norwegian. The local model is downloaded once;
files are prepared incrementally in the background and results open the source
page. Node.js 24 or newer is required. See [search details](../../docs/SEARCH.md).

## Install and update

With Node.js 24 or newer and Apple's developer tools installed, double-click
**[Update Scholia.command](../../Update%20Scholia.command)** in the repository
folder. It installs dependencies, builds the app, installs it in
`/Applications/Scholia.app`, and opens it. The same action handles the first
installation and later updates.

Once installed, choose **Scholia → Update Scholia…** from the application menu
or **Update Scholia…** in its menu-bar panel. A Terminal window shows progress;
the app is force quit when the new build is ready and reopens after installation.
Press Enter at the final prompt to close the updater's Terminal window.

The equivalent command from the repository root is:

```sh
npm run update:macos
```

Updates use the current files in this source folder, including local edits. If
you want changes from GitHub, update your checkout first. Keep the source folder
on your Mac; if you move it, double-click its updater once to reconnect the app.
Chats, documents, settings, and saved credentials survive app replacement.

Local updates use incremental debug compilation and skip the IDE index, so repeat
updates compile only affected Swift files. The first build still prepares the
cache; Terminal prints an elapsed-time message during long compiler steps.
For a fully optimized distribution build, use `npm run update:macos -- --release`
or `npm run build:macos -- release`.

The build packages and signs a temporary app before replacing the copy in `dist`.
The updater force quits each running copy in `dist` and Applications before
replacing its files, including copies blocked by a dialog. Save edits before
updating; force quit does not run the app's normal shutdown saves.

The installer verifies the signature, replaces the Applications copy, verifies
it again, and discards its temporary backup after a successful update. A failed
replacement restores the previous app. Add Scholia to your Dock from Applications
if you want a permanent shortcut.

For development, `npm run build:macos` only produces `dist/macos/Scholia.app`;
`npm run install:macos -- --skip-build --launch` installs that build without
rebuilding. `npm run run:macos` runs from source; packaged builds are needed for
Services and launch at login. Use `npm run update:macos -- --help` for options.

The build automatically uses an installed macOS 26.5 SDK when the macOS 27
Command Line Tools lack `SwiftUIMacros.StateMacro`. Set `SDKROOT` to explicitly
choose another SDK:

```sh
SDKROOT=/path/to/MacOSX.sdk npm run update:macos
```

### Signing and permissions

The build prefers Developer ID Application or Apple Development signing. On a
development Mac without either, it creates a persistent **Scholia Local Code
Signing** identity with a non-exportable private key. A stable designated
requirement lets Accessibility and Screen Recording grants survive later builds.
Public releases still need Developer ID signing and notarization.

An older ad-hoc installation needs a one-time migration:

```sh
npm run install:macos -- --migrate-permissions --launch
```

Grant Accessibility and Screen Recording permissions to the stable-signed copy
once, then use the normal install command for updates.

Keychain approval is separate. For a locally signed app, the macOS file keychain
also identifies the app by its code-directory hash (`cdhash`), which changes when
the app changes. **Always Allow** approves that build for that saved credential;
the same local certificate and designated requirement do not prevent another
Keychain prompt after a rebuild. Apple Development and Developer ID Application
signatures use a stable team identity for this check. The build already prefers
these Apple-issued identities when installed. See
[Apple's Keychain client-identity implementation](https://github.com/apple-oss-distributions/Security/blob/main/securityd/src/clientid.cpp).

To avoid prompts caused by changing local-build fingerprints, install an Apple
Development or Developer ID Application certificate and its private key, then
use that same team for subsequent builds. Switching from the local identity may
require one more approval for each saved credential. Resetting privacy grants
with `--migrate-permissions` does not fix this Keychain behavior.

`SCHOLIA_CODESIGN_IDENTITY` selects a certificate;
`SCHOLIA_AUTO_LOCAL_SIGNING=0` disables automatic local identity creation;
`SCHOLIA_REQUIRE_STABLE_SIGNING=1` rejects ad-hoc builds.

## First launch

1. Open Settings and save the provider connection and credential. Open a model
   picker (or **Browse & test…** in Settings) to search the full catalog and
   **Test** any model. Successful tests show **Verified** and enable selection;
   **Retest** checks access again. Tests use a short text request and do not
   change the active model. Verification applies to the tested endpoint and key.
   Custom model IDs entered in Settings can also be tested with **Test provider**.
2. Open the workspace with Command-1. Import files with Command-O or connect
   Canvas. Finder's Open With and file drops are supported.
3. Grant Accessibility if you want selection explanations or visible-window
   context. Grant Screen Recording for desktop region capture. Reading a
   document and capturing its PDF figure inside Scholia do not need those grants.

Accessibility and Screen Recording prompts open from **Request Access** controls.
macOS may also request folder access when you ask Scholia to find or read a local file.
Settings refreshes status when you return from System Settings. Quick Ask,
clipboard input, and Services remain useful without Accessibility.

## Exam search

The exam schedule and **Manage dates** both have a search field for course code,
course name, exam component, or date. Search filters the displayed exams;
collision checks continue to use the complete selected plan. Filtered bulk
selection applies to matching exams.

**Add exam** opens a searchable picker containing your library courses and the
bundled study-plan catalog. Pick a course to add an editable exam component, or
choose **Add manually**. Existing components are labeled. Dates are left blank
until entered or imported from Studentweb, and changes take effect when you
choose **Save plan**.

## Chat

The course overview fills the available width. Its inline chat grows with the
window (480–780 points before attachments), with a scrolling transcript. Choose
**General** in the conversation mode menu for everyday conversation, brainstorming,
planning, or complete solutions without pedagogical restrictions. Course references
remain available. **Explain** combines explanations with guided help, and
**Practice** keeps its learning focus. The mode is saved with the conversation.

The brain button opens workspace or assignment memory: save notes and pin reference
files to carry them into new chats. Assignments inherit course memory and keep their
own notes and references separate from other assignments.

### Report & fix

Choose **Scholia → Report & fix…** (⌘⇧B), or the bug button in the workspace toolbar.
Describe a problem and save it for later, or choose a Codex model and reasoning effort and launch a repair
agent immediately. The panel captures the current window and diagnostic context;
you can inspect the diagnostics and remove the screenshot before launching.
Reports and results stay in `~/Library/Application Support/Scholia/Repairs`.

The launcher uses the locally installed, signed-in Codex CLI and your selected
Scholia source folder. It edits that checkout with the workspace-write sandbox,
shows progress and the final response, and provides **Stop**. Review the changes,
then use **Build & relaunch** to install the result through Scholia's updater.
The **Effort** picker shows the selected model's supported levels. **Default** uses
your Codex configuration. Effort is saved with each report and remembered between
app launches; switching to a model that does not support the chosen level resets
it to Default. Older reports keep Default.
Saving a note does not start an agent. The repair model and effort choices are independent of
the model used for studying. Closing the report window leaves a running repair
active; quitting Scholia stops it.

### Personalization from ChatGPT and Claude

Open **Settings → Personalization → Connect…**, sign in to the service, then
choose **Sync saved settings**. Each service has its own opt-in toggle and
Scholia browser login. The importer reads rendered custom instructions, profile
preferences, and saved memories, including the older Claude memory panel.
Review the imported text in settings. It is included with the next chat message
sent to whichever AI provider you select, including local providers.

**Refresh automatically** checks every 15 minutes while the Mac app is running;
**Refresh now** checks immediately. This is polling, not an instant remote change
notification. Refresh uses temporary WebKit views which are released afterwards;
no browser is retained between checks. Turning a source off excludes it from
subsequent requests. **Forget…** removes its local snapshot and Scholia login.
Nothing is changed on ChatGPT or Claude.

This is a settings-page integration, not a provider API: a signed-in session and
recognizable rendered controls are required. Site redesigns, localized labels,
login challenges, unavailable memory panels, filtered lists, and oversized
sections can prevent a refresh. The UI reports missing sections and retains their
last good copy. A successfully read section replaces its prior value, including
explicitly emptied fields/lists, so deleted preferences do not accumulate. Limits
are 8,000 characters each for instructions/profile and 24,000 for memories.
No conversation history or authentication tokens are imported. The snapshot
is stored separately from course libraries in a local file readable only by
the current user. This feature belongs to the Mac app; hosted accounts do not
receive its saved personalization.

The source controls are documented in [ChatGPT personalization](https://learn.chatgpt.com/docs/personalize)
and [Claude memory import/export](https://support.claude.com/en/articles/12123587-import-and-export-your-memory-from-claude).

## Files in chat

Drop files from Finder or Spotlight anywhere in the study chat sidebar, or use
the paperclip. The native composers also accept file promises from apps such as
Mail. Any file type can be attached, and a project folder becomes a bounded
inventory with the readable contents of its files. Up to 24 attachments can be
added per question. Drafts and sent attachments survive reopening a conversation.

Supported extraction includes PDF/OCR, images, Unicode text and source code,
Office documents, notebooks, RTF, ZIP-based projects, and Simulink `.slx`/`.mdl`.
Simulink attachments expose saved blocks, connections, parameters, and embedded
readable sources; they do not run MATLAB or resolve external workspace variables.
Binary/protected files, audio/video, and unreadable files remain visible with a
reading limitation and a request for a usable export when their contents matter.

The native study sidebar's **Document context** switch names the open document and keeps the current page and selection
as an anchor and searches the full indexed document for relevant passages, including
distant pages. Local questions stay compact; follow-up questions retain the previous
topic, and overview requests sample across the document. **Whole document · all text**
explicitly sends all extracted text when it fits, with unreadable pages disclosed.
New document chats default to that document. **Also use course library and memory**
adds saved course references separately; course chat and assignment chat retain their
own context. If a course conversation is open beside a PDF, **Use open document for
this question** carries the visible draft and attachments into a document conversation
without replacing an existing draft. PDF selection actions and search results bind to
the open document. **Inspect** shows the pages actually supplied for the last answer,
source names, attachment read status, saved-text previews, and an include checkbox
for each file. It also controls searches of other course files. Explicit attachments
and selected passages remain available when saved-source context is off; previous
conversation text is retained.
The tutor is instructed to ask a focused question when project-specific evidence
is missing or ambiguous, rather than assume values or invent results.

Attachment rows identify files and folders separately and show their original path.
The information button (or a sent attachment chip) shows the exact source, stable
attachment ID, saved file manifest, and actual omissions. Re-read a draft attachment
with its refresh button to recover text omitted by older versions or update its
snapshot. Failed or cancelled refreshes keep the saved evidence and draft intact.
Simulink static structure is distinguished from simulation state that was never evaluated.

Reading pages and specific questions about long attachments use cached text retrieval
with exact identifiers and BM25 ranking. The request identifies selected ranges and omissions,
keeps project manifests and small setup scripts, and leaves saved attachments
unchanged. Full extracted text is stored separately from the conversation preview;
large overview requests use distributed passages, and attachment-scoped read/search
operations can request additional saved ranges. Those operations work with local-file
access off and cannot read unrelated files. This does not start an embedding model.
Distinct model files retain their own identity even when their basenames match.

Give Quick Chat or the workspace tutor a path such as `~/Documents/notes.pdf`,
or ask for an approximate location: “Find my lecture 3 notes in Downloads.”
Scholia searches filenames and folder paths, then reads relevant files for your
question. It supports PDF, Office documents, UTF-8 text/code, and images when the
selected model supports them. Searches are bounded; if a search is incomplete,
specify a narrower folder. Hidden files, app bundles, and dependency/build trees
are skipped during broad searches. You can supply their exact paths.

PDF file reads and attachments accept files up to 1 GB. When you give a local PDF
path, the assistant can read only the pages your question needs, such as the
opening pages or a chapter located from the table of contents. Reads extract text
and run OCR only on those pages, returning up to 24,000 characters at a time
(5 pages by default, or up to 20 for an explicit range), with page numbers and
continuation details. Excerpts are marked as partial. Attachments retain their full
readable extraction in a local content-addressed store; the 200,000-character inline
preview is not an extraction cutoff. PDF extraction visits every page; project
extraction continues through files and OCRs contained images. Real resource guards
(50 million extracted UTF-16 units, bounded archive expansion and traversal) and
unsupported binary/visual content remain explicitly reported. ZIP/Simulink local reads
can also page through a specific archive member without unpacking or executing it.

**Settings → Privacy → Local files** has two controls:

- **Allow file access** enables lookup and reading, and is on by default.
- **Allow write access** enables creating folders and creating/editing text and
  code files. It is off by default. Existing files must be read completely before
  replacement; a file changed since that read is not overwritten. Turning either
  control off blocks subsequent operations in an answer already running.

File contents read for a question go to the selected model. macOS folder privacy
permissions still apply; Settings includes a link to **Full Disk Access** for
protected locations. Automatic classification, practice generation, and model
connection tests do not receive these file tools. The Mac's local browser
workspace shares its chat permissions. Hosted websites and the Chrome extension
do not gain access to your Mac's filesystem from this setting.

## Companion shortcuts

| Shortcut              | Action                                      |
| --------------------- | ------------------------------------------- |
| Command-1             | Open study workspace                        |
| Command-2             | Start and open the optional local website   |
| Command-[ / Command-] | Back / Forward in the workspace             |
| Command-Shift-Space   | Open temporary Quick Ask / Quick Chat       |
| Command-Shift-E       | Explain the current selection               |
| Command-Shift-S       | Capture a screen region                     |
| Command-Shift-P       | Toggle Selection Explain for the active app |

Global shortcuts can be changed in Settings. Selection Explain and region
capture have independent per-app switches, so either shortcut can be handed to
the Chrome extension. The menu-bar icon reflects the selection switch.

Quick Chat starts with a compact prompt and expands for attachments or a temporary conversation. Return sends;
Shift-Return adds a line. Paste or attach files for context; each file shows what
Scholia could read.
You can draft the next question while an answer streams; send it after the answer
finishes, or stop the response first. Typing also works while a workspace sheet is open.
**Move to saved chat** preserves the thread. Select part of an answer to open a
nested explanation, then use Back to return. Editing a sent question regenerates
the conversation from that point.

Every chat uses the shared rich renderer, including streamed answers: programming
and LaTeX code fences have language labels, syntax highlighting and **Copy code**;
math delimiters render equations. Unknown languages remain readable literal code.
The model picker groups verified models first for each provider, followed by
approximate capacity tiers and newest versions within a family.
Model test progress occupies a fixed footer, and rows keep their positions while
the picker is open. Newly verified models move to the top the next time it opens.

Expand **Activity** on an answer to see actual source reads, attachment preparation,
request progress and provider-reported searches or tool results. Assignment file
preparation appears in its chat before you ask a question. Activity is retained
with saved conversations; it does not grant additional computer or file access.

With Codex selected, the composer shows the lowest remaining allowance beside
the reasoning control. Click it for each limit window, reset times, and refresh.
The account figures come from [Codex rate limits](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt),
refresh while chat is active and after responses, and explicitly become unavailable
or outdated when they cannot be checked. Each completed answer shows elapsed
time and measured tokens, with input, cached input, output, and model-request
details. These survive reopening saved chats. Cached tokens are part of input;
token counts are not converted into subscription percentages or prices.

In study chat, PDF citations such as `[p. 79]` and `[pp. 77–81]` jump to the
answer's saved source (ranges open at the first page). Known filenames, attachment
paths and IDs, and archive members are clickable; archive members open their
saved extraction. Ambiguous references remain plain text. Independent source
reads and searches can run in batches of up to eight per model round trip,
preserving access checks, source identities, and explicit reading limits without
changing the selected model or reasoning effort.

Quick Chat and saved chats offer **Compact**, **Full**, and **None** automatic
context. When enabled, sending a question reads bounded visible-window text via
Accessibility and ranks it locally. It does not continuously monitor windows.
None retains explicit selections and attachments while omitting surrounding
window context. Mail selection can draft a reply in Scholia; it never sends it
through the mail client.

Closing the workspace leaves the menu-bar companion running. Launch with
`--background` to start only the companion. Open Scholia windows share one Dock
identity; the Dock icon remains until quit after a window has been opened.

## Providers and local data

Provider keys and Canvas tokens use Keychain. Preferences use `UserDefaults`;
workspace documents and conversations use Application Support. See
[Privacy](../../docs/PRIVACY.md) for retention and capture details.

Hosted providers require HTTPS. Loopback HTTP is allowed for local providers.
The native app starts its bundled Codex or Claude Code bridge when selected,
reuses a healthy existing bridge, and stops only processes it owns. Node.js and
the chosen CLI must be installed. Ollama and opencode keep their own lifecycle.
GPT NTNU requires its personal API key and an NTNU network or VPN connection.

**Open in Browser** starts a loopback server on `127.0.0.1:8792` for this Mac's
workspace. The browser receives no raw provider or Canvas secrets. It requires
the app to remain running. The [hosted web service](../../docs/HOSTING.md) is a
separate deployment with separate account storage.

## Verification

**Study on Paper (⌘3)** provides native iPhone Continuity Camera capture and a
temporary visual tutoring session. Use the packaged app for camera permission
testing. Setup, provider requirements, sampling, retention, and physical-device
checks are documented in [Study on Paper](../../docs/PAPER_STUDY.md).

```sh
npm run check
npm run smoke:macos:paper
npm run smoke:macos:paper:ui
# Makes real model requests using an existing Codex sign-in:
npm run smoke:macos:paper:live
npm run smoke:macos:course-ui
npm run smoke:macos:workspace -- --data-only
npm run smoke:macos:workspace -- --learning-only
npm run smoke:macos:workspace -- --assignments-preview --assignment-page-smoke
zsh scripts/smoke-macos-panels.sh
```

Smoke scripts accept `SDKROOT`. They link actual application code against
isolated libraries and deterministic fixtures. The panel check exercises
content changes and resizing without provider requests. Browser verification
uses Chromium. With full Xcode installed, `swift test --package-path apps/macos`
also runs the Swift package tests.
