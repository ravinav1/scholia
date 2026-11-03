import XCTest
@testable import ScholiaMac

final class CompletionUsageTests: XCTestCase {
    func testTokenUsageCountsCacheInsideInputAndAggregatesAllModelRequests() throws {
        let first = try XCTUnwrap(CompletionUsage.from([
            "usage": ["prompt_tokens": 1000, "completion_tokens": 200, "prompt_tokens_details": ["cached_tokens": 800]],
            "scholia_usage": ["elapsed_seconds": 20.5]
        ]))
        XCTAssertEqual(first.totalTokens, 1200)
        XCTAssertEqual(first.cachedInputTokens, 800)
        let second = CompletionUsage(inputTokens: 2000, cachedInputTokens: 1500, outputTokens: 600, elapsedSeconds: 40)
        let total = first.adding(second)
        XCTAssertEqual(total.totalTokens, 3800)
        XCTAssertEqual(total.cachedInputTokens, 2300)
        XCTAssertEqual(total.elapsedSeconds, 60.5)
        XCTAssertEqual(total.requestCount, 2)
        XCTAssertEqual(first.mergingSnapshot(first), first, "Repeated SSE snapshots must not double token totals")
        XCTAssertNil(first.adding(CompletionUsage(elapsedSeconds: 10)).inputTokens)
    }

    func testMissingAndInvalidUsageIsNotShownAsZero() throws {
        XCTAssertNil(CompletionUsage.from([:]))
        XCTAssertNil(CompletionUsage.from(["usage": ["prompt_tokens": true, "completion_tokens": -2]]))
        XCTAssertNil(CompletionUsage.from(["usage": ["prompt_tokens": "123"]]))
        let partial = try XCTUnwrap(CompletionUsage.from(["usage": ["input_tokens": 10, "input_tokens_details": ["cached_tokens": 15]]]))
        XCTAssertEqual(partial.inputTokens, 10)
        XCTAssertNil(partial.cachedInputTokens)
        XCTAssertNil(partial.totalTokens)
        XCTAssertEqual(CompletionUsage.from(["usage": ["completion_tokens": 0]])?.outputTokens, 0)
    }

    func testJSONCompletionPreservesUsageAndReasoning() throws {
        let provider = try XCTUnwrap(ProviderCatalog.provider(id: "codex"))
        let data = Data(#"{"choices":[{"message":{"content":"An answer","reasoning_content":"A summary"}}],"usage":{"prompt_tokens":50,"completion_tokens":25,"prompt_tokens_details":{"cached_tokens":40}},"scholia_usage":{"elapsed_seconds":4}}"#.utf8)
        let output = try ProviderClient().outputFromJSON(data, provider: provider)
        XCTAssertEqual(output.text, "An answer")
        XCTAssertEqual(output.reasoning, "A summary")
        XCTAssertEqual(output.usage?.totalTokens, 75)
        XCTAssertEqual(output.usage?.elapsedSeconds, 4)
    }

    func testQuotaWindowsPreserveResetAndObservationDates() throws {
        let data = Data(#"{"ok":true,"fetchedAt":"2026-10-22T09:00:00.000Z","rateLimits":{"planType":"pro","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":45,"windowDurationMins":10080}}}"#.utf8)
        let snapshot = try CodexUsageSnapshot.from(data)
        XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [88, 55])
        XCTAssertEqual(snapshot.windows.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(snapshot.windows.first?.resetsAt, Date(timeIntervalSince1970: 1800000000))
        XCTAssertEqual(snapshot.planType, "pro")
        XCTAssertEqual(snapshot.fetchedAt, ISO8601DateFormatter().date(from: "2026-10-22T09:00:00Z"))
        let restored = try JSONDecoder().decode(CodexUsageSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored, snapshot)
    }

    func testQuotaNeverGuessesMissingOrAmbiguousBudget() throws {
        for json in [#"{"ok":true}"#, #"{"rateLimits":{"primary":{"usedPercent":null}}}"#,
                     #"{"rateLimits":{"primary":{"usedPercent":false}}}"#,
                     #"{"rateLimitsByLimitId":{"a":{"primary":{"usedPercent":10}},"b":{"primary":{"usedPercent":20}}}}"#] {
            XCTAssertThrowsError(try CodexUsageSnapshot.from(Data(json.utf8)))
        }
        let codex = try CodexUsageSnapshot.from(Data(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":0}},"other":{"primary":{"usedPercent":90}}}}"#.utf8))
        XCTAssertEqual(codex.windows.first?.remainingPercent, 100)
    }
}
