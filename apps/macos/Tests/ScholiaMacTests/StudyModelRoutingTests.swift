import Foundation
import XCTest
@testable import ScholiaMac

final class StudyModelRoutingTests: XCTestCase {
    private let provider = ProviderCatalog.provider(id: "codex")

    private func route(
        _ question: String, mode: StudyModelMode = .auto,
        previous: [String] = [], models: [ModelDefinition]? = nil,
        contextCharacters: Int = 0, hasImages: Bool = false
    ) -> StudyModelRoute {
        StudyModelRouter.route(mode: mode, providerID: provider.id,
            selectedModel: "gpt-5.5", reasoningEffort: "high", availableModels: models ?? provider.models,
            question: question, previousQuestions: previous, contextCharacters: contextCharacters, hasImages: hasImages)
    }

    func testEverydayStudyUsesFastModelAndLowEffort() {
        for question in ["What is an eigenvector?", "Summarize this lecture", "Explain the definition of a proof"] {
            let result = route(question)
            XCTAssertEqual(result.modelID, "gpt-6-luna")
            XCTAssertEqual(result.reasoningEffort, "low")
        }
    }

    func testWorkedProblemsAndDeepReasoningUseDifferentTiers() {
        XCTAssertEqual(route("Solve this equation step by step").modelID, "gpt-6.1-sol")
        XCTAssertEqual(route("Solve this equation step by step").reasoningEffort, "medium")
        XCTAssertEqual(route("Optimize this function").tier, "balanced")
        for question in ["Prove convergence", "Derive the formula", "Check my proof", "Compare these papers"] {
            XCTAssertEqual(route(question).modelID, "gpt-6-astra")
            XCTAssertEqual(route(question).reasoningEffort, "high")
        }
    }

    func testContinuationKeepsProblemTierButNewQuestionDowngrades() {
        let previous = ["Prove convergence", "Why?", "Explain that"]
        XCTAssertEqual(route("Continue", previous: previous).tier, "deep")
        XCTAssertEqual(route("What is a vector?", previous: previous).tier, "fast")
        XCTAssertEqual(route("Continue", previous: ["Prove convergence", "What is a vector?"]).tier, "fast")
    }

    func testExtensiveContextPromotesToBalanced() {
        XCTAssertEqual(route("Summarize", contextCharacters: 80_001).tier, "balanced")
    }

    func testExplicitModesAndManualReasoningAreRespected() {
        XCTAssertEqual(route("Prove convergence", mode: .fast).tier, "fast")
        XCTAssertEqual(route("Define a vector", mode: .deep).tier, "deep")
        let manual = route("Prove convergence", mode: .manual)
        XCTAssertEqual(manual.modelID, "gpt-5.5")
        XCTAssertEqual(manual.reasoningEffort, "high")
    }

    func testRoutingNeverInventsAnUnavailableModel() {
        let fallback = provider.models.filter { $0.id == "gpt-6-sol" }
        XCTAssertEqual(route("Prove convergence", models: fallback).modelID, "gpt-6-sol")
        let unavailable = route("Prove convergence", models: [])
        XCTAssertEqual(unavailable.modelID, "gpt-5.5")
        XCTAssertEqual(unavailable.tier, "manual")
        XCTAssertTrue(unavailable.reason.contains("verified"))
    }

    func testImagesExcludeKnownTextOnlyRoutingModels() {
        let models = [
            ModelDefinition(id: "gpt-6-luna", label: "Luna", supportsImages: false),
            ModelDefinition(id: "gpt-5.4-mini", label: "Mini", supportsImages: true)
        ]
        XCTAssertEqual(route("Explain this", models: models, hasImages: true).modelID, "gpt-5.4-mini")
        XCTAssertEqual(route("Explain this", models: models).modelID, "gpt-6-luna")
    }

    func testUnknownProviderKeepsSelectedModel() {
        let result = StudyModelRouter.route(mode: .auto, providerID: "custom", selectedModel: "my-model",
            reasoningEffort: "medium", availableModels: provider.models, question: "Prove convergence")
        XCTAssertEqual(result.modelID, "my-model")
        XCTAssertEqual(result.reasoningEffort, "medium")
        XCTAssertTrue(result.reason.contains("unavailable for this provider"))
    }

    func testExistingSettingsDecodeAsManualAndNewModeRoundTrips() throws {
        var settings = AppSettings()
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).resolvedStudyModelMode, .manual)
        settings.studyModelMode = .auto
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).resolvedStudyModelMode, .auto)
    }

    @MainActor
    func testWorkspaceRoutesRequestAndPersistsReasonWithoutChangingBaseConfiguration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        workspace.createCourse(name: "Algebra", code: "")
        workspace.draft = "Prove that this sequence converges"
        let config = ProviderConfiguration(provider: provider, model: "gpt-5.5",
            endpoint: "http://127.0.0.1:8789", apiKey: "", language: .english,
            reasoningEffort: "low", fastClaudeMode: false)
        workspace.submit(configuration: config, routingMode: .auto, routingModels: provider.models) { _, selected, _ in
            XCTAssertEqual(selected.model, "gpt-6-astra")
            XCTAssertEqual(selected.reasoningEffort, "high")
            return CompletionResult(text: "Proof explanation", providerID: selected.provider.id,
                providerName: selected.provider.name, model: selected.model)
        }
        for _ in 0..<100 where workspace.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(workspace.isStreaming)
        XCTAssertEqual(config.model, "gpt-5.5")
        XCTAssertEqual(config.reasoningEffort, "low")
        XCTAssertEqual(workspace.messages.last?.modelRouting?.tier, "deep")
        XCTAssertEqual(workspace.messages.last?.modelRouting?.modelID, "gpt-6-astra")
        XCTAssertTrue(workspace.messages.last?.activity?.contains { $0.title.contains("Auto study selected") } == true)
    }
}
