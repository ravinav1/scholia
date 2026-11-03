import Foundation
import SQLite3
import ScholiaSearch

struct StudySearchFile: Codable, Sendable {
    var id: String
    var courseID: String
    var courseName: String
    var documentID: String?
    var materialID: String?
    var title: String
    var fileName: String
    var kind: String
}

struct StudySearchHit: Codable, Identifiable, Sendable {
    var id: String
    var courseID: String
    var courseName: String
    var documentID: String?
    var materialID: String?
    var title: String
    var fileName: String
    var kind: String
    var page: Int
    var passages: Int
    var snippet: String
    var approximate: Bool? = nil
    var semantic: Bool? = nil
    var score: Double? = nil
}

struct StudySearchResponse: Codable, Sendable {
    var results: [StudySearchHit]
    var total: Int
    var terms: [String]
    var coverage: [String: Int]
    var strategy: String
    var queryMs: Double
    var totalMs: Double = 0
    var updatedFiles: Int = 0
    var candidateUpperBound: Int = 0
    var semantic: StudySemanticProgress? = nil
}

/// SQLite work and text extraction reads stay off the UI actor. This disposable
/// index uses the same literal query contract as the hosted Needle engine.
actor StudyWorkspaceSearch {
    private let semanticSearch = StudySemanticSearch()
    private var names: [String: (raw: String, text: String, words: [[UInt32]])] = [:]
    private static let nameWordBoundary = try! NSRegularExpression(pattern: "([a-z])([A-Z])")
    private var connection: StudySearchDatabase?
    private var connectionPath: String?
    private var revisions: [String: String] = [:]
    private var frequencies: [String: Int] = [:]
    private var cachedCoverage: [String: [String: Int]] = [:]
    private var cachedCounts: [String: Int] = [:]
    private func invalidate() {
        revisions = [:]; frequencies = [:]; cachedCoverage = [:]; cachedCounts = [:]
    }
    private func searchNames(courses: [StudyCourse], terms: [String], courseID: String, start: Date) throws -> StudySearchResponse {
        var hits: [StudySearchHit] = []
        var active = Set<String>()
        var count = 0, remote = 0
        // Convert each query/word once. Allocating Character arrays for every
        // near-match dominated filename searches across a large catalog.
        let queries = terms.map { term -> (text: String, fuzzy: [UInt32]?) in
            (term, term.count >= 5 && term.allSatisfy({ $0.isLetter || $0.isNumber })
                ? term.unicodeScalars.map(\.value) : nil)
        }
        for course in courses {
            let id = course.id.uuidString
            let courseName = course.code.isEmpty ? course.name : "\(course.code) · \(course.name)"
            let saved = Set(course.documents.compactMap(\.sourceKey))
            let files = course.documents.map {
                StudySearchFile(id: $0.id.uuidString, courseID: id, courseName: courseName,
                    documentID: $0.id.uuidString, title: $0.title,
                    fileName: $0.originalFileName ?? $0.fileName, kind: $0.kind.rawValue)
            } + course.materials.filter { !saved.contains($0.id) }.map {
                StudySearchFile(id: "\(id):\($0.id)", courseID: id, courseName: courseName,
                    materialID: $0.id, title: $0.title, fileName: $0.fileName ?? "", kind: $0.kind.rawValue)
            }
            for file in files {
                try Task.checkCancellation()
                active.insert(file.id)
                if !courseID.isEmpty && courseID != id { continue }
                count += 1
                if file.documentID == nil { remote += 1 }
                let raw = "\(file.title)\n\(file.fileName)\n\(courseName)"
                if names[file.id]?.raw != raw {
                    let separated = Self.nameWordBoundary.stringByReplacingMatches(in: raw,
                        range: NSRange(raw.startIndex..., in: raw), withTemplate: "$1 $2")
                    let words = Self.normalize(separated).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                        .map { $0.unicodeScalars.map(\.value) }
                    names[file.id] = (raw, Self.normalize(raw), words)
                }
                guard !terms.isEmpty, let name = names[file.id] else { continue }
                var approximate = false
                guard queries.allSatisfy({ query in
                    if name.text.contains(query.text) { return true }
                    if let fuzzy = query.fuzzy, name.words.contains(where: { Self.oneEditPrefix(fuzzy, $0) }) {
                        approximate = true
                        return true
                    }
                    return false
                }) else { continue }
                hits.append(StudySearchHit(id: file.id, courseID: id, courseName: courseName,
                    documentID: file.documentID, materialID: file.materialID, title: file.title,
                    fileName: file.fileName, kind: file.kind, page: 0, passages: 1,
                    snippet: String(name.text.prefix(260)), approximate: approximate))
            }
        }
        for id in names.keys where !active.contains(id) { names.removeValue(forKey: id) }
        hits.sort {
            if $0.approximate != $1.approximate { return $0.approximate != true }
            return $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        let elapsed = Date().timeIntervalSince(start) * 1000
        return StudySearchResponse(results: Array(hits.prefix(60)), total: hits.count, terms: terms,
            coverage: ["files": count, "remoteFiles": remote, "contentFiles": 0, "unavailableFiles": 0],
            strategy: "names", queryMs: elapsed, totalMs: elapsed, candidateUpperBound: count)
    }
    private static func oneEditPrefix(_ a: [UInt32], _ word: [UInt32]) -> Bool {
        for size in [a.count - 1, a.count, a.count + 1] where word.count >= size {
            var i = 0, j = 0, edits = 0
            while i < a.count && j < size {
                if a[i] == word[j] { i += 1; j += 1; continue }
                edits += 1
                if edits > 1 { break }
                if a.count >= size { i += 1 }
                if size >= a.count { j += 1 }
            }
            if edits + a.count - i + size - j <= 1 { return true }
        }
        return false
    }
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "\0", with: " ")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func terms(_ query: String) throws -> [String] {
        guard query.utf16.count <= 512, !query.contains("\0") else {
            throw StudyError.message("Use a search of at most 512 characters.")
        }
        let regex = try NSRegularExpression(pattern: #""([^"]*)"|"([^"]*)$|([^\s"]+)"#)
        let source = query as NSString
        var result: [String] = []
        for match in regex.matches(in: query, range: NSRange(location: 0, length: source.length)) {
            for group in 1...3 where match.range(at: group).location != NSNotFound {
                let term = normalize(source.substring(with: match.range(at: group)))
                if !term.isEmpty && !result.contains(term) { result.append(term) }
                break
            }
        }
        guard result.count <= 32 else { throw StudyError.message("Use at most 32 search terms.") }
        return result
    }

    func search(courses: [StudyCourse], store: StudyLibraryStore, query: String,
                courseID: String = "", mode: String = "all", scan: Bool = false, accelerated: Bool = true) async throws -> StudySearchResponse {
        let start = Date()
        guard ["all", "files", "content", "semantic"].contains(mode) else { throw StudyError.message("Unknown search mode.") }
        guard courseID.isEmpty || courses.contains(where: { $0.id.uuidString == courseID }) else {
            throw StudyError.message("Workspace not found.")
        }
        if mode == "semantic" {
            guard query.utf16.count <= 512, !query.contains("\0") else {
                throw StudyError.message("Use a search of at most 512 characters.")
            }
            return try await semanticSearch.search(courses: courses, store: store, query: query, courseID: courseID)
        }
        let terms = try Self.terms(query)
        if mode == "files" { return try searchNames(courses: courses, terms: terms, courseID: courseID, start: start) }
        let path = store.root.appendingPathComponent("needle-v1.sqlite")
        if connectionPath != path.path || connection == nil {
            try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
            connection = try StudySearchDatabase(path: path.path); connectionPath = path.path
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            invalidate()
        }
        let db = connection!
        if try db.externallyChanged() { invalidate() }
        if revisions.isEmpty {
            revisions = Dictionary(uniqueKeysWithValues: try db.rows("SELECT id,revision FROM files").map { ($0["id"]!, $0["revision"]!) })
        }
        let previousRevisions = revisions
        let active = Set(courses.flatMap { course in
            course.documents.map { $0.id.uuidString } + course.remoteOnlyMaterials.map { "\(course.id.uuidString):\($0.id)" }
        })
        var updated = 0
        var transactionOpen = false
        defer { if transactionOpen { try? db.execute("ROLLBACK"); invalidate() } }
        let removed = previousRevisions.keys.filter { !active.contains($0) }
        if !removed.isEmpty {
            invalidate()
            try db.execute("BEGIN IMMEDIATE"); transactionOpen = true
            for id in removed {
                try Task.checkCancellation()
                try db.execute("DELETE FROM files WHERE id=?", [id])
            }
            try db.execute("COMMIT"); transactionOpen = false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for course in courses where courseID.isEmpty || course.id.uuidString == courseID {
            let name = course.code.isEmpty ? course.name : "\(course.code) · \(course.name)"
            var entries: [(StudySearchFile, URL?, String)] = course.documents.map { document in
                let original = store.directory(for: document.id).appendingPathComponent("index.json")
                let enriched = store.enrichedIndexURL(for: document)
                let indexURL = enriched.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? original
                return (StudySearchFile(id: document.id.uuidString, courseID: course.id.uuidString, courseName: name,
                    documentID: document.id.uuidString, title: document.title,
                    fileName: document.originalFileName ?? document.fileName, kind: document.kind.rawValue),
                    indexURL, document.contentHash ?? "")
            }
            entries += course.remoteOnlyMaterials.map { material in
                (StudySearchFile(id: "\(course.id.uuidString):\(material.id)", courseID: course.id.uuidString,
                    courseName: name, materialID: material.id, title: material.title,
                    fileName: material.fileName ?? "", kind: material.kind.rawValue), nil, material.version)
            }
            for (file, url, version) in entries {
                try Task.checkCancellation()
                let data = String(decoding: try encoder.encode(file), as: UTF8.self)
                let attributes = url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
                let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let stamp = "\(modified):\(attributes?[.size] ?? 0):\(attributes?[.systemFileNumber] ?? 0)"
                let revision = "names-v2|\(data)|\(url?.path ?? "")|\(version)|\(stamp)"
                if previousRevisions[file.id] == revision { continue }
                let index = url.flatMap { try? Data(contentsOf: $0) }
                    .flatMap { try? JSONDecoder().decode(StudyDocumentIndex.self, from: $0) }
                let pages = file.kind == "preview" ? [] : index?.pages ?? []
                let coverage = url == nil ? "remote" : pages.contains { !Self.normalize($0.text).isEmpty } ? "ready" : "unavailable"
                if updated == 0 { invalidate() }
                if !transactionOpen { try db.execute("BEGIN IMMEDIATE"); transactionOpen = true }
                do {
                    try db.execute("DELETE FROM files WHERE id=?", [file.id])
                    try db.execute("INSERT INTO files VALUES(?,?,?,?,?)", [file.id, file.courseID, revision, data, coverage])
                    try db.execute("INSERT INTO passages(file,page,text) VALUES(?,0,?)", [file.id, Self.normalize("\(file.title)\n\(file.fileName)\n\(file.courseName)")])
                    for page in pages {
                        try Task.checkCancellation()
                        let text = Self.normalize(page.text)
                        if !text.isEmpty {
                            try db.execute("INSERT INTO passages(file,page,text) VALUES(?,?,?)", [file.id, String(page.number), text])
                        }
                    }
                    updated += 1
                    if updated % 64 == 0 { try db.execute("COMMIT"); transactionOpen = false }
                } catch { invalidate(); throw error }
            }
        }
        if transactionOpen { try db.execute("COMMIT"); transactionOpen = false }
        try Task.checkCancellation()
        let queryStart = Date()
        if cachedCoverage.count >= 128 && cachedCoverage[courseID] == nil {
            cachedCoverage.removeAll(keepingCapacity: true); cachedCounts.removeAll(keepingCapacity: true)
        }
        if cachedCoverage[courseID] == nil {
          let coverageRow = try db.rows("""
            SELECT count(*) AS files, coalesce(sum(coverage='ready'),0) AS contentFiles,
            coalesce(sum(coverage='remote'),0) AS remoteFiles,
            coalesce(sum(coverage='unavailable'),0) AS unavailableFiles FROM files
            \(courseID.isEmpty ? "" : "WHERE course=?")
            """, courseID.isEmpty ? [] : [courseID]).first ?? [:]
          cachedCoverage[courseID] = coverageRow.mapValues { Int($0) ?? 0 }
        }
        var grams: [String] = [], seen = Set<String>()
        for term in terms {
            let chars = Array(term.unicodeScalars)
            if chars.count >= 3 {
                for offset in 0...(chars.count - 3) {
                    let gram = String(String.UnicodeScalarView(chars[offset..<(offset + 3)]))
                    if seen.insert(gram).inserted { grams.append(gram) }
                }
            }
        }
        var anchors: [(gram: String, rows: Int)] = []
        if !scan && !grams.isEmpty {
            let sampleCount = min(24, grams.count)
            for position in 0..<sampleCount {
                let gram = grams[position * grams.count / sampleCount]
                if frequencies[gram] == nil {
                    let frequency = try db.rows("SELECT doc FROM fragment_counts WHERE term=?", [gram]).first
                    if frequencies.count >= 512 { frequencies.removeAll(keepingCapacity: true) }
                    frequencies[gram] = Int(frequency?["doc"] ?? "0") ?? 0
                }
                anchors.append((gram, frequencies[gram]!))
                if frequencies[gram] == 0 { break }
            }
            anchors.sort { $0.rows < $1.rows }
            anchors = Array(anchors.prefix(3))
        }
        if cachedCounts[courseID] == nil {
          cachedCounts[courseID] = Int(try db.rows(courseID.isEmpty ? "SELECT count(*) AS n FROM passages" :
            "SELECT count(*) AS n FROM passages p JOIN files f ON f.id=p.file WHERE f.course=?",
            courseID.isEmpty ? [] : [courseID]).first?["n"] ?? "0") ?? 0
        }
        let scopedRows = cachedCounts[courseID]!
        let missing = anchors.first?.rows == 0
        let useIndex = anchors.first.map { $0.rows < scopedRows / 2 } ?? false
        var conditions: [String] = [], params: [String] = []
        if useIndex && !missing {
            conditions.append("p.id IN (SELECT rowid FROM fragments WHERE fragments MATCH ?)")
            params.append(anchors.map { "\"\($0.gram.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " AND "))
        }
        if !courseID.isEmpty { conditions.append("f.course=?"); params.append(courseID) }
        if mode == "files" { conditions.append("p.page=0") }
        if mode == "content" { conditions.append("p.page>0") }
        for term in terms.sorted(by: { $0.utf8.count > $1.utf8.count }) {
            conditions.append(accelerated ? "needle_contains(p.text,?)" : "instr(p.text,?)>0"); params.append(term)
        }
        let hits = terms.isEmpty || missing ? [] : try db.rows("""
            SELECT p.file, min(p.page) AS page, count(*) AS passages
            FROM passages p JOIN files f ON f.id=p.file
            WHERE \(conditions.joined(separator: " AND ")) GROUP BY p.file
            ORDER BY (min(p.page)=0) DESC, p.file
            """, params)
        var results: [StudySearchHit] = []
        for hit in hits.prefix(60) {
            guard let row = try db.rows("""
                SELECT f.data,p.text FROM files f JOIN passages p ON p.file=f.id
                WHERE f.id=? AND p.page=? LIMIT 1
                """, [hit["file"]!, hit["page"]!]).first else { continue }
            let file = try JSONDecoder().decode(StudySearchFile.self, from: Data(row["data"]!.utf8))
            let text = row["text"]!
            let first = terms.compactMap { text.range(of: $0, options: .literal)?.lowerBound }.min() ?? text.startIndex
            let offset = text.index(first, offsetBy: -70, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(offset, offsetBy: 260, limitedBy: text.endIndex) ?? text.endIndex
            let snippet = "\(offset > text.startIndex ? "…" : "")\(text[offset..<end])\(end < text.endIndex ? "…" : "")"
            results.append(StudySearchHit(id: file.id, courseID: file.courseID, courseName: file.courseName,
                documentID: file.documentID, materialID: file.materialID, title: file.title, fileName: file.fileName,
                kind: file.kind, page: Int(hit["page"]!)!, passages: Int(hit["passages"]!)!, snippet: snippet))
        }
        return StudySearchResponse(results: results, total: hits.count, terms: terms,
            coverage: cachedCoverage[courseID] ?? [:], strategy: missing ? "absent" : useIndex ? "trigram" : accelerated ? "native-scan" : "scan",
            queryMs: Date().timeIntervalSince(queryStart) * 1000, totalMs: Date().timeIntervalSince(start) * 1000,
            updatedFiles: updated, candidateUpperBound: missing ? 0 : useIndex ? min(scopedRows, anchors[0].rows) : scopedRows)
    }
}

/// Connection and prepared statements stay confined to the search actor.
private final class StudySearchDatabase {
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var dataVersion = ""
    init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open search index."
            sqlite3_close(db); db = nil
            throw StudyError.message(message)
        }
        do {
            try execute("""
                PRAGMA foreign_keys=ON;
                PRAGMA busy_timeout=5000;
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=NORMAL;
                PRAGMA cache_size=-4096;
                PRAGMA mmap_size=268435456;
                CREATE TABLE IF NOT EXISTS files (id TEXT PRIMARY KEY, course TEXT NOT NULL,
                    revision TEXT NOT NULL, data TEXT NOT NULL, coverage TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS files_course ON files(course);
                CREATE TABLE IF NOT EXISTS passages (id INTEGER PRIMARY KEY,
                    file TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE, page INTEGER NOT NULL, text TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS passages_file ON passages(file,page);
                CREATE VIRTUAL TABLE IF NOT EXISTS fragments USING fts5(
                    text, content='passages', content_rowid='id', tokenize='trigram case_sensitive 1', detail=none);
                CREATE VIRTUAL TABLE IF NOT EXISTS fragment_counts USING fts5vocab(fragments,'row');
                CREATE TRIGGER IF NOT EXISTS passages_add AFTER INSERT ON passages BEGIN
                    INSERT INTO fragments(rowid,text) VALUES(new.id,new.text); END;
                CREATE TRIGGER IF NOT EXISTS passages_remove AFTER DELETE ON passages BEGIN
                    INSERT INTO fragments(fragments,rowid,text) VALUES('delete',old.id,old.text); END;
                """)
            try check(scholia_register_search(db))
            _ = try externallyChanged()
        } catch {
            for statement in statements.values { sqlite3_finalize(statement) }; statements = [:]
            sqlite3_close(db); db = nil; throw error
        }
    }
    deinit { for statement in statements.values { sqlite3_finalize(statement) }; sqlite3_close(db) }
    func externallyChanged() throws -> Bool {
        let current = try rows("PRAGMA data_version").first?["data_version"] ?? ""
        let changed = dataVersion != current; dataVersion = current; return changed
    }
    private func check(_ code: Int32) throws {
        if code != SQLITE_OK && code != SQLITE_DONE {
            throw StudyError.message(String(cString: sqlite3_errmsg(db)))
        }
    }
    func execute(_ sql: String, _ params: [String] = []) throws {
        if params.isEmpty { try check(sqlite3_exec(db, sql, nil, nil, nil)); return }
        _ = try rows(sql, params)
    }
    func rows(_ sql: String, _ params: [String] = []) throws -> [[String: String]] {
        var statement: OpaquePointer? = statements[sql]
        if statement == nil {
            try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil))
            if statements.count >= 128, let key = statements.keys.first {
                sqlite3_finalize(statements.removeValue(forKey: key))
            }
            statements[sql] = statement
        }
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        for (index, value) in params.enumerated() {
            try check(sqlite3_bind_text(statement, Int32(index + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
        }
        var result: [[String: String]] = []
        while true {
            let code = sqlite3_step(statement)
            if code != SQLITE_ROW { try check(code); return result }
            var row: [String: String] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                if let value = sqlite3_column_text(statement, column) {
                    row[String(cString: sqlite3_column_name(statement, column))] = String(cString: value)
                }
            }
            result.append(row)
        }
    }
}
