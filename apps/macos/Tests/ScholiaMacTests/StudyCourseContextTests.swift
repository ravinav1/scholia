import XCTest
@testable import ScholiaMac

final class StudyCourseContextTests: XCTestCase {
    func testCourseAndReadingContextRetainPaperURLsWithoutClaimingRemoteContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let title = "Before and beyond trust: reliance in medical AI"
        let paperURL = "https://doi.org/10.1136/medethics-2020-107095"
        var syllabus = try StudyDocumentImporter.read(data: Data(title.utf8), name: "Syllabus.txt", store: store)
        syllabus.sourceKey = "pages:syllabus"
        syllabus.sourceURL = "https://canvas.example/courses/1/pages/syllabus"
        var paper = try StudyDocumentImporter.read(data: Data("Paper excerpt about reliance in medical AI.".utf8), name: "Paper.txt", store: store)
        paper.sourceKey = "files:paper"
        var reference = CanvasMaterialReference(id: "files:paper", kind: .files, remoteID: "paper", title: title, sourceURL: paperURL, version: "1")
        reference.linkedFromID = syllabus.sourceKey
        let remote = CanvasMaterialReference(id: "files:remote", kind: .files, remoteID: "remote", title: "Saving or Creating", sourceURL: "https://doi.org/10.1080/15265161.2017.1340988", version: "1")
        let course = StudyCourse(name: "Bioethics", documents: [syllabus, paper], canvasMaterials: [reference, remote])
        let pack = StudyContextBuilder.build(document: nil, index: nil, currentPage: 1,
            question: "Suggest an essay reading about medical AI", selection: "", course: course, store: store, includeCourse: true)
        XCTAssertTrue(pack.text.contains("[\(title)](\(paperURL))"))
        XCTAssertTrue(pack.text.contains("Source URL (this document): \(paperURL)"))
        XCTAssertTrue(pack.text.contains("not downloaded; contents unavailable; source URL: \(remote.sourceURL)"))
        XCTAssertEqual(Set(pack.sources.map(\.documentID)), Set([syllabus.id, paper.id]))
        let reading = StudyContextBuilder.build(document: paper, index: try store.index(for: paper), currentPage: 1,
            question: "Explain this paper", selection: "", course: course, store: store, includeCourse: false)
        XCTAssertTrue(reading.text.contains("Source URL (this document): \(paperURL)"))
        XCTAssertFalse(reading.text.contains(remote.sourceURL))
        for url in ["javascript:alert(1)", "https://user:password@example.com/paper", "https://example.com/" + String(repeating: "x", count: 2100)] {
            XCTAssertNil(StudyContextBuilder.courseSourceURL(url))
        }
    }

    func testCourseQuestionsUseMetadataAndSavedTextWithoutOpeningADocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let saved = try StudyDocumentImporter.read(
            data: Data("# Mechanics\nMomentum is conserved in an isolated system.".utf8), name: "Mechanics.md", store: store)
        let details = CanvasAssignmentDetails(record: [
            "due_at": "2026-10-12T10:00:00Z", "submission_types": ["online_upload"],
            "submission": ["workflow_state": "unsubmitted"]])
        let remote = CanvasMaterialReference(
            id: "files:7", kind: .files, remoteID: "7", title: "Thermodynamics lecture", sourceURL: "https://canvas.example/courses/1/files/7", version: "1",
            moduleID: 2, moduleTitle: "Heat and energy")
        let assignment = CanvasMaterialReference(
            id: "assignments:8", kind: .assignments, remoteID: "8", title: "Energy problem set", sourceURL: "https://canvas.example/courses/1/assignments/8", version: "1", assignment: details)
        let course = StudyCourse(name: "Physics", code: "FY1003", documents: [saved], canvasMaterials: [remote, assignment], catalogUpdatedAt: Date(), term: "Autumn 2026")
        let pack = StudyContextBuilder.build(
            document: nil, index: nil, currentPage: 1, question: "Give me an overview and upcoming deadlines", selection: "", course: course, store: store, includeCourse: false)
        XCTAssertTrue(pack.text.contains("Code: FY1003"))
        XCTAssertTrue(pack.text.contains("Term: Autumn 2026"))
        XCTAssertTrue(pack.text.contains("Heat and energy"))
        XCTAssertTrue(pack.text.contains("2026-10-12T10:00:00Z"))
        XCTAssertTrue(pack.text.contains("Not handed in"))
        XCTAssertTrue(pack.text.contains("not downloaded; contents unavailable"))
        XCTAssertTrue(pack.text.contains("Momentum is conserved"))
        XCTAssertEqual(pack.sources.map(\.documentID), [saved.id])
        XCTAssertTrue(pack.imagePages.isEmpty)
        let dates = StudyContextBuilder.build(document: nil, index: nil, currentPage: 1,
            question: "When is the Energy problem set due?", selection: "", course: course, store: store, includeCourse: true)
        XCTAssertTrue(dates.text.contains("2026-10-12T10:00:00Z"))
        XCTAssertFalse(dates.text.contains("Momentum is conserved"))
        XCTAssertTrue(dates.sources.isEmpty)

        let long = StudyDocument(title: "Long reading", kind: .text, fileName: "long.txt", pageCount: 30)
        let index = StudyDocumentIndex(pages: (1...30).map { number in
            StudyPage(number: number, text: (number == 25 ? "zebraquantum is the relevant result. " : "") + String(repeating: "Background text. ", count: 350))
        })
        let question = "Explain zebraquantum and the formula on page 20"
        let focused = StudyContextBuilder.build(document: long, index: index, currentPage: 1,
            question: question, selection: "", course: course, store: store, includeCourse: false,
            budget: StudyContextBuilder.requestBudget(question))
        XCTAssertTrue(focused.sources.contains { $0.page == 25 })
        XCTAssertTrue(focused.sources.contains { $0.page == 20 })
        XCTAssertTrue(focused.sources.contains { $0.page == 1 })
        XCTAssertFalse(focused.wholeDocument)
        XCTAssertLessThan(focused.text.utf16.count, 50_000)
    }

    func testBroadCourseRetrievalSpansDocumentsAndDisclosesLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let long = StudyDocument(title: "Mechanics", kind: .text, fileName: "mechanics.txt", pageCount: 24)
        try store.write(document: long, index: StudyDocumentIndex(pages: (1...24).map {
            StudyPage(number: $0, text: String(repeating: "Mechanics and momentum. ", count: 600))
        }), data: Data("Mechanics".utf8))
        let short = try StudyDocumentImporter.read(
            data: Data("Thermodynamics studies heat and entropy.".utf8), name: "Heat.md", store: store)
        let pack = StudyContextBuilder.build(
            document: nil, index: nil, currentPage: 1, question: "Overview", selection: "",
            course: StudyCourse(name: "Physics", documents: [long, short]), store: store, includeCourse: true)
        XCTAssertEqual(Set(pack.sources.map(\.documentID)), Set([long.id, short.id]))
        XCTAssertTrue(pack.text.contains("heat and entropy"))
        XCTAssertTrue(pack.text.contains("omitted or shortened text is not visible"))
        XCTAssertLessThan(pack.text.utf16.count, 32_000)
    }

    func testLargeCourseCatalogIsBoundedAndDoesNotImplyUnreadContents() {
        let materials = (1...300).map { number in
            CanvasMaterialReference(id: "files:\(number)", kind: .files, remoteID: "\(number)",
                title: "Lecture \(number) " + String(repeating: "Long title ", count: 20),
                sourceURL: "https://canvas.example/courses/1/files/\(number)", version: "1")
        }
        let pack = StudyContextBuilder.build(
            document: nil, index: nil, currentPage: 1, question: "Course materials", selection: "",
            course: StudyCourse(name: "Physics", canvasMaterials: materials), store: StudyLibraryStore(), includeCourse: false)
        XCTAssertTrue(pack.text.contains("additional inventory items omitted"))
        XCTAssertTrue(pack.text.contains("No assignment records are indexed; this does not establish"))
        XCTAssertTrue(pack.sources.isEmpty)
        XCTAssertLessThan(pack.text.utf16.count, 15_000)
    }

    @MainActor
    func testCourseDraftSurvivesReadingNavigationAndSourceLinksKeepCourseScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let document = try StudyDocumentImporter.read(
            data: Data("Momentum is conserved.".utf8), name: "Mechanics.md", store: store)
        let model = StudyWorkspaceModel(store: store)
        model.createCourse(name: "Physics", code: "FY1003")
        model.library.courses[0].documents = [document]
        model.draft = "Give an overview of how this course's topics connect."
        model.saveDraft()
        let courseThread = try XCTUnwrap(model.thread?.id)
        model.selectDocument(document.id)
        model.draft = "Explain this reading"
        model.saveDraft()
        let readingThread = try XCTUnwrap(model.thread?.id)
        model.library.courses[0].threads.append(StudyThread(assignmentID: "assignments:8", draft: "Assignment-only draft"))
        model.askAboutCourse()
        XCTAssertEqual(model.thread?.id, courseThread)
        XCTAssertEqual(model.draft, "Give an overview of how this course's topics connect.")
        XCTAssertEqual(model.course?.threads.first(where: { $0.id == readingThread })?.draft, "Explain this reading")
        XCTAssertNil(model.document)
        model.navigate(to: StudySource(documentID: document.id, title: document.title, page: 1))
        XCTAssertEqual(model.conversationScope, "course")
        model.includeCourseContext = false
        XCTAssertTrue(model.canSend)
        let config = ProviderConfiguration(provider: ProviderCatalog.provider(id: "ollama"), model: "test", endpoint: "http://127.0.0.1:11434", apiKey: "", language: .english, fastClaudeMode: false)
        model.submit(configuration: config) { messages, _, onToken in
            let context = messages.last?.attachments?.first?.extractedText ?? ""
            XCTAssertTrue(context.contains("Code: FY1003"))
            XCTAssertTrue(context.contains("Momentum is conserved"))
            XCTAssertFalse(context.contains("Current page:"))
            XCTAssertTrue(model.answerStartedAt != nil)
            XCTAssertTrue(model.messages.last?.metadata?.contains("Waiting for") == true)
            onToken("These topics")
            XCTAssertEqual(model.messages.last?.metadata, "Writing answer…")
            return CompletionResult(text: "These topics connect through conservation laws.", providerID: "test", providerName: "Test", model: "test")
        }
        for _ in 0..<100 where model.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isStreaming)
        XCTAssertNil(model.answerStartedAt)
        XCTAssertEqual(model.thread?.id, courseThread)
        model.flush()
        let reopened = StudyWorkspaceModel(store: store)
        XCTAssertEqual(reopened.conversationScope, "course")
        XCTAssertEqual(reopened.messages.last?.content, "These topics connect through conservation laws.")
    }
}
