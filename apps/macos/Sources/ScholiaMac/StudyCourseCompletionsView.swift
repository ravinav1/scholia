import SwiftUI
import WebKit

struct StudentwebResultsImportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session: StudentwebImportSession
    @ObservedObject var workspace: StudyWorkspaceModel
    let onSaved: (Int) -> Void

    init(workspace: StudyWorkspaceModel, onSaved: @escaping (Int) -> Void) {
        self.workspace = workspace
        self.onSaved = onSaved
        _session = StateObject(wrappedValue: StudentwebImportSession(resultsMode: true, connection: workspace.studentwebResultsConnection))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Check Studentweb · NTNU").font(.system(size: 23, design: .serif))
                Spacer()
                Button("Cancel") { session.finish(); dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(session.savingResults)
            }
            Text("Results are checked and saved automatically. Only course codes and passed / not passed reach Scholia. Sign in on Studentweb if asked; your login stays in this browser’s memory until you quit or forget the sign-in.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Label(session.host, systemImage: "lock.fill").font(.caption)
                if session.loading || session.extracting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Use ID and PIN") { session.usePINSignIn() }.disabled(session.savingResults)
                Button("Try again") { session.refresh() }.disabled(session.savingResults)
            }
            ZStack {
                // Native opacity does not change the page's DOM visibility.
                // Authentication is interactive; the transcript never flashes
                // on screen while its statuses are reduced inside WebKit.
                StudentwebBrowser(session: session)
                    .opacity(session.showingSignIn ? 1 : 0)
                    .allowsHitTesting(session.showingSignIn && !session.savingResults)
                    .accessibilityHidden(!session.showingSignIn)
                if !session.showingSignIn {
                    VStack(spacing: 12) {
                        if session.failure == nil { ProgressView() }
                        Text(session.failure == nil ? "Checking course pass statuses…" : "Your saved statuses were kept.")
                            .foregroundStyle(.secondary)
                    }
                }
            }.frame(minHeight: 410).clipShape(RoundedRectangle(cornerRadius: 8))
            Text(session.status).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = session.failure { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(20).frame(minWidth: 820, idealWidth: 960, minHeight: 640, idealHeight: 740)
            .interactiveDismissDisabled(session.savingResults)
            .onAppear {
                session.onResults = { [weak workspace = workspace] rows in
                    guard let workspace else { throw StudentwebResults.invalid }
                    try await workspace.replaceCourseCompletions(rows)
                }
            }
            .onChange(of: session.savedResults) { _, saved in
                if saved { onSaved(session.completions.count); dismiss() }
            }
            .onDisappear { session.finish() }
    }
}

struct StudyCourseCompletionsView: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    var checkOnOpen = false
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var started = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Course pass statuses").font(.system(size: 25, design: .serif))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Stored on this Mac in your local Keychain: a course code and passed / not passed. No grades, result dates, attempts or personal details. Statuses stay out of the web client, library exports and search. When you use Get advice, passed course codes are included in requests to your selected model.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text("Passed courses are labelled in your workspace and skipped when building a native exam selection. You can still select a retake manually. Courses without a recognised result remain unknown.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack {
                Button("Check Studentweb") { message = nil; importing = true }
                    .buttonStyle(.borderedProminent)
                Button("Forget sign-in") {
                    workspace.studentwebResultsConnection.disconnect()
                    message = "Sign-in forgotten. Saved pass statuses are unchanged."
                }
                Spacer()
                if !workspace.courseCompletions.isEmpty || workspace.courseCompletionsError != nil {
                    Button("Delete all saved statuses", role: .destructive) { save([]) }
                }
            }.disabled(workspace.courseCompletionsBusy)
            let rows = workspace.courseCompletions
            ScrollView {
                LazyVStack(spacing: 10) {
                    if rows.isEmpty {
                        Text("No pass statuses saved.").foregroundStyle(.secondary).padding(25)
                    }
                    ForEach(rows) { row in
                        HStack {
                            Text(row.courseCode).font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(row.passed ? "Passed" : "Not passed").foregroundStyle(.secondary)
                            Button("Delete", role: .destructive) {
                                save(workspace.courseCompletions.filter { $0.id != row.id })
                            }.controlSize(.small).disabled(workspace.courseCompletionsBusy)
                        }.padding(.vertical, 4)
                    }
                }
            }.frame(minHeight: 150, maxHeight: .infinity)
            if let error = workspace.courseCompletionsError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button("Retry Keychain access") { Task { await workspace.loadCourseCompletions(allowInteraction: true) } }
                        .disabled(workspace.courseCompletionsBusy)
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.padding(24).frame(width: 680, height: 570)
            .background(Color(nsColor: .windowBackgroundColor))
            .task {
                await workspace.loadCourseCompletions()
                if checkOnOpen, !started { started = true; importing = true }
            }
            .sheet(isPresented: $importing) {
                StudentwebResultsImportView(workspace: workspace) { count in
                    message = "Updated \(count) course pass statuses on this Mac."
                }
            }
    }

    private func save(_ rows: [StudyCourseCompletion]) {
        Task {
            do {
                try await workspace.replaceCourseCompletions(rows)
                message = rows.isEmpty ? "Saved statuses deleted from this Mac." : "Pass statuses saved on this Mac."
            } catch { message = error.localizedDescription }
        }
    }
}
