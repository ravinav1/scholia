import AppKit
import SwiftUI
@preconcurrency import WebKit

@MainActor
final class PersonalizationBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let source: PersonalizationSource
    let webView: WKWebView
    init(source: PersonalizationSource) {
        self.source = source
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: source.browserStoreID)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 760), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }
    func open(_ url: URL) { webView.load(URLRequest(url: url)) }
    func close() { webView.stopLoading(); webView.loadHTMLString("", baseURL: nil) }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "https" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, url.scheme == "https" { open(url) }
        return nil
    }

    private func read(_ action: String) async throws -> [String: String] {
        guard source.accepts(webView.url) else { return [:] }
        let raw = try await webView.callAsyncJavaScript(PersonalizationPage.script,
            arguments: ["action": action], in: nil, contentWorld: .defaultClient)
        guard let string = raw as? String, let data = string.data(using: .utf8),
              let result = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return result
    }
    private func settled(_ action: String, timeout: TimeInterval = 20) async throws -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        var previous: [String: String] = [:]
        var stable = 0
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(700))
            guard !webView.isLoading else { continue }
            let value = (try? await read(action)) ?? [:]
            if !value.isEmpty && value == previous { stable += 1 } else { stable = 0 }
            previous = value
            if stable >= 2 { return value }
        }
        return [:]
    }
    func snapshot() async throws -> [String: String] {
        open(source.profileURL)
        var values = try await settled("profile")
        try Task.checkCancellation()
        if source == .claude {
            open(source.memoryURL)
            // Wait for the settings surface before pressing its read-only
            // View/Manage control. Some versions show the memory list directly.
            for _ in 0..<15 {
                try await Task.sleep(for: .milliseconds(700))
                try Task.checkCancellation()
                if !webView.isLoading, source.accepts(webView.url) { break }
            }
        }
        _ = try? await read("openMemory")
        var memories = try await settled("memory")
        if source == .claude && memories.isEmpty {
            open(URL(string: "https://claude.ai/settings/capabilities")!)
            for _ in 0..<15 {
                try await Task.sleep(for: .milliseconds(700))
                try Task.checkCancellation()
                if !webView.isLoading, source.accepts(webView.url) { break }
            }
            _ = try? await read("openMemory")
            memories = try await settled("memory")
        }
        values.merge(memories) { _, new in new }
        try Task.checkCancellation()
        return values
    }
}

@MainActor
final class PersonalizationSync: ObservableObject {
    static let shared = PersonalizationSync()
    @Published private(set) var preferences: PersonalizationPreferences
    @Published private(set) var refreshing: PersonalizationSource?
    @Published private(set) var storageError: String?
    var interactiveSource: PersonalizationSource?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let storeURL: URL
    private let reader: (@MainActor (PersonalizationSource) async throws -> [String: String])?

    init(storeURL: URL = PersonalizationStore.url,
        reader: (@MainActor (PersonalizationSource) async throws -> [String: String])? = nil) {
        self.storeURL = storeURL
        self.reader = reader
        preferences = PersonalizationStore.load(from: storeURL)
    }
    func start() {
        guard timer == nil, PersonalizationSource.allCases.contains(where: { preferences[$0].enabled && preferences[$0].automatic }) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDue() }
        }
        timer?.tolerance = 15
        refreshDue()
    }
    func stop() { timer?.invalidate(); timer = nil; cancel() }
    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil; refreshing = nil
    }
    func update(_ source: PersonalizationSource, enabled: Bool? = nil, automatic: Bool? = nil) {
        if let enabled { preferences[source].enabled = enabled }
        if let automatic { preferences[source].automatic = automatic }
        if refreshing == source { cancel() }
        persist()
        if PersonalizationSource.allCases.contains(where: { preferences[$0].enabled && preferences[$0].automatic }) { start() }
        else { timer?.invalidate(); timer = nil }
        if enabled == true || automatic == true { refreshDue() }
    }
    func disconnect(_ source: PersonalizationSource) {
        if refreshing == source { cancel() }
        preferences.connections.removeValue(forKey: source.rawValue)
        persist()
        // Wait for WebKit to delete this source's login before another connect
        // can reuse it. No other app's or provider's browser store is touched.
        clearing.insert(source)
        Task {
            await WKWebsiteDataStore(forIdentifier: source.browserStoreID).removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            clearing.remove(source)
            objectWillChange.send()
        }
    }
    private(set) var clearing: Set<PersonalizationSource> = []

    private func persist() {
        do { try PersonalizationStore.save(preferences, to: storeURL); storageError = nil }
        catch { storageError = "Could not save personalization: \(error.localizedDescription)" }
    }
    private func refreshDue() {
        guard task == nil, interactiveSource == nil,
              let source = PersonalizationSource.allCases.first(where: { !clearing.contains($0) && preferences[$0].isDue() }) else { return }
        refresh(source)
    }
    func refresh(_ source: PersonalizationSource, using existing: PersonalizationBrowser? = nil) {
        guard task == nil, !clearing.contains(source), preferences[source].enabled else { return }
        let run = UUID(); generation = run; refreshing = source
        task = Task { [weak self] in
            guard let self else { return }
            let browser = existing ?? (reader == nil ? PersonalizationBrowser(source: source) : nil)
            defer { if existing == nil { browser?.close() } }
            do {
                let values: [String: String]
                if let browser { values = try await browser.snapshot() }
                else if let reader { values = try await reader(source) }
                else { return }
                guard !Task.isCancelled, generation == run, preferences[source].enabled else { return }
                try preferences[source].receive(values)
            } catch {
                guard !Task.isCancelled, generation == run else { return }
                preferences[source].lastChecked = Date()
                preferences[source].issue = error.localizedDescription
            }
            guard generation == run else { return }
            persist(); refreshing = nil; task = nil
        }
    }
}

struct PersonalizationSettingsView: View {
    @ObservedObject var sync: PersonalizationSync
    @State private var connection: PersonalizationSource?
    @State private var forgetting: PersonalizationSource?
    var body: some View {
        Form {
            Section {
                Text("Bring your custom instructions, profile preferences, and saved memories into Scholia chats.")
                Text("The saved copy is stored on this Mac. Enabled personalization is sent with your messages to your selected AI provider. Automatic refresh checks every 15 minutes while Scholia is running. Updates apply to the next message.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(PersonalizationSource.allCases) { source in
                sourceSection(source)
            }
            if let error = sync.storageError { Text(error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .onAppear { sync.start() }
        .sheet(item: $connection) { source in
            PersonalizationConnectionView(source: source, sync: sync)
        }
        .confirmationDialog("Forget imported personalization and sign out?", isPresented: Binding(
            get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })) {
            if let source = forgetting {
                Button("Forget \(source.title)", role: .destructive) { sync.disconnect(source); forgetting = nil }
            }
        } message: { Text("This removes the local copy and Scholia's login. Your account on the original service is unchanged.") }
    }
    private func sourceSection(_ source: PersonalizationSource) -> some View {
        let value = sync.preferences[source]
        return Section(source.title) {
            Toggle("Use \(source.title) personalization", isOn: Binding(
                get: { sync.preferences[source].enabled }, set: { sync.update(source, enabled: $0) }))
                .accessibilityIdentifier("personalization-\(source.rawValue)-enabled")
            Toggle("Refresh automatically", isOn: Binding(
                get: { sync.preferences[source].automatic }, set: { sync.update(source, automatic: $0) }))
                .disabled(!value.enabled)
            HStack {
                Button(value.hasSnapshot ? "Open connection…" : "Connect…") { connection = source }
                Button("Refresh now") { sync.refresh(source) }
                    .disabled(!value.enabled || sync.refreshing != nil)
                if sync.refreshing == source { ProgressView().controlSize(.small) }
                Spacer()
                Button("Forget…", role: .destructive) { forgetting = source }
                    .disabled(!value.hasSnapshot && !value.enabled)
            }.disabled(sync.clearing.contains(source))
            if let checked = value.lastChecked {
                Text("Last checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Sign in through Connect to import your saved settings.").font(.caption).foregroundStyle(.secondary)
            }
            if let updated = value.lastUpdated {
                Text("Last changed \(updated.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = value.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            if value.hasSnapshot {
                DisclosureGroup("Review imported personalization") {
                    ForEach(PersonalizationSection.allCases) { section in
                        Text(section.title).font(.caption.bold())
                        Text(value.sections[section.rawValue].map { $0.isEmpty ? "Empty on source" : $0 } ?? "Not imported yet")
                            .font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
    }
}

private struct PersonalizationConnectionView: View {
    let source: PersonalizationSource
    @ObservedObject var sync: PersonalizationSync
    @StateObject private var browser: PersonalizationBrowser
    @Environment(\.dismiss) private var dismiss
    init(source: PersonalizationSource, sync: PersonalizationSync) {
        self.source = source; self.sync = sync
        _browser = StateObject(wrappedValue: PersonalizationBrowser(source: source))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connect \(source.title)").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            Text("Sign in, then choose Sync saved settings. Scholia reads your instructions, profile, and memory pages. Save any edits on \(source.title) before syncing.")
                .font(.callout)
            HStack {
                Button("Profile") { browser.open(source.profileURL) }
                Button("Memories") { browser.open(source.memoryURL) }
                Spacer()
                if sync.refreshing == source { ProgressView().controlSize(.small); Text("Reading saved settings…").font(.caption) }
                Button("Sync saved settings") {
                    sync.update(source, enabled: true)
                    sync.refresh(source, using: browser)
                }.disabled(sync.refreshing != nil)
            }
            if let issue = sync.preferences[source].issue { Text(issue).font(.caption).foregroundStyle(.orange) }
            PersonalizationWebView(browser: browser)
        }
        .padding(16).frame(minWidth: 850, minHeight: 680)
        .onAppear {
            sync.cancel(); sync.interactiveSource = source
            browser.open(source.profileURL)
        }
        .onDisappear {
            sync.cancel(); sync.interactiveSource = nil; browser.close()
        }
    }
}

private struct PersonalizationWebView: NSViewRepresentable {
    let browser: PersonalizationBrowser
    func makeNSView(context: Context) -> WKWebView { browser.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
