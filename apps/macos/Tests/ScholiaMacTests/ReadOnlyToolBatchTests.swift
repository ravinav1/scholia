import Foundation
import XCTest
@testable import ScholiaMac

final class ReadOnlyToolBatchTests: XCTestCase {
    private func rows(_ result: LocalFileToolResult) throws -> [[String: Any]] {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        return try XCTUnwrap(json["results"] as? [[String: Any]])
    }

    func testBatchRejectsMutationsNestingAndOversizedRequestsBeforeReadingAnything() throws {
        var executed = 0
        for requests in [[], Array(repeating: LocalFileToolCall(operation: "read"), count: 9),
                         [.init(operation: "read"), .init(operation: "write", content: "unrequested")],
                         [.init(operation: "read", requests: [.init(operation: "read")])]] {
            XCTAssertThrowsError(try ReadOnlyToolBatch.execute(.init(operation: "read_batch", requests: requests),
                allowedOperations: ["read"]) { _ in
                    executed += 1
                    return try .json(["text": "should not run"])
                })
        }
        XCTAssertEqual(executed, 0)
    }

    func testIndependentFailuresKeepOtherEvidenceAndContinuationOffsets() throws {
        let call = LocalFileToolCall(operation: "read_batch", requests: [
            .init(operation: "read", path: "first.pdf"), .init(operation: "read", path: "missing.pdf"),
            .init(operation: "read", path: "third.pdf")])
        let result = try ReadOnlyToolBatch.execute(call, allowedOperations: ["read"]) { request in
            if request.path == "missing.pdf" { throw LocalFileToolError("PDF unavailable") }
            return try .json(["path": request.path!, "text": "[PDF page 79]\nExact equation",
                              "nextPage": 80, "nextOffset": 431, "partialDocument": true])
        }
        let results = try rows(result)
        XCTAssertEqual(results.compactMap { $0["status"] as? String }, ["ok", "error", "ok"])
        XCTAssertEqual(results.compactMap { $0["requestIndex"] as? Int }, [1, 2, 3])
        XCTAssertEqual((results[2]["result"] as? [String: Any])?["nextOffset"] as? Int, 431)
        XCTAssertTrue(result.text.contains("[PDF page 79]"))
    }

    func testResponseAllowanceDisclosesOmittedAndUnexecutedRequests() throws {
        var executed = 0
        let requests = Array(repeating: LocalFileToolCall(operation: "read"), count: 8)
        let result = try ReadOnlyToolBatch.execute(.init(operation: "read_batch", requests: requests), allowedOperations: ["read"]) { _ in
            executed += 1
            return try .json(["text": String(repeating: "x", count: 24_000), "nextOffset": 24_000])
        }
        let results = try rows(result)
        XCTAssertEqual(results.count, 8)
        XCTAssertEqual(executed, 5)
        XCTAssertEqual(results.compactMap { $0["status"] as? String }, ["ok", "ok", "ok", "ok", "omitted", "skipped", "skipped", "skipped"])
        XCTAssertLessThanOrEqual(result.text.utf16.count, ReadOnlyToolBatch.maximumResultCharacters)
    }

    func testCancellationStopsBatchBeforeFurtherReads() throws {
        var executed = 0
        XCTAssertThrowsError(try ReadOnlyToolBatch.execute(.init(operation: "read_batch", requests: [
            .init(operation: "read"), .init(operation: "read")]), allowedOperations: ["read"]) { _ in
                executed += 1
                throw CancellationError()
            }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(executed, 1)
    }

    func testAttachmentBatchPreservesExactSourcesAndRejectsExcludedUUID() async throws {
        let file = MessageAttachment(fileName: "ttk4100.slx", mimeType: "application/zip", byteCount: 50,
            extractedText: "Gain = 1000; Saturation = 240000", sourcePath: "/exact/ttk4100.slx")
        let tools = AttachmentCorpusTools(messages: [.init(role: .user, content: "Map this model", attachments: [file])])
        let result = try await tools.execute(.init(operation: "attachment_batch", requests: [
            .init(operation: "attachment_search", path: file.id.uuidString, query: "Gain"),
            .init(operation: "attachment_read", path: UUID().uuidString),
            .init(operation: "attachment_search", path: file.id.uuidString, query: "Saturation")]))
        let results = try rows(result)
        XCTAssertEqual(results.compactMap { $0["status"] as? String }, ["ok", "error", "ok"])
        XCTAssertTrue(result.text.contains("not included"))
        XCTAssertTrue(result.text.contains("240000"))
        XCTAssertEqual((results[2]["result"] as? [String: Any])?["attachmentID"] as? String, file.id.uuidString)
    }

    func testLocalBatchRespectsRevokedReadAccessAndNeverWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("evidence.txt")
        try Data("original evidence".utf8).write(to: path)
        let policy = LocalFileAccessPolicy(read: true, write: true)
        let tools = LocalFileTools(policy: policy, home: root)
        let call = LocalFileToolCall(operation: "read_batch", requests: [.init(operation: "read", path: path.path)])
        let read = try await tools.execute(call)
        XCTAssertTrue(read.text.contains("original evidence"))
        do {
            _ = try await tools.execute(.init(operation: "read_batch", requests: [
                .init(operation: "write", path: path.path, content: "changed")]))
            XCTFail("Batch must reject writes even when local write permission is on")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Writes")) }
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "original evidence")
        policy.update(read: false, write: false)
        do {
            _ = try await tools.execute(call)
            XCTFail("Batch must honor revoked read access")
        } catch { XCTAssertTrue(error.localizedDescription.contains("off")) }
    }
}
