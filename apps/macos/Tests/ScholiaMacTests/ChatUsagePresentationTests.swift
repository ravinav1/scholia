import Foundation
import XCTest
@testable import ScholiaMac

final class ChatUsagePresentationTests: XCTestCase {
    func testOldConversationsDecodeWithoutUsage() throws {
        let json = #"{"id":"880730B1-28D8-4C21-B24E-E52160271F66","role":"assistant","content":"Existing answer","isStreaming":false}"#
        let message = try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8))
        XCTAssertNil(message.usage)
        XCTAssertNil(message.responseDurationSeconds)
        XCTAssertEqual(ChatUsagePresentation.summary(usage: message.usage, duration: nil), "")
    }

    func testMeasuredUsageSurvivesHistorySanitizationAndRoundTrip() throws {
        let usage = CompletionUsage(inputTokens: 21_000, cachedInputTokens: 14_000,
            outputTokens: 3_000, elapsedSeconds: 390, requestCount: 3)
        let original = ConversationMessage(role: .assistant, content: "Answer", usage: usage, responseDurationSeconds: 400)
        let sanitized = try XCTUnwrap(StoredConversation.sanitizedMessages([original]).first)
        let restored = try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(sanitized))
        XCTAssertEqual(restored.usage, usage)
        XCTAssertEqual(restored.responseDurationSeconds, 400)
        XCTAssertEqual(restored.usage?.totalTokens, 24_000, "Cached tokens are already included in input")
        XCTAssertTrue(ChatUsagePresentation.summary(usage: usage, duration: 400).hasPrefix("6m 40s"))
    }

    func testUnavailableUsageDoesNotBecomeZeroOrAnAllowanceEstimate() {
        XCTAssertEqual(ChatUsagePresentation.summary(usage: nil, duration: 400), "6m 40s")
        let partial = ChatUsagePresentation.summary(usage: CompletionUsage(outputTokens: 321), duration: nil)
        XCTAssertEqual(partial, "321 output tokens")
        XCTAssertNil(ChatUsagePresentation.duration(.nan))
        XCTAssertNil(ChatUsagePresentation.duration(-1))
        XCTAssertEqual(ChatUsagePresentation.duration(0.4), "<1s")
    }

    func testAllowanceBecomesStaleAtResetAndAfterMissedRefreshes() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = CodexUsageSnapshot(windows: [CodexUsageWindow(id: "primary", usedPercent: 25,
            windowDurationMinutes: 300, resetsAt: now.addingTimeInterval(30))], fetchedAt: now)
        XCTAssertFalse(ChatUsagePresentation.isStale(snapshot, now: now))
        XCTAssertTrue(ChatUsagePresentation.isStale(snapshot, now: now.addingTimeInterval(30)))
        let noReset = CodexUsageSnapshot(windows: [CodexUsageWindow(id: "primary", usedPercent: 25)], fetchedAt: now)
        XCTAssertTrue(ChatUsagePresentation.isStale(noReset, now: now.addingTimeInterval(121)))
    }
}
