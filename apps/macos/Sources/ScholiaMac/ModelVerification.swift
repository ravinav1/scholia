import Foundation

enum ModelPickerOrder {
    /// Capacity tiers are a presentation heuristic, not a cross-provider benchmark.
    static func sorted(_ models: [ModelDefinition], verified: Set<String>) -> [ModelDefinition] {
        models.sorted { left, right in
            if verified.contains(left.id) != verified.contains(right.id) { return verified.contains(left.id) }
            let lhs = capacity(left.id), rhs = capacity(right.id)
            if lhs != rhs { return lhs > rhs }
            let leftFamily = family(left.id), rightFamily = family(right.id)
            if leftFamily == rightFamily {
                let order = left.id.compare(right.id, options: [.numeric, .caseInsensitive])
                if order != .orderedSame { return order == .orderedDescending }
            }
            let label = left.label.localizedStandardCompare(right.label)
            return label == .orderedSame ? left.id < right.id : label == .orderedAscending
        }
    }

    private static func words(_ id: String) -> Set<String> {
        Set(id.lowercased().split { !$0.isLetter }.map(String.init))
    }
    private static func capacity(_ id: String) -> Int {
        let tokens = words(id)
        if !tokens.isDisjoint(with: ["nano", "tiny"]) { return 0 }
        if !tokens.isDisjoint(with: ["mini", "lite", "small"]) { return 1 }
        if !tokens.isDisjoint(with: ["flash", "haiku", "luna"]) { return 2 }
        if !tokens.isDisjoint(with: ["medium", "terra"]) { return 3 }
        if !tokens.isDisjoint(with: ["opus", "astra", "pro", "ultra", "max", "large"]) { return 5 }
        return 4
    }
    private static func family(_ id: String) -> String {
        let value = id.lowercased().split(separator: "/").last.map(String.init) ?? id.lowercased()
        let prefix = value.prefix { !$0.isNumber }
        return String(prefix).trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
    }
}

struct ModelTestTarget: Hashable, Sendable {
    let providerID: String
    let modelID: String
    let endpoint: String

    init(providerID: String, modelID: String, endpoint: String) {
        self.providerID = providerID
        self.modelID = ProviderCatalog.resolvedModelID(modelID, for: providerID)
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ModelTestStatus: Equatable, Sendable {
    case testing
    case verified(Date)
    case failed(String)
    case cancelled
}

/// Keeps asynchronous results attached to the connection that was actually tested.
/// Invalidated or cancelled attempts cannot later restore a verification.
struct ModelVerificationState: Sendable {
    struct Attempt: Sendable {
        let id = UUID()
        let target: ModelTestTarget
    }

    private(set) var activeTest: Attempt?
    private(set) var results: [ModelTestTarget: ModelTestStatus] = [:]

    mutating func begin(_ target: ModelTestTarget) -> Attempt? {
        guard activeTest == nil else { return nil }
        let attempt = Attempt(target: target)
        activeTest = attempt
        results[target] = .testing
        return attempt
    }

    @discardableResult
    mutating func finish(
        _ attempt: Attempt,
        status: ModelTestStatus,
        settings: inout AppSettings
    ) -> Bool {
        guard activeTest?.id == attempt.id else { return false }
        let target = attempt.target
        switch status {
        case .testing:
            return false
        case .verified(let date):
            settings.markModelVerified(
                providerID: target.providerID, modelID: target.modelID,
                endpoint: target.endpoint, testedAt: date
            )
        case .failed:
            settings.removeModelVerification(
                providerID: target.providerID, modelID: target.modelID,
                endpoint: target.endpoint
            )
        case .cancelled:
            break
        }
        results[target] = status
        activeTest = nil
        return true
    }

    mutating func invalidate(providerID: String) {
        if activeTest?.target.providerID == providerID { activeTest = nil }
        results = results.filter { $0.key.providerID != providerID }
    }
}
