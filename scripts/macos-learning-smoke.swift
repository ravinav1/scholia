import Foundation
import AppKit
import SwiftUI
import Combine
@testable import ScholiaMac

extension StudyWorkspaceSmoke {
    static let practiceConfiguration = ProviderConfiguration(provider: ProviderCatalog.provider(id: "openai"), model: "gpt-4.1", endpoint: "http://127.0.0.1:1", apiKey: "fixture", language: .english, fastClaudeMode: false)
    static let practiceCompletion: StudyCompletion = { messages, _, _ in
        try await Task.sleep(for: .milliseconds(80))
        let grading = messages.first?.content.contains("Assess meaning") == true
        let text: String
        if grading {
            text = #"{"verdict":"partial","correct":"You considered the transformation.","issue":"Distinguish direction from length.","nextStep":"Revisit what a scalar multiple can change."}"#
        } else {
            let instruction = messages.first?.content ?? ""
            let count = (1...5).first { instruction.contains("exactly \($0) short") } ?? 1
            text = try String(data: JSONSerialization.data(withJSONObject: ["questions": (1...count).map { n in
                ["concept": "Eigenvectors", "prompt": "Question \(n): What property of an eigenvector is preserved by a linear transformation? Justify your answer.", "referenceAnswer": "It stays on the same line through the origin: Av is a scalar multiple of v. The length can change.", "rubric": ["Identify collinearity", "Distinguish length and direction"], "hints": ["Consider the geometry.", "Compare the vector before and after applying A.", "Write Av = lambda v and consider the scalar."], "sourceIndex": 0, "requiresVisual": false] as [String: Any]
            }]), encoding: .utf8)!
        }
        return CompletionResult(text: text, providerID: "fixture", providerName: "Deterministic fixture", model: "fixture")
    }

    static func checkLearning() async throws {
        for language in ["en", "no"] {
            for mode in StudyTeachingMode.allCases {
                let prepared = PreparedConversation(language: language, messages: [], teachingMode: mode)
                precondition(prepared.systemPrompt.contains(TutoringPolicy.learningBoundary) == (mode != .chat))
                precondition(prepared.systemPrompt.contains(mode.instruction))
            }
        }
        precondition(PreparedConversation(language: "en", messages: [], purpose: .practiceGeneration)
            .systemPrompt.contains("do not reproduce or solve the source problems"))
        var settings = AppSettings()
        for n in 1...15 {
            settings.recordModelUse(providerID: "codex", modelID: "model-\(n)", endpoint: settings.endpoints["codex"]!, at: Date(timeIntervalSince1970: Double(n)))
        }
        settings.recordModelUse(providerID: "openai", modelID: "model-14", endpoint: settings.endpoints["openai"]!, at: Date(timeIntervalSince1970: 20))
        settings.recordModelUse(providerID: "codex", modelID: "model-14", endpoint: settings.endpoints["codex"]!, at: Date(timeIntervalSince1970: 21))
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        precondition(restored.recentModels.count == 12 && restored.recentModels.prefix(2).map(\.providerID) == ["codex", "openai"])
        settings.endpoints["codex"] = "http://localhost:9999/v1/chat/completions"
        precondition(settings.recentModels.map(\.providerID) == ["openai"])
        let catalog = try CodexModelCatalog.models(from: Data(#"{"data":[{"id":"gpt-6.1-sol","label":"GPT-6.1 Sol","reasoning":{"efforts":["low","high","future"],"default":"future"},"supportsImages":false},{"id":"gpt-6.1-sol"}]}"#.utf8))
        precondition(catalog.count == 1 && catalog[0].defaultReasoningEffort == "future" && catalog[0].supportsImages == false)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-learning-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryStore = StudyLibraryStore(root: root)
        let document = try StudyDocumentImporter.read(data: Data("An eigenvector remains on the same line through the origin. Its length can change. Av = lambda v.".utf8), name: "Algebra.md", store: libraryStore)
        let course = StudyCourse(name: "Learning fixture", documents: [document])
        var library = StudyLibrary(courses: [course], selectedCourseID: course.id, selectedDocumentID: document.id)
        try libraryStore.save(library)
        let model = StudyWorkspaceModel(store: libraryStore)
        // Let the initial document load and classification finish before
        // measuring notifications caused by editor input.
        try await Task.sleep(for: .milliseconds(500))
        model.newThread()
        var workspaceChanges = 0
        let subscription = model.objectWillChange.sink { workspaceChanges += 1 }
        for n in 0..<250 { model.draft = "An unfinished thought \(n)" }
        precondition(workspaceChanges == 0, "Typing must not publish changes to the reader and conversation")
        precondition(model.thread?.draft == "", "The library copy waits for a typing pause")
        try await Task.sleep(for: .milliseconds(500))
        precondition(workspaceChanges == 1 && model.thread?.draft == model.draft, "A typing burst coalesces into one library change (got \(workspaceChanges))")
        subscription.cancel()
        let draftedThread = model.thread!.id
        model.draft = "Saved immediately on navigation"
        model.newThread()
        model.selectThread(draftedThread)
        precondition(model.draft == "Saved immediately on navigation")
        model.draft = "Saved immediately on flush"
        model.flush()
        let flushedLibrary = try libraryStore.load()
        precondition(flushedLibrary.courses[0].threads.first(where: { $0.id == draftedThread })?.draft == "Saved immediately on flush")
        let learning = model.learning
        model.preparePractice(count: 2, scope: "Eigenvectors", openBook: false, configuration: practiceConfiguration, complete: practiceCompletion)
        for _ in 0..<100 where learning.state.session == nil { try await Task.sleep(for: .milliseconds(30)) }
        guard let initial = learning.state.session, let first = initial.currentQuestionID else { throw StudyError.message("Practice fixture did not generate: \(learning.error ?? "unknown")") }
        precondition(learning.state.questions.count == 2 && learning.state.concepts.count == 1)
        precondition(learning.view(library: library).question?.referenceAnswer == nil)
        precondition(learning.view(library: library).question?.rubric == nil)
        precondition(learning.view(library: library).question?.source.excerpt == "")
        let publicJSON = try JSONEncoder().encode(learning.view(library: library))
        precondition(!String(data: publicJSON, encoding: .utf8)!.contains("It stays on the same line"), "The API must not leak the reference answer")
        func cmd(_ action: String, text: String? = nil, attempt: UUID? = nil) -> LearningCommand {
            let session = learning.state.session!
            return LearningCommand(action: action, sessionID: session.id, questionID: session.currentQuestionID, expectedVersion: session.version, attemptID: attempt, text: text)
        }
        func rejects(_ body: () throws -> Void) {
            do { try body(); preconditionFailure("Expected a conflict") } catch {}
        }
        rejects { try learning.perform(cmd("reveal")) }
        precondition(learning.view(library: library).question?.referenceAnswer == nil)
        let attempt = cmd("attempt", text: "The magnitude remains constant.")
        try learning.perform(attempt); try learning.perform(attempt)
        precondition(learning.state.attempts.count == 1 && learning.state.attempts[0].independent)
        let reopened = StudyLearningModel(root: root)
        precondition(reopened.state.attempts.first?.answer == attempt.text)
        precondition(reopened.state.session?.stage == "attempt")
        let stale = cmd("hint")
        try learning.perform(cmd("hint"))
        rejects { try learning.perform(stale) }
        learning.assess(attemptID: attempt.id, configuration: practiceConfiguration, complete: practiceCompletion)
        for _ in 0..<100 where learning.busy != nil { try await Task.sleep(for: .milliseconds(10)) }
        precondition(learning.state.attempts[0].assessment?.verdict == "partial")
        try learning.perform(cmd("dispute", text: "Please check this interpretation.", attempt: attempt.id))
        try learning.perform(cmd("revise"))
        let revised = cmd("attempt", text: "Det er linjen gjennom origo som bevares, ikke lengden.")
        try learning.perform(revised)
        precondition(learning.state.attempts.count == 2)
        precondition(learning.state.attempts[1].previousAttemptID == attempt.id && !learning.state.attempts[1].independent)
        try learning.perform(cmd("reveal"))
        try learning.perform(cmd("selfAssess", text: "correct", attempt: revised.id))
        precondition(learning.view(library: library).question?.referenceAnswer != nil)
        precondition(learning.state.attempts[1].selfAssessment == "correct" && learning.state.attempts[1].assessment == nil)
        if CommandLine.arguments.contains("--learning-preview") {
            let controller = StudyWindowController(app: AppModel.shared, workspace: model, autosave: false)
            controller.show(); model.practiceScreen = "session"; model.practicePresented = true
            try await Task.sleep(for: .milliseconds(450))
            let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("apps/macos/.build/verification")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            precondition(controller.window.attachedSheet != nil, "The reader opens a native practice sheet")
            // A SwiftUI sheet's visual-effect host cannot be cached by NSView.
            // Render the same content in an AppKit-owned frame for visual QA.
            model.practicePresented = false; controller.window.orderOut(nil)
            let preview = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            preview.appearance = NSAppearance(named: .aqua)
            preview.contentViewController = PanelContentController(rootView: StudyPracticeView(workspace: model, learning: learning).environmentObject(AppModel.shared), size: NSSize(width: 720, height: 700))
            preview.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(300))
            try snapshot(preview, at: output.appendingPathComponent("practice-native.png"))
            preview.orderOut(nil)
        }
        let resumed = StudyLearningModel(root: root)
        precondition(resumed.state.session?.revealed == true && resumed.state.session?.hintCount == 1)
        precondition(resumed.state.attempts[0].answer == "The magnitude remains constant.")
        let oldDate = Date().addingTimeInterval(-172_800)
        try learning.commit(LearningEvent(command: LearningCommand(action: "saveReview", questionID: first), date: oldDate))
        try learning.perform(cmd("next"))
        precondition(learning.state.session?.hintCount == 0 && learning.state.session?.revealed == false)
        try learning.perform(cmd("finish"))
        rejects { try learning.perform(cmd("revealSaved")) }
        try learning.perform(LearningCommand(action: "review", questionID: first))
        rejects { try learning.perform(cmd("reveal")) }
        let recall = cmd("attempt", text: "Av is collinear with v; its magnitude need not stay fixed.")
        try learning.perform(recall)
        let correct = LearningAssessment(verdict: "correct", correct: "Equivalent valid reasoning", issue: "None", nextStep: "Try another context", model: "fixture")
        try learning.commit(LearningEvent(command: cmd("assess", attempt: recall.id), assessment: correct))
        let finish = cmd("finish")
        try learning.perform(finish)
        let scheduled = learning.state.reviews[first]!
        precondition(scheduled.intervalDays == 3 && scheduled.evidenceAttemptID == recall.id)
        try learning.perform(finish)
        precondition(learning.state.reviews[first] == scheduled, "Repeated finish cannot schedule twice")
        rejects { try learning.perform(cmd("finish")) }
        let snooze = LearningCommand(action: "snooze", questionID: first, expectedVersion: scheduled.version, days: 1)
        try learning.perform(snooze); try learning.perform(snooze)
        precondition(learning.state.reviews[first]?.version == scheduled.version + 1)
        rejects { try learning.perform(LearningCommand(action: "snooze", questionID: first, expectedVersion: scheduled.version, days: 2)) }
        // An independent old snapshot cannot overwrite a newer writer.
        rejects { try reopened.perform(LearningCommand(action: "limit", days: 2)) }
        let savedState = try LearningStore(root: root).load()
        precondition(savedState.dailyLimit == 10)
        library.courses[0].documents[0].contentHash = "changed-manual-import"
        precondition(learning.view(library: library).question?.stale == true)
        precondition(learning.state.questions[first]?.source.contentHash == document.contentHash)
        let pending = LearningCommand(action: "attempt", sessionID: initial.id, questionID: first, expectedVersion: 1, text: "Lost window")
        rejects { try learning.perform(pending) }
        // Native/browser ownership includes course, document, thread, page and draft.
        let owner = model.draftOwner
        model.draft = "A newer native draft"
        rejects { try model.validateDraftOwner(owner) }
        let current = model.draftOwner; try model.validateDraftOwner(current)
        model.createCourse(name: "Other course", code: "")
        rejects { try model.validateDraftOwner(current) }
        let invalid = #"{"questions":[{"concept":"x","prompt":"The complete reference answer","referenceAnswer":"The complete reference answer","rubric":["x"],"hints":["a","b","c"],"sourceIndex":0,"requiresVisual":false}]}"#
        rejects { _ = try LearningGeneration.questions(invalid, sources: [learning.state.questions[first]!.source], count: 1, model: "fixture") }
        for verdict in ["correct", "partial", "incorrect", "uncertain"] {
            let feedback = try LearningGeneration.assessment("{\"verdict\":\"\(verdict)\",\"correct\":\"Equivalent wording accepted\",\"issue\":\"Ambiguous source\",\"nextStep\":\"Check the premise\"}", model: "fixture")
            precondition(feedback.verdict == verdict)
        }
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path + ".learning"))
        let disk = try LearningStore(root: root).load()
        precondition(disk.attempts.count == 3 && disk.reviews[first] == learning.state.reviews[first])
        // Scheduler outcomes are determined by evidence, never confidence alone.
        for condition in ["revealed", "hinted", "openBook", "uncertain", "disputed", "stale"] {
            var replay = disk
            replay.reviews[first]?.dueAt = oldDate; replay.reviews[first]?.intervalDays = 6
            try replay.apply(LearningEvent(command: LearningCommand(action: "review", questionID: first)))
            func event(_ action: String, text: String? = nil, attemptID: UUID? = nil) -> LearningEvent {
                let s = replay.session!
                return LearningEvent(command: LearningCommand(action: action, sessionID: s.id, questionID: first, expectedVersion: s.version, attemptID: attemptID, text: text))
            }
            if condition == "hinted" { try replay.apply(event("hint")) }
            if condition == "openBook" { try replay.apply(event("source")) }
            var answer = event("attempt", text: "Equivalent valid reasoning")
            answer.command.confidence = 5; answer.command.sourceStale = condition == "stale"
            try replay.apply(answer)
            var feedback = event("assess", attemptID: answer.command.id)
            feedback.assessment = correct; if condition == "uncertain" { feedback.assessment?.verdict = "uncertain" }
            try replay.apply(feedback)
            if condition == "revealed" { try replay.apply(event("reveal")) }
            if condition == "disputed" { try replay.apply(event("dispute", text: "Ambiguous task", attemptID: answer.command.id)) }
            let end = event("finish"); try replay.apply(end); try replay.apply(end)
            precondition(replay.reviews[first]?.intervalDays == (["uncertain", "disputed", "stale"].contains(condition) ? 6 : 1), "Unexpected scheduler outcome for \(condition)")
        }
        // Offline answers can receive feedback after the session is finished.
        var offlineQuestion = learning.state.questions[first]!; offlineQuestion.id = UUID()
        let offlineSession = LearningSession(id: UUID(), courseID: course.id, questionIDs: [offlineQuestion.id])
        try learning.commit(LearningEvent(command: LearningCommand(action: "create"), questions: [offlineQuestion], session: offlineSession))
        let offlineAttempt = cmd("attempt", text: "My offline answer")
        try learning.perform(offlineAttempt)
        learning.assess(attemptID: offlineAttempt.id, configuration: practiceConfiguration) { _, _, _ in throw URLError(.notConnectedToInternet) }
        for _ in 0..<100 where learning.busy != nil { try await Task.sleep(for: .milliseconds(10)) }
        precondition(learning.error?.contains("Your answer is saved") == true)
        try learning.perform(cmd("finish"))
        try learning.commit(LearningEvent(command: cmd("assess", attempt: offlineAttempt.id), assessment: correct))
        try learning.perform(cmd("dispute", text: "Check later", attempt: offlineAttempt.id))
        precondition(learning.state.attempts.last?.dispute == "Check later")
        try learning.perform(cmd("revealSaved"))
        precondition(learning.view(library: library).recap.first?.referenceAnswer != nil)
        let unchanged = learning.state.questions[first]
        rejects { try learning.commit(LearningEvent(command: LearningCommand(action: "create"), questions: [learning.state.questions[first]!], session: LearningSession(id: UUID(), courseID: course.id, questionIDs: [first]))) }
        precondition(learning.state.questions[first] == unchanged)

        print("PASS: tutoring boundaries, recent models, dynamic catalog, isolated/debounced typing, draft persistence, hidden solutions, attempt-first reveal and recap, learning events and restart")
    }
}
