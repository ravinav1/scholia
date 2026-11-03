import CryptoKit
import Foundation

/// Immutable extracted evidence is separate from the small attachment preview
/// serialized in conversation history. A corpus key is its SHA-256 digest, not a
/// filesystem path supplied by an attachment or document.
enum AttachmentTextCorpusStore {
    static let maximumUTF16Units = 50_000_000
    private static let maximumUTF8Bytes = maximumUTF16Units * 3
    @TaskLocal static var directoryOverride: URL?
    private static let cache = CorpusCache()

    struct Reference: Sendable {
        var id: String
        var utf16Count: Int
    }

    struct CorpusError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private static var directory: URL {
        directoryOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scholia/AttachmentText", isDirectory: true)
    }

    static func store(_ text: String) throws -> Reference {
        try Task.checkCancellation()
        let units = text.utf16.count
        guard units <= maximumUTF16Units else {
            throw CorpusError(message: "Extracted text exceeds the 50-million-character resource limit; a smaller project scope is required.")
        }
        let data = Data(text.utf8)
        let id = digest(data)
        let root = directory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent(id + ".txt")
        if !FileManager.default.fileExists(atPath: file.path) {
            try data.write(to: file, options: .atomic)
        } else {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= maximumUTF8Bytes else {
                throw CorpusError(message: "The full-text storage location is not a valid corpus file.")
            }
            let existing = try Data(contentsOf: file, options: .mappedIfSafe)
            if digest(existing) != id { try data.write(to: file, options: .atomic) }
        }
        try Task.checkCancellation()
        cache.insert(text, key: file.path)
        return Reference(id: id, utf16Count: units)
    }

    /// A missing or corrupted corpus is an evidence gap. Never return the
    /// preview as though it were the original complete extracted document.
    static func text(for attachment: MessageAttachment) throws -> String {
        guard let id = attachment.textCorpusID else { return attachment.extractedText }
        try Task.checkCancellation()
        guard id.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CorpusError(message: "The saved full-text reference is invalid. Read the original attachment again.")
        }
        let file = directory.appendingPathComponent(id + ".txt")
        if let value = cache.value(for: file.path) {
            try validateCount(value, expected: attachment.textCorpusUTF16Count)
            return value
        }
        do {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= maximumUTF8Bytes else {
                throw CorpusError(message: "The saved full text is not a valid local corpus. Read the original attachment again.")
            }
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            guard digest(data) == id, let text = String(data: data, encoding: .utf8), text.utf16.count <= maximumUTF16Units else {
                throw CorpusError(message: "The saved full text failed its integrity check. Read the original attachment again.")
            }
            try validateCount(text, expected: attachment.textCorpusUTF16Count)
            try Task.checkCancellation()
            cache.insert(text, key: file.path)
            return text
        } catch is CancellationError { throw CancellationError() }
        catch let error as CorpusError { throw error }
        catch {
            throw CorpusError(message: "The saved full text is unavailable (\(error.localizedDescription)). Read the original attachment again; the preview alone is incomplete.")
        }
    }

    private static func validateCount(_ text: String, expected: Int?) throws {
        if let expected, expected != text.utf16.count {
            throw CorpusError(message: "The saved full-text length does not match this attachment. Read the original attachment again.")
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private final class CorpusCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        private var order: [String] = []
        private var cost = 0
        func value(for key: String) -> String? { lock.withLock { values[key] } }
        func insert(_ text: String, key: String) {
            let size = text.utf16.count
            guard size <= 10_000_000 else { return }
            lock.withLock {
                guard values[key] == nil else { return }
                while !order.isEmpty && (order.count >= 8 || cost + size > 20_000_000) {
                    if let removed = values.removeValue(forKey: order.removeFirst()) { cost -= removed.utf16.count }
                }
                values[key] = text; order.append(key); cost += size
            }
        }
    }
}
