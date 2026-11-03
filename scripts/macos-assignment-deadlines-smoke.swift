import Foundation
@testable import ScholiaMac

private final class DeadlineResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var due: String? = "2026-10-08T21:59:59Z"
    private var offline = false
    private var feedbackStatus = 200
    private var slow = false
    private(set) var conditional = false

    func set(due: String?, offline: Bool = false, feedbackStatus: Int = 200, slow: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.due = due; self.offline = offline; self.feedbackStatus = feedbackStatus
        self.slow = slow
    }

    var isSlow: Bool { lock.lock(); defer { lock.unlock() }; return slow }

    func response(_ request: URLRequest) throws -> (Int, Any) {
        lock.lock(); defer { lock.unlock() }
        conditional = conditional || request.value(forHTTPHeaderField: "If-None-Match") != nil
            || request.value(forHTTPHeaderField: "If-Modified-Since") != nil
        if offline { throw URLError(.notConnectedToInternet) }
        if request.url!.path == "/api/v1/users/self/profile" { return (200, ["id": 42, "name": "Fixture student"]) }
        if request.url!.path.contains("submissions") { return (feedbackStatus, []) }
        let record: [String: Any] = [
            "id": 31969, "name": "Exercise 6", "updated_at": "unchanged",
            "due_at": due as Any? ?? NSNull(), "description": "<p>Show your work.</p>",
            "submission_types": ["online_upload"], "submission": ["workflow_state": "unsubmitted"]
        ]
        return (200, request.url!.path.hasSuffix("/assignments") ? [record] : record)
    }
}

private final class DeadlineProtocol: URLProtocol, @unchecked Sendable {
    static let state = DeadlineResponses()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "canvas.deadlines.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.state.isSlow {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { self.respond() }
        } else { respond() }
    }
    private func respond() {
        do {
            let (status, value) = try Self.state.response(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json", "ETag": "unchanged", "Cache-Control": "max-age=3600"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: value))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class UnexpectedWikiProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { preconditionFailure("Automatic wiki checks must wait for deadline refresh") }
    override func stopLoading() {}
}

extension StudyWorkspaceSmoke {
    static func checkDeadlineRefreshScheduling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-deadline-scheduling-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = deadlineClient()
        DeadlineProtocol.state.set(due: "2026-10-11T21:59:59Z", slow: true)
        defer { DeadlineProtocol.state.set(due: "2026-10-11T21:59:59Z") }
        let store = StudyLibraryStore(root: root)
        let course = StudyCourse(name: "Calculus", code: "TMA4100-26H", canvasID: 24624,
            canvasOrigin: "https://canvas.deadlines.test", canvasUserID: 42, favorite: true, term: "2026 HØST")
        try store.save(StudyLibrary(courses: [course], canvasOrigin: "https://canvas.deadlines.test", canvasUserID: 42))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UnexpectedWikiProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let workspace = StudyWorkspaceModel(store: store, mathWikiSession: session, canvasClientFactory: { _, _, _ in client })
        let wikiEnabled = workspace.automaticallyUpdateMathWiki, contentEnabled = workspace.automaticallyUpdateCanvasContent
        defer {
            workspace.automaticallyUpdateMathWiki = wikiEnabled
            workspace.automaticallyUpdateCanvasContent = contentEnabled
        }
        workspace.automaticallyUpdateMathWiki = true
        let refresh = Task { await workspace.refreshCanvasAssignmentsIfNeeded(force: true) }
        for _ in 0..<100 where !workspace.assignmentRefreshBusy { try await Task.sleep(for: .milliseconds(1)) }
        precondition(workspace.assignmentRefreshBusy)
        await workspace.refreshMathWikiIfNeeded()
        workspace.automaticallyUpdateCanvasContent = true
        await workspace.refreshCanvasContentIfNeeded()
        workspace.automaticallyUpdateCanvasContent = false
        await workspace.refreshCanvasFilesIfNeeded()
        precondition(!workspace.canvasBusy, "Automatic content checks must not interrupt the deadline refresh")
        await refresh.value
        precondition(workspace.library.canvasAssignmentsError == nil && workspace.library.canvasAssignmentsCheckedAt != nil)
        precondition(workspace.library.courses[0].materials[0].assignment?.dueAt == "2026-10-11T21:59:59Z")
        workspace.flush()
    }

    private static func deadlineClient() -> CanvasClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeadlineProtocol.self]
        return CanvasClient(origin: URL(string: "https://canvas.deadlines.test")!, token: "fixture",
            session: URLSession(configuration: configuration))
    }

    static func checkMovedAssignmentDeadlines() async throws {
        let client = deadlineClient()
        DeadlineProtocol.state.set(due: "2026-10-08T21:59:59Z")
        let first = try await client.assignmentUpdates(courseID: 24624).first!
        DeadlineProtocol.state.set(due: "2026-10-11T21:59:59Z", feedbackStatus: 500)
        let next = try await client.assignmentUpdates(courseID: 24624).first!
        precondition(next.assignment?.dueAt == "2026-10-11T21:59:59Z")
        precondition(next.version != first.version)
        precondition(!DeadlineProtocol.state.conditional)
        DeadlineProtocol.state.set(due: nil, feedbackStatus: 403)
        let removed = try await client.assignmentUpdate(courseID: 24624, id: "31969")
        precondition(removed.assignment?.dueAt == nil)
        precondition(removed.version.hasSuffix("|due:none"))
    }

    static func checkDeadlineAuthentication() async throws {
        DeadlineProtocol.state.set(due: "2026-10-11T21:59:59Z", feedbackStatus: 401)
        do {
            _ = try await deadlineClient().assignmentUpdates(courseID: 24624)
            preconditionFailure("An expired session must still require reconnecting")
        } catch let error as CanvasHTTPError { precondition(error.requiresSignIn) }
    }

    @MainActor
    static func checkCachedAssignmentDeadline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-deadline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let client = deadlineClient()
        DeadlineProtocol.state.set(due: "2026-10-08T21:59:59Z")
        let reference = try await client.assignmentUpdate(courseID: 24624, id: "31969")
        let course = StudyCourse(name: "TFE4130", canvasID: 24624,
            canvasOrigin: "https://canvas.deadlines.test", canvasMaterials: [reference])
        let store = StudyLibraryStore(root: root)
        try store.save(StudyLibrary(courses: [course]))
        let workspace = StudyWorkspaceModel(store: store)
        func open() async throws {
            workspace.openAssignment(workspace.library.courses[0].materials[0], courseID: course.id, clientOverride: client)
            for _ in 0..<1000 where workspace.assignmentPreparing { try await Task.sleep(for: .milliseconds(10)) }
            precondition(!workspace.assignmentPreparing)
        }
        try await open()
        precondition(workspace.assignmentText.contains("2026-10-08"))
        let documentID = workspace.course?.documents.first?.id
        // A background metadata refresh must also repair the generated date in
        // already-downloaded instructions, even while their file stays offline.
        workspace.library.courses[0].canvasMaterials?[0].assignment?.dueAt = "2026-10-11T21:59:59Z"
        DeadlineProtocol.state.set(due: "2026-10-11T21:59:59Z", offline: true)
        try await open()
        precondition(workspace.assignmentText.contains("2026-10-11"))
        precondition(!workspace.assignmentText.contains("2026-10-08"))
        let context = StudyContextBuilder.build(document: nil, index: nil, currentPage: 1,
            question: "When is this assignment due?", selection: "", course: workspace.course!, store: store,
            includeCourse: false, assignment: workspace.assignment)
        precondition(context.text.contains("2026-10-11") && !context.text.contains("2026-10-08"))
        let cachedText = "Teacher instructions\n\nDue: 2026-10-08T21:59:59Z"
        precondition(CanvasAssignmentDetails.refreshingCachedDeadline(cachedText,
            sourceVersion: "unchanged|due:2026-10-08T21:59:59Z", dueAt: nil) == "Teacher instructions")
        precondition(CanvasAssignmentDetails.refreshingCachedDeadline(cachedText,
            sourceVersion: "unchanged", dueAt: nil) == cachedText, "Do not rewrite dates authored by the instructor")
        DeadlineProtocol.state.set(due: "2026-10-11T21:59:59Z")
        try await open()
        precondition(workspace.assignment?.assignment?.dueAt == "2026-10-11T21:59:59Z")
        precondition(workspace.assignmentText.contains("2026-10-11"))
        precondition(!workspace.assignmentText.contains("2026-10-08"))
        precondition(workspace.course?.documents.first?.id == documentID)
        precondition(workspace.assignmentNotice == nil)
        DeadlineProtocol.state.set(due: "2026-10-11T21:59:59Z", offline: true)
        try await open()
        precondition(workspace.assignmentText.contains("Show your work"))
        precondition(workspace.assignment?.assignment?.dueAt == "2026-10-11T21:59:59Z")
        precondition(workspace.assignmentNotice?.contains("Deadline may be out of date") == true)
        workspace.flush()
        let saved = try store.load()
        precondition(saved.courses[0].materials[0].assignment?.dueAt == "2026-10-11T21:59:59Z")
    }
}
