import Foundation
import CoreFoundation

/// Measured provider usage, never an estimate of subscription allowance.
struct CompletionUsage: Codable, Equatable, Sendable {
    var inputTokens: Int? = nil
    var cachedInputTokens: Int? = nil
    var outputTokens: Int? = nil
    var elapsedSeconds: Double? = nil
    var requestCount: Int = 1

    var totalTokens: Int? {
        guard let inputTokens, let outputTokens else { return nil }
        let sum = inputTokens.addingReportingOverflow(outputTokens)
        return sum.overflow ? nil : sum.partialValue
    }

    func adding(_ other: CompletionUsage) -> CompletionUsage {
        // A missing counter on any request makes the complete turn total unknown.
        func sum(_ left: Int?, _ right: Int?) -> Int? {
            guard let left, let right else { return nil }
            let result = left.addingReportingOverflow(right)
            return result.overflow ? nil : result.partialValue
        }
        return CompletionUsage(
            inputTokens: sum(inputTokens, other.inputTokens),
            cachedInputTokens: sum(cachedInputTokens, other.cachedInputTokens),
            outputTokens: sum(outputTokens, other.outputTokens),
            elapsedSeconds: elapsedSeconds.flatMap { left in other.elapsedSeconds.map { left + $0 } },
            requestCount: requestCount + other.requestCount
        )
    }

    /// SSE usage frames are cumulative snapshots, not additional requests.
    func mergingSnapshot(_ newer: CompletionUsage) -> CompletionUsage {
        CompletionUsage(inputTokens: newer.inputTokens ?? inputTokens,
            cachedInputTokens: newer.cachedInputTokens ?? cachedInputTokens,
            outputTokens: newer.outputTokens ?? outputTokens,
            elapsedSeconds: newer.elapsedSeconds ?? elapsedSeconds,
            requestCount: max(requestCount, newer.requestCount))
    }

    static func from(_ event: [String: Any]) -> CompletionUsage? {
        let response = event["response"] as? [String: Any] ?? event
        let usage = response["usage"] as? [String: Any] ?? [:]
        let details = usage["prompt_tokens_details"] as? [String: Any]
            ?? usage["input_tokens_details"] as? [String: Any] ?? [:]
        let timing = event["scholia_usage"] as? [String: Any] ?? [:]
        func count(_ value: Any?) -> Int? {
            guard let number = numeric(value), number >= 0, number.rounded(.down) == number,
                  number < Double(Int.max) else { return nil }
            return Int(number)
        }
        let input = count(usage["prompt_tokens"] ?? usage["input_tokens"])
        var cached = count(details["cached_tokens"] ?? usage["cached_input_tokens"])
        if let input, let cachedValue = cached, cachedValue > input { cached = nil }
        let output = count(usage["completion_tokens"] ?? usage["output_tokens"])
        let elapsed = numeric(timing["elapsed_seconds"]).flatMap { $0 >= 0 ? $0 : nil }
        guard input != nil || cached != nil || output != nil || elapsed != nil else { return nil }
        return CompletionUsage(inputTokens: input, cachedInputTokens: cached, outputTokens: output, elapsedSeconds: elapsed)
    }

    fileprivate static func numeric(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}

struct CodexUsageWindow: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var usedPercent: Double
    var windowDurationMinutes: Int? = nil
    var resetsAt: Date? = nil
    var remainingPercent: Double { max(0, min(100, 100 - usedPercent)) }
    var label: String {
        guard let minutes = windowDurationMinutes else { return id == "primary" ? "Session" : "Extended" }
        if minutes == 10_080 { return "Weekly" }
        if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440)-day" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}

struct CodexUsageSnapshot: Codable, Equatable, Sendable {
    var windows: [CodexUsageWindow]
    var fetchedAt: Date
    var planType: String? = nil
    var limitName: String? = nil

    static func from(_ data: Data, now: Date = Date()) throws -> CodexUsageSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["ok"] as? Bool != false else {
            throw ProviderClientError.invalidResponse("Codex usage is unavailable.")
        }
        let byID = root["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        // Never assign an arbitrary model-specific budget to the whole account.
        let limits = root["rateLimits"] as? [String: Any] ?? byID["codex"]
            ?? (byID.count == 1 ? byID.values.first : nil) ?? [:]
        let windows = ["primary", "secondary"].compactMap { id -> CodexUsageWindow? in
            guard let window = limits[id] as? [String: Any],
                  let used = CompletionUsage.numeric(window["usedPercent"]), used >= 0, used <= 100 else { return nil }
            let duration = CompletionUsage.numeric(window["windowDurationMins"]).flatMap { minutes in
                minutes > 0 && minutes < Double(Int.max) && minutes.rounded(.down) == minutes ? Int(minutes) : nil
            }
            let reset = CompletionUsage.numeric(window["resetsAt"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return CodexUsageWindow(id: id, usedPercent: used, windowDurationMinutes: duration, resetsAt: reset)
        }
        guard !windows.isEmpty else {
            throw ProviderClientError.invalidResponse("Codex has not provided an account usage percentage.")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fetchedAt = (root["fetchedAt"] as? String).flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } ?? now
        return CodexUsageSnapshot(windows: windows, fetchedAt: fetchedAt,
            planType: limits["planType"] as? String, limitName: limits["limitName"] as? String)
    }
}
