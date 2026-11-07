import AppKit
import Foundation
import Security
@testable import ScholiaMac

extension StudyWorkspaceSmoke {
    static func checkCanvasReconnectAndRefresh() async throws {
        let origin = URL(string: "https://canvas.refresh.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CanvasReconnectProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = CanvasClient(origin: origin, token: "fixture", session: session)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-reconnect-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let reference = CanvasMaterialReference(id: "assignments:30793", kind: .assignments, remoteID: "30793",
            title: "Øving 2", sourceURL: origin.absoluteString + "/courses/24090/assignments/30793", version: "unchanged|due:2026-09-27T21:30:00Z",
            assignment: CanvasAssignmentDetails(record: ["submission_types": ["online_upload"], "submission": ["workflow_state": "unsubmitted"]]))
        let course = StudyCourse(name: "Cybernetics", code: "TTK4100-26H", canvasID: 24090,
            canvasOrigin: origin.absoluteString, canvasUserID: 42, canvasMaterials: [reference])
        var other = course; other.id = UUID(); other.canvasUserID = 99
        try store.save(StudyLibrary(courses: [course, other], canvasOrigin: origin.absoluteString,
            canvasUserID: 42, canvasUserName: "Fixture student", showingCourseLibrary: true))
        let workspace = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client })
        CanvasReconnectProtocol.state.set("submitted")

        // No StudyWindowController or StudyWorkspaceView is created. Polling the
        // real native HTTP server must update the user's status on its own.
        let server = StudyWebServer(app: AppModel.shared, workspace: workspace, assets: URL(fileURLWithPath: "dist/web"))
        server.start(port: 0)
        defer { server.stop() }
        for _ in 0..<100 where server.address == nil { try await Task.sleep(for: .milliseconds(20)) }
        let address = server.address!
        let (htmlData, _) = try await URLSession.shared.data(from: address)
        let html = String(decoding: htmlData, as: UTF8.self)
        let token = html.components(separatedBy: "name=\"scholia-token\" content=\"")[1].components(separatedBy: "\"")[0]
        func request(_ action: String? = nil) async throws -> [String: Any] {
            var request = URLRequest(url: address.appendingPathComponent(action == nil ? "api/state" : "api/action"))
            request.setValue(token, forHTTPHeaderField: "X-Scholia-Token")
            if let action {
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["action": action])
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            precondition((response as? HTTPURLResponse)?.statusCode == 200)
            return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func status(_ index: Int = 0) -> CanvasSubmissionStatus? {
            workspace.library.courses[index].materials.first?.assignment?.status
        }
        _ = try await request()
        for _ in 0..<200 where status() != .submitted { try await Task.sleep(for: .milliseconds(10)) }
        precondition(status() == .submitted, "Browser-only polling must repair the stale TTK4100 Øving 2 status")
        precondition(status(1) == .notSubmitted, "A different account's courses must not be overwritten")
        precondition(!workspace.canvasPresented && !workspace.canvasSigningIn)
        precondition(StudyAssignmentGroup.make(courses: [workspace.library.courses[0]], filter: .due).isEmpty)
        precondition(StudyAssignmentGroup.make(courses: [workspace.library.courses[0]], filter: .all).first?.timeframe == .handedIn)
        precondition(StudyMaterialOrganizer.groups(for: workspace.library.courses[0]).flatMap(\.items).first?.submissionStatus == .submitted)
        let windows = NSApplication.shared.windows.filter(\.isVisible).count
        _ = try await request("signIn")
        precondition(!workspace.canvasPresented && !workspace.canvasSigningIn)
        precondition(NSApplication.shared.windows.filter(\.isVisible).count == windows, "Saved sign-in must not open a window")
        for _ in 0..<200 where workspace.assignmentRefreshBusy { try await Task.sleep(for: .milliseconds(10)) }
        let count = CanvasReconnectProtocol.state.count
        _ = try await request()
        try await Task.sleep(for: .milliseconds(50))
        precondition(CanvasReconnectProtocol.state.count == count, "Repeated polling must be throttled")

        CanvasReconnectProtocol.state.set("graded")
        _ = try await request("refreshAssignments")
        for _ in 0..<200 where status() != .graded { try await Task.sleep(for: .milliseconds(10)) }
        precondition(status() == .graded, "Refresh status must bypass the throttle and update unchanged assignment versions")
        precondition(workspace.library.courses[0].materials[0].assignment?.gradeLabel == "1 / 1")
        precondition(workspace.library.courses[0].materials[0].version == reference.version)
        precondition(!CanvasReconnectProtocol.state.conditional)
        workspace.flush()
        let saved = try store.load()
        precondition(saved.courses[0].materials[0].assignment?.status == .graded)

        CanvasReconnectProtocol.state.set("offline")
        await workspace.refreshCanvasAssignmentsIfNeeded(force: true)
        precondition(status() == .graded && workspace.library.canvasAssignmentsError != nil)
        await workspace.beginCanvasSignIn()
        precondition(!workspace.canvasSigningIn, "A network failure is not a reason to open sign-in")

        CanvasReconnectProtocol.state.set("expired")
        await workspace.refreshCanvasAssignmentsIfNeeded(force: true)
        precondition(status() == .graded && workspace.library.canvasAssignmentsError?.contains("Reconnect") == true)
        await workspace.retryCanvasSignIn()
        precondition(workspace.canvasSigningIn && workspace.canvasPresented,
            "Retrying expired credentials must open the Canvas sign-in sheet")
        workspace.cancelCanvasSignIn()
        workspace.canvasPresented = false
        precondition(!workspace.canvasSigningIn)
        CanvasReconnectProtocol.state.set("submitted")
        await workspace.refreshCanvasAssignmentsIfNeeded(force: true)
        precondition(status() == .submitted && workspace.library.canvasAssignmentsError == nil
            && !workspace.canvasNeedsAuthentication,
            "Closing sign-in must not permanently pause background refresh")

        workspace.showAssignments()
        precondition(workspace.isShowingAssignments)
        workspace.showCourseLibrary()
        precondition(!workspace.isShowingAssignments && workspace.isShowingLibrary)
        workspace.goBack()
        precondition(workspace.isShowingAssignments, "Back must restore the dedicated assignments page")
        workspace.flush()
        let reopened = try store.load()
        precondition(reopened.courseLibraryView == .assignments)
        let fallbackStore = StudyLibraryStore(root: root.appendingPathComponent("fallback"))
        var usedBrowserSession = false
        let fallback = StudyWorkspaceModel(store: fallbackStore, canvasClientFactory: { _, browser, _ in
            guard browser else { throw CanvasHTTPError(status: 401) }
            usedBrowserSession = true
            return client
        })
        fallback.canvasAddress = origin.absoluteString
        await fallback.beginCanvasSignIn()
        precondition(usedBrowserSession && !fallback.canvasSigningIn && fallback.library.canvasUserID == 42,
            "An expired token must fall back to a valid saved browser session without opening sign-in")
        UserDefaults.standard.removeObject(forKey: "canvas.auth:\(origin.absoluteString)")
        fallback.flush()
        let lockedStore = StudyLibraryStore(root: root.appendingPathComponent("locked"))
        var interactiveReads = 0
        let locked = StudyWorkspaceModel(store: lockedStore, canvasClientFactory: { _, _, allowInteraction in
            guard allowInteraction else { throw KeychainStoreError.unexpectedStatus(errSecInteractionNotAllowed) }
            interactiveReads += 1
            return client
        })
        locked.canvasAddress = origin.absoluteString
        let silentResult = await locked.checkCanvasConnection()
        precondition(!silentResult && interactiveReads == 0 && !locked.canvasSigningIn)
        await locked.beginCanvasSignIn()
        precondition(interactiveReads == 1 && !locked.canvasSigningIn && locked.library.canvasUserID == 42,
            "Keychain UI must require an explicit reconnect, and must not open Canvas after access succeeds")
        locked.flush()
        for keychainStatus in [errSecAuthFailed, errSecUserCanceled] {
            let retryStore = StudyLibraryStore(root: root.appendingPathComponent("keychain-\(keychainStatus)"))
            try retryStore.save(StudyLibrary(courses: [course], canvasOrigin: origin.absoluteString,
                canvasUserID: 42, canvasUserName: "Fixture student"))
            var retryPrompts = 0
            var acceptsCredentials = false
            let retry = StudyWorkspaceModel(store: retryStore, canvasClientFactory: { _, _, allowInteraction in
                if allowInteraction { retryPrompts += 1 }
                guard allowInteraction && acceptsCredentials else {
                    throw KeychainStoreError.unexpectedStatus(keychainStatus)
                }
                return client
            })
            await retry.refreshCanvasAssignmentsIfNeeded(force: true)
            precondition(retryPrompts == 0 && retry.canvasNeedsAuthentication
                && retry.library.canvasAssignmentsError?.contains("Keychain") == true,
                "Background authentication failures must offer recovery without prompting")
            retry.loadCanvasCourses()
            for _ in 0..<200 where retry.canvasBusy { try await Task.sleep(for: .milliseconds(10)) }
            precondition(!retry.canvasBusy && retryPrompts == 0 && retry.canvasNeedsAuthentication
                && retry.canvasReconnectTitle == "Allow Keychain access",
                "A Keychain failure must offer access to the saved credential rather than a new Canvas login")
            await retry.retryCanvasSignIn()
            precondition(retryPrompts == 1 && retry.canvasNeedsAuthentication && !retry.canvasChecking
                && !retry.canvasSigningIn && !retry.canvasPresented
                && retry.canvasStatus == retry.canvasConnectionStatus,
                "A failed or canceled prompt must stay retryable without reopening itself")
            acceptsCredentials = true
            await retry.retryCanvasSignIn()
            precondition(retryPrompts == 2 && !retry.canvasNeedsAuthentication && !retry.canvasChecking
                && !retry.canvasSigningIn && !retry.canvasPresented
                && retry.library.canvasUserID == 42 && retry.library.courses.map(\.id) == [course.id]
                && retry.canvasStatus == "Connected as Fixture student",
                "Sign in again must retry Keychain access, clear the error, and preserve saved courses")
            for _ in 0..<200 where retry.assignmentRefreshBusy { try await Task.sleep(for: .milliseconds(10)) }
            retry.flush()
        }
        var unrelatedPrompts = 0
        let corrupt = StudyWorkspaceModel(store: StudyLibraryStore(root: root.appendingPathComponent("corrupt")),
            canvasClientFactory: { _, _, allowInteraction in
                if allowInteraction { unrelatedPrompts += 1 }
                throw KeychainStoreError.unexpectedStatus(errSecDecode)
            })
        corrupt.canvasAddress = origin.absoluteString
        await corrupt.retryCanvasSignIn()
        precondition(unrelatedPrompts == 0 && !corrupt.canvasNeedsAuthentication && !corrupt.canvasSigningIn,
            "Non-authentication Keychain errors must not trigger a credential prompt")
        corrupt.flush()
        var allowedBefore = DarwinBoolean(true), allowedAfter = DarwinBoolean(true)
        precondition(SecKeychainGetUserInteractionAllowed(&allowedBefore) == errSecSuccess)
        let absent = try await ProviderKeychain.valueAsync(for: "scholia-missing-fixture-\(UUID())")
        precondition(SecKeychainGetUserInteractionAllowed(&allowedAfter) == errSecSuccess)
        precondition(absent.isEmpty && allowedBefore.boolValue == allowedAfter.boolValue,
            "Silent Keychain reads must restore the interaction policy")
        print("PASS: browser-only TTK4100 submission refresh, silent saved login, account isolation, unchanged versions, manual refresh, offline/expired sessions, Keychain password/cancellation retries and assignments navigation")
    }
}

private final class CanvasReconnectState: @unchecked Sendable {
    private let lock = NSLock()
    private var mode = "submitted"
    private var requests = 0
    private var conditionalRequest = false
    func set(_ mode: String) { lock.lock(); defer { lock.unlock() }; self.mode = mode }
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    var conditional: Bool { lock.lock(); defer { lock.unlock() }; return conditionalRequest }
    func record(_ request: URLRequest) -> String {
        lock.lock(); defer { lock.unlock() }
        requests += 1
        conditionalRequest = conditionalRequest || request.value(forHTTPHeaderField: "If-None-Match") != nil
            || request.value(forHTTPHeaderField: "If-Modified-Since") != nil
        return mode
    }
}

private final class CanvasReconnectProtocol: URLProtocol, @unchecked Sendable {
    static let state = CanvasReconnectState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "canvas.refresh.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let mode = Self.state.record(request)
        if mode == "offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
        }
        let url = request.url!
        let body: Any
        if url.path == "/api/v1/users/self/profile" { body = ["id": 42, "name": "Fixture student"] }
        else if url.path == "/api/v1/courses/24090/students/submissions" { body = [[String: Any]]() }
        else {
            precondition(url.path == "/api/v1/courses/24090/assignments")
            body = [["id": 30793, "name": "Øving 2", "updated_at": "unchanged", "due_at": "2026-09-27T21:30:00Z",
                "submission_types": ["online_upload"], "grading_type": "points", "points_possible": 1,
                "submission": ["workflow_state": mode, "submitted_at": "2026-09-27T12:00:00Z",
                    "posted_at": "2026-09-28T10:00:00Z", "score": 1, "grade": "1"]]]
        }
        let response = HTTPURLResponse(url: url, statusCode: mode == "expired" ? 401 : 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "ETag": "unchanged", "Cache-Control": "max-age=3600"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
