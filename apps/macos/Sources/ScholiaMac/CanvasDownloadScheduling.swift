import Foundation

enum CanvasSavedFileIntegrity: String, Codable, Sendable {
    case verified, unverified, needsRepair
}

struct CanvasSavedFileCheck: Sendable {
    var document: StudyDocument
    var bytes: Int?
    var integrity: CanvasSavedFileIntegrity
    var checkedAt: Date

    static func run(_ documents: [StudyDocument], store: StudyLibraryStore) throws -> [Self] {
        try documents.map { document in
            try Task.checkCancellation()
            let attributes = try? store.file(for: document).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let bytes = attributes?.isRegularFile == true ? attributes?.fileSize : nil
            let integrity: CanvasSavedFileIntegrity
            if try store.isComplete(document) { integrity = .verified }
            else if bytes != nil && document.contentHash == nil { integrity = .unverified }
            else { integrity = .needsRepair }
            return Self(document: document, bytes: bytes, integrity: integrity, checkedAt: Date())
        }
    }
}

struct CanvasCourseDownloadInventory: Identifiable {
    var id: UUID
    var title: String
    var saved = 0
    var bytes: Int64 = 0
    var verified = 0
    var unverified = 0
    var repairs = 0
    var ready = 0
    var available = 0
    var unavailable = 0
    var checkedAt: Date?

    var formattedBytes: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static func make(_ course: StudyCourse) -> Self {
        let documents = course.documents.filter { $0.sourceKey != nil }
        var value = Self(id: course.id, title: course.displayName)
        for document in documents {
            if let bytes = document.contentBytes {
                value.saved += 1
                value.bytes += Int64(bytes)
            }
            switch document.contentIntegrity {
            case .verified: value.verified += 1
            case .needsRepair: value.repairs += 1
            default: value.unverified += 1
            }
            if let checked = document.contentCheckedAt {
                value.checkedAt = max(value.checkedAt ?? .distantPast, checked)
            }
        }
        let bySource = Dictionary(documents.map { ($0.sourceKey!, $0) }, uniquingKeysWith: { first, _ in first })
        for reference in course.materials {
            guard reference.unavailableReason == nil else { value.unavailable += 1; continue }
            value.available += 1
            if let document = bySource[reference.id], document.contentIntegrity == .verified,
                reference.version.isEmpty || document.sourceVersion == reference.version {
                value.ready += 1
            }
        }
        return value
    }

    static func total(_ courses: [Self]) -> Self {
        var value = Self(id: UUID(), title: "All courses")
        for course in courses {
            value.saved += course.saved; value.bytes += course.bytes
            value.verified += course.verified; value.unverified += course.unverified
            value.repairs += course.repairs; value.ready += course.ready
            value.available += course.available; value.unavailable += course.unavailable
            if let checked = course.checkedAt { value.checkedAt = max(value.checkedAt ?? .distantPast, checked) }
        }
        return value
    }
}

enum CanvasDownloadPriority: String, CaseIterable, Identifiable, Sendable {
    case background, prioritized
    var id: String { rawValue }
    var title: String { self == .background ? "Background" : "Prioritize downloads" }
    var detail: String {
        self == .background
            ? "Downloads run gently while you use Scholia."
            : "Downloads use available bandwidth without pausing for study activity."
    }
    var taskPriority: TaskPriority { self == .background ? .background : .userInitiated }
    var concurrentDownloads: Int { self == .background ? 1 : CanvasDownloadScheduling.maximumConcurrentDownloads }
    var networkPriority: Float { self == .background ? URLSessionTask.lowPriority : URLSessionTask.highPriority }
}

/// Keeps active transfers in step with the priority control without restarting them.
final class CanvasDownloadTaskPriority: @unchecked Sendable {
    private let lock = NSLock()
    private var priority: CanvasDownloadPriority
    private var tasks: [ObjectIdentifier: URLSessionTask] = [:]

    init(_ priority: CanvasDownloadPriority) { self.priority = priority }
    func update(_ priority: CanvasDownloadPriority) {
        lock.withLock {
            self.priority = priority
            for task in tasks.values { task.priority = priority.networkPriority }
        }
    }
    func register(_ task: URLSessionTask) {
        lock.withLock {
            tasks[ObjectIdentifier(task)] = task
            task.priority = priority.networkPriority
        }
    }
    func remove(_ task: URLSessionTask) { _ = lock.withLock { tasks.removeValue(forKey: ObjectIdentifier(task)) } }
}

private enum CanvasDownloadEvent<Output: Sendable>: Sendable {
    case completed(Int, Output)
    case capacityCheck
}

enum CanvasDownloadScheduling {
    static let maximumConcurrentDownloads = 6

    /// A bounded pool keeps downloading while completed files are saved. One
    /// cancellable wake-up lets a live priority change open slots during a slow transfer.
    /// Completion callbacks are serialized so durable checkpoints cannot move backwards.
    @MainActor static func run<Output: Sendable>(
        count: Int,
        priority: @escaping @MainActor @Sendable () -> CanvasDownloadPriority,
        operation: @escaping @MainActor @Sendable (Int) async throws -> Output,
        completed: @MainActor (Int, Output) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: CanvasDownloadEvent<Output>.self) { group in
            var next = 0, active = 0, finished = 0
            var checkingCapacity = false
            while finished < count {
                try Task.checkCancellation()
                while next < count && active < priority().concurrentDownloads {
                    let index = next
                    next += 1; active += 1
                    group.addTask(priority: priority().taskPriority) {
                        .completed(index, try await operation(index))
                    }
                }
                if next < count && active < maximumConcurrentDownloads && !checkingCapacity {
                    checkingCapacity = true
                    group.addTask {
                        try await Task.sleep(for: .milliseconds(100))
                        return .capacityCheck
                    }
                }
                guard let event = try await group.next() else { break }
                switch event {
                case .capacityCheck:
                    checkingCapacity = false
                case .completed(let index, let output):
                    active -= 1; finished += 1
                    try await completed(index, output)
                }
            }
            group.cancelAll()
        }
    }

    /// Short sleeps are cancellable and reread the controls, so a priority change takes effect during a pause.
    @MainActor static func checkpoint(
        priority: () -> CanvasDownloadPriority,
        foregroundBusy: () -> Bool,
        constrained: () -> Bool,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) async throws {
        try Task.checkCancellation()
        while priority() == .background && foregroundBusy() {
            try await sleep(.milliseconds(50))
            try Task.checkCancellation()
        }
        let slices = constrained() ? 12 : 4
        for _ in 0..<slices {
            guard priority() == .background else { break }
            try await sleep(.milliseconds(50))
            try Task.checkCancellation()
            while priority() == .background && foregroundBusy() {
                try await sleep(.milliseconds(50))
                try Task.checkCancellation()
            }
        }
        await Task.yield()
        try Task.checkCancellation()
    }
}

struct CanvasDownloadProgress: Codable, Equatable, Sendable {
    var origin: String
    var userID: Int
    var remainingCourseIDs: [UUID]
    var pendingMaterialIDs: [UUID: [String]] = [:]
}

actor CanvasDownloadProgressStore {
    private let file: URL
    init(root: URL) { file = Self.file(root: root) }
    private static func file(root: URL) -> URL { root.appendingPathComponent("canvas-download-progress.json") }
    static func load(root: URL) throws -> CanvasDownloadProgress? {
        let file = file(root: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(CanvasDownloadProgress.self, from: Data(contentsOf: file))
    }
    func save(_ progress: CanvasDownloadProgress?) throws {
        if let progress, !progress.remainingCourseIDs.isEmpty {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(progress).write(to: file, options: .atomic)
        } else if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}

@MainActor final class CanvasMaterialTransfer {
    let id = UUID()
    let maximumBytes: Int
    let task: Task<(StudyDocument, Int), Error>
    var waiters = Set<UUID>()
    var finished = false
    init(maximumBytes: Int, task: Task<(StudyDocument, Int), Error>) {
        self.maximumBytes = maximumBytes
        self.task = task
    }
}

/// Each caller can stop waiting without cancelling a transfer still needed by another caller.
final class CanvasMaterialWaiter: @unchecked Sendable {
    typealias Value = (StudyDocument, Int)
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    func install(_ continuation: CheckedContinuation<Value, Error>) {
        let result = lock.withLock { () -> Result<Value, Error>? in
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }
    func complete(_ result: Result<Value, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
