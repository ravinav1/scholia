import AppKit
import PDFKit
import XCTest
@testable import ScholiaMac

final class StudyWorkspaceTests: XCTestCase {
    func testCanvasAddressesAndPaginationKeepCredentialsOnOrigin() throws {
        let origin = try CanvasAddress.origin("canvas.ntnu.no/courses/4?token=secret")
        XCTAssertEqual(origin.absoluteString, "https://canvas.ntnu.no")
        XCTAssertThrowsError(try CanvasAddress.origin("http://canvas.ntnu.no"))
        XCTAssertThrowsError(try CanvasAddress.origin("https://user:secret@canvas.ntnu.no"))
        let current = origin.appendingPathComponent("api/v1/courses")
        XCTAssertNotNil(CanvasAddress.nextPage("<https://canvas.ntnu.no/api/v1/courses?page=2>; rel=\"next\"", current: current, origin: origin))
        XCTAssertNil(CanvasAddress.nextPage("<https://other.example/api/v1/courses?page=2>; rel=\"next\"", current: current, origin: origin))
        XCTAssertNil(CanvasAddress.nextPage("<https://canvas.ntnu.no/api/v1/users?page=2>; rel=\"next\"", current: current, origin: origin))
    }

    func testWholeDocumentAndExplicitPageContextSurviveProviderPreparation() throws {
        let store = StudyLibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let doc = StudyDocument(title: "Linear maps", kind: .pdf, fileName: "original.pdf", pageCount: 3)
        let index = StudyDocumentIndex(pages: [StudyPage(number: 1, text: "Definition of linear maps"), StudyPage(number: 2, text: "Eigenvectors"), StudyPage(number: 3, text: "A diagonalization example")])
        let pack = StudyContextBuilder.build(document: doc, index: index, currentPage: 2, question: "Explain page 3", selection: "Eigenvectors", course: StudyCourse(name: "Algebra"), store: store, includeCourse: false)
        XCTAssertTrue(pack.wholeDocument)
        XCTAssertEqual(pack.sources.map(\.page), [1, 2, 3])
        XCTAssertTrue(pack.imagePages.contains(3))
        XCTAssertTrue(pack.imagePages.contains(2))
        let messages = StudyContextBuilder.requestMessages([ConversationMessage(role: .user, content: "Explain page 3")], pack: pack, mode: .explain, images: [])
        let prepared = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english)
        XCTAssertTrue(prepared.messages[0].content.contains("A diagonalization example"))
        XCTAssertTrue(prepared.messages[0].content.contains("one manageable next step"))
        XCTAssertTrue(prepared.messages[0].content.contains("Current page: 2 of 3"))
    }

    func testLongDocumentKeepsExplicitAndCurrentPagesAndDisclosesOmissions() {
        let pages = (1...40).map { StudyPage(number: $0, text: String(repeating: "Page \($0) contents. ", count: 100)) }
        let document = StudyDocument(title: "Long book", kind: .pdf, fileName: "original.pdf", pageCount: 40)
        let pack = StudyContextBuilder.build(document: document, index: StudyDocumentIndex(pages: pages), currentPage: 20,
                                            question: "Explain page 39", selection: "", course: StudyCourse(name: "Test"),
                                            store: StudyLibraryStore(), includeCourse: false, budget: 4_000)
        XCTAssertFalse(pack.wholeDocument)
        XCTAssertTrue(pack.sources.contains { $0.page == 39 })
        XCTAssertTrue(pack.sources.contains { $0.page == 20 })
        XCTAssertTrue(pack.text.contains("omitted pages are not visible"))
        XCTAssertLessThan(pack.text.count, 5_000)
    }

    func testExplicitEntirePDFIncludesAllPagesBeyondTheNormalBudget() throws {
        let pages = (1...30).map { StudyPage(number: $0,
            text: String(repeating: "Document evidence 🧠 e\u{301}. ", count: 500) + "Conclusion \($0)") }
        let document = StudyDocument(title: "Long reading", kind: .pdf, fileName: "original.pdf", pageCount: 30)
        let pack = try StudyContextBuilder.entirePDF(document: document, index: StudyDocumentIndex(pages: pages))
        XCTAssertTrue(pack.wholeDocument)
        XCTAssertEqual(pack.sources.count, 30)
        XCTAssertGreaterThan(pack.text.utf16.count, 140_000)
        let messages = StudyContextBuilder.requestMessages([ConversationMessage(role: .user, content: "Explain the entire PDF.")],
            pack: pack, mode: .explain, images: [])
        let prepared = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .automatic)
        XCTAssertEqual(messages[0].attachments?.map(\.extractedText).joined(), pack.text)
        XCTAssertTrue(prepared.messages[0].content.contains("Conclusion 30"))
        XCTAssertTrue(prepared.messages[0].content.contains("Read every supplied PDF page"))
        XCTAssertThrowsError(try StudyContextBuilder.entirePDF(document: document,
            index: StudyDocumentIndex(pages: Array(pages.dropLast()))))
        let oversized = StudyDocumentIndex(pages: (1...30).map { StudyPage(number: $0, text: String(repeating: "x", count: 30_000)) })
        XCTAssertThrowsError(try StudyContextBuilder.entirePDF(document: document, index: oversized))
    }

    func testCourseRetrievalIsScopedToSelectedCourse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StudyLibraryStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try StudyDocumentImporter.read(data: Data("# Force\n\nForce and acceleration in this course".utf8), name: "Mechanics.md", store: store)
        _ = try StudyDocumentImporter.read(data: Data("Force and private unrelated course notes".utf8), name: "Other.md", store: store)
        let pack = StudyContextBuilder.build(document: nil, index: nil, currentPage: 1, question: "force", selection: "", course: StudyCourse(name: "Physics", documents: [one]), store: store, includeCourse: true)
        XCTAssertTrue(pack.text.contains("Force and acceleration"))
        XCTAssertFalse(pack.text.contains("private unrelated"))
        XCTAssertEqual(pack.sources.count, 1)
    }

    @MainActor
    func testFirstQuestionEditCancellationAndPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        model.createCourse(name: "Algebra", code: "TMA4115")
        model.draft = "Why is this linear?"
        model.mode = .explain
        let config = ProviderConfiguration(provider: ProviderCatalog.provider(id: "ollama"), model: "test", endpoint: "http://127.0.0.1:11434", apiKey: "", language: .english, fastClaudeMode: false)
        model.submit(configuration: config) { messages, _, onToken in
            XCTAssertTrue(messages.last?.content.hasPrefix("Why is this linear?") == true)
            XCTAssertTrue(messages.last?.content.contains("one manageable next step") == true)
            onToken("A linear map ")
            return CompletionResult(text: "A linear map preserves sums and scaling.", providerID: "test", providerName: "Test", model: "test")
        }
        for _ in 0..<100 where model.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isStreaming)
        XCTAssertEqual(model.messages.first?.content, "Why is this linear?")
        XCTAssertEqual(model.messages.last?.content, "A linear map preserves sums and scaling.")
        model.edit(try XCTUnwrap(model.messages.first))
        XCTAssertEqual(model.messages.count, 2, "Editing must not destroy the old conversation before send.")
        model.cancelEdit()
        XCTAssertEqual(model.messages.count, 2)
        model.flush()
        let reopened = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        XCTAssertEqual(reopened.course?.code, "TMA4115")
        XCTAssertEqual(reopened.messages.count, 2)
    }

    func testDocumentFocusEligibilityIsPure() {
        XCTAssertTrue(StudyWorkspaceModel.canFocusDocument(hasDocument: true, showingLibrary: false, examPlannerPresented: false))
        XCTAssertFalse(StudyWorkspaceModel.canFocusDocument(hasDocument: false, showingLibrary: false, examPlannerPresented: false))
        XCTAssertFalse(StudyWorkspaceModel.canFocusDocument(hasDocument: true, showingLibrary: true, examPlannerPresented: false))
        XCTAssertFalse(StudyWorkspaceModel.canFocusDocument(hasDocument: true, showingLibrary: false, examPlannerPresented: true))
    }

    @MainActor
    func testDocumentFocusTogglesAndClearsWhenLeavingTheDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        model.createCourse(name: "Random processes", code: "TTK4255")
        model.toggleDocumentFocus()
        XCTAssertFalse(model.documentFocused, "Nothing to focus without an open document")
        let slides = StudyDocument(title: "Week 41", kind: .pdf, fileName: "original.pdf", pageCount: 2, contentHash: "slides")
        try model.store.write(document: slides, index: StudyDocumentIndex(pages: [StudyPage(number: 1, text: "Canonical decompositions")]), data: Data("Fixture".utf8))
        model.library.courses[0].documents.append(slides)
        model.selectDocument(slides.id)
        model.toggleDocumentFocus()
        XCTAssertTrue(model.documentFocused)
        model.newThread()
        XCTAssertTrue(model.documentFocused, "Starting a chat beside the slides keeps focus")
        model.toggleDocumentFocus()
        XCTAssertFalse(model.documentFocused)
        model.toggleDocumentFocus()
        model.showCourseLibrary()
        XCTAssertFalse(model.documentFocused, "Leaving the document ends focus")
        model.selectDocument(slides.id)
        model.toggleDocumentFocus()
        model.examPlannerPresented = true
        XCTAssertFalse(model.documentFocused, "The exam planner covers the reader, so focus ends")
        let thread = try XCTUnwrap(model.library.courses[0].threads.first)
        model.removeThread(thread.id)
        XCTAssertFalse(model.library.courses[0].threads.contains { $0.id == thread.id })
    }

    @MainActor
    func testPassageExplanationsStayOutOfTheConversationUntilKept() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        model.createCourse(name: "Algebra", code: "TMA4115")
        let slides = StudyDocument(title: "Week 41", kind: .pdf, fileName: "original.pdf", pageCount: 1, contentHash: "slides")
        try model.store.write(document: slides, index: StudyDocumentIndex(pages: [StudyPage(number: 1, text: "Eigenvalues")]), data: Data("Fixture".utf8))
        model.library.courses[0].documents.append(slides)
        model.selectDocument(slides.id)
        model.automaticContextEnabled = false
        let config = ProviderConfiguration(provider: ProviderCatalog.provider(id: "ollama"), model: "test", endpoint: "http://127.0.0.1:11434", apiKey: "", language: .english, fastClaudeMode: false)
        let sent = model.sendReaderSelection("Av = λv", inChat: false) {
            model.submit(configuration: config) { _, _, onToken in
                onToken("An eigenvector ")
                return CompletionResult(text: "An eigenvector keeps its direction.", providerID: "test", providerName: "Test", model: "test")
            }
        }
        XCTAssertTrue(sent)
        for _ in 0..<100 where model.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.messages.isEmpty, "The visible conversation must not receive the popover's explanation")
        let scratch = try XCTUnwrap(model.library.courses[0].threads.first { $0.isSelectionScratch == true })
        XCTAssertEqual(scratch.messages.count, 2)
        XCTAssertEqual(model.selectionResponseTarget?.threadID, scratch.id)
        XCTAssertEqual(model.selectionResponseTarget?.inChat, false)
        model.keepSelectionExplanationInChat()
        XCTAssertEqual(model.messages.count, 2, "Keep in chat moves the explanation into the document conversation")
        XCTAssertTrue(model.library.courses[0].threads.first { $0.isSelectionScratch == true }?.messages.isEmpty == true)
        XCTAssertEqual(model.library.courses[0].threads.filter { $0.isSelectionScratch != true }.count, 1)
    }

    func testStudyWindowKeepsAppInDockIndependentlyOfQuickChat() {
        XCTAssertEqual(scholiaApplicationActivationPolicy(explanationWindowParticipates: false, quickChatWindowVisible: false, studyWindowVisible: true), .regular)
    }

    func testHTMLImportDoesNotExposeScriptsAsStudyMaterial() {
        let text = StudyHTML.plainText("<h1>Lecture</h1><script>steal()</script><style>hidden</style><p>A &amp; B</p>")
        XCTAssertTrue(text.contains("Lecture"))
        XCTAssertTrue(text.contains("A & B"))
        XCTAssertFalse(text.contains("steal"))
        XCTAssertFalse(text.contains("hidden"))
    }
}
