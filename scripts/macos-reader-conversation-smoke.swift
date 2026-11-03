import CoreGraphics
import Foundation
@testable import ScholiaMac

@main
struct ReaderConversationSmoke {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-reader-conversation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdfURL = root.appendingPathComponent("fixture.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = CGContext(pdfURL as CFURL, mediaBox: &box, nil)!
        for _ in 1...6 { pdf.beginPDFPage(nil); pdf.endPDFPage() }
        pdf.closePDF()
        let store = StudyLibraryStore(root: root.appendingPathComponent("library"))
        let model = StudyWorkspaceModel(store: store)
        model.createCourse(name: "Reader scope fixture", code: "PDF101")
        let document = StudyDocument(title: "Open compendium", kind: .pdf, fileName: "compendium.pdf", pageCount: 6)
        let pages = (1...6).map { StudyPage(number: $0, text: $0 == 6
            ? "Farcontroller uses gain42 for feedback."
            : "READER_PAGE_\($0): current reader evidence.") }
        try store.write(document: document, index: StudyDocumentIndex(pages: pages), data: Data(contentsOf: pdfURL))
        model.library.courses[0].documents = [document]
        let courseFile = MessageAttachment(fileName: "project.m", mimeType: "text/plain", byteCount: 8,
            extractedText: "TRANSFERRED_FILE_GAIN = 42;", readStatus: .complete)
        let oldDocumentFile = MessageAttachment(fileName: "old.m", mimeType: "text/plain", byteCount: 8,
            extractedText: "OLD_DOCUMENT_DRAFT_FILE", readStatus: .complete)
        let courseThread = StudyThread(title: "Course chat", messages: [ConversationMessage(role: .user, content: "COURSE_HISTORY")],
            draft: "Explain farcontroller settings", draftAttachments: [courseFile])
        let oldDocumentThread = StudyThread(title: "Existing reading draft", documentID: document.id,
            draft: "OLD_DOCUMENT_DRAFT", draftAttachments: [oldDocumentFile])
        model.library.courses[0].threads = [courseThread, oldDocumentThread]
        model.selectThread(courseThread.id)
        precondition(model.isCourseConversation && !model.includeCourseContext, "Legacy nil settings must default to no other-course context")
        model.navigate(to: StudySource(documentID: document.id, title: document.title, page: 4))
        for _ in 0..<100 where model.documentIndex == nil { try await Task.sleep(for: .milliseconds(10)) }
        precondition(model.isCourseConversation && model.currentPage == 4, "Citation browsing must preserve intentional course conversation")
        model.askAboutOpenDocument()
        precondition(!model.isCourseConversation && model.thread?.documentID == document.id && model.currentPage == 4)
        precondition(model.thread?.id != oldDocumentThread.id, "An existing reading draft must not be overwritten")
        precondition(model.draft == courseThread.draft && model.draftAttachments == [courseFile], "Explicit scope switch must carry the visible question/files")
        precondition(model.course?.threads.first { $0.id == courseThread.id }?.draftAttachments == [courseFile])
        precondition(model.course?.threads.first { $0.id == courseThread.id }?.messages == courseThread.messages)
        precondition(model.course?.threads.first { $0.id == oldDocumentThread.id }?.draft == "OLD_DOCUMENT_DRAFT")
        precondition(model.course?.threads.first { $0.id == oldDocumentThread.id }?.draftAttachments == [oldDocumentFile])
        print("PASS explicit PDF scope switch carries visible question/files while preserving both existing drafts and course history")

        let configuration = ProviderConfiguration(provider: ProviderCatalog.provider(id: "ollama"), model: "fixture",
            endpoint: "http://127.0.0.1:1", apiKey: "", language: .english, fastClaudeMode: false, modelSupportsImages: false)
        var observed = false
        model.submit(configuration: configuration) { messages, _, _ in
            observed = true
            let text = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english).messages.last!.content
            precondition(text.contains("READER_PAGE_4") && text.contains("Farcontroller uses gain42"), "Question must use open PDF's current and remote relevant pages")
            precondition(text.contains("TRANSFERRED_FILE_GAIN"))
            precondition(!text.contains("OLD_DOCUMENT_DRAFT_FILE") && !text.contains("COURSE_HISTORY"))
            return CompletionResult(text: "Gain42 controls feedback.", providerID: "fixture", providerName: "Fixture", model: "fixture")
        }
        for _ in 0..<100 where model.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        precondition(observed && !model.isStreaming && model.error == nil)
        print("PASS switched question provider payload is bound to the open PDF and transferred explicit files")

        model.selectThread(courseThread.id)
        model.navigate(to: StudySource(documentID: document.id, title: document.title, page: 2))
        model.openSelectionInChat("SELECTED_PDF_PASSAGE", question: "Explain this symbol")
        for _ in 0..<100 where model.documentIndex == nil { try await Task.sleep(for: .milliseconds(10)) }
        precondition(model.documentIndex?.pages.count == 6, "Wait for the PDF index, as the Send button does")
        precondition(!model.isCourseConversation && model.currentPage == 2 && model.selectedText == "SELECTED_PDF_PASSAGE")
        precondition(model.draftAttachments.isEmpty, "Selection Open in chat must not transfer unrelated course draft attachments")
        precondition(model.course?.threads.first { $0.id == courseThread.id }?.draftAttachments == [courseFile])

        let pending = MessageAttachment(fileName: "pending.txt", mimeType: "text/plain", byteCount: 10,
            extractedText: "UNSENT_COMPOSER_FILE", readStatus: .complete)
        model.draft = "PRESERVE_READER_DRAFT"
        model.draftImage = Data([1, 2, 3])
        model.draftAttachments = [pending]
        model.saveDraft()
        let draftThreadID = model.thread!.id
        var selectionObserved = false
        let sent = model.sendReaderSelection("SELECTED_PDF_PASSAGE", question: "Explain this symbol") {
            model.submit(configuration: configuration) { messages, _, _ in
                selectionObserved = true
                let text = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english).messages.last!.content
                precondition(text.contains("SELECTED_PDF_PASSAGE") && text.contains("READER_PAGE_2"))
                precondition(!text.contains("UNSENT_COMPOSER_FILE") && !text.contains("PRESERVE_READER_DRAFT"))
                precondition(messages.last?.imageData == nil
                    && messages.last?.attachments?.contains { $0.id == pending.id || $0.isImage } != true)
                return CompletionResult(text: "Selection explanation.", providerID: "fixture", providerName: "Fixture", model: "fixture")
            }
        }
        precondition(sent && model.draft == "PRESERVE_READER_DRAFT" && model.draftImage == Data([1, 2, 3]) && model.draftAttachments == [pending])
        for _ in 0..<100 where model.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        precondition(selectionObserved && model.error == nil && !model.isStreaming)
        model.flush()
        let saved = try store.load().courses[0].threads.first { $0.id == draftThreadID }!
        precondition(saved.draft == "PRESERVE_READER_DRAFT" && saved.draftImage == Data([1, 2, 3]) && saved.draftAttachments == [pending])
        print("PASS PDF selection Explain/Open in chat binds reader scope and preserves unsent text, image, and file drafts")

        model.selectCourse(model.course!.id)
        model.selectDocument(document.id)
        model.setPage(5)
        precondition(!model.isCourseConversation && model.currentPage == 5, "Normal search/document navigation must select document conversation")
        precondition(!model.includeCourseContext)
        model.includeCourseContext = true
        model.saveDraft()
        model.selectThread(courseThread.id)
        model.selectThread(draftThreadID)
        precondition(model.includeCourseContext, "Explicit course-context opt-in must survive navigation")
        print("PASS document navigation defaults to PDF context and preserves explicit course-context opt-in")
    }
}
