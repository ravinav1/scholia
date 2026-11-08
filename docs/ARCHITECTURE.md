# Architecture

Scholia has two runtimes: a native macOS app and a Chrome extension. Their
libraries are separate and do not synchronize.

## Repository map

| Path              | Responsibility                                                                        |
| ----------------- | ------------------------------------------------------------------------------------- |
| `apps/macos`      | SwiftUI/AppKit application, native document readers, local library, Canvas, providers |
| `apps/chrome`     | Extension capture, PDF reader, side panel, settings, service worker                   |
| `packages/core`   | Shared JavaScript prompts, provider contracts, context ranking, tutoring rules        |
| `packages/search` | Local semantic embedding, indexing, and worker runtime for native search              |
| `scripts`         | Build, packaging, local bridges, and integration checks                               |
| `tests`           | JavaScript unit and service integration tests                                         |

The normalized explanation request is defined in
`packages/core/schemas/explain-request.schema.json`. Swift implements the same
prompt and provider concepts with native types. Captured sources are delimited
as reference material, separately from user instructions and credentials.

## Native macOS

SwiftUI supplies navigation and controls. AppKit owns window behavior,
resizable reader/tutor panes, text rendering, and platform integration. PDFKit
reads PDFs, Vision performs local OCR, and Quick Look presents original layouts
when a semantic reader cannot preserve them. WebKit is used for Canvas sign-in,
not as the application's UI runtime.

`StudyWorkspaceModel` owns courses, documents, navigation, threads, and drafts.
`StudyDocumentImporter` copies originals into the library and builds bounded indexes.
PDF text and OCR, Office extraction, notebook parsing, and image processing use
local frameworks and background work. Notebook cells, macros, and formulas are
never executed. Document passage ranking uses a bundled JavaScriptCore helper.
Optional semantic library search uses a local embedding model in the Node worker
under `packages/search`; it makes no provider request.

`npm run build:native-resources` builds the JavaScriptCore search/highlighting
helpers and copies public study-plan data into `dist/native-resources`. The Mac
build packages these files under `Contents/Resources/NativeResources`.

Library snapshots are written through a serial utility queue that coalesces
pending saves; lifecycle boundaries flush the latest state. Back/Forward records
reading destinations and saves drafts before navigation. An AppKit split view
lets the tutor occupy almost the full document window without replacing the
reader or reloading the PDF.

Saved capture conversations use a separate coalescing utility writer, with
clears ordered behind outstanding writes and a durability barrier at app exit.
Resizing native answers reflows their existing attributed text and adjusts math
attachments without reparsing Markdown. Equation images are shared across pane
widths in a cost-limited cache. Dismantling a PDF reader releases its document and
interaction callbacks immediately.

PDF parsing runs on a serial background actor. Document tickets discard stale
loads after navigation, while same-document conversations retain their index
and OCR work. A bounded LRU cache shares decoded text indexes across reading,
practice, and context retrieval; file identity, size, and modification time
invalidate edited or replaced indexes. Reading-position changes leave material
groupings intact.

Canvas catalogs metadata before downloading content. Materials have stable
source identities, optional module positions, remote versions, and saved
references. Refresh reconciles additions, changes, and removals while preserving
conversations, local edits, and incomplete collections. Downloads stream in
bounded chunks with cancellation. API requests refuse redirects; file requests
can follow signed HTTPS storage links after removing Canvas credentials.

Frequently visited courses can preload a small number of files while idle. The
policy waits until three visits and three seconds of idle time, selects at most
three files, limits each to 10 MB and the batch to 20 MB, and yields to active
work, Low Power Mode, and thermal pressure. Users can disable it. This does not
start a bulk course download.

Provider secrets use Keychain; preferences use `UserDefaults`. Library files,
indexes, reading history, edit revisions, and conversations live under
`~/Library/Application Support/Scholia/Study`. Structured practice uses a
separate SQLite event store with stable event IDs, version checks, source
snapshots, and transactional review scheduling. See [Practice](PRACTICE.md).

Desktop selection and region capture are separate from workspace reading:
Accessibility reads bounded visible text on demand and rejects secure fields;
region capture crops and resizes only an explicitly selected area. Quick Chat
remains in memory until promoted to a saved conversation. Local CLI bridges are
started only when needed and stopped only if Scholia owns their process.

## Native paper study

`PaperStudyWindowController` owns a separate temporary session. `PaperCamera`
uses AVFoundation Continuity/external camera discovery, a local preview, and a
serial capture queue. Only selected, resized crops reach `PaperStudySession`,
at most twice per second; quality and hand checks run locally. Session revision
and request generations reject stale answers, with one pending request and
latency-aware spacing. `PaperTutor` builds bounded multimodal context and
validates structured observations through the existing `ProviderClient`, using
a dedicated tutoring purpose. Paper sessions do not write `StudyLibrary` or
`ConversationStore`; closing or clearing stops capture and releases the session.
See [paper study](PAPER_STUDY.md) for controls and provider retention boundaries.

## Chrome extension

The content script runs in an isolated world and never receives provider keys.
It captures text, accessible mathematics, sanitized page structure, or an
explicitly chosen image. Its page serializer omits executable content, event
handlers, live form values, and Scholia's controls. Longer sources are ranked
locally into bounded context. **Complete page** and **Entire site** are explicit
options, with bounded traversal and capture.

The service worker owns settings, credentials, provider transport, tab capture,
commands, and messaging. Only extension-owned pages can request secret settings.
Provider requests stream through a long-lived port with cancellation and
protocol-specific parsing. Hosted endpoint traffic requires HTTPS; HTTP is
accepted only for local loopback providers.

The toolbar popup, side panel, full-tab chat, PDF reader, and explanation layers
reuse the same rendering and provider contracts. A saved chat retains its fixed
source context; switching tabs does not replace it. Selected passages are scoped
to their originating tab. Recursive explanations retain bounded parent context,
and Back returns to the unchanged parent conversation. Editing a user message
replaces the later conversation branch.

PDF.js, workers, decoders, fonts, and character maps are bundled. Visible pages
are rendered before background indexing; rendering and semantic indexes are
bounded and yield to interaction. Persisted PDF indexes use a document
fingerprint. Local file handles remain revocable, and provider context strips
private URL query data. Canvas indexes are scoped by host, account, and course.

Browser answers use bundled Markdown, syntax highlighting, and KaTeX with raw
HTML disabled, unsafe link schemes rejected, and remote answer images blocked.
Native answers use cmark-gfm and a single selectable AppKit text view with local
math rendering. Returned provider reasoning, when available, stays in a
separate collapsed disclosure. Neither runtime loads remote executable code.

## Verification

`npm run check` runs JavaScript tests, source validation, and Swift syntax checks.

Native smoke runners link application code against isolated temporary libraries
and deterministic provider/Canvas fixtures. Data checks cover importing,
reconciliation, search, edits, persistence, and image coordinates. UI checks
cover native windows. Extension browser automation uses Chromium. CI builds
and tests the native release with full Xcode on `macos-latest`; local XCTest
requires full Xcode too. Build output and smoke screenshots are ignored; old
one-off measurements are not maintained as product specifications.
