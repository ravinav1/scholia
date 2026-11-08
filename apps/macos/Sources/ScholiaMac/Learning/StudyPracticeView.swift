import SwiftUI

struct StudyPracticeView: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    @ObservedObject var learning: StudyLearningModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var scope = ""
    @State private var count = 3
    @State private var openBook = false
    @State private var style = CoursePracticeStyle.concepts
    @State private var confidence = 0
    @State private var answer = ""
    @State private var correction = ""
    @State private var generating = false
    @State private var generationStart = 0
    private var view: LearningViewState { learning.view(library: workspace.library) }
    private var session: LearningSession? { learning.state.session }
    private var question: LearningQuestionView? { view.question }
    private var currentAttempts: [LearningAttempt] {
        view.attempts.filter { $0.questionID == session?.currentQuestionID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Practice & review").font(.title2.weight(.semibold))
                Spacer()
                Button("New practice") { workspace.practiceScreen = "setup" }
                Button("Review due (\(view.dueCount))") { workspace.practiceScreen = "review" }
                Button("Close") { workspace.practicePresented = false }.keyboardShortcut(.cancelAction)
            }
            Divider()
            if let busy = learning.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(busy)
                    Spacer()
                    Button("Cancel") {
                        workspace.practiceTask?.cancel()
                        workspace.practiceTicket = nil
                        learning.cancel()
                        generating = false
                    }
                }
            }
            if let error = learning.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if workspace.practiceScreen == "setup" {
                        setup
                    } else if workspace.practiceScreen == "review" {
                        reviews
                    } else if let session, session.finished {
                        recap
                    } else if let session, let question {
                        activity(session, question)
                    } else {
                        Text("Choose a passage or resume a saved session.")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
        }.padding(24).frame(width: 720, height: 700)
            .background(StudyPalette.paper(colorScheme == .dark))
            .onChange(of: learning.state.sequence) { _, _ in
                if generating, learning.state.sequence > generationStart, learning.state.session != nil {
                    workspace.practiceScreen = "session"
                    generating = false
                }
            }
            .onChange(of: session?.currentQuestionID) { _, _ in restoreDraft() }
            .onChange(of: session?.id) { _, _ in restoreDraft() }
            .onChange(of: answer) { _, value in
                if let session, let qid = session.currentQuestionID {
                    UserDefaults.standard.set(value, forKey: draftKey(session.id, qid))
                }
            }
            .onAppear { restoreDraft() }
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Practice your course").font(.title)
            if let coverage = view.coverage { courseCoverage(coverage) }
            Picker("Material", selection: $workspace.practiceSourceScope) {
                Text("Cover the whole course").tag("course")
                Text("Revisit weak areas").tag("weak")
                if workspace.document != nil { Text("Current reading / selection").tag("reading") }
            }
            Picker("Practice mode", selection: $style) {
                ForEach(CoursePracticeStyle.allCases) { Text($0.title).tag($0) }
            }
            Text(
                workspace.practiceSourceScope != "reading" ? "All saved course materials · sources rotate between sessions" : workspace.selectedText.isEmpty
                    ? workspace.document.map { "\($0.title) · page/section \(workspace.currentPage)" }
                        ?? "Downloaded course materials" : "Selected passage · \(workspace.document?.title ?? "Course")"
            ).foregroundStyle(.secondary)
            if workspace.draftImage != nil { Text("Includes your selected figure.").font(.caption) }
            TextField("Topic or focus (optional)", text: $scope).textFieldStyle(.roundedBorder)
            Picker("Session length", selection: $count) {
                ForEach([1, 2, 3, 4, 5, 8, 12], id: \.self) { Text("Up to \($0) question\($0 == 1 ? "" : "s")").tag($0) }
            }
            Toggle("Open-book practice", isOn: $openBook)
            Text(
                openBook
                    ? "Source access is recorded with each attempt."
                    : "Try recall with the source hidden. You can open it or show the solution at any time."
            ).font(.caption).foregroundStyle(.secondary)
            Button("Prepare questions") {
                generating = true
                generationStart = learning.state.sequence
                workspace.startPractice(using: app, count: count, scope: scope, openBook: openBook,
                    sourceScope: workspace.practiceSourceScope, style: style.rawValue)
            }.scholiaButtonStyle(.borderedProminent).disabled(
                learning.busy != nil || workspace.course == nil || generating)
            Text("Untimed · Saved locally · Generated questions can be imperfect").font(.caption).foregroundStyle(
                .secondary)
            if !view.sessions.isEmpty {
                Divider()
                Text("Continue a session").font(.headline)
                ForEach(view.sessions.filter { $0.courseID == workspace.course?.id }) { saved in
                    Button("\(saved.title) · \(saved.finished ? "Recap" : "Resume")") {
                        run(LearningCommand(action: "resume", sessionID: saved.id))
                        workspace.practiceScreen = "session"
                    }
                }
            }
        }.onChange(of: learning.error) { _, error in if error != nil { generating = false } }
            .onAppear { if workspace.document == nil { workspace.practiceSourceScope = "course" } }
    }
    private func courseCoverage(_ coverage: CoursePracticeCoverage) -> some View {
        let pages = coverage.materials.reduce(0) { $0 + $1.pages }
        let attempted = coverage.materials.reduce(0) { $0 + $1.attempted }
        let independent = coverage.materials.reduce(0) { $0 + $1.independent }
        return VStack(alignment: .leading, spacing: 10) {
            Text(coverage.title).font(.headline)
            ProgressView(value: Double(attempted), total: Double(max(1, pages)))
            Text("\(attempted) of \(pages) readable pages attempted · \(independent) last answered independently")
                .font(.caption).foregroundStyle(.secondary)
            Text("Each course session moves across saved readings and pages. Coverage records practice, not mastery of every concept.")
                .font(.caption).foregroundStyle(.secondary)
            if coverage.missing > 0 {
                HStack {
                    Text("\(coverage.missing) materials still need downloading.")
                    Button("Download course materials") {
                        workspace.practicePresented = false
                        workspace.syncCanvasCourses(courseIDs: [coverage.courseID], downloadAll: true)
                    }
                }.font(.caption)
            }
            DisclosureGroup("Material coverage") {
                ForEach(coverage.materials) { material in
                    HStack {
                        Text(material.title).lineLimit(2)
                        Spacer()
                        Text("\(material.attempted)/\(material.pages) · \(material.needsReview) to revisit").foregroundStyle(.secondary)
                    }.font(.caption).padding(.vertical, 3)
                }
            }
            if !coverage.concepts.isEmpty {
                DisclosureGroup("Concept progress") {
                    ForEach(coverage.concepts) { concept in
                        HStack {
                            Text(concept.title)
                            Spacer()
                            Text(concept.independent ? "Answered independently" : concept.needsReview ? "Revisit" : "Not attempted")
                                .foregroundStyle(.secondary)
                        }.font(.caption).padding(.vertical, 3)
                    }
                }
            }
        }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
    private func activity(_ s: LearningSession, _ q: LearningQuestionView) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("\(s.review ? "DELAYED REVIEW" : "PRACTICE") · \(s.position + 1) OF \(s.questionIDs.count)").font(
                .caption
            ).foregroundStyle(.secondary)
            Text(q.concept).font(.title2)
            source(q)
            RichMarkdownView(source: q.prompt)
            ForEach(Array(q.hints.enumerated()), id: \.offset) { index, hint in
                VStack(alignment: .leading) {
                    Text(["Conceptual cue", "Method cue", "Partial step"][min(index, 2)]).font(.headline)
                    RichMarkdownView(source: hint, compact: true)
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(currentAttempts) { attempt in
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        "\(attempt.previousAttemptID == nil ? "Original attempt" : "Revision") · \(attempt.independent ? "Independent" : "Assisted / open book")"
                    ).font(.caption.weight(.semibold))
                    Text(attempt.answer).textSelection(.enabled)
                    if let feedback = attempt.assessment {
                        Text(
                            "\(feedback.verdict.capitalized) · \(feedback.origin == "model" ? "Model judgment" : "Self-assessment")"
                        ).font(.headline)
                        feedbackLine("What was correct", feedback.correct)
                        feedbackLine("First issue", feedback.issue)
                        feedbackLine("Next step", feedback.nextStep)
                        Text("Evidence: \(q.source.title), page/section \(q.source.page)").font(.caption)
                            .foregroundStyle(.secondary)
                        if let dispute = attempt.dispute {
                            Text("Unresolved: \(dispute)").foregroundStyle(.orange)
                        } else {
                            TextField("Correction or concern (optional)", text: $correction).textFieldStyle(
                                .roundedBorder)
                            Button("This feedback seems wrong") {
                                run(command("dispute", attempt: attempt.id, text: correction))
                                correction = ""
                            }
                        }
                    } else {
                        Text("Saved · awaiting feedback").font(.caption)
                        Button("Retry feedback") { run(command("feedback", attempt: attempt.id)) }.disabled(
                            learning.busy != nil)
                    }
                    if let own = attempt.selfAssessment {
                        Text("Self-assessment: \(own) · separate from model feedback").font(.caption)
                    }
                    if s.revealed {
                        HStack {
                            Text("My self-check:").font(.caption)
                            ForEach(["correct", "partial", "incorrect", "uncertain"], id: \.self) { value in
                                Button(value) { run(command("selfAssess", attempt: attempt.id, text: value)) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
            if s.stage == "question" || s.stage == "revision" || s.stage == "attempt" && currentAttempts.isEmpty {
                Text("Your answer").font(.headline)
                TextEditor(text: $answer).frame(minHeight: 90).border(.secondary.opacity(0.25)).accessibilityLabel(
                    "Your practice answer")
                Picker("Confidence (optional)", selection: $confidence) {
                    Text("Not recorded").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0) / 5").tag($0) }
                }
                Button("Save answer & get feedback") {
                    var c = command("attempt", text: answer)
                    c.confidence = confidence == 0 ? nil : confidence
                    do {
                        try workspace.practiceCommand(c, using: app)
                        answer = ""
                        confidence = 0
                    } catch { learning.error = error.localizedDescription }
                }.scholiaButtonStyle(.borderedProminent).disabled(
                    answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || learning.busy != nil)
            } else {
                Button("Try again") { run(command("revise")) }.disabled(learning.busy != nil)
            }
            HStack {
                if s.hintCount < q.hintCount { Button("Next hint") { run(command("hint")) } }
                if !s.revealed {
                    Button("Show solution / worked example") { run(command("reveal")) }
                        .disabled(!view.attempts.contains { $0.questionID == q.id })
                        .help("Save an attempt first. You can describe where you are stuck.")
                }
                Button("Save for review") { run(command("saveReview")) }
            }
            if currentAttempts.isEmpty && !s.revealed {
                Text("Save an attempt to unlock the solution. If you are stuck, describe what you tried or where you need help.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let solution = q.referenceAnswer {
                Divider()
                Text("Reference solution").font(.headline)
                RichMarkdownView(source: solution)
                ForEach(q.rubric ?? [], id: \.self) { Text("• " + $0) }
                Text("Revealing the solution is recorded as assistance.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(s.position + 1 < s.questionIDs.count ? "Next question / skip" : "Finish session") {
                    run(command("next"))
                    answer = ""
                }.disabled(learning.busy != nil)
                Button("Finish now") { run(command("finish")) }.disabled(learning.busy != nil)
                Spacer()
                Button("Explain in tutor") {
                    guard run(command("source")) else { return }
                    guard workspace.resumeReading(q.source.documentID, page: q.source.page) else { return }
                    workspace.newThread()
                    workspace.mode = .explain
                    workspace.draft =
                        "Help me understand this practice question without giving away the solution:\n\(q.prompt)"
                    if let attempt = view.attempts.last(where: { $0.questionID == q.id }) {
                        workspace.draft += "\n\nMy attempt:\n\(attempt.answer)\n\nHelp me find the first gap in my reasoning."
                    } else {
                        workspace.draft += "\n\nExplain the relevant concept and give me one starting hint."
                    }
                    workspace.saveDraft()
                    workspace.practicePresented = false
                }
            }
        }
    }
    private func source(_ q: LearningQuestionView) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(q.source.title) · page/section \(q.source.page) · source saved with question").font(.caption)
                .foregroundStyle(.secondary)
            if q.stale {
                Text(
                    "Source changed or is unavailable. This question needs revalidation; feedback uses the saved source revision."
                ).foregroundStyle(.orange)
            }
            Text(q.validation).font(.caption2).foregroundStyle(.secondary)
            Button("Go to source page") {
                if session?.finished != true, !run(command("source")) { return }
                guard workspace.resumeReading(q.source.documentID, page: q.source.page) else { return }
                workspace.practicePresented = false
            }
            if session?.openBook == false && session?.finished == false && session?.revealed == false {
                Button("Open saved source") { run(command("source")) }
            }
            if !q.source.excerpt.isEmpty {
                DisclosureGroup("Saved source excerpt") {
                    Text(q.source.excerpt).font(.callout).textSelection(.enabled)
                }
            }
            if let data = q.source.image, let image = NSImage(data: data) {
                if q.requiresVisual {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220).accessibilityLabel(
                        "Question figure")
                } else {
                    DisclosureGroup("Saved page image") {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220).accessibilityLabel(
                            "Saved source figure")
                    }
                }
            }
        }
    }
    private var recap: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Session recap").font(.title)
            Text("Use the dated attempts as evidence. A completed session alone does not establish mastery.")
                .foregroundStyle(.secondary)
            ForEach(view.recap, id: \.id) { q in
                let attempts = view.attempts.filter { $0.questionID == q.id }
                VStack(alignment: .leading, spacing: 8) {
                    Text(q.concept).font(.headline)
                    Text(
                        attempts.isEmpty
                            ? "Skipped · untested"
                            : attempts.contains(where: \.independentSuccess)
                                ? "Answered independently" : "Revisit after assistance, revision or unresolved feedback"
                    )
                    source(q)
                    ForEach(attempts) { attempt in
                        DisclosureGroup(
                            "\(attempt.createdAt.formatted()) · \(attempt.independent ? "Independent" : "Assisted / revision")"
                        ) {
                            Text(attempt.answer).textSelection(.enabled)
                            if let feedback = attempt.assessment {
                                feedbackLine("What was correct", feedback.correct)
                                feedbackLine("First issue", feedback.issue)
                                feedbackLine("Next step", feedback.nextStep)
                                if let dispute = attempt.dispute {
                                    Text("Unresolved: \(dispute)")
                                } else {
                                    Button("This feedback seems wrong") {
                                        run(
                                            LearningCommand(
                                                action: "dispute", sessionID: session?.id, questionID: q.id,
                                                expectedVersion: session?.version, attemptID: attempt.id))
                                    }
                                }
                            } else {
                                Button("Retry feedback") {
                                    run(
                                        LearningCommand(
                                            action: "feedback", sessionID: session?.id, questionID: q.id,
                                            attemptID: attempt.id))
                                }
                            }
                        }
                    }
                    if let solution = q.referenceAnswer {
                        DisclosureGroup("Reference solution") { RichMarkdownView(source: solution) }
                    } else if !attempts.isEmpty {
                        Button("Show solution") {
                            run(
                                LearningCommand(
                                    action: "revealSaved", sessionID: session?.id, questionID: q.id,
                                    expectedVersion: session?.version))
                        }
                    } else {
                        Text("Skipped without an attempt. Practise this question again to unlock its solution.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Save for review") { run(LearningCommand(action: "saveReview", questionID: q.id)) }
                }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    private var reviews: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Today · \(view.dueCount) available").font(.title)
            Text(
                "Initial intervals are 1, 3, 6… days, capped at 30. Independent recall extends the interval. Assistance brings a short follow-up; unresolved feedback keeps the interval. No penalties for missed days."
            ).foregroundStyle(.secondary)
            Stepper(
                "Daily workload: \(view.dailyLimit)",
                value: Binding(get: { view.dailyLimit }, set: { run(LearningCommand(action: "limit", days: $0)) }),
                in: 1...30)
            if view.reviews.isEmpty { Text("Save a question after practice to bring it back here after a delay.") }
            ForEach(view.reviews) { review in
                VStack(alignment: .leading, spacing: 8) {
                    Text(review.concept).font(.headline)
                    Text("\(review.title) · \(review.dueAt.formatted(date: .abbreviated, time: .shortened))").font(
                        .caption)
                    Text(review.reason).font(.callout)
                    if review.stale { Text("Source changed · needs revalidation").foregroundStyle(.orange) }
                    HStack {
                        Button("Review") {
                            run(LearningCommand(action: "review", questionID: review.id))
                            workspace.practiceScreen = "session"
                        }
                        .disabled(!learning.state.due().contains(where: { $0.id == review.id }))
                        Button("Snooze 1 day") {
                            run(
                                LearningCommand(
                                    action: "snooze", questionID: review.id, expectedVersion: review.version, days: 1))
                        }
                        Button("Remove") {
                            run(
                                LearningCommand(
                                    action: "removeReview", questionID: review.id, expectedVersion: review.version))
                        }
                    }
                }.padding(14).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            Divider()
            Text("Recent sessions").font(.headline)
            ForEach(view.sessions) { saved in
                Button("\(saved.title) · \(saved.finished ? "Recap" : "Resume")") {
                    run(LearningCommand(action: "resume", sessionID: saved.id))
                    workspace.practiceScreen = "session"
                }
            }
        }
    }
    private func feedbackLine(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            RichMarkdownView(source: text, compact: true)
        }
    }
    private func command(_ action: String, attempt: UUID? = nil, text: String? = nil) -> LearningCommand {
        LearningCommand(
            action: action, sessionID: session?.id, questionID: session?.currentQuestionID,
            expectedVersion: session?.version, attemptID: attempt, text: text)
    }
    @discardableResult private func run(_ command: LearningCommand) -> Bool {
        do {
            try workspace.practiceCommand(command, using: app)
            return true
        } catch {
            learning.error = error.localizedDescription
            return false
        }
    }
    private func draftKey(_ sessionID: UUID, _ questionID: UUID) -> String {
        "scholia.practice-draft.\(workspace.store.root.path).\(sessionID).\(questionID)"
    }
    private func restoreDraft() {
        guard let session, let qid = session.currentQuestionID else { return }
        answer = UserDefaults.standard.string(forKey: draftKey(session.id, qid)) ?? ""
    }
}
