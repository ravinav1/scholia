import SwiftUI

/// Shows the answer to one selection while the existing study conversation saves it.
struct StudySelectionResponseView: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    let courseID: UUID?
    let threadID: UUID?
    let answerID: UUID?
    let sourceTitle: String
    let initialError: String?
    var onClose: () -> Void
    var onOpenChat: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    init(workspace: StudyWorkspaceModel, onClose: @escaping () -> Void, onOpenChat: @escaping () -> Void) {
        self.workspace = workspace
        courseID = workspace.course?.id
        threadID = workspace.thread?.id
        answerID = workspace.isCurrentThreadStreaming ? workspace.messages.last?.id : nil
        sourceTitle = workspace.document.map { "\($0.title) · page \(workspace.currentPage)" }
            ?? workspace.course?.displayName ?? "Selected passage"
        initialError = answerID == nil ? workspace.error : nil
        self.onClose = onClose
        self.onOpenChat = onOpenChat
    }

    private var thread: StudyThread? {
        workspace.library.courses.first { $0.id == courseID }?.threads.first { $0.id == threadID }
    }
    private var answer: ConversationMessage? { thread?.messages.first { $0.id == answerID } }
    private var responseError: String? {
        initialError ?? (answer?.metadata == "Response interrupted" ? workspace.error : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Explanation").font(.system(size: 18, design: .serif))
                    Text(sourceTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(sourceTitle)
                }
                Spacer(minLength: 0)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .scholiaButtonStyle(.plain).help("Close explanation")
                    .accessibilityLabel("Close explanation").keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let answer {
                        if let reasoning = answer.reasoning, !reasoning.isEmpty {
                            ProviderReasoningView(source: reasoning, compact: true)
                        }
                        if !answer.content.isEmpty {
                            RichMarkdownView(source: answer.content, compact: true, onOpenLink: workspace.openCourseLink)
                        }
                        if answer.isStreaming {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(answer.metadata ?? "Preparing your answer…").font(.caption).foregroundStyle(.secondary)
                            }
                        } else if let metadata = answer.metadata {
                            Text(metadata).font(.caption2).foregroundStyle(.secondary)
                        }
                        if !answer.isStreaming, let sources = thread?.sources[answer.id.uuidString], !sources.isEmpty {
                            DisclosureGroup("Sources · \(sources.count) pages") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(sources) { source in
                                        Button("\(source.title) · p. \(source.page)") {
                                            onClose()
                                            workspace.navigate(to: source)
                                        }.font(.caption).scholiaButtonStyle(.plain)
                                    }
                                }.padding(.top, 6)
                            }.font(.caption)
                        }
                    }
                    if let responseError {
                        Label(responseError, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button("Open in chat", action: onOpenChat)
                Spacer()
                if answer?.isStreaming == true {
                    Button("Stop", action: workspace.stopAnswer)
                } else if let answer, !answer.content.isEmpty {
                    Button("Copy answer", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer.content, forType: .string)
                    }
                }
            }.controlSize(.small).padding(12)
        }.frame(width: 460, height: 440)
            .background(StudyPalette.paper(colorScheme == .dark))
            .tint(ScholiaVisualStyle.accentColor(for: colorScheme))
            .accessibilityIdentifier("study-selection-response")
    }
}
