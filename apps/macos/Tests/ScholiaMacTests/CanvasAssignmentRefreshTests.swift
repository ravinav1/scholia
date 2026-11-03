import Foundation
import XCTest
@testable import ScholiaMac

private final class AssignmentResponseState: @unchecked Sendable {
    let lock = NSLock()
    var count = 0
    var conditional = false
    func next(_ request: URLRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        conditional = conditional || request.value(forHTTPHeaderField: "If-None-Match") != nil
            || request.value(forHTTPHeaderField: "If-Modified-Since") != nil
        return count
    }
}
private final class AssignmentRefreshProtocol: URLProtocol, @unchecked Sendable {
    static let state = AssignmentResponseState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "canvas.refresh.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let number = Self.state.next(request)
        let status = number == 1 ? "unsubmitted" : "submitted"
        let records: [[String: Any]] = [["id": 1, "name": "Exercise", "updated_at": "unchanged", "submission_types": ["online_upload"],
            "submission": ["workflow_state": status]]]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "ETag": "unchanged", "Cache-Control": "max-age=3600"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: records))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class CanvasAssignmentRefreshTests: XCTestCase {
    func testSubmissionChangesAreFetchedDespiteUnchangedAssignmentVersionAndCacheHeaders() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AssignmentRefreshProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = CanvasClient(origin: URL(string: "https://canvas.refresh.test")!, token: "fixture", session: session)
        let first = try await client.assignmentUpdates(courseID: 1)
        let next = try await client.assignmentUpdates(courseID: 1)
        XCTAssertEqual(first.first?.assignment?.status, .notSubmitted)
        XCTAssertEqual(next.first?.assignment?.status, .submitted)
        XCTAssertEqual(next.first?.version, first.first?.version)
        XCTAssertFalse(AssignmentRefreshProtocol.state.conditional)
    }
}
