import Foundation

enum CodexModelCatalog {
    private struct Envelope: Decodable {
        var data: [Entry]
    }
    private struct Entry: Decodable {
        struct Reasoning: Decodable { var efforts: [String]; var `default`: String? }
        var id: String
        var label: String?
        var reasoning: Reasoning?
        var supportsImages: Bool?
    }
    static func models(from data: Data) throws -> [ModelDefinition] {
        let entries = try JSONDecoder().decode(Envelope.self, from: data).data
        var seen = Set<String>()
        let models = entries.prefix(2_000).compactMap { entry -> ModelDefinition? in
            let id = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.count <= 200, seen.insert(id).inserted else { return nil }
            let efforts = Array((entry.reasoning?.efforts ?? []).filter { !$0.isEmpty && $0.count <= 40 }.prefix(12))
            let preferred = entry.reasoning?.default
            return ModelDefinition(id: id, label: String((entry.label ?? id).prefix(240)),
                reasoningEfforts: efforts,
                defaultReasoningEffort: preferred.flatMap { efforts.contains($0) ? $0 : nil } ?? efforts.first,
                supportsImages: entry.supportsImages)
        }
        guard !models.isEmpty else { throw LocalBridgeManagerError.catalogUnavailable("Codex returned no models.") }
        return models
    }
}
