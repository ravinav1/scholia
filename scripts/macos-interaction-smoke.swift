@preconcurrency import AppKit
import SwiftUI
@testable import ScholiaMac

extension StudyWorkspaceSmoke {
    static func checkInteractionData() throws {
        let checks = MaterialCacheChecks()
        try checks.testQueriesAndLayoutsNeverReuseAnotherSearchResult()
        try checks.testCatalogEditsDownloadsAndAssignmentProgressInvalidateCachedRows()
        try checks.testChatUpdatesAndCourseSwitchesKeepCatalogsIsolated()
        checks.testRepeatedCatalogRenderingBenchmark()
        checkStreamingCadence()
        print("PASS: material cache freshness, query/layout isolation, lossless streaming cadence")
    }

    static func checkInteractionUI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-interaction-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let messages = (0..<80).flatMap { index in
            [ConversationMessage(role: .user, content: "Question \(index): Explain this topic."),
             ConversationMessage(role: .assistant, content: "Answer \(index)\n\n" + String(repeating:
                "A **linear map** preserves addition and scaling. Examine the basis vectors, then test a small example.\n\n", count: 5))]
        }
        let thread = StudyThread(messages: messages, draft: "Keep this draft")
        let course = StudyCourse(name: "Long conversation fixture", threads: [thread])
        try store.save(StudyLibrary(courses: [course], selectedCourseID: course.id,
            selectedThreadID: thread.id, showingCourseLibrary: false))
        let workspace = StudyWorkspaceModel(store: store)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = PanelContentController(rootView: StudyTutorPane(workspace: workspace)
            .environmentObject(AppModel.shared), size: NSSize(width: 640, height: 800))
        window.contentViewController = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(600))
        let mounted = descendants(SelfSizingTextView.self, in: host.view)
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try snapshot(window, at: output.appendingPathComponent("interaction-long-chat.png"))
        precondition(mounted.count < 40, "Long conversations must not mount every Markdown document (\(mounted.count))")
        precondition(mounted.contains { $0.renderedSource.hasPrefix("Answer 79") }, "Opening history must reach the latest answer")
        let latest = mounted.first { $0.renderedSource.hasPrefix("Answer 79") }!
        let scroll = latest.enclosingScrollView!
        let bottomGap = scroll.documentView!.bounds.maxY - scroll.documentVisibleRect.maxY
        precondition(abs(bottomGap) < 5, "The final answer must be visible at the bottom (gap \(bottomGap))")
        precondition(workspace.draft == "Keep this draft")
        print("Long conversation: \(mounted.count) mounted Markdown views for 80 answers")

        // Exercise the actual split controllers and the nonanimated path used
        // for first layout and Reduce Motion, without changing system settings.
        // Their reader must survive hiding/showing the sidebar and tutor.
        let state = InteractionPaneState()
        let panes = PanelContentController(rootView: InteractionPanes(state: state), size: NSSize(width: 1_200, height: 780))
        window.contentViewController = panes
        window.setContentSize(NSSize(width: 1_200, height: 780))
        try await Task.sleep(for: .milliseconds(250))
        let originalReaders = descendants(SelfSizingTextView.self, in: panes.view)
        precondition(originalReaders.count == 1)
        let reader = originalReaders[0]
        for _ in 0..<3 {
            state.sidebarVisible = false
            state.tutorVisible = false
            try await Task.sleep(for: .milliseconds(250))
            let splits = splitControllers(panes)
            precondition(splits.count == 2)
            precondition(splits[0].splitViewItems[0].isCollapsed)
            precondition(splits[1].splitViewItems[1].isCollapsed)
            state.sidebarVisible = true
            state.tutorVisible = true
            try await Task.sleep(for: .milliseconds(250))
            precondition(!splits[0].splitViewItems[0].isCollapsed)
            precondition(!splits[1].splitViewItems[1].isCollapsed)
            precondition(descendants(SelfSizingTextView.self, in: panes.view).first === reader,
                "Panel transitions must preserve the reader's native view")
        }
        for (split, itemIndex) in zip(splitControllers(panes), [0, 1]) {
            setStudyPaneCollapsed(true, item: split.splitViewItems[itemIndex], animated: false)
            precondition(split.splitViewItems[itemIndex].isCollapsed)
            setStudyPaneCollapsed(false, item: split.splitViewItems[itemIndex], animated: false)
            precondition(!split.splitViewItems[itemIndex].isCollapsed)
        }
        // Change direction before an animation has finished.
        for _ in 0..<6 {
            state.sidebarVisible.toggle()
            state.tutorVisible.toggle()
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(300))
        let splits = splitControllers(panes)
        precondition(!splits[0].splitViewItems[0].isCollapsed && !splits[1].splitViewItems[1].isCollapsed)
        precondition(descendants(SelfSizingTextView.self, in: panes.view).first === reader)
        precondition(reader.bounds.width > 0)
        try snapshot(window, at: output.appendingPathComponent("interaction-panels.png"))
        workspace.flush()
        print("PASS: lazy transcript, latest-answer navigation, panel transitions, rapid reversals, nonanimated fallback and reader preservation")
    }

    private static func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }

    private static func splitControllers(_ controller: NSViewController) -> [NSSplitViewController] {
        descendants(NSSplitView.self, in: controller.view).compactMap { $0.delegate as? NSSplitViewController }
    }
}

@MainActor
private final class InteractionPaneState: ObservableObject {
    @Published var sidebarVisible = true
    @Published var tutorVisible = true
}

private struct InteractionPanes: View {
    @ObservedObject var state: InteractionPaneState
    var body: some View {
        StudySidebarSplitView(sidebar: Text("Library"), content:
            StudyWorkspaceSplitView(reader: RichMarkdownView(source: "# Keep reading\n\nReader identity survives panel transitions."),
                tutor: Text("Tutor"), tutorVisible: state.tutorVisible, readerReset: 0, minimumReaderWidth: 300),
            sidebarVisible: state.sidebarVisible)
    }
}

@MainActor
private struct MaterialCacheChecks {
    private func course() -> StudyCourse {
        StudyCourse(name: "Algebra", canvasMaterials: [
            CanvasMaterialReference(id: "files:1", kind: .files, remoteID: "1", title: "Lecture 2",
                fileName: "vectors.pdf", sourceURL: "https://canvas.example/files/1", version: "v1",
                moduleID: 1, moduleTitle: "Vectors", modulePosition: 1, moduleItemPosition: 1),
            CanvasMaterialReference(id: "files:2", kind: .files, remoteID: "2", title: "Lecture 10",
                fileName: "matrices.pdf", sourceURL: "https://canvas.example/files/2", version: "v1"),
            CanvasMaterialReference(id: "assignments:1", kind: .assignments, remoteID: "1", title: "Exercise 1",
                sourceURL: "https://canvas.example/assignments/1", version: "v1",
                assignment: CanvasAssignmentDetails(record: [:]))
        ])
    }

    private func snapshot<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func assertCurrent(_ cache: StudyMaterialListCache, _ course: StudyCourse,
                               query: String = "", file: StaticString = #filePath, line: UInt = #line) throws {
        assertEqual(try snapshot(cache.groups(for: course, query: query)),
            try snapshot(StudyMaterialOrganizer.groups(for: course, query: query)), file: file, line: line)
        assertEqual(try snapshot(cache.files(for: course, query: query)),
            try snapshot(StudyMaterialOrganizer.files(for: course, query: query)), file: file, line: line)
    }

    func testQueriesAndLayoutsNeverReuseAnotherSearchResult() throws {
        let cache = StudyMaterialListCache(), course = course()
        for query in ["", "vectors", "Lecture 10", "no match", "", "matrices.pdf", "vectors", "  VECTORS  "] {
            try assertCurrent(cache, course, query: query)
        }
        assertEqual(cache.files(for: course, query: "vectors").map(\.title), ["vectors.pdf"])
        assertFalse(cache.files(for: course).contains { $0.materialID == "assignments:1" })
    }

    func testCatalogEditsDownloadsAndAssignmentProgressInvalidateCachedRows() throws {
        let cache = StudyMaterialListCache()
        var course = course()
        try assertCurrent(cache, course)
        course.canvasMaterials?[0].moduleTitle = "Updated module"
        course.canvasMaterials?[0].fileName = "updated.pdf"
        try assertCurrent(cache, course)
        course.canvasMaterials?[0].moduleSection = "Hidden module heading"
        course.canvasMaterials?[0].folderTitle = "Øving assets"
        course.canvasMaterials?[0].linkedFromTitle = "Linked page"
        course.canvasMaterials?[0].linkedSection = "Linked subsection"
        for query in ["hidden module", "ØVING", "linked page", "linked subsection", "updated.pdf"] {
            try assertCurrent(cache, course, query: query)
        }
        assertEqual(cache.references(for: course)["files:1"]?.fileName, "updated.pdf")

        course.documents.append(StudyDocument(title: "My saved lecture", kind: .pdf, fileName: "original.pdf",
            pageCount: 12, sourceKey: "files:1", sourceVersion: "v1"))
        try assertCurrent(cache, course)
        assertEqual(cache.files(for: course).filter { $0.materialID == "files:1" }.count, 1)
        course.canvasMaterials?[0].version = "v2"
        try assertCurrent(cache, course)
        assertTrue(cache.files(for: course).first { $0.materialID == "files:1" }!.updateAvailable)

        course.catalogChanges = CanvasCatalogChanges(added: ["files:2"])
        try assertCurrent(cache, course)
        assertEqual(cache.files(for: course).first { $0.materialID == "files:2" }?.badge, "New")
        course.assignmentProgress = ["assignments:1": .handedIn]
        try assertCurrent(cache, course)
        assertEqual(cache.groups(for: course).flatMap(\.items).first { $0.materialID == "assignments:1" }?.submissionStatus, .submitted)

        course.documents.removeAll()
        course.canvasMaterials?.removeFirst()
        try assertCurrent(cache, course)
        assertNil(cache.references(for: course)["files:1"])
    }

    func testChatUpdatesAndCourseSwitchesKeepCatalogsIsolated() throws {
        let cache = StudyMaterialListCache()
        var course = course()
        let before = try snapshot(cache.groups(for: course))
        course.threads = [StudyThread(messages: [ConversationMessage(role: .assistant, content: "A streamed answer")])]
        course.threads[0].draft = "My next question"
        course.name = "Renamed course"
        assertEqual(try snapshot(cache.groups(for: course)), before)
        try assertCurrent(cache, course)
        let other = StudyCourse(name: "Empty course")
        assertTrue(cache.groups(for: other).isEmpty)
        assertTrue(cache.files(for: other).isEmpty)
        assertTrue(cache.references(for: other).isEmpty)
        try assertCurrent(cache, course)
    }

    func testRepeatedCatalogRenderingBenchmark() {
        let cache = StudyMaterialListCache()
        let course = StudyCourse(name: "Large fixture", canvasMaterials: (1...250).map { index in
            CanvasMaterialReference(id: "files:\(index)", kind: .files, remoteID: "\(index)",
                title: "Lecture \(index) linear algebra", fileName: "lecture-\(index).pdf",
                sourceURL: "https://canvas.example/files/\(index)", version: "v1")
        })
        _ = cache.groups(for: course)
        let clock = ContinuousClock()
        let uncached = clock.measure { for _ in 0..<20 { _ = StudyMaterialOrganizer.groups(for: course) } }
        let cached = clock.measure { for _ in 0..<20 { _ = cache.groups(for: course) } }
        let result = "Material list benchmark (250 files, 20 updates): regrouping \(uncached), cached \(cached)\n"
        FileHandle.standardOutput.write(Data(result.utf8))
        let queries = ["l", "le", "lec", "lect", "lecture", "lecture 2", "linear", "algebra", "no match", ""]
        let searchingUncached = clock.measure {
            for query in queries { _ = StudyMaterialOrganizer.groups(for: course, query: query) }
        }
        let searchingCached = clock.measure {
            for query in queries {
                _ = cache.groups(for: course, query: query)
                // An unfiltered sidebar/web request must not evict search preparation.
                _ = cache.groups(for: course)
            }
        }
        FileHandle.standardOutput.write(Data("Material search benchmark (250 files, 10 queries): rebuilding \(searchingUncached), filtering \(searchingCached)\n".utf8))
        assertEqual(cache.groups(for: course).flatMap(\.items).count, 250)
    }
}

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: (file), line: line)
}
private func assertTrue(_ value: Bool) { precondition(value) }
private func assertFalse(_ value: Bool) { precondition(!value) }
private func assertNil<T>(_ value: T?) { precondition(value == nil) }

private func checkStreamingCadence() {
    var buffer = StreamingUpdateBuffer()
    let start = ContinuousClock.now
    var delivered: [String] = []
    assertNil(buffer.append("", now: start))
    for offset in 0..<150 {
        if let update = buffer.append("x", now: start.advanced(by: .milliseconds(offset))) { delivered.append(update) }
    }
    if let update = buffer.flush() { delivered.append(update) }
    assertEqual(delivered.joined(), String(repeating: "x", count: 150))
    assertEqual(delivered.map { $0.utf16.count }, [1, 50, 50, 49])
    assertNil(buffer.flush())
    buffer = StreamingUpdateBuffer()
    assertEqual(buffer.append("Hello", now: start), "Hello")
    assertNil(buffer.append(" 👋", now: start))
    let burst = String(repeating: "a", count: 2_048)
    assertEqual(buffer.append(burst, now: start), " 👋" + burst)
    assertNil(buffer.append("tail", now: start))
    assertEqual(buffer.flush(), "tail")
    buffer = StreamingUpdateBuffer()
    assertEqual(buffer.append("A", now: start), "A")
    assertEqual(buffer.append("B", now: start.advanced(by: .milliseconds(100))), "B")
}
