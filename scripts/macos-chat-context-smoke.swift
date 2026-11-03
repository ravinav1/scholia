@preconcurrency import AppKit
import SwiftUI
@testable import ScholiaMac

@main
@MainActor
struct ChatContextSmoke {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); print("PASS: native drop, sidebar layout, file persistence, context switches, provider payload, and edit isolation"); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        NSApplication.shared.run()
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-context-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("controller.m")
        let opaque = root.appendingPathComponent("measurements.custom")
        try Data("Kp = 42;\nKi = 7;".utf8).write(to: script)
        try Data([0, 0xff, 0x01, 0x00]).write(to: opaque)
        let store = StudyLibraryStore(root: root.appendingPathComponent("library"))
        let model = StudyWorkspaceModel(store: store)
        model.createCourse(name: "Kybintro · Course project", code: "TTK4100")
        let source = try StudyDocumentImporter.read(data: Data("COURSE_SECRET_493".utf8), name: "Kybintro compendium.txt", store: store)
        model.library.courses[0].documents = [source]
        model.library.courses[0].aiMemory = StudyAIMemory(notes: "MEMORY_SECRET_827", documentIDs: [source.id])
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setPropertyList([script.path, opaque.path, script.path], forType: AttachmentDropReader.legacyFiles)
        precondition(AttachmentDropReader.fileURLs(from: board).count == 2, "Spotlight/Finder duplicates must resolve once")
        let editor = BoundedComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 70))
        editor.string = "Explain the controller"
        editor.onDropAttachment = { model.attachFromPasteboard($0) }
        let drag = AttachmentTestDraggingInfo(board)
        precondition(editor.draggingEntered(drag) == .copy)
        precondition(editor.prepareForDragOperation(drag) && editor.performDragOperation(drag))
        precondition(editor.string == "Explain the controller", "Dropping must attach, not insert a path")
        precondition(model.isIngestingAttachment && !model.canSend)
        for _ in 0..<250 where model.isIngestingAttachment { try await Task.sleep(for: .milliseconds(20)) }
        precondition(model.draftAttachments.count == 2 && !model.isIngestingAttachment)
        precondition(model.draftAttachments[0].extractedText.contains("Kp = 42"))
        precondition(model.draftAttachments[1].effectiveReadStatus == .unreadable)
        let owner = model.draftOwner
        model.setAttachmentIncluded(model.draftAttachments[0].id, included: false)
        precondition(model.draftOwner != owner)
        model.setAttachmentIncluded(model.draftAttachments[0].id, included: true)

        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 400, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = NSHostingController(rootView: StudyTutorPane(workspace: model)
            .environmentObject(AppModel.shared).frame(maxWidth: .infinity, maxHeight: .infinity))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(350))
        for size in [NSSize(width: 400, height: 760), NSSize(width: 310, height: 650)] {
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
            let editors = descendants(window.contentView!).compactMap { $0 as? BoundedComposerTextView }
            precondition(editors.count == 1 && editors[0].bounds.width > 100 && editors[0].bounds.height > 20, "Composer must remain visible at narrow sidebar widths")
            let dropViews = descendants(window.contentView!).filter { $0.registeredDraggedTypes.contains(.fileURL) }
            precondition(dropViews.count >= 2, "Both composer and sidebar must receive file drops")
            try snapshot(window, name: "native-chat-files-\(Int(size.width)).png")
        }

        model.automaticContextEnabled = false
        model.selectedText = "Explicit selected passage"
        model.draft = "What is missing to understand this project?"
        let files = model.draftAttachments
        let configuration = ProviderConfiguration(provider: ProviderCatalog.provider(id: "ollama"), model: "fixture",
            endpoint: "http://127.0.0.1:1", apiKey: "", language: .english, fastClaudeMode: false)
        var observed = false
        model.submit(configuration: configuration) { messages, _, _ in
            observed = true
            let request = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english)
            let text = request.messages.map(\.content).joined(separator: "\n")
            precondition(text.contains("Kp = 42") && text.contains("Explicit selected passage"))
            precondition(text.contains("contents could not be read") && text.contains("measurements.custom"))
            precondition(!text.contains("COURSE_SECRET_493") && !text.contains("MEMORY_SECRET_827"))
            precondition(request.systemPrompt.contains("ask the user a focused question"))
            return CompletionResult(text: "Please attach the Simulink model and export the measurement data so I can verify the complete project.", providerID: "fixture", providerName: "Fixture", model: "fixture")
        }
        for _ in 0..<250 where model.isStreaming { try await Task.sleep(for: .milliseconds(20)) }
        precondition(observed && !model.isStreaming && model.error == nil)
        precondition(model.messages.first?.attachments == files && model.draftAttachments.isEmpty)
        precondition(model.thread?.sources.values.allSatisfy(\.isEmpty) == true)
        model.setAttachmentIncluded(files[0].id, included: false)
        let followup = try PromptBuilder.prepare(messages: model.messages, capture: nil, languagePreference: .english)
        precondition(!followup.messages.map(\.content).joined().contains("Kp = 42"), "Excluded earlier attachment must not leak into later requests")
        model.flush()
        let restored = StudyWorkspaceModel(store: store)
        precondition(!restored.automaticContextEnabled && restored.messages.first?.attachments?.count == 2)
        restored.edit(restored.messages.first!)
        precondition(restored.draftAttachments.count == 2)
        restored.attachFiles(at: [script])
        restored.cancelEdit()
        try await Task.sleep(for: .milliseconds(150))
        precondition(restored.draftAttachments.isEmpty && !restored.isIngestingAttachment)
        model.draft = "Explain how the controller connects to the model."
        try await Task.sleep(for: .milliseconds(150))
        try snapshot(window, name: "native-chat-context-off.png")
        try await readingContext(root: root, window: window)
    }

    static func readingContext(root: URL, window: NSWindow) async throws {
        let store = StudyLibraryStore(root: root.appendingPathComponent("adaptive-reading"))
        let reader = StudyWorkspaceModel(store: store)
        reader.createCourse(name: "Kybintro", code: "TTK4100")
        let document = StudyDocument(title: "Kybintro compendium", kind: .text, fileName: "compendium.txt", pageCount: 30)
        let pages = (1...30).map { number in
            StudyPage(number: number, text: number == 27
                ? "ProportionalController uses gain Kp to convert the tracking error into a control signal."
                : "Background page \(number): position and velocity describe the motion of a rocket.")
        }
        try store.write(document: document, index: StudyDocumentIndex(pages: pages), data: Data("Compendium fixture".utf8))
        let unrelated = StudyDocument(title: "Other lecture", kind: .text, fileName: "other.txt", pageCount: 1)
        try store.write(document: unrelated, index: StudyDocumentIndex(pages: [StudyPage(number: 1,
            text: "UNRELATED_COURSE_SECRET: What does the background material use for common introductory exercises?")]),
            data: Data("Other fixture".utf8))
        reader.library.courses[0].documents = [document, unrelated]
        reader.library.courses[0].aiMemory = StudyAIMemory(notes: "COURSE_MEMORY_SECRET", documentIDs: [unrelated.id])
        reader.selectDocument(document.id)
        for _ in 0..<100 where reader.documentIndex == nil { try await Task.sleep(for: .milliseconds(20)) }
        precondition(reader.documentIndex?.pages.count == 30)
        precondition(!reader.includeCourseContext, "New reading chats must default to the open document")
        reader.draft = "What does ProportionalController use Kp for?"
        window.setContentSize(NSSize(width: 380, height: 780))
        window.contentViewController = NSHostingController(rootView: StudyTutorPane(workspace: reader)
            .environmentObject(AppModel.shared).frame(maxWidth: .infinity, maxHeight: .infinity))
        window.setContentSize(NSSize(width: 380, height: 780))
        window.contentView?.setFrameSize(NSSize(width: 380, height: 780))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        try snapshot(window, name: "native-adaptive-reading-ready.png")
        let configuration = ProviderConfiguration(provider: ProviderCatalog.provider(id: "ollama"), model: "fixture",
            endpoint: "http://127.0.0.1:1", apiKey: "", language: .english, fastClaudeMode: false)
        var observed = false
        reader.submit(configuration: configuration) { messages, _, _ in
            observed = true
            let prompt = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english)
            let text = prompt.messages.map(\.content).joined()
            precondition(text.contains("ProportionalController uses gain Kp"), "Question from page1 must find evidence on page27")
            precondition(text.contains("Background page 1:"), "Current reading page remains an anchor")
            precondition(!text.contains("Background page 15:"), "Unrelated pages should not crowd the request")
            precondition(!text.contains("UNRELATED_COURSE_SECRET"), "Question stopwords must not add unrelated course text")
            precondition(!text.contains("COURSE_MEMORY_SECRET"), "Document-only context must not add course memory or pinned files")
            return CompletionResult(text: "The controller uses Kp to scale the tracking error [p. 27].", providerID: "fixture", providerName: "Fixture", model: "fixture")
        }
        for _ in 0..<200 where reader.isStreaming { try await Task.sleep(for: .milliseconds(20)) }
        precondition(observed && reader.error == nil && !reader.isStreaming)
        precondition(reader.currentPage == 1, "Retrieving another page must not move the reader")
        let sources = reader.thread?.sources[reader.messages.last!.id.uuidString] ?? []
        precondition(sources.contains { $0.page == 27 } && sources.contains { $0.page == 1 })
        precondition(sources.count < 10)
        try await Task.sleep(for: .milliseconds(150))
        try snapshot(window, name: "native-adaptive-reading-answer.png")
        print("PASS adaptive reading: page1 question retrieves page27 without unrelated pages or moving the reader")

        reader.draft = "Why?"
        var followupObserved = false
        reader.submit(configuration: configuration) { messages, _, _ in
            followupObserved = true
            let text = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english).messages.last!.content
            precondition(text.contains("ProportionalController uses gain Kp"), "Vague follow-up must retain remote evidence")
            precondition(!text.contains("Background page 15:"))
            return CompletionResult(text: "Kp scales how strongly the control signal responds to the tracking error.", providerID: "fixture", providerName: "Fixture", model: "fixture")
        }
        for _ in 0..<200 where reader.isStreaming { try await Task.sleep(for: .milliseconds(20)) }
        precondition(followupObserved && reader.error == nil && !reader.isStreaming)
        reader.setPage(12)
        reader.draft = "Explain this page"
        var localObserved = false
        reader.submit(configuration: configuration) { messages, _, _ in
            localObserved = true
            let text = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english).messages.last!.content
            precondition(text.contains("Background page 12:"))
            precondition(!text.contains("ProportionalController uses gain Kp"), "Explicit local reading must stop resending earlier distant evidence")
            precondition(!text.contains("UNRELATED_COURSE_SECRET"))
            return CompletionResult(text: "This page describes position and velocity.", providerID: "fixture", providerName: "Fixture", model: "fixture")
        }
        for _ in 0..<200 where reader.isStreaming { try await Task.sleep(for: .milliseconds(20)) }
        precondition(localObserved && reader.error == nil && !reader.isStreaming)
        print("PASS adaptive provider requests: distant follow-up continuity and local-page reset")
        reader.includeEntirePDF = true
        reader.selectedText = "SELECTED_RELATION: position and velocity"
        reader.draft = "Explain the highlighted relation using the whole document"
        var wholeObserved = false
        reader.submit(configuration: configuration) { messages, _, _ in
            wholeObserved = true
            let text = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english).messages.last!.content
            precondition(text.contains("SELECTED_RELATION"), "Whole-document mode must preserve the selected passage")
            precondition(text.contains("Background page 15:") && text.contains("Background page 30:") && text.contains("ProportionalController uses gain Kp"))
            precondition(!text.contains("UNRELATED_COURSE_SECRET"))
            return CompletionResult(text: "Position and velocity describe the state used by the controller.", providerID: "fixture", providerName: "Fixture", model: "fixture")
        }
        for _ in 0..<200 where reader.isStreaming { try await Task.sleep(for: .milliseconds(20)) }
        precondition(wholeObserved && reader.error == nil && !reader.isStreaming)
        precondition(reader.thread?.sources[reader.messages.last!.id.uuidString]?.count == 30)
        print("PASS whole-document provider request includes all text and the selected passage")
        reader.includeEntirePDF = false
        reader.includeCourseContext = true
        reader.draft = "What does ProportionalController use Kp for?"
        var courseAdditionObserved = false
        reader.submit(configuration: configuration) { messages, _, _ in
            courseAdditionObserved = true
            let text = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english).messages.last!.content
            precondition(text.contains("ProportionalController uses gain Kp"))
            precondition(text.contains("COURSE_MEMORY_SECRET") && text.contains("UNRELATED_COURSE_SECRET"), "Explicit course addition must restore saved memory and pinned files")
            return CompletionResult(text: "The supplied course memory is available alongside the open document.", providerID: "fixture", providerName: "Fixture", model: "fixture")
        }
        for _ in 0..<200 where reader.isStreaming { try await Task.sleep(for: .milliseconds(20)) }
        precondition(courseAdditionObserved && reader.error == nil && !reader.isStreaming)
        reader.flush()
        precondition(StudyWorkspaceModel(store: store).includeCourseContext, "Explicit course-context choice must persist")
        print("PASS document-only default and explicit course-memory addition")
    }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func snapshot(_ window: NSWindow, name: String) throws {
        let directory = URL(fileURLWithPath: "/private/tmp/scholia-chat-verification", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let view = window.contentView!
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw NSError(domain: "ChatContextSmoke", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot capture \(name): view bounds are \(view.bounds)"])
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}

@MainActor
private final class AttachmentTestDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
