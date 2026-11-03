import Foundation
import XCTest
@testable import ScholiaMac

final class ConversationHistoryWriterTests: XCTestCase {
    private func conversation(_ title: String) -> StoredConversation {
        StoredConversation(id: UUID(), title: title, createdAt: Date(), updatedAt: Date(),
            capture: nil, messages: [ConversationMessage(role: .user, content: title)])
    }

    func testSlowWriteDoesNotBlockSubmissionAndClearSupersedesQueuedSaves() throws {
        let probe = WriteProbe()
        let writer = ConversationHistoryWriter { values in probe.write(values) }
        writer.save([conversation("first")])
        XCTAssertEqual(probe.started.wait(timeout: .now() + 2), .success)
        // The disk operation is deliberately blocked. These submissions must
        // return without waiting and obsolete snapshots must not be encoded.
        for number in 0..<100 { writer.save([conversation("queued \(number)")]) }
        writer.save([])
        probe.release.signal()
        try writer.flush()
        XCTAssertEqual(probe.titles, [["first"], []])
    }

    func testClearCannotBeUndoneByAnOlderSaveAndNewHistoryCanFollowIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("chats.json")
        let writer = ConversationHistoryWriter { values in
            if values.isEmpty { try ConversationStore.clear(at: url) }
            else { try ConversationStore.save(values, to: url) }
        }
        writer.save([conversation("old")])
        writer.save([])
        try writer.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let new = conversation("new")
        writer.save([new])
        try writer.flush()
        XCTAssertEqual(ConversationStore.load(from: url).map(\.id), [new.id])
    }

    func testFlushReportsFailureUntilALaterWriteSucceeds() throws {
        let writer = ConversationHistoryWriter { values in
            if !values.isEmpty { throw CocoaError(.fileWriteOutOfSpace) }
        }
        writer.save([conversation("failed")])
        XCTAssertThrowsError(try writer.flush())
        XCTAssertThrowsError(try writer.flush())
        writer.save([])
        XCTAssertNoThrow(try writer.flush())
    }
}

private final class WriteProbe: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var writes: [[String]] = []
    var titles: [[String]] { lock.withLock { writes } }
    func write(_ values: [StoredConversation]) {
        let first = lock.withLock {
            writes.append(values.map(\.title))
            return writes.count == 1
        }
        if first {
            started.signal()
            // Bound failures so a regression cannot hang the test runner.
            _ = release.wait(timeout: .now() + 5)
        }
    }
}
