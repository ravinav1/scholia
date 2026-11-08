# Chrome extension

The Chrome app is built from `apps/chrome` plus `packages/core`.

The extension runs independently of the native macOS app. It has its own PDF
reader, conversations, browser context, provider settings and local storage.
Exam planning remains a native-app capability; no Scholia website or loopback
workspace is required or launched by the extension.

```sh
npm install
npm run build
```

Load `dist/chrome` as an unpacked extension. Do not load `apps/chrome`
directly: the production directory contains bundled JavaScript and local KaTeX
assets required by Manifest V3.

Each local build stamps `dist/chrome/manifest.json` with a fresh Chrome-valid
version that Chromium displays directly, so rebuild before reloading the
unpacked extension. Release builds can set an explicit version with
`SCHOLIA_EXTENSION_VERSION=1.2.3 npm run build`.

Run `node scripts/smoke/browser/smoke-chromium-region.mjs` after building to verify direct
page/PDF region selection, Retina cropping, and cancellation in Chromium.

Every assistant response—inside the page popup, layered explanations, sidebar,
and separate response chat—uses the same CommonMark/GFM renderer. It supports
nested and task lists, headings, block quotes, safe links, tables, KaTeX math,
hard breaks, inline code, and distinctly bordered fenced code with language-aware
highlighting and a Copy button. Raw HTML is shown as text, active URL schemes are rejected, and
model-authored remote images are represented without fetching them. Provider-
returned reasoning or reasoning summaries appear in a separate collapsed
panel, and no panel is rendered when the response contains none.

## Gestures

- Toolbar side panel: ask questions grounded in the current page or complete
  PDF, then continue the conversation without leaving the source.
- Toolbar icon: open an independent, streaming Quick Chat inside the pinned
  extension popup, plus current-site access, quick selection/capture actions,
  model/Fast mode controls, and saved-chat management. It does not open the
  sidebar; **Open sidebar** remains a separate explicit action.
- Sidebar chat: use **Home** to return without discarding the conversation, or
  **New chat** to reset it. Model and reasoning controls sit in the message bar
  and on sidebar home. Reasoning choices follow the selected model's supported
  levels and are remembered per provider, including in popup and PDF chats.
  Expand **Chat options** for context, language, web search, and Codex/Claude Code
  Fast mode. Source details expand above the conversation. **Compact context**
  reads the page beside the sidebar, ranks page/PDF/course/site and saved
  ChatGPT reference text locally, and limits the source
  pack to about 6,000 characters. **Full** includes entire articles and short
  PDFs (typically 10–15 pages) up to 120,000 extracted source characters, with
  page boundaries preserved. Larger sources use bounded excerpts. Full context
  is retained when saving and reopening a chat; **None** sends only the conversation
  plus text or images you attach. The choice is saved with the chat. In every
  extension message composer, Enter sends and Shift+Enter inserts a new line.
  Use the search button
  or `Command+F` / `Ctrl+F` to find messages in the active conversation;
  `Enter` and `Shift+Enter` move between results.
- Use the expand button in a completed sidebar chat to open the same saved
  conversation in the extension-owned `chat.html` tab. The full-page view adds
  a persistent recent-chat rail and a wider reading column while retaining the
  sidebar's source context, model controls, streaming, search, edit/resend,
  attachments, rendered math, tables, and recursive response explanations.
- Use **Move to chat ↗** in a page explanation or response explanation popup
  to continue it in a full-page chat, or in that PDF's own sidebar when using
  the PDF reader. Each embedded PDF sidebar keeps its conversation and source
  tied to its containing tab rather than following other windows or global
  Quick Chat navigation. The saved chat retains the transcript,
  selected source, parent explanation context, and drafted follow-up. Wait for
  a response to finish or stop it before moving; the popup closes only after
  the chat opens successfully, returning to the parent explanation when nested.
- Source cards show the detected document language. In **Auto**, Scholia detects
  it from the bounded page, email-thread, or extracted-PDF text instead of
  assuming that every non-Norwegian document is English; a reliable text result
  can correct stale HTML language metadata or the browser locale.
- Completed sidebar turns are kept in bounded extension-local history. Recent
  chats can be reopened or deleted from either surface; oversized source images
  are not retained. An open sidebar and dedicated tab synchronize newer saved
  turns rather than maintaining divergent transcript copies.
- A text selection on the source page is mirrored into the side panel as both
  the active source excerpt and a removable composer attachment. If a chat is
  already underway, the selection is attached to the next turn without
  changing the chat's fixed source context. With OpenAI, Anthropic, OpenRouter,
  or the local Codex bridge selected, enable **Web search** on the selection
  prompt or chat controls to search current public sources for that turn;
  returned citations are rendered as clickable source links.
- Select text inside any side-panel assistant response to open an anchored
  Explain prompt. Submitting it opens a separate explanation layer with its own
  follow-ups instead of inserting a turn into the parent chat. Text in that
  generated answer can be selected again to create another layer without a
  depth limit; Back unwinds one layer at a time, and every layer retains its own
  scroll position. Settings can import an editable memory/project snapshot from
  a visible signed-in ChatGPT tab. **Get full memory from ChatGPT** opens a
  dedicated canonical Personalization tab, presses Memory summary → Manage, and reads
  only the rendered memory manager after generation finishes and the text has
  stabilized. It closes that temporary tab and returns to Settings on success;
  on failure it leaves the tab visible for sign-in or troubleshooting without
  navigating an existing conversation. Imported memory is used automatically for Scholia requests on
  `chatgpt.com`; saved project context is added only for the matching project.
  Quick Chat can optionally refresh through a temporary inactive ChatGPT tab
  on a recurring 3-hour, 12-hour, 1-day, 3-day, or 7-day schedule, close that
  tab, and include the latest locally saved snapshot in its first question. If
  Chrome missed a scheduled run, Quick Chat uses the saved snapshot immediately
  and catches up in the background instead of delaying the prompt.
  Elsewhere, the response Explain prompt offers a per-request toggle. Scholia
  never reads ChatGPT cookies or private account endpoints.
- User messages in the sidebar, separate response layers, and in-page
  explanation layers expose **Edit**. Resending an edit keeps the earlier
  transcript, discards later turns that depended on the old wording, and
  regenerates from the changed message.
- **Follow links**, available on the home screen and during a page chat, searches
  Canvas course materials and follows relevant links across sites for each
  question. Links in the question get priority. HTML, PDFs, Office documents,
  and readable text files are supported; source URLs stay beside their excerpts.
  **Sources read** lists the evidence gathered. Normal mode asks you to choose
  sites before reading them, including newly discovered sites. **YOLO** skips
  these reviews for this chat; it still respects disabled sites and allowlists.
  Both modes only read: they never click buttons, submit forms, or change Canvas.
  **Stop**, Home, a new chat, or closing the chat cancels research and pending
  requests. A cancelled question stays in the composer for editing.
  Each question allows up to 36 linked-page requests, three link levels, and
  45 seconds of network work, excluding review time (Canvas indexing has its
  own limits below). Redirects, sign-in pages, action links, inaccessible files,
  and unsupported content are skipped, and incomplete coverage is reported.
- The side-panel **Complete page** toggle scrolls through the current document
  to trigger lazy content, reads live semantic text plus accessible embedded
  documents and open shadow content, captures a bounded full-page visual for
  image-capable models, and restores the original scroll position. Very long or
  unbounded pages are explicitly marked as visually sampled.
- Ordinary page questions index live rendered and dynamically inserted text,
  useful image labels, accessible embedded content, and a bounded, sanitized DOM
  HTML snapshot. Scripts, styles, event handlers, live form values, Scholia's UI,
  and large inline data URLs are omitted before relevance packing.
- In supported webmail readers, selecting a passage changes the pill to **Draft
  reply**. Scholia extracts only the surrounding conversation (including visible
  sender, recipient, date, and attachment-name metadata), uses it as private
  reference context, and drafts a ready-to-send response in the thread's tone
  and language. It never presses the mail client's Send button.
- Select text: use the small Explain pill; click anywhere outside it to dismiss.
- Open a PDF: on Chromium 151 and newer, Scholia handles Chrome's existing PDF
  stream in place, keeping the original HTTP(S) or `file://` navigation in the
  address bar while the selectable reader is active. Browsers without the public
  MIME API use the extension-owned compatibility view after navigation completes.
  Automatic opening is enabled in every supported browser, including Brave.
  PDFs opened from Finder, dragged into a browser tab, or opened with the
  browser's Open File command use Scholia's reader too.
  Repository preview pages first resolve through their raw PDF address. Mark
  text to show the ordinary Explain pill in place. Selection/mark drafts are
  keyed to that viewer tab, so marking one open PDF cannot appear in another
  PDF tab, and they are cleared when that tab loads a replacement document.
  **Chat with PDF** opens a floating in-reader chat with locally extracted,
  page-numbered context. Chat mounts directly into the reader's document in all
  browsers, including Brave. Its isolated styles and controller avoid nested
  extension-frame navigation, which affected Brave builds block, while keeping
  each PDF tab's conversation independent. Use the viewer's
  search button or `Command+F` / `Ctrl+F` and choose **Exact** for literal
  phrases or **Semantic** for locally ranked concepts and natural-language
  questions. `Enter` and `Shift+Enter` move through highlighted results. The
  view button offers **Continuous**, **Single page**, and **Two-page spread**
  layouts alongside **Automatic**, **Fit page**, and **Fit width** sizing; both
  choices persist between PDFs. Left/Right move to the previous or next page,
  or by a complete spread in two-page view, while Up/Down scroll by a line.
  Page Up/Down and Space/Shift+Space
  scroll by a viewport; Home/End jump to the document edges; and `Command`/`Ctrl`
  with +, −, or 0 controls PDF zoom. The
  printer button (or `Command+P` / `Ctrl+P`) prepares every page at print
  resolution—including pages outside the lazy render cache—and then opens
  Chrome's native print preview. The viewer opens external DOI/publisher links
  in a new tab, follows internal
  page and named-destination links in place, and resolves relative links from
  the actual downloaded PDF address. Repository preview links from GitHub,
  GitLab, and Bitbucket are resolved to their raw document, and bounded HTML
  preview pages can supply an embedded or explicit download URL. It shows the
  sanitized original page address with a **Copy URL** button that copies the
  full original PDF address, including download parameters, and has a persistent
  light/dark interface control that never recolors the PDF pages themselves.
  Pages render at a minimum 2× density. When a zoomed page exceeds the full-page
  canvas budget, the visible area is rendered again directly from the PDF at
  display resolution. Refinement follows scrolling, resizing, and display
  density changes while preserving selectable text and bounding canvas memory.
  Reading, navigation, selection, downloading, and printing are available as
  soon as the first page opens. A quick text index makes exact search and chat
  context available progressively; OCR for scanned pages and semantic search
  build automatically in the background. Search results expand without moving
  the current page or selection. Print preparation takes priority over new
  indexing work. The toolbar shows each stage, and completed indexes are cached
  locally for reopening.
  **Chrome view** returns to the built-in viewer; the toolbar menu's **Open
  Scholia PDF view** button restores the selectable view.
- The toolbar menu also offers **Open a PDF file or address** at any time. HTTP,
  HTTPS, and file addresses open in a new Scholia reader tab, and a local file
  can be chosen from that tab. On supported Chromium 151 and newer, Scholia handles the
  browser's PDF stream in place, so the active reader and restored tab keep the
  original HTTP(S) or `file://` address in the address bar. Existing opaque
  reader links migrate back to their saved original address after an extension
  reload. The MIME reader stores its current page in per-tab session storage;
  it avoids History API updates that crash Chromium's handler frame. Older
  Chromium versions and browsers without the public API keep the extension-URL reader as a
  compatibility fallback. A PDF selected with the
  Chromium file picker keeps a revocable handle to that file—not a copy of its
  bytes—so its reader tab can reopen the same file from disk after a restart.
  Chromium may ask you to allow read access again. Transient blob/data sources
  and the legacy file-input fallback remain session-only.
- Selecting LaTeX inside Overleaf's CodeMirror editor shows the ordinary
  Scholia Explain affordance while selections in other editable fields remain
  ignored.
- Click MathJax: select its whole source expression.
- Option/Alt-click MathJax: choose the exact symbol, then use Narrower/Wider.
- Shift+Alt-click, or press **+ symbol**, to select several math symbols.
- Select text or mathematics inside an assistant answer to explain it in a new
  layer. Parent explanations remain fully rendered behind the active panel and
  available as context; Back returns to the previous layer.
- Press ⊘ in the in-page popup to disable Scholia for that website; re-enable
  it from the compact toolbar menu or sidebar.
- Settings can switch website access to allowlist mode; the toolbar then adds
  or removes the current website from the whitelist.
- `Command+Shift+E` / `Ctrl+Shift+E`: explain the current selection.
- `Command+Shift+S` / `Ctrl+Shift+S`: capture a visible region. Region questions
  retain the current page context; in Scholia's PDF viewer that includes the
  locally extracted, page-numbered PDF text.
- `Command+Shift+K` / `Ctrl+Shift+K`: open a fresh Quick Chat in the sidebar, or close it when it is already open.
  Extension settings show the active Region and Quick Chat bindings and link to
  Chrome's shortcut editor for remapping them. On ordinary pages, Scholia also
  handles this key in-page when Chrome has left the extension command unassigned.
- If the native Scholia macOS app is also installed, its active-app menu offers
  separate Selection Explain and screen-region switches. Hand off only the
  shortcut that the extension should own in that Chromium browser.
- Use the image button in either composer to choose a local image, or paste an
  image directly into the question field. In an active sidebar chat, chosen,
  pasted, and region-captured images become editable attachment drafts, then
  travel with the question as new user turns in that same chat;
  from Home they open a new image-grounded conversation and keep any question
  already typed.
- Toolbar icon: open the compact Scholia menu.

Chrome blocks content scripts on internal pages such as `chrome://settings`,
the Chrome Web Store, and its built-in PDF viewer. PDFs are handled in Scholia's
own selectable viewer and side panel. Region selection opens directly over the
rendered page or PDF: drag to capture, or press Escape to cancel. The PDF chat
hides during selection and returns afterward. Capture covers the visible page
viewport, not content currently scrolled off-screen.

PDF pages with little selectable text are read with bundled, on-device OCR
(English and Norwegian). This also applies to PDF attachments. Recovered text
keeps its page numbers, feeds document context and search, and is cached with
the reader's PDF index. Existing selectable text is retained. OCR processes up
to 50 sparse pages per document, with a 30-second limit per recognition job;
unreadable or skipped pages are reported. The original PDF is unchanged.

Links whose visible path ends in `.pdf` sometimes return an HTML preview rather
than PDF bytes. Scholia follows standard raw-download response hints and common
repository preview formats, verifies the PDF signature before parsing, and
keeps **Open original page** available if no safe document download can be
found.

On the compatibility path, local `file://` PDFs require
**Allow access to file URLs** on Scholia's extension details page (for Brave:
`brave://extensions` → Scholia → Details). This is a one-time browser permission
that extensions cannot enable themselves. You can also use **Choose PDF
file** when the panel asks. The original-URL MIME reader does not require that
file-access permission. PDF text
extraction, page mapping, and semantic relevance ranking all happen locally;
only the bounded context pack is included in a provider request. Completed
text indexes are cached in extension-local IndexedDB under a PDF.js document
fingerprint, so reopening the same bytes can restore search and chat context
without extracting every page again. PDFs up to 1 GB can be opened. Large
chosen or downloaded PDFs are parsed through bounded local range reads to avoid
keeping a second full-file copy in JavaScript memory, though indexing and
rendering very large documents can still take substantial time.
PDF.js image decoders are bundled with the extension, including the local
WebAssembly path needed by JPEG 2000 and JBIG2-heavy scanned or illustrated
documents. No decoder code is fetched remotely.

## Provider protocols

The worker has dedicated wire handling for Anthropic, Ollama, Cohere, and the
native opencode session API. Its OpenAI-compatible path is used by OpenAI,
GPT NTNU, OpenRouter, Groq, Together, Mistral, custom endpoints, and the local
Codex and Claude Code bridges. GPT NTNU uses the IDUN endpoint and requires a
personal API key plus an NTNU network or VPN connection. Fast mode maps to
Codex's fast service tier and Claude Code's Fast setting. Local bridge health,
usage, Codex image support, and
optional Claude image support are discovered over loopback. Scholia also reads
the live opencode provider catalog, keeps only connected and built-in providers,
merges manually configured model IDs into every picker, and caches that compact
list for ten minutes. Search popovers render at most 80 matching rows at once so
even a large server catalog does not stall the extension UI.
The exact-ID field remains available for models a server does not advertise.

### Chat files and Canvas courses

Every browser chat composer has an **Attach files** paperclip and accepts file
drops and file paste. This includes sidebar, full-page, PDF-reader, toolbar, and
selection explanation chats. Any file can be attached; supported text, PDFs,
Office files, and readable archive members (including Simulink XML) are extracted
locally. Files remain with their sent message when saved, reopened, or edited.
Limits are 24 files, one visual image per message, and 25 MB per browser file.
Complete supported extraction text is retained: large extension attachments use
IndexedDB, and hosted attachments use account-scoped text files. The UI shows a
bounded preview; it does not discard the rest of the saved text. Each question
searches the saved extraction and selects up to 24,000 characters per file and
48,000 per turn, with explicit request coverage. Followups can retrieve different
parts, including the end of a long file. Format-specific processing limits and
unreadable, encrypted, or unsupported contents are reported visibly. Attachment
IDs and supplied paths distinguish separate copies; browsers cannot supply an
original absolute path for an ordinary file selection.

On a signed-in Canvas course page, automatic page context searches that course's
syllabus, pages, assignments, and readable files, including module-only files.
**Index / refresh course** builds or refreshes the local index; **Refresh course
index** is also available during that chat. New questions reuse the index and
check for changes once it is 15 minutes old. Unchanged documents are reused;
changed and removed documents are reconciled on refresh. **Clear index** removes
the current course's local index. None mode skips automatic course retrieval.

Indexes live in extension IndexedDB, separated by Canvas host, signed-in account,
and course. Up to eight courses are retained, with 300 sources and two million
text characters per course. Large, locked, or unsupported materials make the
index partial; the context notice reports that limitation. Course API access and
current account identity are verified before using cached content. Only ranked
excerpts and source links are included in a model request; raw course downloads
and signed download URLs are not stored in the index.

## Local bridge setup

To install a macOS URL handler for a local bridge:

```sh
npm run bridge:install:codex
npm run bridge:install:claude
npm run bridge:install:opencode
```

Each accepts `-- --port N` or `-- --uninstall`. Node.js and the chosen CLI must
be installed. To start Codex or Claude directly, use `npm run bridge:codex` or
`npm run bridge:claude`; opencode uses `opencode serve --port 4096`.
Rerun the installer if the source folder or launcher paths change.

Disable Scholia for a site from the popup or toolbar. Allowlist mode keeps it
inactive except on the hostnames you choose.

## Testing and release

Browser verification uses Chromium. After building:

```sh
node scripts/smoke/browser/smoke-chromium-region.mjs
node scripts/smoke/browser/smoke-chromium-history.mjs
npm run smoke:chromium:recursion
```

For a Web Store package:

```sh
npm run check
npm run package:chrome
```

Upload `dist/scholia-chrome-<version>.zip`. Packaging uses the version in
`package.json`, checks manifest entries and bundled dependencies, rejects remote
or dynamically evaluated code, and verifies that the manifest is at the ZIP
root. Update `package.json`, the lockfile, and the source manifest together when
bumping the release version.

The listing's single purpose is to explain user-selected text, mathematics,
images, regions, pages, and PDFs with the user's chosen provider. Suggested
short description: “Select text, math, or a screen region and get a contextual
AI explanation.”

| Permission       | Use                                                                           |
| ---------------- | ----------------------------------------------------------------------------- |
| `activeTab`      | User-requested page reading and region capture                                |
| `offscreen`      | Bundled local OCR for scanned PDFs, including attachments on restricted pages |
| `alarms`         | Optional scheduled ChatGPT memory refresh                                     |
| `contextMenus`   | Explain and Capture commands                                                  |
| `clipboardWrite` | Copy code buttons                                                             |
| `scripting`      | Connect the ChatGPT context probe to an already-open tab                      |
| `storage`        | Settings, credentials, access rules, and saved chats                          |
| `sidePanel`      | Contextual chat beside the page                                               |
| `<all_urls>`     | Selection controls, requested page/PDF/site context, and provider requests    |

Before submitting, publish the [privacy policy](../../docs/PRIVACY.md), complete
the store's privacy questionnaire to match extension behavior, provide toolbar
and sidebar screenshots, and check the support URL. The extension has no
analytics, advertising, or project-operated content backend. The separately
hosted web app has a different data path, documented in the same policy.
