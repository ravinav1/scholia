import CryptoKit
import Foundation
import SQLite3

// These value comparisons let metadata changes avoid serializing unchanged
// catalogs, conversations and attachments. Arrays retain their shared storage.
extension ContentPollingModel.Bin: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hours == rhs.hours && lhs.events == rhs.events && lhs.days == rhs.days
    }
}
extension ContentPollingModel: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.version == rhs.version && lhs.timeZone == rhs.timeZone && lhs.bins == rhs.bins
            && lhs.failures == rhs.failures && lhs.extraChecks == rhs.extraChecks
            && lhs.attemptedAt == rhs.attemptedAt && lhs.observedAt == rhs.observedAt
            && lhs.updatedAt == rhs.updatedAt && lhs.retryAfter == rhs.retryAfter && lhs.signature == rhs.signature
    }
}

/// One helper is owned by a StudyLibraryStore and shared by copies of that value.
/// There is no process-wide root cache. A lock owns the SQLite connection and
/// last committed snapshot; the writer invokes this on its serial utility queue.
final class StudyLibraryPersistence: @unchecked Sendable {
    struct Metrics: Equatable, Sendable {
        var encodedRows = 0
        var encodedBytes = 0
        var writtenRows = 0
        var deletedRows = 0
        var reorderedRows = 0
        var transactions = 0
    }
    private let root: URL
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var committed: StudyLibrary?
    private var revision: Int64?
    private var lastMetrics = Metrics()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let migrationWillCommit: (() throws -> Void)?
    private static let applicationID: Int64 = 0x5343484c
    private static let schemaVersion: Int64 = 1
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(root: URL, migrationWillCommit: (() throws -> Void)? = nil) {
        self.root = root
        self.migrationWillCommit = migrationWillCommit
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }
    deinit { if let db { sqlite3_close_v2(db) } }
    var metrics: Metrics { lock.withLock { lastMetrics } }

    func load() throws -> StudyLibrary {
        try lock.withLock {
            try open()
            // A read transaction keeps metadata and child rows from different
            // commits from being combined when another process writes.
            try execute("BEGIN DEFERRED")
            do {
                try validateSchema()
                let loaded = try readLibrary()
                let value = try currentRevision()
                try execute("COMMIT")
                committed = loaded
                revision = value
                return loaded
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }

    /// The optional hook is used by standalone fault-injection checks. It runs
    /// inside the transaction, before either data or the cache is committed.
    func save(_ library: StudyLibrary, beforeCommit: (() throws -> Void)? = nil) throws {
        try lock.withLock {
            guard library.version == 1 else { throw newerVersion() }
            try open()
            try execute("BEGIN IMMEDIATE")
            do {
                try validateSchema()
                let current = try currentRevision()
                if let revision, revision != current {
                    throw StudyError.message("Your study library changed in another process. Reopen the study workspace before saving again. Your unsaved changes remain in this window.")
                }
                let previous = try committed ?? readLibrary()
                var work = Metrics()
                try apply(library, previous: previous, work: &work)
                if work.writtenRows + work.deletedRows + work.reorderedRows > 0 {
                    try execute("UPDATE library_metadata SET revision = revision + 1 WHERE singleton = 1")
                    work.transactions = 1
                }
                try beforeCommit?()
                let nextRevision = try currentRevision()
                try execute("COMMIT")
                committed = library
                revision = nextRevision
                lastMetrics = work
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }

    func exportJSON(to destination: URL) throws {
        let normalized = destination.standardizedFileURL.resolvingSymlinksInPath()
        let activeFiles = ["library.sqlite", "library.sqlite-wal", "library.sqlite-shm"].map {
            root.appendingPathComponent($0).standardizedFileURL.resolvingSymlinksInPath()
        }
        guard !activeFiles.contains(normalized) else {
            throw StudyError.message("Choose a JSON export file outside the active SQLite files.")
        }
        // Export is a read, not an instruction to rebase a live writer's
        // expected revision after another process has changed the database.
        let library = try lock.withLock {
            try open()
            try execute("BEGIN DEFERRED")
            do {
                try validateSchema()
                let result = try readLibrary()
                try execute("COMMIT")
                return result
            } catch { try? execute("ROLLBACK"); throw error }
        }
        let exportEncoder = JSONEncoder()
        exportEncoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try exportEncoder.encode(library).write(to: destination, options: .atomic)
    }

    private func open() throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(root.appendingPathComponent("library.sqlite").path, &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let connection else {
            let detail = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open SQLite"
            if let connection { sqlite3_close_v2(connection) }
            throw StudyError.message("Could not open the study library: \(detail)")
        }
        db = connection
        do {
            sqlite3_busy_timeout(connection, 5_000)
            try execute("PRAGMA foreign_keys = ON")
            let version = try integer("PRAGMA user_version")
            let application = try integer("PRAGMA application_id")
            guard version <= Self.schemaVersion, application == 0 || application == Self.applicationID else {
                throw newerVersion()
            }
            if version == 0 {
                try initialize()
            } else {
                guard application == Self.applicationID else { throw newerVersion() }
                _ = try currentRevision()
            }
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
        } catch {
            sqlite3_close_v2(connection)
            db = nil
            throw error
        }
    }

    private func initialize() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            // The migration lock covers the schema check and backup creation:
            // concurrent first launches must not race on either file.
            if try integer("PRAGMA user_version") != 0 {
                guard try integer("PRAGMA user_version") == Self.schemaVersion,
                      try integer("PRAGMA application_id") == Self.applicationID else { throw newerVersion() }
                try execute("COMMIT")
                return
            }
            guard try integer("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") == 0 else {
                throw StudyError.message("The study database has an unrecognized schema. It has been preserved.")
            }
            let legacyURL = root.appendingPathComponent("library.json")
            var initial = StudyLibrary()
            var backup: String?
            if FileManager.default.fileExists(atPath: legacyURL.path) {
                let data = try Data(contentsOf: legacyURL)
                initial = try decoder.decode(StudyLibrary.self, from: data)
                guard initial.version == 1 else { throw newerVersion() }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let name = "library-v1-backup-\(digest).json"
                let destination = root.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    // Foundation rejects atomic+withoutOverwriting. Publish a
                    // completely written unique sibling with a no-replace move.
                    let temporary = root.appendingPathComponent(".library-v1-backup-\(UUID()).tmp")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try data.write(to: temporary, options: .atomic)
                    do { try FileManager.default.moveItem(at: temporary, to: destination) }
                    catch {
                        guard (try? Data(contentsOf: destination)) == data else { throw error }
                    }
                }
                guard try Data(contentsOf: destination) == data else {
                    throw StudyError.message("The legacy library backup does not match its source. Both files have been preserved.")
                }
                backup = name
            }
            try execute("""
                CREATE TABLE library_metadata (singleton INTEGER PRIMARY KEY CHECK(singleton = 1), revision INTEGER NOT NULL, payload BLOB NOT NULL, legacy_backup TEXT);
                CREATE TABLE courses (id TEXT PRIMARY KEY, position INTEGER NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE documents (course_id TEXT NOT NULL, id TEXT NOT NULL, position INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(course_id,id), FOREIGN KEY(course_id) REFERENCES courses(id) ON DELETE CASCADE);
                CREATE TABLE materials (course_id TEXT NOT NULL, id TEXT NOT NULL, position INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(course_id,id), FOREIGN KEY(course_id) REFERENCES courses(id) ON DELETE CASCADE);
                CREATE TABLE threads (course_id TEXT NOT NULL, id TEXT NOT NULL, position INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(course_id,id), FOREIGN KEY(course_id) REFERENCES courses(id) ON DELETE CASCADE);
                CREATE TABLE messages (course_id TEXT NOT NULL, thread_id TEXT NOT NULL, id TEXT NOT NULL, position INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(course_id,thread_id,id), FOREIGN KEY(course_id,thread_id) REFERENCES threads(course_id,id) ON DELETE CASCADE);
                """)
            var work = Metrics()
            let metadata = try encoded(Self.metadata(initial), work: &work)
            try execute("INSERT INTO library_metadata(singleton, revision, payload, legacy_backup) VALUES(1, 0, ?, ?)",
                [.data(metadata), backup.map(Value.text) ?? .null])
            var empty = initial
            empty.courses = []
            try apply(initial, previous: empty, work: &work)
            try execute("PRAGMA application_id = \(Self.applicationID)")
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
            try migrationWillCommit?()
            try execute("COMMIT")
            work.transactions = 1
            lastMetrics = work
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private static func metadata(_ library: StudyLibrary) -> StudyLibrary {
        var value = library; value.courses = []; return value
    }
    private static func metadata(_ course: StudyCourse) -> StudyCourse {
        var value = course
        value.documents = []; value.threads = []
        // Preserve nil versus an explicitly empty catalog in the portable model.
        value.canvasMaterials = course.canvasMaterials == nil ? nil : []
        return value
    }
    private static func metadata(_ thread: StudyThread) -> StudyThread {
        var value = thread; value.messages = []; return value
    }

    private func apply(_ library: StudyLibrary, previous: StudyLibrary, work: inout Metrics) throws {
        if Self.metadata(library) != Self.metadata(previous) {
            try execute("UPDATE library_metadata SET payload = ? WHERE singleton = 1", [.data(try encoded(Self.metadata(library), work: &work))])
            work.writtenRows += 1
        }
        // Comparing shared arrays avoids a full traversal for unchanged subtrees.
        guard library.courses != previous.courses else { return }
        let oldCourses = try unique(previous.courses, id: { $0.id.uuidString })
        try sync(table: "courses", owner: [], current: library.courses.map(Self.metadata),
            previous: previous.courses.map(Self.metadata), id: { $0.id.uuidString }, work: &work)
        for course in library.courses {
            let owner = [("course_id", course.id.uuidString)]
            let old = oldCourses[course.id.uuidString]?.value
            if course.documents != old?.documents {
                try sync(table: "documents", owner: owner, current: course.documents, previous: old?.documents ?? [],
                    id: { $0.id.uuidString }, work: &work)
            }
            if course.canvasMaterials != old?.canvasMaterials {
                try sync(table: "materials", owner: owner, current: course.canvasMaterials ?? [], previous: old?.canvasMaterials ?? [],
                    id: { $0.id }, work: &work)
            }
            if course.threads != old?.threads {
                let oldThreads = try unique(old?.threads ?? [], id: { $0.id.uuidString })
                try sync(table: "threads", owner: owner, current: course.threads.map(Self.metadata),
                    previous: (old?.threads ?? []).map(Self.metadata), id: { $0.id.uuidString }, work: &work)
                for thread in course.threads {
                    let oldThread = oldThreads[thread.id.uuidString]?.value
                    if thread.messages != oldThread?.messages {
                        try sync(table: "messages", owner: owner + [("thread_id", thread.id.uuidString)],
                            current: thread.messages, previous: oldThread?.messages ?? [], id: { $0.id.uuidString }, work: &work)
                    }
                }
            }
        }
    }

    private func unique<T>(_ values: [T], id: (T) -> String) throws -> [String: (index: Int, value: T)] {
        var result: [String: (index: Int, value: T)] = [:]
        for (index, value) in values.enumerated() {
            let key = id(value)
            guard result.updateValue((index, value), forKey: key) == nil else {
                throw StudyError.message("The study library contains duplicate item identifiers. The previous saved library has been preserved.")
            }
        }
        return result
    }
    private func sync<T: Codable & Equatable>(table: String, owner: [(String, String)], current: [T], previous: [T],
        id: (T) -> String, work: inout Metrics) throws {
        guard current != previous else { return }
        let old = try unique(previous, id: id)
        let next = try unique(current, id: id)
        let ownerColumns = owner.map(\.0)
        let ownerValues = owner.map { Value.text($0.1) }
        let predicate = (ownerColumns + ["id"]).map { "\($0) = ?" }.joined(separator: " AND ")
        for key in old.keys where next[key] == nil {
            try execute("DELETE FROM \(table) WHERE \(predicate)", ownerValues + [.text(key)])
            work.deletedRows += Int(sqlite3_changes(db))
        }
        for (position, value) in current.enumerated() {
            let key = id(value)
            let earlier = old[key]
            if earlier?.value != value {
                let columns = ownerColumns + ["id", "position", "payload"]
                let conflict = (ownerColumns + ["id"]).joined(separator: ",")
                try execute("INSERT INTO \(table)(\(columns.joined(separator: ","))) VALUES(\(columns.map { _ in "?" }.joined(separator: ","))) ON CONFLICT(\(conflict)) DO UPDATE SET position = excluded.position, payload = excluded.payload",
                    ownerValues + [.text(key), .integer(Int64(position)), .data(try encoded(value, work: &work))])
                work.writtenRows += 1
            } else if earlier?.index != position {
                try execute("UPDATE \(table) SET position = ? WHERE \(predicate)", [.integer(Int64(position))] + ownerValues + [.text(key)])
                work.reorderedRows += 1
            }
        }
    }

    private func readLibrary() throws -> StudyLibrary {
        guard let data = try blobs("SELECT payload FROM library_metadata WHERE singleton = 1").first else {
            throw StudyError.message("The study database is missing its committed metadata. It has been preserved.")
        }
        var library = try decoder.decode(StudyLibrary.self, from: data)
        guard library.version == 1 else { throw newerVersion() }
        library.courses = try rows(StudyCourse.self, table: "courses", owner: [])
        for ci in library.courses.indices {
            let owner = [("course_id", library.courses[ci].id.uuidString)]
            library.courses[ci].documents = try rows(StudyDocument.self, table: "documents", owner: owner)
            if library.courses[ci].canvasMaterials != nil {
                library.courses[ci].canvasMaterials = try rows(CanvasMaterialReference.self, table: "materials", owner: owner)
            }
            library.courses[ci].threads = try rows(StudyThread.self, table: "threads", owner: owner)
            for ti in library.courses[ci].threads.indices {
                let threadOwner = owner + [("thread_id", library.courses[ci].threads[ti].id.uuidString)]
                library.courses[ci].threads[ti].messages = try rows(ConversationMessage.self, table: "messages", owner: threadOwner)
            }
        }
        return library
    }
    private func rows<T: Decodable>(_ type: T.Type, table: String, owner: [(String, String)]) throws -> [T] {
        let predicate = owner.isEmpty ? "" : " WHERE " + owner.map { "\($0.0) = ?" }.joined(separator: " AND ")
        return try blobs("SELECT payload FROM \(table)\(predicate) ORDER BY position", owner.map { .text($0.1) })
            .map { try decoder.decode(type, from: $0) }
    }
    private func encoded<T: Encodable>(_ value: T, work: inout Metrics) throws -> Data {
        let data = try encoder.encode(value)
        work.encodedRows += 1
        work.encodedBytes += data.count
        return data
    }
    private func currentRevision() throws -> Int64 {
        try integer("SELECT revision FROM library_metadata WHERE singleton = 1")
    }
    private func validateSchema() throws {
        guard try integer("PRAGMA user_version") == Self.schemaVersion,
              try integer("PRAGMA application_id") == Self.applicationID else { throw newerVersion() }
    }
    private func newerVersion() -> StudyError { .message("This library uses a newer or unrecognized Scholia database version. Its files have been preserved.") }

    private enum Value { case text(String), data(Data), integer(Int64), null }
    private func statement(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &value, nil) == SQLITE_OK, let value else { throw failure() }
        do {
            for (offset, input) in values.enumerated() {
                let index = Int32(offset + 1)
                let result: Int32
                switch input {
                case .text(let text):
                    let utf8 = text.utf8CString
                    guard utf8.count - 1 <= Int(Int32.max) else { throw StudyError.message("A study library identifier is too large to save.") }
                    result = utf8.withUnsafeBufferPointer {
                        sqlite3_bind_text(value, index, $0.baseAddress, Int32($0.count - 1), Self.transient)
                    }
                case .data(let data):
                    guard data.count <= Int(Int32.max) else { throw StudyError.message("A study library item is too large to save.") }
                    result = data.withUnsafeBytes { sqlite3_bind_blob(value, index, $0.baseAddress, Int32($0.count), Self.transient) }
                case .integer(let number): result = sqlite3_bind_int64(value, index, number)
                case .null: result = sqlite3_bind_null(value, index)
                }
                guard result == SQLITE_OK else { throw failure() }
            }
            return value
        } catch { sqlite3_finalize(value); throw error }
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        if values.isEmpty {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
            return
        }
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func integer(_ sql: String) throws -> Int64 {
        let statement = try statement(sql, [])
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_int64(statement, 0)
    }
    private func blobs(_ sql: String, _ values: [Value] = []) throws -> [Data] {
        let statement = try statement(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [Data] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw failure() }
            result.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        }
    }
    private func failure() -> StudyError {
        .message("Could not save or read the study database: \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable"). The last committed library has been preserved.")
    }
}
