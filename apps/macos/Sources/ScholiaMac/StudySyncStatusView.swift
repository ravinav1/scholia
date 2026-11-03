import AppKit
import SwiftUI

/// Keep continuous progress animation in AppKit. A SwiftUI animation timeline
/// makes the entire hosting graph process a new frame, including a long agenda.
struct StudySyncSpinner: NSViewRepresentable {
    func makeNSView(context: Context) -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.isDisplayedWhenStopped = false
        indicator.usesThreadedAnimation = true
        indicator.setAccessibilityElement(false)
        indicator.startAnimation(nil)
        return indicator
    }

    func updateNSView(_ indicator: NSProgressIndicator, context: Context) {}

    static func dismantleNSView(_ indicator: NSProgressIndicator, coordinator: ()) {
        indicator.stopAnimation(nil)
    }
}

struct StudySyncStatusIcon: View {
    let active: Bool
    let needsAttention: Bool
    let reduceMotion: Bool

    var body: some View {
        Group {
            if active && !reduceMotion {
                StudySyncSpinner()
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(active ? Color.accentColor : Color.secondary)
            }
        }
        .frame(width: 16, height: 16)
        .overlay(alignment: .topTrailing) {
            if needsAttention {
                Circle().fill(.orange).frame(width: 5, height: 5).offset(x: 3, y: -3)
            }
        }
    }
}

struct StudySyncActivity: Encodable, Sendable {
    var active: Bool
    var messages: [String]
    var warnings: [String]
    var canStop: Bool
    var canStopPreloading: Bool
    var needsAuthentication: Bool
    var reconnectTitle: String
    var canReconnect: Bool

    var needsAttention: Bool { needsAuthentication || !warnings.isEmpty }
}

extension StudyWorkspaceModel {
    var syncActivity: StudySyncActivity {
        var messages = [activity, canvasStatus, preloadStatus, canvasVerificationStatus].compactMap { $0 }
        if canvasChecking || canvasSigningIn || canvasNeedsAuthentication {
            messages.append(canvasConnectionStatus)
        }
        if assignmentRefreshBusy { messages.append("Checking for assignment updates…") }
        var seen = Set<String>()
        messages = messages.filter { !$0.isEmpty && seen.insert($0).inserted }
        return StudySyncActivity(
            active: canvasBusy || isImporting || activity != nil || preloadStatus != nil || canvasChecking
                || canvasVerifyingDownloads || canvasFileSyncRunning || canvasContentSyncRunning || assignmentRefreshBusy,
            messages: messages, warnings: canvasWarnings,
            canStop: canvasBusy || isImporting || activity != nil,
            canStopPreloading: preloadStatus != nil,
            needsAuthentication: canvasNeedsAuthentication || canvasSigningIn,
            reconnectTitle: canvasReconnectTitle,
            canReconnect: canvasNeedsAuthentication && !canvasBusy && !canvasChecking)
    }
}

struct StudySyncStatusButton: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presented = false

    var body: some View {
        let activity = workspace.syncActivity
        Button { presented.toggle() } label: {
            StudySyncStatusIcon(active: activity.active, needsAttention: activity.needsAttention, reduceMotion: reduceMotion)
        }
        .buttonStyle(ScholiaIconButtonStyle())
        .help(activity.active ? "Sync in progress — show details" : "Show sync activity")
        .accessibilityLabel("Sync activity")
        .accessibilityValue(activity.active ? "In progress" : activity.needsAttention ? "Needs attention" : "Idle")
        .accessibilityIdentifier("workspace-sync-status")
        .popover(isPresented: $presented, arrowEdge: .bottom) {
            StudySyncStatusPanel(workspace: workspace) {
                presented = false
                workspace.canvasPresented = true
            }
        }
    }
}

struct StudySyncStatusPanel: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    var showDetails: () -> Void

    var body: some View {
        let activity = workspace.syncActivity
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Sync activity").font(.headline)
                Spacer()
                Text(activity.active ? "In progress" : "Idle").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if activity.messages.isEmpty {
                        Text(activity.active ? "Syncing your coursework…" : "No sync in progress.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(activity.messages.enumerated()), id: \.offset) { _, message in
                        Text(message).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !activity.warnings.isEmpty {
                        Divider()
                        Label("Notices", systemImage: "exclamationmark.circle").fontWeight(.medium)
                        ForEach(Array(activity.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 300)
            if activity.canStop || activity.canStopPreloading {
                HStack {
                    if activity.canStop {
                        Button("Stop") { workspace.cancelCanvas(); workspace.cancelImport() }
                    }
                    if activity.canStopPreloading {
                        Button("Stop preloading") { workspace.preloadFrequentCourses = false }
                    }
                }
            }
            HStack {
                if workspace.canvasNeedsAuthentication {
                    Button(activity.reconnectTitle) { Task { await workspace.retryCanvasSignIn() } }
                        .disabled(!activity.canReconnect)
                }
                Button("Details", action: showDetails)
                Spacer()
                if !activity.active && workspace.canvasStatus != nil {
                    Button("Clear status") { workspace.canvasStatus = nil }
                }
            }
            .controlSize(.small)
        }
        .padding(18).frame(width: 390)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("workspace-sync-details")
    }
}
