import Foundation
import Darwin

/// Keep extraction and indexing away from the saved original until they both succeed.
struct StudyDocumentStaging: Sendable {
    let store: StudyLibraryStore

    struct PreparedDocument: Sendable {
        let document: StudyDocument
        fileprivate let root: URL
        fileprivate let files: [String: FileStamp]
    }
    fileprivate struct FileStamp: Equatable, Sendable {
        var size: UInt64
        var modified: Date
        var inode: UInt64
    }

    init(destination: StudyLibraryStore) {
        store = StudyLibraryStore(root: destination.root.appendingPathComponent("ImportStaging/\(UUID())"))
    }

    func discard() {
        // A failed rollback must never remove the only remaining old original.
        guard !FileManager.default.fileExists(atPath: store.root.appendingPathComponent("recovery-required").path) else { return }
        try? FileManager.default.removeItem(at: store.root)
    }

    /// Hash and decode on the import worker; commit only checks unchanged file stamps.
    func prepare(_ document: StudyDocument) throws -> PreparedDocument {
        try Task.checkCancellation()
        let before = try fileStamps(document)
        guard try store.isComplete(document), before == (try fileStamps(document)) else {
            throw StudyError.message("The downloaded file or its index is incomplete. Retry the download.")
        }
        var verified = document
        verified.contentBytes = before[URL(fileURLWithPath: document.fileName).lastPathComponent].map { Int($0.size) }
        verified.contentCheckedAt = Date()
        verified.contentIntegrity = .verified
        return PreparedDocument(document: verified, root: store.root, files: before)
    }

    func commit(_ document: StudyDocument, to destination: StudyLibraryStore) throws {
        try commit(prepare(document), to: destination)
    }

    func commit(_ prepared: PreparedDocument, to destination: StudyLibraryStore) throws {
        try Task.checkCancellation()
        let document = prepared.document
        guard prepared.root == store.root, prepared.files == (try fileStamps(document)) else {
            throw StudyError.message("The staged download changed before it could be saved. Retry the download.")
        }
        let manager = FileManager.default
        let staged = store.directory(for: document.id)
        let target = destination.directory(for: document.id)
        let backup = destination.root.appendingPathComponent("Revisions/\(document.id)/\(UUID())")
        let replacing = manager.fileExists(atPath: target.path)
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard replacing else { try manager.moveItem(at: staged, to: target); return }
        try manager.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Atomic directory exchange leaves a complete original+index at target,
        // even if the process exits between installing it and archiving the old copy.
        guard renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            try manager.moveItem(at: staged, to: backup)
        } catch {
            if renamex_np(staged.path, target.path, UInt32(RENAME_SWAP)) != 0 {
                try? Data("Previous original retained for recovery".utf8)
                    .write(to: store.root.appendingPathComponent("recovery-required"), options: .atomic)
                throw StudyError.message("The replacement is saved, but its previous copy could not be archived. It is retained at \(store.root.path).")
            }
            throw error
        }
    }

    private func fileStamps(_ document: StudyDocument) throws -> [String: FileStamp] {
        let manager = FileManager.default
        let directory = store.directory(for: document.id)
        let names = try manager.contentsOfDirectory(atPath: directory.path)
        var result: [String: FileStamp] = [:]
        for name in names {
            let attributes = try manager.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                let size = attributes[.size] as? NSNumber,
                let modified = attributes[.modificationDate] as? Date,
                let inode = attributes[.systemFileNumber] as? NSNumber else {
                throw StudyError.message("The staged download contains an unexpected file.")
            }
            result[name] = FileStamp(size: size.uint64Value, modified: modified, inode: inode.uint64Value)
        }
        return result
    }
}
