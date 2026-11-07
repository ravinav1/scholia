import Foundation
@testable import ScholiaMac

extension StudyWorkspaceSmoke {
    static func checkDataTransfer() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        func receive(_ path: String, limit: Int) async throws -> (Data, HTTPURLResponse) {
            let request = URLRequest(url: URL(string: "https://canvas.example.test/transfer/\(path)")!)
            return try await CanvasDataTransfer(limit: limit, downloads: true).receive(request, session: session)
        }
        let expected = Data((0..<196_608).map { UInt8($0 % 251) })
        for path in ["declared", "streamed"] {
            let (data, response) = try await receive(path, limit: expected.count)
            precondition(response.statusCode == 200 && data == expected, "Chunk boundaries must not alter file bytes")
        }
        for path in ["declared", "streamed"] {
            do {
                _ = try await receive(path, limit: expected.count - 1)
                preconditionFailure("Reject files above the limit, whether or not Content-Length is present")
            } catch {
                precondition(error.localizedDescription.contains("size limit"), "Oversized responses must report a size error")
            }
        }
        let (body, forbidden) = try await receive("forbidden", limit: 1)
        precondition(forbidden.statusCode == 403 && body.isEmpty, "HTTP errors must remain available without buffering an error body")

        let waitingURL = URL(string: "https://canvas.example.test/transfer/wait-\(UUID())")!
        let waiting = Task {
            try await CanvasDataTransfer(limit: 1_000_000, downloads: true)
                .receive(URLRequest(url: waitingURL), session: session)
        }
        for _ in 0..<100 where !TransferFixtureProtocol.state.started(waitingURL) {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(TransferFixtureProtocol.state.started(waitingURL), "The cancellation fixture must begin receiving")
        let cancellationStart = ContinuousClock.now
        waiting.cancel()
        do {
            _ = try await waiting.value
            preconditionFailure("Cancelling a download must not return partial bytes")
        } catch is CancellationError {
            // The transfer normalizes Task cancellation before the session callback arrives.
        }
        precondition(cancellationStart.duration(to: .now) < .seconds(1), "Cancellation must not wait for the server to finish")
        for _ in 0..<100 where !TransferFixtureProtocol.state.stopped(waitingURL) {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(TransferFixtureProtocol.state.stopped(waitingURL), "Task cancellation must also stop the underlying network request")

        let alreadyCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await receive("declared", limit: expected.count)
        }
        do {
            _ = try await alreadyCancelled.value
            preconditionFailure("Cancellation before receive must not start a successful download")
        } catch is CancellationError {}
        print("PASS: chunked downloads preserve bytes, enforce declared and streamed limits, retain HTTP status, and cancel the network task")
        try await checkDocumentStaging()
        try await checkCanvasSessionsAndAttachments()
    }

    private static func checkDocumentStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-staging-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = StudyLibraryStore(root: root)
        func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
        let originalData = Data("Original course notes".utf8)
        let replacementData = Data("Updated course notes".utf8)
        let original = try StudyDocumentImporter.read(data: originalData, name: "Lecture.md", store: destination)
        let staging = StudyDocumentStaging(destination: destination)
        defer { staging.discard() }
        let replacement = try StudyDocumentImporter.read(data: replacementData, name: "Lecture.md", store: staging.store, id: original.id)
        var savedBytes = try bytes(destination.file(for: original))
        precondition(savedBytes == originalData, "Indexing a replacement must leave the saved document untouched")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try staging.commit(replacement, to: destination)
        }
        do {
            try await cancelled.value
            preconditionFailure("A cancelled import must not commit its replacement")
        } catch is CancellationError {}
        savedBytes = try bytes(destination.file(for: original))
        precondition(savedBytes == originalData)

        let missing = StudyDocumentStaging(destination: destination)
        defer { missing.discard() }
        do {
            try missing.commit(replacement, to: destination)
            preconditionFailure("A missing staged file must fail")
        } catch {}
        savedBytes = try bytes(destination.file(for: original))
        precondition(savedBytes == originalData, "A failed commit must restore the original directory")

        for failure in ["missing original", "missing index", "malformed index", "truncated original"] {
            let partial = StudyDocumentStaging(destination: destination)
            defer { partial.discard() }
            let candidate = try StudyDocumentImporter.read(
                data: replacementData, name: "Lecture.md", store: partial.store, id: original.id)
            let indexURL = partial.store.directory(for: candidate.id).appendingPathComponent("index.json")
            switch failure {
            case "missing original":
                try FileManager.default.removeItem(at: partial.store.file(for: candidate))
            case "missing index":
                try FileManager.default.removeItem(at: indexURL)
            case "malformed index":
                try Data("{unfinished".utf8).write(to: indexURL)
            default:
                try Data(replacementData.prefix(5)).write(to: partial.store.file(for: candidate))
            }
            do {
                try partial.commit(candidate, to: destination)
                preconditionFailure("A staged document with \(failure) must never replace saved material")
            } catch {}
            savedBytes = try bytes(destination.file(for: original))
            let originalIndex = try destination.index(for: original)
            precondition(savedBytes == originalData, "Rejecting \(failure) must retain original bytes")
            precondition(originalIndex.pages.first?.text == "Original course notes", "Rejecting \(failure) must retain the original index")
        }

        let cancelledNew = StudyDocumentStaging(destination: destination)
        defer { cancelledNew.discard() }
        let newDocument = try StudyDocumentImporter.read(
            data: replacementData, name: "New lecture.md", store: cancelledNew.store)
        let cancelledNewTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try cancelledNew.commit(newDocument, to: destination)
        }
        do {
            try await cancelledNewTask.value
            preconditionFailure("Cancelling a new import must not publish its files")
        } catch is CancellationError {}
        precondition(!FileManager.default.fileExists(atPath: destination.directory(for: newDocument.id).path),
                     "A cancelled new document must leave no partial original or index in the library")
        try FileManager.default.removeItem(at: cancelledNew.store.directory(for: newDocument.id).appendingPathComponent("index.json"))
        do {
            try cancelledNew.commit(newDocument, to: destination)
            preconditionFailure("An incomplete new import must not publish its files")
        } catch {}
        precondition(!FileManager.default.fileExists(atPath: destination.directory(for: newDocument.id).path),
                     "A failed new document must leave no partial destination")
        cancelledNew.discard()
        precondition(!FileManager.default.fileExists(atPath: cancelledNew.store.root.path),
                     "Discard removes all partial staging files")

        try staging.commit(replacement, to: destination)
        savedBytes = try bytes(destination.file(for: replacement))
        let savedIndex = try destination.index(for: replacement)
        precondition(savedBytes == replacementData)
        precondition(savedIndex.pages.first?.text == "Updated course notes")
        let revisions = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Revisions/\(original.id)"), includingPropertiesForKeys: nil)
        precondition(revisions.count == 1)
        let previousBytes = try bytes(revisions[0].appendingPathComponent(original.fileName))
        precondition(previousBytes == originalData, "Successful replacements must retain the previous original")
        print("PASS: staging rejects missing, malformed and truncated files; cancelled and failed imports retain originals and leave no partial new documents")
    }
}

extension StudyWorkspaceSmoke {
    static func checkCanvasSessionsAndAttachments() async throws {
        let origin = URL(string: "https://canvas.example.test")!
        let now = Date()
        let cookie = HTTPCookie(properties: [.name: "session", .value: "fixture-secret", .domain: "canvas.example.test", .path: "/api", .secure: "TRUE", .expires: now.addingTimeInterval(3600), HTTPCookiePropertyKey("HttpOnly"): "TRUE"])!
        let sso = HTTPCookie(properties: [.name: "sso", .value: "never-archive", .domain: ".example.test", .path: "/"])!
        let archived = CanvasCookieArchive(savedAt: now, entries: [CanvasCookieArchive.Entry(cookie), CanvasCookieArchive.Entry(sso)])
        let restored = try JSONDecoder().decode(CanvasCookieArchive.self, from: JSONEncoder().encode(archived))
        let valid = restored.cookies(origin: origin, now: now)
        precondition(valid.count == 1 && valid[0].isSecure && valid[0].isHTTPOnly)
        precondition(restored.cookies(origin: origin, now: now.addingTimeInterval(3601)).isEmpty)
        precondition(restored.cookies(origin: origin, now: now.addingTimeInterval(8 * 86400)).isEmpty)
        precondition(CanvasCookieArchive.header(valid, url: origin.appendingPathComponent("api/v1/courses"), origin: origin).contains("fixture-secret"))
        precondition(CanvasCookieArchive.header(valid, url: origin.appendingPathComponent("apievil"), origin: origin).isEmpty)
        precondition(CanvasCookieArchive.header(valid, url: URL(string: "https://evil.test/api")!, origin: origin).isEmpty)

        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CanvasAuthFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let jar = CanvasCookieFixture()
        let client = CanvasClient(origin: origin, session: session, cookies: { _ in await jar.header }, receiveCookies: { _, headers in await jar.receive(headers) })
        _ = try await client.account()
        _ = try await client.account() // The second request must carry the renewed cookie.
        let ref = try await client.fileReference(id: "1308344", courseID: 24623)
        precondition(ref.fileName == "Exercise 5.pdf")
        let material = try await client.material(ref, courseID: 24623)
        let bytes = try await client.download(material.downloadURL!)
        precondition(bytes == Data("%PDF-fixture".utf8))
        do { _ = try await client.fileReference(id: "2", courseID: 24623); preconditionFailure("Locks must remain enforced") }
        catch { precondition(error.localizedDescription.contains("not currently available")) }
        do { _ = try await client.fileReference(id: "3", courseID: 24623); preconditionFailure("Expired sign-in must fail") }
        catch let error as CanvasHTTPError { precondition(error.status == 401) }
        var original = URLRequest(url: origin.appendingPathComponent("files/1/download"))
        original.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        original.setValue("session=fixture", forHTTPHeaderField: "Cookie")
        let redirect = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil, headerFields: [:])!
        let policy = CanvasRedirectPolicy(downloads: true)
        let same = policy.redirectedRequest(URLRequest(url: origin.appendingPathComponent("files/1")), response: redirect, original: original)
        precondition(same?.value(forHTTPHeaderField: "Cookie") == "session=fixture")
        let external = policy.redirectedRequest(URLRequest(url: URL(string: "https://storage.example.test/1")!), response: redirect, original: original)
        precondition(external?.value(forHTTPHeaderField: "Cookie") == nil && external?.value(forHTTPHeaderField: "Authorization") == nil)
        print("PASS: Canvas cookie renewal, secure local archive filtering, path isolation, linked-only attachment fallback, locks and redirect credentials")
    }
}

private actor CanvasCookieFixture {
    var header = "session=original"
    func receive(_ headers: [String: String]) {
        if headers.contains(where: { $0.key.lowercased() == "set-cookie" && $0.value.contains("renewed") }) { header = "session=renewed" }
    }
}

private final class CanvasAuthFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, path = request.url!.path
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var body: [String: Any] = ["id": 7, "name": "Fixture account"]
        if url.host == "storage.example.test" {
            precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        } else if path == "/api/v1/users/self/profile" {
            headers["Set-Cookie"] = "session=renewed; Path=/; Secure; HttpOnly"
        } else {
            precondition(request.value(forHTTPHeaderField: "Cookie") == "session=renewed")
            if path.hasPrefix("/api/v1/courses/") { status = path.hasSuffix("/3") ? 401 : 403 }
            else if path.hasPrefix("/api/v1/files/") {
                precondition(!path.hasSuffix("/3"), "Do not retry auth failures through another endpoint")
                body = ["id": 1308344, "filename": "Exercise 5.pdf", "display_name": "Exercise 5.pdf", "hidden_for_user": true, "locked_for_user": path.hasSuffix("/2"), "url": "https://storage.example.test/exercise.pdf"]
            }
        }
        let data = url.host == "storage.example.test" ? Data("%PDF-fixture".utf8) : try! JSONSerialization.data(withJSONObject: body)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class TransferFixtureState: @unchecked Sendable {
    private let lock = NSLock()
    private var startedURLs = Set<URL>()
    private var stoppedURLs = Set<URL>()

    func start(_ url: URL) { _ = lock.withLock { startedURLs.insert(url) } }
    func stop(_ url: URL) { _ = lock.withLock { stoppedURLs.insert(url) } }
    func started(_ url: URL) -> Bool { lock.withLock { startedURLs.contains(url) } }
    func stopped(_ url: URL) -> Bool { lock.withLock { stoppedURLs.contains(url) } }
}

private final class TransferFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = TransferFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let name = url.lastPathComponent
        let data = Data((0..<196_608).map { UInt8($0 % 251) })
        let headers = name == "declared" ? ["Content-Length": String(data.count)] : [:]
        let response = HTTPURLResponse(url: url, statusCode: name == "forbidden" ? 403 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if name.hasPrefix("wait-") {
            client?.urlProtocol(self, didLoad: Data([1]))
            Self.state.start(url)
            return
        }
        for offset in stride(from: 0, to: data.count, by: 65_536) {
            client?.urlProtocol(self, didLoad: data.subdata(in: offset..<min(offset + 65_536, data.count)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if let url = request.url { Self.state.stop(url) }
    }
}
