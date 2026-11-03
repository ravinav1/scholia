# Scholia privacy policy

**Effective date:** 27 September 2026

Scholia explains material you choose from a page, document, screenshot, or image.
It includes no analytics, advertising, or telemetry. Storage and transmission
depend on the client you use:

- The **Chrome extension** processes sources locally and sends questions directly
  to your chosen provider. Its history and settings stay in extension storage.
- The **native Mac app** stores its library on your Mac and credentials in
  Keychain. Its optional **Open in Browser** interface uses a loopback server on
  that Mac and shares the same library.
- The **hosted web service** stores account data and uploaded or downloaded files
  on the server you sign into. It sends provider requests on your behalf using
  your saved credentials. Workspaces are private between accounts, but the
  server operator can access stored data and decrypt credentials.

Native, extension, and hosted libraries do not automatically synchronize. A
hosted operator must provide their own contact, backup, and retention details in
addition to this description of the software.

## Data Scholia handles

Depending on the feature you use, Scholia may handle:

- selected text or mathematical notation;
- your question, recent conversation turns, and selected answer text used for a
  follow-up explanation;
- the title and address of the current page, with URL query parameters and
  fragments removed before provider submission;
- rendered page text, a sanitized snapshot of the page's DOM HTML, locally built
  headings, and relevant excerpts when page-wide context is enabled;
- lazy-loaded live text, readable embedded-frame text, image labels, and a
  stitched page visual when you explicitly enable **Complete page**;
- the bounded conversation containing a passage you select in a supported
  webmail reader, including visible sender/recipient/date fields, message text,
  and attachment names (not attachment contents), when you choose **Draft
  reply**;
- page and document text from Canvas and linked websites when you enable
  **Follow links**; you review new sites before reads, or choose **YOLO** to
  skip those reviews for the current chat. Relevant excerpts and their URLs
  are sent to the selected model. Research source URLs preserve meaningful
  query parameters; known credentials, signed URLs, tracking parameters, and
  fragments are excluded;
- PDF text and page numbers extracted locally from a document you opened or
  chose;
- when enabled in the macOS app, bounded Accessibility text and labels from a
  small set of windows visible when you send a question, locally ranked for
  relevance to that question;
- a visible-tab region, visible-page fallback, or image you explicitly chose or
  pasted;
- provider, model, language, endpoint, and per-site access settings;
- sidebar chat transcripts and the bounded source context needed to reopen a
  saved chat;
- an optional, user-reviewed snapshot of ChatGPT memory or project text that
  you explicitly import from a visible signed-in ChatGPT tab;
- an optional automatically refreshed ChatGPT Memory snapshot when you choose
  a Quick Chat refresh interval;
- provider API keys or local-endpoint credentials;
- the current site's hostname when you add it to an allowlist or blocklist;
- imported documents, extracted indexes, edits, and retained earlier versions;
- in native chats and the Mac's local browser workspace, local filenames, paths,
  and file contents read to answer your question when **Allow file access** is
  enabled; file text and images read this way are sent to the selected model;
- Canvas account/course identifiers, catalogs, deadlines, submission status,
  downloaded course material, and your Canvas token or native session;
- native practice questions, attempts, assistance, feedback, and review dates; and
- for hosted web, your account email, password hash, session records, private
  workspaces, and account-specific settings.

The extension does not read Chrome browsing history, copy browser cookies, or
collect form history, contacts, location, or financial information. Canvas
requests may use the browser's existing authenticated session without exposing
its cookies to page content or providers. The optional ChatGPT web connection checks
only whether an open ChatGPT tab exposes its signed-in composer/account UI. It
does not copy session cookies, call private ChatGPT account endpoints, or
silently enumerate chats, project files, or projects. When you explicitly click
**Get full memory from ChatGPT**, it opens the visible Personalization screen,
clicks **Memory summary → Manage**, and reads the memory text rendered there.
If you choose a Quick Chat refresh interval, Scholia performs the same rendered-
UI read in a temporary inactive ChatGPT tab on that schedule while Chrome is
running, then closes that tab. Startup and the first Quick Chat question start
a missed refresh in the background; the question uses the last saved snapshot
without waiting. It does not navigate or replace your active conversation.

## How data is used

The native **Study on Paper** feature requests camera access only after Connect.
Its video preview stays on the Mac; no audio or video recording is made. Manual
questions or resumed proactive analysis send the selected notebook crop and up
to two earlier crops with bounded session context to the selected model.
Help-on-request observation keeps steps locally until the student asks. Paper
sessions are held in memory, bounded to 24 crops / approximately 20 MB of encoded
images, and cleared on close or Clear session; they are not saved in the study
library. Pause AI keeps the camera preview active; Stop camera releases it.
Provider retention still applies. Local CLI bridges may write temporary request
images until completion/cancellation; clearing Scholia does not delete data
already received by a provider. Paper requests do not enable local file tools.
See [camera controls and retention](PAPER_STUDY.md).

Data is used only to provide the explanation or contextual conversation you
request, remember your extension settings, enforce your site access choices,
keep an active conversation grounded in the source you chose, and let you
return to saved chats and readings. Hosted data is additionally used to
authenticate your account and keep its workspaces separate from other accounts.

The Mac app's **Settings → Privacy → Local files** controls file tools in chat.
Read access is enabled by default. **Allow write access** is separately disabled
by default and permits creating folders and creating or editing text/code files
when enabled. Disabling access blocks subsequent file operations, including in
an active answer. macOS folder permissions still apply. These tools are not
available to background document classification or model connection tests, and
do not give the hosted website or extension access to your Mac's filesystem.

Long pages, sites, and PDFs are indexed on the device. Completed PDF text
indexes may be retained in extension-local IndexedDB under a document
fingerprint so the same PDF can reopen without repeating extraction. The cache
does not retain the source URL or local filename, keeps at most 12 bounded
indexes, and evicts older entries when its 60-million-character budget is
reached. Clearing Scholia's extension data removes the cache. For the active page, the
DOM snapshot omits scripts, styles, event handlers, live form values, Scholia's
own controls, and large inline URLs. The extension sends a bounded context pack
rather than the complete local index. Automatic page, PDF, site, and in-page
selection context in Compact mode is question-ranked into a roughly 6,000-character pack;
automatically attached saved ChatGPT context is separately capped at roughly
4,000 characters. In the extension, Full mode includes complete articles and
short PDFs up to 120,000 source characters, with bounded excerpts for larger sources; the
explicit None control can omit both while preserving selections and images.
Screenshots and chosen images are resized on
the device before submission.

In the extension, sparse or scanned PDF pages are rendered locally for OCR.
The OCR engine and English/Norwegian language data are bundled with the
extension; recognition does not upload page images or download remote code.
Up to 50 sparse pages per document are processed, with a 30-second limit per
recognition job. Recovered text can be retained in the PDF index and saved
chat context described here, and sent to the selected provider when you ask a
question. Temporary recognition images are discarded after processing.

For a mail selection, Scholia targets the conversation containing the selected
passage rather than the inbox or unrelated messages. The thread is delimited as
untrusted private reference text. Selecting text alone does not contact a model;
the provider request begins only when you choose **Draft reply** or submit a
question. Scholia never sends the reply through the mail service.

For optional ChatGPT context import, Scholia reads text you select in the
ChatGPT page, text in a settings/project dialog you deliberately leave open, or
the rendered memory manager after you explicitly start the full-memory import.
The importer ignores generation/loading placeholders and waits for the rendered
summary to remain stable before saving it locally. The snapshot is then shown
in an editable Settings field. It remains manual unless you select a Quick Chat
refresh interval; the available intervals are every chat, 3 or 12 hours, 1, 3,
or 7 days.

## When data leaves the device

Scholia sends a provider request only after an explicit action such as asking a
question, choosing **Explain**, starting a capture, or submitting a follow-up.
In the native app and extension, that request goes directly to the provider or
compatible endpoint selected in Settings. Hosted web sends it through the
service's server to your chosen provider. Supported hosted choices include Anthropic, OpenAI, OpenRouter, Groq,
Together AI, Mistral AI, Cohere, and GPT NTNU's IDUN service. You can instead
choose Ollama, a local CLI bridge, opencode, or a custom compatible endpoint.

The selected provider receives the question and the source material required
for that explanation. An API key is sent only to its configured endpoint for
authentication. The provider's own privacy policy, retention settings, and
service terms apply. Local CLI tools may contact the model service associated
with your local login.

When you explicitly enable **Web search**, Scholia asks OpenAI, Anthropic,
OpenRouter, or the local Codex CLI bridge to use that provider's hosted search
tool for the current turn. The provider may derive and send search queries to
its own search infrastructure or search partners, and the provider's search
pricing and data terms apply. Native and extension search requests do not pass through a Scholia server. Web search is not offered for local or generic compatible
endpoints whose tool contract cannot be verified.

An imported ChatGPT memory/project snapshot can be sent to the selected Scholia
provider in two cases: when you turn on **Include imported ChatGPT context** for
an explanation of selected assistant-response text, or automatically for a
Scholia request whose source page is `chatgpt.com` while **Automatically use
imported memory on chatgpt.com** is enabled. Automatic use always includes the
global memory snapshot, but includes saved project context only when its
`g-p-…` identifier matches the current ChatGPT project. The request clearly
delimits the snapshot as reference material. This can disclose the imported
text to a provider other than OpenAI if that is the provider you selected.
When you select a Quick Chat refresh interval, the same saved snapshot is also
included automatically in new Quick Chat requests, including chats about pages
outside ChatGPT. Choosing **Manual only** disables that automatic refresh and
inclusion.

The software contains no advertising, profiling, or model-training data
collection. Native and extension use does not send content to project
maintainers. A hosted service's operator can access its database, files,
backups, and credential-encryption key; choose an operator you trust and review
their policy. Provider processing and retention are governed by that provider.

## Storage and retention

### Chrome extension

Provider settings, API keys, and site access rules are stored in
`chrome.storage.local` until you change them, clear the extension's data, or
uninstall Scholia. Chrome extension storage is not an operating-system
keychain; use a dedicated, revocable provider key with a spending limit.
Imported ChatGPT snapshots are stored with those local settings until you clear
their fields, clear extension data, or uninstall Scholia.

On supported Chromium 151 and newer, a PDF handled by Scholia keeps its original HTTP,
HTTPS, or file address in the browser address bar; Chromium supplies the
document through a one-use stream and Scholia does not persist that stream.
The reader stores a document fingerprint and page number in per-tab session
storage to restore its reading position on reload; it does not store PDF bytes
there. Browsers without the public MIME API use the extension-URL compatibility reader.
Compatibility and migration routes may retain the original address behind an
opaque viewer token in `chrome.storage.local`. Those records are capped at 256,
expire after 180 days of inactivity, and are removed with extension data or
uninstall. A signed URL's query remains available to the browser or private
source record when required to read the document, but it is removed from
provider context. When you select a PDF
with Chromium's file picker, Scholia may retain its filename and a revocable
browser file handle in extension-local IndexedDB so the restored reader can
read that same file from disk. It does not retain a copy of the PDF bytes or
expose its filesystem path. Chromium can revoke access and require you to allow
it again. Handle records are capped at 32, expire after 180 days of inactivity,
and are removed with extension data or uninstall. Blob/data addresses and the
legacy file-input fallback remain session-only.

Sidebar chats are also stored in `chrome.storage.local` until you delete one,
choose **Clear all**, clear extension data, or uninstall Scholia. History is
bounded to 24 recent chats and an internal serialized-size limit. It may include
your questions, answers, selected excerpts, a bounded page/PDF/site context
pack, a sanitized source address, and a size-limited chosen or captured image.
When a provider explicitly returns reasoning or a reasoning summary, that
bounded text is stored with its assistant answer so it can be shown again.
Raw PDF download addresses, browser tab identifiers, and oversized source
images are not retained in chat history. These chats are not synced to a
Scholia account or sent to a Scholia server.

The latest page selection—and, for a mail selection, its bounded thread
context—may be placed in `chrome.storage.session` for up to ten minutes so the
side panel can receive it. It is scoped to the originating tab and removed when
submitted, cleared, navigated away from, or replaced in the PDF viewer. A same-site crawl stays in
content-script memory for up to ten minutes. Session data disappears when the
browser session ends.

The extension does not keep an account database or backend copy. Use the
toolbar menu or sidebar Home to delete saved chats. Uninstall the extension or
clear its extension data in Chrome to remove all locally stored settings and
history. Provider-side deletion requests must be made to the provider you
selected.

### Native macOS app

The native app uses local storage and native permission boundaries:

- provider credentials are stored in the macOS Keychain;
- non-secret preferences are stored in `UserDefaults`; per-application desktop
  integration overrides store only an application's bundle identifier, display
  name, Selection Explain state, and region-capture state;
- Quick Ask messages and follow-up answers are kept in memory and are not
  persisted unless you explicitly choose **Move to saved chat**, which promotes
  the active temporary thread; nested explanations retain only bounded parent
  context while they are in memory;
- full chats are stored as a bounded local JSON history in the user's
  Application Support directory and can be reopened or cleared in Scholia;
  bounded provider-returned reasoning is stored with its assistant answer, while
  reasoning in Quick Ask remains in memory unless the thread is promoted;
- Accessibility is used to read the current selection, never protected text
  fields;
- if **Use compact visible-window context by default** is enabled, sending
  a Quick Ask or saved-chat question triggers one bounded, text-only scan of
  ordinary windows currently on screen. Scholia prioritizes the application
  active before its own window; on the first root Quick Chat question, it also
  prioritizes a visible ChatGPT desktop-app conversation when available. It
  reads at most five candidates, correlates visible browser content with tab
  titles exposed through Accessibility, and sends at most three locally ranked windows
  within a 6,000-character workspace cap, and keeps the combined automatic
  source context within an 8,000-character prompt budget. Turning Compact off
  restores the previous full source behavior (bounded to 24,000 characters);
  the separate None control omits automatic text while retaining the explicit
  selection or image. Scholia skips secure
  fields, password managers, minimized windows, Scholia windows, and system
  surfaces. It does not run between questions and does not take screenshots;
- for a text selection in a recognized native mail reader, Accessibility may
  also read a bounded snapshot of the nearest focused conversation container,
  including loaded message text and visible labels such as participants, dates,
  and attachment names; it does not open attachments or read the inbox as a
  general mailbox corpus;
- the optional selection pill checks for a selection only after a mouse-up in
  an application where it is enabled, and fades without taking focus;
- a Command-C fallback is used only after an explicit explain command or a
  mouse-up selection inside a Scholia assistant answer when the focused control
  does not expose selected text through Accessibility, and the previous
  pasteboard is restored when no intervening pasteboard write occurs;
- screen capture occurs only after the region shortcut or menu command, and the
  selected image is cropped and resized locally before provider submission;
- a native region request may also read a bounded snapshot of visible text from
  the active app's focused Accessibility window before the capture overlay takes
  focus, along with its window title and a sanitized document address; protected
  text fields are skipped and local directory paths, URL credentials, queries,
  and fragments are removed;
- hosted endpoints must use HTTPS, while plain HTTP is limited to loopback
  addresses.

The source application and focused-window title may accompany a text selection
as a short reference label. For an explicit native region capture, bounded
visible window text may also accompany the image as delimited reference context.
This can include text exposed by a PDF reader or another active application.
For a recognized native mail selection, the bounded accessible conversation is
delimited as private, untrusted reference context and is sent only when you
choose **Draft reply**, invoke the explicit selection command, or submit your
own question. Scholia produces a draft inside its own window and never sends it
through the mail client.

### Native workspaces and local website

The native study library lives under
`~/Library/Application Support/Scholia/Study`. It contains imported originals,
text indexes, reading positions, course catalogs, conversations, drafts, edit
revisions, and a separate practice event store. Removing a workspace removes
its library entry; imported files and earlier revisions remain on disk for
recovery. Clearing the library on disk requires closing Scholia first. Keychain
credentials are stored separately and are not deleted by removing library files.

The optional **Studentweb results** feature is native-only. Clicking it starts
an automatic check of NTNU's Results page and saves course codes and pass booleans
in a separate, non-synchronizing local Keychain item. The check reuses its own
in-memory sign-in, follows the official Feide form when needed, and opens Results
automatically. **Use ID and PIN** opens the official Studentweb login for direct
entry instead. Scholia never reads or stores those fields. A new sign-in may
still require credentials or MFA.
Grades, names, student/candidate numbers, credentials, dates, attempts and raw
page content are not imported or logged. The extractor returns only
`{courseCode, passed}` after reducing the grade inside the isolated browser.
Hidden rows, partial assessments and unknown results are omitted; absence of a
status means unknown. Empty, unstable or unsupported results never erase saved
statuses. Closing the window cancels pending reads and clears non-cookie website
data. Login cookies remain only inside a per-library nonpersistent WebKit store
until **Forget sign-in** or app exit. Cookies and authentication tokens are never
copied out of WebKit or saved by Scholia. A check sends normal HTTPS requests to
Studentweb and Feide, which still handle sign-in. Importing itself sends no
results to a Scholia server or AI provider.

These records are outside the study library, browser API, hosted service, search,
exports and backups made by Scholia. Native recommendation selections are
filtered locally after the AI response. Native **Get advice** uses the passed
course codes when you submit a question or follow-up, including passed courses
outside the exam plan. Those codes are sent to your selected model provider,
which may be remote; failed results, grades, attempts and identity are excluded.
The advice view identifies the included courses. When degree context is enabled,
the same selected provider receives these codes in both the curriculum-lookup
selection step and the final advice step; an invalid lookup plan may require one
repair call. No additional provider is introduced. The current list is read for
each turn, and deleting statuses removes them from subsequent request context;
it cannot retract earlier provider requests or mentions in conversation history.
Other provider workflows, browser advice and hosted advice cannot access this
Keychain record. Applying a selection still changes the normal shared exam
plan. The Keychain record lasts until replaced or deleted in **Studentweb
results → Delete all saved statuses**, and individual records can also be
deleted. Clearing library files or uninstalling the app does not remove this
separate Keychain item. Deletion does not erase historical system backups or
Studentweb's own records. See the [Results import workflow](STUDY_WORKSPACE.md#local-course-pass-statuses-from-results)
for scope, limits and synthetic privacy checks.

Degree-plan lookups use a bundled public NTNU catalogue with cohort-specific
courses, semesters, branches and choice rules. Refreshing that catalogue uses
public requests without Studentweb credentials or cookies. Relevant public plan
data is included in degree-advice requests. The model first receives a compact
index of the selected cohorts and optional focus, then chooses validated read-only
lookups. Those lookups execute against the stored catalogue, without live NTNU
requests or access to other local files. The final advice uses only the retrieved
records. Admission years cannot be overridden by model lookup commands. These choices remain in the open panel;
they are not saved as enrolment records. This catalogue contains no personal
results and is independent of the private pass-status record.

Canvas sign-in uses the app's WebKit data store; Scholia does not collect your
institutional password. Personal Canvas tokens use Keychain. Catalog refreshes
read accessible course metadata and your submission status. Opening a material
fetches it; explicit bulk download controls fetch more. If **Preload frequent
courses** is enabled, the Mac may download a small batch after repeated visits
and an idle delay. This can be disabled in the workspace menu. Canvas access is
read-only; hiding an assignment changes only Scholia's list.

**Open in Browser** explicitly starts a server bound to `127.0.0.1:8792`. It
requires a per-launch token, validates Host and Origin, rejects cross-site
requests, and does not expose provider keys or Canvas credentials to the
browser. It shares native storage and remains available only while Scholia runs.
Opening the native workspace alone does not start this server.

### Hosted web accounts

Hosted web uploads chosen documents and stores fetched Canvas files on its
server. It also stores extracted indexes, conversations and source references,
reading history, drafts, edits, assignment visibility, Canvas metadata, and
provider settings. Files are private to the authenticated account at the API
boundary; separate sessions retain independent navigation.

Account emails and salted scrypt password hashes are stored in SQLite. Provider
keys and Canvas tokens are encrypted with AES-256-GCM using a server-held key.
This is encryption of credentials at rest, not end-to-end encryption: the
operator can decrypt them, and document contents are readable in server storage.
The service needs that access to index documents, fetch Canvas material, and
send questions to your selected provider.

Sessions use HttpOnly, SameSite=Strict cookies, with Secure enabled for HTTPS,
and expire after seven days. The database stores hashes of random session
tokens. Signing out revokes that session. An administrator's password reset
revokes all of that account's sessions. Login attempts are rate-limited by
account and connection address; the software does not persist an analytics
history. A reverse proxy or hosting platform may maintain access logs under
the operator's policy.

Workspace preferences and unsent drafts can also be retained in the browser,
scoped to the account. Signing out clears Scholia session draft storage. Clearing
browser data does not delete server data. Previous document versions and server
backups may be retained after edits or removal. There is no self-service account
deletion interface; contact the service operator for account/file deletion and
backup retention. Provider-side deletion must be requested from the provider.

The hosted service does not run native desktop capture, native OCR, or the
native spaced-practice store. Its saved files require server access; they are
not an automatic offline copy in the browser. See [Hosting](HOSTING.md) for
operator configuration and backup responsibilities.

## Browser access and user controls

Scholia requests access to websites because its single purpose is to explain
content on the page you are reading. It uses that access for selection UI,
explicit page context, user-initiated PDF reading, explicit linked-site research,
and visible-tab capture. It does not passively collect a browsing history or
take background screenshots.

You can disable Scholia on individual sites or switch to allowlist mode, which
keeps it inactive everywhere except the hostnames you approve. Linked-site
research is off until you enable **Follow links**. Normal mode reviews sites
for each question. YOLO skips reviews but remains read-only, respects site
restrictions, and never submits forms or changes course data. Reads use the
browser's existing signed-in access. Stop, leaving the chat, starting another
chat, and closing the chat cancel pending research requests; no detached crawler
continues afterward. Read-source titles and safe URLs are retained with saved
chats alongside the selected excerpts. Page-wide
context can also be disabled in Settings. Lazy loading and full-page visual
capture occur only when you enable **Complete page**; Scholia restores the
original scroll position after capture.

## Security

Hosted provider traffic uses HTTPS. Unencrypted HTTP is allowed only for
loopback endpoints on the same device. Provider credentials remain in
extension-owned settings and service-worker contexts; they are never inserted
into page content or sent to content scripts.

Model output is rendered locally as CommonMark/GitHub-Flavored Markdown. In the
extension, raw HTML is disabled, unsafe link schemes and remote response images
are blocked, syntax highlighting is bundled, and KaTeX runs with `trust: false`.
The native app likewise restricts links, never fetches response images, and
typesets LaTeX locally with bundled math fonts.
Remote executable code is not loaded. These measures reduce risk but cannot
make an external provider, model response, or untrusted page infallible.
Do not use Scholia as the sole authority for safety-critical decisions.

## Children

Scholia is a general-purpose reading tool and is not directed to children under 13. The project does not knowingly collect personal information from children.

## Limited Use

Scholia's use of information received from Google APIs adheres to the Chrome Web
Store User Data Policy, including the Limited Use requirements. Data access is
limited to providing the extension's user-facing explanation features.

## Changes and contact

Material changes to this policy will be dated here and disclosed with the
corresponding extension update. Questions may be opened in the repository's
[issue tracker](https://github.com/heaps0rt/scholia/issues). Report security or
sensitive privacy problems privately through
[GitHub Security Advisories](https://github.com/heaps0rt/scholia/security/advisories/new).

## Chat attachments and Canvas course indexes

In the extension and native app, files explicitly attached to chat are processed
locally. PDF, Office, and text
attachments are converted to bounded text; images are resized for the selected
provider. The extracted text is sent with the user message and retained in local
chat history. Raw document bytes are not sent to the model or saved in history.

When automatic context is enabled on a Canvas course page, Scholia can use the
existing browser login to read that course's syllabus, pages, assignments,
modules, and accessible files through read-only requests. Searchable text is
cached in extension IndexedDB per host/account/course, with up to eight course
indexes. Refresh checks document timestamps and updates or removes indexed
content. The sidebar's Clear index button deletes the current course index.
Only question-relevant excerpts are forwarded to the chosen provider. Automatic context can include a bounded set of readable open tabs ranked for
relevance to the current question. None mode omits automatic source context.

The extension requests clipboard-write access so Copy code works in explanation
popups. Copy buttons write only the selected code block; this permission does
not grant clipboard-reading access.
