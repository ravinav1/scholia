import XCTest
@testable import ScholiaMac

final class PaperTutorRoutingTests: XCTestCase {
    private var choices: [ModelDefinition] {
        [ModelDefinition(id: "gpt-6-luna", label: "Luna", reasoningEfforts: ["low", "medium"],
            defaultReasoningEffort: "medium", supportsImages: true),
         ModelDefinition(id: "gpt-6-astra", label: "Astra", reasoningEfforts: ["low", "medium", "high"],
            defaultReasoningEffort: "medium", supportsImages: true)]
    }

    func testAutomaticUsesVerifiedFastThenStrongerAndDetailedRequestSkipsFirstCall() {
        let automatic = PaperTutorRouting.plan(mode: .automatic, providerID: "codex",
            selectedModel: "gpt-6-astra", reasoningEffort: "high", availableModels: choices,
            request: "Check my current line", helpLevel: 0)
        XCTAssertEqual(automatic.initial.modelID, "gpt-6-luna")
        XCTAssertEqual(automatic.initial.reasoningEffort, "low")
        XCTAssertEqual(automatic.verification?.modelID, "gpt-6-astra")
        XCTAssertEqual(automatic.verification?.reasoningEffort, "low")
        for question in ["Please give the complete worked solution.", "Prove this identity rigorously."] {
            let detailed = PaperTutorRouting.plan(mode: .automatic, providerID: "codex",
                selectedModel: "gpt-6-luna", reasoningEffort: "low", availableModels: choices,
                request: question, helpLevel: 0)
            XCTAssertEqual(detailed.initial.modelID, "gpt-6-astra")
            XCTAssertEqual(detailed.initial.reasoningEffort, "medium")
            XCTAssertNil(detailed.verification)
        }
    }

    func testExplicitModesUseOneCallAndUnsupportedOrUnverifiedRoutesFallBack() {
        for mode in [PaperModelMode.fast, .thorough] {
            let plan = PaperTutorRouting.plan(mode: mode, providerID: "codex", selectedModel: "custom-vision",
                reasoningEffort: nil, availableModels: choices, request: "Check this step", helpLevel: 0)
            XCTAssertEqual(plan.initial.modelID, mode == .fast ? "gpt-6-luna" : "gpt-6-astra")
            XCTAssertNil(plan.verification)
        }
        let one = PaperTutorRouting.plan(mode: .automatic, providerID: "codex", selectedModel: "gpt-6-astra",
            reasoningEffort: "medium", availableModels: Array(choices.suffix(1)), request: "Check", helpLevel: 0)
        XCTAssertEqual(one.initial.modelID, "gpt-6-astra")
        XCTAssertNil(one.verification)
        XCTAssertTrue(one.reason.contains("pair unavailable"))
        let custom = PaperTutorRouting.plan(mode: .automatic, providerID: "custom", selectedModel: "private-vision",
            reasoningEffort: "medium", availableModels: choices, request: "Check", helpLevel: 0)
        XCTAssertEqual(custom.initial.modelID, "private-vision")
        XCTAssertEqual(custom.initial.reasoningEffort, "medium")
        XCTAssertNil(custom.verification)
        var textOnly = choices
        textOnly[0].supportsImages = false
        let imageAware = PaperTutorRouting.plan(mode: .automatic, providerID: "codex", selectedModel: "gpt-6-astra",
            reasoningEffort: nil, availableModels: textOnly, request: "Check", helpLevel: 0)
        XCTAssertEqual(imageAware.initial.modelID, "gpt-6-astra")
        XCTAssertNil(imageAware.verification)
    }

    func testConfidenceCannotSuppressReviewOfIncompleteOrSuspectedErrors() {
        for status in PaperTutorResponse.Status.allCases {
            var response = PaperTutorResponse(status: status, transcription: "x", feedback: "", focus: "x",
                confidence: 0.99, issueKey: "")
            XCTAssertEqual(PaperTutorRouting.escalationReason(response) != nil,
                [.mistake, .unclear, .incomplete, .pageChange].contains(status))
            response.confidence = 0.4
            XCTAssertEqual(PaperTutorRouting.escalationReason(response) != nil, status != .obstructed)
        }
        let unanswered = PaperTutorResponse(status: .ok, transcription: "x", feedback: "", focus: "",
            confidence: 0.99, issueKey: "")
        XCTAssertNil(PaperTutorRouting.escalationReason(unanswered))
        XCTAssertNotNil(PaperTutorRouting.escalationReason(unanswered, requestedHelp: true))
    }
}
