@preconcurrency import AppKit
import PDFKit
import SwiftUI
@testable import ScholiaMac

@main
@MainActor
struct StudyWorkspaceSmoke {
    static func main() {
        if CommandLine.arguments.contains("--downloads-only") {
            do { try checkDownloadNames(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        if CommandLine.arguments.contains("--performance-only") {
            do { try benchmarkDashboard(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        if CommandLine.arguments.contains("--semesters-only") {
            do { try checkSemesters(); print("PASS: semester parsing, multi-term membership, chronology, shared filters, favorites and persistence"); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                if CommandLine.arguments.contains("--personalization-only") {
                    try await checkPersonalization(); exit(0)
                }
                if CommandLine.arguments.contains("--material-cache-only") {
                    try checkInteractionData()
                    exit(0)
                }
                if CommandLine.arguments.contains("--interactions-only") {
                    try checkInteractionData()
                    try await checkInteractionUI()
                    exit(0)
                }
                if CommandLine.arguments.contains("--course-ui-only") || CommandLine.arguments.contains("--course-layout-only") {
                    try await checkCourseUI(); exit(0)
                }
                if CommandLine.arguments.contains("--ai-workspace-only") { try await checkAIWorkspace(); exit(0) }
                if CommandLine.arguments.contains("--document-focus-only") { try await checkDocumentFocus(); exit(0) }
                if CommandLine.arguments.contains("--document-focus-preview") { try await previewDocumentFocus(); exit(0) }
                if CommandLine.arguments.contains("--passage-explanation-only") { try await checkPassageExplanationScratch(); exit(0) }
                if CommandLine.arguments.contains("--reference-shortcuts-only") { try await checkReferenceLinksAndShortcuts(); exit(0) }
                if CommandLine.arguments.contains("--sync-status-only") { try await checkSyncStatusUI(); exit(0) }
                if CommandLine.arguments.contains("--ocr-only") { try await checkDocumentOCR(); exit(0) }
                if CommandLine.arguments.contains("--assignment-agenda-preview") { try await previewAssignmentAgenda(); exit(0) }
                if CommandLine.arguments.contains("--course-documents-only") { try await checkCourseDocuments(); exit(0) }
                if CommandLine.arguments.contains("--canvas-new-files-preview") {
                    try await previewCanvasNewFiles(); exit(0)
                }
                if CommandLine.arguments.contains("--assignment-feedback-preview") {
                    try await previewAssignmentFeedback(); exit(0)
                }
                if CommandLine.arguments.contains("--assignment-status-preview") {
                    try checkAssignmentProgress(); try await previewAssignmentStatus(); exit(0)
                }
                if CommandLine.arguments.contains("--assignment-opening-only") {
                    try await checkAssignmentOpening(); exit(0)
                }
                if CommandLine.arguments.contains("--assignment-deadlines-only") {
                    try await checkDeadlineRefreshScheduling()
                    try await checkMovedAssignmentDeadlines()
                    try await checkDeadlineAuthentication()
                    try await checkCachedAssignmentDeadline()
                    print("PASS: moved and removed deadlines, optional feedback failures, cached instructions, tutor context, offline reading and persistence")
                    exit(0)
                }
                if CommandLine.arguments.contains("--pdf-selection-only") {
                    try await checkPDFSelectionChat(); exit(0)
                }
                if CommandLine.arguments.contains("--assignments-only") || CommandLine.arguments.contains("--assignments-preview") {
                    try await checkDataTransfer(); try await checkAssignments(); try await checkCanvasFavorites(); try await checkCanvasReconnectAndRefresh(); try checkMaterialGroups(); try checkMaterialClassification()
                    print("PASS: Canvas assignment pagination, deadlines, submission states, module fallback, refresh and persistence")
                    if CommandLine.arguments.contains("--assignments-preview") { try await previewAssignments() }
                    exit(0)
                }
                if CommandLine.arguments.contains("--learning-only") || CommandLine.arguments.contains("--learning-preview") { try await checkLearning(); exit(0) }
                if CommandLine.arguments.contains("--data-only") {
                    try await checkDataTransfer(); try await checkLearning()
                    try checkSemesters(); try await checkAssignments(); try await checkStudyFlow(); try checkPDFFit(); try await checkPDFRegions(); try checkFormats(); try await checkDocumentEditing(); try checkMaterialGroups(); try checkMaterialClassification(); try await checkCatalogChanges()
                    print("PASS: Office, notebook, code and original imports; image context; shared semantic search; Canvas changes, partial failures, conditional pagination and module order")
                    exit(0)
                }
                try await run()
                print("PASS: document import, full/page/visual context, conversation/edit/save/reopen, Canvas pagination/auth isolation, native light/dark/compact layout")
                exit(0)
            } catch {
                print("FAIL: \(error)"); exit(1)
            }
        }
        app.run()
    }

    /// Read the current library, but run model measurements on an isolated temporary copy.
    static func benchmarkDashboard() throws {
        var library = try StudyLibraryStore().load()
        library.selectedCourseID = nil; library.selectedDocumentID = nil; library.selectedThreadID = nil
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-performance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root); try store.save(library)
        let workspace = StudyWorkspaceModel(store: store)
        func measure(_ name: String, iterations: Int = 20, work: () -> Int) {
            let start = Date(); var count = 0
            for _ in 0..<iterations { count += work() }
            print("BENCH \(name): \(String(format: "%.2f", Date().timeIntervalSince(start) * 1000 / Double(iterations))) ms; result \(count / iterations)")
        }
        print("Dashboard benchmark: \(library.courses.count) workspaces, \(library.courses.reduce(0) { $0 + $1.materials.count }) materials")
        measure("workspace filter", iterations: 10) {
            let semester = workspace.semesterGroups.first { $0.id == workspace.selectedSemesterID }
            return workspace.sortedCourses.filter {
                (workspace.courseLibraryView != .favorites || $0.isFavorite)
                    && (workspace.selectedSemesterID == "all" || semester?.courseIDs.contains($0.id) == true)
            }.count
        }
        measure("semester groups") { workspace.semesterGroups.count }
        measure("deadline agenda") { StudyAssignmentGroup.make(courses: library.courses).reduce(0) { $0 + $1.items.count } }
        measure("archive agenda") { StudyAssignmentGroup.make(courses: library.courses, filter: .archive).reduce(0) { $0 + $1.items.count } }
    }

    static func checkSemesters() throws {
        func ids(_ term: String?, _ code: String = "", _ name: String = "") -> [String] {
            StudySemester.memberships(term: term, code: code, name: name).map(\.id)
        }
        precondition(ids("2026 HØST") == ["2026-autumn"])
        precondition(ids("2026 VÅR") == ["2026-spring"])
        precondition(ids("2026 HØST|2027 VÅR") == ["2027-spring", "2026-autumn"])
        precondition(ids("Fall 2026") == ["2026-autumn"])
        precondition(ids("Spring 2026") == ["2026-spring"])
        precondition(ids("Høst 2026") == ["2026-autumn"])
        precondition(ids("2026H / 2026 HØST") == ["2026-autumn"], "Equivalent term names must deduplicate")
        precondition(ids("Default term", "TMA4115-26H") == ["2026-autumn"])
        precondition(ids(nil, "TMA4115", "TMA4115-26V :: Linear algebra") == ["2026-spring"])
        precondition(ids("2026 VÅR", "TMA4115-26H") == ["2026-spring"], "Canvas term is authoritative")
        precondition(ids(nil, "TMA4115") == ["unassigned"], "Digits in a course code are not years")
        precondition(ids("Default term") == ["unassigned"])
        precondition(ids("Continuing education") == ["term:continuing education"])
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 15))!
        precondition(StudySemester.current(at: date, calendar: calendar).id == "2026-autumn")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-semesters-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let spanning = StudyCourse(name: "Year course", term: "2026 HØST|2027 VÅR")
        let autumn = StudyCourse(name: "Autumn course", favorite: true, term: "2026 HØST")
        let spring = StudyCourse(name: "Spring course", term: "2026 VÅR")
        let personal = StudyCourse(name: "My readings")
        let library = StudyLibrary(courses: [spanning, autumn, spring, personal])
        try store.save(library)
        let workspace = StudyWorkspaceModel(store: store)
        let groups = StudySemesterGroup.make(courses: workspace.sortedCourses, date: date)
        precondition(workspace.semesterGroups.map(\.courseIDs) == groups.map(\.courseIDs))
        workspace.toggleFavorite(spanning.id)
        precondition(workspace.semesterGroups.first { $0.id == "2026-autumn" }?.courseIDs == [autumn.id, spanning.id])
        workspace.toggleFavorite(autumn.id)
        precondition(workspace.semesterGroups.first { $0.id == "2026-autumn" }?.courseIDs == [spanning.id, autumn.id], "Semester ordering must reflect changed favorites")
        workspace.library.courses[2].term = "2025 HØST"
        precondition(workspace.semesterGroups.contains { $0.id == "2025-autumn" } && !workspace.semesterGroups.contains { $0.id == "2026-spring" }, "Semester metadata changes must immediately update filters")
        workspace.library.courses = library.courses
        precondition(groups.map(\.id) == ["2027-spring", "2026-autumn", "2026-spring", "unassigned"])
        precondition(groups.filter(\.isCurrent).map(\.id) == ["2026-autumn"])
        precondition(groups[1].courseIDs == [autumn.id, spanning.id], "Favorites stay first within a semester")
        precondition(groups[0].courseIDs == [spanning.id], "Year courses must also appear in the next semester")
        workspace.selectSemester("2026-autumn")
        workspace.setCourseLibraryView(.favorites)
        workspace.flush()
        let reopened = StudyWorkspaceModel(store: store)
        precondition(reopened.courseLibraryView == .favorites && reopened.selectedSemesterID == "2026-autumn")
        reopened.setCourseLibraryView(.semesters)
        reopened.selectSemester("not-a-semester")
        precondition(reopened.selectedSemesterID == "2026-autumn", "Invalid filters must not hide the library")
        reopened.selectSemester("all")
        precondition(reopened.selectedSemesterID == "all")
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(library)) as! [String: Any]
        encoded.removeValue(forKey: "courseLibraryView"); encoded.removeValue(forKey: "selectedSemesterID")
        let legacy = try JSONDecoder().decode(StudyLibrary.self, from: JSONSerialization.data(withJSONObject: encoded))
        precondition(legacy.courses.count == 4 && legacy.courseLibraryView == nil)
    }

    static func checkDocumentFocus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-focus-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        workspace.createCourse(name: "Focus fixture", code: "TEST")
        workspace.toggleDocumentFocus()
        precondition(!workspace.documentFocused, "Focus needs an open document")
        let source = root.appendingPathComponent("Slides.pdf")
        try fixturePDF().write(to: source)
        workspace.importDocuments([source])
        for _ in 0..<500 where workspace.isImporting || workspace.document == nil { try await Task.sleep(for: .milliseconds(20)) }
        precondition(workspace.document != nil)
        let controller = StudyWindowController(app: AppModel.shared, workspace: workspace, autosave: false)
        workspace.toggleDocumentFocus()
        precondition(workspace.documentFocused)
        try await Task.sleep(for: .milliseconds(100))
        precondition(controller.windowButtonsHidden, "Focus hides the window buttons while the top bar is gone")
        precondition(!controller.isFullScreen, "A hidden window must not enter full screen")
        workspace.newThread()
        precondition(workspace.documentFocused, "Starting a chat beside the document keeps focus")
        workspace.showCourseLibrary()
        precondition(!workspace.documentFocused, "Leaving the document ends focus")
        try await Task.sleep(for: .milliseconds(100))
        precondition(!controller.windowButtonsHidden, "Window buttons return after focus")
        workspace.selectDocument(try unwrap(workspace.course?.documents.first?.id))
        workspace.toggleDocumentFocus()
        precondition(workspace.documentFocused)
        workspace.examPlannerPresented = true
        precondition(!workspace.documentFocused, "The exam planner covers the reader, so focus ends")
        workspace.examPlannerPresented = false

        // Native full screen on a visible window, in both directions.
        func settle() async throws {
            for _ in 0..<200 where controller.fullScreenTransitioning { try await Task.sleep(for: .milliseconds(50)) }
            try await Task.sleep(for: .milliseconds(300))
        }
        controller.show()
        try await Task.sleep(for: .milliseconds(400))
        workspace.toggleDocumentFocus()
        try await Task.sleep(for: .milliseconds(200)); try await settle()
        precondition(controller.isFullScreen, "Focus enters native full screen")
        workspace.toggleDocumentFocus()
        try await Task.sleep(for: .milliseconds(200)); try await settle()
        precondition(!controller.isFullScreen && !controller.windowButtonsHidden, "Leaving focus leaves full screen")
        // Esc or the green button: the window leaves full screen on its own and focus ends with it.
        workspace.toggleDocumentFocus()
        try await Task.sleep(for: .milliseconds(200)); try await settle()
        precondition(controller.isFullScreen)
        controller.window.toggleFullScreen(nil)
        try await Task.sleep(for: .milliseconds(200)); try await settle()
        precondition(!controller.isFullScreen && !workspace.documentFocused, "Exiting full screen ends focus")
        // A window the user already put in full screen stays there after leaving focus.
        controller.window.toggleFullScreen(nil)
        try await Task.sleep(for: .milliseconds(200)); try await settle()
        precondition(controller.isFullScreen && !workspace.documentFocused, "Plain full screen keeps the chrome")
        workspace.toggleDocumentFocus()
        try await Task.sleep(for: .milliseconds(300))
        workspace.toggleDocumentFocus()
        try await Task.sleep(for: .milliseconds(300)); try await settle()
        precondition(controller.isFullScreen && !workspace.documentFocused, "Leaving focus keeps a full screen the user chose")
        controller.window.toggleFullScreen(nil)
        try await Task.sleep(for: .milliseconds(200)); try await settle()
        precondition(!controller.isFullScreen)
        controller.window.close()
        print("PASS: document focus needs an open document, survives new chats, ends on navigation, hides window buttons and follows native full screen")
    }
    /// Renders the reader beside an empty chat at the minimum window size, then
    /// the same workspace in document focus, so header cropping is visible.
    static func previewDocumentFocus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-focus-preview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let workspace = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        workspace.createCourse(name: "Random processes", code: "TTK4255")
        let source = root.appendingPathComponent("Week_41_Canonical_decompositions_and_random_processes.pdf")
        try fixturePDF().write(to: source)
        workspace.importDocuments([source])
        for _ in 0..<500 where workspace.isImporting || workspace.documentIndex == nil { try await Task.sleep(for: .milliseconds(20)) }
        precondition(workspace.document != nil)
        let controller = StudyWindowController(app: AppModel.shared, workspace: workspace, autosave: false)
        controller.window.appearance = NSAppearance(named: .darkAqua)
        controller.show()
        controller.window.setContentSize(NSSize(width: 1_020, height: 640))
        try await Task.sleep(for: .milliseconds(800))
        try snapshot(controller.window, at: output.appendingPathComponent("document-chat-minimum.png"))
        controller.window.close()
        workspace.documentFocused = true
        try await Task.sleep(for: .milliseconds(100))
        precondition(!controller.isFullScreen, "A hidden window must not enter full screen")
        controller.show()
        controller.window.setContentSize(NSSize(width: 1_020, height: 640))
        try await Task.sleep(for: .milliseconds(800))
        try snapshot(controller.window, at: output.appendingPathComponent("document-focus-minimum.png"))
        if let host = find(StudyPDFHost.self, in: try unwrap(controller.window.contentView)), let page = host.pdf.currentPage {
            let rect = host.pdf.convert(page.bounds(for: host.pdf.displayBox), from: page)
            let margins = (rect.minX, host.pdf.bounds.width - rect.maxX)
            precondition(abs(margins.0 - margins.1) < 2, "A fitted page must sit centred in the reader, not beside a scroller strip: \(margins)")
        }
        let previousMode = AppModel.shared.settings.studyModelMode
        AppModel.shared.settings.studyModelMode = .fast
        workspace.draft = "Prove that the eigenvalues of a symmetric matrix are real."
        try await Task.sleep(for: .milliseconds(500))
        try snapshot(controller.window, at: output.appendingPathComponent("document-focus-fast-mode.png"))
        try await courseUIPress("study-model-mode", in: controller.window)
        try await Task.sleep(for: .milliseconds(600))
        if let panel = controller.window.childWindows?.first(where: { $0.contentView != nil }) {
            try snapshot(panel, at: output.appendingPathComponent("document-model-mode-panel.png"))
        } else {
            print("WARN: model mode panel did not open as a child window")
        }
        AppModel.shared.settings.studyModelMode = previousMode
        workspace.draft = ""
        controller.window.close()
        print("PASS: wrote document-chat-minimum.png, document-focus-minimum.png and document-focus-fast-mode.png")
    }
    /// Explain on a passage answers in the reader popover's hidden thread; the
    /// chat column keeps its conversation until the answer is kept in chat.
    static func checkPassageExplanationScratch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-passage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        workspace.createCourse(name: "Passage fixture", code: "TEST")
        let source = root.appendingPathComponent("Slides.pdf")
        try fixturePDF().write(to: source)
        workspace.importDocuments([source])
        for _ in 0..<500 where workspace.isImporting || workspace.documentIndex == nil { try await Task.sleep(for: .milliseconds(20)) }
        workspace.draft = "An unsent draft in the conversation"
        workspace.saveDraft()
        let visibleBefore = workspace.course?.threads.filter { $0.isSelectionScratch != true } ?? []
        let configuration = ProviderConfiguration(provider: ProviderCatalog.provider(id: "ollama"), model: "fixture", endpoint: "http://127.0.0.1:1", apiKey: "", language: .english, fastClaudeMode: false)
        let completion: StudyCompletion = { messages, _, onToken in
            precondition(messages.last?.content.contains("> eigenvectors") == true)
            onToken("The selected passage ")
            return CompletionResult(text: "The selected passage describes eigenvectors.", providerID: "fixture", providerName: "Fixture", model: "fixture")
        }
        let sent = workspace.sendReaderSelection("eigenvectors", inChat: false) {
            workspace.submit(configuration: configuration, complete: completion)
        }
        precondition(sent, "Explain must start a request from the passage alone")
        let target = try unwrap(workspace.selectionResponseTarget)
        precondition(!target.inChat && workspace.library.selectedThreadID != target.threadID, "The popover follows a hidden thread, not the chat")
        for _ in 0..<500 where workspace.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        precondition(workspace.messages.isEmpty, "The conversation must not show the popover's explanation")
        precondition(workspace.draft == "An unsent draft in the conversation", "The conversation draft must survive an explanation")
        let scratch = try unwrap(workspace.course?.threads.first { $0.id == target.threadID })
        precondition(scratch.isSelectionScratch == true && scratch.messages.count == 2 && scratch.messages.last?.content.contains("describes eigenvectors") == true)
        let visibleAfter = workspace.course?.threads.filter { $0.isSelectionScratch != true } ?? []
        precondition(visibleAfter.map(\.id) == visibleBefore.map(\.id) && visibleAfter.allSatisfy { $0.messages.isEmpty },
            "No visible conversation is created or filled by an explanation")
        // A second explanation replaces the first in the hidden thread instead of growing it.
        _ = workspace.sendReaderSelection("eigenvectors", inChat: false) { workspace.submit(configuration: configuration, complete: completion) }
        for _ in 0..<500 where workspace.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        precondition(workspace.course?.threads.filter { $0.isSelectionScratch == true }.count == 1)
        precondition(workspace.course?.threads.first { $0.isSelectionScratch == true }?.messages.count == 2)
        workspace.keepSelectionExplanationInChat()
        precondition(workspace.messages.count == 2 && workspace.messages.last?.content.contains("describes eigenvectors") == true,
            "Keep in chat moves the explanation into the document conversation")
        precondition(workspace.course?.threads.first { $0.isSelectionScratch == true }?.messages.isEmpty == true)
        precondition(workspace.selectionResponseTarget?.inChat == true)
        // With the setting on, the explanation goes straight into the conversation.
        _ = workspace.sendReaderSelection("eigenvectors", inChat: true) { workspace.submit(configuration: configuration, complete: completion) }
        for _ in 0..<500 where workspace.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        precondition(workspace.messages.count == 4 && workspace.selectionResponseTarget?.inChat == true)
        workspace.flush()
        let reopened = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        precondition(reopened.course?.threads.filter { $0.isSelectionScratch != true }.count == max(1, visibleBefore.count) && reopened.messages.count == 4)
        print("PASS: passage explanations answer in a hidden thread, keep the conversation and draft, replace each other, and can be kept in chat")
    }
    static func checkPDFSelectionChat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-selection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root), workspace = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        workspace.createCourse(name: "Selection fixture", code: "TEST")
        let source = root.appendingPathComponent("Selection.pdf")
        try fixturePDF().write(to: source)
        workspace.importDocuments([source])
        for _ in 0..<500 where workspace.isImporting || workspace.documentIndex == nil { try await Task.sleep(for: .milliseconds(20)) }
        precondition(workspace.documentIndex != nil)
        workspace.setPage(2)
        let controller = StudyWindowController(app: AppModel.shared, workspace: workspace, autosave: false)
        controller.show()
        defer { controller.window.close() }
        try await Task.sleep(for: .milliseconds(500))
        let host = try unwrap(find(StudyPDFHost.self, in: try unwrap(controller.window.contentView)))
        let passage = try unwrap(host.pdf.document?.findString("eigenvectors", withOptions: []).first)
        host.pdf.setCurrentSelection(passage, animate: false)
        host.showSelectionPopup()
        func button(_ title: String, in view: NSView) -> NSButton? {
            if let value = view as? NSButton, value.title == title { return value }
            for child in view.subviews { if let result = button(title, in: child) { return result } }
            return nil
        }
        func clickResponseFooter(_ view: NSView, x: CGFloat) async throws {
            let window = try unwrap(view.window)
            let point = view.convert(NSPoint(x: x, y: view.isFlipped ? view.bounds.maxY - 22 : 22), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try unwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                NSApplication.shared.postEvent(event, atStart: false)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let explain = try unwrap(button("Explain", in: host)), open = try unwrap(button("Open in chat ↗", in: host))
        let popup = try unwrap(open.superview)
        precondition(!popup.isHidden && popup.frame.size == NSSize(width: 320, height: 92))
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try snapshot(controller.window, at: output.appendingPathComponent("pdf-selection-compact-native.png"))
        let configuration = ProviderConfiguration(provider: ProviderCatalog.provider(id: "ollama"), model: "fixture", endpoint: "http://127.0.0.1:1", apiKey: "", language: .english, fastClaudeMode: false)
        @MainActor final class ResponseGate { var finished = false }
        let responseGate = ResponseGate()
        let completion: StudyCompletion = { messages, _, onToken in
            precondition(messages.last?.content.contains("> eigenvectors") == true)
            let prepared = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english)
            precondition(prepared.messages.last?.content.contains("Current page: 2 of 3") == true)
            onToken("The selected passage ")
            while !responseGate.finished { try await Task.sleep(for: .milliseconds(10)) }
            return CompletionResult(text: "The selected passage describes eigenvectors.\n\n```python\nv = [1, 0]\n```", providerID: "fixture", providerName: "Fixture", model: "fixture")
        }
        precondition(workspace.thread == nil && workspace.draft.isEmpty && workspace.draftImage == nil,
            "This regression must start with a selection and no conversation or draft")
        let contentView = try unwrap(controller.window.contentView)
        let buttonPoint = explain.convert(NSPoint(x: explain.bounds.midX, y: explain.bounds.midY), to: contentView.superview)
        let hit = contentView.hitTest(buttonPoint)
        precondition(hit === explain || hit?.isDescendant(of: explain) == true, "The visible Explain button must receive clicks")
        let originalAction = host.onSelectionAction
        host.onSelectionAction = { text, send, question in
            precondition(text == "eigenvectors" && send && question.isEmpty)
            workspace.selectedText = text
            workspace.submit(configuration: configuration, complete: completion)
            return workspace.isStreaming
        }
        let focusBeforeExplain = workspace.tutorFocusRequest
        explain.performClick(nil)
        precondition(workspace.isStreaming && workspace.messages.count == 2,
            "Explain must create the first conversation from a passage alone")
        let response = try unwrap(host.responsePopover)
        precondition(response.isShown && popup.isHidden,
            "Explain must open a response popup instead of leaving only the compact selection controls")
        for _ in 0..<100 where workspace.messages.last?.content.isEmpty == true { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        let responseView = try unwrap(response.contentViewController?.view)
        let responseText = try unwrap(find(NSTextView.self, in: responseView))
        precondition(responseText.string.contains("The selected passage") && workspace.isStreaming,
            "The popup must show streamed model tokens before the response finishes")
        precondition(workspace.tutorFocusRequest == focusBeforeExplain,
            "Explain must not move focus to the sidebar composer")
        responseGate.finished = true
        for _ in 0..<200 where workspace.isStreaming { try await Task.sleep(for: .milliseconds(20)) }
        precondition(workspace.messages.last?.content.contains("describes eigenvectors") == true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            responseView.window?.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(150))
            try snapshot(try unwrap(responseView.window), at: output.appendingPathComponent("pdf-selection-response-\(name).png"))
        }
        precondition(responseText.string.contains("describes eigenvectors"))
        workspace.draft = "Keep this unsent draft"
        try await clickResponseFooter(responseView, x: 55)
        try await Task.sleep(for: .milliseconds(300))
        precondition(host.responsePopover == nil && workspace.tutorFocusRequest == focusBeforeExplain + 1)
        precondition(workspace.draft == "Keep this unsent draft" && controller.window.firstResponder is BoundedComposerTextView,
            "Opening the response in chat must preserve the draft and focus the sidebar")

        // A failed request must show its error in the popup rather than an older answer.
        host.pdf.setCurrentSelection(passage, animate: false)
        host.showSelectionPopup()
        host.onSelectionAction = { _, _, _ in workspace.error = "Fixture provider unavailable"; return true }
        explain.performClick(nil)
        let failedView = try unwrap(host.responsePopover?.contentViewController?.view)
        try await Task.sleep(for: .milliseconds(150))
        precondition(host.responsePopover?.isShown == true
            && find(NSTextView.self, in: failedView)?.string.contains("describes eigenvectors") != true,
            "A failed request must not display the previous response")
        try snapshot(try unwrap(failedView.window), at: output.appendingPathComponent("pdf-selection-response-error.png"))
        host.closeSelectionResponse()
        workspace.error = nil

        // Stop acts on the same saved request that is streaming into the popup.
        responseGate.finished = false
        workspace.draft = ""
        host.pdf.setCurrentSelection(passage, animate: false)
        host.showSelectionPopup()
        host.onSelectionAction = { text, _, _ in
            workspace.selectedText = text
            workspace.submit(configuration: configuration, complete: completion)
            return workspace.isStreaming
        }
        explain.performClick(nil)
        for _ in 0..<100 where workspace.messages.last?.content.isEmpty == true { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(100))
        let stoppingView = try unwrap(host.responsePopover?.contentViewController?.view)
        try await clickResponseFooter(stoppingView, x: stoppingView.bounds.maxX - 35)
        for _ in 0..<100 where workspace.isStreaming { try await Task.sleep(for: .milliseconds(20)) }
        precondition(!workspace.isStreaming && workspace.messages.last?.metadata == "Stopped"
            && workspace.messages.last?.content == "The selected passage ", "Stopping must preserve the partial response")
        host.closeSelectionResponse()
        responseGate.finished = true
        workspace.draft = "Keep this unsent draft"
        host.onSelectionAction = originalAction
        host.showSelectionPopup()
        let focus = workspace.tutorFocusRequest
        open.performClick(nil)
        try await Task.sleep(for: .milliseconds(350))
        precondition(workspace.tutorFocusRequest == focus + 1 && workspace.selectedText == "eigenvectors")
        precondition(workspace.draft == "Keep this unsent draft")
        precondition(controller.window.firstResponder is BoundedComposerTextView, "Open in chat must focus the composer")
        precondition(popup.isHidden, "Opening chat dismisses the selection popover")
        workspace.draft = ""
        workspace.canvasBusy = true
        precondition(workspace.canSend, "A passage alone must be sendable while background sync runs")
        workspace.submit(configuration: configuration, complete: completion)
        for _ in 0..<200 where workspace.isStreaming { try await Task.sleep(for: .milliseconds(20)) }
        precondition(workspace.messages.count == 6 && workspace.selectedText.isEmpty)
        workspace.flush()
        precondition(StudyWorkspaceModel(store: store).messages.first?.content.contains("> eigenvectors") == true)
        let server = StudyWebServer(app: AppModel.shared, workspace: workspace, assets: URL(fileURLWithPath: "dist/web")) {
            workspace.submit(configuration: configuration, complete: completion)
        }
        server.start(port: 0)
        for _ in 0..<100 where server.address == nil { try await Task.sleep(for: .milliseconds(20)) }
        let address = try unwrap(server.address)
        let browser = Process(); browser.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        browser.arguments = ["node", "scripts/smoke-pdf-selection.mjs", address.absoluteString, output.path]
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            browser.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try browser.run() } catch { continuation.resume(throwing: error) }
        }
        precondition(status == 0)
        print("PASS: native selection response popup, streaming tokens, light/dark rendering, error popup without stale answers, explicit Open in chat focus, preserved drafts and saved document context during background sync")
    }

    static func checkPDFFit() throws {
        let host = StudyPDFHost(frame: .zero), controls = StudyPDFControls()
        defer { host.stopObservingEvents() }
        let document = try unwrap(PDFDocument(data: fixturePDF()))
        host.pdf.document = document; controls.attach(host)
        let page = try unwrap(document.page(at: 0))
        var checked = 0
        for viewport in [NSSize(width: 480, height: 720), NSSize(width: 1200, height: 500)] {
            host.frame = NSRect(origin: .zero, size: viewport)
            for rotation in [0, 90, 180, 270] {
                page.rotation = rotation
                for layout in ["continuous", "page", "spread"] {
                    controls.layout = layout
                    for mode in ["page", "width"] {
                        host.pdf.go(to: page); controls.zoomMode = mode; controls.apply(); host.layout(); host.pdf.layoutDocumentView()
                        let rect = host.pdf.convert(page.bounds(for: host.pdf.displayBox), from: page)
                        guard rect.width <= viewport.width + 1, mode != "page" || rect.height <= viewport.height + 1 else {
                            throw StudyError.message("Fit \(mode) clipped a page: layout=\(layout), rotation=\(rotation), viewport=\(viewport), rendered=\(rect.size)")
                        }
                        precondition(!host.pdf.autoScales, "Explicit fit modes must not revert to PDFKit's automatic width heuristic")
                        checked += 1
                    }
                }
            }
        }
        controls.zoomMode = "custom"; controls.scale = 1.25; controls.apply(); host.layout()
        precondition(abs(host.pdf.scaleFactor - 1.25) < 0.001, "Preset zoom must survive layout")
        print("PASS: \(checked) PDF fit-page/fit-width layouts, rotated pages, viewport sizes and 125% zoom")
    }

    static func checkPDFRegions() async throws {
        let data = NSMutableData(), consumer = try unwrap(CGDataConsumer(data: data))
        var media = CGRect(x: 0, y: 0, width: 400, height: 600)
        let context = try unwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        for (rect, color) in [(CGRect(x: 0, y: 0, width: 200, height: 300), NSColor.red), (CGRect(x: 200, y: 0, width: 200, height: 300), NSColor.green), (CGRect(x: 0, y: 300, width: 200, height: 300), NSColor.blue), (CGRect(x: 200, y: 300, width: 200, height: 300), NSColor.yellow)] {
            context.setFillColor(color.cgColor); context.fill(rect)
        }
        // Keep this geometry/send fixture independent of the system OCR service.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("PDF region verification: red, green, blue and yellow quadrants." as NSString).draw(at: NSPoint(x: 35, y: 565), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        let document = try unwrap(PDFDocument(data: data as Data)), page = try unwrap(document.page(at: 0))
        page.setBounds(CGRect(x: 30, y: 40, width: 340, height: 510), for: .cropBox)
        let samples: [(CGRect, (CGFloat, CGFloat, CGFloat))] = [(CGRect(x: 80, y: 100, width: 50, height: 80), (1,0,0)), (CGRect(x: 250, y: 110, width: 70, height: 65), (0,1,0)), (CGRect(x: 75, y: 380, width: 40, height: 95), (0,0,1))]
        var checked = 0
        for rotation in [0, 90, 180, 270] {
            for zoom: CGFloat in [0.5, 1, 1.75, 2.5] {
                for retina: CGFloat in [1, 2] {
                    for flipped in [false, true] {
                        // Simulated layout transforms include arbitrary offsets,
                        // cropping, rotation and opposite NSView Y directions.
                        var transform = CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180)
                        transform = transform.concatenating(CGAffineTransform(scaleX: zoom, y: flipped ? -zoom : zoom)).concatenating(CGAffineTransform(translationX: 285, y: -170))
                        for (rect, expected) in samples {
                            let visible = page.bounds(for: .cropBox).applying(transform), selection = rect.applying(transform)
                            let region = StudyPDFRegionCapture.Region(page: page, pageToView: transform, visibleBounds: visible, number: 1)
                            let image = try unwrap(StudyPDFRegionCapture.render(regions: [region], rect: selection, flipped: flipped, scale: retina))
                            let bitmap = NSBitmapImageRep(cgImage: image)
                            let color = try unwrap(bitmap.colorAt(x: image.width / 2, y: image.height / 2)?.usingColorSpace(.deviceRGB))
                            precondition(abs(color.redComponent - expected.0) < 0.03 && abs(color.greenComponent - expected.1) < 0.03 && abs(color.blueComponent - expected.2) < 0.03, "PDF region color differs at rotation \(rotation), zoom \(zoom), scale \(retina), flipped \(flipped)")
                            checked += 1
                        }
                    }
                }
            }
        }
        // Verify the PDFView conversion itself without opening a window.
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.document = document; view.displayMode = .singlePage; view.autoScales = false
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation; view.scaleFactor = 1.25; view.layoutDocumentView()
            let rect = view.convert(samples[0].0, from: page)
            let capture = try unwrap(StudyPDFRegionCapture.capture(pdf: view, rect: rect))
            precondition(capture.primaryPage == 1)
            let image = try unwrap(NSBitmapImageRep(data: capture.data)), color = try unwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            guard color.redComponent > 0.8 && color.greenComponent < 0.3 && color.blueComponent < 0.3 else {
                let p: NSPoint = view.convert(NSPoint.zero, from: page), x: NSPoint = view.convert(NSPoint(x: 1, y: 0), from: page), y: NSPoint = view.convert(NSPoint(x: 0, y: 1), from: page)
                throw StudyError.message("Crop integration rotation=\(rotation) color=\(color) rect=\(rect) origin=\(p) x=\(x) y=\(y) flipped=\(view.isFlipped)")
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-crop-send-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root), workspace = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        workspace.createCourse(name: "Crop verification", code: "")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("Quadrants.pdf"); try (data as Data).write(to: file)
        workspace.importDocuments([file])
        for _ in 0..<500 where workspace.isImporting || workspace.documentIndex == nil { try await Task.sleep(for: .milliseconds(20)) }
        guard workspace.document != nil, workspace.documentIndex != nil else { throw StudyError.message("Crop fixture import failed: \(workspace.error ?? "missing document")") }
        let rect = view.convert(samples[0].0, from: page), crop = try unwrap(StudyPDFRegionCapture.capture(pdf: view, rect: rect))
        workspace.setPage(crop.primaryPage); workspace.draftImage = crop.data; workspace.draft = "Explain only the selected red region."
        let config = ProviderConfiguration(provider: ProviderCatalog.provider(id: "openai"), model: "gpt-5-mini", endpoint: "https://fixture.invalid", apiKey: "fixture", language: .english, fastClaudeMode: false)
        workspace.submit(configuration: config) { messages, _, _ in
            precondition(messages.last?.imageData == crop.data, "The exact crop must reach the provider request")
            guard messages.last?.attachments?.contains(where: { $0.extractedText.contains("Current page: 1") }) == true else {
                throw StudyError.message("Crop context missing page: \(messages.last?.attachments?.map(\.extractedText) ?? [])")
            }
            return CompletionResult(text: "Fixture checked.", providerID: "fixture", providerName: "Fixture", model: "Fixture")
        }
        for _ in 0..<500 where workspace.isStreaming { try await Task.sleep(for: .milliseconds(20)) }
        if let error = workspace.error { throw StudyError.message(error) }
        precondition(workspace.messages.count == 2 && workspace.messages.first?.imageData == crop.data)
        workspace.flush()
        precondition(StudyWorkspaceModel(store: store).messages.first?.imageData == crop.data, "Saved conversation must retain the actual crop")
        print("PASS: \(checked) PDF crop rasters plus PDFView conversion and exact-image send/save; zoom, Retina, rotated pages, crop boxes and offsets")
    }

    static func checkDownloadNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-download-names-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let bytes = try fixturePDF()
        var document = try StudyDocumentImporter.read(data: bytes, name: "Øving 3.pdf", store: store)
        var course = StudyCourse(name: "Linear algebra", code: "TMA4115")
        precondition(document.fileName == "original.pdf")
        precondition(document.downloadFileName(in: course) == "Øving 3.pdf")
        let destination = root.appendingPathComponent(document.downloadFileName(in: course))
        try Data(contentsOf: store.file(for: document)).write(to: destination)
        let saved = try Data(contentsOf: destination)
        precondition(saved == bytes, "Saving with the original name must preserve PDF bytes")
        document.originalFileName = nil
        document.sourceKey = "files:42"
        course.canvasMaterials = [CanvasMaterialReference(id: "files:42", kind: .files, remoteID: "42",
            title: "Exercise 4", fileName: "Exercise 4 - vectors.pdf", sourceURL: "https://canvas.ntnu.no/files/42", version: "v1")]
        precondition(document.downloadFileName(in: course) == "Exercise 4 - vectors.pdf")
        document.sourceKey = nil
        document.title = "Eigenvectors.pdf"
        precondition(document.downloadFileName(in: course) == "TMA4115 - Eigenvectors.pdf")
        course.code = ""
        precondition(document.downloadFileName(in: course) == "Linear algebra - Eigenvectors.pdf")
        let code = try StudyDocumentImporter.read(data: Data("print(42)".utf8), name: "linear_maps.py", store: store)
        precondition(code.downloadFileName(in: course) == "linear_maps.py")
        let image = StudyDocument(title: "Figure", kind: .image, fileName: "original.jpg", pageCount: 1, originalFileName: "Figure.png")
        precondition(image.downloadFileName(in: course) == "Figure.jpg", "Converted images retain their saved format")
        print("PASS: download names preserve original and Canvas filenames, legacy course/title fallbacks and saved bytes")
    }

    static func checkFormats() throws {
        let argument = try unwrap(CommandLine.arguments.firstIndex(of: "--fixtures"))
        let root = URL(fileURLWithPath: CommandLine.arguments[argument + 1])
        let store = StudyLibraryStore(root: root.appendingPathComponent("store"))
        func read(_ name: String) throws -> StudyDocument { try StudyDocumentImporter.read(data: Data(contentsOf: root.appendingPathComponent(name)), name: name, store: store) }
        let code = try read("analysis.py"), codeIndex = try store.index(for: code)
        precondition(code.kind == .code && code.pageCount == 2)
        precondition(codeIndex.pages[0].text.contains("    return x * 2"))
        precondition(codeIndex.pages[1].text.contains("Lines 161"))
        let notebook = try read("lab.ipynb"), notebookIndex = try store.index(for: notebook)
        precondition(notebook.kind == .notebook && notebook.pageCount == 2)
        precondition(notebookIndex.pages[1].text.contains("Saved result: 42"))
        precondition(notebookIndex.pages[1].images?.count == 1)
        precondition(StudyContextBuilder.pageImages(document: notebook, pages: [2], store: store).count == 1)
        let word = try read("lecture.docx"), wordIndex = try store.index(for: word)
        precondition(word.kind == .office && wordIndex.pages[0].text.contains("Eigenvectors"))
        precondition(wordIndex.pages[0].text.contains("| Horizontal | 2 |"))
        precondition(wordIndex.pages[0].images?.count == 1)
        let slides = try read("slides.pptx"), slideIndex = try store.index(for: slides)
        precondition(slides.pageCount == 2 && slideIndex.pages[0].text.contains("Taught first") && slideIndex.pages[1].text.contains("Taught second"))
        precondition(slideIndex.pages[0].images?.count == 1)
        let sheet = try read("measurements.xlsx"), sheetIndex = try store.index(for: sheet)
        precondition(sheetIndex.pages[0].text.contains("| Row | A | B | C | D |"))
        precondition(sheetIndex.pages[0].text.contains("12 (=SUM(D1:D1))"))
        let odt = try read("reading.odt")
        let odtIndex = try store.index(for: odt)
        precondition(odtIndex.pages[0].text.contains("OpenDocument"))
        let legacy = try read("legacy.doc")
        precondition(legacy.kind == .preview && legacy.contentNotice?.contains("not been text-indexed") == true)
        for name in ["unsafe.docx", "entities.docx"] {
            do { _ = try read(name); preconditionFailure("Unsafe Office parts must be rejected") } catch {}
        }
        let engine = StudyDocumentSearch()
        let pages = [StudyPage(number: 1, text: "Photosynthesis converts solar radiation into energy in plants."), StudyPage(number: 2, text: "A matrix rotates a vector.")]
        precondition(engine.matches(pages: pages, query: "matrix", semantic: false) == [2])
        precondition(engine.matches(pages: pages, query: "how do plants use sunlight", semantic: true).first == 1)
        let pack = StudyContextBuilder.build(document: notebook, index: notebookIndex, currentPage: 2, question: "Explain this plot", selection: "saved results", course: StudyCourse(name: "Fixture", documents: [notebook]), store: store, includeCourse: false)
        precondition(pack.text.contains("Saved result: 42") && pack.text.contains("saved results"))
    }

    static func checkMaterialGroups() throws {
        func ref(_ id: String, _ title: String) -> CanvasMaterialReference { CanvasMaterialReference(id: id, kind: .files, remoteID: id, title: title, fileName: title + ".pdf", sourceURL: "https://canvas.ntnu.no/courses/11/files/1", version: "v1") }
        var first = ref("files:1", "Lecture 10"), second = ref("files:2", "Lecture 2")
        first.moduleID = 7; first.moduleTitle = "Week 1"; first.modulePosition = 1; first.moduleItemPosition = 2
        second.moduleID = 7; second.moduleTitle = "Week 1"; second.modulePosition = 1; second.moduleItemPosition = 1
        var saved = StudyDocument(title: "Lecture 10", kind: .pdf, fileName: "original.pdf", pageCount: 1, sourceKey: first.id, sourceVersion: "v1")
        saved.lastPage = 1
        let course = StudyCourse(name: "Test", documents: [saved], canvasMaterials: [first, second, ref("files:3", "Lecture 10 other"), ref("files:4", "Lecture 2 other"), ref("files:5", "Random name")])
        let groups = StudyMaterialOrganizer.groups(for: course)
        precondition(groups.first?.items.map(\.title) == ["Lecture 2", "Lecture 10"])
        precondition(groups.first?.items.last?.documentID == saved.id)
        precondition(groups.flatMap(\.items).count == 5, "Saved material must not be duplicated")
        precondition(groups.first { $0.id == "lectures" }?.items.map(\.title) == ["Lecture 2 other", "Lecture 10 other"])
        precondition(groups.first { $0.id == "documents" }?.items.first?.title == "Random name")
        precondition(StudyMaterialOrganizer.groups(for: course, query: "Week 1").flatMap(\.items).count == 2)
        precondition(StudyMaterialOrganizer.category(title: "forel2_bban4040_handout.pdf", fileName: nil, kind: .files, documentKind: nil).0 == "lectures")
        precondition(StudyMaterialOrganizer.category(title: "lf_oving3_bban4040.pdf", fileName: nil, kind: .files, documentKind: nil).0 == "exercises")
        precondition(StudyMaterialOrganizer.category(title: "icon-star.png", fileName: "icon-star.png", kind: .files, documentKind: nil).0 == "assets")
        var inventory = course
        let imported = StudyDocument(title: "My notes", kind: .text, fileName: "original.md", pageCount: 1, originalFileName: "My notes.txt")
        let orphanFile = StudyDocument(title: "Removed file", kind: .pdf, fileName: "original.pdf", pageCount: 1, sourceKey: "files:removed")
        let instructions = StudyDocument(title: "Assignment instructions", kind: .text, fileName: "original.md", pageCount: 1, sourceKey: "assignments:1")
        inventory.documents += [imported, orphanFile, instructions]
        var asset = ref("files:asset", "Course logo"); asset.fileName = "icon-logo.png"
        var assignment = first; assignment.id = "assignments:1"; assignment.kind = .assignments
        inventory.canvasMaterials?.append(contentsOf: [asset, assignment])
        let files = StudyMaterialOrganizer.files(for: inventory)
        precondition(files.count == 8 && Set(files.map(\.id)).count == 8, "All files includes local, remote and orphaned downloads without duplicating cached Canvas files")
        precondition(files.contains { $0.title == "icon-logo.png" && $0.documentID == nil }, "Collapsed course assets remain visible in All files")
        precondition(files.contains { $0.title == "My notes.txt" } && files.contains { $0.title == "Removed file.pdf" })
        precondition(!files.contains { $0.materialID == assignment.id || $0.documentID == instructions.id }, "Generated Canvas descriptions are not original files")
        precondition(files.firstIndex { $0.title == "Lecture 2.pdf" }! < files.firstIndex { $0.title == "Lecture 10.pdf" }!, "Raw files use natural filename order")
        precondition(StudyMaterialOrganizer.files(for: inventory, query: ".PNG").map(\.title) == ["icon-logo.png"])
        precondition(StudyMaterialOrganizer.files(for: inventory, query: "no such file").isEmpty)
        var frequent = inventory; frequent.canvasID = 1; frequent.visitCount = 2
        for index in frequent.canvasMaterials!.indices { frequent.canvasMaterials![index].byteCount = 1000 }
        precondition(StudyCoursePreloading.candidates(in: frequent).isEmpty, "Newly visited courses do not preload")
        frequent.visitCount = 3
        let candidates = StudyCoursePreloading.candidates(in: frequent)
        precondition(candidates.count == 3 && !candidates.contains { $0.id == first.id || $0.id == asset.id || $0.kind != .files })
        frequent.canvasMaterials = [ref("files:large", "Large"), ref("files:unknown", "Unknown")]
        frequent.canvasMaterials![0].byteCount = 11_000_000
        precondition(StudyCoursePreloading.candidates(in: frequent).isEmpty, "Large and unknown-size downloads are never prefetched")
        let navigationRoot = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-navigation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: navigationRoot) }
        let navigation = StudyWorkspaceModel(store: StudyLibraryStore(root: navigationRoot))
        navigation.createCourse(name: "Course A", code: "A")
        let a = navigation.course!.id
        navigation.draft = "Keep my draft"
        navigation.createCourse(name: "Course B", code: "B")
        let b = navigation.course!.id
        navigation.goBack(); precondition(navigation.course?.id == a && navigation.draft == "Keep my draft")
        navigation.goForward(); precondition(navigation.course?.id == b)
        navigation.showCourseLibrary(); navigation.goBack(); precondition(navigation.course?.id == b && !navigation.isShowingLibrary)
        navigation.flush()
        let reopened = StudyWorkspaceModel(store: navigation.store)
        precondition(reopened.library.courses.first { $0.id == a }?.threads.first?.draft == "Keep my draft", "Background saves and flush retain the latest draft")
        let numbered = StudyCourse(name: "Numbered lectures", canvasMaterials: [ref("a", "demo_forel5"), ref("b", "forel2_handout"), ref("c", "forel10_notes")])
        precondition(StudyMaterialOrganizer.groups(for: numbered).first?.items.map(\.title) == ["forel2_handout", "demo_forel5", "forel10_notes"])
        precondition(StudyMaterialOrganizer.category(title: "analysis.ipynb", fileName: "analysis.ipynb", kind: .files, documentKind: nil).0 == "code")
        let removed = CanvasCatalogChanges.reconcile(previous: [first, second], catalog: CanvasMaterialCatalog(items: [second], warnings: [], completeKinds: [.files], moduleOrderComplete: true))
        precondition(removed.changes.removed == [first.id])
        let retained = CanvasCatalogChanges.reconcile(previous: [first, second], catalog: CanvasMaterialCatalog(items: [], warnings: ["Files unavailable"]))
        precondition(retained.items.count == 2 && retained.changes.removed.isEmpty && retained.changes.retained.count == 2)
        var moved = second; moved.moduleItemPosition = 3
        let changed = CanvasCatalogChanges.reconcile(previous: [first, second], catalog: CanvasMaterialCatalog(items: [first, moved, ref("new", "New reading")], warnings: [], completeKinds: [.files], moduleOrderComplete: true))
        precondition(changed.changes.updated == [second.id] && changed.changes.added == ["new"])
        var partial = first; partial.moduleID = nil; partial.moduleTitle = nil; partial.version = ""
        let merged = CanvasCatalogChanges.reconcile(previous: [first], catalog: CanvasMaterialCatalog(items: [partial], warnings: ["Modules unavailable"]))
        precondition(merged.items.first?.moduleID == 7 && merged.items.first?.version == "v1")
    }

    static func checkDocumentEditing() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("scholia-editing-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        let store = StudyLibraryStore(root: root), original = Data("def square(x):\n    return x * x\n".utf8)
        var code = try StudyDocumentImporter.read(data: original, name: "square.py", store: store)
        code.sourceKey = "files:123"; code.sourceVersion = "v1"
        let workspace = StudyWorkspaceModel(store: store)
        workspace.createCourse(name: "Editing fixture", code: "EDIT")
        workspace.library.courses[0].documents = [code]; workspace.selectDocument(code.id)
        var draft = try StudyDocumentEditing.read(code, store: store)
        let stale = draft
        draft.source = "def cube(x):\n    return x ** 3\n"
        try await workspace.saveDocumentEdits(draft)
        let saved = try unwrap(workspace.document), savedData = try Data(contentsOf: store.file(for: saved))
        precondition(savedData == Data(draft.source!.utf8) && saved.id == code.id && saved.sourceKey == code.sourceKey && saved.locallyEditedAt != nil)
        let savedIndex = try store.index(for: saved)
        precondition(savedIndex.pages[0].text.contains("    return x ** 3"))
        let pack = StudyContextBuilder.build(document: saved, index: savedIndex, currentPage: 1, question: "Explain cube", selection: "", course: workspace.course!, store: store, includeCourse: false)
        precondition(pack.text.contains("def cube(x)") && !pack.text.contains("def square(x)"), "The tutor must receive the saved edit")
        let backup = try unwrap(fm.contentsOfDirectory(at: root.appendingPathComponent("Revisions/\(code.id)"), includingPropertiesForKeys: nil).first)
        let backupData = try Data(contentsOf: backup.appendingPathComponent(code.fileName))
        precondition(backupData == original, "The original must remain recoverable")
        do { _ = try StudyDocumentEditing.save(stale, document: saved, store: store); preconditionFailure("Stale edits must not overwrite another save") } catch {}
        var empty = try StudyDocumentEditing.read(saved, store: store); empty.source = ""
        let cleared = try StudyDocumentEditing.save(empty, document: saved, store: store)
        let emptyData = try Data(contentsOf: store.file(for: cleared)); precondition(emptyData.isEmpty)

        let book: [String: Any] = ["nbformat": 4, "nbformat_minor": 5, "custom": ["keep": true], "metadata": ["language_info": ["name": "python"]], "cells": [
            ["cell_type": "markdown", "id": "intro", "source": ["# Original\n"], "metadata": ["tags": ["lesson"]]],
            ["cell_type": "code", "id": "calc", "source": ["print(2)\n"], "execution_count": 9, "metadata": ["keep": "yes"], "outputs": [["output_type": "stream", "name": "stdout", "text": ["2\n"]]]]
        ]]
        let bookData = try JSONSerialization.data(withJSONObject: book)
        let notebook = try StudyDocumentImporter.read(data: bookData, name: "lesson.ipynb", store: store)
        var bookDraft = try StudyDocumentEditing.read(notebook, store: store)
        let unchanged = try StudyDocumentEditing.applying(bookDraft, to: bookData, document: notebook)
        precondition(unchanged == bookData, "Opening and saving without changes must not reformat a notebook")
        bookDraft.cells[0].source = "# Revised\n"; bookDraft.cells[1].source = "print(3)\n"
        let updated = try StudyDocumentEditing.save(bookDraft, document: notebook, store: store)
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: store.file(for: updated))) as! [String: Any]
        let cells = result["cells"] as! [[String: Any]], previous = book["cells"] as! [[String: Any]]
        precondition(NSDictionary(dictionary: result["metadata"] as! [String: Any]).isEqual(to: book["metadata"] as! [String: Any]))
        precondition(NSDictionary(dictionary: result["custom"] as! [String: Any]).isEqual(to: book["custom"] as! [String: Any]))
        precondition(NSArray(array: cells[1]["outputs"] as! [Any]).isEqual(to: previous[1]["outputs"] as! [Any]))
        precondition(cells[1]["id"] as? String == "calc" && cells[1]["execution_count"] as? Int == 9)
        let updatedIndex = try store.index(for: updated)
        precondition(updatedIndex.pages[1].text.contains("print(3)") && updatedIndex.pages[1].text.contains("before this cell was edited"))
        let editing = StudyEditingState(store: store)
        editing.begin(updated)
        for _ in 0..<100 where editing.busy { try await Task.sleep(for: .milliseconds(10)) }
        editing.setSource("# Recovered draft", documentID: updated.id, cell: 0); editing.flush()
        let restored = StudyEditingState(store: store); restored.begin(updated)
        for _ in 0..<100 where restored.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(restored.drafts[updated.id]?.cells[0].source == "# Recovered draft")
        restored.cancel(updated.id)
        precondition(!fm.fileExists(atPath: root.appendingPathComponent("Editing/\(updated.id).json").path))
        print("PASS: local code/notebook edits, updated tutor context, original backups, empty files, metadata/output preservation, conflict rejection and draft recovery")
    }

    static func checkCatalogChanges() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CanvasFixtureProtocol.self]
        let client = CanvasClient(origin: try CanvasAddress.origin("canvas.ntnu.no"), token: "fixture-token", session: URLSession(configuration: config))
        CanvasFixtureProtocol.state.revision = 1; CanvasFixtureProtocol.state.reset()
        let firstCourses = try await client.courses(), first = try await client.catalog(courseID: 11)
        precondition(firstCourses.count == 2)
        CanvasFixtureProtocol.state.reset()
        let secondCourses = try await client.courses(), second = try await client.catalog(courseID: 11)
        precondition(secondCourses.count == 2, "304 pagination must retain the original Link header")
        precondition(CanvasFixtureProtocol.state.notModified >= 5, "Metadata refresh must send conditional requests")
        precondition(CanvasCatalogChanges.reconcile(previous: first.items, catalog: second).changes.count == 0)
        precondition(second.items.first { $0.id == "files:42" }?.moduleID == 5)
        CanvasFixtureProtocol.state.revision = 2
        let changed = try await client.catalog(courseID: 11)
        precondition(CanvasCatalogChanges.reconcile(previous: second.items, catalog: changed).changes.updated.contains("pages:lecture"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-catalog-data-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        workspace.loadCanvasCourses(clientOverride: client)
        for _ in 0..<500 where workspace.canvasBusy { try await Task.sleep(for: .milliseconds(20)) }
        let course = try unwrap(workspace.library.courses.first { $0.canvasID == 11 })
        workspace.selectCourse(course.id); workspace.toggleFavorite(course.id)
        let reference = try unwrap(course.materials.first { $0.id == "pages:lecture" })
        workspace.openCanvasMaterial(reference, courseID: course.id)
        for _ in 0..<500 where workspace.canvasBusy { try await Task.sleep(for: .milliseconds(20)) }
        let savedID = try unwrap(workspace.document?.id)
        CanvasFixtureProtocol.state.reset()
        workspace.openCanvasMaterial(reference, courseID: course.id)
        precondition(CanvasFixtureProtocol.state.paths.isEmpty)
        workspace.loadCanvasCourses(clientOverride: client)
        for _ in 0..<500 where workspace.canvasBusy { try await Task.sleep(for: .milliseconds(20)) }
        precondition(workspace.document?.id == savedID && workspace.course?.isFavorite == true && !workspace.isShowingLibrary)
        CanvasFixtureProtocol.state.revision = 3
        workspace.syncCanvasCourses(courseIDs: [course.id])
        for _ in 0..<500 where workspace.canvasBusy { try await Task.sleep(for: .milliseconds(20)) }
        let updated = try unwrap(workspace.course?.materials.first { $0.id == reference.id })
        let oldDocument = try unwrap(workspace.document)
        precondition(workspace.course?.updateAvailable(for: oldDocument) != nil)
        workspace.openCanvasMaterial(updated, courseID: course.id)
        for _ in 0..<500 where workspace.canvasBusy { try await Task.sleep(for: .milliseconds(20)) }
        precondition(workspace.document?.id == savedID && workspace.document?.sourceVersion == "v3")
        workspace.flush()
        let reopened = StudyWorkspaceModel(store: workspace.store)
        precondition(reopened.document?.id == savedID && reopened.course?.isFavorite == true)
        var localDraft = try StudyDocumentEditing.read(try unwrap(workspace.document), store: workspace.store)
        localDraft.source = "My local lecture notes must survive a Canvas update."
        try await workspace.saveDocumentEdits(localDraft)
        CanvasFixtureProtocol.state.revision = 4
        workspace.syncCanvasCourses(courseIDs: [course.id])
        for _ in 0..<500 where workspace.canvasBusy { try await Task.sleep(for: .milliseconds(20)) }
        workspace.openCanvasMaterial(try unwrap(workspace.course?.materials.first { $0.id == reference.id }), courseID: course.id)
        for _ in 0..<500 where workspace.canvasBusy { try await Task.sleep(for: .milliseconds(20)) }
        let preserved = try unwrap(workspace.course?.documents.first { $0.id == savedID })
        let localData = try String(contentsOf: workspace.store.file(for: preserved), encoding: .utf8)
        precondition(preserved.locallyEditedAt != nil && preserved.sourceKey == nil && localData == localDraft.source)
        precondition(workspace.document?.id != savedID && workspace.document?.sourceVersion == "v4", "Canvas updates must keep local edits as a separate document")
        CanvasFixtureProtocol.state.revision = 1
    }

    static func run() async throws {
        try checkSemesters()
        try await checkStudyFlow()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-study-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let workspace = StudyWorkspaceModel(store: store)
        let controller = StudyWindowController(app: AppModel.shared, workspace: workspace, autosave: false)
        controller.window.appearance = NSAppearance(named: .aqua)
        controller.show()
        try await Task.sleep(for: .milliseconds(500))
        try snapshot(controller.window, at: output.appendingPathComponent("workspace-welcome.png"))

        workspace.createCourse(name: "Linear algebra & differential equations", code: "TMA4115")
        let pdfData = try fixturePDF()
        let source = root.appendingPathComponent("Linear transformations.pdf")
        try pdfData.write(to: source)
        workspace.importDocuments([source])
        for _ in 0..<500 where workspace.isImporting || workspace.documentIndex == nil { try await Task.sleep(for: .milliseconds(20)) }
        let document = try unwrap(workspace.document)
        precondition(document.pageCount == 3)
        workspace.setPage(2)
        let course = try unwrap(workspace.course)
        let pack = StudyContextBuilder.build(document: document, index: workspace.documentIndex, currentPage: 2,
                                            question: "Explain the eigenvectors on page 3", selection: "Av = λv", course: course, store: store, includeCourse: true)
        precondition(pack.wholeDocument && pack.sources.count == 3)
        precondition(pack.text.contains("Current page: 2 of 3"))
        let images = StudyContextBuilder.pageImages(document: document, pages: [2, 3], store: store)
        precondition(images.count == 2 && images.allSatisfy { $0.imageData?.isEmpty == false })
        try await Task.sleep(for: .milliseconds(150))
        workspace.selectingFigure = true
        try await Task.sleep(for: .milliseconds(100))
        let host = try unwrap(find(StudyPDFHost.self, in: try unwrap(controller.window.contentView)))
        let start = host.crop.convert(NSPoint(x: 70, y: 100), to: nil)
        let end = host.crop.convert(NSPoint(x: 200, y: 240), to: nil)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try unwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                         windowNumber: controller.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        host.crop.mouseDown(with: try mouse(.leftMouseDown, start))
        host.crop.mouseDragged(with: try mouse(.leftMouseDragged, end))
        host.crop.mouseUp(with: try mouse(.leftMouseUp, end))
        precondition(workspace.draftImage?.isEmpty == false, "Figure selection must produce an actual raster")
        workspace.draftImage = nil
        let model = ProviderConfiguration(provider: ProviderCatalog.provider(id: "ollama"), model: "smoke", endpoint: "http://127.0.0.1:11434", apiKey: "", language: .english, fastClaudeMode: false)
        workspace.draft = "Why does the matrix stretch some directions without rotating them?"
        workspace.selectedText = "Av = λv"
        workspace.submit(configuration: model) { messages, _, onToken in
            precondition(messages.last?.content.hasPrefix("Why does the matrix stretch") == true)
            let prepared = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english)
            precondition(prepared.messages.last?.content.contains("Current page: 2 of 3") == true)
            precondition(prepared.messages.last?.content.contains("Av = λv") == true)
            let answer = """
            An **eigenvector** points along a direction that the transformation preserves. The matrix can stretch or shrink it, but it stays on the same line. [p. 2]

            $$A\\mathbf{v}=\\lambda\\mathbf{v}$$

            Think of the grid on the left as a rubber sheet. Most arrows turn as the sheet stretches. The two highlighted directions keep their orientation.

            - **The vector** $\\mathbf{v}$ gives a preserved direction.
            - **The eigenvalue** $\\lambda$ tells you the scale factor.

            For $A=\\begin{pmatrix}2&0\\\\0&1\\end{pmatrix}$, a horizontal arrow doubles in length while a vertical arrow keeps its length. [p. 3]

            What would happen to a vector pointing diagonally between those two directions?
            """
            onToken(String(answer.prefix(80)))
            return CompletionResult(text: answer, providerID: "smoke", providerName: "Smoke fixture", model: "Local test fixture")
        }
        for _ in 0..<500 where workspace.isStreaming { try await Task.sleep(for: .milliseconds(20)) }
        precondition(workspace.messages.count == 2)
        precondition(workspace.course?.threads.count == 1, "The first question must create exactly one conversation")
        precondition(workspace.messages.first?.content.hasPrefix("Why does the matrix stretch") == true)
        workspace.edit(try unwrap(workspace.messages.first))
        precondition(workspace.messages.count == 2)
        workspace.cancelEdit()
        workspace.flush()
        let restored = StudyWorkspaceModel(store: store)
        precondition(restored.messages.count == 2 && restored.document?.lastPage == 2)
        workspace.draft = "An unsent follow-up"
        workspace.flush()
        precondition(StudyWorkspaceModel(store: store).draft == "An unsent follow-up")
        workspace.draft = ""; workspace.flush()
        try await Task.sleep(for: .milliseconds(700))
        try snapshot(controller.window, at: output.appendingPathComponent("workspace-reader.png"))
        for size in [NSSize(width: 1_040, height: 700), NSSize(width: 1_420, height: 900)] {
            controller.window.setContentSize(size)
            let frame = controller.window.frame
            try await Task.sleep(for: .milliseconds(250))
            precondition(controller.window.frame == frame, "Content unexpectedly resized the native window")
        }
        controller.window.setContentSize(NSSize(width: 1_040, height: 700))
        try await Task.sleep(for: .milliseconds(400))
        try snapshot(controller.window, at: output.appendingPathComponent("workspace-compact.png"))
        controller.window.setContentSize(NSSize(width: 1_420, height: 900))
        controller.window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(500))
        try snapshot(controller.window, at: output.appendingPathComponent("workspace-dark.png"))
        controller.window.appearance = NSAppearance(named: .aqua)
        workspace.canvasPresented = true
        try await Task.sleep(for: .milliseconds(400))
        if let sheet = controller.window.attachedSheet { try snapshot(sheet, at: output.appendingPathComponent("workspace-canvas.png")) }
        workspace.canvasPresented = false
        try await Task.sleep(for: .milliseconds(200))
        try await canvasFixtures()
        try await courseCatalogWorkflow(workspace: workspace, controller: controller, output: output)
        controller.window.close()
        try contextEdgeCases(store: store)
        workspace.newThread()
        workspace.draft = "A cancelled question"
        workspace.submit(configuration: model) { _, _, _ in
            try await Task.sleep(for: .seconds(5))
            throw StudyError.message("Cancelled requests should not reach completion")
        }
        workspace.stopAnswer()
        for _ in 0..<100 where workspace.isStreaming { try await Task.sleep(for: .milliseconds(20)) }
        precondition(!workspace.isStreaming && workspace.messages.map(\.role) == [.user, .assistant],
            "Cancellation must retain the question and its recorded activity")
        precondition(workspace.messages.first?.content == "A cancelled question"
            && workspace.messages.last?.content.isEmpty == true
            && workspace.messages.last?.metadata == "Stopped"
            && workspace.messages.last?.isStreaming == false,
            "Cancelled answers must stop cleanly without fabricated answer text")
    }

    static func checkStudyFlow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-study-flow-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        var first = StudyDocument(title: "First reading", kind: .text, fileName: "first.md", pageCount: 3)
        first.lastPage = 2
        let second = StudyDocument(title: "Second reading", kind: .text, fileName: "second.md", pageCount: 3)
        let unread = StudyDocument(title: "Not opened", kind: .text, fileName: "unread.md", pageCount: 1)
        for document in [first, second] {
            try store.write(document: document, index: StudyDocumentIndex(pages: (1...3).map { StudyPage(number: $0, text: "Page \($0)") }), data: Data("Saved reading".utf8))
        }
        let algebra = StudyCourse(name: "Algebra", documents: [first, unread])
        let biology = StudyCourse(name: "Biology", documents: [second])
        try store.save(StudyLibrary(courses: [algebra, biology], showingCourseLibrary: true))
        let workspace = StudyWorkspaceModel(store: store)
        precondition(workspace.recentReadings.isEmpty, "Imports must not be presented as visited readings")
        workspace.resumeReading(first.id)
        precondition(workspace.course?.id == algebra.id && workspace.currentPage == 2)
        workspace.setPage(3)
        workspace.selectedText = "an equation"
        workspace.setPage(3)
        precondition(workspace.selectedText == "an equation", "Duplicate page notifications must preserve the selected passage")
        workspace.draft = "My own question."
        workspace.prepareStudyPrompt(.practice)
        let draft = workspace.draft
        workspace.prepareStudyPrompt(.practice)
        precondition(workspace.draft == draft && draft == "My own question." && workspace.practicePresented)
        workspace.resumeReading(second.id)
        precondition(workspace.course?.id == biology.id && workspace.currentPage == 1)
        precondition(workspace.recentReadings.map(\.id) == [second.id, first.id])
        workspace.resumeReading(first.id)
        precondition(workspace.mode == .practice && workspace.draft == draft && workspace.currentPage == 3)
        workspace.resumeReading(UUID())
        precondition(workspace.document?.id == first.id, "A stale reading must not change the selection")
        workspace.showCourseLibrary(); workspace.flush()
        let reopened = StudyWorkspaceModel(store: store)
        precondition(reopened.recentReadings.first?.document.lastPage == 3 && reopened.recentReadings.count == 2)
        precondition(reopened.draft == draft && reopened.isShowingLibrary)
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as! [String: Any]
        legacy.removeValue(forKey: "lastOpenedAt")
        let decoded = try JSONDecoder().decode(StudyDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(decoded.lastOpenedAt == nil && decoded.lastPage == 2)
        let savedDocument = try unwrap(reopened.recentReadings.first?.document)
        var edit = try StudyDocumentEditing.read(savedDocument, store: store)
        edit.source = "Updated reading"
        let edited = try StudyDocumentEditing.save(edit, document: savedDocument, store: store)
        precondition(edited.lastOpenedAt == savedDocument.lastOpenedAt, "Editing must retain resume history")
        precondition(StudyTeachingMode.practice.starter(document: nil).contains("downloaded course materials"))
        print("PASS: recent reading order, cross-course resume, page and draft persistence, study starters, legacy decoding and edit history")
    }

    static func snapshot(_ window: NSWindow, at url: URL) throws {
        let view = try unwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try unwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
        print("Screenshot: \(url.path)")
    }

    static func fixturePDF() throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = try unwrap(CGDataConsumer(data: data as CFMutableData))
        let context = try unwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in 1...3 {
            context.beginPDFPage(nil)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            NSColor.white.setFill(); box.fill()
            ("TMA4115  /  LECTURE NOTES" as NSString).draw(at: NSPoint(x: 54, y: 729), withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.gray])
            let title = page == 1 ? "Linear transformations" : page == 2 ? "Directions that stay the same" : "A concrete example"
            (title as NSString).draw(at: NSPoint(x: 54, y: 666), withAttributes: [.font: NSFont.systemFont(ofSize: 26, weight: .semibold)])
            let body = page == 1 ? "A linear map preserves vector addition and scalar multiplication.\nWe can understand a matrix by watching what it does to a grid."
                : page == 2 ? "Some vectors change length without changing their line of action.\nThese are the eigenvectors of the transformation.\n\nAv = λv\n\nThe scalar λ is the eigenvalue associated with v."
                : "Consider the diagonal matrix A = diag(2, 1).\nThe vector (1, 0) has eigenvalue 2.\nThe vector (0, 1) has eigenvalue 1.\nThese independent directions form a basis for the plane."
            (body as NSString).draw(in: NSRect(x: 54, y: 470, width: 500, height: 158), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.darkGray])
            for i in 0...10 {
                let offset = CGFloat(i) * 31
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 150 + offset, y: 130)); path.line(to: NSPoint(x: 150 + offset, y: 440))
                path.move(to: NSPoint(x: 150, y: 130 + offset)); path.line(to: NSPoint(x: 460, y: 130 + offset))
                NSColor.lightGray.withAlphaComponent(0.4).setStroke(); path.lineWidth = 0.5; path.stroke()
            }
            let arrow = NSBezierPath(); arrow.move(to: NSPoint(x: 305, y: 285)); arrow.line(to: NSPoint(x: 435, y: 285))
            arrow.move(to: NSPoint(x: 426, y: 290)); arrow.line(to: NSPoint(x: 435, y: 285)); arrow.line(to: NSPoint(x: 426, y: 280))
            NSColor.systemGreen.setStroke(); arrow.lineWidth = 3; arrow.stroke()
            let vertical = NSBezierPath(); vertical.move(to: NSPoint(x: 305, y: 285)); vertical.line(to: NSPoint(x: 305, y: 385))
            NSColor.systemOrange.setStroke(); vertical.lineWidth = 3; vertical.stroke()
            ("\(page)" as NSString).draw(at: NSPoint(x: 305, y: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 10)])
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF(); return data as Data
    }

    static func canvasFixtures() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CanvasFixtureProtocol.self]
        let origin = try CanvasAddress.origin("canvas.ntnu.no")
        let client = CanvasClient(origin: origin, token: "fixture-token", session: URLSession(configuration: config))
        let account = try await client.account(); precondition(account.id == 7)
        let courses = try await client.courses(); precondition(courses.count == 2)
        let material = try await client.catalog(courseID: 11)
        precondition(material.items.contains { $0.id == "pages:lecture" })
        precondition(material.items.contains { $0.id == "files:42" })
        precondition(!material.warnings.isEmpty, "Partial Canvas failures must be visible")
        let downloaded = try await client.download(URL(string: "https://storage.example.org/file.pdf")!)
        precondition(String(data: downloaded, encoding: .utf8) == "clean download")
        precondition(CanvasAddress.nextPage("<https://evil.example/api/v1/courses>; rel=\"next\"", current: origin.appendingPathComponent("api/v1/courses"), origin: origin) == nil)
    }

    static func courseCatalogWorkflow(workspace: StudyWorkspaceModel, controller: StudyWindowController, output: URL) async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CanvasFixtureProtocol.self]
        let client = CanvasClient(origin: try CanvasAddress.origin("canvas.ntnu.no"), token: "fixture-token", session: URLSession(configuration: config))
        CanvasFixtureProtocol.state.reset()
        CanvasFixtureProtocol.state.pdf = try fixturePDF()
        workspace.loadCanvasCourses(clientOverride: client)
        for _ in 0..<500 where workspace.canvasBusy { try await Task.sleep(for: .milliseconds(20)) }
        precondition(!workspace.canvasBusy)
        let indexed = workspace.library.courses.filter { $0.canvasID != nil }
        precondition(indexed.count == 2 && indexed.allSatisfy { $0.documents.isEmpty && $0.catalogUpdatedAt != nil })
        precondition(CanvasFixtureProtocol.state.paths.contains("/api/v1/courses/11/pages/lecture"),
            "Catalog discovery must crawl page links")
        precondition(!CanvasFixtureProtocol.state.paths.contains("/api/v1/courses/11/files/42"),
            "A module-only file already in the catalog should resolve download metadata only when opened")
        precondition(!CanvasFixtureProtocol.state.paths.contains { $0.contains("storage.example") },
            "Catalog discovery must not download file bodies")
        let algebra = try unwrap(indexed.first { $0.canvasID == 11 })
        workspace.toggleFavorite(algebra.id)
        workspace.selectCourse(algebra.id)
        let page = try unwrap(algebra.materials.first { $0.id == "pages:lecture" })
        CanvasFixtureProtocol.state.reset()
        workspace.openCanvasMaterial(page, courseID: algebra.id)
        for _ in 0..<500 where workspace.canvasBusy || workspace.documentIndex == nil { try await Task.sleep(for: .milliseconds(20)) }
        precondition(workspace.document?.title == "Lecture" && workspace.currentPageText.contains("Eigenvectors"))
        precondition(CanvasFixtureProtocol.state.paths == ["/api/v1/courses/11/pages/lecture"], "Opening one page must fetch only that page")
        let pageID = try unwrap(workspace.document?.id)
        workspace.flush()
        let reopened = StudyWorkspaceModel(store: workspace.store)
        precondition(reopened.course?.isFavorite == true && reopened.course?.materials.count == algebra.materials.count)
        CanvasFixtureProtocol.state.reset()
        reopened.openCanvasMaterial(page, courseID: algebra.id)
        precondition(CanvasFixtureProtocol.state.paths.isEmpty && reopened.document?.id == pageID, "Saved content must reopen without a Canvas connection")
        workspace.syncCanvasCourses(courseIDs: [algebra.id], downloadAll: true)
        for _ in 0..<500 where workspace.canvasBusy { try await Task.sleep(for: .milliseconds(20)) }
        precondition(workspace.course?.documents.count == 3)
        precondition(workspace.course?.documents.contains { $0.kind == .pdf } == true)
        precondition(workspace.course?.documents.first { $0.sourceKey == page.id }?.id == pageID)
        precondition(CanvasFixtureProtocol.state.paths.filter { $0 == "/api/v1/courses/11/pages/lecture" }.count == 1,
            "Catalog discovery checks page links once; unchanged saved pages must not be downloaded again")
        workspace.loadCanvasCourses(clientOverride: client)
        for _ in 0..<500 where workspace.canvasBusy { try await Task.sleep(for: .milliseconds(20)) }
        precondition(workspace.library.courses.filter { $0.canvasID == 11 }.count == 1)
        precondition(workspace.library.courses.first { $0.canvasID == 11 }?.isFavorite == true)
        for (name, code) in [("Algorithms & data structures", "TDT4120"), ("Probability and statistics", "TMA4240"), ("Computer systems", "TDT4186")] { workspace.createCourse(name: name, code: code) }
        // Optional catalog fields must decode from the existing version-1 library.
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.library)) as! [String: Any]
        legacy.removeValue(forKey: "showingCourseLibrary")
        legacy["courses"] = (legacy["courses"] as! [[String: Any]]).map { course in
            var value = course
            for key in ["favorite", "canvasFavorite", "canvasMaterials", "catalogUpdatedAt", "catalogWarnings", "term"] { value.removeValue(forKey: key) }
            return value
        }
        let migrated = try JSONDecoder().decode(StudyLibrary.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(migrated.courses.count == workspace.library.courses.count && migrated.courses.allSatisfy { !$0.isFavorite })
        precondition(migrated.courses.flatMap(\.documents).count == workspace.library.courses.flatMap(\.documents).count)
        workspace.showCourseLibrary()
        try await Task.sleep(for: .milliseconds(350))
        try snapshot(controller.window, at: output.appendingPathComponent("workspace-courses.png"))
        controller.window.setContentSize(NSSize(width: 1_040, height: 700))
        try await Task.sleep(for: .milliseconds(250))
        try snapshot(controller.window, at: output.appendingPathComponent("workspace-courses-compact.png"))
        controller.window.setContentSize(NSSize(width: 1_420, height: 900))
        precondition(scholiaApplicationActivationPolicy(explanationWindowParticipates: false, quickChatWindowVisible: false, hasOpenedApplicationWindow: true) == .regular)
        precondition(scholiaApplicationActivationPolicy(explanationWindowParticipates: false, quickChatWindowVisible: true) == .regular)
        let quick = QuickAskPanelController(model: AppModel.shared)
        quick.showPrompt()
        precondition(NSApp.activationPolicy() == .regular && quick.window?.title == "Scholia Quick Chat")
        quick.hide()
        precondition(NSApp.activationPolicy() == .regular, "Scholia should keep one Dock identity after Quick Chat closes")
        // Exercise the actual loopback server and browser against this isolated native library.
        let server = StudyWebServer(app: AppModel.shared, workspace: workspace, assets: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/web"), practiceProvider: (practiceConfiguration, practiceCompletion)) {
            let config = ProviderConfiguration(provider: ProviderCatalog.provider(id: "openai"), model: "gpt-4.1", endpoint: "http://127.0.0.1:1", apiKey: "fixture", language: .english, fastClaudeMode: false)
            workspace.submit(configuration: config) { messages, _, onToken in
                precondition(messages.last?.content.contains("Explain this diagram") == true)
                let prepared = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english)
                precondition(prepared.messages.last?.content.contains("Current page: 2 of 3") == true)
                precondition(messages.last?.imageData != nil, "Web figure must reach the same native vision pipeline")
                onToken("An eigenvector ")
                try await Task.sleep(for: .milliseconds(300))
                return CompletionResult(text: "An **eigenvector** stays on the same line when transformed. The diagram shows a preserved direction. [p. 2]", providerID: "fixture", providerName: "Fixture", model: "fixture")
            }
        }
        server.start(port: 0)
        for _ in 0..<100 where server.address == nil { try await Task.sleep(for: .milliseconds(20)) }
        let address = try unwrap(server.address)
        let browser = Process(); browser.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        browser.arguments = ["node", "scripts/smoke-study-web.mjs", address.absoluteString, output.path]
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            browser.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do { try browser.run() } catch { continuation.resume(throwing: error) }
        }
        server.stop()
        precondition(status == 0, "Chromium website smoke failed")
        workspace.selectCourse(algebra.id)
    }

    static func contextEdgeCases(store: StudyLibraryStore) throws {
        let pages = (1...40).map { StudyPage(number: $0, text: String(repeating: "Page \($0) contents. ", count: 100)) }
        let document = StudyDocument(title: "Long book", kind: .pdf, fileName: "original.pdf", pageCount: 40)
        let pack = StudyContextBuilder.build(document: document, index: StudyDocumentIndex(pages: pages), currentPage: 20,
                                            question: "Explain page 39", selection: "", course: StudyCourse(name: "Test"),
                                            store: store, includeCourse: false, budget: 4_000)
        precondition(!pack.wholeDocument && pack.sources.contains { $0.page == 20 } && pack.sources.contains { $0.page == 39 })
        precondition(pack.text.contains("omitted pages are not visible"))
        precondition(StudyContextBuilder.citedSources(in: "See [p. 20] and [p. 99]", allowed: pack.sources).map(\.page) == [20])
        let own = try StudyDocumentImporter.read(data: Data("Force and acceleration in this course".utf8), name: "Mechanics.md", store: store)
        _ = try StudyDocumentImporter.read(data: Data("Force and private unrelated course notes".utf8), name: "Other.md", store: store)
        let coursePack = StudyContextBuilder.build(document: nil, index: nil, currentPage: 1, question: "force", selection: "", course: StudyCourse(name: "Physics", documents: [own]), store: store, includeCourse: true)
        precondition(coursePack.text.contains("Force and acceleration") && !coursePack.text.contains("private unrelated"))
        let text = StudyHTML.plainText("<p>&#x03bb; &amp; &#955;</p><script>unsafe()</script>")
        precondition(text.contains("λ & λ") && !text.contains("unsafe"))
        let codex = ProviderConfiguration(provider: ProviderCatalog.provider(id: "codex"), model: "fixture", endpoint: "http://127.0.0.1:8789", apiKey: "", language: .english, fastClaudeMode: false)
        precondition(codex.studyImageInputAllowed, "Bridge-advertised image support must not be disabled")
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let result = view as? T { return result }
        for subview in view.subviews { if let result = find(type, in: subview) { return result } }
        return nil
    }
}

private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw CocoaError(.validationMissingMandatoryProperty) }; return value
}

final class CanvasFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    private var bytes: Data?
    private var version = 1
    private var conditional = 0
    var revision: Int { get { lock.withLock { version } } set { lock.withLock { version = newValue } } }
    var notModified: Int { lock.withLock { conditional } }
    func conditionalHit() { lock.withLock { conditional += 1 } }
    var paths: [String] { lock.withLock { requests } }
    var pdf: Data? { get { lock.withLock { bytes } } set { lock.withLock { bytes = newValue } } }
    func record(_ path: String) { lock.withLock { requests.append(path) } }
    func reset() { lock.withLock { requests = []; conditional = 0 } }
}

final class CanvasFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = CanvasFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.state.record(url.host == "storage.example.org" ? url.absoluteString : url.path)
        var binary: Data?
        var headers = ["Content-Type": "application/json"]
        var status = 200
        var body: String
        if url.host == "storage.example.org" {
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
            body = "clean download"
            binary = Self.state.pdf
            if binary != nil { headers["Content-Type"] = "application/pdf" }
        } else {
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            switch url.path {
            case "/api/v1/users/self/profile": body = "{\"id\":7,\"name\":\"Test Student\"}"
            case "/api/v1/courses":
                if url.query?.contains("page=2") != true {
                    precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "include[]" && $0.value == "favorites" } == true)
                }
                if url.query?.contains("page=2") == true { body = "[{\"id\":12,\"name\":\"Physics\",\"is_favorite\":\(Self.state.revision == 1)}]" }
                else { body = "[{\"id\":11,\"name\":\"Algebra\",\"course_code\":\"TMA4115\"}]"; headers["Link"] = "<https://canvas.ntnu.no/api/v1/courses?page=2>; rel=\"next\"" }
            case "/api/v1/courses/11", "/api/v1/courses/12": body = "{\"id\":11,\"syllabus_body\":\"<p>Course overview and learning goals.</p>\"}"
            case "/api/v1/courses/11/pages": body = "[{\"url\":\"lecture\",\"title\":\"Lecture\",\"updated_at\":\"v1\"}]"
            case "/api/v1/courses/11/pages/lecture": body = "{\"title\":\"Lecture\",\"body\":\"<p>Eigenvectors</p>\",\"updated_at\":\"v1\"}"
            case "/api/v1/courses/11/files": body = "{}"; status = 403
            case "/api/v1/courses/11/assignments": body = "[]"
            case "/api/v1/courses/11/folders", "/api/v1/courses/12/folders": body = "[]"
            case "/api/v1/courses/11/discussion_topics", "/api/v1/courses/12/discussion_topics":
                precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                    $0.name == "only_announcements" && $0.value == "true"
                } == true)
                body = "[]"
            case "/api/v1/courses/11/modules": body = "[{\"id\":5,\"items_count\":1}]"
            case "/api/v1/courses/11/modules/5/items": body = "[{\"type\":\"File\",\"content_id\":42}]"
            case "/api/v1/courses/11/files/42": body = "{\"id\":42,\"display_name\":\"Notes\",\"filename\":\"notes.pdf\",\"url\":\"https://storage.example.org/file.pdf\"}"
            case "/api/v1/courses/12/pages", "/api/v1/courses/12/files", "/api/v1/courses/12/assignments", "/api/v1/courses/12/modules": body = "[]"
            default: preconditionFailure("Unexpected Canvas fixture request: \(url.path)")
            }
        }
        if status == 200 && url.host == "canvas.ntnu.no" {
            body = body.replacingOccurrences(of: "v1", with: "v\(Self.state.revision)")
            let tag = "\"fixture-\(Self.state.revision)-\(url.query ?? "")\""
            headers["ETag"] = tag
            if request.value(forHTTPHeaderField: "If-None-Match") == tag { status = 304; body = ""; headers.removeValue(forKey: "Link"); Self.state.conditionalHit() }
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: binary ?? Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
