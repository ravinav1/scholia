import Foundation

/// Batches known, independent source locations into one model round trip.
/// Source operations retain their own authorization, limits, and provenance.
enum ReadOnlyToolBatch {
    static let maximumRequests = 8
    static let maximumResultCharacters = 120_000

    static func execute(_ call: LocalFileToolCall, allowedOperations: Set<String>,
                        operation: (LocalFileToolCall) throws -> LocalFileToolResult) throws -> LocalFileToolResult {
        guard let requests = call.requests, !requests.isEmpty, requests.count <= maximumRequests else {
            throw LocalFileToolError("A read batch must contain 1–\(maximumRequests) independent requests.")
        }
        guard requests.allSatisfy({ allowedOperations.contains($0.operation) && $0.requests == nil }) else {
            throw LocalFileToolError("A read batch may contain only \(allowedOperations.sorted().joined(separator: ", ")) operations. Writes and nested batches are not allowed.")
        }
        var results: [[String: Any]] = []
        var limited = false
        for (index, request) in requests.enumerated() {
            try Task.checkCancellation()
            let identity: [String: Any] = ["requestIndex": index + 1, "operation": request.operation]
            var entry = identity
            if limited {
                entry["status"] = "skipped"
                entry["error"] = "Batch response limit reached. This request was not executed; request it separately only if needed."
            } else {
                do {
                    let result = try operation(request)
                    guard result.imageData == nil else {
                        throw LocalFileToolError("Images must be requested individually; no image is included in this batch result.")
                    }
                    entry["result"] = try JSONSerialization.jsonObject(with: Data(result.text.utf8))
                    entry["status"] = "ok"
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    entry["status"] = "error"
                    entry["error"] = TextInputPolicy.bounded(error.localizedDescription, maximumUTF16Units: 1_000)
                }
                // Leave space for all remaining skipped statuses and the envelope.
                let candidate = try LocalFileToolResult.json(["results": results + [entry]])
                if candidate.text.utf16.count > maximumResultCharacters - 4_000 {
                    limited = true
                    entry = identity
                    entry["status"] = "omitted"
                    entry["error"] = "This result exceeded the remaining batch response allowance and is not included. Request this location separately if needed; do not treat its contents as read evidence."
                }
            }
            results.append(entry)
        }
        return try .json(["operation": call.operation, "requestedCount": requests.count,
                         "results": results, "responseLimited": limited,
                         "note": "Results use 1-based requestIndex. Each successful result retains its original source identity, reading limits, and continuation offsets. Only included results are evidence; errors, omitted results, and skipped requests are not evidence of absence."])
    }
}
