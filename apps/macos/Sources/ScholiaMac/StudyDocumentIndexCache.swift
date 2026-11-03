import Foundation

/// Decoded indexes are shared by reading, practice, and context retrieval. File
/// identity is checked on every access so edits, OCR checkpoints, and atomic
/// replacements remain visible without retaining an entire library in memory.
final class StudyDocumentIndexCache: @unchecked Sendable {
    static let shared = StudyDocumentIndexCache(observesMemoryPressure: true)

    private struct Revision: Equatable {
        var size: Int
        var modified: Date?
        var fileNumber: UInt64?

        init(_ url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            modified = attributes[.modificationDate] as? Date
            fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        }
    }
    private struct Entry {
        var revision: Revision
        var index: StudyDocumentIndex
        var cost: Int
        var accessed: UInt64
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var cost = 0
    private var clock: UInt64 = 0
    private var memoryPressure = false
    private var cacheGeneration: UInt64 = 0
    private var pressureSource: DispatchSourceMemoryPressure?
    private let maximumBytes: Int
    private let maximumEntries: Int
    private let readData: @Sendable (URL) throws -> Data

    init(maximumBytes: Int = 24 * 1_024 * 1_024, maximumEntries: Int = 16,
         observesMemoryPressure: Bool = false,
         readData: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumEntries = max(0, maximumEntries)
        self.readData = readData
        if observesMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical],
                queue: .global(qos: .utility))
            pressureSource = source
            source.setEventHandler { [weak self] in
                guard let self, let pressure = self.pressureSource?.data else { return }
                self.setMemoryPressure(!pressure.contains(.normal))
            }
            source.resume()
        }
    }

    deinit { pressureSource?.cancel() }

    /// Keep active readers' snapshots usable while releasing cache ownership.
    /// Reads still work under pressure, but cannot refill the cache until it ends.
    func setMemoryPressure(_ active: Bool) {
        lock.withLock {
            memoryPressure = active
            if active {
                cacheGeneration &+= 1
                entries.removeAll(keepingCapacity: false)
                cost = 0
            }
        }
    }

    func index(at url: URL) throws -> StudyDocumentIndex {
        try Task.checkCancellation()
        let key = url.path
        let revision = try Revision(url)
        let (cached, generation) = lock.withLock { () -> (StudyDocumentIndex?, UInt64) in
            guard var entry = entries[key], entry.revision == revision else { return (nil, cacheGeneration) }
            clock &+= 1
            entry.accessed = clock
            entries[key] = entry
            return (entry.index, cacheGeneration)
        }
        if let cached { return cached }

        // Disk access and decoding never hold the cache lock. A cold document
        // cannot block readers of other already decoded indexes.
        let data = try readData(url)
        let index = try JSONDecoder().decode(StudyDocumentIndex.self, from: data)
        try Task.checkCancellation()
        // A concurrent writer may have replaced the file while it was read.
        // Return this valid snapshot but do not cache it under the newer file.
        guard try Revision(url) == revision else { return index }
        let entryCost = data.count + index.pages.reduce(0) { $0 + $1.text.utf8.count + 128 }
        lock.withLock {
            // An in-flight decode must not undo a pressure-triggered purge.
            guard !memoryPressure, generation == cacheGeneration else { return }
            if let previous = entries.removeValue(forKey: key) { cost -= previous.cost }
            guard maximumEntries > 0, entryCost <= maximumBytes else { return }
            while !entries.isEmpty && (entries.count >= maximumEntries || cost + entryCost > maximumBytes) {
                guard let oldest = entries.min(by: { $0.value.accessed < $1.value.accessed })?.key,
                      let removed = entries.removeValue(forKey: oldest) else { break }
                cost -= removed.cost
            }
            clock &+= 1
            entries[key] = Entry(revision: revision, index: index, cost: entryCost, accessed: clock)
            cost += entryCost
        }
        return index
    }
}
