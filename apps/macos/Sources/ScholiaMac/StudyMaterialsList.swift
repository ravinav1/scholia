import SwiftUI

struct StudyMaterialsList: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    let course: StudyCourse
    var query = ""
    var compact = false
    @AppStorage private var collapsed: String
    @AppStorage private var materialView: String
    private var materialCache: StudyMaterialListCache { workspace.materialListCache }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(workspace: StudyWorkspaceModel, course: StudyCourse, query: String = "", compact: Bool = false) {
        self.workspace = workspace
        self.course = course
        self.query = query
        self.compact = compact
        _collapsed = AppStorage(wrappedValue: "assets", "study.materialGroups.\(course.id)")
        _materialView = AppStorage(wrappedValue: "organized", "study.materialView.\(course.id)")
    }
    private var closed: Set<String> { Set(collapsed.split(separator: "|").map(String.init)) }
    private func toggle(_ id: String) {
        var values = closed
        if !values.insert(id).inserted { values.remove(id) }
        collapsed = values.sorted().joined(separator: "|")
    }
    var body: some View {
        let flat = !compact && materialView == "files"
        let groups = flat ? [] : materialCache.groups(for: course, query: query)
        let references = materialCache.references(for: course)
        let closed = closed
        LazyVStack(alignment: .leading, spacing: compact ? 8 : 20) {
            if flat {
                let files = materialCache.files(for: course, query: query)
                Text("\(files.count) files").font(.caption).foregroundStyle(.secondary)
                LazyVStack(spacing: 4) {
                    ForEach(files) { entry in material(entry, reference: references[entry.materialID ?? ""]) }
                }
                if files.isEmpty {
                    Text(query.isEmpty ? "No files in this workspace yet." : "No matching files.").font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(flat ? [] : groups) { group in
                let isCanvas = ["module:", "canvas-page:", "folder:"].contains { group.id.hasPrefix($0) }
                let topicGroups = !isCanvas && group.items.contains { $0.topic != nil }
                let expanded = !closed.contains(group.id) || !query.isEmpty
                LazyVStack(alignment: .leading, spacing: compact ? 2 : 8) {
                    Button {
                        toggle(group.id)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                            Text(group.title).font(.system(size: compact ? 11 : 14, weight: .semibold)).lineLimit(
                                compact ? 2 : nil)
                            Spacer(minLength: 3)
                            Text("\(group.items.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(
                                .tertiary)
                        }.padding(.horizontal, compact ? 9 : 2).padding(.vertical, 7).contentShape(Rectangle())
                    }.scholiaButtonStyle(.plain).help(group.basis).accessibilityLabel(
                        "\(group.title), \(group.items.count) materials")
                        .accessibilityValue(closed.contains(group.id) && query.isEmpty ? "Collapsed" : "Expanded")
                    if expanded {
                        if !compact {
                            Text(group.basis).font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 3)
                        }
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { offset, entry in
                            let heading = isCanvas ? entry.canvasHeading : topicGroups ? entry.topic ?? group.title : nil
                            let previous = offset == 0 ? nil : isCanvas ? group.items[offset - 1].canvasHeading
                                : group.items[offset - 1].topic ?? group.title
                            if let heading, heading != previous, heading != group.title {
                                Text(heading).font(.system(size: compact ? 9 : 11, weight: .medium))
                                    .foregroundStyle(.secondary).padding(.top, 5).padding(.horizontal, compact ? 9 : 2)
                            }
                            if isCanvas, let section = entry.canvasSubheading,
                                offset == 0 || heading != previous || section != group.items[offset - 1].canvasSubheading {
                                Text(section).font(.system(size: compact ? 9 : 10)).foregroundStyle(.tertiary)
                                    .padding(.top, 3).padding(.horizontal, compact ? 9 : 2)
                            }
                            material(entry, reference: references[entry.materialID ?? ""], showTopic: !topicGroups)
                                .transition(.opacity)
                        }
                    }
                }.animation(reduceMotion ? nil : ScholiaVisualStyle.fastAnimation, value: expanded)
            }
            if !flat && groups.isEmpty && !query.isEmpty {
                Text("No matching materials").font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
    }
    private func material(_ entry: StudyMaterialEntry, reference: CanvasMaterialReference?, showTopic: Bool = true) -> some View {
        let isAssignment = reference?.kind == .assignments
        let selected = workspace.library.selectedCourseID == course.id && (
            isAssignment
            ? workspace.library.selectedAssignmentID == reference?.id
            : entry.documentID != nil && workspace.library.selectedDocumentID == entry.documentID)
        return HStack(spacing: 4) {
            Button {
                if isAssignment, let reference {
                    workspace.openAssignment(reference, courseID: course.id)
                } else if let id = entry.documentID {
                    workspace.selectDocument(id)
                } else if let reference {
                    workspace.openCanvasMaterial(reference, courseID: course.id)
                }
            } label: {
                HStack(alignment: compact ? .top : .center, spacing: compact ? 8 : 12) {
                    Image(systemName: entry.symbol).font(.system(size: compact ? 12 : 20, weight: .light))
                        .foregroundStyle(.secondary).frame(width: compact ? 15 : 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(
                            .system(size: compact ? 11 : 13, weight: selected ? .semibold : .regular)
                        ).lineLimit(compact ? 2 : 3).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !compact {
                            if showTopic, let topic = entry.topic { Text(topic).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                            Text(entry.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                            if entry.extractionMethod == "ocr" || entry.extractionMethod == "mixed" {
                                Text("Text includes on-device OCR").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                        }
                        if isAssignment && reference?.assignment?.requiresSubmission != false {
                            StudySubmissionBadge(status: entry.submissionStatus, grade: entry.assignment?.gradeLabel,
                                feedback: entry.assignment?.hasFeedback == true, corrected: entry.assignment?.progressOverride != nil)
                        }
                        if let badge = entry.badge {
                            Text(badge).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.accentColor)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: entry.documentID == nil ? "icloud.and.arrow.down" : "internaldrive").font(
                        .system(size: 10)
                    ).foregroundStyle(.tertiary)
                        .help(entry.documentID == nil ? "Download on demand" : "Saved offline")
                }.padding(.horizontal, compact ? 9 : 13).padding(.vertical, compact ? 8 : 12)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .background(
                        selected ? Color.accentColor.opacity(0.10) : compact ? .clear : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: compact ? 7 : 10))
            }.scholiaButtonStyle(.plain).help("\(entry.title)\n\(reference?.unavailableReason ?? entry.classificationBasis)").disabled(
                !isAssignment && entry.documentID == nil
                    && (workspace.canvasBusy || reference?.unavailableReason != nil)
            )
            .accessibilityLabel(entry.title)
            .accessibilityValue([
                entry.documentID != nil ? "Saved offline" : reference?.unavailableReason ?? "Download on demand",
                entry.requiresSubmission == false ? nil : entry.submissionStatus?.submissionLabel,
                entry.assignment?.gradeLabel,
                entry.assignment?.hasFeedback == true ? "Feedback available" : nil,
                entry.badge
            ].compactMap { $0 }.joined(separator: ". "))
            .contextMenu {
                if entry.updateAvailable, let reference {
                    Button("Download updated version") { workspace.openCanvasMaterial(reference, courseID: course.id) }
                        .disabled(workspace.canvasBusy)
                }
                if let id = entry.documentID {
                    Button("Remove downloaded copy", role: .destructive) { workspace.removeDocument(id) }.disabled(
                        workspace.canvasBusy || workspace.isImporting || workspace.isStreaming)
                }
            }
            if !compact, entry.updateAvailable, let reference {
                Button("Update") { workspace.openCanvasMaterial(reference, courseID: course.id) }.controlSize(.small)
                    .disabled(workspace.canvasBusy)
            }
            if let source = entry.sourceURL, let url = URL(string: source), url.scheme == "https" {
                Link(destination: url) { Image(systemName: "arrow.up.right").font(.system(size: 11)) }
                    .buttonStyle(ScholiaIconButtonStyle())
                    .help("Open original source for \(entry.title)")
                    .accessibilityLabel("Open original source for \(entry.title)")
            }
        }
    }
}
