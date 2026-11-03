# Study workspace

The workspace keeps courses, documents, and tutor conversations together. It is
available in the native Mac app, its optional local website, and the independent
hosted web service. The local website shares the Mac's library; hosted accounts
have their own private libraries.

## Keyboard shortcuts

| Action | Mac | Web on Windows / Linux |
| --- | --- | --- |
| Search coursework (file names and contents) | ⌘K | Ctrl+K |
| Switch workspace and quick actions | ⌘⇧K | Ctrl+Shift+K |

Choose **Switch** or use the shortcut, then type a workspace name or course code.
The picker searches every semester, even when the dashboard is filtered. Favorites
come first and the current workspace moves to the end. The first six workspaces
appear before you type; typing searches them all. Use **↑ / ↓** to select a result,
**Enter** to open it, or **Escape** to close the picker.

Type **>** for actions: search coursework in the current workspace or across the
whole library, open the dashboard, assignments, exam dates, or due reviews, and
create a workspace. Inside a course, you can also browse materials, add documents,
or start a new chat. Switching workspaces saves your existing chat draft.

## Start reading

1. Create a workspace or connect Canvas.
2. Import a PDF, image, notebook, Office document, or readable text/code file.
3. Open a reading and ask in the tutor beside it. Select text to attach a passage,
   or use the viewfinder to ask about a PDF figure. Pasted images can be attached
   to a question too.
4. Choose **Explain**, **Practice**, or **General**. Explain includes step-by-step
   guidance. General supports ordinary conversation and complete solutions without
   the teaching restrictions, while retaining course context. Source buttons beneath an
   answer return to the cited page or section.

Open **Memory & files** in the web tutor, or the brain button in the native tutor,
to save workspace notes and up to 24 reference files. They remain available in new
conversations and after reopening Scholia. Each assignment has its own memory;
assignment chats also inherit the parent workspace's memory. Notes from other
assignments stay separate. Import a document into the workspace, then pin it here
to include relevant text excerpts with future questions. Existing Guide me
conversations become Explain, and old Chat conversations become General.

You can also attach files directly to a question. Drop them onto the chat sidebar
or use the paperclip; the Mac app accepts Finder/Spotlight files and project
folders. Simulink `.slx` packages and `.mdl` definitions expose static model
structure, with missing dependencies and unreadable parts disclosed. Unknown
formats stay attached with an explicit contents-unavailable status.
**Document context** in the native reader (**Reading context** in the browser) names
the open document, anchors the answer to the page you are reading, and searches the
full indexed document for relevant evidence, including distant pages. Local questions
stay compact; short follow-ups retain their topic, and overviews cover later chapters.
**Whole document · all text** sends every page's extracted text when it fits and
discloses unreadable pages. In course or assignment chat, the switch is labeled
**Course context** or **Project context**. **Inspect** shows the pages actually supplied
for the last answer, file status, and saved-text previews. New reading chats use the open
document by default; a separate course-library switch adds other saved readings and
workspace memory. The native **Use open document for this question** action carries a
course-chat draft and attachments into the visible document's conversation while
preserving other drafts. Attachment information buttons explain partial reads and
list actual omissions and original source paths. Files and folders have distinct
labels. Large extracted attachments retain full text outside the inline preview;
question-specific retrieval and paginated attachment reads can reach later sections.
The draft refresh button re-reads the source to recover older truncated snapshots,
preserving existing evidence if the read fails or is cancelled. Turning off
saved-source context keeps explicit attachments, selections, and the existing conversation.

The compact PDF selection popover accepts **Explain** without a comment, including
the first question in a document with no previous conversation.
On Mac, **Explain** opens a response popup beside the passage and streams the
answer there without opening the sidebar. The popup includes formatted text,
math and code, source links, **Stop**, and **Copy answer**. It uses the selected
model and document context, and the answer remains saved in the study conversation.
Choose **Open in chat** in the response popup to continue in the sidebar.
**Open in chat** brings the selected passage into the sidebar and focuses the
composer, preserving an existing draft. A passage alone enables **Send**; the
saved question includes the quote and uses the document's context. Background
Canvas downloading does not block these controls.

**Continue reading** restores the page and conversation for a reading you have
opened. Downloading a file does not mark it as read. In the Mac app, Back and
Forward (Command-[ and Command-]) return through reading destinations while
preserving drafts. **Dashboard** returns to the workspace library.

Drag the divider between the reader and tutor to give either more room. With a
document open, the tutor can occupy almost the entire window; the native reader
then shows an **Expand** control. The website also supports arrow keys on the
focused divider and a double-click to restore the usual chat width.
On Mac, drag the right edge of the left course library to resize it. Its width
is remembered when you reopen Scholia; the library toggle still hides and shows it.

Choose **Ask about this course** to open a compact conversation directly beneath
the course buttons. Collapse it when you want more room for materials; longer
conversations scroll inside the box. Course conversations include saved course details, material titles,
assignment deadlines and submission status, plus relevant excerpts from saved
readings. The starters help with a course overview, upcoming work, or a study
plan. **Whole course** identifies the active scope; opening a source keeps that
conversation and its draft. Reading and assignment conversations have their own
drafts. Unopened materials provide metadata only, and incomplete catalogs or
missing text are identified in the context. Refresh Canvas for current details.

The composer shows the selected reasoning mode beside the model when the model
supports a choice. Select a level there to apply it to subsequent questions.
This works in the Mac app, its local website, and hosted web accounts; unsupported
models do not show a reasoning selector.

Choose **Auto study** in the composer to select a model for each question. For
OpenAI and Codex, it prefers GPT-6 Luna with low reasoning for recall, explanations
and summaries, GPT-6.1 Sol with medium reasoning for worked problems, and GPT-6
Astra with high reasoning for proofs, derivations and synthesis across readings.
This is a starting policy based on [OpenAI's model guidance](https://developers.openai.com/api/docs/guides/model-selection),
not a benchmark of study accuracy. A local rule-based classifier considers the
question, short follow-ups and context size without an extra model request.
The selected model and reason appear with the answer.

**Fast** and **Deep** fix the routing tier; **Choose model** / **Manual** use the
model and reasoning level you picked. Your manual choice is retained when you
switch modes. Routing stays within the current provider, supports OpenAI/Codex
and Anthropic/Claude Code, and uses available catalog choices (verified models
on Mac). Other providers and unavailable routing tiers retain your selected
model and report why. Existing accounts start in manual mode. Provider access
and charges still apply to the model used.

Course materials default to **Organized**, using Canvas modules, page sections,
and folders where available. Files linked inside a Canvas page stay with that
page in its module's teaching order. Choose **All files** for a flat, searchable list of files with
original filenames. This choice is remembered per workspace. Generated
assignment descriptions and Canvas pages remain in the organized view rather
than appearing as duplicate files.

Canvas pages, syllabi and assignment imports retain their original HTML and
hyperlinks. **Original page** shows the saved page structure, with **Reading view**
available beside it. Clicking a known course link opens its saved original PDF
or document in Scholia, or downloads it if needed. External links remain normal
links, and **Open source** opens the Canvas page in your browser. Embedded document
previews offer an explicit document link. Scripts and active embedded content do
not run in the reader.

In the Mac app, course links that request a new window still open in Scholia.
Links inside PDFs, notebooks, assignment instructions and tutor answers use the
same course-document navigation, so Back returns to the reading you came from.

The Mac app checks every PDF page for scanned or image content and runs on-device
OCR, including PDFs with an old invisible OCR layer. Clear digital text is retained;
reliable recognition replaces obsolete invisible text rather than appending a
second garbled copy. The original PDF stays unchanged. Saved older indexes refresh
when opened or used for practice, with page progress and resumable checkpoints.
The resulting text is used by document search, library search, the tutor and course
practice. Pages that cannot be recognized keep their existing text and report the
limitation.

Older imports that discarded hyperlinks recover unambiguous file links from the
course catalog immediately. Opening an old page also requests its original HTML;
an unchanged Canvas version does not prevent this format upgrade. Local edits
are preserved separately. The existing saved page remains readable if Canvas
cannot be reached.

Each course card also offers **Practice course** for concept understanding,
active recall, application problems and exam-style questions. Course sessions
work through saved material and show coverage, concepts to revisit and missing
downloads. See [practice and review](PRACTICE.md) for feedback and progress details.

When Canvas provides no grouping, saved files use document headings, text sampled
across the file, and file metadata. Recognized headings provide topic subheaders
and can be searched even when a filename is uninformative. Files with conflicting or insufficient evidence remain under
**Documents**; remote files use metadata until they are downloaded. Analysis
is cached with the file rather than repeated during navigation.

## Assignments

Open **Assignments** in the sidebar for a dedicated page across all workspaces.
It starts on **All assignments**, with **Upcoming** work first, followed by overdue
work, **Handed in · awaiting grade**, and **Graded** work. Assignments that have not opened yet are included.
Submitted, graded, excused, hidden, and non-upload assignments remain in this
complete list. Course assignment lists also start on **All assignments**.

The dashboard agenda spans workspaces independently of the workspace search and
semester filters. **Due & overdue** shows outstanding work; **Handed in** shows
submitted work awaiting a grade; **Graded** has its own filter and count. **All assignments**, **Archive**, and **Hidden** keep the other
states accessible. Date headers group assignments with the same local deadline
inside the list. Each course also has its own assignment list.

An assignment's badge distinguishes **Handed in · awaiting grade**, **Graded**,
**Not handed in**, **Excused**, and **Status not synced**. Missing submission data
is not treated as proof that work is outstanding. While Scholia is open, assignment
deadlines, status and posted grades refresh automatically about every two minutes, and are
checked on return to the app when due. The local website also runs these checks
when the native workspace window is closed. **Refresh status** on the Assignments
page checks immediately. These lightweight checks do not download
course files. A failed check keeps the last successful status and retries later;
**Refresh course catalog** in the Mac library's Canvas options still performs a full catalog refresh.
Opening an assignment also checks its current deadline, even when its instructions
and files are already saved. If that check fails, saved work remains readable with
a deadline warning. The Mac app reconciles the generated deadline in older saved
instructions and tutor context with the latest assignment metadata. Optional
feedback failures do not discard a successful deadline response.
Automatic wiki and course-file checks wait for an active deadline refresh to
finish, so they cannot repeatedly interrupt checks partway through a large library.
Posted grades appear alongside the status, including points, percentages,
letter grades, and complete/incomplete grades. Unpublished grades stay hidden.
The Canvas workflow flag alone does not count as a published grade. A grade from
a previous attempt also leaves the current submission awaiting a grade. Visible
comments, feedback attachments, or media from someone other than the student, and posted rubric assessments, are
marked **Feedback available**. The assignment's **Feedback** section displays the
reviewer's comments, author, date, and rubric results directly in Scholia. The
PDF focus toolbar also has a **Feedback** button. Earlier comments remain readable
with an earlier-attempt label, without marking the current attempt as reviewed.
Own comments and feedback tied to an earlier attempt do not trigger this badge.

Open feedback attachments in Scholia's document reader. Their downloads use the
authenticated Canvas file API, and saved comments, rubrics and opened files remain
available offline. Expiring download URLs are not saved in the library. Feedback
refreshes with assignment status and can be refreshed from its own panel without
downloading course materials again. Failed refreshes keep the saved feedback;
an explicit empty Canvas response removes deleted feedback. Audio/video comments
that Canvas serves as media links can be opened in Canvas from the comment.

Use an assignment's **Status** menu in the Mac app to correct its progress locally: handed in,
graded, or graded with feedback. These course-specific choices survive refreshes
and restarts and never change Canvas. **Use Canvas status** clears the correction.

Clicking an assignment opens its instructions and the first explicitly linked
Canvas PDF in Scholia's reader. **Included files** lists every linked file;
choose one to read it while keeping the assignment open. This includes readable
simulation inputs and data such as `in.nanowire` and `Ni.eam`, as well as PDFs.
Collapse **Included files** to make more room for the reading. The website
remembers that choice separately for each assignment.
Assignments without a linked PDF show their instructions and included files.
Saved instructions and downloaded files remain available locally in the Mac app.
A failed download offers Retry without discarding saved material.

On Mac, an assignment PDF opens in a focused reading view with **Assignment chat**
beside it. **Assignment overview** brings back the instructions, file list, and
course library; **Focus PDF + chat** returns to the focused view. The compact
**Included files** menu switches attachments without leaving the assignment.
Switching views keeps the current PDF page, conversation, and unsent draft.

Saved conversations are listed in the sidebar; hover one to delete it, or use
the trash button in the chat header for the open conversation. The workspace
options button (**⋯**) opens a panel with favorite and preload switches, rename,
saved companion chats to bring in, and removal. On the Mac, the companion's
**Saved chats** button opens a list where each chat can be opened or deleted.

The chat column keeps its header to one line: the mode picker and a context
chip such as **Document · p. 12** or **Course context**. Click the chip to see
what the next question will include, switch document or course context off,
add the course library and memory, or ask about the course instead. The
message box starts one line tall and grows with what you type. The reader
centres a fitted page and stays on the current page when its width changes,
for example when entering focus.

Any open document can take the whole screen for a lecture: press the focus
button in the reader toolbar, **⌘⇧F**, or **View → Toggle Document Focus**. The
Mac app hides the sidebar and top bar, enters full screen, and keeps the chat
beside the reading. **Esc**, the green window button, the shortcut, or the same
toolbar button return to the normal layout; opening the dashboard, assignments,
or exam dates also leaves focus. Switching chats or documents keeps it.

Opening an assignment prepares its linked files for the study companion.
Instructions and readable attachment content receive their own context budget,
even when **Include relevant course materials** is off. File labels distinguish
ready content from files that still need to be opened or have no readable text.
Automatic preparation covers up to 50 files, 20 MB each and 50 MB total; open
larger supported files individually. Unsupported binary files retain their
original for viewing, with no claim that their contents are readable by the tutor.

Choose **Hide** to keep an assignment out of your usual lists. **All assignments**
shows the complete list, including hidden items, in both the sidebar and each
workspace. The **Hidden** filter shows only hidden items. Choose **Unhide** in
either view to show an assignment in your usual lists again. This changes only
your Scholia list; it does not delete the assignment or alter a submission. The
separate Canvas link opens the original assignment when you need to hand in work.

## Exam planner and Studentweb

Open **Exam dates** from the Mac app or website dashboard/navigation. In the
extension, **Exam planner** opens your study website; configure its address in
extension settings. For the local Mac website, first choose **Open in Browser**
(Command-2). A hosted website uses its usual account sign-in.

The schedule stays inside your workspace, with chronological date cards and
side-by-side comparisons of overlapping exams. **Keep [course]** shows which
course and selected components will be set aside before you choose. **Undo last
change** restores your previous plan. **Course selection** includes courses
set aside, so you can reconsider them. **Select all** selects every exam component;
**Clear selection** clears them, and both actions support undo. Selected courses
with complete or flexible timing and no fixed-time overlaps
are automatically favorited; those automatic stars follow later plan changes,
while favorites you set yourself are preserved.

Use **Manage dates** to edit or import dates in the same workspace. In the Mac
app, choose **Sign in to Studentweb**. A temporary WebKit window opens
the official Studentweb site. Sign in yourself and stay on the opening page.
Scholia reads only visible exam rows in **Kommende hendelser / Upcoming events**.
It never opens **Aktive emner**, expands hidden details or follows course links.
Each opening-page row remains a separate entry, including multiple components
of one course, hand-in deadlines, exam release times and exam periods. The import
shows the number of entries read against the number of visible source rows.
Choose **Review exams**, correct the fields and select the exams you intend to take.
A direct import replaces previous Studentweb entries in the preview, preserving
manual entries, selections and flexible/fixed timing choices for identical exams. Dates absent from the opening
page cannot survive from an earlier import. Choose **Save plan** to keep the refresh.
The Mac-backed website can open this same importer; reload its saved plan after
saving in the Mac app. Hosted websites retain the paste/file import workflow.

Alternatively, copy the opening page's exam rows into **Paste details** / **Paste dates from
Studentweb**, then preview and correct the course, exam component, date, and times.
The website also accepts text, CSV/TSV and ICS calendar files. You can always add
or edit an exam manually, including dates not yet announced. The editor defaults
to chronological **Date order**; **By course** groups midterms and finals together.
Select each exam you intend to take and choose
**Save plan**. A selected date is a personal planning choice; Scholia never
registers for or withdraws from an exam.

On Mac, expand **Course selection**, then expand any course with multiple exams.
Each component has its own checkbox and date, so you can select only a midterm,
only a final, or any combination. The course shows how many exams are selected;
**Select all** and **Clear** inside its dropdown apply only to that course.
Individual selections save immediately and support **Undo last change**.

Only selected exams are checked for conflicts. Known overlapping intervals show a collision;
overlapping dates with incomplete times show a possible collision. Missing dates
or times are marked as incomplete, and back-to-back known intervals do not overlap.
For an exam whose timing can be agreed with your professor, choose **Mark timing
flexible** in its overlap card, or enable **Flexible timing · agree with professor**
in Manage dates. Both exams stay selected. The original date remains visible for
reference, while the flexible exam is excluded from overlap checks and may be
included in recommendations. Oral exams default to flexible timing, including
existing saved oral exams and new imports. **Use fixed timing** restores overlap
checks; this explicit choice survives saving and matching imports. Flexible
exams remain labelled as needing an arrangement with your professor.
On Mac, a flexible pair disappears from **Make a choice** once both exams are
selected. If one was set aside, the comparison keeps its **Take this exam**
checkbox available until you select it. Both exams remain in your schedule;
restoring fixed timing brings any overlap back. These choices save immediately
and support **Undo last change**.
Times use **Europe/Oslo**, including when your device uses another timezone.
An overnight or multi-day exam needs its end date. A clear result only describes
time overlap; verify travel time and registration requirements separately.

Direct exam-date sign-in uses a separate, nonpersistent WebKit data store. Scholia's date importer
does not inspect login fields, store credentials in Keychain, or reuse Canvas
cookies. It runs only on Studentweb's HTTPS opening page (the root, `start.jsf`
or `forside.jsf`), in an isolated JavaScript world. It requires the upcoming-events
table and an explicit year in the row's date column or labelled assessment details.
Dates and times may be displayed beneath their labels. Hidden content, registration
and withdrawal deadlines, result dates and unrelated page dates are excluded.
Rows without an announced date remain incomplete; no date or duration is invented.
Only course codes and exam date/time/type tokens
cross into the planner; names, student/candidate numbers, grades and raw page
content are excluded. The import does not send content to an AI provider or Scholia's
hosted service. Closing the import window discards its temporary website data.
Studentweb and the identity provider still process their normal sign-in data.
Changes to Studentweb's markup can require falling back to paste import; the
planner never guesses missing dates or submits registration forms.

Paste/file imports are parsed on your device. Leave personal details out of the
pasted selection. Previewing does not save a plan; only
reviewed scheduling fields are persisted, with no raw pasted page or calendar
description. Repeat paste/file imports keep existing selections and skip identical
dates; changed dates are new candidates to review. Direct imports preserve the
number of source rows, even when several components have identical dates. Saving refuses to overwrite a
plan that changed in another window; reload the saved plan before editing again.
Local plans share the Mac library; hosted plans belong to the signed-in account.

The schedule's **Recommend exams** text box accepts your interests, background,
goals, required courses and desired workload. On request, the configured model
receives that text and the reviewed course titles and exam fields. The app checks
the returned ranking against the existing plan, keeps every component of each
chosen course, and excludes fixed-time overlaps or incomplete timing unless that
exam is marked flexible. Flexible exams are shown as arrangements still to make.
The model cannot add courses or generate exam dates. Review the explanations and
choose **Use this selection** to apply it; **Undo last change** restores the
previous selection. Changing the plan or your interests invalidates the suggestion.

Studentweb or the official course page remains the source of current exam details.
See NTNU's [exam information](https://i.ntnu.no/en-GB/eksamen) and
[registration guidance](https://i.ntnu.no/wiki/-/wiki/English/Register+for+courses+and+exams).

### Local course pass statuses from Results

In the Mac app, choose **Exam dates → Studentweb results…**, or **Studentweb
results…** in the workspace's options menu. That action opens NTNU Studentweb,
starts its Feide sign-in when needed, opens **Resultater / Results**, and saves
the course pass statuses automatically. Choose **Use ID and PIN** to sign in
directly on Studentweb instead. Scholia never reads or saves either login field.
An existing sign-in is reused while Scholia is running; a new sign-in can still
require credentials or MFA. The native list
contains only course codes and **Passed / Not passed**. Use **Check Studentweb**
to update again, **Delete** to remove a status, or **Forget sign-in** before
connecting another account. Forgetting sign-in does not delete saved statuses.

Saving replaces the previous snapshot; it never combines different sign-ins or
institutions. It checks the visible whole-course table: hidden, collapsed and
paginated rows are not fetched or expanded. Codes are matched exactly, apart
from the library's semester suffix. Check that they belong to your current
institution; identical codes from different institutions cannot be distinguished
without storing extra identifying information.

The importer only recognises complete-course table rows with an unambiguous code
and result. A–E and explicit Norwegian/English pass labels become `true`;
F and explicit fail labels become `false`. See NTNU's
[grading scale](https://i.ntnu.no/wiki/-/wiki/English/Grading%20Scale).
Pending, missing, numeric, exempted or unknown results are omitted, as are partial
assessments, approved compulsory work and the separate **Deler der samlet resultat
ikke er beregnet** table. A whole-course pass counts even when credits are blank
(often a retake) or zero. Omission means **unknown**, not failed. A passed complete
attempt wins over a failed retake within the same read. The automatic check waits
for two matching nonempty snapshots, with bounded retries. Empty or unsupported
pages keep the previous saved statuses; deletion is always an explicit action.

Passed courses get a native workspace label and can be hidden with **Hide passed
courses**. **Select unfinished courses** skips passed courses when adding exams
to the selection, retaining any retakes you already selected explicitly. Native
recommendation selections remove passed courses **after** the AI response, on
your Mac; this can reduce the suggested workload. You can still select a retake
manually. **Get advice** in the Mac app includes the current passed-course codes
in each question and follow-up, including courses outside the exam plan. The
selected model receives these codes as completed background; failed results,
grades and identity are excluded. The chat shows which passed courses are
included. Missing courses remain unknown, and an unreadable Keychain record
stops the request instead of silently omitting it. Updating or deleting statuses
affects the next advice request. Importing or deleting statuses does not alter
your existing exam plan, favorites or courses.

The saved record contains only `{courseCode, passed}` pairs in a separate,
non-synchronizing macOS Keychain item per local library. It is excluded from
`library.json`, the local web API, hosted Scholia, search indexes and exports.
Native **Get advice** is the explicit exception for provider input: it sends only
the passed-course codes. Other provider requests do not read this record.
Studentweb grades and personal details are reduced inside
WebKit before the bridge returns; no transcript, raw page, screenshot, login
field, cookie, result date, attempt count or course name is imported or logged.
Extraction follows a user-started check, is limited to the main frame at
`https://fsweb.no/studentweb/resultater.jsf`, and never calls a private results API.
The browser disallows transcript downloads. Closing cancels pending reads and
clears non-cookie website data. Cookies stay inside a per-library, nonpersistent
WebKit store for this app run; they are never copied to native storage or shared
with Canvas, the user's ordinary browser, or another local library. **Forget
sign-in** replaces and clears that store. Quitting discards it. Results are
processed behind a native progress view, hidden from both display and native
accessibility. Sign-in pages are shown only when needed.

The request flow first sends a normal GET to Results. If sign-in is needed, it
loads the [official NTNU login](https://fsweb.no/studentweb/login.jsf?inst=FSNTNU)
and invokes the existing Feide form's handler. **Use ID and PIN** keeps the
official login page open for manual entry and disables automatic Feide routing
for that check. The official forms' JSF POST, view state and sign-in redirects
remain entirely inside WebKit. No password filling, token extraction,
authentication replay or Scholia authentication proxy is involved. After the
Studentweb landing page loads, a GET opens Results. Navigation attempts are
bounded; a changed login form falls back to manual sign-in in the same window.
This relies on [Feide's session-based SSO](https://docs.feide.no/general/feide_overview.html),
not persistent login credentials. Studentweb and the identity provider necessarily
handle the HTTPS sign-in and page requests themselves; results processing and
Scholia's saved record stays on the Mac. Submitting native advice sends its
passed-course codes to the selected provider, which may be remote. Deleting local
statuses cannot retract earlier advice requests or copies in the conversation.

For an explicitly requested live check, run `npm run check:studentweb:live` and
sign in directly in its private Chromium window. This manual tool runs the same
results extractor and reports only schema checks and aggregate counts. It does
not import statuses, record credentials, capture screenshots, trace requests or
save page content. Enter `refresh` to verify session reuse and `stop` to close
Chromium and remove its temporary profile. Automated checks use fabricated
results and never require a real login.

Statuses remain until you replace or delete them. Use **Delete** beside a course
or **Delete all saved statuses**; deletion also works if a stored record is
unreadable. Keychain failures retain the previous saved record and show a generic
error. Deletion removes Scholia's live record, not historical operating-system
backups; local Keychain protection does not defend against a compromised Mac.
The app does not sync this record to iCloud. Exam selections you explicitly apply
still use the existing shared exam-plan storage and provider workflow.

Verification uses synthetic records only:

```sh
node --test tests/studentweb-results.test.js tests/studentweb-sign-in.test.js tests/studentweb-extraction.test.js
npm run smoke:chromium:studentweb-results
npm run smoke:macos:studentweb-results
```

### Degree plans for advice and course lookup

The public NTNU catalogue includes **admission cohorts 2009–2026 for MTTK and
MTNANO**, with **2023 as the default for both**. It reads the same unauthenticated
year-list and study-plan JSON resources as NTNU's
[study-plan page](https://www.ntnu.no/studier/studieplan). Every course group and
specialisation branch in those responses is imported. The **2023** snapshot has
semesters 1–8 for both degrees; semesters 9–10 are explicitly missing. Publication
coverage varies by cohort. Missing requirements are never filled from another cohort.
In native or browser **Get advice**, the compact degree controls show an
**admission-year selector for each programme**. Both selected cohorts are available
for a comparison; being available does not mean the student is enrolled in both.
**Optional study focus** is collapsed by default and lets the student suggest a
study year, semester or specialisation/profile. These are retrieval hints; the
model can still check relevant foundations in other years. Changing admission
year resets the profile. **Use degree plans for advice** turns curriculum context
on or off. Controls are fixed during a request. Choices stay in the open advice
panel and are not saved as enrolment records or synced with Studentweb.

The canonical local file is `packages/core/data/ntnu-study-plans.json`. It is
bundled with Scholia, so advice and lookups do not fetch NTNU pages at runtime.
Course definitions, choice rules, course groups and direction nodes are separate
dictionaries, deduplicated by content. A plan is keyed by `programme:admissionYear`
and each semester points to its direction tree. Choice status belongs to a
course's group membership: a compulsory course in one branch does not become
compulsory in every branch. Practice and other plan elements are retained as
requirements, not presented as exam courses. Group descriptions and minimum
choice rules are preserved.

JavaScript's `StudyPlanIndex` and Swift's `StudyPlanIndex` build hash indexes once
for exact course-code, programme and study-year lookup. `semester()` in JS and
`year(..., term:)` in Swift narrow a year to autumn or spring. Advice uses a
provider-independent, two-step retrieval workflow:

1. The selected model receives the question, conversation and exam context, plus
   a small index of the selected cohorts (degree names, years, publication coverage
   and branch paths). The native advice action also includes current passed-course
   codes. No full curriculum is attached at this stage.
2. The model selects bounded JSON lookup commands: `overview`, `courses` (up to
   20 exact codes) or `year` (one study year, optional semester and profile).
   Scholia validates the commands and resolves them against the stored index.
3. The model receives only those results and answers the original question.

For “exam X in MTTK or exam Y in MTNANO given my passes and progress?”, the model
can request both course placements, relevant year requirements and placements of
passed courses. The answer should compare foundation gaps and progression without
inventing prerequisites, enrolment or degree-completion percentages.

The admission years are locked to the selectors; lookup commands cannot change
cohort, read files, request URLs or perform network calls. At most eight lookups
and 80,000 characters of retrieved reference are accepted per turn. Invalid or
overly broad lookup plans get one repair attempt; another failure stops advice
instead of attaching the entire catalogue or displaying the planning response.
Cancellation and changes to exam dates or native pass records are checked between
model calls. Every follow-up plans its lookups again using the current cohorts and
current passed courses. Shared/ancestor requirements remain included for a profile;
unpublished semesters and unmatched codes remain explicitly identified.

The browser loads only small public selector metadata. Course definitions stay on
the local/hosted advice service until retrieved. Source links, cohort, fetch time
and publication coverage accompany results. Public degree retrieval also supports
hosted advice; private Studentweb pass statuses remain unavailable to the web API
and hosted service.

Add programmes, default admission years and their verified nominal duration to
`packages/core/data/ntnu-study-plan-sources.json`, then refresh and rebuild:

```sh
npm run import:study-plans
npm run build:web
node --test tests/study-plans.test.js tests/study-plan-retrieval.test.js tests/hosted-exam-recommendations.test.js
```

The importer discovers actual admission cohorts from NTNU's read-only year list
(not from academic publication years), uses bounded public GET requests without login cookies, records
source checksums, and replaces the catalogue only after every configured plan
has been fetched and validated. It never calls NTNU's update or sign-in routes.

## Canvas and downloads

On the Mac, **Sign in** and the local website's **Reconnect Canvas** first check
the saved token or session without opening a window. Canvas opens in a native
WebKit sheet only when the saved login has expired. Network failures keep the
last successful assignment state and display a refresh error. Closing the
sign-in sheet does not stop later status checks. Scholia uses that session
without reading your institutional password. Each request uses current
Canvas cookies, and renewed cookies are synchronized back to the sign-in window.
Only cookies scoped to the Canvas host are archived in this Mac's device-only
Keychain, with expiry controlled by Canvas rather than a local time limit. SSO
cookies are excluded from that archive. Cookie saves are serialized, and a
background Keychain save failure does not invalidate a working Canvas session.
**Disconnect** clears the archive and
Canvas cookies. If a saved personal token has expired, Scholia also checks the
saved browser session before opening sign-in. A verified browser session replaces
that expired connection. You can also connect
with a personal access token, stored in Keychain. Hosted web uses a personal
Canvas token saved to your account; its operator chooses the allowed Canvas
hosts. Expired credentials need to be renewed before new material can download.

Saved-session checks and cookie renewal run without Keychain prompts and off the
main thread. If macOS requires permission to read a saved login, cached work stays
available; choose **Allow Keychain access** on Mac to grant access. Completing
browser sign-in also saves the renewed session with permission to access Keychain.

Local development builds may need **Always Allow** again after an update: the
file keychain additionally checks the app's changing code fingerprint, even when
its local signing certificate stays the same. Apple-issued development or
Developer ID signing uses a stable team identity for that check. See
[signing and permissions](../apps/macos/README.md#signing-and-permissions).

**Index all courses** lists accessible courses and catalogs their materials
without fetching every file. Favorite workspaces stay at the top. Canvas stars
are imported until you make a local favorite choice; Scholia never changes the
Canvas favorite or course data.

The PDF reader has a visible **Download** button; other documents show
**Save a copy** in the reader toolbar, beside the light/dark reader, print, and
open-original buttons. Downloads and saved copies use the original uploaded or
Canvas filename. Older files without a saved filename
use the course code (or course name) and document title. On Mac, choose a
destination in the save dialog.

Opening an online material downloads that item. **Download all** fetches a
course's supported materials; **Download everything** covers the catalog. Stop
keeps completed downloads, and repeated downloads reuse unchanged saved items.
**Update content** on a course checks the full catalog and downloads new or
changed files, pages, assignments and the syllabus in one action. Unchanged
downloads are reused; locally edited versions are preserved separately. The
refresh icon on each course card performs the same update.

**Settings → Courses → Automatically update course content** enables the same
check-and-fetch operation every five minutes for current-semester courses,
favorites, and the open course while the native or local browser workspace is
open. This global preference is saved across restarts and is also available in
Canvas settings. It is off initially; turning it off stops an automatic update,
and manual course updates remain available. Failed work stays available to retry.

Choose a course under **Update a course**, then **Update now**, in Settings →
Courses or the Canvas window to run an update manually. If downloads are already
running, **Queue update** schedules that course after the current work finishes.
The control shows **Queued** or **Updating…**; repeated clicks do not add duplicate
work. **Stop** also clears queued manual requests. These updates use the selected
download priority and work with automatic course updates switched off.

**Check for changes** refreshes metadata, preserving conversations and local
edits and flagging new versions. Partial collections retain their older entries
when Canvas cannot be checked.

Catalog refreshes follow links inside Canvas pages and assignment descriptions,
including nested course pages, PDF preview frames and notebook attachments.
Accessible linked files are discovered even when the course Files tab is
disabled. **Download all** saves these originals and indexes their contents for
offline reading, search and tutor context. Repeated links share one saved file;
page and file requests still respect Canvas access restrictions.

MA and TMA courses at NTNU also check `wiki.math.ntnu.no` for the semester saved
on the course. Scholia follows that semester's teaching pages, menus and linked
files, including staff-hosted notes and past exams explicitly assigned there.
It does not substitute the newest semester when the requested archive is missing.

Math wiki updates run separately every **two minutes** while a workspace is open,
for current-semester courses, favorites and the open course. They work without
Canvas credentials. Conditional HTTP requests reuse unchanged pages when the
server supports validators; only new or changed materials are downloaded.
Attachment metadata is rechecked every five minutes, or immediately when its
teaching page changes. Failed checks retain saved materials and back off from the
normal interval up to one hour after repeated failures. **Settings → Courses → Automatically update math wiki**
is on by default and can stop these checks independently of Canvas updates.

Canvas and math wiki also learn publishing patterns separately for each course.
A local Gamma–Poisson model estimates changes per observed hour, by time of day
and day of week (Europe/Oslo for NTNU). It needs at least eight hours of observed
coverage, changes on three distinct days, and an active window with at least
three times the overall change rate before adding checks. Older evidence decays
with a 28-day half-life. Initial imports, gaps longer than 30 minutes, incomplete
catalogs, student grades/submissions, and synthetic file cache versions do not
teach a publishing pattern. The model learns as the workspace stays open; it
does not make training requests or send data to an AI service.

The regular two-minute wiki and five-minute Canvas schedules remain. Predictions
may add a check halfway between regular checks, at most once an hour and twice
per course/source in a rolling 24 hours, with eight extra course checks total
across the workspace. These limits count catalog checks, each of which may need
several HTTP requests. The history and budgets survive restarts. Nearby checks
are coalesced, unchanged downloads are reused, and extra Canvas checks skip public
sites (which keep their own regular checks). Each source's existing automatic
update switch also controls its predictive checks. Manual updates still work
immediately and also contribute observations.

For all courses, catalog refreshes check Canvas announcements (including older,
paginated announcements), syllabi, pages and module links for a dedicated course
website. Confirmed teaching sites are crawled within their course directory;
ordinary references and staff profiles do not become new course websites.
When Canvas does not link a teaching site, Scholia also checks verified course
homepages. **TDT4120** uses **[algdat.idi.ntnu.no](https://algdat.idi.ntnu.no/)** for
lecture slides, the syllabus booklet, exercise information and public past exams.
This works with Canvas semester codes such as `TDT4120-26H`. A course-provided
teaching site takes precedence; an old-exam archive alone does not suppress the
official homepage. Choose **Update now** in the course to fetch it, or let normal
course-content updates run. Website downloads are searchable alongside other
coursework. Immediate HTML page redirects are followed; private exercise systems,
queues and sign-in pages stay out of the material library.
Wiki and website pages/files join the same course library and download controls
as Canvas materials. Source links remain attached, and repeated URLs do not
duplicate entries. Canvas credentials are never sent to these public websites.
Missing, inaccessible, or incomplete websites retain previously discovered
materials and report a warning. Sites requiring JavaScript or a separate sign-in
may still need to be opened in a browser.

For a smaller manual update, **Check for new files** checks file lists, modules,
and links within pages and assignments using conditional metadata requests.
Every metadata page is checked so newly visible files are found even when their
upload dates are old. The library button checks displayed courses; the same
operation is available in a course's **All materials** menu and context menu.

Only file IDs discovered since the saved baseline enter the new-file download
queue. A course's first index establishes that baseline without downloading its
history. Older on-demand materials, edited local copies, and already saved files
are skipped, even if their Canvas metadata changed. **All materials → Download
all materials** remains available for a complete download or updated versions.
Failed and interrupted new-file downloads keep their queue across restarts, and
successful files are removed as they finish. Opening a queued file manually also
removes it from the queue. Current download-priority settings apply to these
transfers. **Stop** keeps completed files and the remaining queue.

Each course shows its last file check, result, and any connection or download
error. Course checks retain saved metadata and pending work when access is
unavailable, and stay within the connected Canvas account. Turning off
**Automatically update course content** stops scheduled Canvas content downloads;
math wiki updates and assignment submission and grade status checks have their
own schedules.

On Mac, bulk downloads default to **Background**, leaving room for active study
work. The Canvas window's **Download priority** control can switch to
**Prioritize downloads** and back while a download is running. Changes take
effect on active transfers immediately. Prioritized mode uses up to six parallel
transfers, skips pacing and study-activity pauses, and stops background preloading
so downloads can use the available bandwidth. Background mode returns to one
paced transfer after active materials finish safely. Canvas server limits and
your network connection still determine the maximum speed.
Choose **Done** to close the window and keep studying while downloads continue
in Scholia. **Stop** cancels active bulk downloads and keeps completed materials
and a saved checkpoint. The Canvas window shows the remaining courses and
**Resume downloads**; the paused job remains available after restarting
Scholia, and resumes only when you choose it. Resume checks the saved materials
and continues unfinished work for the same Canvas account.
Cached originals are checked against their saved hashes, with their page indexes
and referenced images validated before reuse. New downloads are staged and
validated before an atomic replacement; previous originals are retained in the
library's Revisions folder. Checkpoints advance only after the library is saved.
The Canvas window shows saved material counts, their total size, verified current
materials, and files needing repair. Expand the inventory for a course breakdown
and per-course **Update now** and **View files** actions. **Verify saved files**
checks what is actually on disk in the background, including downloads made
before this version; results survive restart.
Legacy files without a reference hash remain unchecked until a fresh download
establishes one. Catalog totals can grow as additional courses are checked.

The Mac can **Preload frequent courses** after three separate visits. Once the
course is idle for three seconds, it fetches at most three eligible files,
10 MB per file and 20 MB total. It pauses for active work, Low Power Mode, or
thermal pressure. Disable the option in the workspace menu or use **Stop**
during preloading. This setting is native; hosted web downloads when requested.

Material access is read-only. API pagination stays on the Canvas origin, and
file redirects lose Canvas tokens and cookies before reaching storage hosts.
Course identity is scoped by Canvas host and account. Download catalogs are not
represented as tutor-readable text until content has been saved and indexed.

## Reading and editing

The PDF readers provide selectable text, bookmarks, exact and semantic search,
page entry, continuous/single/spread layouts, zoom, figure capture, and printing.
The web reader refines the visible portion of a PDF directly from its vector
content at at least 2× density, subject to a bounded canvas budget. High zoom
does not have to enlarge a low-resolution full-page bitmap. Refinement updates
on scrolling, resizing, and display-density changes without replacing text
selection or annotation layers. Scanned images retain their source detail.
Native indexing uses on-device Vision OCR for images and every scanned or mixed
PDF page, including old invisible text layers. Hosted indexing can use local Tesseract OCR;
the Docker image includes it (see [Hosting](HOSTING.md)). OCR text
also contributes to file classification. Processing is bounded, and the
document notice reports incomplete coverage or unavailable OCR. Handwriting
and mathematical notation can be misread, so keep the original visible when
checking an uncertain passage. File organization does not send files to an AI
provider.

Notebooks retain Markdown, code, and saved outputs in a continuous reader. Text
and code preserve reading sections and indentation. Office readers show extracted
paragraphs, slide text, tables, and cached workbook values. The Mac's
**Original layout** uses Quick Look for formatting the semantic reader cannot
preserve. Notebook cells, macros, and formulas are never executed. Section
references in these formats are not necessarily printed page numbers.

**Edit** is available for supported text, code, and notebooks. Saving rebuilds
the tutor index and checks the original revision to avoid overwriting another
edit. Prior versions are retained for recovery. Editing changes Scholia's copy,
not the original file or Canvas. New Canvas versions preserve a locally edited
copy separately in the native library.

Each tutor turn has a fresh, bounded source snapshot. It includes the current
page or selection and relevant saved material from that workspace. Native
context can include the whole document when it fits, otherwise page references
and locally ranked excerpts. Hosted context is bounded separately. Inspect the
source list to see what supported the answer. A model does not automatically
see every image in a long document; explicit visual questions require a model
that accepts images.

## Practice and storage

The Mac and its local website include **Practice this** and **Review due**:
source-linked questions, attempts, hints, feedback, revisions, and delayed
review. See [Practice and review](PRACTICE.md). Hosted web offers conversational
**Practice** tutoring; it does not include the native practice-session store or
spaced review queue.

Native files, indexes, conversations, and reading positions are stored under
`~/Library/Application Support/Scholia/Study`. Workspace removal removes its
library entry while retaining imported files on disk for recovery. Native edit
drafts and revisions are also local. Hosted data is stored on the service's
persistent volume. See [Privacy](PRIVACY.md) for retention and operator access.

## Open in Browser

On the Mac, choose **Open in Browser** or press Command-2 to start the local
website at `http://127.0.0.1:8792`. Keep Scholia running. Native and browser views
share the current workspace, Canvas connection, provider configuration,
conversations, and reading position. Canvas sign-in opens the Mac's sheet;
provider setup stays in native Settings.

For a website that stays available without the Mac, use the separate account
service described in [Hosting](HOSTING.md). It has its own data and sessions;
it does not expose or synchronize your Mac library.

## Verification

```sh
npm run check
npm run smoke:macos:workspace -- --data-only
npm run smoke:macos:workspace -- --learning-only
npm run smoke:macos:workspace -- --assignments-preview --assignment-page-smoke
npm run build:web
node scripts/smoke-hosted-web.mjs
```

Native smoke checks use temporary libraries and deterministic Canvas/provider
fixtures. Browser checks use Chromium. See [Mac setup](../apps/macos/README.md)
if the installed Command Line Tools need an explicit SDK selection.
