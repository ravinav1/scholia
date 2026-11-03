import Foundation

struct StudySemanticProgress: Codable, Sendable {
    var state: String
    var indexedFiles: Int
    var totalFiles: Int
    var indexedChunks: Int
    var totalChunks: Int
    var model: String
    var progress: Double
    var message: String?
    var preparing: Bool { !["ready", "error"].contains(state) }
    var description: String {
        switch state {
        case "loading_model": "Preparing the local search model… \(Int(progress))%"
        case "loading_index": "Opening semantic search…"
        case "indexing": "Preparing semantic search… \(indexedFiles) of \(totalFiles) files ready"
        case "error": message ?? "Semantic search could not be prepared."
        default: "\(indexedFiles) files ready for semantic search"
        }
    }
}

private struct StudySemanticFile: Encodable, Sendable {
    var file: StudySearchFile
    var indexPath: String?
    private enum CodingKeys: String, CodingKey { case indexPath }
    func encode(to encoder: Encoder) throws {
        try file.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(indexPath, forKey: .indexPath)
    }
}

/// A private pipe to one warm local inference worker. The literal search actor
/// remains available while the worker downloads assets or prepares embeddings.
actor StudySemanticSearch {
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var buffer = Data()
    private var sequence = 0
    private var generation = 0
    private var pending: [Int: CheckedContinuation<StudySearchResponse, any Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]

    private struct Request: Encodable {
        var id: Int
        var path: String
        var files: [StudySemanticFile]
        var query: String
        var options: Options
        struct Options: Encodable { var courseID: String }
    }
    private struct Reply: Decodable {
        var id: Int
        var result: StudySearchResponse?
        var error: String?
    }

    func search(courses: [StudyCourse], store: StudyLibraryStore, query: String, courseID: String) async throws -> StudySearchResponse {
        try Task.checkCancellation()
        var files: [StudySemanticFile] = []
        for course in courses {
            let id = course.id.uuidString
            let name = course.code.isEmpty ? course.name : "\(course.code) · \(course.name)"
            for document in course.documents {
                let original = store.directory(for: document.id).appendingPathComponent("index.json")
                let enriched = store.enrichedIndexURL(for: document)
                let index = enriched.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? original
                files.append(StudySemanticFile(file: StudySearchFile(id: document.id.uuidString,
                    courseID: id, courseName: name, documentID: document.id.uuidString,
                    title: document.title, fileName: document.originalFileName ?? document.fileName,
                    kind: document.kind.rawValue), indexPath: index.path))
            }
            for material in course.remoteOnlyMaterials {
                files.append(StudySemanticFile(file: StudySearchFile(id: "\(id):\(material.id)",
                    courseID: id, courseName: name, materialID: material.id, title: material.title,
                    fileName: material.fileName ?? "", kind: material.kind.rawValue)))
            }
        }
        try start()
        sequence += 1
        let id = sequence
        let request = Request(id: id, path: store.root.appendingPathComponent("semantic-v1.sqlite").path,
            files: files, query: query, options: .init(courseID: courseID))
        var data = try JSONEncoder().encode(request); data.append(10)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    await self?.timedOut(id)
                }
                do { try input?.write(contentsOf: data) }
                catch {
                    timeouts.removeValue(forKey: id)?.cancel()
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: Int) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
        try? input?.write(contentsOf: Data("{\"cancel\":\(id)}\n".utf8))
    }
    private func timedOut(_ id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        timeouts.removeValue(forKey: id)
        continuation.resume(throwing: StudyError.message("Semantic search took too long. Try searching again."))
        process?.terminate()
    }
    private func start() throws {
        if process?.isRunning == true { return }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("SemanticSearch/scripts/semantic-search-bridge.mjs"))
        }
        candidates.append(source.appendingPathComponent("scripts/semantic-search-bridge.mjs"))
        guard let script = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw StudyError.message("The local search runtime is missing. Update Scholia and try again.")
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let nodes = ["/opt/homebrew/bin/node", "/usr/local/bin/node"] + path.split(separator: ":").map { "\($0)/node" }
        guard let node = nodes.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw StudyError.message("Semantic search needs Node.js 24 or newer. Install it, then reopen search.")
        }
        generation += 1
        let ticket = generation
        let child = Process(), incoming = Pipe(), outgoing = Pipe()
        child.executableURL = URL(fileURLWithPath: node)
        child.arguments = ["--no-warnings", script.path]
        child.standardInput = incoming; child.standardOutput = outgoing; child.standardError = FileHandle.nullDevice
        let stream = AsyncStream<Data> { continuation in
            outgoing.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; continuation.finish() }
                else { continuation.yield(data) }
            }
        }
        child.terminationHandler = { child in
            Task { await self.stopped(ticket, status: child.terminationStatus) }
        }
        try child.run()
        process = child; input = incoming.fileHandleForWriting; buffer = Data()
        reader = Task { [weak self] in
            for await data in stream { await self?.receive(data, ticket: ticket) }
        }
    }
    private func receive(_ data: Data, ticket: Int) {
        guard ticket == generation else { return }
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard let reply = try? JSONDecoder().decode(Reply.self, from: line),
                  let continuation = pending.removeValue(forKey: reply.id) else { continue }
            timeouts.removeValue(forKey: reply.id)?.cancel()
            if let result = reply.result { continuation.resume(returning: result) }
            else { continuation.resume(throwing: StudyError.message(reply.error ?? "Semantic search failed.")) }
        }
    }
    private func stopped(_ ticket: Int, status: Int32) {
        guard ticket == generation else { return }
        for continuation in pending.values {
            continuation.resume(throwing: StudyError.message("The local search worker stopped (\(status)). Try searching again."))
        }
        pending.removeAll(); input = nil; process = nil; reader?.cancel(); reader = nil
        for timeout in timeouts.values { timeout.cancel() }
        timeouts.removeAll()
    }
}
