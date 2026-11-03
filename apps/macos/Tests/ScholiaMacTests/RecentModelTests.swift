import Foundation
import XCTest
@testable import ScholiaMac

final class RecentModelTests: XCTestCase {
    func testHistorySurvivesRestartAndKeepsProviderAndEndpointIdentity() throws {
        var settings = AppSettings()
        for n in 1...15 {
            settings.recordModelUse(providerID: "codex", modelID: "model-\(n)", endpoint: settings.endpoints["codex"]!, at: Date(timeIntervalSince1970: Double(n)))
        }
        settings.recordModelUse(providerID: "openai", modelID: "model-14", endpoint: settings.endpoints["openai"]!, at: Date(timeIntervalSince1970: 20))
        settings.recordModelUse(providerID: "codex", modelID: "model-14", endpoint: settings.endpoints["codex"]!, at: Date(timeIntervalSince1970: 21))
        let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(saved.recentModels.count, 12)
        XCTAssertEqual(saved.recentModels.prefix(2).map(\.providerID), ["codex", "openai"])
        XCTAssertEqual(saved.recentModels.prefix(2).map(\.modelID), ["model-14", "model-14"])
        settings.endpoints["codex"] = "http://localhost:9999/v1/chat/completions"
        XCTAssertEqual(settings.recentModels.map(\.providerID), ["openai"])
        XCTAssertNil(AppSettings().recentProviderModels)
    }

    func testDiscoveringFutureCodexModelPreservesReasoningAndVisionMetadata() throws {
        let data = Data(#"{"data":[{"id":"gpt-6.1-sol","label":"GPT-6.1 Sol","reasoning":{"efforts":["low","high","future"],"default":"future"},"supportsImages":false},{"id":"gpt-6.1-sol"}]}"#.utf8)
        let models = try CodexModelCatalog.models(from: data)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].id, "gpt-6.1-sol")
        XCTAssertEqual(models[0].reasoningEfforts, ["low", "high", "future"])
        XCTAssertEqual(models[0].defaultReasoningEffort, "future")
        XCTAssertEqual(models[0].supportsImages, false)
    }
}
