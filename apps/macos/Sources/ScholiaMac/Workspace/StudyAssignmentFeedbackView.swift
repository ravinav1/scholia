import SwiftUI

struct StudyAssignmentFeedbackView: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    let courseID: UUID
    let assignmentID: String
    var showsTitle = true
    var onOpenAttachment: () -> Void = {}

    private var assignment: CanvasMaterialReference? {
        workspace.library.courses.first { $0.id == courseID }?.materials.first { $0.id == assignmentID }
    }
    private var key: String { workspace.feedbackKey(courseID: courseID, assignmentID: assignmentID) }
    private var refreshing: Bool { workspace.feedbackRefreshing.contains(key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if showsTitle { Text("Feedback").font(.system(size: 14, weight: .semibold)) }
                Spacer()
                if refreshing { ProgressView().controlSize(.mini).accessibilityLabel("Refreshing feedback") }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await workspace.refreshAssignmentFeedback(courseID: courseID, assignmentID: assignmentID, force: true) }
                }.disabled(refreshing).controlSize(.small).help("Fetch current feedback from Canvas")
            }
            if let message = workspace.feedbackErrors[key] {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if workspace.canvasNeedsAuthentication {
                    Button("Reconnect Canvas") { Task { await workspace.retryCanvasSignIn() } }.controlSize(.small)
                }
            }
            if let feedback = assignment?.assignment?.feedback, !feedback.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(feedback.comments) { comment in commentView(comment) }
                        if !feedback.rubric.isEmpty {
                            Text("Rubric").font(.system(size: 12, weight: .semibold))
                            ForEach(feedback.rubric) { criterion in rubricView(criterion) }
                        }
                    }.padding(.trailing, 5).padding(.vertical, 3)
                }
            } else {
                Text(refreshing ? "Loading feedback…" : assignment?.assignment?.feedback == nil
                    ? "Feedback has not been downloaded yet. Refresh to load it from Canvas."
                    : "No written feedback or attachments have been posted in Canvas yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.vertical, 5)
            }
        }
        .task(id: key) { await workspace.refreshAssignmentFeedback(courseID: courseID, assignmentID: assignmentID) }
    }

    private func commentView(_ comment: CanvasFeedbackComment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(comment.author).font(.system(size: 12, weight: .semibold))
                if !comment.currentAttempt {
                    Text(comment.attempt.map { "Earlier attempt · \($0)" } ?? "Earlier feedback")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let date = CanvasAssignmentDetails.date(comment.createdAt) {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if !comment.text.isEmpty {
                Text(comment.text).font(.system(size: 12)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(comment.attachments) { attachment in
                attachmentView(attachment)
            }
            if let media = comment.mediaType, let value = assignment?.sourceURL,
                let url = URL(string: value), url.scheme == "https" {
                Link("Open \(media) feedback in Canvas ↗", destination: url).font(.system(size: 11))
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private func attachmentView(_ attachment: CanvasFeedbackAttachment) -> some View {
        let file = workspace.assignmentFeedbackFiles.first { $0.id == attachment.materialID }
        let reading = workspace.document?.sourceKey == attachment.materialID
        return HStack(alignment: .center, spacing: 9) {
            Image(systemName: "paperclip").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.name).font(.system(size: 11, weight: .medium)).lineLimit(2)
                if let file {
                    Text(workspace.assignmentFileStatus(file)).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button(reading ? "Reading" : "Open") {
                workspace.openAssignmentFile(attachment.materialID)
                onOpenAttachment()
            }.controlSize(.small).disabled(reading || file?.unavailableReason != nil || file == nil)
                .help(file?.unavailableReason ?? "Open this feedback attachment in Scholia")
                .accessibilityLabel("Open feedback attachment: \(attachment.name)")
        }.padding(.vertical, 4)
    }

    private func rubricView(_ criterion: CanvasRubricFeedback) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(criterion.title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                if let score = criterion.scoreLabel { Text(score).font(.system(size: 11)).monospacedDigit() }
            }
            if let description = criterion.description, !description.isEmpty {
                Text(description).font(.system(size: 11)).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let rating = criterion.rating, !rating.isEmpty { Text(rating).font(.system(size: 11)).foregroundStyle(.secondary) }
            if let comment = criterion.comment, !comment.isEmpty {
                Text(comment).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }
}
