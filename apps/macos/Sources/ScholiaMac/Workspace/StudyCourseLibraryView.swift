import SwiftUI

struct StudyCourseLibraryView: View, Equatable {
    let workspace: StudyWorkspaceModel
    @StateObject private var dashboard: StudyDashboardState
    var createCourse: () -> Void
    @State private var query = ""
    @State private var resultsPresented = false
    @State private var hidePassed = false
    @Environment(\.colorScheme) private var scheme

    init(workspace: StudyWorkspaceModel, createCourse: @escaping () -> Void) {
        self.workspace = workspace
        self.createCourse = createCourse
        _dashboard = StateObject(wrappedValue: workspace.dashboardState)
    }
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.workspace === rhs.workspace }

    private var courses: [StudyCourse] {
        let selectedSemester = workspace.selectedSemesterID
        let courseIDs = Set(workspace.semesterGroups.first { $0.id == selectedSemester }?.courseIDs ?? [])
        let favoritesOnly = workspace.courseLibraryView == .favorites
        return workspace.courses(matching: query).filter {
            (!favoritesOnly || $0.isFavorite)
                && (!hidePassed || workspace.coursePassed($0.displayCode) != true)
                && (selectedSemester == "all" || courseIDs.contains($0.id))

        }
    }
    var body: some View {
        let _ = dashboard.revision
        let displayedCourses = courses
        let pendingFiles = displayedCourses.reduce(0) { $0 + ($1.canvasFileSync?.pendingFileIDs.count ?? 0) }
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 21) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your study workspace").font(.system(size: 27, design: .serif))
                        Text("Pick up a reading. Keep your next deadline in sight.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        workspace.checkForNewCanvasFiles(courseIDs: displayedCourses.map(\.id), download: pendingFiles > 0 ? true : nil)
                    } label: {
                        Label(workspace.canvasFileSyncRunning ? "Checking files…"
                            : pendingFiles > 0 ? "Download new files · \(pendingFiles)" : "Check for new files", systemImage: "arrow.down.circle")
                    }.controlSize(.regular).disabled(workspace.canvasBusy || displayedCourses.isEmpty)
                        .help("Check the displayed courses and download newly discovered files")
                    Menu {
                        Button("Studentweb results…") { resultsPresented = true }
                        Button("Refresh course catalog") { workspace.loadCanvasCourses() }
                        Button("Canvas settings") { workspace.canvasPresented = true }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(workspace.canvasBusy)
                        .accessibilityLabel("Canvas options")
                }
                Button { workspace.examPlannerPresented = true } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "calendar.badge.clock").font(.system(size: 24)).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Exam dates").font(.system(size: 13, weight: .semibold))
                            let exams = workspace.library.examPlan ?? []
                            let selected = exams.filter(\.selected).count
                            let conflicts = StudyExamPlanner.collisions(exams).count
                            Text(selected == 0 ? "Choose your exams and see how the dates fit." : "\(selected) exams selected · \(conflicts == 0 ? "No overlaps found" : "\(conflicts) overlaps to review")")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("View schedule →").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                    }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
                }.scholiaButtonStyle(.plain)
                HStack(alignment: .top, spacing: 20) {
                    workspacePanel(displayedCourses).frame(maxWidth: .infinity, maxHeight: .infinity)
                    StudyAssignmentAgendaView(workspace: workspace).equatable()
                        .frame(width: min(370, max(280, geometry.size.width * 0.30)))
                }.frame(maxHeight: .infinity)
            }.padding(24)
        }.background(StudyPalette.paper(scheme == .dark))
            .task { await workspace.loadCourseCompletions() }
            .sheet(isPresented: $resultsPresented) { StudyCourseCompletionsView(workspace: workspace, checkOnOpen: true) }
    }

    private func workspacePanel(_ displayedCourses: [StudyCourse]) -> some View {
        let semesters = workspace.semesterGroups
        let readings = query.isEmpty && workspace.courseLibraryView != .favorites
            ? StudyRecentReading.inCourses(workspace.library.courses, limit: 2) : []
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("Workspaces").font(.system(size: 21, design: .serif))
                Text("\(displayedCourses.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Picker(
                    "Workspace filter",
                    selection: Binding(
                        get: {
                            workspace.courseLibraryView == .favorites ? StudyCourseLibraryViewMode.favorites : .all
                        }, set: workspace.setCourseLibraryView)
                ) {
                    Text("All workspaces").tag(StudyCourseLibraryViewMode.all)
                    Text("Favorites").tag(StudyCourseLibraryViewMode.favorites)
                }.labelsHidden().pickerStyle(.menu).scholiaPointingCursor().fixedSize().accessibilityLabel(
                    "Workspace filter")
            }
            VStack(spacing: 8) {
                if !workspace.courseCompletions.isEmpty {
                    Toggle("Hide passed courses", isOn: $hidePassed).font(.system(size: 11))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a workspace", text: $query).textFieldStyle(.plain)
                        .accessibilityLabel("Find a workspace")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .scholiaButtonStyle(.plain).foregroundStyle(.secondary)
                            .help("Clear workspace search").accessibilityLabel("Clear workspace search")
                    }
                }.font(.system(size: 12)).padding(10)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                HStack(spacing: 8) {
                    Image(systemName: "calendar").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker(
                        "Semester",
                        selection: Binding(get: { workspace.selectedSemesterID }, set: workspace.selectSemester)
                    ) {
                        Text("All semesters").tag("all")
                        ForEach(semesters) { Text($0.title).tag($0.id) }
                    }.labelsHidden().pickerStyle(.menu).scholiaPointingCursor().frame(maxWidth: 220).accessibilityLabel(
                        "Semester")
                    Spacer()
                    if let current = semesters.first(where: \.isCurrent), workspace.selectedSemesterID != current.id {
                        Button("This semester") { workspace.selectSemester(current.id) }
                            .scholiaButtonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if query.isEmpty && workspace.courseLibraryView != .favorites && !readings.isEmpty {
                        StudyContinueReadingView(
                            workspace: workspace, readings: Array(readings.prefix(2)), compact: true)
                    }
                    if displayedCourses.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], spacing: 12) {
                            ForEach(displayedCourses) { StudyCourseLibraryCard(workspace: workspace, course: $0).equatable() }
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "star").font(.system(size: 10))
                        Text("Canvas favorites and your pinned workspaces stay first.").font(.system(size: 10))
                    }.foregroundStyle(.secondary).padding(.bottom, 8)
                }.padding(.trailing, 3)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 11) {
            Image(systemName: "books.vertical").font(.system(size: 25, weight: .light)).foregroundStyle(
                Color.accentColor)
            Text(workspace.library.courses.isEmpty ? "Make room for a course." : "No matching workspaces.")
                .font(.system(size: 22, design: .serif))
            Text(
                workspace.library.courses.isEmpty
                    ? "Connect Canvas or create a workspace for your readings."
                    : "Try another name, semester, or workspace filter."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
            if workspace.library.courses.isEmpty {
                Button("Create workspace", action: createCourse).controlSize(.small)
            }
        }.padding(25).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 13))
    }

}

/// A status update in the shared workspace must not rebuild every course card.
/// Compare only values this card displays; document/catalog contents can change
/// independently without affecting a card whose counts and controls are equal.
struct StudyCourseLibraryCard: View, Equatable {
    private struct Presentation: Equatable, Sendable {
        let name: String
        let code: String
        let term: String?
        let canvasURL: URL?
        let isCanvas: Bool
        let isFavorite: Bool
        let isPassed: Bool
        let indexed: Bool
        let materialCount: Int
        let documentCount: Int
        let pendingFileCount: Int
        let canUpdate: Bool
        let updateTitle: String
        let canvasBusy: Bool
    }
    let workspace: StudyWorkspaceModel
    let course: StudyCourse
    private let presentation: Presentation
    @Environment(\.colorScheme) private var scheme

    init(workspace: StudyWorkspaceModel, course: StudyCourse) {
        self.workspace = workspace
        self.course = course
        presentation = Presentation(name: course.name, code: course.code, term: course.term,
            canvasURL: course.canvasURL, isCanvas: course.canvasID != nil, isFavorite: course.isFavorite,
            isPassed: workspace.coursePassed(course.displayCode) == true, indexed: course.catalogUpdatedAt != nil,
            materialCount: course.canvasMaterials?.count ?? 0, documentCount: course.documents.count,
            pendingFileCount: course.canvasFileSync?.pendingFileIDs.count ?? 0,
            canUpdate: workspace.canUpdateCanvasCourseContent(course), updateTitle: workspace.canvasCourseUpdateTitle(course.id),
            canvasBusy: workspace.canvasBusy)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.workspace === rhs.workspace && lhs.course.id == rhs.course.id && lhs.presentation == rhs.presentation
    }

    var body: some View {
        let canUpdate = presentation.canUpdate
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(course.displayCode.isEmpty ? "PERSONAL WORKSPACE" : course.displayCode)
                    .font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if course.canvasID != nil {
                    Button { workspace.updateCanvasCourseContent(courseIDs: [course.id]) } label: {
                        Image(systemName: "arrow.clockwise")
                    }.scholiaButtonStyle(.plain).disabled(!canUpdate)
                        .help(presentation.updateTitle).accessibilityLabel("Update \(course.displayName)")
                }
                Button {
                    workspace.toggleFavorite(course.id)
                } label: {
                    Image(systemName: course.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(course.isFavorite ? Color.accentColor : .secondary)
                }.scholiaButtonStyle(.plain).help(course.isFavorite ? "Remove favorite" : "Favorite workspace")
                    .accessibilityLabel("\(course.isFavorite ? "Remove favorite" : "Favorite") \(course.name)")
            }
            Button {
                workspace.selectCourse(course.id)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(course.displayName).font(.system(size: 18, design: .serif)).lineLimit(2)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                    Text(course.term ?? (course.canvasID == nil ? "Personal workspace" : "Canvas"))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    if presentation.isPassed {
                        Label("Passed · on this Mac", systemImage: "checkmark.circle")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if let pending = course.canvasFileSync?.pendingFileIDs.count, pending > 0 {
                        Label("\(pending) new \(pending == 1 ? "file" : "files") waiting", systemImage: "arrow.down.circle")
                            .font(.system(size: 10)).foregroundStyle(Color.accentColor)
                    }
                    Divider()
                    HStack {
                        Text(
                            course.canvasID == nil
                                ? "\(course.documents.count) documents"
                                : course.catalogUpdatedAt == nil
                                    ? "Ready to index"
                                    : "\(course.canvasMaterials?.count ?? 0) materials · \(course.documents.count) saved"
                        )
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(Color.accentColor)
                    }
                }.contentShape(Rectangle())
            }.scholiaButtonStyle(.plain).help("Open \(course.displayName)")
            Button("Practice course", systemImage: "checkmark.bubble") {
                workspace.selectCourse(course.id)
                workspace.practiceSourceScope = "course"
                workspace.prepareStudyPrompt(.practice)
            }.controlSize(.small)
        }.padding(15)
            .background(
                scheme == .dark ? Color.white.opacity(0.025) : .white.opacity(0.75),
                in: RoundedRectangle(cornerRadius: 13)
            )
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.primary.opacity(0.07), lineWidth: 1))
            .contextMenu {
                Button("Open workspace") { workspace.selectCourse(course.id) }
                Button(course.isFavorite ? "Remove favorite" : "Favorite") { workspace.toggleFavorite(course.id) }
                if let url = course.canvasURL {
                    Divider()
                    Link("Open in Canvas", destination: url)
                    Button("Update course content") { workspace.updateCanvasCourseContent(courseIDs: [course.id]) }
                        .disabled(!canUpdate)
                    Button("Check for new files") { workspace.checkForNewCanvasFiles(courseIDs: [course.id]) }
                        .disabled(presentation.canvasBusy)
                    if course.canvasFileSync?.pendingFileIDs.isEmpty == false {
                        Button("Download new files") { workspace.checkForNewCanvasFiles(courseIDs: [course.id], download: true) }
                            .disabled(presentation.canvasBusy)
                    }
                    Button("Check for changes") { workspace.syncCanvasCourses(courseIDs: [course.id]) }.disabled(
                        presentation.canvasBusy)
                    Button("Download all materials") {
                        workspace.syncCanvasCourses(courseIDs: [course.id], downloadAll: true)
                    }.disabled(presentation.canvasBusy)
                }
            }
    }
}

struct StudyCourseMaterialsView: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let course: StudyCourse
    var askCourse: () -> Void
    private var courseChatExpanded: Binding<Bool>?
    @State private var localChatExpanded = false
    @State private var query = ""
    @State private var emptyAssignmentsExpanded = false
    @AppStorage private var materialView: String
    @Environment(\.colorScheme) private var colorScheme
    init(workspace: StudyWorkspaceModel, course: StudyCourse, courseChatExpanded: Binding<Bool>? = nil,
         askCourse: @escaping () -> Void) {
        self.workspace = workspace
        self.course = course
        self.courseChatExpanded = courseChatExpanded
        self.askCourse = askCourse
        _materialView = AppStorage(wrappedValue: "organized", "study.materialView.\(course.id)")
    }
    private var chatExpanded: Binding<Bool> { courseChatExpanded ?? $localChatExpanded }
    // Attachments and errors must not squeeze the conversation out of its own panel.
    private var chatExtraHeight: CGFloat {
        (workspace.draftImage == nil ? 0 : 100)
            + (workspace.selectedText.isEmpty ? 0 : 60)
            + (workspace.error == nil ? 0 : 72)
            + (workspace.editingMessageID == nil ? 0 : 26)
    }
    var body: some View {
        GeometryReader { geometry in
            courseContent(chatHeight: min(780, max(480, geometry.size.height * 0.72)) + chatExtraHeight)
        }
    }

    private func courseContent(chatHeight: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Text(course.code.isEmpty ? "YOUR WORKSPACE" : course.displayCode)
                            .font(.system(size: 10, weight: .semibold)).tracking(1)
                            .foregroundStyle(Color.accentColor).lineLimit(1).help(course.code)
                        if let term = course.term {
                            Text("·").foregroundStyle(.tertiary)
                            Text(term).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Text(course.displayName).font(.system(size: 30, design: .serif))
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            chatToggle
                            Spacer(minLength: 12)
                            courseActions
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            chatToggle
                            courseActions
                        }
                    }.controlSize(.regular)
                    if course.canvasID != nil {
                        StudyCourseSyncStatus(workspace: workspace, course: course)
                    }
                    if chatExpanded.wrappedValue {
                        StudyTutorPane(workspace: workspace, inlineCourse: true)
                            .frame(height: chatHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.12), lineWidth: 1))
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Course chat")
                            .accessibilityIdentifier("course-chat-panel")
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                if materialView != "files", query.isEmpty,
                    let reading = StudyRecentReading.inCourses([course], limit: 1).first
                {
                    StudyContinueReadingView(workspace: workspace, readings: [reading])
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Materials").font(.system(size: 21, design: .serif))
                            .accessibilityIdentifier("course-materials-title")
                        Spacer(minLength: 12)
                        Picker("Materials view", selection: $materialView) {
                            Text("Organized").tag("organized")
                            Text("All files").tag("files")
                        }.pickerStyle(.segmented).labelsHidden().scholiaPointingCursor().frame(maxWidth: 210)
                    }
                    if !course.documents.isEmpty || !course.materials.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search materials", text: $query).textFieldStyle(.plain)
                                .accessibilityLabel("Search materials")
                                .accessibilityIdentifier("course-material-search")
                            if !query.isEmpty {
                                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                                    .scholiaButtonStyle(.plain).foregroundStyle(.secondary)
                                    .help("Clear material search").accessibilityLabel("Clear material search")
                            }
                        }.font(.system(size: 12)).padding(10)
                            .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if course.canvasID != nil && materialView != "files" {
                    if StudyAssignment.list(courses: [course]).isEmpty {
                        DisclosureGroup(isExpanded: $emptyAssignmentsExpanded) {
                            StudyAssignmentsView(workspace: workspace, courses: [course], query: query, showCourse: false)
                                .padding(.top, 10)
                        } label: {
                            Label(
                                course.catalogUpdatedAt == nil ? "Assignments · Not indexed yet" : "Assignments · None to submit in indexed materials",
                                systemImage: course.catalogUpdatedAt == nil ? "calendar" : "checkmark.circle")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(12)
                            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                    } else {
                        StudyAssignmentsView(workspace: workspace, courses: [course], query: query, showCourse: false)
                        Divider()
                    }
                }
                if !course.documents.isEmpty || !course.materials.isEmpty {
                    StudyMaterialsList(workspace: workspace, course: course, query: query)
                } else {
                    Text(
                        course.canvasID == nil
                            ? "Drop PDFs, images, or notes here to begin."
                            : "Index this course to discover its readings and assignments."
                    )
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 30)
                }
            }.animation(reduceMotion ? nil : ScholiaVisualStyle.disclosureAnimation, value: chatExpanded.wrappedValue)
                .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatToggle: some View {
        Button {
            if chatExpanded.wrappedValue {
                chatExpanded.wrappedValue = false
            } else {
                chatExpanded.wrappedValue = true
                askCourse()
            }
        } label: {
            HStack(spacing: 8) {
                Label(chatExpanded.wrappedValue ? "Hide course chat" : "Ask about this course",
                      systemImage: "bubble.left.and.bubble.right")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(chatExpanded.wrappedValue ? 180 : 0))
            }.foregroundStyle(colorScheme == .dark ? Color.black.opacity(0.88) : Color.white)
        }.scholiaButtonStyle(.borderedProminent)
            .help(chatExpanded.wrappedValue ? "Collapse course chat" : "Ask about course topics, deadlines, or saved readings")
            .accessibilityIdentifier("course-chat-toggle")
            .accessibilityValue(chatExpanded.wrappedValue ? "Expanded" : "Collapsed")
    }

    @ViewBuilder private var courseActions: some View {
        if course.canvasID != nil {
            HStack(spacing: 10) {
                StudyCourseUpdateButton(workspace: workspace, courseID: course.id)
                Menu("Materials") {
                    Button("Check for new files") { workspace.checkForNewCanvasFiles(courseIDs: [course.id]) }
                    Button(course.catalogUpdatedAt == nil ? "Index materials" : "Check all materials for changes") {
                        workspace.syncCanvasCourses(courseIDs: [course.id])
                    }
                    Button("Download all materials") {
                        workspace.syncCanvasCourses(courseIDs: [course.id], downloadAll: true)
                    }
                }.disabled(workspace.canvasBusy).accessibilityLabel("Material download options")
                if let url = course.canvasURL {
                    Link(destination: url) { Label("Canvas", systemImage: "arrow.up.right.square") }
                        .help("Open course in Canvas").accessibilityLabel("Open course in Canvas")
                }
            }.fixedSize(horizontal: true, vertical: false)
        } else {
            Button(action: workspace.chooseDocuments) { Label("Add documents", systemImage: "plus") }
        }
    }
}

private struct StudyCourseSyncStatus: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    let course: StudyCourse
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var warnings: [String] {
        let messages = (course.catalogWarnings ?? []) + (course.canvasFileSync?.error?.components(separatedBy: "\n") ?? [])
        var seen = Set<String>()
        return messages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    private var needsAttention: Bool { workspace.canvasNeedsAuthentication || !warnings.isEmpty }
    private var checkedAt: Date? {
        [course.canvasFileSync?.checkedAt, course.catalogUpdatedAt, course.syncedAt].compactMap { $0 }.max()
    }
    private var pending: Int { course.canvasFileSync?.pendingFileIDs.count ?? 0 }
    private var title: String {
        if workspace.canvasNeedsAuthentication { return "Reconnect Canvas to check for updates" }
        if !warnings.isEmpty { return "Some course materials couldn’t be checked" }
        if pending > 0 { return "\(pending) new \(pending == 1 ? "file" : "files") ready to download" }
        return checkedAt == nil ? "Course materials haven’t been indexed yet" : "Course materials checked"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: needsAttention ? "exclamationmark.circle" : pending > 0 ? "arrow.down.circle" : checkedAt == nil ? "books.vertical" : "checkmark.circle")
                    .font(.system(size: 16)).foregroundStyle(needsAttention ? Color.orange : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    if let date = checkedAt {
                        Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text("Update this course to find readings and assignments.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if workspace.canvasNeedsAuthentication {
                    Button("Reconnect") { Task { await workspace.retryCanvasSignIn() } }
                        .controlSize(.small).disabled(workspace.canvasBusy)
                        .accessibilityLabel("Reconnect Canvas")
                }
                Button { expanded.toggle() } label: {
                    HStack(spacing: 5) {
                        Text("Details")
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }.font(.system(size: 11)).padding(.vertical, 5)
                }.scholiaButtonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Canvas sync details")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("course-sync-toggle")
            }
            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    if let date = course.catalogUpdatedAt {
                        Text("Catalog checked \(date.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if let date = course.canvasFileSync?.checkedAt {
                        Text("Files checked \(date.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if let updated = course.syncedAt {
                        Text("Content updated \(updated.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if let summary = course.canvasFileSync?.summary { Text(summary) }
                    ForEach(warnings, id: \.self) { Text($0) }
                    Text("Materials download when opened. Saved documents are available offline and to your tutor.")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("course-sync-details")
                    .transition(.opacity)
            }
        }.animation(reduceMotion ? nil : ScholiaVisualStyle.disclosureAnimation, value: expanded)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background((needsAttention ? Color.orange : Color.accentColor).opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                (needsAttention ? Color.orange : Color.accentColor).opacity(0.14), lineWidth: 1))
    }
}

struct StudyContinueReadingView: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    let readings: [StudyRecentReading]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Continue reading").font(.system(size: compact ? 16 : 18, design: .serif))
                Spacer()
            }
            LazyVGrid(columns: [readings.count == 1 ? GridItem(.flexible()) : GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                ForEach(readings) { reading in
                    Button {
                        workspace.resumeReading(reading.document.id)
                    } label: {
                        HStack(spacing: 11) {
                            Image(systemName: reading.document.kind.symbol)
                                .font(.system(size: 18, weight: .light)).foregroundStyle(Color.accentColor)
                                .frame(width: 30, height: 36)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(reading.document.title).font(.system(size: 13, weight: .medium))
                                    .lineLimit(2).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if compact {
                                    Text(reading.courseName).font(.system(size: 10)).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Text(reading.document.readingPosition).font(.system(size: 11))
                                    .foregroundStyle(Color.accentColor).lineLimit(1)
                            }
                            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.accentColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.16), lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                    }.scholiaButtonStyle(.plain).help(
                        "Resume \(reading.document.title), \(reading.document.readingPosition.lowercased())")
                }
            }
        }
    }
}
