# Practice and review

Structured practice and review are available in the native Mac app. Questions,
attempts, and review schedules are saved in its local learning store.

**Practice course** on each course card opens course preparation. Choose **Cover
the whole course**, **Revisit weak areas**, or the current reading/selection.
The four practice modes are **Understand concepts**, **Active recall**, **Apply
& solve**, and **Exam practice**. Add an optional topic focus. Sessions default
to three questions and accept up to twelve. Course sessions use one question per
selected source page and rotate through all readable saved documents and pages,
including documents beyond the first thirty. Short courses can produce fewer
questions than the selected limit. A failed source-coverage check rejects the
generated batch instead of silently concentrating on one reading.

The course overview shows material coverage and concept progress. It distinguishes
attempted pages, the latest independent correct answers, and pages to revisit.
Generating or finishing a session does not establish mastery. Changed sources,
assistance and disputed judgments cannot count as current independent success.
Missing downloads are shown with a course download action; unsaved or unreadable
material is not claimed as covered. These counts describe source pages practiced,
not exhaustive coverage of every concept on a page or a prediction of exam results.

**Practice this** still supports the selected passage or current page/section.
A selected figure is retained with its source. The Practice composer starter
opens setup without replacing the chat draft. Generation uses the configured
provider, happens only on request, and can be cancelled. Changing the reading
in the native workspace cancels preparation for its previous scope.

Recall keeps the source collapsed. Open-book practice records source access. A visual question retains its necessary figure. Three controls progressively expose a conceptual cue, a method cue and a partial step. **Show solution / worked example** unlocks after a saved attempt for that question in the current session. Describing where you are stuck is a valid starting attempt. Skipping to the recap does not unlock solutions. **Explain in tutor** opens Guide me at the originating source with your attempt, without revealing or attaching the private answer; tutor access is recorded as assistance while retaining the practice session. Neither scrolling nor ordinary highlighting triggers a quiz, and there is no timer.

**Save answer & get feedback** commits the original answer and optional confidence before contacting the provider. Feedback reports correct reasoning, the first material error or missing justification, and one next step. Judgments can be correct, partial, incorrect or uncertain. **Try again** preserves the first answer and appends a revision. **This feedback seems wrong** records a concern and marks the judgment unresolved; it is also available in the recap. A self-check after revealing the solution is recorded separately from model feedback. Feedback can be retried after finishing a session.

Questions and feedback identify the supporting document and page/section. **Open saved source** shows the bounded historical excerpt; **Go to source page** opens the current reading and records source access. The source hash and Canvas version remain attached to the original question and rubric. When a local edit, Canvas update or removal changes that identity, the question is marked as needing revalidation. Preparing a new session makes new question IDs; it does not replace historical criteria. Generated content is labeled as not independently verified.

## Review scheduling

Save selected questions during practice or in the recap. **Review due** is next to the reader/dashboard controls and includes recent sessions for resuming practice. The initial workload limit is ten completed reviews per local day, adjustable from 1–30. Snooze moves a question one day from now; saved questions can be removed from the queue without deleting attempts. There are no missed-day penalties.

Scheduler version 1 starts with a one-day delay. A correct first attempt without hints, source access, reveal or revision doubles the previous interval, with a minimum of three and maximum of thirty days. Assisted or incomplete reviews return after one day. Uncertain/disputed judgments, missing feedback and stale sources preserve the interval. Self-assessment alone does not establish independent recall. Confidence does not control the schedule. One finish event updates a review once; repeated requests and delayed feedback do not advance it again. These intervals are initial product parameters, not universal learning prescriptions.

## Persistence

`Study/Learning/events.sqlite` is separate from `library.sqlite` and chat history. SQLite transactions append uniquely identified events and reject a stale writer. A retried event must carry the same ID and content. Session versions protect concurrent actions; review versions protect snoozes/removals. Source snapshots, question revisions, attempts, feedback, concerns and schedule evidence are local by default. No research telemetry is collected.

Reference answers stay hidden until an explicit reveal after a saved attempt.
Generated text can still leak an answer indirectly, so model behavior requires
evaluation beyond application checks.

Saved questions, hints, solutions, attempts, and scheduling work without internet
or a provider. Automatic feedback and new questions require a provider; failure
leaves the answer saved for later feedback or self-check. Unsent answer drafts
are local and scoped to the library, session, and question. Changing provider or
model does not reset a session.

## Verification and remaining evaluation

Run:

```sh
npm run check
zsh scripts/smoke/macos/run.sh workspace --learning-only
zsh scripts/smoke/macos/run.sh workspace --data-only
zsh scripts/smoke/macos/run.sh workspace
```

The native smoke uses an isolated library and deterministic generation/feedback.
It checks original/revised answers, confidence and assistance, hidden solutions,
disputes, self-checks, source versions, restart, duplicate events, competing
writers, scheduler outcomes, and offline/late feedback. No live provider
completion or Canvas account is needed for these checks.

Before broad educational use, evaluate actual responses from each offered provider/model with correct, partial, mistaken and ambiguous answers; equivalent mathematics and reasoning; non-English answers; explicit reveal requests; repeated difficulty; noisy OCR; missing pages/images; and indirect answer leakage. Check source support and question solvability manually. The first release provides structured partial/uncertain judgments but does not implement symbolic equivalence, numerical-tolerance grading or semantic proof that a generated rubric is correct. These remain evaluation/validation work. No learning-outcome improvement is claimed without a delayed, unassisted evaluation.

Worked-example fading, a curated concept bank and adaptive curriculum plans remain
separate work. Concept progress here is evidence from generated questions and
dated attempts. Extension structured practice and extension/native handoff also
remain separate work.

## Tutoring contract

Explain, Guide me and Practice share a system-level learning boundary: Scholia
helps with concepts, source passages, prerequisites, reasoning checks and small
analogous examples. It does not write complete assigned solutions, answer lists,
proofs, code or essays, including requests to solve an entire PDF. Switching
modes, claiming permission or repeatedly requesting the next step does not relax
that boundary. A redirect should offer a useful starting point without blaming
the learner. Ordinary reading, summaries, translation and correspondence remain
directly supported.

Explain teaches ideas directly; Guide me adapts one hint or partial step to the
learner's attempt; Practice waits for an answer and gives specific feedback.
Internal practice generation creates different questions from assigned source
problems and stores private reference answers. Feedback cannot disclose the
full answer. The native and JavaScript prompt contracts have parity tests;
provider requests carry the chosen mode as a system instruction on every turn.
The reveal gate is enforced by the practice services, including recap requests,
while historical events remain replayable. Prompts alone cannot guarantee every
provider's behavior; use the evaluation cases below when changing models.
