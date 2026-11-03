import AppKit
import XCTest
@testable import ScholiaMac

final class ChatReferencesTests: XCTestCase {
    private func document(_ title: String = "KybintroKompendium.pdf") -> StudyDocument {
        StudyDocument(title: title, kind: .pdf, fileName: "original.pdf", pageCount: 176, originalFileName: title)
    }
    private func attachment() -> MessageAttachment {
        MessageAttachment(fileName: "ttk4100.slx", mimeType: "application/zip", byteCount: 12,
            extractedText: "Contents of ttk4100.slx\n\nFILE MANIFEST\nsimulink/systems/system_root.xml — complete\nsimulink/systems/system_74.xml — complete\n\nEXTRACTED CONTENT\n--- File: simulink/systems/system_root.xml [complete] ---\n<root>saved model</root>\n\n--- File: simulink/systems/system_74.xml [complete] ---\n<system>drag</system>",
            sourcePath: "/Users/heap/project/ttk4100.slx")
    }

    func testPDFPagesAndRangesValidateBoundsAndIgnorePrintedNumbers() {
        let doc = document()
        let context = ChatReferenceContext(documents: [doc], defaultDocumentID: doc.id)
        let text = "PDF [p. 66] is printed page 58. See [pp. 77–81], [p. 79], PDF p. 114 and PDF pp. 163–166. [p. 0] [p. 177] [pp. 175–179] [pp. 81–77]"
        let links = context.links(in: text)
        XCTAssertEqual(links.count, 5)
        XCTAssertEqual(links.compactMap { link -> Int? in
            guard case .document(let id, let page) = context.destination(for: link.url), id == doc.id else { return nil }
            return page
        }, [66, 77, 79, 114, 163])
        XCTAssertTrue(links[1].help.contains("opens page 77"))
        XCTAssertTrue(ChatReferenceContext(documents: [doc]).links(in: "[p. 79]").isEmpty)
    }

    func testAttachmentPathIDAndArchiveMembersUseSavedEvidence() throws {
        let file = attachment()
        let context = ChatReferenceContext(attachments: [.init(file)])
        let text = "ttk4100.slx, \(file.sourcePath!), \(file.id.uuidString), simulink/systems/system_root.xml and simulink/systems/system_74.xml. Unseen: other/system.xml."
        let links = context.links(in: text)
        XCTAssertEqual(links.count, 5)
        XCTAssertEqual(context.links(in: "The file is ttk4100.slx.").count, 1)
        XCTAssertEqual(context.destination(for: links[3].url), .attachment(file.id, member: "simulink/systems/system_root.xml"))
        XCTAssertEqual(context.localURL(for: URL(fileURLWithPath: file.sourcePath!)), links[0].url)
        XCTAssertNil(context.localURL(for: URL(fileURLWithPath: "/etc/passwd")))
        XCTAssertNil(context.destination(for: ChatReferenceContext.url(.attachment(file.id, member: "invented.xml"))))
        XCTAssertNil(context.destination(for: ChatReferenceContext.url(.attachment(UUID(), member: nil))))
        XCTAssertNil(context.destination(for: ChatReferenceContext.url(.document(UUID(), page: 1))))
    }

    func testAmbiguousNamesDoNotChooseAnArbitraryAttachmentOrDocument() {
        let one = attachment()
        var two = one; two.id = UUID(); two.sourcePath = "/different/project/ttk4100.slx"
        let context = ChatReferenceContext(documents: [document(), document()], attachments: [.init(one), .init(two)])
        XCTAssertTrue(context.links(in: "ttk4100.slx KybintroKompendium.pdf simulink/systems/system_root.xml").isEmpty)
        let pathLink = context.links(in: one.sourcePath!)
        XCTAssertEqual(pathLink.count, 1)
        XCTAssertEqual(context.destination(for: pathLink[0].url), .attachment(one.id, member: nil))
        XCTAssertTrue(context.links(in: "other-ttk4100.slx /another/path/ttk4100.slx").isEmpty)
    }

    @MainActor
    func testRendererLinksTableCitationsAndInlineFileCodeWithoutChangingTextOrExternalLinks() throws {
        let doc = document(), file = attachment()
        let context = ChatReferenceContext(documents: [doc], attachments: [.init(file)], defaultDocumentID: doc.id)
        let markdown = """
        | Reading | Evidence |
        |---|---|
        | **PD control [pp. 77–81]** | `ttk4100.slx` |

        [KybintroKompendium.pdf](https://example.com/book) and [model](file:///Users/heap/project/ttk4100.slx).

        `[p. 66]` and `simulink/systems/system_74.xml`.

        ```text
        ttk4100.slx [p. 66]
        ```
        """
        let plain = RichMarkdownDocumentRenderer(compact: true, colorScheme: .dark, availableWidth: 500).render(markdown)
        let linked = RichMarkdownDocumentRenderer(compact: true, colorScheme: .dark, availableWidth: 500, references: context).render(markdown)
        XCTAssertEqual(plain.string, linked.string)
        var labels: [String] = [], urls: [URL] = []
        linked.enumerateAttribute(.link, in: NSRange(location: 0, length: linked.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            if url.scheme == "scholia-source" { labels.append((linked.string as NSString).substring(with: range)); urls.append(url) }
        }
        XCTAssertEqual(labels, ["[pp. 77–81]", "ttk4100.slx", "model", "simulink/systems/system_74.xml"])
        let externalRange = (linked.string as NSString).range(of: "KybintroKompendium.pdf")
        XCTAssertEqual(linked.attribute(.link, at: externalRange.location, effectiveRange: nil) as? URL, URL(string: "https://example.com/book"))
        XCTAssertEqual(context.destination(for: urls[0]), .document(doc.id, page: 77))
    }

    @MainActor
    func testSourceLinkHitTestingInTableAndContextChangesInvalidateCachedRender() throws {
        let doc = document()
        let context = ChatReferenceContext(documents: [doc], defaultDocumentID: doc.id)
        let view = SelfSizingTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        let markdown = "| Reading | Page |\n|---|---|\n| PD control | [pp. 77–81] |"
        view.updateMarkdown(markdown, compact: true, colorScheme: .light, width: 500)
        view.updateMarkdown(markdown, compact: true, colorScheme: .light, width: 500, references: context)
        _ = view.requiredHeight(for: 500)
        let manager = try XCTUnwrap(view.layoutManager), container = try XCTUnwrap(view.textContainer)
        let range = (view.string as NSString).range(of: "77")
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        let point = NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        XCTAssertEqual(view.sourceLink(at: point), ChatReferenceContext.url(.document(doc.id, page: 77)))
        XCTAssertNil(view.sourceLink(at: NSPoint(x: 499, y: 399)))
        view.updateMarkdown(markdown, compact: true, colorScheme: .light, width: 500)
        XCTAssertNil(view.textStorage?.attribute(.link, at: range.location, effectiveRange: nil))
    }

    @MainActor
    func testAnswerReferencesStayBoundToSavedSourcesAfterNavigating() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        model.createCourse(name: "Control", code: "TTK4100")
        let doc = document(), other = document("Other.pdf"), file = attachment()
        let answer = ConversationMessage(role: .assistant, content: "[p. 79]")
        let later = MessageAttachment(fileName: "later.slx", mimeType: "application/zip", byteCount: 0, extractedText: "")
        let thread = StudyThread(documentID: doc.id,
            messages: [ConversationMessage(role: .user, content: "Explain", attachments: [file]), answer,
                ConversationMessage(role: .user, content: "Next", attachments: [later])],
            sources: [answer.id.uuidString: [StudySource(documentID: doc.id, title: doc.title, page: 66)]])
        model.library.courses[0].documents = [doc, other]
        model.library.courses[0].threads = [thread]
        model.library.selectedThreadID = thread.id
        model.library.selectedDocumentID = other.id
        let context = model.chatReferenceContext(for: answer)
        XCTAssertEqual(context.defaultDocumentID, doc.id)
        XCTAssertEqual(context.attachments.map(\.id), [file.id])
        XCTAssertEqual(context.destination(for: try XCTUnwrap(context.links(in: answer.content).first).url), .document(doc.id, page: 79))
    }

    func testMemberInspectorShowsOnlyTheRequestedSavedMember() {
        let text = attachment().extractedText
        let excerpt = ChatAttachmentInspection.excerpt(text, member: "simulink/systems/system_root.xml")
        XCTAssertTrue(excerpt.contains("saved model"))
        XCTAssertFalse(excerpt.contains("<system>drag</system>"))
        XCTAssertTrue(ChatAttachmentInspection.excerpt(text, member: "unread.xml").contains("unavailable"))
    }
}
