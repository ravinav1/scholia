import Foundation
import XCTest
@testable import ScholiaMac

final class ModelVerificationTests: XCTestCase {
    func testEveryCatalogModelAndCustomModelCanBeVerifiedWithoutChangingSelection() throws {
        var settings = AppSettings()
        settings.quickAskProviderID = "custom"
        settings.quickAskModels = ["custom": "chat-model"]
        settings.quickAskThinkingProfiles = [
            "custom": ["deep": QuickAskThinkingProfileConfiguration(modelID: "deep-model")]
        ]
        let original = settings
        var verification = ModelVerificationState()
        for provider in ProviderCatalog.providers {
            for modelID in provider.models.map(\.id) + ["custom/Future-Model"] {
                let target = ModelTestTarget(providerID: provider.id, modelID: modelID, endpoint: provider.endpoint)
                let attempt = try XCTUnwrap(verification.begin(target))
                XCTAssertEqual(verification.results[target], .testing)
                XCTAssertTrue(verification.finish(attempt, status: .verified(Date()), settings: &settings))
                XCTAssertNotNil(settings.verifiedModel(for: provider.id, modelID: modelID))
                XCTAssertNil(verification.activeTest)
            }
        }
        XCTAssertEqual(settings.providerID, original.providerID)
        XCTAssertEqual(settings.models, original.models)
        XCTAssertEqual(settings.quickAskProviderID, original.quickAskProviderID)
        XCTAssertEqual(settings.quickAskModels, original.quickAskModels)
        XCTAssertEqual(settings.quickAskThinkingProfiles, original.quickAskThinkingProfiles)
    }

    func testSuccessStaysWithTestedEndpointWhenSettingsChangeDuringRequest() throws {
        var settings = AppSettings()
        settings.endpoints["custom"] = "http://localhost:8000/v1/chat/completions"
        let target = target(for: settings)
        var verification = ModelVerificationState()
        let attempt = try XCTUnwrap(verification.begin(target))
        settings.endpoints["custom"] = "http://localhost:9000/v1/chat/completions"
        let testedAt = Date(timeIntervalSince1970: 123)

        verification.finish(attempt, status: .verified(testedAt), settings: &settings)

        XCTAssertNil(settings.verifiedModel(for: "custom", modelID: "working"))
        settings.endpoints["custom"] = target.endpoint
        XCTAssertEqual(settings.verifiedModel(for: "custom", modelID: "working")?.testedAt, testedAt)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.verifiedModel(for: "custom", modelID: "working")?.testedAt, testedAt)
    }

    func testFailedRetestRemovesOnlyTheTestedModelAndEndpoint() throws {
        var settings = AppSettings()
        settings.endpoints["custom"] = "http://localhost:8000"
        settings.markModelVerified(providerID: "custom", modelID: "working")
        settings.markModelVerified(providerID: "custom", modelID: "other-model")
        let target = target(for: settings)
        var verification = ModelVerificationState()
        let attempt = try XCTUnwrap(verification.begin(target))
        settings.endpoints["custom"] = "http://localhost:9000"
        settings.markModelVerified(providerID: "custom", modelID: "working")

        verification.finish(attempt, status: .failed("Model is unavailable"), settings: &settings)

        XCTAssertNotNil(settings.verifiedModel(for: "custom", modelID: "working"))
        settings.endpoints["custom"] = target.endpoint
        XCTAssertNil(settings.verifiedModel(for: "custom", modelID: "working"))
        XCTAssertNotNil(settings.verifiedModel(for: "custom", modelID: "other-model"))
        XCTAssertEqual(verification.results[target], .failed("Model is unavailable"))
    }

    func testCredentialChangeInvalidatesPendingAndCompletedTestsForThatProvider() throws {
        var settings = AppSettings()
        var verification = ModelVerificationState()
        let target = target(for: settings)
        let first = try XCTUnwrap(verification.begin(target))
        verification.finish(first, status: .verified(Date()), settings: &settings)
        let pending = try XCTUnwrap(verification.begin(target))

        verification.invalidate(providerID: "custom")
        settings.removeModelVerification(providerID: "custom")

        XCTAssertFalse(verification.finish(pending, status: .verified(Date()), settings: &settings))
        XCTAssertNil(settings.verifiedModel(for: "custom", modelID: "working"))
        XCTAssertNil(verification.results[target])
        XCTAssertNil(verification.activeTest)
    }

    func testCancellationKeepsPreviousVerificationAndIgnoresLateReplies() throws {
        var settings = AppSettings()
        settings.markModelVerified(providerID: "custom", modelID: "working")
        let original = settings
        var verification = ModelVerificationState()
        let target = target(for: settings)
        let attempt = try XCTUnwrap(verification.begin(target))

        XCTAssertTrue(verification.finish(attempt, status: .cancelled, settings: &settings))
        XCTAssertFalse(verification.finish(attempt, status: .failed("Late error"), settings: &settings))
        XCTAssertEqual(settings, original)
        XCTAssertEqual(verification.results[target], .cancelled)
        XCTAssertNil(verification.activeTest)
    }

    func testDuplicateStartsAndOldRepliesDoNotInterfereWithNextTest() throws {
        var settings = AppSettings()
        var verification = ModelVerificationState()
        let target = target(for: settings)
        let first = try XCTUnwrap(verification.begin(target))
        XCTAssertNil(verification.begin(target))
        verification.finish(first, status: .cancelled, settings: &settings)
        let second = try XCTUnwrap(verification.begin(target))
        XCTAssertFalse(verification.finish(first, status: .verified(Date()), settings: &settings))
        XCTAssertEqual(verification.activeTest?.id, second.id)
        XCTAssertEqual(verification.results[target], .testing)
        XCTAssertNil(settings.verifiedModel(for: "custom", modelID: "working"))
    }

    func testSameModelIDOnDifferentProvidersHasSeparateResults() throws {
        var settings = AppSettings()
        var verification = ModelVerificationState()
        let custom = target(for: settings)
        let ollama = ModelTestTarget(providerID: "ollama", modelID: custom.modelID, endpoint: custom.endpoint)
        let first = try XCTUnwrap(verification.begin(custom))
        verification.finish(first, status: .failed("Unknown model"), settings: &settings)
        let second = try XCTUnwrap(verification.begin(ollama))
        verification.invalidate(providerID: "custom")
        let testedAt = Date()
        XCTAssertTrue(verification.finish(second, status: .verified(testedAt), settings: &settings))
        XCTAssertEqual(verification.results[ollama], .verified(testedAt))
        XCTAssertNil(verification.results[custom])
    }

    func testTargetNormalizesEndpointAndModelID() {
        XCTAssertEqual(
            ModelTestTarget(providerID: "opencode", modelID: "opencode-go/GLM-5.3-flash", endpoint: " http://localhost:4096\n"),
            ModelTestTarget(providerID: "opencode", modelID: "opencode-go/glm-5.3-flash", endpoint: "http://localhost:4096")
        )
    }

    private func target(for settings: AppSettings) -> ModelTestTarget {
        ModelTestTarget(providerID: "custom", modelID: "working", endpoint: settings.endpoints["custom"]!)
    }
}
