import Foundation

enum OpenCodeModelCatalogError: LocalizedError {
    case malformed
    case empty

    var errorDescription: String? {
        switch self {
        case .malformed: "OpenCode returned a malformed model catalog."
        case .empty: "OpenCode did not report any usable models."
        }
    }
}

enum OpenCodeModelCatalog {
    private static let maximumModels = 2_000

    static func models(from data: Data) throws -> [ModelDefinition] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenCodeModelCatalogError.malformed
        }
        let root = object["data"] as? [String: Any] ?? object
        let providers = root["all"] as? [[String: Any]]
            ?? root["providers"] as? [[String: Any]]
            ?? []
        let connectedValues = root["connected"] as? [Any]
        let connected = Set((connectedValues ?? []).compactMap { value -> String? in
            let id = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        })
        var seen = Set<String>()
        var result: [ModelDefinition] = []

        for provider in providers {
            guard provider["enabled"] as? Bool != false,
                  let providerID = (provider["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !providerID.isEmpty else { continue }
            if connectedValues != nil,
               !connected.contains(providerID),
               providerID != "opencode",
               providerID != "opencode-go" { continue }

            let providerName = ((provider["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap { $0.isEmpty ? nil : $0 } ?? providerID
            let values: [[String: Any]]
            if let dictionary = provider["models"] as? [String: Any] {
                values = dictionary.keys.sorted().compactMap { key in
                    guard var model = dictionary[key] as? [String: Any] else { return nil }
                    if model["id"] == nil && model["modelID"] == nil { model["id"] = key }
                    return model
                }
            } else {
                values = provider["models"] as? [[String: Any]] ?? []
            }

            for model in values {
                guard model["enabled"] as? Bool != false else { continue }
                let rawID = ((model["id"] as? String) ?? (model["modelID"] as? String) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rawID.isEmpty, rawID.count <= 200 else { continue }
                let id = rawID.hasPrefix("\(providerID)/") ? rawID : "\(providerID)/\(rawID)"
                guard id.count <= 200,
                      !ProviderCatalog.isRetiredModelID(id, for: "opencode"),
                      seen.insert(id).inserted else { continue }
                let name = ((model["name"] as? String) ?? (model["label"] as? String) ?? rawID)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let label = providerName == providerID ? name : "\(name) · \(providerName)"
                let rawVariants: [String]
                if let dictionary = model["variants"] as? [String: Any] {
                    rawVariants = dictionary.keys
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && $0.count <= 40 }
                } else if let values = model["variants"] as? [Any] {
                    rawVariants = values.compactMap { value in
                        let raw = (value as? String)
                            ?? (value as? [String: Any])?["id"] as? String
                        let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        return clean.isEmpty || clean.count > 40 ? nil : clean
                    }
                } else {
                    rawVariants = []
                }
                let preferredOrder = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
                let variants = Array(Set(rawVariants)).sorted { left, right in
                    let leftIndex = preferredOrder.firstIndex(of: left) ?? preferredOrder.count
                    let rightIndex = preferredOrder.firstIndex(of: right) ?? preferredOrder.count
                    return leftIndex == rightIndex ? left < right : leftIndex < rightIndex
                }
                let defaultVariant = variants.contains("medium") ? "medium" : variants.first
                result.append(ModelDefinition(
                    id: id,
                    label: label,
                    reasoningEfforts: variants,
                    defaultReasoningEffort: defaultVariant,
                    supportsImages: imageSupport(model: model)
                ))
                if result.count >= maximumModels { return result }
            }
        }
        guard !result.isEmpty else { throw OpenCodeModelCatalogError.empty }
        return result
    }

    /// Reads the catalog's advertised image capability. A missing or null
    /// value keeps the model's support unknown (nil), not false.
    private static func imageSupport(model: [String: Any]) -> Bool? {
        let capabilities = model["capabilities"] as? [String: Any]
        if let image = booleanImageCapability(capabilities?["input"]) { return image }
        if let attachment = capabilities?["attachment"] as? Bool { return attachment }
        if let image = booleanImageCapability(model["modalities"]) { return image }
        if let modalities = model["modalities"] as? [String: Any],
           let image = booleanImageCapability(modalities["input"]) { return image }
        if let image = booleanImageCapability(model["input"]) { return image }
        return nil
    }

    private static func booleanImageCapability(_ value: Any?) -> Bool? {
        if let values = value as? [String] {
            return values.map { $0.lowercased() }.contains("image")
        }
        if let values = value as? [Any] {
            let normalized = values.compactMap { ($0 as? String)?.lowercased() }
            return normalized.isEmpty ? nil : normalized.contains("image")
        }
        if let dictionary = value as? [String: Any] {
            if let image = dictionary["image"] as? Bool { return image }
            if let inputs = dictionary["input"] { return booleanImageCapability(inputs) }
        }
        return nil
    }
}
