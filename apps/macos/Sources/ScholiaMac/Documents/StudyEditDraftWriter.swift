import Foundation

/// Ordered per-document operations on one utility queue. A tombstone always
/// follows an in-flight save, and coalescing only replaces pending operations.
final class StudyEditDraftWriter: @unchecked Sendable {
    typealias Completion = @Sendable (UUID, String?) -> Void
    private struct Operation {
        var generation: UInt64
        var draft: StudyEditDraft?
        var completion: Completion
    }
    private let root: URL
    private let queue = DispatchQueue(label: "app.scholia.edit-drafts", qos: .utility)
    private let lock = NSLock()
    private var pending: [UUID: Operation] = [:]
    private var generations: [UUID: UInt64] = [:]
    private var running = false
    // Errors and retry values are confined to the writer queue.
    private var failures: [UUID: (Operation, String)] = [:]
    private let write: @Sendable (Data, URL) throws -> Void
    private(set) var writes = 0

    init(root: URL, write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.root = root.appendingPathComponent("Editing", isDirectory: true)
        self.write = write
    }
    private func file(_ id: UUID) -> URL { root.appendingPathComponent("\(id).json") }

    func save(_ draft: StudyEditDraft, completion: @escaping Completion) {
        enqueue(draft.documentID, draft: draft, completion: completion)
    }
    func remove(_ id: UUID, completion: @escaping Completion) { enqueue(id, draft: nil, completion: completion) }
    private func enqueue(_ id: UUID, draft: StudyEditDraft?, completion: @escaping Completion) {
        lock.withLock {
            let generation = (generations[id] ?? 0) &+ 1
            generations[id] = generation
            pending[id] = Operation(generation: generation, draft: draft, completion: completion)
            scheduleLocked()
        }
    }
    private func scheduleLocked() {
        guard !running else { return }
        running = true
        queue.async { [self] in
            while let next = lock.withLock({ () -> (UUID, Operation)? in
                guard let item = pending.first else { running = false; return nil }
                pending.removeValue(forKey: item.key)
                return (item.key, item.value)
            }) {
                let (id, operation) = next
                var message: String?
                do {
                    if let draft = operation.draft {
                        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        try write(JSONEncoder().encode(draft), file(id))
                        writes += 1
                    } else if FileManager.default.fileExists(atPath: file(id).path) {
                        try FileManager.default.removeItem(at: file(id))
                    }
                    lock.withLock { _ = failures.removeValue(forKey: id) }
                } catch {
                    message = error.localizedDescription
                    lock.withLock { failures[id] = (operation, error.localizedDescription) }
                }
                if lock.withLock({ generations[id] == operation.generation }) {
                    operation.completion(id, message)
                }
            }
        }
    }
    func recover(_ document: StudyDocument, store: StudyLibraryStore) async throws -> StudyEditDraft {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                queue.async { [self] in
                    do {
                        if let data = try? Data(contentsOf: file(document.id)),
                            let restored = try? JSONDecoder().decode(StudyEditDraft.self, from: data),
                            restored.documentID == document.id, restored.cells.map(\.id) == Array(restored.cells.indices) {
                            continuation.resume(returning: restored)
                        } else { continuation.resume(returning: try StudyDocumentEditing.read(document, store: store)) }
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
    }
    func retry() {
        lock.withLock {
            for (id, failure) in failures {
                guard generations[id] == failure.0.generation, pending[id] == nil else { continue }
                pending[id] = failure.0
            }
            if !pending.isEmpty { scheduleLocked() }
        }
    }
    func flush() throws {
        try queue.sync {
            let messages = lock.withLock { failures.map { "\($0.key): \($0.value.1)" }.sorted() }
            if !messages.isEmpty { throw StudyError.message(messages.joined(separator: "\n")) }
        }
    }
}
