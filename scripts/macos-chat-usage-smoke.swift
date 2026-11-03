import AppKit
import SwiftUI
@testable import ScholiaMac

final class UsageFixtureState: @unchecked Sendable {
    static let shared = UsageFixtureState()
    private let lock = NSLock()
    private var count = 0
    private var hold = false
    var requestCount: Int { lock.withLock { count } }
    func holdNext() { lock.withLock { hold = true } }
    func begin() -> Bool {
        lock.withLock {
            count += 1
            let shouldHold = hold
            hold = false
            return shouldHold
        }
    }
}

final class UsageFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.path == "/v1/usage", "Usage must not start an inference request")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
        if UsageFixtureState.shared.begin() { return }
        let now = Date().timeIntervalSince1970
        let json: [String: Any] = ["ok": true, "rateLimits": ["limitId": "codex",
            "primary": ["usedPercent": 27, "windowDurationMins": 300, "resetsAt": now + 7_200],
            "secondary": ["usedPercent": 9, "windowDurationMins": 10_080, "resetsAt": now + 300_000]]]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
@MainActor
struct ChatUsageSmoke {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        Task { @MainActor in
            do { try await run(); print("PASS: native usage retrieval, persistence, unavailable values, reset freshness, and UI rendering"); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        NSApplication.shared.run()
    }

    static func run() async throws {
        let legacy = #"{"id":"880730B1-28D8-4C21-B24E-E52160271F66","role":"assistant","content":"Existing answer","isStreaming":false}"#
        let old = try JSONDecoder().decode(ConversationMessage.self, from: Data(legacy.utf8))
        precondition(old.usage == nil && old.responseDurationSeconds == nil)
        let usage = CompletionUsage(inputTokens: 21_000, cachedInputTokens: 14_000, outputTokens: 3_000, elapsedSeconds: 390, requestCount: 3)
        let original = ConversationMessage(role: .assistant, content: "Answer", usage: usage, responseDurationSeconds: 400)
        let sanitized = StoredConversation.sanitizedMessages([original])[0]
        let restored = try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(sanitized))
        precondition(restored.usage == usage && restored.responseDurationSeconds == 400 && restored.usage?.totalTokens == 24_000)
        precondition(ChatUsagePresentation.summary(usage: nil, duration: nil).isEmpty)
        precondition(ChatUsagePresentation.summary(usage: nil, duration: 400) == "6m 40s")
        precondition(ChatUsagePresentation.summary(usage: CompletionUsage(outputTokens: 321), duration: nil) == "321 output tokens")
        precondition(ChatUsagePresentation.duration(.nan) == nil && ChatUsagePresentation.duration(-1) == nil)
        let now = Date(timeIntervalSince1970: 1_000)
        let oldSnapshot = CodexUsageSnapshot(windows: [CodexUsageWindow(id: "primary", usedPercent: 25,
            windowDurationMinutes: 300, resetsAt: now.addingTimeInterval(30))], fetchedAt: now)
        precondition(!ChatUsagePresentation.isStale(oldSnapshot, now: now))
        precondition(ChatUsagePresentation.isStale(oldSnapshot, now: now.addingTimeInterval(30)))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [UsageFixtureProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let monitor = CodexUsageMonitor(client: ProviderClient(session: session))
        let configuration = ProviderConfiguration(provider: ProviderCatalog.provider(id: "codex"), model: "fixture",
            endpoint: "https://usage.fixture.test/v1/chat/completions", apiKey: "fixture", language: .english,
            reasoningEffort: "max", fastClaudeMode: false)
        await monitor.refresh(configuration: configuration, force: true)
        precondition(monitor.error == nil && !monitor.isRefreshing)
        precondition(monitor.snapshot?.windows.map(\.remainingPercent) == [73, 91])

        // Closing the composer must not cancel the fresh sample queued by an
        // answer that completed while the original request was in flight.
        let initialRequests = UsageFixtureState.shared.requestCount
        UsageFixtureState.shared.holdNext()
        let interrupted = Task { await monitor.refresh(configuration: configuration, force: true) }
        for _ in 0..<100 where UsageFixtureState.shared.requestCount == initialRequests {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(monitor.isRefreshing)
        await monitor.refresh(configuration: configuration, force: true)
        interrupted.cancel()
        await interrupted.value
        for _ in 0..<100 where UsageFixtureState.shared.requestCount < initialRequests + 2 || monitor.isRefreshing {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(UsageFixtureState.shared.requestCount == initialRequests + 2 && !monitor.isRefreshing && monitor.error == nil,
            "A post-answer refresh must survive cancellation of the view's old request")

        let doc = StudyDocument(title: "KybintroKompendium.pdf", kind: .pdf, fileName: "original.pdf", pageCount: 176)
        let source = """
        The closest match is **PD control [pp. 77–81]**.

        | Relevant reading | Connection to this model |
        |---|---|
        | **PD control [pp. 77–81]** | Position and velocity feedback supply damping. See equation (6.17) [p. 79]. |
        | **Mechanical modelling [pp. 20–21]** | Newton’s force balance explains acceleration. |
        """
        let preview = VStack(alignment: .leading, spacing: 18) {
            Text("Chat preview · fixture data").font(.caption).foregroundStyle(.secondary)
            RichMarkdownView(source: source, compact: true,
                references: ChatReferenceContext(documents: [doc], defaultDocumentID: doc.id))
            ChatResponseUsageView(usage: usage, duration: 400)
            VStack(alignment: .leading, spacing: 16) {
                Text("Ask about what you're reading…").font(.callout).foregroundStyle(.secondary)
                Text("GPT-6 Astra ⌄").font(.caption)
                HStack(spacing: 12) {
                    Label("Auto ⌄", systemImage: "globe")
                    Label("Manual ⌄", systemImage: "bolt")
                    Label("Max ⌄", systemImage: "brain")
                    CodexUsageIndicator(monitor: monitor, configuration: configuration)
                }.font(.system(size: 10))
            }.padding(14).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            Spacer(minLength: 0)
        }.padding(20).frame(width: 400, height: 620)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = NSHostingController(rootView: preview)
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let view = window.contentView!
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("native-chat-usage.png"))
        window.close()
    }
}
