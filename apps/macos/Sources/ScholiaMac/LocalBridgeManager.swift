@preconcurrency import AppKit
@preconcurrency import Foundation

struct LocalBridgeHealth: Sendable {
    var service: String
    var version: String?
}

enum LocalBridgeManagerError: LocalizedError {
    case invalidEndpoint
    case missingRuntime(String)
    case missingBridge(String)
    case launchFailed(String)
    case exited(String)
    case timedOut(String)
    case catalogUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The local-provider endpoint is not a valid URL."
        case .missingRuntime(let detail), .missingBridge(let detail), .launchFailed(let detail):
            detail
        case .exited(let detail):
            "The local provider stopped before it became ready.\(detail.isEmpty ? "" : " \(detail)")"
        case .timedOut(let label):
            "\(label) did not become ready within 10 seconds."
        case .catalogUnavailable(let detail):
            detail
        }
    }
}

/// Owns only bridge processes started by this copy of Scholia. Existing healthy
/// loopback providers are reused and are never terminated by the app.
@MainActor
final class LocalBridgeManager {
    private var processes: [String: Process] = [:]
    private var logHandles: [String: FileHandle] = [:]
    private var logURLs: [String: URL] = [:]
    private var startupTasks: [String: Task<LocalBridgeHealth, Error>] = [:]

    func ensureRunning(
        provider: ProviderDefinition,
        endpoint: String,
        apiKey: String
    ) async throws -> LocalBridgeHealth {
        let key = provider.id
        if let existing = startupTasks[key] {
            return try await existing.value
        }

        let task = Task { @MainActor [weak self] () throws -> LocalBridgeHealth in
            guard let self else { throw CancellationError() }
            return try await self.startAndWait(provider: provider, endpoint: endpoint, apiKey: apiKey)
        }
        startupTasks[key] = task
        defer { startupTasks[key] = nil }
        return try await task.value
    }

    func check(
        provider: ProviderDefinition,
        endpoint: String,
        apiKey: String
    ) async -> LocalBridgeHealth? {
        guard let healthURL = healthURL(provider: provider, endpoint: endpoint) else { return nil }
        return try? await fetchHealth(at: healthURL, provider: provider, apiKey: apiKey)
    }

    func discoverModels(
        provider: ProviderDefinition,
        endpoint: String,
        apiKey: String
    ) async throws -> [ModelDefinition] {
        if provider.id == "codex" {
            guard let url = serviceURL(endpoint: endpoint, path: "/v1/models") else {
                throw LocalBridgeManagerError.invalidEndpoint
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            applyAuthorization(to: &request, provider: provider, apiKey: apiKey)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw LocalBridgeManagerError.catalogUnavailable("Codex model discovery is unavailable.")
            }
            return try CodexModelCatalog.models(from: data)
        }
        guard provider.protocolKind == .opencode else { return provider.models }
        var lastError: Error = LocalBridgeManagerError.catalogUnavailable(
            "OpenCode model discovery is unavailable."
        )
        for path in ["/provider", "/config/providers"] {
            guard let url = serviceURL(endpoint: endpoint, path: path) else {
                throw LocalBridgeManagerError.invalidEndpoint
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.25
            applyAuthorization(to: &request, provider: provider, apiKey: apiKey)
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw LocalBridgeManagerError.catalogUnavailable(
                        "OpenCode returned an invalid model-catalog response."
                    )
                }
                guard (200..<300).contains(http.statusCode) else {
                    lastError = LocalBridgeManagerError.catalogUnavailable(
                        "OpenCode model catalog returned HTTP \(http.statusCode)."
                    )
                    continue
                }
                return try await Task.detached(priority: .utility) {
                    try OpenCodeModelCatalog.models(from: data)
                }.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func stopOwnedProcess() {
        for task in startupTasks.values { task.cancel() }
        startupTasks = [:]
        stopAllProcesses()
    }

    private func stopAllProcesses() {
        for process in processes.values where process.isRunning { process.terminate() }
        processes = [:]
        for handle in logHandles.values { try? handle.close() }
        logHandles = [:]
        logURLs = [:]
    }

    private func stopProcess(for providerID: String) {
        if let process = processes[providerID] {
            if process.isRunning { process.terminate() }
            processes.removeValue(forKey: providerID)
        }
        try? logHandles[providerID]?.close()
        logHandles.removeValue(forKey: providerID)
        logURLs.removeValue(forKey: providerID)
    }

    private func startAndWait(
        provider: ProviderDefinition,
        endpoint: String,
        apiKey: String
    ) async throws -> LocalBridgeHealth {
        guard let bridge = provider.bridge,
              let healthURL = healthURL(provider: provider, endpoint: endpoint) else {
            throw LocalBridgeManagerError.invalidEndpoint
        }
        if let health = try? await fetchHealth(at: healthURL, provider: provider, apiKey: apiKey) { return health }

        if provider.id == "codex" || provider.id == "claudecode" {
            try launchBundledBridge(provider: provider, endpoint: endpoint)
        } else if let value = bridge.startURL,
                  let url = URL(string: value),
                  NSWorkspace.shared.open(url) {
            // URL handlers are only a launch request. Readiness below is the
            // source of truth, so stale handlers can no longer look successful.
        } else {
            throw LocalBridgeManagerError.launchFailed(
                "Could not launch \(bridge.label). Start it with: \(bridge.startCommand)"
            )
        }

        for _ in 0..<40 {
            try Task.checkCancellation()
            if let health = try? await fetchHealth(at: healthURL, provider: provider, apiKey: apiKey) { return health }
            if let process = processes[provider.id], !process.isRunning {
                throw LocalBridgeManagerError.exited(logTail(for: provider.id))
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw LocalBridgeManagerError.timedOut(bridge.label)
    }

    private func launchBundledBridge(provider: ProviderDefinition, endpoint: String) throws {
        // A healthy owned process returned before this method is reached. If
        // one remains here, restart it instead of waiting on a wedged child.
        if processes[provider.id] != nil { stopProcess(for: provider.id) }

        let node = try executable(
            named: "Node.js",
            command: "node",
            candidates: ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        )
        let scriptName: String
        let binaryName: String
        let binaryFlag: String
        let binaryCandidates: [String]
        switch provider.id {
        case "codex":
            scriptName = "codex-bridge.mjs"
            binaryName = "Codex CLI"
            binaryFlag = "--codex"
            binaryCandidates = [
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
                "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
            ]
        case "claudecode":
            scriptName = "claude-code-bridge.mjs"
            binaryName = "Claude Code"
            binaryFlag = "--claude"
            binaryCandidates = [
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/local/claude").path,
                "/opt/homebrew/bin/claude", "/usr/local/bin/claude"
            ]
        default:
            throw LocalBridgeManagerError.missingBridge("Scholia has no embedded launcher for \(provider.name).")
        }
        let binary = try executable(named: binaryName, command: provider.id == "codex" ? "codex" : "claude", candidates: binaryCandidates)
        let script = try bridgeScript(named: scriptName)
        let port = URLComponents(string: endpoint)?.port ?? (provider.id == "codex" ? 8789 : 8787)

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("scholia-\(provider.id)-bridge.log")
        try Data().write(to: logURL, options: .atomic)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script.path, "--port", String(port), binaryFlag, binary]
        process.currentDirectoryURL = script.deletingLastPathComponent()
        process.standardOutput = logHandle
        process.standardError = logHandle
        var environment = ProcessInfo.processInfo.environment
        let usefulPaths = [
            URL(fileURLWithPath: node).deletingLastPathComponent().path,
            URL(fileURLWithPath: binary).deletingLastPathComponent().path,
            environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        ]
        environment["PATH"] = usefulPaths.joined(separator: ":")
        process.environment = environment

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw LocalBridgeManagerError.launchFailed("Could not launch \(provider.name): \(error.localizedDescription)")
        }
        self.processes[provider.id] = process
        self.logHandles[provider.id] = logHandle
        self.logURLs[provider.id] = logURL
    }

    private func fetchHealth(
        at url: URL,
        provider: ProviderDefinition,
        apiKey: String
    ) async throws -> LocalBridgeHealth {
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        applyAuthorization(to: &request, provider: provider, apiKey: apiKey)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ok"] as? Bool == true || json["healthy"] as? Bool == true else {
            throw LocalBridgeManagerError.launchFailed("The local provider returned an invalid health response.")
        }
        return LocalBridgeHealth(
            service: json["service"] as? String ?? "local provider",
            version: json["version"] as? String ?? json["bridgeVersion"] as? String
        )
    }

    private func healthURL(provider: ProviderDefinition, endpoint: String) -> URL? {
        guard let bridge = provider.bridge else { return nil }
        return serviceURL(endpoint: endpoint, path: bridge.healthPath)
    }

    private func serviceURL(endpoint: String, path: String) -> URL? {
        guard var components = URLComponents(string: endpoint),
              components.scheme != nil, components.host != nil else { return nil }
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func applyAuthorization(
        to request: inout URLRequest,
        provider: ProviderDefinition,
        apiKey: String
    ) {
        guard !apiKey.isEmpty else { return }
        let value: String
        if provider.protocolKind == .opencode {
            value = "Basic \(Data("opencode:\(apiKey)".utf8).base64EncodedString())"
        } else {
            value = "Bearer \(apiKey)"
        }
        request.setValue(value, forHTTPHeaderField: "Authorization")
    }

    private func bridgeScript(named name: String) throws -> URL {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("Bridge").appendingPathComponent(name))
        }
        var sourceRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { sourceRoot.deleteLastPathComponent() }
        candidates.append(sourceRoot.appendingPathComponent("scripts").appendingPathComponent(name))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("scripts").appendingPathComponent(name))
        if let match = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { return match }
        throw LocalBridgeManagerError.missingBridge("The embedded \(name) resource is missing. Reinstall Scholia.")
    }

    private func executable(named label: String, command: String, candidates: [String]) throws -> String {
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent(command).path }
        if let match = (candidates + pathCandidates).first(where: FileManager.default.isExecutableFile(atPath:)) {
            return match
        }
        throw LocalBridgeManagerError.missingRuntime("\(label) was not found. Install it, then try again.")
    }

    private func logTail(for providerID: String) -> String {
        guard let logURL = logURLs[providerID],
              let text = try? String(contentsOf: logURL, encoding: .utf8) else { return "" }
        let useful = text.split(whereSeparator: \Character.isNewline).suffix(4).joined(separator: " ")
        return String(useful.suffix(700))
    }
}
