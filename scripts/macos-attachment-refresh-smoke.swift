@preconcurrency import AppKit
import Foundation
@testable import ScholiaMac

@main
@MainActor
struct AttachmentRefreshSmoke {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); print("PASS: attachment refresh, exact drop identity, provenance, corpus transport and preserved drafts"); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        NSApplication.shared.run()
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-refresh-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ttk4100.txt")
        try Data("Original controller".utf8).write(to: file)
        let store = StudyLibraryStore(root: root.appendingPathComponent("library"))
        let model = StudyWorkspaceModel(store: store)
        model.createCourse(name: "Attachment identity", code: "TTK4100")
        model.draft = "Explain my actual model."
        model.attachFiles(at: [file])
        try await wait(model)
        let original = model.draftAttachments[0]
        model.setAttachmentIncluded(original.id, included: false)
        let full = String(repeating: "Background evidence.\n", count: 20_000) + "TAIL_CONTROLLER_GAIN = 84;"
        try Data(full.utf8).write(to: file)
        model.refreshDraftAttachment(original.id)
        precondition(model.isIngestingAttachment && !model.canSend)
        try await wait(model)
        let updated = model.draftAttachments[0]
        precondition(updated.id == original.id && !updated.includedInContext)
        precondition(updated.sourcePath == file.path && updated.textCorpusID != nil)
        let savedText = try AttachmentTextCorpusStore.text(for: updated)
        precondition(savedText == full)
        precondition(model.draft == "Explain my actual model." && model.draftAttachments.count == 1)
        precondition(updated.readingDetailsText.contains(file.path))
        precondition(updated.readingDetailsText.contains(updated.id.uuidString))
        precondition(updated.readStatusLabel == "All text indexed")

        let wire = StudyWebAttachment(updated)
        let decoded = try JSONDecoder().decode(StudyWebAttachment.self, from: JSONEncoder().encode(wire))
        let transported = try decoded.attachment(existing: updated)
        precondition(transported == updated)
        var oldBrowser = decoded
        oldBrowser.textCorpusID = nil
        oldBrowser.textCorpusUTF16Count = nil
        oldBrowser.text = "A browser preview cannot replace saved evidence"
        oldBrowser.sourcePath = "/another/model.slx"
        let preserved = try oldBrowser.attachment(existing: updated)
        precondition(preserved == updated, "Roundtrip without corpus metadata must retain immutable saved source")
        do { _ = try decoded.attachment(); preconditionFailure("Unscoped corpus reference accepted") }
        catch { /* A browser cannot open an arbitrary native saved corpus. */ }
        var forged = decoded
        forged.id = UUID().uuidString
        do { _ = try forged.attachment(existing: updated); preconditionFailure("Mismatched source ID accepted") }
        catch {}
        model.flush()
        let restored = StudyWorkspaceModel(store: store)
        precondition(restored.draftAttachments.first == updated)
        let restoredText = try AttachmentTextCorpusStore.text(for: restored.draftAttachments[0])
        precondition(restoredText == full)

        model.refreshDraftAttachment(original.id)
        model.cancelAttachmentIngestion()
        try await Task.sleep(for: .milliseconds(100))
        precondition(!model.isIngestingAttachment && model.draftAttachments[0] == updated)
        precondition(model.draft == "Explain my actual model.")

        try FileManager.default.removeItem(at: file)
        model.refreshDraftAttachment(original.id)
        try await wait(model)
        precondition(model.draftAttachments[0] == updated, "Failed refresh must retain saved evidence")
        precondition(model.error?.contains("saved attachment was kept") == true)

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let dragged = root.appendingPathComponent("ttk4100.slx")
        let item = NSPasteboardItem()
        item.setString(dragged.absoluteString, forType: .fileURL)
        item.setString(root.path, forType: .string)
        board.writeObjects([item])
        precondition(AttachmentDropReader.fileURLs(from: board, allowPathStrings: true) == [dragged],
            "A real file URL must never also attach its parent folder from a text representation")
        board.clearContents()
        board.setPropertyList([dragged.path], forType: AttachmentDropReader.legacyFiles)
        board.setString(root.path, forType: .string)
        precondition(AttachmentDropReader.fileURLs(from: board, allowPathStrings: true) == [dragged])
        let folder = MessageAttachment(fileName: "TTK4100", mimeType: "inode/directory", byteCount: 1,
            extractedText: "Project folder: TTK4100", sourcePath: root.path)
        precondition(folder.sourceKindLabel == "Folder" && folder.readingDetailsText.contains("Folder: TTK4100"))
    }

    static func wait(_ model: StudyWorkspaceModel) async throws {
        for _ in 0..<500 where model.isIngestingAttachment { try await Task.sleep(for: .milliseconds(20)) }
        precondition(!model.isIngestingAttachment, "Attachment worker timed out")
    }
}
