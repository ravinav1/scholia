@preconcurrency import AppKit
import Foundation
@testable import ScholiaMac

// Match CanvasClient's actor isolation when measuring the previous implementation.
private actor ByteLoopBaseline {
    func download(_ url: URL, session: URLSession) async throws -> Data {
        let (bytes, _) = try await session.bytes(from: url)
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        return data
    }
}

// Only synthetic content and temporary library stores. Canvas networking is intercepted.
@main @MainActor
struct PerformanceAudit {
    static func emit(_ name: String, _ values: [String: Any]) {
        let record = values.merging(["name": name]) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) { FileHandle.standardOutput.write(data + Data([10])) }
    }
    static func measure(_ name: String, iterations: Int = 10, work: () throws -> Void) rethrows {
        try work()
        var times: [Double] = []
        for _ in 0..<iterations { let start = ContinuousClock.now; try work(); times.append(milliseconds(start)) }
        times.sort()
        emit(name, ["medianMs": times[times.count / 2], "p95Ms": times[min(times.count - 1, Int(ceil(Double(times.count) * 0.95)) - 1)]])
    }
    static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1_000 + Double(value.attoseconds) / 1e15
    }
    static func library(_ count: Int) -> StudyLibrary {
        var library = StudyLibrary(); library.showingCourseLibrary = true
        for i in 0..<count {
            let refs = (0..<32).map { j in CanvasMaterialReference(id: "pages:\(j)", kind: .pages, remoteID: String(j), title: "Lecture \(j)", sourceURL: "https://canvas.example.test/courses/\(i + 1)/pages/\(j)", version: "v1") }
            library.courses.append(StudyCourse(name: "Synthetic course \(i + 1)", code: "TEST\(i + 1)", canvasID: i + 1, canvasOrigin: "https://canvas.example.test", canvasUserID: 7, favorite: i < 4, canvasMaterials: refs, catalogUpdatedAt: Date(), term: "2026 HØST"))
        }
        return library
    }
    static func auditDownloads(session: URLSession, client: CanvasClient) async throws {
        for size in [1_000_000, 10_000_000, 50_000_000] {
            let url = URL(string: "https://canvas.example.test/blob/\(size)")!
            var start = ContinuousClock.now
            let data = try await client.download(url)
            emit("native.download.chunks", ["bytes": data.count, "elapsedMs": milliseconds(start)])
            start = .now
            let (bulk, _) = try await session.data(from: url)
            emit("native.download.bulkBaseline", ["bytes": bulk.count, "elapsedMs": milliseconds(start)])
            if CommandLine.arguments.contains("--compare-byte-loop") {
                start = .now
                let previous = try await ByteLoopBaseline().download(url, session: session)
                precondition(previous == data && bulk == data)
                emit("native.download.byteLoopBaseline", ["bytes": previous.count, "elapsedMs": milliseconds(start)])
            }
        }
    }
    static func auditHistoryWrites(root: URL) throws {
        let url = root.appendingPathComponent("chats.json")
        let values = (0..<20).map { number in
            StoredConversation(id: UUID(), title: "Synthetic chat \(number)", createdAt: Date(), updatedAt: Date(),
                capture: nil, messages: [ConversationMessage(role: .user, content: "Explain this figure",
                    imageData: Data(repeating: 65, count: 1_000_000), imageMimeType: "image/jpeg")])
        }
        try measure("native.history.synchronousSave", iterations: 5) {
            try ConversationStore.save(values, to: url)
        }
        let writer = ConversationHistoryWriter { try ConversationStore.save($0, to: url) }
        measure("native.history.queuedSave", iterations: 20) { writer.save(values) }
        let start = ContinuousClock.now
        try writer.flush()
        let flushMs = milliseconds(start)
        let restored = ConversationStore.load(from: url)
        precondition(Set(restored.map(\.id)) == Set(values.map(\.id)))
        precondition(restored.allSatisfy { $0.messages.first?.imageData?.count == 1_000_000 })
        emit("native.history.durability", ["flushMs": flushMs, "retainedChats": restored.count,
            "encodedBytes": try Data(contentsOf: url).count])
    }
    static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-audit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            if CommandLine.arguments.contains("--history-only") {
                try auditHistoryWrites(root: root)
                return
            }
            _ = NSApplication.shared
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AuditProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let client = CanvasClient(origin: URL(string: "https://canvas.example.test")!, token: "fixture", session: session)
            if CommandLine.arguments.contains("--downloads-only") {
                try await auditDownloads(session: session, client: client)
                return
            }
            for count in [6, 89, 300] {
                let store = StudyLibraryStore(root: root.appendingPathComponent("library-\(count)")), library = library(count)
                try measure("native.\(count)courses.save") { try store.save(library) }
                try measure("native.\(count)courses.load") { _ = try store.load() }
                let model = StudyWorkspaceModel(store: store)
                measure("native.\(count)courses.favorite") { model.toggleFavorite(library.courses[0].id) }
                measure("native.\(count)courses.semesters") { _ = model.semesterGroups }
                emit("native.\(count)courses.size", ["libraryBytes": try Data(contentsOf: store.root.appendingPathComponent("library.json")).count])
            }
            var imageLibrary = library(89)
            var imageThread = StudyThread(title: "Image-heavy synthetic history")
            for _ in 0..<20 { imageThread.messages.append(ConversationMessage(role: .user, content: "Explain this figure", imageData: Data(repeating: 65, count: 1_000_000), imageMimeType: "image/jpeg")) }
            imageLibrary.courses[0].threads = [imageThread]
            let imageStore = StudyLibraryStore(root: root.appendingPathComponent("images"))
            try measure("native.89courses.20imageMessages.save", iterations: 5) { try imageStore.save(imageLibrary) }
            emit("native.89courses.20imageMessages.size", ["libraryBytes": try Data(contentsOf: imageStore.root.appendingPathComponent("library.json")).count])
            let store = StudyLibraryStore(root: root.appendingPathComponent("context"))
            var course = StudyCourse(name: "Synthetic context")
            let text = String(repeating: "Eigenvectors preserve directions. Matrices transform vectors. Orthogonal basis and eigenvalue decomposition.\n\n", count: 500)
            for i in 0..<60 { course.documents.append(try StudyDocumentImporter.read(data: Data(text.utf8), name: "Lecture \(i).md", store: store)) }
            measure("native.context.60documents", iterations: 5) {
                _ = StudyContextBuilder.build(document: nil, index: nil, currentPage: 1, question: "How does eigenvalue decomposition work?", selection: "", course: course, store: store, includeCourse: true)
            }
            try await auditDownloads(session: session, client: client)
            let syncStore = StudyLibraryStore(root: root.appendingPathComponent("sync"))
            let model = StudyWorkspaceModel(store: syncStore)
            model.canvasAddress = "https://canvas.example.test"
            for label in ["cold", "warm"] {
                AuditProtocol.state.reset(); let start = ContinuousClock.now
                model.loadCanvasCourses(clientOverride: client)
                while model.canvasBusy { try await Task.sleep(for: .milliseconds(10)) }
                emit("native.sync.\(label)", ["courses": model.library.courses.count, "materials": model.library.courses.reduce(0) { $0 + $1.materials.count }, "requests": AuditProtocol.state.requests, "notModified": AuditProtocol.state.notModified, "elapsedMs": milliseconds(start), "warnings": model.canvasWarnings.count])
            }
            AuditProtocol.state.reset(); let cancelStart = ContinuousClock.now
            model.loadCanvasCourses(clientOverride: client)
            try await Task.sleep(for: .milliseconds(100)); model.cancelCanvas()
            while model.canvasBusy { try await Task.sleep(for: .milliseconds(5)) }
            emit("native.sync.cancel", ["elapsedMs": milliseconds(cancelStart), "retainedCourses": model.library.courses.count, "status": model.canvasStatus ?? ""])
            AuditProtocol.state.reset()
            let retryStart = ContinuousClock.now
            _ = try await client.download(URL(string: "https://canvas.example.test/throttle")!)
            emit("native.sync.429Retry", ["elapsedMs": milliseconds(retryStart), "requests": AuditProtocol.state.requests])
            AuditProtocol.state.reset()
            do { _ = try await client.download(URL(string: "https://canvas.example.test/unavailable")!) } catch {
                emit("native.sync.503", ["requests": AuditProtocol.state.requests, "error": error.localizedDescription])
            }
            if CommandLine.arguments.contains("--browser") {
                let webStore = StudyLibraryStore(root: root.appendingPathComponent("web"))
                try webStore.save(library(89))
                let webModel = StudyWorkspaceModel(store: webStore)
                let server = StudyWebServer(app: AppModel.shared, workspace: webModel, assets: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/web"))
                server.start(port: 0)
                for _ in 0..<100 where server.address == nil { try await Task.sleep(for: .milliseconds(20)) }
                guard let address = server.address else { throw StudyError.message(webModel.error ?? "Server did not start") }
                defer { server.stop() }
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["node", "scripts/performance/audit-performance-browser.mjs", address.absoluteString]
                let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
                    do { try process.run() } catch { continuation.resume(throwing: error) }
                }
                if status != 0 { throw StudyError.message("Browser audit failed: \(status)") }
            }
        } catch { emit("audit.error", ["error": String(describing: error)]); exit(1) }
    }
}

final class AuditProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0, conditional = 0, throttle = 0
    var requests: Int { lock.withLock { count } }
    var notModified: Int { lock.withLock { conditional } }
    func reset() { lock.withLock { count = 0; conditional = 0; throttle = 0 } }
    func record(_ request: URLRequest) -> Int {
        lock.withLock {
            count += 1
            if request.value(forHTTPHeaderField: "If-None-Match") != nil { conditional += 1 }
            if request.url?.path == "/throttle" { throttle += 1 }
            return throttle
        }
    }
}
final class AuditProtocol: URLProtocol, @unchecked Sendable {
    static let state = AuditProtocolState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, throttle = Self.state.record(request)
        var status = 200, headers = ["Content-Type": "application/json", "ETag": "\"v1\""]
        var data = Data()
        if url.path.hasPrefix("/blob/") { data = Data(repeating: 65, count: Int(url.lastPathComponent)!); headers["Content-Type"] = "application/octet-stream" }
        else if url.path == "/throttle" { if throttle == 1 { status = 429; headers["Retry-After"] = "1" } else { data = Data("ok".utf8) } }
        else if url.path == "/unavailable" { status = 503 }
        else {
            Thread.sleep(forTimeInterval: 0.02)
            if request.value(forHTTPHeaderField: "If-None-Match") != nil { status = 304 }
            else {
                let value: Any
                if url.path == "/api/v1/users/self/profile" { value = ["id": 7, "name": "Fixture"] }
                else if url.path == "/api/v1/courses" { value = (1...89).map { ["id": $0, "name": "Course \($0)", "course_code": "TEST\($0)"] as [String: Any] } }
                else if url.path.hasSuffix("/pages") { value = (1...32).map { ["url": "lecture\($0)", "title": "Lecture \($0)", "updated_at": "v1"] } }
                else if ["files", "assignments", "modules"].contains(url.lastPathComponent) { value = [Int]() }
                else { value = ["syllabus_body": ""] }
                data = try! JSONSerialization.data(withJSONObject: value)
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.path.hasPrefix("/blob/") {
            for offset in stride(from: 0, to: data.count, by: 65_536) {
                client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + 65_536, data.count)))
            }
        } else {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
