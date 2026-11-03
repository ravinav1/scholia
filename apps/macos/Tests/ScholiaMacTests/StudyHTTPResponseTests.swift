import XCTest
@testable import ScholiaMac

final class StudyHTTPResponseTests: XCTestCase {
    func testUnchangedStateHasAnEmpty304ResponseWithoutCachingPrivateData() throws {
        let original = StudyHTTPResponse(data: Data("{\"draft\":\"Private question\"}".utf8),
            headers: ["ETag": "\"revision-1\""])
        let unchanged = original.revalidated(ifNoneMatch: "\"old\", W/\"revision-1\"")
        XCTAssertEqual(unchanged.status, 304)
        XCTAssertTrue(unchanged.data.isEmpty)
        let wire = try XCTUnwrap(String(data: unchanged.serialized(), encoding: .utf8))
        XCTAssertTrue(wire.hasPrefix("HTTP/1.1 304 Not Modified\r\n"))
        XCTAssertTrue(wire.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(wire.contains("ETag: \"revision-1\"\r\n"))
        XCTAssertFalse(wire.contains("Private question"))
        XCTAssertTrue(wire.hasSuffix("\r\n\r\n"))
        XCTAssertEqual(original.status, 200, "Revalidation must not destroy the reusable full snapshot")
        XCTAssertFalse(original.data.isEmpty)
    }

    func testChangedAndUnvalidatedRequestsStillReceiveTheFullSnapshot() {
        let original = StudyHTTPResponse(data: Data("current".utf8), headers: ["ETag": "\"new\""])
        for validator in [nil, "\"old\"", "\"newer\""] {
            let response = original.revalidated(ifNoneMatch: validator)
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(response.data, original.data)
        }
        let failure = StudyHTTPResponse.error(403, "Reopen this website from Scholia")
        XCTAssertEqual(failure.revalidated(ifNoneMatch: "*").status, 403)
    }

    func testAssetRevalidationRetainsCachePolicyAndWeakValidator() throws {
        let asset = StudyHTTPResponse(data: Data("export {};".utf8), type: "text/javascript",
            headers: ["ETag": "W/\"file-revision\"", "Cache-Control": "private, no-cache"])
        let response = asset.revalidated(ifNoneMatch: "\"file-revision\"")
        XCTAssertEqual(response.status, 304)
        let wire = try XCTUnwrap(String(data: response.serialized(), encoding: .utf8))
        XCTAssertTrue(wire.contains("Cache-Control: private, no-cache\r\n"))
        XCTAssertFalse(wire.contains("Cache-Control: no-store"))
        XCTAssertTrue(wire.contains("ETag: W/\"file-revision\"\r\n"))
    }
}
