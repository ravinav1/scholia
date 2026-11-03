import Foundation

/// A serial, coalescing writer keeps JSON encoding and disk I/O off the UI thread.
/// Flush remains synchronous at lifecycle boundaries so the latest draft is durable.
final class StudyLibraryWriter: @unchecked Sendable {
    private let store: StudyLibraryStore
    private let queue = DispatchQueue(label: "app.scholia.library-writer", qos: .utility)
    private let lock = NSLock()
    private var pending: StudyLibrary?
    private var running = false
    // Accessed only on queue, including by the async durability barrier.
    private var latestWriteError: Error?
    init(store: StudyLibraryStore) { self.store = store }

    func save(_ library: StudyLibrary, onError: @escaping @Sendable (String) -> Void) {
        lock.withLock {
            pending = library
            guard !running else { return }
            running = true
            // Enqueue while holding the lock: a following barrier cannot overtake this save.
            queue.async { [self] in
                while let snapshot = lock.withLock({ () -> StudyLibrary? in
                    guard let value = pending else {
                        running = false
                        return nil
                    }
                    pending = nil
                    return value
                }) {
                    do {
                        try store.save(snapshot)
                        latestWriteError = nil
                    } catch {
                        latestWriteError = error
                        onError(error.localizedDescription)
                    }
                }
            }
        }
    }

    /// Wait for already submitted snapshots without capturing or rewriting library state.
    /// A failed write remains a failure until a later snapshot is successfully saved.
    func waitForPendingWrites() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.withLock {
                queue.async { [self] in
                    if let error = latestWriteError { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
    }

    func flush(_ library: StudyLibrary) throws {
        // Use the same ordering/coalescing path so a newer queued snapshot always wins.
        save(library, onError: { _ in })
        try queue.sync {
            if let error = latestWriteError { throw error }
        }
    }
}
