import Foundation

enum StudyModelMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case manual, auto, fast, deep

    var id: String { rawValue }
    var label: String {
        switch self {
        case .manual: "Manual"
        case .auto: "Auto study"
        case .fast: "Fast"
        case .deep: "Deep"
        }
    }
    var detail: String {
        switch self {
        case .manual: "Use your selected model and reasoning level."
        case .auto: "Use a fast model for everyday study and more reasoning for harder questions."
        case .fast: "Prefer a quick model for explanations, recall, and summaries."
        case .deep: "Prefer the strongest available model for proofs and difficult problems."
        }
    }
}

struct StudyModelRoute: Codable, Equatable, Sendable {
    var mode: StudyModelMode
    var modelID: String
    var reasoningEffort: String?
    var tier: String
    var reason: String

    var description: String {
        "\(mode.label) · \(modelID)"
            + (reasoningEffort.map { " · \($0) reasoning" } ?? "")
            + " · \(reason)"
    }
}

/// Local routing avoids a paid classification call. Only the supplied models
/// may be chosen; the app supplies models verified for the active endpoint.
enum StudyModelRouter {
    static func classify(
        question: String, previousQuestions: [String] = [], contextCharacters: Int = 0
    ) -> (tier: String, reason: String) {
        let current = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = previousQuestions.suffix(4).reversed().first { !isContinuation($0) }
            ?? previousQuestions.last ?? ""
        let text = String((isContinuation(current)
            ? String(previous.prefix(12_000)) + "\n" + current : current).prefix(16_000))
        if matches(
            #"\b(?:prove|disprove|derive|derivation|counterexample|rigorous|rigorously)\b|\b(?:check|verify|critique|construct|write|give|find)\b[^.!?\n]{0,70}\bproof\b|\b(?:synthesi[sz]e|reconcile)\b|\b(?:compare|connect|integrate)\b[^.!?\n]{0,100}\b(?:readings|papers|sources|theories)\b"#,
            in: text) {
            return ("deep", "Proof, derivation, or synthesis across sources")
        }
        if matches(
            #"\b(?:solve|calculate|compute|evaluate|debug|analy[sz]e|optimi[sz]e|integrate|differentiate)\b|\b(?:step.by.step|multi.step|worked example|check my (?:work|answer|solution)|compare|trade.?offs)\b"#,
            in: text) {
            return ("balanced", "Worked problem or analysis")
        }
        if current.count > 3_000 || contextCharacters > 80_000 {
            return ("balanced", "Long question or extensive source context")
        }
        return ("fast", "Everyday explanation, recall, or summary")
    }

    static func route(
        mode: StudyModelMode, providerID: String, selectedModel: String,
        reasoningEffort: String? = nil, availableModels: [ModelDefinition],
        question: String, previousQuestions: [String] = [],
        contextCharacters: Int = 0, hasImages: Bool = false
    ) -> StudyModelRoute {
        func unchanged(_ reason: String) -> StudyModelRoute {
            StudyModelRoute(mode: mode, modelID: selectedModel, reasoningEffort: reasoningEffort,
                tier: "manual", reason: reason)
        }
        guard mode != .manual else { return unchanged("Selected model") }
        guard let choices = candidates[providerID] else {
            return unchanged("Automatic routing is unavailable for this provider; using your selected model")
        }
        let classification = mode == .auto
            ? classify(question: question, previousQuestions: previousQuestions, contextCharacters: contextCharacters)
            : (tier: mode.rawValue, reason: mode == .fast ? "Fast mode selected" : "Deep mode selected")
        _ = choices
        guard let choice = tierChoice(tier: classification.tier, providerID: providerID,
            availableModels: availableModels, hasImages: hasImages) else {
            return unchanged("No suitable verified routing model is available; using your selected model")
        }
        return StudyModelRoute(mode: mode, modelID: choice.model.id, reasoningEffort: choice.reasoningEffort,
            tier: classification.tier, reason: classification.reason)
    }

    static let tiers = ["fast", "balanced", "deep"]
    static func tierLabel(_ tier: String) -> String {
        switch tier {
        case "fast": "Everyday"
        case "balanced": "Problems"
        case "deep": "Proofs"
        default: tier.capitalized
        }
    }
    private static let tierEfforts = ["fast": "low", "balanced": "medium", "deep": "high"]

    /// The verified model and reasoning level a tier uses for a provider. The
    /// mode picker shows this so the choice is visible before a question is sent.
    static func tierChoice(
        tier: String, providerID: String, availableModels: [ModelDefinition], hasImages: Bool = false
    ) -> (model: ModelDefinition, reasoningEffort: String?)? {
        guard let ids = candidates[providerID]?[tier],
            let definition = ids.compactMap({ id in availableModels.first(where: { $0.id == id }) })
                .first(where: { !hasImages || $0.supportsImages != false }) else { return nil }
        let effort = tierEfforts[tier].flatMap { definition.reasoningEfforts.contains($0) ? $0 : nil }
            ?? definition.defaultReasoningEffort.flatMap { definition.reasoningEfforts.contains($0) ? $0 : nil }
            ?? definition.reasoningEfforts.first
        return (definition, effort)
    }
    static func supportsRouting(providerID: String) -> Bool { candidates[providerID] != nil }

    private static func matches(_ expression: String, in text: String) -> Bool {
        text.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func isContinuation(_ question: String) -> Bool {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count < 180 && matches(
            #"^(?:why\b|how so\b|continue\b|go on\b|explain (?:that|this|it|the (?:last|next) step)\b|what (?:about|if)\b|and\b|try again\b|check (?:that|this|it)\b|that(?:'s| is) (?:wrong|incorrect)\b)"#,
            in: text)
    }

    private static let candidates: [String: [String: [String]]] = [
        "openai": [
            "fast": ["gpt-6-luna", "gpt-5-mini", "gpt-4.1-mini"],
            "balanced": ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.5", "gpt-5"],
            "deep": ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-5.5", "o3"]
        ],
        "codex": [
            "fast": ["gpt-6-luna", "gpt-5.6-luna", "gpt-5.4-mini"],
            "balanced": ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol", "gpt-5.5"],
            "deep": ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol", "gpt-5.5"]
        ],
        "anthropic": [
            "fast": ["claude-haiku-4-5-20251001", "claude-sonnet-4-6"],
            "balanced": ["claude-sonnet-4-6", "claude-opus-4-8"],
            "deep": ["claude-opus-4-8", "claude-opus-4-7", "claude-sonnet-4-6"]
        ],
        "claudecode": ["fast": ["haiku", "sonnet"], "balanced": ["sonnet", "opus"], "deep": ["opus", "sonnet"]]
    ]
}
