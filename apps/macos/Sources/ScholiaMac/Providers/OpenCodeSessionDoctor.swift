import Foundation
import SQLite3

/// A session-poisoning attachment found in opencode's local database.
/// Providers that cannot deserialize file data-URL blocks reject every later
/// request that replays the affected session.
struct OpenCodePoisonedAttachment: Identifiable, Hashable, Sendable {
    var id: String { partID }
    var partID: String
    var sessionID: String
    var sessionTitle: String
    var messageID: String
    var isUserFilePart: Bool
    var toolName: String?
    var fileName: String?
    var mimeType: String?
    var byteCount: Int

    var summary: String {
        let candidate = fileName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = candidate.flatMap { $0.isEmpty ? nil : $0 } ?? mimeType ?? "attachment"
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        if isUserFilePart {
            return "\(kind) · \(size) · attached to a user message"
        }
        return "\(kind) · \(size) · \(toolName ?? "tool") result"
    }
}

enum OpenCodeSessionDoctorError: LocalizedError, Equatable {
    case cannotOpenDatabase(String)
    case backupFailed(String)
    case updateFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenDatabase(let detail):
            "Could not open opencode's database. \(detail)"
        case .backupFailed(let detail):
            "Could not back up opencode's database, so no changes were made. \(detail)"
        case .updateFailed(let detail):
            "Repairing the opencode database failed. \(detail)"
        }
    }
}

/// Read-only scanning is always safe. Mutating operations are transactionally
/// atomic and are expected to be preceded by `backup(databaseURL:)` from the
/// user-confirmed settings action.
enum OpenCodeSessionDoctor {
    static let maximumSafeDataURLBytes = 512 * 1_024

    struct RepairOutcome: Equatable, Sendable {
        var strippedParts: Int
        var deletedSessions: Int
        var backupURL: URL?
    }

    static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL? {
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    static func backupDirectory(fileManager: FileManager = .default) -> URL? {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = support
            .appendingPathComponent("Scholia", isDirectory: true)
            .appendingPathComponent("opencode-backups", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }

    /// Reports user file parts containing unsafe data URLs and tool attachment
    /// arrays containing either non-image data URLs or oversized images.
    static func scan(databaseURL: URL) throws -> [OpenCodePoisonedAttachment] {
        let connection = try SQLite3.open(url: databaseURL, readOnly: true)
        defer { sqlite3_close(connection) }

        let titleExpression: String
        if try SQLite3.table("session", hasColumn: "title", connection: connection) {
            titleExpression = "COALESCE(NULLIF(s.title, ''), '(untitled)')"
        } else if try SQLite3.table("session", hasColumn: "data", connection: connection) {
            titleExpression = "COALESCE(NULLIF(json_extract(s.data, '$.title'), ''), '(untitled)')"
        } else {
            titleExpression = "'(untitled)'"
        }

        var findings: [OpenCodePoisonedAttachment] = []
        try SQLite3.forEachRow(
            connection,
            sql: """
            SELECT p.id, p.message_id, p.session_id, p.data, \(titleExpression)
            FROM part AS p
            LEFT JOIN session AS s ON s.id = p.session_id
            WHERE json_valid(p.data)
              AND p.data LIKE '%data:%'
              AND (
                json_extract(p.data, '$.type') = 'file'
                OR (
                  json_extract(p.data, '$.type') = 'tool'
                  AND json_type(p.data, '$.state.attachments') = 'array'
                )
              )
            ORDER BY p.session_id, p.id
            """
        ) { row in
            guard let partID = row[safe: 0] as? String,
                  let messageID = row[safe: 1] as? String,
                  let sessionID = row[safe: 2] as? String,
                  let serialized = row[safe: 3] as? String,
                  let part = try? JSONSerialization.jsonObject(
                    with: Data(serialized.utf8)
                  ) as? [String: Any],
                  let type = part["type"] as? String else { return }

            let title = (row[safe: 4] as? String) ?? "(untitled)"
            let isUserFilePart = type == "file"
            guard isUserFilePart || type == "tool" else { return }
            for candidate in attachmentCandidates(in: part, isUserFilePart: isUserFilePart) {
                guard let diagnosis = diagnose(dataURL: candidate.url) else { continue }
                findings.append(OpenCodePoisonedAttachment(
                    partID: partID,
                    sessionID: sessionID,
                    sessionTitle: title,
                    messageID: messageID,
                    isUserFilePart: isUserFilePart,
                    toolName: isUserFilePart ? nil : (part["tool"] as? String),
                    fileName: candidate.name,
                    mimeType: diagnosis.mimeType,
                    byteCount: diagnosis.byteCount
                ))
                // A repair is performed per part. One finding is therefore
                // sufficient even when the same tool part has several bad URLs.
                break
            }
        }
        return findings
    }

    /// Returns nil for a reasonably sized image. Non-image data URLs poison
    /// providers that only support image file blocks; oversized images are
    /// rejected to keep replay payloads bounded.
    static func diagnose(dataURL: String) -> (mimeType: String?, byteCount: Int)? {
        guard dataURL.range(of: "data:", options: [.anchored, .caseInsensitive]) != nil,
              let comma = dataURL.firstIndex(of: ",") else { return nil }
        let metadata = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma])
        let components = metadata.split(separator: ";", omittingEmptySubsequences: false)
        let rawMIME = components.first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let mimeType = rawMIME.isEmpty ? nil : rawMIME
        let encoded = dataURL[dataURL.index(after: comma)...]
        let byteCount: Int
        if components.dropFirst().contains(where: { $0.caseInsensitiveCompare("base64") == .orderedSame }) {
            let count = encoded.unicodeScalars.reduce(into: 0) { result, scalar in
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) { result += 1 }
            }
            let padding = encoded.reversed()
                .lazy
                .filter { !$0.isWhitespace }
                .prefix(2)
                .prefix { $0 == "=" }
                .count
            byteCount = max(0, (count * 3) / 4 - padding)
        } else {
            let value = String(encoded)
            byteCount = (value.removingPercentEncoding ?? value).utf8.count
        }
        let isImage = mimeType?.hasPrefix("image/") == true
        guard !isImage || byteCount > maximumSafeDataURLBytes else { return nil }
        return (mimeType, byteCount)
    }

    static func backup(
        databaseURL: URL,
        destinationDirectory: URL? = nil,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> URL {
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw OpenCodeSessionDoctorError.backupFailed("The source database does not exist.")
        }
        guard let directory = destinationDirectory ?? backupDirectory(fileManager: fileManager) else {
            throw OpenCodeSessionDoctorError.backupFailed("The backup folder is unavailable.")
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw OpenCodeSessionDoctorError.backupFailed(error.localizedDescription)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let nonce = UUID().uuidString.prefix(8)
        let destination = directory.appendingPathComponent(
            "opencode-\(formatter.string(from: now))-\(nonce).db"
        )

        let source: OpaquePointer
        do {
            source = try SQLite3.open(url: databaseURL, readOnly: true)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw OpenCodeSessionDoctorError.backupFailed(error.localizedDescription)
        }
        let target: OpaquePointer
        do {
            target = try SQLite3.open(url: destination, readOnly: false, createIfMissing: true)
        } catch {
            sqlite3_close(source)
            try? fileManager.removeItem(at: destination)
            throw OpenCodeSessionDoctorError.backupFailed(error.localizedDescription)
        }
        defer {
            sqlite3_close(target)
            sqlite3_close(source)
        }

        guard let handle = sqlite3_backup_init(target, "main", source, "main") else {
            try? fileManager.removeItem(at: destination)
            throw OpenCodeSessionDoctorError.backupFailed("The backup could not be started.")
        }
        var stepResult = SQLITE_OK
        var busyAttempts = 0
        repeat {
            stepResult = sqlite3_backup_step(handle, 128)
            if stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED {
                busyAttempts += 1
                if busyAttempts <= 200 { sqlite3_sleep(25) }
            }
        } while stepResult == SQLITE_OK
            || ((stepResult == SQLITE_BUSY || stepResult == SQLITE_LOCKED) && busyAttempts <= 200)
        let finishResult = sqlite3_backup_finish(handle)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            try? fileManager.removeItem(at: destination)
            throw OpenCodeSessionDoctorError.backupFailed("The backup could not be completed.")
        }
        pruneBackups(in: directory, keeping: 10, fileManager: fileManager)
        return destination
    }

    /// Deletes unsafe user file parts. Tool parts retain any safe attachments;
    /// only diagnosed entries are removed from their JSON attachment array.
    static func stripAttachments(
        _ findings: [OpenCodePoisonedAttachment],
        databaseURL: URL
    ) throws -> Int {
        let unique = Dictionary(findings.map { ($0.partID, $0) }, uniquingKeysWith: { first, _ in first })
        guard !unique.isEmpty else { return 0 }
        let connection = try SQLite3.open(url: databaseURL, readOnly: false)
        defer { sqlite3_close(connection) }
        let updatesTimestamp = try SQLite3.table("part", hasColumn: "time_updated", connection: connection)

        return try SQLite3.transaction(connection) {
            var changed = 0
            for finding in unique.values.sorted(by: { $0.partID < $1.partID }) {
                if finding.isUserFilePart {
                    try SQLite3.execute(
                        connection,
                        sql: "DELETE FROM part WHERE id = ? AND session_id = ?",
                        parameters: [finding.partID, finding.sessionID]
                    )
                    changed += SQLite3.changeCount(connection)
                    continue
                }
                let rows = try SQLite3.query(
                    connection,
                    sql: "SELECT data FROM part WHERE id = ? AND session_id = ? LIMIT 1",
                    parameters: [finding.partID, finding.sessionID]
                )
                guard let serialized = rows.first?[safe: 0] as? String,
                      let repaired = repairedToolPart(serialized) else { continue }
                try SQLite3.execute(
                    connection,
                    sql: updatesTimestamp
                        ? "UPDATE part SET data = ?, time_updated = CAST(strftime('%s','now') AS INTEGER) * 1000 WHERE id = ? AND session_id = ?"
                        : "UPDATE part SET data = ? WHERE id = ? AND session_id = ?",
                    parameters: [repaired, finding.partID, finding.sessionID]
                )
                changed += SQLite3.changeCount(connection)
            }
            return changed
        }
    }

    /// Nuke option: deletes complete sessions. Every table containing a
    /// `session_id` column is cleared first for compatibility with old and new
    /// opencode schemas, then the session row is deleted in one transaction.
    static func deleteSessions(_ sessionIDs: [String], databaseURL: URL) throws -> Int {
        let unique = Array(Set(sessionIDs.filter { !$0.isEmpty })).sorted()
        guard !unique.isEmpty else { return 0 }
        let connection = try SQLite3.open(url: databaseURL, readOnly: false)
        defer { sqlite3_close(connection) }
        let placeholders = unique.map { _ in "?" }.joined(separator: ",")

        return try SQLite3.transaction(connection) {
            let tables = try SQLite3.query(
                connection,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
            ).compactMap { $0[safe: 0] as? String }
            for table in tables where table != "session" {
                guard try SQLite3.table(table, hasColumn: "session_id", connection: connection) else { continue }
                try SQLite3.execute(
                    connection,
                    sql: "DELETE FROM \(SQLite3.quotedIdentifier(table)) WHERE session_id IN (\(placeholders))",
                    parameters: unique
                )
            }
            try SQLite3.execute(
                connection,
                sql: "DELETE FROM session WHERE id IN (\(placeholders))",
                parameters: unique
            )
            return SQLite3.changeCount(connection)
        }
    }

    private static func attachmentCandidates(
        in part: [String: Any],
        isUserFilePart: Bool
    ) -> [(url: String, name: String?)] {
        var candidates: [(String, String?)] = []
        if isUserFilePart {
            if let url = dataURL(in: part) {
                candidates.append((url, attachmentName(in: part)))
            }
            if let source = part["source"] as? [String: Any], let url = dataURL(in: source) {
                candidates.append((url, attachmentName(in: part) ?? attachmentName(in: source)))
            }
        }
        if let state = part["state"] as? [String: Any],
           let attachments = state["attachments"] as? [[String: Any]] {
            candidates += attachments.compactMap { attachment in
                dataURL(in: attachment).map { ($0, attachmentName(in: attachment)) }
            }
        }
        return candidates
    }

    private static func dataURL(in value: [String: Any]) -> String? {
        for key in ["url", "dataURL", "dataUrl", "data"] {
            if let candidate = value[key] as? String,
               candidate.range(of: "data:", options: [.anchored, .caseInsensitive]) != nil {
                return candidate
            }
        }
        return nil
    }

    private static func attachmentName(in value: [String: Any]) -> String? {
        for key in ["name", "filename", "fileName"] {
            if let candidate = value[key] as? String, !candidate.isEmpty { return candidate }
        }
        return nil
    }

    private static func repairedToolPart(_ serialized: String) -> String? {
        guard var part = try? JSONSerialization.jsonObject(
            with: Data(serialized.utf8)
        ) as? [String: Any],
              var state = part["state"] as? [String: Any],
              let attachments = state["attachments"] as? [[String: Any]] else { return nil }
        let safe = attachments.filter { attachment in
            guard let url = dataURL(in: attachment) else { return true }
            return diagnose(dataURL: url) == nil
        }
        guard safe.count != attachments.count else { return nil }
        state["attachments"] = safe
        part["state"] = state
        guard let data = try? JSONSerialization.data(withJSONObject: part, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func pruneBackups(
        in directory: URL,
        keeping limit: Int,
        fileManager: FileManager
    ) {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let backups = contents
            .filter { $0.lastPathComponent.hasPrefix("opencode-") && $0.pathExtension == "db" }
            .compactMap { url -> (url: URL, date: Date)? in
                guard let date = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate else { return nil }
                return (url, date)
            }
            .sorted { left, right in
                left.date == right.date
                    ? left.url.lastPathComponent > right.url.lastPathComponent
                    : left.date > right.date
            }
        for stale in backups.dropFirst(max(0, limit)) {
            try? fileManager.removeItem(at: stale.url)
        }
    }
}

/// Minimal checked wrapper around the system SQLite C API.
enum SQLite3 {
    static func open(
        url: URL,
        readOnly: Bool,
        createIfMissing: Bool = false
    ) throws -> OpaquePointer {
        if !createIfMissing && !FileManager.default.fileExists(atPath: url.path) {
            throw OpenCodeSessionDoctorError.cannotOpenDatabase("The database does not exist.")
        }
        var handle: OpaquePointer?
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : SQLITE_OPEN_READWRITE | (createIfMissing ? SQLITE_OPEN_CREATE : 0)
        let result = sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error."
            sqlite3_close(handle)
            throw OpenCodeSessionDoctorError.cannotOpenDatabase(message)
        }
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 5_000)
        if !readOnly { _ = sqlite3_exec(handle, "PRAGMA foreign_keys = ON", nil, nil, nil) }
        return handle
    }

    static func execute(_ connection: OpaquePointer, sql: String, parameters: [Any] = []) throws {
        let statement = try prepare(connection, sql: sql, parameters: parameters)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw OpenCodeSessionDoctorError.updateFailed(String(cString: sqlite3_errmsg(connection)))
        }
    }

    static func query(_ connection: OpaquePointer, sql: String, parameters: [Any] = []) throws -> [[Any]] {
        var rows: [[Any]] = []
        try forEachRow(connection, sql: sql, parameters: parameters) { rows.append($0) }
        return rows
    }

    /// Iterates query results without retaining every row. This matters for
    /// opencode attachment parts, whose JSON can contain multi-megabyte data
    /// URLs even though the number of matching records is small.
    static func forEachRow(
        _ connection: OpaquePointer,
        sql: String,
        parameters: [Any] = [],
        body: ([Any]) throws -> Void
    ) throws {
        let statement = try prepare(connection, sql: sql, parameters: parameters)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw OpenCodeSessionDoctorError.updateFailed(String(cString: sqlite3_errmsg(connection)))
            }
            let columnCount = sqlite3_column_count(statement)
            var row: [Any] = []
            row.reserveCapacity(Int(columnCount))
            for index in 0..<columnCount {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, index) {
                        row.append(String(cString: text))
                    } else {
                        row.append(NSNull())
                    }
                case SQLITE_INTEGER:
                    row.append(Int(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT:
                    row.append(Double(sqlite3_column_double(statement, index)))
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(statement, index) {
                        row.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index))))
                    } else {
                        row.append(Data())
                    }
                default:
                    row.append(NSNull())
                }
            }
            try body(row)
        }
    }

    static func transaction<T>(_ connection: OpaquePointer, body: () throws -> T) throws -> T {
        try execute(connection, sql: "BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute(connection, sql: "COMMIT")
            return value
        } catch {
            try? execute(connection, sql: "ROLLBACK")
            throw error
        }
    }

    static func table(_ table: String, hasColumn column: String, connection: OpaquePointer) throws -> Bool {
        try query(connection, sql: "PRAGMA table_info(\(quotedIdentifier(table)))")
            .contains { ($0[safe: 1] as? String)?.caseInsensitiveCompare(column) == .orderedSame }
    }

    static func quotedIdentifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func changeCount(_ connection: OpaquePointer) -> Int {
        Int(sqlite3_changes(connection))
    }

    private static func prepare(
        _ connection: OpaquePointer,
        sql: String,
        parameters: [Any]
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw OpenCodeSessionDoctorError.updateFailed(String(cString: sqlite3_errmsg(connection)))
        }
        for (index, parameter) in parameters.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch parameter {
            case let value as String:
                result = sqlite3_bind_text(
                    statement, position, value, -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            case let value as Int:
                result = sqlite3_bind_int64(statement, position, Int64(value))
            case let value as Double:
                result = sqlite3_bind_double(statement, position, value)
            case let value as Data:
                result = value.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(
                        statement, position, buffer.baseAddress, Int32(buffer.count),
                        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                    )
                }
            case is NSNull:
                result = sqlite3_bind_null(statement, position)
            default:
                result = sqlite3_bind_text(
                    statement, position, String(describing: parameter), -1,
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
            guard result == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw OpenCodeSessionDoctorError.updateFailed(String(cString: sqlite3_errmsg(connection)))
            }
        }
        return statement
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
