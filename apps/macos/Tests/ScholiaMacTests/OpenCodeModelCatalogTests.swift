import Foundation
import XCTest
@testable import ScholiaMac

final class OpenCodeModelCatalogTests: XCTestCase {
    func testCatalogIncludesOnlyConnectedAndBuiltInProvidersWhenConnectionDataExists() throws {
        let data = Data(#"""
        {
          "connected": ["opencode-go"],
          "all": [
            {"id":"opencode","name":"OpenCode Zen","models":{"x-preview-f-free":{"id":"x-preview-f-free","name":"Ox Alpha Free (Unlimited)","variants":{"low":{},"medium":{},"high":{}}}}},
            {"id":"opencode-go","name":"OpenCode Go","models":{"ox-alpha-free":{"id":"ox-alpha-free","name":"Ox Alpha Free"},"glm-5.3-flash":{"id":"glm-5.3-flash","name":"GLM 5.3 Flash","variants":{"low":{},"medium":{},"high":{}}}}},
            {"id":"my-local","name":"My local models","source":"custom","models":{"new/model":{"name":"A newly configured model"}}},
            {"id":"unused","name":"Unused","models":{"hidden":{"id":"hidden","name":"Hidden"}}}
          ]
        }
        """#.utf8)

        let models = try OpenCodeModelCatalog.models(from: data)
        XCTAssertEqual(models.map(\.id), [
            "opencode-go/glm-5.3-flash"
        ])
        XCTAssertEqual(models[0].label, "GLM 5.3 Flash · OpenCode Go")
        XCTAssertEqual(models[0].reasoningEfforts, ["low", "medium", "high"])
        XCTAssertEqual(models[0].defaultReasoningEffort, "medium")
    }

    func testTypedModelIDResolvesToExactCatalogCasing() {
        XCTAssertEqual(
            ProviderCatalog.resolvedModelID(
                "opencode-go/GLM-5.3-flash",
                for: "opencode"
            ),
            "opencode-go/glm-5.3-flash"
        )
        XCTAssertEqual(
            ProviderCatalog.resolvedModelID(
                "FUTURE/mixed-case",
                for: "opencode",
                candidates: [ModelDefinition(id: "future/Mixed-Case", label: "Mixed Case")]
            ),
            "future/Mixed-Case"
        )
    }

    func testOlderConfigProvidersShapeIsAccepted() throws {
        let data = Data(#"{"providers":[{"id":"future","name":"Future","models":[{"id":"anything-new","name":"Anything New"}]}]}"#.utf8)
        XCTAssertEqual(try OpenCodeModelCatalog.models(from: data), [
            ModelDefinition(id: "future/anything-new", label: "Anything New · Future")
        ])
    }

    func testImageCapabilitiesSupportObjectAndModalityArrayShapes() throws {
        let data = Data(#"""
        {"connected":["future"],"all":[{"id":"future","models":{
          "vision":{"id":"vision","capabilities":{"input":{"image":true}}},
          "text":{"id":"text","capabilities":{"input":{"image":false}}},
          "array":{"id":"array","modalities":{"input":["text","image"]}}
        }}]}
        """#.utf8)
        let models = try OpenCodeModelCatalog.models(from: data)
        XCTAssertEqual(models.first(where: { $0.id == "future/vision" })?.supportsImages, true)
        XCTAssertEqual(models.first(where: { $0.id == "future/text" })?.supportsImages, false)
        XCTAssertEqual(models.first(where: { $0.id == "future/array" })?.supportsImages, true)
    }

    func testArrayVariantsAndCustomModesHaveDeterministicOrder() throws {
        let data = Data(#"""
        {"providers":[{"id":"future","models":[{
          "id":"reasoner","variants":[{"id":"ultra"},"low",{"id":"custom"},{"id":"low"}]
        }]}]}
        """#.utf8)
        let model = try XCTUnwrap(OpenCodeModelCatalog.models(from: data).first)
        XCTAssertEqual(model.reasoningEfforts, ["low", "ultra", "custom"])
        XCTAssertEqual(model.defaultReasoningEffort, "low")
    }
}
