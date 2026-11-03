import Foundation
import SwiftUI

/// Shared by chat surfaces so opening two composers does not double polling.
@MainActor
final class CodexUsageMonitor: ObservableObject {
    @Published private(set) var snapshot: CodexUsageSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false
    private let client: ProviderClient
    private var configurationKey: String?
    private var requestID: UUID?
    private var lastAttempt: Date?
    private var refreshAgain = false

    init(client: ProviderClient = ProviderClient()) { self.client = client }

    func refresh(configuration: ProviderConfiguration, force: Bool = false) async {
        guard configuration.provider.id == "codex" else { return }
        let key = configuration.endpoint + "\n" + configuration.apiKey
        if configurationKey != key {
            configurationKey = key
            snapshot = nil
            error = nil
            lastAttempt = nil
            requestID = nil
            refreshAgain = false
        }
        if requestID != nil {
            // An in-flight sample may predate the answer that just finished.
            if force { refreshAgain = true }
            return
        }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < 55 { return }
        let id = UUID()
        requestID = id
        lastAttempt = Date()
        isRefreshing = true
        do {
            let value = try await client.codexUsage(configuration: configuration, forceRefresh: force)
            guard requestID == id else { return }
            snapshot = value
            error = nil
        } catch {
            guard requestID == id else { return }
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                lastAttempt = nil
            } else {
                self.error = error.localizedDescription
            }
        }
        guard requestID == id else { return }
        requestID = nil
        isRefreshing = false
        if refreshAgain {
            refreshAgain = false
            // The view that began the old fetch may have disappeared. A queued
            // post-answer sample must not inherit that fetch's cancellation.
            Task { await refresh(configuration: configuration, force: true) }
        }
    }
}

enum ChatUsagePresentation {
    static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return nil }
        let value = Int(seconds.rounded(.down))
        if value < 1 { return "<1s" }
        if value < 60 { return "\(value)s" }
        if value < 3_600 { return "\(value / 60)m \(value % 60)s" }
        return "\(value / 3_600)h \((value % 3_600) / 60)m"
    }

    static func summary(usage: CompletionUsage?, duration: Double?) -> String {
        var parts = [Self.duration(duration ?? usage?.elapsedSeconds)].compactMap { $0 }
        if let total = usage?.totalTokens, total >= 0 {
            parts.append("\(total.formatted()) tokens")
        } else if let output = usage?.outputTokens, output >= 0 {
            parts.append("\(output.formatted()) output tokens")
        } else if let input = usage?.inputTokens, input >= 0 {
            parts.append("\(input.formatted()) input tokens")
        }
        return parts.joined(separator: " · ")
    }

    static func isStale(_ snapshot: CodexUsageSnapshot, now: Date) -> Bool {
        now.timeIntervalSince(snapshot.fetchedAt) > 120
            || snapshot.windows.contains { $0.resetsAt.map { $0 <= now } ?? false }
    }
}

struct CodexUsageIndicator: View {
    @ObservedObject var monitor: CodexUsageMonitor
    let configuration: ProviderConfiguration?
    @State private var presented = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            Button { presented.toggle() } label: {
                Label(label(at: timeline.date), systemImage: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize()
            }
            .scholiaButtonStyle(.plain)
            .accessibilityLabel("Codex allowance: \(label(at: timeline.date))")
            .accessibilityIdentifier("codex-usage-indicator")
            .help("Codex allowance remaining. Click for each limit window, reset times, and refresh.")
            .popover(isPresented: $presented) { details }
        }
        .task(id: configuration.map { $0.endpoint + "\n" + $0.apiKey }) {
            guard let configuration else { return }
            await monitor.refresh(configuration: configuration)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                if scenePhase == .active { await monitor.refresh(configuration: configuration) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let configuration else { return }
            Task { await monitor.refresh(configuration: configuration) }
        }
    }

    private func label(at now: Date) -> String {
        guard let snapshot = monitor.snapshot,
              let remaining = snapshot.windows.map(\.remainingPercent).min() else {
            return monitor.isRefreshing ? "Usage…" : "Usage unavailable"
        }
        guard monitor.error == nil, !ChatUsagePresentation.isStale(snapshot, now: now) else {
            return "Usage outdated"
        }
        return "\(remaining.formatted(.number.precision(.fractionLength(0...1))))% left"
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Codex allowance").font(.headline)
                Spacer()
                if monitor.isRefreshing { ProgressView().controlSize(.small) }
                Button {
                    guard let configuration else { return }
                    Task { await monitor.refresh(configuration: configuration, force: true) }
                } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(monitor.isRefreshing || configuration == nil)
                    .accessibilityLabel("Refresh Codex allowance")
            }
            if let snapshot = monitor.snapshot {
                if let name = snapshot.limitName, !name.isEmpty { Text(name).font(.caption).foregroundStyle(.secondary) }
                ForEach(snapshot.windows) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(window.label)
                            Spacer()
                            Text("\(window.remainingPercent.formatted(.number.precision(.fractionLength(0...1))))% left").monospacedDigit()
                        }.font(.caption)
                        ProgressView(value: window.remainingPercent, total: 100)
                            .accessibilityLabel("\(window.label) remaining")
                        if let reset = window.resetsAt {
                            Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Checked \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = monitor.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            if monitor.snapshot == nil && monitor.error == nil {
                Text(monitor.isRefreshing ? "Checking your Codex account…" : "No allowance has been reported yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Shared across Codex activity. The indicator shows the lowest remaining window. Each answer shows its measured tokens and time; tokens do not convert directly to an allowance percentage.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(width: 300)
    }
}

struct ChatResponseUsageView: View {
    let usage: CompletionUsage?
    let duration: Double?
    @State private var presented = false

    var body: some View {
        let summary = ChatUsagePresentation.summary(usage: usage, duration: duration)
        if !summary.isEmpty {
            Button { presented.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                    Text(summary)
                    Image(systemName: "info.circle")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }.scholiaButtonStyle(.plain)
                .accessibilityLabel("Response usage: \(summary). Show details")
                .popover(isPresented: $presented) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Response usage").font(.headline)
                        if let elapsed = ChatUsagePresentation.duration(duration ?? usage?.elapsedSeconds) {
                            metric("Elapsed", value: elapsed)
                        }
                        if let input = usage?.inputTokens { metric("Input tokens", value: input.formatted()) }
                        if let cached = usage?.cachedInputTokens { metric("Cached input (included above)", value: cached.formatted()) }
                        if let output = usage?.outputTokens { metric("Output tokens", value: output.formatted()) }
                        if let count = usage?.requestCount, count > 1 { metric("Model requests", value: count.formatted()) }
                        Text(usage?.totalTokens == nil
                            ? "The provider did not report a complete token total for this answer."
                            : "Measured across this answer’s model requests, including tool follow-ups. Cached input is part of input tokens.")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("Elapsed time includes preparing sources and reading files. Token counts are not a price or a subscription percentage.")
                            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(16).frame(width: 300)
                }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        HStack { Text(title); Spacer(); Text(value).monospacedDigit() }.font(.caption)
    }
}
