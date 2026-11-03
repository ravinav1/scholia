import SwiftUI

struct StudyAssignmentPageView: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    let assignment: CanvasMaterialReference
    @State private var instructionsExpanded = true
    @State private var collapsedFiles: Set<String> = []
    @State private var feedbackExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ASSIGNMENT").font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(
                Color.accentColor)
            Text(assignment.title).font(.system(size: 25, design: .serif)).textSelection(.enabled)
            HStack(spacing: 12) {
                if let date = assignment.assignment?.dueDate {
                    Text("Due \(date.formatted(date: .abbreviated, time: .shortened))")
                } else {
                    Text(assignment.assignment == nil ? "Deadline not synced" : "No due date")
                }
                if assignment.assignment?.requiresSubmission != false {
                    StudySubmissionBadge(status: assignment.assignment?.status, grade: assignment.assignment?.gradeLabel,
                                feedback: assignment.assignment?.hasFeedback == true, corrected: assignment.assignment?.progressOverride != nil)
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                if let courseID = workspace.course?.id {
                    StudyAssignmentStatusMenu(workspace: workspace, courseID: courseID, assignmentID: assignment.id,
                        progress: workspace.course?.assignmentProgress?[assignment.id])
                        .disabled(assignment.assignment == nil)
                }
            }
            if let courseID = workspace.course?.id,
                assignment.assignment?.status.isHandedIn == true || assignment.assignment?.feedback?.isEmpty == false {
                DisclosureGroup(isExpanded: $feedbackExpanded) {
                    StudyAssignmentFeedbackView(workspace: workspace, courseID: courseID, assignmentID: assignment.id, showsTitle: false)
                        .frame(maxHeight: workspace.document == nil ? 320 : 180).padding(.vertical, 8)
                } label: { Text("Feedback").font(.system(size: 12, weight: .semibold)) }
            }
            DisclosureGroup("Instructions", isExpanded: $instructionsExpanded) {
                ScrollView {
                    if workspace.assignmentText.isEmpty {
                        Text(
                            workspace.assignmentPreparing
                                ? "Loading instructions…"
                                : assignment.unavailableReason
                                    ?? "No saved instructions. Retry to load this assignment."
                        )
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(
                            maxWidth: .infinity, alignment: .leading
                        ).padding(.vertical, 8)
                    } else {
                        RichMarkdownView(source: workspace.assignmentText, onOpenLink: workspace.openCourseLink)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                    }
                }.frame(maxHeight: workspace.document == nil ? .infinity : 90)
            }.font(.system(size: 12))
            if !workspace.assignmentFiles.isEmpty {
                DisclosureGroup("Included files · \(workspace.assignmentFiles.count)", isExpanded: filesExpanded) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(workspace.assignmentFiles) { file in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(
                                        systemName: workspace.document?.sourceKey == file.id
                                            ? "doc.text.fill" : "doc.text"
                                    )
                                    .foregroundStyle(Color.accentColor).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(file.fileName ?? file.title).font(.system(size: 11, weight: .medium))
                                            .textSelection(.enabled)
                                        Text(workspace.assignmentFileStatus(file)).font(.system(size: 10))
                                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 6)
                                    Button(workspace.document?.sourceKey == file.id ? "Reading" : "Open") {
                                        workspace.openAssignmentFile(file.id)
                                    }.disabled(
                                        workspace.document?.sourceKey == file.id
                                            || file.unavailableReason != nil
                                    )
                                    .help(
                                        file.unavailableReason
                                            ?? "Download and open \(file.fileName ?? file.title) before other Canvas downloads")
                                }.padding(.vertical, 3)
                            }
                        }.padding(.trailing, 4)
                    }.frame(height: min(170, CGFloat(workspace.assignmentFiles.count) * 48))
                }.font(.system(size: 11, weight: .semibold)).controlSize(.small)
            } else if !workspace.assignmentPreparing && assignment.assignment?.linkedFileIDs != nil
                && workspace.assignmentNotice == nil
            {
                Text("No files are linked to this assignment.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let notice = workspace.assignmentNotice {
                HStack(alignment: .top) {
                    Text(notice).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if assignment.unavailableReason == nil {
                        Button("Retry") {
                            if let course = workspace.course {
                                workspace.openAssignment(assignment, courseID: course.id)
                            }
                        }
                        .controlSize(.small).disabled(workspace.assignmentPreparing)
                    }
                }
            } else if workspace.assignmentPreparing {
                ProgressView("Preparing assignment files for the companion…").controlSize(.small).font(
                    .system(size: 11))
            }
        }.padding(20).frame(
            maxWidth: .infinity, maxHeight: workspace.document == nil ? .infinity : nil, alignment: .topLeading)
    }

    private var filesExpanded: Binding<Bool> {
        let key = "\(workspace.course?.id.uuidString ?? ""):\(assignment.id)"
        return Binding(
            get: { !collapsedFiles.contains(key) },
            set: { expanded in
                if expanded { collapsedFiles.remove(key) } else { collapsedFiles.insert(key) }
            })
    }
}
