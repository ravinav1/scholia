import AppKit
import Combine
import Foundation
import SQLite3
@testable import ScholiaMac

private final class RefreshResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var submitted = false
    private var offline = false
    func set(submitted: Bool, offline: Bool = false) {
        lock.withLock { self.submitted = submitted; self.offline = offline }
    }
    func snapshot() -> (submitted: Bool, offline: Bool) {
        lock.withLock { (submitted, offline) }
    }
}

private final class RefreshPerformanceProtocol: URLProtocol, @unchecked Sendable {
    static let state = RefreshResponseState()
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "canvas.performance.test"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let state = Self.state.snapshot()
        if state.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body: Any
        if request.url!.path.contains("users/self") {
            body = ["id": 42, "name": "Fixture student"]
        } else if request.url!.path.contains("students/submissions") {
            body = [] as [[String: Any]]
        } else {
            body = (1...200).map { id -> [String: Any] in
                ["id": id, "name": "Exercise \(id)", "updated_at": "unchanged",
                 "submission_types": ["online_upload"],
                 "submission": ["workflow_state": state.submitted ? "submitted" : "unsubmitted"]]
            }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main @MainActor
struct AssignmentRefreshPerformanceSmoke {
    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-refresh-performance-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = URL(string: "https://canvas.performance.test")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefreshPerformanceProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = CanvasClient(origin: origin, token: "fixture", session: session)
        var courses: [StudyCourse] = []
        for id in 1...2 {
            var materials = try await client.assignmentUpdates(courseID: id)
            materials[0].moduleTitle = "Preserved module"
            courses.append(StudyCourse(name: "Fixture \(id)", canvasID: id,
                canvasOrigin: origin.absoluteString, canvasUserID: 42, canvasMaterials: materials))
        }
        let store = StudyLibraryStore(root: root)
        let now = Date()
        var library = StudyLibrary(courses: courses, selectedCourseID: courses[0].id,
            canvasOrigin: origin.absoluteString, canvasUserID: 42, canvasUserName: "Fixture student",
            showingCourseLibrary: true)
        library.canvasAssignmentsCheckedAt = now
        try store.save(library)
        let workspace = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client })
        var publications = 0
        let observation = workspace.$library.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        let libraryFile = root.appendingPathComponent("library.sqlite")
        func savedRevision() throws -> Int64 {
            var db: OpaquePointer?
            guard sqlite3_open_v2(libraryFile.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
                throw StudyError.message("Could not open refresh test database")
            }
            defer { sqlite3_close_v2(db) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT revision FROM library_metadata WHERE singleton = 1", -1, &statement, nil) == SQLITE_OK,
                let statement else { throw StudyError.message("Missing library revision") }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw StudyError.message("Could not read library revision") }
            return sqlite3_column_int64(statement, 0)
        }
        func awaitSaved(_ matches: (StudyLibrary) -> Bool) async throws {
            for _ in 0..<200 {
                if matches(try store.load()) { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("The refresh snapshot was not persisted")
        }

        let unchangedDate = try savedRevision()
        await workspace.refreshCanvasAssignmentsIfNeeded(now: now, force: true)
        try await Task.sleep(for: .milliseconds(50))
        precondition(publications == 0, "Equal assignment data and metadata must not publish the library")
        let afterUnchangedDate = try savedRevision()
        precondition(afterUnchangedDate == unchangedDate, "An identical refresh must not rewrite the library")
        print("PASS: 400 unchanged assignments produce zero library publications and no rewrite")

        let nextCheck = now.addingTimeInterval(120)
        await workspace.refreshCanvasAssignmentsIfNeeded(now: nextCheck, force: true)
        precondition(publications == 1, "An ordinary unchanged poll publishes only its last-check metadata")
        try await awaitSaved { $0.canvasAssignmentsCheckedAt == nextCheck }
        precondition(workspace.library.courses.map(\.canvasMaterials) == courses.map(\.canvasMaterials))
        print("PASS: a later unchanged poll publishes one metadata snapshot, with no course changes")

        publications = 0
        RefreshPerformanceProtocol.state.set(submitted: true)
        let changedCheck = nextCheck.addingTimeInterval(120)
        await workspace.refreshCanvasAssignmentsIfNeeded(now: changedCheck, force: true)
        precondition(publications == 1, "400 changed assignments across two courses must publish only once")
        try await awaitSaved { saved in
            saved.canvasAssignmentsCheckedAt == changedCheck
                && saved.courses.allSatisfy { course in
                    course.canvasMaterials?.allSatisfy { $0.assignment?.status == .submitted } == true
                }
        }
        precondition(workspace.library.courses.allSatisfy { $0.canvasMaterials?.first?.moduleTitle == "Preserved module" })
        print("PASS: 400 submission changes publish once, persist correctly and preserve catalog fields")

        RefreshPerformanceProtocol.state.set(submitted: true, offline: true)
        await workspace.refreshCanvasAssignmentsIfNeeded(now: changedCheck, force: true)
        try await awaitSaved { $0.canvasAssignmentsError != nil }
        publications = 0
        let failureDate = try savedRevision()
        await workspace.refreshCanvasAssignmentsIfNeeded(now: changedCheck, force: true)
        try await Task.sleep(for: .milliseconds(50))
        let afterFailureDate = try savedRevision()
        precondition(publications == 0 && afterFailureDate == failureDate,
            "An unchanged failure must not invalidate or rewrite the library")
        print("PASS: repeated offline refresh retains saved status without publishing or rewriting")
    }
}
