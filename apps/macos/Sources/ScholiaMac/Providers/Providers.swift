import Foundation

enum ProviderProtocol: String, Codable, Sendable {
    case openAI
    case anthropic
    case cohere
    case ollama
    case opencode
}

struct ModelDefinition: Identifiable, Hashable, Sendable {
    var id: String
    var label: String
    var reasoningEfforts: [String] = []
    var defaultReasoningEffort: String?
    /// Nil when the model's image support is unknown. opencode reports this
    /// per model; GLM 5.3, for example, accepts text only.
    var supportsImages: Bool? = nil
}

struct LocalBridgeDefinition: Hashable, Sendable {
    var label: String
    var healthPath: String
    var startURL: String?
    var startCommand: String
    var imageSupportComesFromHealth = false
}

struct ProviderDefinition: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var protocolKind: ProviderProtocol
    var endpoint: String
    var keyRequired: Bool
    var keyHint: String
    var supportsImages: Bool
    var defaultModel: String
    var models: [ModelDefinition]
    var bridge: LocalBridgeDefinition?

    func model(named id: String) -> ModelDefinition? {
        models.first { $0.id == id }
    }

    var shortName: String {
        if let parenIndex = name.firstIndex(of: "(") {
            name[..<parenIndex].trimmingCharacters(in: .whitespaces)
        } else {
            name
        }
    }
}

enum ProviderCatalog {
    private static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    private static let codexEfforts = ["minimal", "low", "medium", "high", "xhigh", "max"]
    private static let openCodeModelReplacements = [
        "opencode-go/ox-alpha-free": "opencode-go/glm-5.3-flash",
        "opencode/x-preview-f-free": "opencode-go/glm-5.3-flash"
    ]

    static let providers: [ProviderDefinition] = [
        ProviderDefinition(
            id: "anthropic", name: "Anthropic", protocolKind: .anthropic,
            endpoint: "https://api.anthropic.com/v1/messages", keyRequired: true,
            keyHint: "sk-ant-…", supportsImages: true, defaultModel: "claude-sonnet-4-6",
            models: strings(["claude-opus-4-8", "claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"])
        ),
        ProviderDefinition(
            id: "openai", name: "OpenAI", protocolKind: .openAI,
            endpoint: "https://api.openai.com/v1/chat/completions", keyRequired: true,
            keyHint: "sk-…", supportsImages: true, defaultModel: "gpt-5-mini",
            models: [
                reasoning("gpt-6-astra", "GPT-6 Astra", ["low", "medium", "high", "xhigh", "max"], "medium"),
                reasoning("gpt-6.1-sol", "GPT-6.1 Sol", ["low", "medium", "high", "xhigh", "max"], "medium"),
                reasoning("gpt-6-sol", "GPT-6 Sol", ["none", "low", "medium", "high", "xhigh", "max"], "medium"),
                reasoning("gpt-6-luna", "GPT-6 Luna", ["none", "low", "medium", "high", "xhigh", "max"], "medium")
            ] + strings([
                "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
                "gpt-5.5", "gpt-5", "gpt-5-mini", "gpt-5-nano",
                "gpt-4.1", "gpt-4.1-mini", "o3", "o4-mini"
            ])
        ),
        ProviderDefinition(
            id: "ntnu", name: "GPT NTNU", protocolKind: .openAI,
            endpoint: "https://llm.hpc.ntnu.no/v1/chat/completions", keyRequired: true,
            keyHint: "Personal NTNU LLM API key", supportsImages: true,
            defaultModel: "openai/gpt-oss-120b",
            models: [
                ModelDefinition(
                    id: "openai/gpt-oss-120b",
                    label: "GPT OSS 120B",
                    supportsImages: false
                ),
                ModelDefinition(
                    id: "moonshotai/Kimi-K2.6",
                    label: "Kimi K2.6",
                    supportsImages: true
                ),
                ModelDefinition(
                    id: "NorwAI/NorwAI-Magistral-24B-reasoning",
                    label: "NorwAI Magistral 24B Reasoning",
                    supportsImages: false
                ),
                ModelDefinition(
                    id: "norallm/normistral-11b-thinking",
                    label: "NorMistral 11B Thinking",
                    supportsImages: false
                ),
                ModelDefinition(
                    id: "NbAiLab/borealis-27b",
                    label: "Borealis 27B",
                    supportsImages: false
                ),
                ModelDefinition(
                    id: "Qwen/Qwen3.8-27B-FP8",
                    label: "Qwen 3.8 27B FP8",
                    supportsImages: true
                ),
                ModelDefinition(
                    id: "Inferact/GLM-5.3-NVFP4",
                    label: "GLM 5.3 NVFP4",
                    supportsImages: false
                ),
                ModelDefinition(
                    id: "mistralai/Mistral-Medium-3.5-128B",
                    label: "Mistral Medium 3.5 128B",
                    supportsImages: true
                ),
                ModelDefinition(
                    id: "deepseek-ai/DeepSeek-V4-Flash-Vision-Exp",
                    label: "DeepSeek V4 Flash Vision (demo)",
                    supportsImages: true
                ),
                ModelDefinition(
                    id: "zai-org/GLM-5.3-Flash",
                    label: "GLM 5.3 Flash (demo)",
                    supportsImages: true
                )
            ]
        ),
        ProviderDefinition(
            id: "openrouter", name: "OpenRouter", protocolKind: .openAI,
            endpoint: "https://openrouter.ai/api/v1/chat/completions", keyRequired: true,
            keyHint: "sk-or-…", supportsImages: true, defaultModel: "anthropic/claude-sonnet-4.6",
            models: strings([
                "anthropic/claude-opus-4.8", "anthropic/claude-sonnet-4.6", "openai/gpt-5.5",
                "openai/gpt-5-mini", "openai/gpt-oss-20b:free", "google/gemini-3.5-flash",
                "google/gemini-2.5-pro", "deepseek/deepseek-v4-pro"
            ])
        ),
        ProviderDefinition(
            id: "groq", name: "Groq", protocolKind: .openAI,
            endpoint: "https://api.groq.com/openai/v1/chat/completions", keyRequired: true,
            keyHint: "gsk_…", supportsImages: true,
            defaultModel: "meta-llama/llama-4-maverick-17b-128e-instruct",
            models: strings([
                "meta-llama/llama-4-maverick-17b-128e-instruct",
                "meta-llama/llama-4-scout-17b-16e-instruct", "llama-3.3-70b-versatile",
                "openai/gpt-oss-120b"
            ])
        ),
        ProviderDefinition(
            id: "together", name: "Together AI", protocolKind: .openAI,
            endpoint: "https://api.together.xyz/v1/chat/completions", keyRequired: true,
            keyHint: "Together API key", supportsImages: true,
            defaultModel: "deepseek-ai/DeepSeek-V3.1",
            models: strings([
                "deepseek-ai/DeepSeek-V3.1", "meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8",
                "Qwen/Qwen3-235B-A22B-Instruct-2507-tput"
            ])
        ),
        ProviderDefinition(
            id: "mistral", name: "Mistral AI", protocolKind: .openAI,
            endpoint: "https://api.mistral.ai/v1/chat/completions", keyRequired: true,
            keyHint: "Mistral API key", supportsImages: true,
            defaultModel: "mistral-large-latest",
            models: strings(["magistral-medium-latest", "mistral-large-latest", "mistral-small-latest", "codestral-latest"])
        ),
        ProviderDefinition(
            id: "cohere", name: "Cohere", protocolKind: .cohere,
            endpoint: "https://api.cohere.com/v2/chat", keyRequired: true,
            keyHint: "Cohere API key", supportsImages: false,
            defaultModel: "command-a-03-2025",
            models: strings(["command-a-03-2025", "command-r-plus-08-2024", "command-r-08-2024"])
        ),
        ProviderDefinition(
            id: "claudecode", name: "Claude Code (local)", protocolKind: .openAI,
            endpoint: "http://127.0.0.1:8787/v1/chat/completions", keyRequired: false,
            keyHint: "Optional bridge bearer token", supportsImages: false,
            defaultModel: "sonnet",
            models: [
                reasoning("fable", "Fable 5 (Claude Code)", claudeEfforts, "high"),
                reasoning("opus", "Opus 4.8 (Claude Code)", claudeEfforts, "high"),
                reasoning("sonnet", "Sonnet 4.6 (Claude Code)", claudeEfforts, "high"),
                reasoning("haiku", "Haiku 4.5 (Claude Code)", claudeEfforts, "medium")
            ],
            bridge: LocalBridgeDefinition(
                label: "Claude Code bridge", healthPath: "/health",
                startURL: "claudecode://start?port=8787",
                startCommand: "npm run bridge:claude", imageSupportComesFromHealth: true
            )
        ),
        ProviderDefinition(
            id: "codex", name: "Codex CLI (local)", protocolKind: .openAI,
            endpoint: "http://127.0.0.1:8789/v1/chat/completions", keyRequired: false,
            keyHint: "Optional bridge bearer token", supportsImages: false,
            defaultModel: "gpt-5.5",
            models: [
                reasoning("gpt-6-astra", "GPT-6 Astra", ["low", "medium", "high", "xhigh", "max"], "medium"),
                reasoning("gpt-6.1-sol", "GPT-6.1 Sol", ["low", "medium", "high", "xhigh", "max"], "medium"),
                reasoning("gpt-6-sol", "GPT-6 Sol", ["low", "medium", "high", "xhigh", "max"], "medium"),
                reasoning("gpt-6-luna", "GPT-6 Luna", ["low", "medium", "high", "xhigh", "max"], "medium"),
                reasoning("gpt-5.5", "GPT-5.5", codexEfforts, "high"),
                reasoning("gpt-5.6-sol", "GPT-5.6 Sol", ["low", "medium", "high", "xhigh", "max", "ultra"], "medium"),
                reasoning("gpt-5.6-terra", "GPT-5.6 Terra", codexEfforts, "high"),
                reasoning("gpt-5.6-luna", "GPT-5.6 Luna", ["minimal", "low", "medium", "high", "max"], "medium"),
                reasoning("gpt-5.4", "GPT-5.4", codexEfforts, "high"),
                reasoning("gpt-5.4-mini", "GPT-5.4 Mini", ["minimal", "low", "medium", "high"], "medium")
            ],
            bridge: LocalBridgeDefinition(
                label: "Codex bridge", healthPath: "/health", startURL: "scholia-codex://start",
                startCommand: "npm run bridge:codex", imageSupportComesFromHealth: true
            )
        ),
        ProviderDefinition(
            id: "opencode", name: "opencode (local server)", protocolKind: .opencode,
            endpoint: "http://127.0.0.1:4096", keyRequired: false,
            keyHint: "Optional opencode server password", supportsImages: true,
            defaultModel: "opencode-go/deepseek-v4-pro",
            models: [
                ModelDefinition(id: "opencode-go/deepseek-v4-pro", label: "DeepSeek V4 Pro"),
                ModelDefinition(id: "opencode-go/glm-5.3", label: "GLM 5.3", supportsImages: false),
                ModelDefinition(id: "opencode-go/glm-5.3-flash", label: "GLM 5.3 Flash", supportsImages: false),
                ModelDefinition(id: "opencode-go/qwen3.7-max", label: "Qwen3.7 Max"),
                ModelDefinition(id: "opencode-go/minimax-m3", label: "MiniMax M3"),
                ModelDefinition(id: "opencode-go/glm-5.2", label: "GLM 5.2", supportsImages: false),
                ModelDefinition(id: "opencode-go/kimi-k2.7-code", label: "Kimi K2.7 Code"),
                ModelDefinition(id: "opencode-go/kimi-k2.6", label: "Kimi K2.6"),
                ModelDefinition(id: "opencode-go/minimax-m2.7", label: "MiniMax M2.7"),
                ModelDefinition(id: "opencode-go/glm-5.1", label: "GLM 5.1", supportsImages: false),
                ModelDefinition(id: "opencode-go/deepseek-v4-flash", label: "DeepSeek V4 Flash")
            ],
            bridge: LocalBridgeDefinition(
                label: "opencode server", healthPath: "/global/health", startURL: "opencode://start",
                startCommand: "opencode serve --port 4096"
            )
        ),
        ProviderDefinition(
            id: "ollama", name: "Ollama (local)", protocolKind: .ollama,
            endpoint: "http://127.0.0.1:11434/api/chat", keyRequired: false,
            keyHint: "", supportsImages: true, defaultModel: "qwen3:8b",
            models: strings(["qwen3:8b", "gemma3:12b", "llama3.2-vision:11b", "llama3.2:3b"])
        ),
        ProviderDefinition(
            id: "custom", name: "Custom compatible endpoint", protocolKind: .openAI,
            endpoint: "http://127.0.0.1:8080/v1/chat/completions", keyRequired: false,
            keyHint: "Optional bearer token", supportsImages: true,
            defaultModel: "default", models: strings(["default"])
        )
    ]

    static var defaultModels: [String: String] {
        Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.defaultModel) })
    }

    static func canonicalModelID(_ modelID: String, for providerID: String) -> String {
        let value = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return providerID == "opencode" ? openCodeModelReplacements[value] ?? value : value
    }

    static func resolvedModelID(
        _ modelID: String,
        for providerID: String,
        candidates: [ModelDefinition] = []
    ) -> String {
        let canonical = canonicalModelID(modelID, for: providerID)
        guard providerID == "opencode", !canonical.isEmpty else { return canonical }
        let builtIn = providers.first(where: { $0.id == providerID })?.models ?? []
        return (builtIn + candidates).first {
            $0.id.caseInsensitiveCompare(canonical) == .orderedSame
        }?.id ?? canonical
    }

    static func isRetiredModelID(_ modelID: String, for providerID: String) -> Bool {
        providerID == "opencode"
            && openCodeModelReplacements[modelID.trimmingCharacters(in: .whitespacesAndNewlines)] != nil
    }

    static var defaultEndpoints: [String: String] {
        Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.endpoint) })
    }

    static func provider(id: String) -> ProviderDefinition {
        providers.first { $0.id == id } ?? providers.first { $0.id == "openai" }!
    }

    private static func strings(_ ids: [String]) -> [ModelDefinition] {
        ids.map { ModelDefinition(id: $0, label: $0) }
    }

    private static func labeled(_ values: [(String, String)]) -> [ModelDefinition] {
        values.map { ModelDefinition(id: $0.0, label: $0.1) }
    }

    private static func reasoning(
        _ id: String,
        _ label: String,
        _ efforts: [String],
        _ defaultEffort: String
    ) -> ModelDefinition {
        ModelDefinition(
            id: id, label: label, reasoningEfforts: efforts,
            defaultReasoningEffort: defaultEffort
        )
    }
}

enum AnswerLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case english
    case norwegian

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Auto · match prompt"
        case .english: "English"
        case .norwegian: "Norsk bokmål"
        }
    }

    var code: String {
        switch self {
        case .automatic: "auto"
        case .english: "en"
        case .norwegian: "no"
        }
    }

    init?(code: String) {
        switch code {
        case "auto": self = .automatic
        case "en": self = .english
        case "no": self = .norwegian
        default: return nil
        }
    }
}

struct SelectionPopupApplicationPreference: Codable, Equatable, Identifiable, Sendable {
    var bundleIdentifier: String
    var applicationName: String
    var enabled: Bool
    var captureEnabled: Bool? = nil

    var id: String { bundleIdentifier }
}

enum QuickAskThinkingProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case balanced
    case reason
    case deep

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: "Low"
        case .balanced: "Balanced"
        case .reason: "Reason"
        case .deep: "Deep"
        }
    }

    var defaultReasoningEffort: String {
        switch self {
        case .low: "low"
        case .balanced: "medium"
        case .reason: "high"
        case .deep: "xhigh"
        }
    }

    var defaultReasoningPreferenceOrder: [String] {
        switch self {
        case .low: ["low", "minimal"]
        case .balanced: ["medium"]
        case .reason: ["high"]
        case .deep: ["xhigh", "max", "ultra"]
        }
    }

    func defaultReasoningEffort(supportedEfforts: [String]) -> String? {
        defaultReasoningPreferenceOrder.first(where: supportedEfforts.contains)
    }

    func advanced(reverse: Bool = false) -> QuickAskThinkingProfile {
        advanced(reverse: reverse, among: Set(Self.allCases)) ?? .balanced
    }

    func advanced(
        reverse: Bool = false,
        among availableProfiles: Set<QuickAskThinkingProfile>
    ) -> QuickAskThinkingProfile? {
        guard !availableProfiles.isEmpty else { return nil }
        let profiles = Self.allCases
        guard let index = profiles.firstIndex(of: self) else { return .balanced }
        let direction = reverse ? -1 : 1
        for distance in 1...profiles.count {
            let candidateIndex = (index + direction * distance + profiles.count * 2)
                % profiles.count
            let candidate = profiles[candidateIndex]
            if availableProfiles.contains(candidate) { return candidate }
        }
        return nil
    }

    func closest(among availableProfiles: Set<QuickAskThinkingProfile>) -> QuickAskThinkingProfile? {
        guard let currentIndex = Self.allCases.firstIndex(of: self) else { return nil }
        return availableProfiles.min { left, right in
            let leftIndex = Self.allCases.firstIndex(of: left) ?? 0
            let rightIndex = Self.allCases.firstIndex(of: right) ?? 0
            let leftDistance = abs(leftIndex - currentIndex)
            let rightDistance = abs(rightIndex - currentIndex)
            return leftDistance == rightDistance
                ? leftIndex < rightIndex
                : leftDistance < rightDistance
        }
    }

    static func inferred(from reasoningEffort: String?) -> QuickAskThinkingProfile? {
        switch reasoningEffort {
        case "minimal", "low": .low
        case "medium": .balanced
        case "high": .reason
        case "xhigh", "max", "ultra": .deep
        default: nil
        }
    }
}

struct QuickAskThinkingProfileConfiguration: Codable, Equatable, Sendable {
    var modelID: String? = nil
    var reasoningEffort: String? = nil
}

struct VerifiedProviderModel: Codable, Equatable, Sendable {
    var id: String
    var endpoint: String
    var testedAt: Date
}

struct RecentProviderModel: Codable, Equatable, Sendable, Identifiable {
    var providerID: String
    var modelID: String
    var endpoint: String
    var lastUsedAt: Date
    var id: String { "\(providerID)\u{0}\(modelID)" }
}

struct AppSettings: Codable, Equatable, Sendable {
    var providerID = "openai"
    var language = AnswerLanguage.automatic
    var models = ProviderCatalog.defaultModels
    var endpoints = ProviderCatalog.defaultEndpoints
    var reasoningEfforts: [String: String] = ["claudecode": "high", "codex": "high"]
    // Optional so settings saved before study routing retain manual behavior.
    var studyModelMode: StudyModelMode?
    /// Passage explanations answer in the reader popover only, unless set.
    var selectionExplanationsInChat: Bool?
    var quickAskProviderID: String?
    var quickAskModels: [String: String]?
    var quickAskReasoningEfforts: [String: String]?
    var quickAskActiveThinkingProfiles: [String: String]?
    var quickAskThinkingProfiles: [String: [String: QuickAskThinkingProfileConfiguration]]?
    var fastClaudeMode = false
    var showSelectionPill = true
    var captureRegionEnabled: Bool? = true
    var selectionPopupApplications: [SelectionPopupApplicationPreference]?
    var keepExplanationWindowOnTop: Bool? = true
    var showExplanationWindowInWindowSwitcher: Bool? = false
    var useVisibleWorkspaceContext: Bool? = true
    var localFileAccessEnabled: Bool? = true
    var localFileWriteAccessEnabled: Bool? = false
    var verifiedProviderModels: [String: [VerifiedProviderModel]]?
    var recentProviderModels: [RecentProviderModel]?
    var explainShortcut: KeyboardShortcut? = .explainDefault
    var captureShortcut: KeyboardShortcut? = .captureDefault
    var quickAskShortcut: KeyboardShortcut? = .quickAskDefault
    var toggleSelectionPopupShortcut: KeyboardShortcut? = .toggleSelectionPopupDefault
    var selectionPopupOffsetX: Double?
    var selectionPopupOffsetY: Double?
    var launchAtLogin = false

    var resolvedExplainShortcut: KeyboardShortcut { explainShortcut ?? .explainDefault }
    var resolvedStudyModelMode: StudyModelMode { studyModelMode ?? .manual }
    var resolvedSelectionExplanationsInChat: Bool { selectionExplanationsInChat ?? false }
    var resolvedCaptureShortcut: KeyboardShortcut { captureShortcut ?? .captureDefault }
    var resolvedQuickAskShortcut: KeyboardShortcut { quickAskShortcut ?? .quickAskDefault }
    var resolvedToggleSelectionPopupShortcut: KeyboardShortcut {
        toggleSelectionPopupShortcut ?? .toggleSelectionPopupDefault
    }
    var resolvedKeepExplanationWindowOnTop: Bool { keepExplanationWindowOnTop ?? true }
    var resolvedShowExplanationWindowInWindowSwitcher: Bool {
        showExplanationWindowInWindowSwitcher ?? false
    }
    var resolvedUseVisibleWorkspaceContext: Bool { useVisibleWorkspaceContext ?? true }
    var resolvedLocalFileAccessEnabled: Bool { localFileAccessEnabled ?? true }
    var resolvedLocalFileWriteAccessEnabled: Bool {
        resolvedLocalFileAccessEnabled && (localFileWriteAccessEnabled ?? false)
    }
    var resolvedCaptureRegionEnabled: Bool { captureRegionEnabled ?? showSelectionPill }
    var shouldMonitorSelections: Bool {
        showSelectionPill || selectionPopupApplications?.contains(where: \.enabled) == true
    }

    func verifiedModelIDs(for providerID: String) -> Set<String> {
        let endpoint = (endpoints[providerID] ?? ProviderCatalog.provider(id: providerID).endpoint)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Set((verifiedProviderModels?[providerID] ?? [])
            .filter { $0.endpoint == endpoint }
            .map(\.id))
    }

    var recentModels: [RecentProviderModel] {
        var seen = Set<String>()
        return (recentProviderModels ?? []).sorted { $0.lastUsedAt > $1.lastUsedAt }.filter { record in
            let endpoint = (endpoints[record.providerID] ?? ProviderCatalog.provider(id: record.providerID).endpoint)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ProviderCatalog.providers.contains { $0.id == record.providerID }
                && record.endpoint == endpoint && !record.modelID.isEmpty && record.modelID.count <= 200
                && record.lastUsedAt.timeIntervalSince1970 > 0 && record.lastUsedAt <= Date().addingTimeInterval(300)
                && seen.insert(record.id).inserted
        }
    }

    mutating func recordModelUse(providerID: String, modelID: String, endpoint: String, at date: Date = Date()) {
        let modelID = ProviderCatalog.canonicalModelID(modelID, for: providerID)
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProviderCatalog.providers.contains(where: { $0.id == providerID }),
              !modelID.isEmpty, modelID.count <= 200 else { return }
        var records = recentProviderModels ?? []
        records.removeAll { $0.providerID == providerID && $0.modelID == modelID && $0.endpoint == endpoint }
        records.append(RecentProviderModel(providerID: providerID, modelID: modelID, endpoint: endpoint, lastUsedAt: date))
        recentProviderModels = Array(records.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(12))
    }

    func verifiedModel(for providerID: String, modelID: String) -> VerifiedProviderModel? {
        let canonical = ProviderCatalog.canonicalModelID(modelID, for: providerID)
        let endpoint = (endpoints[providerID] ?? ProviderCatalog.provider(id: providerID).endpoint)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (verifiedProviderModels?[providerID] ?? [])
            .filter { $0.id == canonical && $0.endpoint == endpoint }
            .max(by: { $0.testedAt < $1.testedAt })
    }

    mutating func markModelVerified(
        providerID: String,
        modelID: String,
        endpoint testedEndpoint: String? = nil,
        testedAt: Date = Date()
    ) {
        let canonical = ProviderCatalog.canonicalModelID(modelID, for: providerID)
        guard !canonical.isEmpty else { return }
        let endpoint = (testedEndpoint ?? endpoints[providerID] ?? ProviderCatalog.provider(id: providerID).endpoint)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var all = verifiedProviderModels ?? [:]
        var records = all[providerID] ?? []
        records.removeAll { $0.id == canonical && $0.endpoint == endpoint }
        records.append(VerifiedProviderModel(id: canonical, endpoint: endpoint, testedAt: testedAt))
        all[providerID] = Array(records.sorted { $0.testedAt > $1.testedAt }.prefix(64))
        verifiedProviderModels = all
    }

    mutating func removeModelVerification(
        providerID: String, modelID: String? = nil, endpoint testedEndpoint: String? = nil
    ) {
        guard var all = verifiedProviderModels else { return }
        if let modelID {
            let canonical = ProviderCatalog.canonicalModelID(modelID, for: providerID)
            let endpoint = (testedEndpoint ?? endpoints[providerID] ?? ProviderCatalog.provider(id: providerID).endpoint)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            all[providerID]?.removeAll { $0.id == canonical && $0.endpoint == endpoint }
            if all[providerID]?.isEmpty == true { all.removeValue(forKey: providerID) }
        } else {
            all.removeValue(forKey: providerID)
        }
        verifiedProviderModels = all
    }

    func selectionPillIsEnabled(for bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier = normalizedBundleIdentifier(bundleIdentifier) else {
            return showSelectionPill
        }
        return selectionPopupApplications?
            .first(where: { $0.bundleIdentifier == bundleIdentifier })?
            .enabled ?? showSelectionPill
    }

    func selectionPopupPreference(
        for bundleIdentifier: String?
    ) -> SelectionPopupApplicationPreference? {
        guard let bundleIdentifier = normalizedBundleIdentifier(bundleIdentifier) else { return nil }
        return selectionPopupApplications?.first { $0.bundleIdentifier == bundleIdentifier }
    }

    func captureRegionIsEnabled(for bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier = normalizedBundleIdentifier(bundleIdentifier) else {
            return resolvedCaptureRegionEnabled
        }
        guard let preference = selectionPopupApplications?
            .first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return resolvedCaptureRegionEnabled
        }
        return preference.captureEnabled ?? preference.enabled
    }

    mutating func setSelectionPillEnabled(
        _ enabled: Bool,
        for bundleIdentifier: String,
        applicationName: String
    ) {
        guard let bundleIdentifier = normalizedBundleIdentifier(bundleIdentifier) else { return }
        let normalizedName = normalizedApplicationName(applicationName, fallback: bundleIdentifier)
        var preferences = selectionPopupApplications ?? []
        if let index = preferences.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            let captureEnabled = preferences[index].captureEnabled ?? preferences[index].enabled
            preferences[index] = SelectionPopupApplicationPreference(
                bundleIdentifier: bundleIdentifier,
                applicationName: normalizedName,
                enabled: enabled,
                captureEnabled: captureEnabled
            )
        } else {
            preferences.append(SelectionPopupApplicationPreference(
                bundleIdentifier: bundleIdentifier,
                applicationName: normalizedName,
                enabled: enabled,
                captureEnabled: resolvedCaptureRegionEnabled
            ))
        }
        selectionPopupApplications = preferences
    }

    mutating func setCaptureRegionEnabled(
        _ enabled: Bool,
        for bundleIdentifier: String,
        applicationName: String
    ) {
        guard let bundleIdentifier = normalizedBundleIdentifier(bundleIdentifier) else { return }
        let normalizedName = normalizedApplicationName(applicationName, fallback: bundleIdentifier)
        var preferences = selectionPopupApplications ?? []
        if let index = preferences.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            preferences[index] = SelectionPopupApplicationPreference(
                bundleIdentifier: bundleIdentifier,
                applicationName: normalizedName,
                enabled: preferences[index].enabled,
                captureEnabled: enabled
            )
        } else {
            preferences.append(SelectionPopupApplicationPreference(
                bundleIdentifier: bundleIdentifier,
                applicationName: normalizedName,
                enabled: selectionPillIsEnabled(for: bundleIdentifier),
                captureEnabled: enabled
            ))
        }
        selectionPopupApplications = preferences
    }

    mutating func removeSelectionPopupPreference(for bundleIdentifier: String) {
        guard let bundleIdentifier = normalizedBundleIdentifier(bundleIdentifier) else { return }
        selectionPopupApplications?.removeAll { $0.bundleIdentifier == bundleIdentifier }
    }

    func resolvedQuickAskModel(for provider: ProviderDefinition) -> String {
        quickAskModels?[provider.id] ?? models[provider.id] ?? provider.defaultModel
    }
    func resolvedQuickAskReasoningEffort(for provider: ProviderDefinition) -> String? {
        guard let definition = provider.model(named: resolvedQuickAskModel(for: provider)),
              !definition.reasoningEfforts.isEmpty else { return nil }
        if let effort = quickAskReasoningEfforts?[provider.id],
            definition.reasoningEfforts.contains(effort) {
            return effort
        }
        if let effort = reasoningEfforts[provider.id],
            definition.reasoningEfforts.contains(effort) {
            return effort
        }
        return definition.defaultReasoningEffort ?? definition.reasoningEfforts.first
    }
    func resolvedQuickAskThinkingProfile(for provider: ProviderDefinition) -> QuickAskThinkingProfile {
        if let rawValue = quickAskActiveThinkingProfiles?[provider.id],
           let profile = QuickAskThinkingProfile(rawValue: rawValue) {
            return profile
        }
        return QuickAskThinkingProfile.inferred(
            from: resolvedQuickAskReasoningEffort(for: provider)
        ) ?? .balanced
    }
    func quickAskThinkingConfiguration(
        for profile: QuickAskThinkingProfile,
        provider: ProviderDefinition
    ) -> QuickAskThinkingProfileConfiguration? {
        quickAskThinkingProfiles?[provider.id]?[profile.rawValue]
    }
    func resolvedQuickAskThinkingModel(
        for profile: QuickAskThinkingProfile,
        provider: ProviderDefinition
    ) -> String {
        if let modelID = quickAskThinkingConfiguration(for: profile, provider: provider)?
            .modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !modelID.isEmpty {
            return modelID
        }
        return resolvedQuickAskModel(for: provider)
    }
    func resolvedQuickAskThinkingReasoningEffort(
        for profile: QuickAskThinkingProfile,
        provider: ProviderDefinition
    ) -> String? {
        let modelID = resolvedQuickAskThinkingModel(for: profile, provider: provider)
        guard let definition = provider.model(named: modelID),
              !definition.reasoningEfforts.isEmpty else { return nil }
        if let effort = quickAskThinkingConfiguration(for: profile, provider: provider)?
            .reasoningEffort,
           definition.reasoningEfforts.contains(effort) {
            return effort
        }
        return profile.defaultReasoningEffort(supportedEfforts: definition.reasoningEfforts)
    }
    func resolvedQuickAskProviderID(for activeProviderID: String) -> String {
        if let id = quickAskProviderID?.trimmingCharacters(in: .whitespacesAndNewlines),
           ProviderCatalog.providers.contains(where: { $0.id == id }) {
            return id
        }
        return activeProviderID
    }
    var resolvedSelectionPopupOffset: CGSize {
        CGSize(width: selectionPopupOffsetX ?? 0, height: selectionPopupOffsetY ?? 0)
    }

    mutating func normalize() {
        captureRegionEnabled = resolvedCaptureRegionEnabled
        if !ProviderCatalog.providers.contains(where: { $0.id == providerID }) {
            providerID = "openai"
        }
        if let id = quickAskProviderID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty, ProviderCatalog.providers.contains(where: { $0.id == id }) {
            quickAskProviderID = id
        } else {
            quickAskProviderID = nil
        }
        for provider in ProviderCatalog.providers {
            let model = models[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            models[provider.id] = model.isEmpty
                ? provider.defaultModel
                : ProviderCatalog.resolvedModelID(String(model.prefix(200)), for: provider.id)
            let endpoint = endpoints[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            endpoints[provider.id] = endpoint.isEmpty ? provider.endpoint : String(endpoint.prefix(2_048))

            guard let definition = provider.model(named: models[provider.id] ?? ""),
                  !definition.reasoningEfforts.isEmpty else { continue }
            let requested = reasoningEfforts[provider.id] ?? ""
            reasoningEfforts[provider.id] = definition.reasoningEfforts.contains(requested)
                ? requested
                : definition.defaultReasoningEffort
        }
        var normalizedQuickModels: [String: String] = [:]
        for provider in ProviderCatalog.providers {
            guard let raw = quickAskModels?[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            normalizedQuickModels[provider.id] = ProviderCatalog.canonicalModelID(
                String(raw.prefix(200)),
                for: provider.id
            )
        }
        quickAskModels = normalizedQuickModels
        var normalizedQuickEfforts: [String: String] = [:]
        for provider in ProviderCatalog.providers {
            guard let definition = provider.model(named: resolvedQuickAskModel(for: provider)),
                  let requested = quickAskReasoningEfforts?[provider.id],
                  definition.reasoningEfforts.contains(requested) else { continue }
            normalizedQuickEfforts[provider.id] = requested
        }
        quickAskReasoningEfforts = normalizedQuickEfforts
        var normalizedActiveThinkingProfiles: [String: String] = [:]
        for provider in ProviderCatalog.providers {
            guard let rawValue = quickAskActiveThinkingProfiles?[provider.id],
                  QuickAskThinkingProfile(rawValue: rawValue) != nil else { continue }
            normalizedActiveThinkingProfiles[provider.id] = rawValue
        }
        quickAskActiveThinkingProfiles = normalizedActiveThinkingProfiles
        var normalizedThinkingProfiles: [String: [String: QuickAskThinkingProfileConfiguration]] = [:]
        for provider in ProviderCatalog.providers {
            var providerProfiles: [String: QuickAskThinkingProfileConfiguration] = [:]
            for profile in QuickAskThinkingProfile.allCases {
                guard var configuration = quickAskThinkingProfiles?[provider.id]?[profile.rawValue] else {
                    continue
                }
                if let rawModelID = configuration.modelID?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !rawModelID.isEmpty {
                    configuration.modelID = ProviderCatalog.canonicalModelID(
                        String(rawModelID.prefix(200)),
                        for: provider.id
                    )
                } else {
                    configuration.modelID = nil
                }
                if let rawEffort = configuration.reasoningEffort?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !rawEffort.isEmpty {
                    let modelID = configuration.modelID ?? resolvedQuickAskModel(for: provider)
                    if let definition = provider.model(named: modelID),
                       !definition.reasoningEfforts.isEmpty {
                        configuration.reasoningEffort = definition.reasoningEfforts.contains(rawEffort)
                            ? String(rawEffort.prefix(40))
                            : nil
                    } else {
                        // Runtime-discovered opencode variants are validated by
                        // AppModel against the live catalog before they are set.
                        configuration.reasoningEffort = provider.id == "opencode"
                            ? String(rawEffort.prefix(40))
                            : nil
                    }
                } else {
                    configuration.reasoningEffort = nil
                }
                if configuration.modelID != nil || configuration.reasoningEffort != nil {
                    providerProfiles[profile.rawValue] = configuration
                }
            }
            if !providerProfiles.isEmpty {
                normalizedThinkingProfiles[provider.id] = providerProfiles
            }
        }
        quickAskThinkingProfiles = normalizedThinkingProfiles
        var normalizedVerifiedModels: [String: [VerifiedProviderModel]] = [:]
        let now = Date()
        for provider in ProviderCatalog.providers {
            var latestByIDAndEndpoint: [String: VerifiedProviderModel] = [:]
            for record in verifiedProviderModels?[provider.id] ?? [] {
                let id = ProviderCatalog.canonicalModelID(record.id, for: provider.id)
                let endpoint = record.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, id.count <= 200,
                      !endpoint.isEmpty, endpoint.count <= 2_048,
                      record.testedAt.timeIntervalSince1970 > 0,
                      record.testedAt <= now.addingTimeInterval(300) else { continue }
                let normalized = VerifiedProviderModel(
                    id: id,
                    endpoint: endpoint,
                    testedAt: record.testedAt
                )
                let key = "\(endpoint)\u{0}\(id)"
                if (latestByIDAndEndpoint[key]?.testedAt ?? Date.distantPast) < normalized.testedAt {
                    latestByIDAndEndpoint[key] = normalized
                }
            }
            let records = latestByIDAndEndpoint.values
                .sorted { $0.testedAt > $1.testedAt }
                .prefix(64)
            if !records.isEmpty { normalizedVerifiedModels[provider.id] = Array(records) }
        }
        verifiedProviderModels = normalizedVerifiedModels
        var normalizedApplicationPreferences: [String: SelectionPopupApplicationPreference] = [:]
        for preference in selectionPopupApplications ?? [] {
            guard let bundleIdentifier = normalizedBundleIdentifier(preference.bundleIdentifier) else {
                continue
            }
            normalizedApplicationPreferences[bundleIdentifier] = SelectionPopupApplicationPreference(
                bundleIdentifier: bundleIdentifier,
                applicationName: normalizedApplicationName(
                    preference.applicationName,
                    fallback: bundleIdentifier
                ),
                enabled: preference.enabled,
                captureEnabled: preference.captureEnabled ?? preference.enabled
            )
        }
        selectionPopupApplications = normalizedApplicationPreferences.values
            .sorted {
                let comparison = $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName)
                return comparison == .orderedSame
                    ? $0.bundleIdentifier < $1.bundleIdentifier
                    : comparison == .orderedAscending
            }
            .prefix(256)
            .map { $0 }
        keepExplanationWindowOnTop = resolvedKeepExplanationWindowOnTop
        showExplanationWindowInWindowSwitcher = resolvedShowExplanationWindowInWindowSwitcher
        useVisibleWorkspaceContext = resolvedUseVisibleWorkspaceContext
        if resolvedExplainShortcut.isValid { explainShortcut = resolvedExplainShortcut }
        else { explainShortcut = .explainDefault }
        if resolvedCaptureShortcut.isValid { captureShortcut = resolvedCaptureShortcut }
        else { captureShortcut = .captureDefault }
        if resolvedQuickAskShortcut.isValid { quickAskShortcut = resolvedQuickAskShortcut }
        else { quickAskShortcut = .quickAskDefault }
        if resolvedToggleSelectionPopupShortcut.isValid {
            toggleSelectionPopupShortcut = resolvedToggleSelectionPopupShortcut
        } else {
            toggleSelectionPopupShortcut = .toggleSelectionPopupDefault
        }
        if explainShortcut == captureShortcut {
            captureShortcut = .captureDefault
            if explainShortcut == captureShortcut { explainShortcut = .explainDefault }
        }
        if quickAskShortcut == explainShortcut || quickAskShortcut == captureShortcut {
            quickAskShortcut = .quickAskDefault
        }
        if toggleSelectionPopupShortcut == explainShortcut
            || toggleSelectionPopupShortcut == captureShortcut
            || toggleSelectionPopupShortcut == quickAskShortcut {
            toggleSelectionPopupShortcut = .toggleSelectionPopupDefault
        }
        if let x = selectionPopupOffsetX, x.isFinite {
            selectionPopupOffsetX = min(max(x, -4_000), 4_000)
        } else {
            selectionPopupOffsetX = nil
        }
        if let y = selectionPopupOffsetY, y.isFinite {
            selectionPopupOffsetY = min(max(y, -4_000), 4_000)
        } else {
            selectionPopupOffsetY = nil
        }
    }

    private func normalizedBundleIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(255))
    }

    private func normalizedApplicationName(_ value: String, fallback: String) -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((normalized.isEmpty ? fallback : normalized).prefix(200))
    }
}

@MainActor
enum AppSettingsStore {
    private static let key = "scholia.macos.settings.v1"

    static func load(defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key),
              var value = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        value.normalize()
        return value
    }

    static func save(_ settings: AppSettings, defaults: UserDefaults = .standard) {
        var normalized = settings
        normalized.normalize()
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        defaults.set(data, forKey: key)
    }
}
