import Foundation

enum PaperModelMode: String, CaseIterable, Identifiable, Sendable {
    case automatic, fast, thorough
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .fast: "Fast"
        case .thorough: "Thorough"
        }
    }
    var detail: String {
        switch self {
        case .automatic: "Start fast; check possible mistakes and uncertain readings with a stronger model. Up to two calls per request."
        case .fast: "Use one fast model. Faster replies, with a greater chance of misreading or missing a mistake."
        case .thorough: "Use one stronger model for every request. Usually slower."
        }
    }
}

struct PaperTutorModelRoute: Equatable, Sendable {
    var modelID: String
    var reasoningEffort: String?
    var description: String { modelID + (reasoningEffort.map { " · \($0) reasoning" } ?? "") }
}

struct PaperTutorRoutingPlan: Sendable {
    var initial: PaperTutorModelRoute
    var verification: PaperTutorModelRoute?
    var reason: String
}

@MainActor
struct PaperTutorExecution {
    var plan: PaperTutorRoutingPlan
    var complete: @MainActor @Sendable ([ConversationMessage], PaperTutorModelRoute) async throws -> String
}

enum PaperTutorRouting {
    /// Use the same verified, endpoint-specific model choices as ordinary study
    /// routing. These are request-local overrides, never settings mutations.
    static func plan(mode: PaperModelMode, providerID: String, selectedModel: String,
        reasoningEffort: String?, availableModels: [ModelDefinition], request: String,
        helpLevel: Int) -> PaperTutorRoutingPlan {
        func route(_ tier: StudyModelMode, preferredEffort: String) -> (model: PaperTutorModelRoute, available: Bool) {
            let result = StudyModelRouter.route(mode: tier, providerID: providerID,
                selectedModel: selectedModel, reasoningEffort: reasoningEffort,
                availableModels: availableModels, question: request, hasImages: true)
            guard result.tier != "manual",
                let definition = availableModels.first(where: { $0.id == result.modelID }) else {
                return (PaperTutorModelRoute(modelID: selectedModel, reasoningEffort: reasoningEffort), false)
            }
            let effort = definition.reasoningEfforts.contains(preferredEffort) ? preferredEffort
                : definition.defaultReasoningEffort ?? definition.reasoningEfforts.first
            return (PaperTutorModelRoute(modelID: result.modelID, reasoningEffort: effort), true)
        }
        let needsDepth = helpLevel >= 2 || StudyModelRouter.classify(question: request).tier == "deep"
            || request.range(of: #"\b(?:complete|full|worked)\s+(?:worked\s+)?solution\b|\bfinal\s+answer\b"#,
                options: [.regularExpression, .caseInsensitive]) != nil
        let fast = route(.fast, preferredEffort: "low")
        let thorough = route(.deep, preferredEffort: needsDepth ? "medium" : "low")
        switch mode {
        case .fast:
            return PaperTutorRoutingPlan(initial: fast.model, verification: nil,
                reason: fast.available ? "Fast · one model call"
                    : "No verified fast route available · using your selected model")
        case .thorough:
            return PaperTutorRoutingPlan(initial: thorough.model, verification: nil,
                reason: thorough.available ? "Thorough · one model call"
                    : "No verified stronger route available · using your selected model")
        case .automatic:
            if needsDepth {
                return PaperTutorRoutingPlan(initial: thorough.model, verification: nil,
                    reason: thorough.available ? "Detailed request · using the stronger available model directly"
                        : "Detailed request · no verified stronger route; using your selected model")
            }
            guard fast.available, thorough.available, fast.model.modelID != thorough.model.modelID else {
                let fallback = thorough.available ? thorough.model
                    : PaperTutorModelRoute(modelID: selectedModel, reasoningEffort: reasoningEffort)
                return PaperTutorRoutingPlan(initial: fallback, verification: nil,
                    reason: "Fast/strong verified pair unavailable · using \(fallback.modelID); no separate stronger review")
            }
            return PaperTutorRoutingPlan(initial: fast.model, verification: thorough.model,
                reason: "Fast check first · stronger review for possible mistakes or uncertainty")
        }
    }

    static func escalationReason(_ response: PaperTutorResponse, requestedHelp: Bool = false) -> String? {
        if requestedHelp, response.feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            response.status != .obstructed {
            return "Checking an unanswered student question"
        }
        // Incomplete is intentionally not trusted just because confidence is
        // high: the live handwriting evaluation found confident false negatives.
        switch response.status {
        case .mistake: return "Verifying a possible mistake"
        case .unclear: return "Checking uncertain notation"
        case .incomplete: return "Checking whether the step is unfinished or misread"
        case .pageChange: return "Checking a possible page change"
        case .obstructed: return nil // More reasoning cannot uncover hidden ink.
        case .ok: return response.confidence < 0.9 ? "Checking an uncertain reading" : nil
        }
    }
}
