@preconcurrency import AppKit
import SwiftUI
import XCTest
@testable import ScholiaMac

final class AttachmentDropTests: XCTestCase {
    @MainActor
    func testFinderAndLegacySpotlightPasteboardsResolveAllFilesWithoutDuplicates() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let one = URL(fileURLWithPath: "/tmp/Project folder/model.slx")
        let two = URL(fileURLWithPath: "/tmp/Project folder/parameters.mat")
        XCTAssertTrue(board.writeObjects([one as NSURL, two as NSURL]))
        XCTAssertEqual(AttachmentDropReader.fileURLs(from: board), [one, two])
        XCTAssertTrue(AttachmentDropReader.canRead(board))
        board.clearContents()
        board.setPropertyList([one.path, two.path, one.path], forType: AttachmentDropReader.legacyFiles)
        XCTAssertEqual(AttachmentDropReader.fileURLs(from: board), [one, two])
    }

    @MainActor
    func testSearchUtilitiesFileURLStringsRemainDistinctFromTextAndWebLinks() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("file:///tmp/Project%20folder/model.slx\nfile:///tmp/notes.txt", forType: .string)
        XCTAssertEqual(AttachmentDropReader.fileURLs(from: board).map(\.path), ["/tmp/Project folder/model.slx", "/tmp/notes.txt"])
        board.clearContents()
        board.setString("Explain file:///tmp/model.slx and https://example.com", forType: .string)
        XCTAssertFalse(AttachmentDropReader.canRead(board))
        board.clearContents()
        board.setString("https://example.com/model.slx", forType: .URL)
        XCTAssertFalse(AttachmentDropReader.canRead(board))
    }

    @MainActor
    func testLauncherPlainPathsAttachOnlyDuringDropAndOnlyWhenTheyExist() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Drop path \(UUID().uuidString).slx")
        try Data("test fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString(file.path, forType: .string)
        XCTAssertTrue(AttachmentDropReader.fileURLs(from: board).isEmpty)
        XCTAssertFalse(AttachmentDropReader.canRead(board))
        XCTAssertEqual(AttachmentDropReader.fileURLs(from: board, allowPathStrings: true), [file])
        XCTAssertTrue(AttachmentDropReader.canRead(board, allowPathStrings: true))
        board.clearContents()
        board.setString(file.path + ".missing", forType: .string)
        XCTAssertFalse(AttachmentDropReader.canRead(board, allowPathStrings: true))
        board.clearContents()
        board.setString("Explain the file at " + file.path, forType: .string)
        XCTAssertFalse(AttachmentDropReader.canRead(board, allowPathStrings: true))
        board.clearContents()
        board.setString("~/", forType: .string)
        XCTAssertEqual(AttachmentDropReader.fileURLs(from: board, allowPathStrings: true).first?.path, NSHomeDirectory())
    }

    @MainActor
    func testNativeTextEditorRoutesDraggingToAttachmentsWithoutInsertingAPath() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([URL(fileURLWithPath: "/tmp/model.slx") as NSURL])
        let drag = AttachmentTestDraggingInfo(board)
        let editor = BoundedComposerTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        editor.string = "Explain this controller"
        var attached: [URL] = []
        editor.onDropAttachment = { attached = AttachmentDropReader.fileURLs(from: $0); return true }
        XCTAssertEqual(editor.draggingEntered(drag), .copy)
        XCTAssertTrue(editor.prepareForDragOperation(drag))
        XCTAssertTrue(editor.performDragOperation(drag))
        XCTAssertEqual(attached.map(\.lastPathComponent), ["model.slx"])
        XCTAssertEqual(editor.string, "Explain this controller")
        editor.isEditable = false
        XCTAssertEqual(editor.draggingEntered(drag), [])
        XCTAssertFalse(editor.prepareForDragOperation(drag))
    }

    @MainActor
    func testSidebarDropAncestorReceivesFilesOutsideEditor() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setPropertyList(["/tmp/project"], forType: AttachmentDropReader.legacyFiles)
        let view = AttachmentDropHostingView(rootView: Text("Transcript"))
        var received = false
        view.onDropAttachment = { received = !$0.types!.isEmpty; return received }
        let drag = AttachmentTestDraggingInfo(board)
        XCTAssertEqual(view.draggingEntered(drag), .copy)
        XCTAssertTrue(view.performDragOperation(drag))
        XCTAssertTrue(received)
    }

    @MainActor
    func testSidebarFilesReadQueueAndPersistWithDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let text = root.appendingPathComponent("controller.m")
        let binary = root.appendingPathComponent("opaque.custom")
        try Data("Kp = 42;\nKi = 7;".utf8).write(to: text)
        try Data([0, 0xff, 0x00, 0xa1]).write(to: binary)
        let model = StudyWorkspaceModel(store: StudyLibraryStore(root: root.appendingPathComponent("library")))
        model.createCourse(name: "Control systems", code: "KYB")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([text as NSURL, binary as NSURL])
        XCTAssertTrue(model.attachFromPasteboard(board))
        XCTAssertTrue(model.isIngestingAttachment)
        XCTAssertFalse(model.canSend)
        for _ in 0..<200 where model.isIngestingAttachment { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.isIngestingAttachment)
        XCTAssertEqual(model.draftAttachments.count, 2)
        XCTAssertTrue(model.draftAttachments[0].extractedText.contains("Kp = 42"))
        XCTAssertEqual(model.draftAttachments[1].readStatus, .unreadable)
        XCTAssertEqual(model.thread?.draftAttachments?.count, 2)
        XCTAssertTrue(model.canSend)
        let id = try XCTUnwrap(model.thread?.id)
        model.newThread()
        XCTAssertTrue(model.draftAttachments.isEmpty)
        model.selectThread(id)
        XCTAssertEqual(model.draftAttachments.count, 2)
    }

    @MainActor
    func testPasteOfDragOnlyPromiseDoesNotInvokeAppKitDropOnlyAPI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let delegate = AttachmentPromiseTestDelegate()
        let provider = NSFilePromiseProvider(fileType: "public.plain-text", delegate: delegate)
        XCTAssertTrue(board.writeObjects([provider]))
        XCTAssertTrue(AttachmentDropReader.canRead(board))
        var receiverCalled = false
        XCTAssertFalse(AttachmentDropReader.receivePromises(from: board, receiving: { _ in receiverCalled = true },
            receive: { _, _ in receiverCalled = true }))
        XCTAssertFalse(receiverCalled)
        let model = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        model.createCourse(name: "Test", code: "")
        XCTAssertTrue(model.attachFromPasteboard(board))
        XCTAssertFalse(model.isIngestingAttachment)
        XCTAssertTrue(model.draftAttachments.isEmpty)
        XCTAssertTrue(model.error?.contains("Drag it into the chat") == true)
        withExtendedLifetime(delegate) {}
    }

    @MainActor
    func testCancelledQueueCannotAttachToNextConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("notes.txt")
        try Data("Old conversation".utf8).write(to: file)
        let model = StudyWorkspaceModel(store: StudyLibraryStore(root: root.appendingPathComponent("library")))
        model.createCourse(name: "Test", code: "")
        model.attachFiles(at: [file])
        model.newThread()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.draftAttachments.isEmpty)
        XCTAssertFalse(model.isIngestingAttachment)
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

private final class AttachmentPromiseTestDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        "parameters.m"
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping ((any Error)?) -> Void) {
        do { try Data("Kp = 42".utf8).write(to: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }
}
