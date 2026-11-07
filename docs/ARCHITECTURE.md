# Architecture

Scholia has three independent runtimes: a native macOS app, a Chrome extension,
and an optional hosted web service. `apps/web` supplies the browser workspace
for either the native app's loopback API or the hosted service. Opening the
native workspace does not start a web server.

## Repository map

| Path            | Responsibility                                                                        |
| --------------- | ------------------------------------------------------------------------------------- |
| `apps/macos`    | SwiftUI/AppKit application, native document readers, local library, Canvas, providers |
| `apps/web`      | Browser workspace, PDF.js reader, tutor UI, local and hosted API client               |
| `apps/server`   | Hosted accounts, private storage, Canvas access, document indexing, provider requests |
| `apps/chrome`   | Extension capture, PDF reader, side panel, settings, service worker                   |
| `packages/core` | Shared JavaScript prompts, provider contracts, context ranking, tutoring rules        |
| `scripts`       | Build, packaging, local bridges, account administration, integration checks           |
| `tests`         | JavaScript unit and service integration tests                                         |

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
never executed. Native semantic search uses the bundled JavaScript ranker in
JavaScriptCore; it requires no model request.

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

## Local browser workspace

**Open in Browser** starts `StudyWebServer` on `127.0.0.1:8792`. Its bundled
frontend shares the native model, files, provider settings, Canvas connection,
reading position, and learning store. The Mac must remain running. Native and
local-browser navigation refer to the same active workspace.

The dashboard loads a small ES module graph. PDF.js, notebook reading, practice,
assignment instructions, and rich text rendering load when first used. HTML
escaping stays independent of Markdown, math, and syntax highlighting. Reader
generations prevent delayed loads from replacing a newer destination; failed
loads expose a retry. Chat updates retain unchanged message sections so activity
ticks and streamed tokens preserve source controls, disclosures, and selection.
The PDF reader additionally budgets retained canvas pixels, evicting completed
offscreen pages while protecting visible pages and active selections. This
avoids retaining ten high-resolution canvases merely to fill PDF.js's page cache.

Both browser APIs support conditional state requests with ETags. The browser
acknowledges only accepted snapshots, skips parsing and rendering on unchanged
responses, and separately advances deadline and answer timers. Native snapshots
are invalidated by model changes and encoded off the main actor. Static assets
revalidate privately; session HTML and API state remain `no-store`. Material
groupings are reused until their catalog inputs change.

The server validates Host and Origin, rejects cross-site requests, and requires
a per-launch token for API and document access. It sends no raw Keychain
credentials to the browser. Responses disable caching and set a restrictive
Content Security Policy. The browser renders PDFs with PDF.js; provider calls,
OCR, and library mutations remain native operations.

Draft and page mutations carry an originating destination and revision. Stale
writes cannot silently overwrite another window's work. Browser edit drafts and
practice outbox entries remain available for recovery after a conflict.

## Hosted web service

`apps/server/server.js` runs independently of macOS on Node.js 24 or newer.
It serves the same frontend with capability flags for hosted features. No
native process, desktop permission, or loopback bridge is required.

- `store.js` owns the SQLite account database, password hashes, sessions, and
  credential encryption. Passwords use salted scrypt; sessions store hashed
  random tokens and expire after seven days. Credentials use AES-256-GCM with
  account-specific authenticated data and a server-held key.
- `workspaces.js` scopes every operation to the authenticated account and
  serializes that account's mutations. Workspaces and conversations are private;
  each session has independent reading navigation. Document edits validate the
  source revision before replacing the active file reference.
- `documents.js` stores originals and indexes beneath account-specific
  directories. Extraction runs in bounded worker threads. PDFs use PDF.js;
  Office and notebook readers extract data without executing document content.
  Hosted extraction does not perform the native app's Vision OCR.
- `canvas.js` uses each account's own Canvas token and an operator-controlled
  host allowlist. `network.js` rejects private/reserved network destinations,
  pins validated DNS results for requests, bounds downloads, and strips
  credentials when following file redirects.

Original document and static-asset responses stream from open file descriptors
with backpressure, instead of buffering complete files for each client. Search
workers retire their isolates after idle deadlines and reopen persistent indexes
on demand. Retirement is negotiated with the parent so a new request or ongoing
semantic indexing cannot be interrupted by the idle timer.

API and file routes authenticate the session and check ownership before reading
data. Mutations require the session's CSRF token. Host/Origin checks, strict
HttpOnly cookies, login throttling, upload limits, CSP, and worker limits provide
additional boundaries. HTTPS is required for non-loopback public origins.
The server operator can read stored files and decrypt credentials; this is not
end-to-end encryption.

The first hosted deployment uses one service process with persistent SQLite and
file storage. It supports separate accounts, conversational tutoring, Canvas,
imports, and editable text/notebooks. Native spaced practice and its review
queue are not exposed in hosted web. Hosted, native, and extension libraries do
not synchronize. See [Hosting](HOSTING.md) before deployment.

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
Hosted tests exercise two-account ownership, credentials, CSRF, independent
navigation, and revision conflicts. `scripts/smoke/browser/smoke-hosted-web.mjs` exercises the
real service in Chromium.

Native smoke runners link application code against isolated temporary libraries
and deterministic provider/Canvas fixtures. Data checks cover importing,
reconciliation, search, edits, persistence, and image coordinates. UI checks
cover native windows and the browser workspace. Browser automation in this
repository uses Chromium. Build output and smoke screenshots are ignored; old
one-off measurements are not maintained as product specifications.
