import AppKit
@testable import ScholiaMac

final class ChatReferenceChecks {
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
        expectEqual(links.count, 5)
        expectEqual(links.compactMap { link -> Int? in
            guard case .document(let id, let page) = context.destination(for: link.url), id == doc.id else { return nil }
            return page
        }, [66, 77, 79, 114, 163])
        expect(links[1].help.contains("opens page 77"))
        expect(ChatReferenceContext(documents: [doc]).links(in: "[p. 79]").isEmpty)
    }

    func testAttachmentPathIDAndArchiveMembersUseSavedEvidence() throws {
        let file = attachment()
        let context = ChatReferenceContext(attachments: [.init(file)])
        let text = "ttk4100.slx, \(file.sourcePath!), \(file.id.uuidString), simulink/systems/system_root.xml and simulink/systems/system_74.xml. Unseen: other/system.xml."
        let links = context.links(in: text)
        expectEqual(links.count, 5)
        expectEqual(context.links(in: "The file is ttk4100.slx.").count, 1)
        expectEqual(context.destination(for: links[3].url), .attachment(file.id, member: "simulink/systems/system_root.xml"))
        expectEqual(context.localURL(for: URL(fileURLWithPath: file.sourcePath!)), links[0].url)
        expectNil(context.localURL(for: URL(fileURLWithPath: "/etc/passwd")))
        expectNil(context.destination(for: ChatReferenceContext.url(.attachment(file.id, member: "invented.xml"))))
        expectNil(context.destination(for: ChatReferenceContext.url(.attachment(UUID(), member: nil))))
        expectNil(context.destination(for: ChatReferenceContext.url(.document(UUID(), page: 1))))
    }

    func testAmbiguousNamesDoNotChooseAnArbitraryAttachmentOrDocument() {
        let one = attachment()
        var two = one; two.id = UUID(); two.sourcePath = "/different/project/ttk4100.slx"
        let context = ChatReferenceContext(documents: [document(), document()], attachments: [.init(one), .init(two)])
        expect(context.links(in: "ttk4100.slx KybintroKompendium.pdf simulink/systems/system_root.xml").isEmpty)
        let pathLink = context.links(in: one.sourcePath!)
        expectEqual(pathLink.count, 1)
        expectEqual(context.destination(for: pathLink[0].url), .attachment(one.id, member: nil))
        expect(context.links(in: "other-ttk4100.slx /another/path/ttk4100.slx").isEmpty)
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
        expectEqual(plain.string, linked.string)
        var labels: [String] = [], urls: [URL] = []
        linked.enumerateAttribute(.link, in: NSRange(location: 0, length: linked.length)) { value, range, _ in
            guard let url = value as? URL else { return }
            if url.scheme == "scholia-source" { labels.append((linked.string as NSString).substring(with: range)); urls.append(url) }
        }
        expectEqual(labels, ["[pp. 77–81]", "ttk4100.slx", "model", "simulink/systems/system_74.xml"])
        let externalRange = (linked.string as NSString).range(of: "KybintroKompendium.pdf")
        expectEqual(linked.attribute(.link, at: externalRange.location, effectiveRange: nil) as? URL, URL(string: "https://example.com/book"))
        expectEqual(context.destination(for: urls[0]), .document(doc.id, page: 77))
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
        let manager = try unwrap(view.layoutManager), container = try unwrap(view.textContainer)
        let range = (view.string as NSString).range(of: "77")
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        let point = NSPoint(x: rect.midX + view.textContainerOrigin.x, y: rect.midY + view.textContainerOrigin.y)
        expectEqual(view.sourceLink(at: point), ChatReferenceContext.url(.document(doc.id, page: 77)))
        expectNil(view.sourceLink(at: NSPoint(x: 499, y: 399)))
        view.updateMarkdown(markdown, compact: true, colorScheme: .light, width: 500)
        expectNil(view.textStorage?.attribute(.link, at: range.location, effectiveRange: nil))
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
        expectEqual(context.defaultDocumentID, doc.id)
        expectEqual(context.attachments.map(\.id), [file.id])
        expectEqual(context.destination(for: try unwrap(context.links(in: answer.content).first).url), .document(doc.id, page: 79))
    }

    func testMemberInspectorShowsOnlyTheRequestedSavedMember() {
        let text = attachment().extractedText
        let excerpt = ChatAttachmentInspection.excerpt(text, member: "simulink/systems/system_root.xml")
        expect(excerpt.contains("saved model"))
        expectFalse(excerpt.contains("<system>drag</system>"))
        expect(ChatAttachmentInspection.excerpt(text, member: "unread.xml").contains("unavailable"))
    }
}

private struct CheckError: Error { var message: String }
private func expect(_ value: @autoclosure () -> Bool, _ message: String = "Assertion failed", file: StaticString = #filePath, line: UInt = #line) {
    precondition(value(), "\(file):\(line): \(message)")
}
private func expectFalse(_ value: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    expect(!value(), "Expected false", file: file, line: line)
}
private func expectEqual<T: Equatable>(_ value: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    expect(value == expected, "Expected \(expected), got \(value)", file: file, line: line)
}
private func expectNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    expect(value == nil, "Expected nil", file: file, line: line)
}
private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw CheckError(message: "Unexpected nil") }; return value
}

@main
struct ChatReferencesSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let checks = ChatReferenceChecks()
        checks.testPDFPagesAndRangesValidateBoundsAndIgnorePrintedNumbers()
        try checks.testAttachmentPathIDAndArchiveMembersUseSavedEvidence()
        checks.testAmbiguousNamesDoNotChooseAnArbitraryAttachmentOrDocument()
        try checks.testRendererLinksTableCitationsAndInlineFileCodeWithoutChangingTextOrExternalLinks()
        try checks.testSourceLinkHitTestingInTableAndContextChangesInvalidateCachedRender()
        try checks.testAnswerReferencesStayBoundToSavedSourcesAfterNavigating()
        checks.testMemberInspectorShowsOnlyTheRequestedSavedMember()
        print("PASS: 7 chat reference checks (PDF ranges, saved attachments, ambiguity, Markdown tables/code, hit testing, source identity, archive evidence)")
    }
}
