@preconcurrency import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StudyWindowController: NSObject, NSWindowDelegate {
    let workspace: StudyWorkspaceModel
    let window: NSWindow
    private let app: AppModel
    private var focusObservation: AnyCancellable?
    private(set) var fullScreenTransitioning = false
    private var enteredFullScreenForFocus = false

    init(app: AppModel, workspace: StudyWorkspaceModel = StudyWorkspaceModel(), autosave: Bool = true) {
        self.app = app
        self.workspace = workspace
        let size = NSSize(width: 1_420, height: 900)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        super.init()
        window.title = "Scholia"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1_020, height: 640)
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentViewController = PanelContentController(
            rootView: StudyWorkspaceView(workspace: workspace).environmentObject(app), size: size)
        window.delegate = self
        window.center()
        if autosave { window.setFrameAutosaveName("ScholiaStudyWorkspace") }
        focusObservation = workspace.$documentFocused.dropFirst().removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] focused in self?.syncFullScreen(focused: focused) }
    }
    func show() {
        app.studyWindowVisibilityDidChange(true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        workspace.exitDocumentFocus()
        workspace.flush()
        app.studyWindowVisibilityDidChange(false)
    }

    // MARK: Document focus

    var isFullScreen: Bool { window.styleMask.contains(.fullScreen) }
    var windowButtonsHidden: Bool { window.standardWindowButton(.closeButton)?.isHidden == true }

    /// Document focus hides the workspace chrome; the window follows by entering
    /// native full screen, and leaving full screen (Esc, the green button) ends
    /// focus. A window that was already full screen stays that way afterwards.
    private func syncFullScreen(focused: Bool) {
        applyFocusChrome(focused)
        guard !fullScreenTransitioning, window.isVisible else { return }
        if focused, !isFullScreen {
            enteredFullScreenForFocus = true
            window.toggleFullScreen(nil)
        } else if !focused, isFullScreen, enteredFullScreenForFocus {
            enteredFullScreenForFocus = false
            window.toggleFullScreen(nil)
        }
    }
    /// The top bar is gone in focus, so the traffic lights would sit on the
    /// reader toolbar while the full-screen transition runs or if it fails.
    private func applyFocusChrome(_ focused: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = focused
        }
    }
    func windowWillEnterFullScreen(_ notification: Notification) { fullScreenTransitioning = true }
    func windowDidEnterFullScreen(_ notification: Notification) {
        fullScreenTransitioning = false
        // Focus ended while the animation ran: follow it out again.
        if !workspace.documentFocused, enteredFullScreenForFocus { syncFullScreen(focused: false) }
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        fullScreenTransitioning = true
        enteredFullScreenForFocus = false
        workspace.exitDocumentFocus()
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        fullScreenTransitioning = false
        if workspace.documentFocused { syncFullScreen(focused: true) }
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        fullScreenTransitioning = false
        enteredFullScreenForFocus = false
    }
}

enum StudyPalette {
    static let accent = Color(red: 0.20, green: 0.38, blue: 0.32)
    static func paper(_ dark: Bool) -> Color {
        dark ? Color(nsColor: .windowBackgroundColor) : Color(red: 0.985, green: 0.979, blue: 0.960)
    }
    static func canvas(_ dark: Bool) -> Color {
        dark ? Color(nsColor: .underPageBackgroundColor) : Color(red: 0.943, green: 0.939, blue: 0.920)
    }
    static func rail(_ dark: Bool) -> Color {
        dark ? Color(red: 0.12, green: 0.14, blue: 0.13) : Color(red: 0.930, green: 0.943, blue: 0.919)
    }
}

struct StudyWorkspaceView: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var courseSheet = false
    @State private var searchSheet = false
    @State private var searchAllWorkspaces = true
    @State private var quickSwitcherSheet = false
    @State private var keyboardShortcutsSheet = false
    @State private var pendingQuickAction: StudyQuickAction?
    @State private var renaming = false
    @State private var courseName = ""
    @State private var courseCode = ""
    @State private var removeCourseID: UUID?
    @State private var removeThreadID: UUID?
    @State private var workspaceOptionsPresented = false
    @State private var sidebarVisible = true
    @State private var tutorVisible = true
    @State private var courseChatExpanded = false
    @State private var readerReset = 0
    @AppStorage("study.workspacesExpanded") private var workspacesExpanded = true
    @AppStorage("study.materialsExpanded") private var materialsExpanded = true
    private var dark: Bool { colorScheme == .dark }
    private var courseWorkspaceVisible: Bool {
        workspace.course != nil && workspace.document == nil && workspace.assignment == nil
    }
    private var assignmentPDFFocused: Bool {
        workspace.assignmentPDFFocused && workspace.assignment != nil && workspace.document?.kind == .pdf
            && !workspace.isShowingLibrary && !workspace.examPlannerPresented
    }
    private var documentFocused: Bool { workspace.documentFocused && workspace.canFocusDocument }

    var body: some View {
        StudySidebarSplitView(
            sidebar: sidebar.environmentObject(app).scholiaButtonStyle(.automatic)
                .tint(ScholiaVisualStyle.accentColor(for: colorScheme)),
            content: VStack(spacing: 0) {
                if !documentFocused {
                    topbar
                    Divider()
                }
                if workspace.examPlannerPresented {
                    StudyExamScheduleView(workspace: workspace)
                } else if workspace.isShowingAssignments {
                    StudyAssignmentsPageView(workspace: workspace)
                } else if workspace.isShowingLibrary {
                    StudyCourseLibraryView(workspace: workspace, createCourse: showCreateCourse)
                } else {
                    StudyWorkspaceSplitView(
                        reader: StudyReaderPane(
                            workspace: workspace, editing: workspace.documentEditing, tutorVisible: $tutorVisible,
                            courseChatExpanded: $courseChatExpanded,
                            expandReader: { readerReset += 1 }, createCourse: { showCreateCourse() },
                            assignmentFocused: assignmentPDFFocused, documentFocused: documentFocused,
                            showAssignmentOverview: { workspace.assignmentPDFFocused = false }
                        )
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity).clipped()
                        .environmentObject(app).scholiaButtonStyle(.automatic),
                        tutor: Group {
                            if !courseWorkspaceVisible {
                                StudyTutorPane(workspace: workspace, assignmentFocused: assignmentPDFFocused)
                            }
                        }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
                            .environmentObject(app).scholiaButtonStyle(.automatic),
                        tutorVisible: !courseWorkspaceVisible && (assignmentPDFFocused || documentFocused || tutorVisible),
                        readerReset: readerReset,
                        minimumReaderWidth: assignmentPDFFocused || documentFocused ? 420
                            : workspace.document == nil && workspace.assignment == nil ? 380 : 80
                    )
                }
            }.environmentObject(app).scholiaButtonStyle(.automatic)
                .tint(ScholiaVisualStyle.accentColor(for: colorScheme)),
            sidebarVisible: sidebarVisible && !assignmentPDFFocused && !documentFocused
        )
        .background(StudyPalette.paper(dark))
        .tint(ScholiaVisualStyle.accentColor(for: colorScheme))
        .accentColor(ScholiaVisualStyle.accentColor(for: colorScheme))
        .task {
            while !Task.isCancelled {
                await workspace.refreshMathWikiIfNeeded()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .task {
            while !Task.isCancelled {
                await workspace.refreshCanvasAssignmentsIfNeeded()
                await workspace.refreshCanvasContentIfNeeded()
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await workspace.refreshMathWikiIfNeeded() }
            Task {
                await workspace.refreshCanvasAssignmentsIfNeeded()
                await workspace.refreshCanvasContentIfNeeded()
            }
        }
        .onChange(of: workspace.library.selectedCourseID) { _, _ in
            query = ""
            courseChatExpanded = false
            Task { await workspace.refreshMathWikiIfNeeded() }
            Task {
                await workspace.refreshCanvasContentIfNeeded()
            }
        }
        .onChange(of: workspace.automaticallyUpdateCanvasContent) { _, enabled in
            if enabled { Task { await workspace.refreshCanvasContentIfNeeded() } }
        }
        .onChange(of: workspace.automaticallyUpdateMathWiki) { _, enabled in
            if enabled { Task { await workspace.refreshMathWikiIfNeeded() } }
        }
        .onChange(of: workspace.isShowingLibrary) { _, _ in query = "" }
        .onChange(of: workspace.library.selectedDocumentID) { _, _ in
            if workspace.assignment != nil && workspace.document?.kind == .pdf {
                workspace.assignmentPDFFocused = true
            }
        }
        .onChange(of: assignmentPDFFocused) { _, focused in
            if focused { readerReset += 1 }
        }
        .onChange(of: documentFocused) { _, _ in readerReset += 1 }
        .onChange(of: workspace.tutorFocusRequest) { _, _ in
            if courseWorkspaceVisible {
                courseChatExpanded = true
            } else {
                tutorVisible = true
                readerReset += 1
            }
        }
        .alert(
            "Delete this conversation?",
            isPresented: Binding(get: { removeThreadID != nil }, set: { if !$0 { removeThreadID = nil } })
        ) {
            Button("Cancel", role: .cancel) { removeThreadID = nil }
            Button("Delete", role: .destructive) {
                if let id = removeThreadID { workspace.removeThread(id) }
                removeThreadID = nil
            }
        } message: {
            Text(workspace.course?.threads.first { $0.id == removeThreadID }
                .map { "“\($0.title)” and its messages are removed from this workspace." }
                ?? "The conversation and its messages are removed from this workspace.")
        }
        .sheet(isPresented: $courseSheet) { courseEditor }
        .sheet(isPresented: $searchSheet) { StudySearchView(workspace: workspace, allWorkspaces: searchAllWorkspaces) }
        .sheet(isPresented: $keyboardShortcutsSheet) { StudyKeyboardShortcutsView().environmentObject(app) }
        .sheet(isPresented: $quickSwitcherSheet, onDismiss: runQuickAction) {
            StudyQuickSwitcher(workspace: workspace) { action in
                pendingQuickAction = action
                quickSwitcherSheet = false
            }
        }
        .sheet(isPresented: $workspace.canvasPresented) { StudyCanvasSheet(workspace: workspace) }
        .sheet(isPresented: $workspace.practicePresented) {
            StudyPracticeView(workspace: workspace, learning: workspace.learning).environmentObject(app)
        }
        .alert(
            "Remove this course workspace?",
            isPresented: Binding(get: { removeCourseID != nil }, set: { if !$0 { removeCourseID = nil } })
        ) {
            Button("Cancel", role: .cancel) { removeCourseID = nil }
            Button("Remove workspace", role: .destructive) {
                if let id = removeCourseID { workspace.removeCourse(id) }
                removeCourseID = nil
            }
        } message: {
            Text(
                "This removes the workspace and its chats from your library. Original files and Canvas content are unaffected."
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) {
            notification in
            guard let view = notification.object as? NSTextView, view.identifier?.rawValue == "ScholiaStudyDocument"
            else { return }
            let text = view.string as NSString
            let range = view.selectedRange()
            if NSMaxRange(range) <= text.length {
                workspace.selectedText = String(text.substring(with: range).prefix(16_000))
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ScholiaMark(size: 31)
                Text("scholia").font(.system(size: 26, weight: .semibold, design: .serif))
                Spacer()
            }.padding(.horizontal, 19).padding(.top, 24).padding(.bottom, 18)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(workspace.isShowingLibrary ? "Find a course" : "Find a material", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .accessibilityLabel(workspace.isShowingLibrary ? "Find a course" : "Find a material")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .scholiaButtonStyle(.plain).foregroundStyle(.secondary)
                        .help("Clear sidebar search").accessibilityLabel("Clear sidebar search")
                }
            }.padding(9).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8)).padding(
                .horizontal, 13)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Button(action: workspace.showCourseLibrary) {
                        Label("Dashboard", systemImage: workspace.isShowingLibrary ? "square.grid.2x2" : "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(
                                workspace.isShowingLibrary && !workspace.isShowingAssignments && !workspace.examPlannerPresented ? Color.accentColor.opacity(0.13) : .clear,
                                in: RoundedRectangle(cornerRadius: 9))
                    }.scholiaButtonStyle(.plain).padding(.top, 12)
                    Button(action: workspace.showAssignments) {
                        Label("Assignments", systemImage: "checklist")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(workspace.isShowingAssignments && !workspace.examPlannerPresented ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.scholiaButtonStyle(.plain)
                    Button { workspace.examPlannerPresented = true } label: {
                        Label("Exam dates", systemImage: "calendar.badge.clock")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(workspace.examPlannerPresented ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    }.scholiaButtonStyle(.plain)
                    if workspace.isShowingLibrary {
                        sectionTitle("WORKSPACES", expanded: $workspacesExpanded) { showCreateCourse() }.padding(
                            .top, 23)
                        if workspacesExpanded || !query.isEmpty {
                            if workspace.library.courses.isEmpty {
                                Text("A home for each course.")
                                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 9).padding(
                                        .vertical, 9)
                            }
                            ForEach(workspace.sidebarCourses(matching: query)) { course in
                                Button {
                                    workspace.selectCourse(course.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(
                                            systemName: course.isFavorite
                                                ? "star.fill"
                                                : course.canvasID == nil ? "books.vertical" : "graduationcap"
                                        )
                                        .font(.system(size: 16)).frame(width: 23)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(course.code.isEmpty ? course.name : course.displayCode).font(
                                                .system(size: 12, weight: .semibold)
                                            ).lineLimit(1)
                                            Text(
                                                course.code.isEmpty
                                                    ? "\(course.documents.count) documents" : course.displayName
                                            )
                                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }.padding(10).contentShape(Rectangle())
                                        .background(
                                            !workspace.isShowingLibrary
                                                && workspace.library.selectedCourseID == course.id
                                                ? Color.accentColor.opacity(0.13) : .clear,
                                            in: RoundedRectangle(cornerRadius: 9))
                                }.scholiaButtonStyle(.plain)
                            }
                            if query.isEmpty && workspace.library.courses.count > 7 {
                                Button(
                                    "Browse all \(workspace.library.courses.count) courses",
                                    action: workspace.showCourseLibrary
                                )
                                .scholiaButtonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(10)
                            }
                        }
                    }
                    if !workspace.isShowingLibrary, let course = workspace.course {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(course.code.isEmpty ? "YOUR WORKSPACE" : course.displayCode).font(
                                .system(size: 10, weight: .semibold)
                            ).tracking(1).foregroundStyle(Color.accentColor).lineLimit(1).help(course.code)
                            Text(course.displayName).font(.system(size: 16, weight: .medium, design: .serif))
                                .lineLimit(2).help(course.displayName)
                            if let term = course.term { Text(term).font(.system(size: 10)).foregroundStyle(.secondary) }
                            Button(action: workspace.showCourseMaterials) {
                                Label("Course overview", systemImage: "rectangle.grid.1x2")
                                    .font(.system(size: 11, weight: workspace.document == nil && workspace.assignment == nil ? .semibold : .regular))
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).padding(.horizontal, 9)
                                    .background(workspace.document == nil && workspace.assignment == nil ? Color.accentColor.opacity(0.10) : .clear,
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }.scholiaButtonStyle(.plain).padding(.top, 5)
                        }.padding(.horizontal, 10).padding(.top, 17).padding(.bottom, 5)
                        sectionTitle("MATERIALS", expanded: $materialsExpanded, action: workspace.chooseDocuments)
                            .padding(.top, 17)
                        if materialsExpanded || !query.isEmpty {
                            StudyMaterialsList(workspace: workspace, course: course, query: query, compact: true)
                        }
                        if course.documents.isEmpty && course.materials.isEmpty {
                            Button(action: workspace.chooseDocuments) {
                                Label("Add your first document", systemImage: "plus")
                            }.scholiaButtonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(10)
                        }
                        if !course.threads.isEmpty {
                            sectionTitle("CONVERSATIONS") {
                                workspace.newThread()
                                if courseWorkspaceVisible { courseChatExpanded = true }
                            }.padding(.top, 23)
                            ForEach(course.threads.reversed()) { thread in
                                StudySidebarThreadRow(
                                    thread: thread, selected: workspace.library.selectedThreadID == thread.id,
                                    deletable: workspace.streamingThreadID != thread.id,
                                    open: {
                                        workspace.selectThread(thread.id)
                                        if courseWorkspaceVisible { courseChatExpanded = true }
                                    },
                                    delete: { removeThreadID = thread.id })
                            }
                        }
                    }
                }.padding(.horizontal, 11).padding(.bottom, 20)
            }
            Divider().padding(.horizontal, 15)
            Button {
                workspace.canvasPresented = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "link.circle.fill").font(.system(size: 21)).foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workspace.library.canvasUserID == nil ? "Connect Canvas" : "Canvas connected").font(
                            .system(size: 11, weight: .semibold))
                        Text(workspace.library.canvasUserName ?? "Bring your courses along").font(.system(size: 10))
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                }.padding(15)
            }.scholiaButtonStyle(.plain)
            HStack {
                SettingsLink { Label("Settings", systemImage: "gearshape") }.scholiaButtonStyle(.plain)
                Spacer()
                Button { keyboardShortcutsSheet = true } label: { Image(systemName: "keyboard") }
                    .scholiaButtonStyle(.plain).help("Keyboard shortcuts").accessibilityLabel("Keyboard shortcuts")
                    .accessibilityIdentifier("workspace-keyboard-shortcuts")
                Button(action: app.openStudyWebsite) { Image(systemName: "globe") }.scholiaButtonStyle(.plain).help(
                    "Open this workspace in your browser")
                Button(action: app.showQuickAsk) { Image(systemName: "sparkles") }.scholiaButtonStyle(.plain).help(
                    "Open Quick Chat")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 19).padding(.bottom, 18)
        }.background(StudyPalette.rail(dark))
    }
    private var topbar: some View {
        HStack(spacing: 10) {
            Button {
                if assignmentPDFFocused {
                    workspace.assignmentPDFFocused = false
                    sidebarVisible = true
                } else {
                    sidebarVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
            }.buttonStyle(ScholiaIconButtonStyle()).help("Toggle course library")
                .accessibilityLabel(sidebarVisible && !assignmentPDFFocused ? "Hide course library" : "Show course library")
            HStack(spacing: 2) {
                Button(action: workspace.goBack) { Image(systemName: "chevron.left") }
                    .disabled(!workspace.canGoBack).help("Back (⌘[)").accessibilityLabel("Back").keyboardShortcut(
                        "[", modifiers: .command)
                Button(action: workspace.goForward) { Image(systemName: "chevron.right") }
                    .disabled(!workspace.canGoForward).help("Forward (⌘])").accessibilityLabel("Forward")
                    .keyboardShortcut("]", modifiers: .command)
            }.buttonStyle(ScholiaIconButtonStyle())
            Button(
                workspace.examPlannerPresented ? "Exam dates" : workspace.isShowingAssignments ? "Assignments" : workspace.isShowingLibrary
                    ? "Dashboard"
                    : (workspace.course?.code.isEmpty == false
                        ? workspace.course!.displayCode : workspace.course?.name ?? "Your study space")
            ) {
                if !workspace.isShowingLibrary { workspace.showCourseMaterials() }
            }.scholiaButtonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(
                1)
            if !workspace.examPlannerPresented, !workspace.isShowingLibrary, let title = workspace.assignment?.title ?? workspace.document?.title {
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                Text(title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(title)
            }
            Spacer(minLength: 12)
            Button { PaperStudyWindowController.shared.show(app: app) } label: {
                Label("Paper", systemImage: "camera.viewfinder")
            }.controlSize(.small).help("Study handwritten work with your iPhone camera (⌘3)")
                .accessibilityIdentifier("paper-study-open")
            StudySyncStatusButton(workspace: workspace)
            if workspace.assignment != nil, workspace.document?.kind == .pdf, !workspace.isShowingLibrary,
               !workspace.examPlannerPresented {
                Button(assignmentPDFFocused ? "Assignment overview" : "Focus PDF + chat") {
                    workspace.assignmentPDFFocused.toggle()
                }.controlSize(.small).fixedSize()
                    .help(assignmentPDFFocused
                        ? "Show assignment instructions, included files, and the course library."
                        : "Give the assignment PDF more room beside its chat. Your draft and conversation stay open.")
                    .accessibilityIdentifier("assignment-pdf-focus")
            }
            Button { quickSwitcherSheet = true } label: {
                Label("Switch", systemImage: "arrow.left.arrow.right")
            }.controlSize(.small).keyboardShortcut("k", modifiers: [.command, .shift]).fixedSize()
                .help("Switch workspace or take an action (⌘⇧K)")
                .accessibilityLabel("Switch workspace or take an action")
                .accessibilityIdentifier("workspace-quick-switcher")
            Button { searchAllWorkspaces = true; searchSheet = true } label: { Label("Search files", systemImage: "magnifyingglass") }
                .controlSize(.small).keyboardShortcut("k", modifiers: .command).fixedSize()
                .help("Search coursework in this workspace or across your library (⌘K)")
            Button { ScholiaRepairCenter.shared.present(workspace: workspace, app: app) } label: { Image(systemName: "ladybug") }
                .controlSize(.small).help("Report a bug and launch a repair agent")
                .accessibilityLabel("Report & fix").accessibilityIdentifier("workspace-report-fix")
            Button {
                workspace.practiceScreen = "review"
                workspace.practicePresented = true
            } label: {
                Label("Review", systemImage: "rectangle.stack")
            }.controlSize(.small).fixedSize().help("Review saved questions that are due")
                .accessibilityIdentifier("workspace-review")
            if workspace.isShowingLibrary {
                Button("New workspace", action: showCreateCourse).controlSize(.small)
                    .scholiaButtonStyle(.borderedProminent).fixedSize()
            } else if workspace.course != nil {
                Button(action: workspace.chooseDocuments) { Label("Add documents", systemImage: "plus") }.controlSize(
                    .small
                ).disabled(workspace.isImporting).fixedSize()
                Button { workspaceOptionsPresented = true } label: {
                    Image(systemName: "ellipsis")
                }.buttonStyle(ScholiaIconButtonStyle())
                    .help("Workspace options").accessibilityLabel("Workspace options")
                    .accessibilityIdentifier("workspace-options")
                    .popover(isPresented: $workspaceOptionsPresented, arrowEdge: .bottom) {
                        StudyWorkspaceOptionsPanel(
                            workspace: workspace, presented: $workspaceOptionsPresented,
                            rename: {
                                courseName = workspace.course?.name ?? ""
                                courseCode = workspace.course?.code ?? ""
                                renaming = true
                                courseSheet = true
                            },
                            remove: { removeCourseID = workspace.course?.id }
                        ).environmentObject(app)
                    }
            }
        }.padding(.horizontal, 16).frame(height: 53).padding(.top, 8)
    }
    private func sectionTitle(_ title: String, expanded: Binding<Bool>? = nil, action: @escaping () -> Void)
        -> some View
    {
        HStack {
            if let expanded {
                Button {
                    expanded.wrappedValue.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right").font(
                            .system(size: 8, weight: .semibold))
                        Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.5)
                    }.foregroundStyle(.secondary).contentShape(Rectangle())
                }.scholiaButtonStyle(.plain).help(
                    expanded.wrappedValue ? "Collapse \(title.lowercased())" : "Expand \(title.lowercased())")
            } else {
                Text(title).font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: action) { Image(systemName: "plus").font(.system(size: 10, weight: .medium)) }
                .scholiaButtonStyle(.plain).help(
                    title == "WORKSPACES" ? "Create a course workspace" : "Add \(title.lowercased())")
        }.padding(.horizontal, 10).padding(.bottom, 5)
    }
    private func showCreateCourse() {
        renaming = false
        courseName = ""
        courseCode = ""
        courseSheet = true
    }
    private func runQuickAction() {
        guard let action = pendingQuickAction else { return }
        pendingQuickAction = nil
        switch action {
        case .course(let id): workspace.selectCourse(id)
        case .search, .searchAll:
            searchAllWorkspaces = action == .searchAll
            searchSheet = true
        case .dashboard: workspace.showCourseLibrary()
        case .assignments: workspace.showAssignments()
        case .exams: workspace.examPlannerPresented = true
        case .review:
            workspace.practiceScreen = "review"
            workspace.practicePresented = true
        case .materials: workspace.showCourseMaterials()
        case .newChat:
            guard !workspace.isStreaming else { return }
            workspace.examPlannerPresented = false
            workspace.newThread()
            workspace.focusTutor()
        case .addDocuments: workspace.chooseDocuments()
        case .create: showCreateCourse()
        }
    }
    private var courseEditor: some View {
        VStack(alignment: .leading, spacing: 20) {
            ScholiaMark(size: 40)
            Text(renaming ? "Your course workspace" : "A new space to learn.").font(.system(size: 27, design: .serif))
            Text("Keep your readings, questions, and explanations together.").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Course name").font(.caption)
                TextField("e.g. Linear algebra", text: $courseName).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Course code · optional").font(.caption)
                TextField("e.g. TMA4115", text: $courseCode).textFieldStyle(.roundedBorder)
            }
            HStack {
                Button("Cancel") { courseSheet = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(renaming ? "Save changes" : "Create workspace") {
                    if renaming {
                        workspace.renameCourse(name: courseName, code: courseCode)
                    } else {
                        workspace.createCourse(name: courseName, code: courseCode)
                    }
                    courseSheet = false
                }.scholiaButtonStyle(.borderedProminent).disabled(
                    courseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ).keyboardShortcut(.defaultAction)
            }.padding(.top, 8)
        }.padding(32).frame(width: 400).background(StudyPalette.paper(dark))
    }
}

private struct StudyReaderPane: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    @ObservedObject var editing: StudyEditingState
    @Binding var tutorVisible: Bool
    @Binding var courseChatExpanded: Bool
    var expandReader: () -> Void
    var createCourse: () -> Void
    var assignmentFocused = false
    var documentFocused = false
    var showAssignmentOverview: () -> Void = {}
    @EnvironmentObject private var app: AppModel
    @StateObject private var pdfControls = StudyPDFControls()
    @State private var semanticSearch = false
    @State private var feedbackPresented = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var zoom: CGFloat = 1
    @State private var search = ""
    @State private var searching = false
    @State private var outline = false
    @State private var dropTarget = false
    @State private var originalLayout = false
    @State private var previewCapture = 0
    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 260
            ZStack(alignment: .topLeading) {
                readingContent.frame(width: max(260, geometry.size.width), height: geometry.size.height)
                    .opacity(compact ? 0 : 1).accessibilityHidden(compact)
                    .allowsHitTesting(!compact)
                if compact {
                    VStack(spacing: 14) {
                        Image(systemName: "doc.richtext").font(.system(size: 22, weight: .light))
                        Text("Reader").font(.system(size: 10, weight: .medium))
                        Button(action: expandReader) { Image(systemName: "arrow.right.to.line") }
                            .help("Expand document reader").accessibilityLabel("Expand document reader")
                    }.foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 24)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
    }
    private var readingContent: some View {
        VStack(spacing: 0) {
            if let assignment = workspace.assignment {
                if assignmentFocused {
                    HStack(spacing: 10) {
                        Label(assignment.title, systemImage: "doc.text")
                            .font(.system(size: 12, weight: .medium)).lineLimit(1).help(assignment.title)
                        Spacer(minLength: 8)
                        if !workspace.assignmentFiles.isEmpty {
                            Menu("Included files") {
                                ForEach(workspace.assignmentFiles) { file in
                                    Button {
                                        workspace.openAssignmentFile(file.id)
                                    } label: {
                                        if workspace.document?.sourceKey == file.id {
                                            Label(file.fileName ?? file.title, systemImage: "checkmark")
                                        } else {
                                            Text(file.fileName ?? file.title)
                                        }
                                    }.disabled(workspace.document?.sourceKey == file.id || file.unavailableReason != nil)
                                }
                            }.controlSize(.small).fixedSize()
                        }
                        if let courseID = workspace.course?.id {
                            Button("Feedback") { feedbackPresented.toggle() }.controlSize(.small)
                                .popover(isPresented: $feedbackPresented) {
                                    StudyAssignmentFeedbackView(workspace: workspace, courseID: courseID,
                                        assignmentID: assignment.id, onOpenAttachment: { feedbackPresented = false })
                                        .padding(18).frame(width: 540, height: 480)
                                }
                        }
                        Button("Instructions", action: showAssignmentOverview).controlSize(.small).fixedSize()
                    }.padding(.horizontal, 15).frame(height: 40)
                        .accessibilityIdentifier("assignment-pdf-heading")
                } else {
                    StudyAssignmentPageView(workspace: workspace, assignment: assignment)
                        .id("\(workspace.course!.id):\(assignment.id)")
                }
                Divider()
            }
            if let document = workspace.document {
                readerToolbar(document)
                Divider()
                if let notice = document.contentNotice {
                    Text(notice).font(.system(size: 10)).foregroundStyle(.secondary).frame(
                        maxWidth: .infinity, alignment: .leading
                    ).padding(.horizontal, 17).padding(.vertical, 8)
                }
                ZStack {
                    StudyPalette.canvas(dark)
                    if editing.drafts[document.id] != nil {
                        StudyDocumentEditorView(editing: editing, document: document)
                    } else {
                        switch document.kind {
                        case .pdf:
                            StudyPDFReader(
                                url: workspace.store.file(for: document),
                                page: Binding(get: { workspace.currentPage }, set: { workspace.setPage($0) }),
                                selection: $workspace.selectedText, selectingFigure: $workspace.selectingFigure,
                                zoom: zoom,
                                onFigure: {
                                    workspace.useOpenDocumentConversation()
                                    workspace.draftImage = $0
                                    tutorVisible = true
                                }, controls: pdfControls,
                                onSelectionAction: { text, explain, question in
                                    workspace.selectedText = text
                                    if explain && !workspace.isStreaming {
                                        return workspace.sendReaderSelection(text, question: question) {
                                            workspace.send(using: app)
                                        }
                                    }
                                    if !explain {
                                        tutorVisible = true
                                        workspace.openSelectionInChat(text, question: question)
                                        return true
                                    }
                                    return false
                                },
                                selectionResponse: { close in
                                    AnyView(StudySelectionResponseView(workspace: workspace, onClose: close) {
                                        close()
                                        tutorVisible = true
                                        workspace.openSelectionInChat(workspace.selectedText)
                                    })
                                },
                                selectionBusy: workspace.isStreaming
                                    || workspace.assignmentPreparing,
                                revision:
                                    "\(document.addedAt.timeIntervalSinceReferenceDate)-\(document.sourceVersion ?? "")-\(document.contentHash ?? "")",
                                onOpenLink: workspace.openCourseLink
                            )
                        case .image:
                            if let image = NSImage(contentsOf: workspace.store.file(for: document)) {
                                Image(nsImage: image).resizable().scaledToFit().padding(30).accessibilityLabel(
                                    document.title)
                            }
                        case .preview:
                            StudyOriginalPreview(
                                url: workspace.store.file(for: document), captureRequest: previewCapture,
                                onCapture: {
                                    workspace.attachImage($0)
                                    tutorVisible = true
                                }
                            ).id(document.addedAt)
                        case .notebook:
                            if let cells = workspace.documentIndex?.pages {
                                StudyNotebookReader(workspace: workspace, document: document, cells: cells).id(
                                    document.id)
                            } else {
                                ProgressView("Opening notebook…")
                            }
                        case .text, .code, .office:
                            if document.isHTML && !originalLayout {
                                StudyOriginalHTML(url: workspace.store.file(for: document), sourceURL: document.sourceURL,
                                    onLink: workspace.openCourseLink).id(document.addedAt)
                            } else if originalLayout && document.kind == .office {
                                StudyOriginalPreview(
                                    url: workspace.store.file(for: document), captureRequest: previewCapture,
                                    onCapture: {
                                        workspace.attachImage($0)
                                        tutorVisible = true
                                    }
                                ).id(document.addedAt)
                            } else {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 20) {
                                        RichMarkdownView(
                                            source: workspace.linkedReadingText,
                                            registerSelectionView: {
                                                $0.identifier = NSUserInterfaceItemIdentifier("ScholiaStudyDocument")
                                            }, onOpenLink: workspace.openCourseLink)
                                        ForEach(
                                            workspace.documentIndex?.pages.first(where: {
                                                $0.number == workspace.currentPage
                                            })?.images ?? [], id: \.self
                                        ) { name in
                                            if let image = NSImage(
                                                contentsOf: workspace.store.directory(for: document.id)
                                                    .appendingPathComponent(name))
                                            {
                                                Image(nsImage: image).resizable().scaledToFit().accessibilityLabel(
                                                    "Embedded image")
                                                Button("Ask about this image") { workspace.attachImage(image) }
                                                    .controlSize(.small)
                                            }
                                        }
                                    }.padding(38).frame(maxWidth: 860, alignment: .leading)
                                        .background(StudyPalette.paper(dark), in: RoundedRectangle(cornerRadius: 3))
                                        .shadow(color: .black.opacity(0.05), radius: 8, y: 3).padding(28)
                                }.id("\(document.id)-\(workspace.currentPage)")
                            }
                        }
                    }
                    if workspace.selectingFigure {
                        VStack {
                            Text("Drag around a figure to ask about it · Esc to cancel").font(.caption.weight(.medium))
                                .padding(10)
                                .background(.regularMaterial, in: Capsule()).padding(14)
                            Spacer()
                        }.allowsHitTesting(false)
                    }
                }
                readerFooter(document)
            } else if workspace.assignment != nil {
                EmptyView()
            } else if let course = workspace.course {
                StudyCourseMaterialsView(workspace: workspace, course: course, courseChatExpanded: $courseChatExpanded) {
                    workspace.askAboutCourse()
                }.id(course.id)
            } else {
                welcome
            }
        }
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 12).stroke(
                    Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8])
                ).padding(8).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
            guard workspace.course != nil, !workspace.isImporting else { return false }
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    let value: Data? = await withCheckedContinuation { continuation in
                        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                            continuation.resume(returning: data)
                        }
                    }
                    if let value, let url = URL(dataRepresentation: value, relativeTo: nil), url.isFileURL {
                        urls.append(url)
                    }
                }
                workspace.importDocuments(urls)
            }
            return true
        }
        .onChange(of: workspace.document?.id) { _, _ in
            zoom = 1
            search = ""
            searching = false
            originalLayout = false
            pdfControls.matches = []
            pdfControls.outline = []
        }
        .onChange(of: pdfControls.layout) { _, _ in pdfControls.apply() }
        .onChange(of: pdfControls.zoomMode) { _, _ in pdfControls.apply() }
        .onChange(of: pdfControls.dark) { _, _ in pdfControls.apply() }
        .onChange(of: workspace.documentIndex?.extractionVersion) { _, _ in
            if !search.isEmpty { pdfControls.search(search, pages: workspace.documentIndex?.pages ?? [], semantic: semanticSearch) }
        }
        .task(id: "\(workspace.document?.id.uuidString ?? "")-\(search)-\(semanticSearch)") {
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            pdfControls.search(search, pages: workspace.documentIndex?.pages ?? [], semantic: semanticSearch)
        }
    }

    private func readerToolbar(_ document: StudyDocument) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if editing.drafts[document.id] != nil {
                    Text(document.kind == .notebook ? "EDIT NOTEBOOK" : "EDIT DOCUMENT").font(
                        .system(size: 9, weight: .semibold)
                    ).tracking(1).foregroundStyle(.secondary)
                    Text("Saved locally").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { editing.cancel(document.id) }.disabled(editing.busy)
                    Button(editing.busy ? "Saving…" : "Save changes") {
                        editing.save(document.id, workspace: workspace)
                    }
                    .scholiaButtonStyle(.borderedProminent).disabled(editing.busy).keyboardShortcut(
                        "s", modifiers: .command)
                } else {
                    Button {
                        outline.toggle()
                    } label: {
                        Image(systemName: "list.bullet")
                    }.buttonStyle(ScholiaIconButtonStyle()).help("Table of contents")
                        .popover(isPresented: $outline) {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(pdfControls.outline.isEmpty ? "Document sections" : "Table of contents").font(
                                    .headline)
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 3) {
                                        if !pdfControls.outline.isEmpty && document.kind == .pdf {
                                            ForEach(pdfControls.outline) { entry in
                                                Button {
                                                    workspace.setPage(entry.page)
                                                    outline = false
                                                } label: {
                                                    HStack {
                                                        Text(entry.title).lineLimit(2)
                                                        Spacer()
                                                        Text("\(entry.page)").foregroundStyle(.secondary)
                                                    }
                                                    .padding(.leading, CGFloat(entry.depth * 12)).padding(7)
                                                    .contentShape(Rectangle())
                                                }.scholiaButtonStyle(.plain).font(.caption)
                                            }
                                        } else {
                                            ForEach(workspace.documentIndex?.pages ?? [], id: \.number) { page in
                                                Button {
                                                    workspace.setPage(page.number)
                                                    outline = false
                                                } label: {
                                                    HStack(alignment: .top) {
                                                        Text("\(page.number)").monospacedDigit().frame(
                                                            width: 26, alignment: .trailing
                                                        ).foregroundStyle(.secondary)
                                                        Text(
                                                            page.text.isEmpty
                                                                ? "Image page"
                                                                : String(page.text.prefix(100)).replacingOccurrences(
                                                                    of: "\n", with: " ")
                                                        ).lineLimit(2)
                                                    }
                                                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                                                    .padding(7).contentShape(Rectangle())
                                                }.scholiaButtonStyle(.plain)
                                            }
                                        }
                                    }
                                }
                            }.padding(16).frame(width: 320, height: 420)
                        }
                    Button {
                        searching.toggle()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }.buttonStyle(ScholiaIconButtonStyle()).help("Find in document (⌘F)").keyboardShortcut(
                        "f", modifiers: .command)
                    if document.kind == .pdf {
                        Menu {
                            Picker("Page layout", selection: $pdfControls.layout) {
                                Text("Continuous").tag("continuous")
                                Text("Single page").tag("page")
                                Text("Two-page spread").tag("spread")
                            }
                        } label: {
                            Image(systemName: pdfControls.layout == "spread" ? "book" : "rectangle.portrait")
                        }.menuStyle(.borderlessButton).scholiaPointingCursor().fixedSize().help("Page layout")
                        Spacer(minLength: 0)
                        Button {
                            pdfControls.zoom(-1)
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }.scholiaButtonStyle(.plain).help("Zoom out")
                        Menu {
                            Button("Automatic") { pdfControls.zoomMode = "auto" }
                            Button("Fit page") { pdfControls.zoomMode = "page" }
                            Button("Fit width") { pdfControls.zoomMode = "width" }
                            Divider()
                            ForEach([50, 75, 100, 125, 150, 200], id: \.self) { value in
                                Button("\(value)%") {
                                    pdfControls.scale = CGFloat(value) / 100
                                    pdfControls.zoomMode = "custom"
                                    pdfControls.apply()
                                }
                            }
                        } label: {
                            Text(
                                pdfControls.zoomMode == "custom"
                                    ? "\(Int(pdfControls.scale * 100))%"
                                    : pdfControls.zoomMode == "width"
                                        ? "Fit width" : pdfControls.zoomMode == "page" ? "Fit page" : "Auto"
                            ).font(.system(size: 10)).frame(minWidth: 39)
                        }.menuStyle(.borderlessButton).scholiaPointingCursor().fixedSize()
                        Button {
                            pdfControls.zoom(1)
                        } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }.scholiaButtonStyle(.plain).help("Zoom in")
                        Button {
                            workspace.selectingFigure.toggle()
                        } label: {
                            Image(systemName: "viewfinder")
                        }.buttonStyle(ScholiaIconButtonStyle()).help("Select a figure for the tutor")
                    } else {
                        Text(
                            document.kind == .notebook ? "NOTEBOOK" : document.kind == .code ? "SOURCE CODE" : "READING"
                        ).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if document.kind == .preview || (originalLayout && document.kind == .office) {
                            Button("Ask about view") { previewCapture += 1 }.controlSize(.small)
                        }
                        if document.kind == .office {
                            Button(originalLayout ? "Reading view" : "Original layout") { originalLayout.toggle() }
                                .controlSize(.small)
                        }
                        if document.isHTML {
                            Button(originalLayout ? "Original page" : "Reading view") { originalLayout.toggle() }
                                .controlSize(.small)
                        }
                    }
                    if let source = document.sourceURL.flatMap({ StudyHTML.safeURL($0) }) {
                        Link(destination: source) { Image(systemName: "arrow.up.right.square") }
                            .help("Open original source").accessibilityLabel("Open original source")
                    }
                    if document.kind == .pdf {
                        Button("Send entire PDF", systemImage: "doc.text") {
                            tutorVisible = true
                            workspace.sendEntirePDF(using: app)
                        }.controlSize(.small).disabled(workspace.isStreaming || workspace.documentIndex == nil)
                            .help("Send every page’s extracted text to the tutor and ask for an explanation")
                        Button("Download", systemImage: "arrow.down.to.line") { saveCopy(document) }
                            .controlSize(.small).help("Download PDF").accessibilityLabel("Download PDF")
                    }
                    if StudyDocumentEditing.supports(document) {
                        Button("Edit", systemImage: "pencil") { editing.begin(document) }.controlSize(.small).disabled(
                            editing.busy
                        ).help("Edit this local document")
                    }
                    if !assignmentFocused && !documentFocused {
                        Button { tutorVisible.toggle() } label: {
                            Image(systemName: "bubble.left.and.bubble.right")
                        }.buttonStyle(ScholiaIconButtonStyle()).help(tutorVisible ? "Hide chat" : "Show chat")
                    }
                    Button { workspace.toggleDocumentFocus() } label: {
                        Image(systemName: documentFocused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }.buttonStyle(ScholiaIconButtonStyle())
                        .help(documentFocused ? "Leave document focus (⌘⇧F)" : "Focus on this document with the chat beside it (⌘⇧F)")
                        .accessibilityLabel(documentFocused ? "Leave document focus" : "Focus on document")
                        .accessibilityIdentifier("document-focus-toggle")
                    Button { pdfControls.dark.toggle() } label: {
                        Image(systemName: pdfControls.dark ? "sun.max" : "moon")
                    }.buttonStyle(ScholiaIconButtonStyle())
                        .help(pdfControls.dark ? "Light reader" : "Dark reader")
                        .accessibilityLabel(pdfControls.dark ? "Light reader" : "Dark reader")
                    if document.kind == .pdf {
                        Button(action: pdfControls.printDocument) { Image(systemName: "printer") }
                            .buttonStyle(ScholiaIconButtonStyle()).help("Print (⌘P)").accessibilityLabel("Print")
                            .keyboardShortcut("p", modifiers: .command)
                    } else {
                        Button { saveCopy(document) } label: { Image(systemName: "arrow.down.to.line") }
                            .buttonStyle(ScholiaIconButtonStyle()).help("Save a copy").accessibilityLabel("Save a copy")
                    }
                    Button { NSWorkspace.shared.open(workspace.store.file(for: document)) } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }.buttonStyle(ScholiaIconButtonStyle()).help("Open original in default app")
                        .accessibilityLabel("Open original in default app")
                }
            }.padding(.horizontal, 13).frame(height: 46)
            if let error = editing.error {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(12)
            }
            if searching && editing.drafts[document.id] == nil {
                HStack(spacing: 8) {
                    Picker("Search", selection: $semanticSearch) {
                        Text("Exact").tag(false)
                        Text("Semantic").tag(true)
                    }.labelsHidden().frame(width: 93)
                    TextField(semanticSearch ? "Find related concepts" : "Find words or phrases", text: $search)
                        .textFieldStyle(.roundedBorder).onSubmit { findNext(1) }
                    Text(
                        pdfControls.matches.isEmpty
                            ? "0" : "\(max(0, pdfControls.matchIndex + 1)) / \(pdfControls.matches.count)"
                    ).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button {
                        findNext(-1)
                    } label: {
                        Image(systemName: "arrow.up")
                    }.scholiaButtonStyle(.plain).help("Previous result")
                    Button {
                        findNext(1)
                    } label: {
                        Image(systemName: "arrow.down")
                    }.scholiaButtonStyle(.plain).help("Next result")
                    Button {
                        searching = false
                        search = ""
                    } label: {
                        Image(systemName: "xmark")
                    }.scholiaButtonStyle(.plain).help("Close search")
                }.padding(.horizontal, 13).padding(.bottom, 10)
            }
        }
    }
    private func saveCopy(_ document: StudyDocument) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = document.downloadFileName(in: workspace.course)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(contentsOf: workspace.store.file(for: document)).write(to: url, options: .atomic) } catch {
            workspace.error = error.localizedDescription
        }
    }
    private func readerFooter(_ document: StudyDocument) -> some View {
        HStack(spacing: 9) {
            if let progress = workspace.documentOCRProgress {
                ProgressView().controlSize(.mini)
                Text(progress).font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
            Image(systemName: document.unreadablePages == 0 ? "checkmark.circle" : "doc.viewfinder").foregroundStyle(
                .secondary)
            Text(
                document.kind == .notebook
                    ? "\(document.pageCount) cells · Saved offline"
                    : document.kind == .preview
                        ? "Original file saved offline"
                        : document.unreadablePages == 0
                            ? "\(document.pageCount) \([StudyDocumentKind.office, .code].contains(document.kind) ? "sections" : "pages") indexed"
                            : "\(document.unreadablePages) image-only pages"
            )
            .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if editing.drafts[document.id] != nil {
                Text(
                    document.kind == .notebook
                        ? "Save to update tutor context · Saved outputs are not rerun" : "Save to update tutor context"
                )
                .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if document.kind == .notebook {
                Text("Scroll to read").font(.system(size: 10)).foregroundStyle(.tertiary)
            } else {
                Button {
                    workspace.setPage(
                        pdfControls.pageTarget(workspace.currentPage, count: document.pageCount, direction: -1))
                } label: {
                    Image(systemName: "chevron.left")
                }.disabled(workspace.currentPage <= 1)
                TextField(
                    "Page", value: Binding(get: { workspace.currentPage }, set: { workspace.setPage($0) }),
                    format: .number
                )
                .textFieldStyle(.plain).multilineTextAlignment(.center).frame(width: 30).font(
                    .system(size: 11).monospacedDigit()
                ).accessibilityLabel("Current page")
                Text("/ \(document.pageCount)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                Button {
                    workspace.setPage(
                        pdfControls.pageTarget(workspace.currentPage, count: document.pageCount, direction: 1))
                } label: {
                    Image(systemName: "chevron.right")
                }.disabled(workspace.currentPage >= document.pageCount)
            }
        }.scholiaButtonStyle(.plain).padding(.horizontal, 20).frame(height: 42).background(StudyPalette.paper(dark))
    }
    private func findNext(_ direction: Int) {
        if let page = pdfControls.nextMatch(direction) { workspace.setPage(page) }
    }
    private var welcome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 22, height: 3)
                    Text(workspace.course == nil ? "A LITTLE SPACE TO THINK" : "YOUR COURSE WORKSPACE").font(
                        .system(size: 10, weight: .medium)
                    ).tracking(2).foregroundStyle(.secondary)
                }.padding(.top, 44)
                Text(workspace.course?.name ?? "Make room for\nunderstanding.")
                    .font(.system(size: workspace.course == nil ? 43 : 35, weight: .regular, design: .serif))
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                Text(
                    workspace.course == nil
                        ? "Your readings on one side. A thoughtful tutor on the other. Bring your course materials, and work through them at your own pace."
                        : "A place for your readings, questions, and the moments when things click. Open a document to start exploring, or ask a question across your course."
                )
                .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(6).fixedSize(
                    horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(action: workspace.course == nil ? createCourse : workspace.chooseDocuments) {
                        Label(workspace.course == nil ? "Create a workspace" : "Add documents", systemImage: "plus")
                            .padding(.horizontal, 8).padding(.vertical, 5)
                    }.scholiaButtonStyle(.borderedProminent)
                    if workspace.course == nil {
                        Button("Connect Canvas") { workspace.canvasPresented = true }.scholiaButtonStyle(.bordered)
                            .padding(.vertical, 5)
                    }
                }
                Divider().padding(.vertical, 12)
                if let course = workspace.course, !course.documents.isEmpty {
                    Text("ON YOUR READING LIST").font(.system(size: 9, weight: .semibold)).tracking(1.5)
                        .foregroundStyle(.secondary)
                    ForEach(course.documents) { document in
                        Button {
                            workspace.selectDocument(document.id)
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: document.kind.symbol).font(.title2).foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(document.title).font(.system(size: 13, weight: .medium))
                                    Text("\(document.pageCount) pages · Continue on page \(document.lastPage)").font(
                                        .caption
                                    ).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").foregroundStyle(.tertiary)
                            }.padding(16).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                        }.scholiaButtonStyle(.plain)
                    }
                } else {
                    welcomeStep(
                        "01", title: "Bring your materials",
                        detail: "Add PDFs, lecture slides, notes, and images—or connect your Canvas courses.")
                    welcomeStep(
                        "02", title: "Read, select, ask",
                        detail:
                            "Highlight a passage or frame a figure. The tutor follows your page and uses the wider document."
                    )
                    welcomeStep(
                        "03", title: "Make it your own",
                        detail: "Ask for an explanation, work through a hint, or test your understanding with practice."
                    )
                }
                Label("Your workspace is saved on this Mac", systemImage: "internaldrive").font(.system(size: 10))
                    .foregroundStyle(.tertiary).padding(.top, 18)
            }.padding(.horizontal, 42).padding(.bottom, 40).frame(maxWidth: 760, alignment: .leading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(StudyPalette.paper(dark))
    }
    private func welcomeStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 17) {
            Text(number).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.accentColor).padding(
                .top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).fixedSize(
                    horizontal: false, vertical: true)
            }
        }
    }
}

private struct StudyChatMessageLayout: Equatable {
    var id: UUID
    var height: CGFloat
}

private struct StudyChatMessageLayoutKey: PreferenceKey {
    static let defaultValue: StudyChatMessageLayout? = nil
    static func reduce(value: inout StudyChatMessageLayout?, nextValue: () -> StudyChatMessageLayout?) {
        if let next = nextValue() { value = next }
    }
}

struct StudyTutorPane: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    var assignmentFocused = false
    var inlineCourse = false
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var composerFocused = false
    @State private var contextPresented = false
    @State private var memoryPresented = false
    @State private var deletingThread = false
    @State private var followOutput = true
    @State private var lastMessageLayout: StudyChatMessageLayout?
    @State private var inspectedChatAttachment: ChatAttachmentInspection?
    private var dark: Bool { colorScheme == .dark }
    private var modelDefinition: ModelDefinition? { app.modelDefinition(for: app.activeProvider, id: app.activeModel) }
    private var visionAvailable: Bool {
        (modelDefinition?.supportsImages ?? (app.activeProvider.id != "opencode"))
            && (app.activeProvider.supportsImages || app.activeProvider.bridge?.imageSupportComesFromHealth == true)
    }

    var body: some View {
        AttachmentDropContainer(onDrop: { workspace.attachFromPasteboard($0, acceptingDrop: true) }, fillsProposedSize: true) {
            tutorBody.environmentObject(app)
        }
    }
    private var tutorBody: some View {
        VStack(spacing: 0) {
            if inlineCourse {
                inlineHeader
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "sparkle").font(.system(size: 16)).foregroundStyle(Color.accentColor)
                    Text(workspace.mode == .chat ? "General" : workspace.assignment != nil ? "Assignment chat" : "Study companion")
                        .font(.system(size: 14, weight: .semibold, design: .serif)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    memoryButton
                    if workspace.thread != nil {
                        Button { deletingThread = true } label: { Image(systemName: "trash") }
                            .buttonStyle(ScholiaIconButtonStyle()).help("Delete this conversation")
                            .accessibilityLabel("Delete this conversation").accessibilityIdentifier("delete-conversation")
                            .disabled(workspace.isCurrentThreadStreaming)
                            .alert("Delete this conversation?", isPresented: $deletingThread) {
                                Button("Cancel", role: .cancel) {}
                                Button("Delete", role: .destructive) {
                                    if let id = workspace.thread?.id { workspace.removeThread(id) }
                                }
                            } message: {
                                Text("The conversation and its messages are removed from this workspace.")
                            }
                    }
                    Button {
                        workspace.newThread()
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }.buttonStyle(ScholiaIconButtonStyle()).help("New conversation").disabled(workspace.course == nil)
                }.padding(.horizontal, 19).frame(height: 46)
                Divider()
                HStack(spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        Picker("Conversation mode", selection: $workspace.mode) {
                            ForEach(StudyTeachingMode.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().fixedSize(horizontal: true, vertical: false)
                        Picker("Conversation mode", selection: $workspace.mode) {
                            ForEach(StudyTeachingMode.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.menu).labelsHidden()
                    }.controlSize(.small).scholiaPointingCursor().disabled(workspace.isCurrentThreadStreaming)
                        .help(workspace.mode.summary)
                    Spacer(minLength: 4)
                    contextChip
                }.padding(.horizontal, 14).padding(.vertical, 8)
                if workspace.mode == .practice {
                    Button("Start a saved practice session") { workspace.prepareStudyPrompt(.practice) }
                        .controlSize(.small).padding(.horizontal, 14).padding(.bottom, 8)
                }
                Divider()
            }
            conversation.frame(minHeight: 0, maxHeight: .infinity).clipped()
            if let error = workspace.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(error).font(.caption).textSelection(.enabled).lineLimit(inlineCourse ? 2 : nil).help(error)
                        if !workspace.messages.isEmpty && !workspace.isStreaming {
                            Button("Retry last question") { workspace.retry(using: app) }.font(.caption)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        workspace.error = nil
                    } label: {
                        Image(systemName: "xmark")
                    }.scholiaButtonStyle(.plain)
                        .accessibilityLabel("Dismiss chat error")
                }.padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9)).padding(
                    .horizontal, 16
                ).padding(.bottom, 8)
            }
            StudyTutorComposer(workspace: workspace, draftState: workspace.composerDraft,
                               composerFocused: $composerFocused, compact: inlineCourse)
        }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(StudyPalette.paper(dark))
            .sheet(isPresented: $memoryPresented) { StudyWorkspaceMemoryView(workspace: workspace) }
            .sheet(item: $inspectedChatAttachment) { ChatAttachmentInspector(inspection: $0) }
            .onChange(of: workspace.tutorFocusRequest) { _, _ in composerFocused = true }
            .onAppear { if workspace.tutorFocusRequest > 0 { composerFocused = true } }
    }
    private var memoryButton: some View {
        Button { memoryPresented = true } label: { Image(systemName: "brain") }
            .buttonStyle(ScholiaIconButtonStyle()).help("Workspace memory and reference files")
            .accessibilityLabel("Workspace memory").accessibilityIdentifier("workspace-memory")
            .disabled(workspace.course == nil)
    }
    /// One small chip summarises what the next question will see; the popover
    /// behind it holds the switches, so the column stays free for answers.
    private var contextChip: some View {
        Button { contextPresented.toggle() } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(workspace.automaticContextEnabled && (workspace.isCourseConversation || workspace.documentIndex != nil || workspace.assignment != nil)
                        ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 5, height: 5)
                Text(contextChipTitle).font(.system(size: 10, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
            }
            .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.05), in: Capsule()).contentShape(Capsule())
        }.scholiaButtonStyle(.plain).help(nextContextDescription)
            .popover(isPresented: $contextPresented) { contextDetails }
            .accessibilityLabel("Chat context: \(nextContextDescription)")
            .accessibilityIdentifier("study-context-chip")
    }
    private var contextChipTitle: String {
        guard workspace.automaticContextEnabled else { return "Context off" }
        if workspace.isCourseConversation { return "Course context" }
        if workspace.assignment != nil { return "Assignment context" }
        if let document = workspace.document {
            return workspace.includeEntirePDF ? "Whole document"
                : document.kind == .notebook ? "Cell \(workspace.currentPage)" : "Document · p. \(workspace.currentPage)"
        }
        return workspace.course == nil ? "No course" : "Course materials"
    }
    private var contextTitle: String {
        workspace.isCourseConversation ? "Course context" : workspace.document == nil ? "Project context" : "Document context"
    }
    private var nextContextDescription: String {
        guard workspace.automaticContextEnabled else { return "Only this conversation, selected text, and your attachments" }
        if let document = workspace.document, !workspace.isCourseConversation {
            let indexedPages = workspace.documentIndex?.pages.count ?? 0
            return workspace.includeEntirePDF
                ? "\(document.title) · all \(document.pageCount) pages of text"
                : indexedPages < document.pageCount
                ? "Page \(workspace.currentPage) · \(indexedPages) of \(document.pageCount) pages indexed"
                : "Page \(workspace.currentPage) · searches all \(document.pageCount) pages when needed"
        }
        if workspace.isCourseConversation, let document = workspace.document {
            return "Course conversation · \(document.title) is open in the reader"
        }
        return workspace.assignment.map { "\($0.title) · instructions and relevant project files" }
            ?? "Searches relevant saved readings in \(workspace.course?.displayName ?? "this course")"
    }
    private var inlineHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(workspace.mode == .chat ? "General" : "Course chat", systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Picker("Conversation mode", selection: $workspace.mode) {
                    ForEach(StudyTeachingMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
                    .disabled(workspace.isCurrentThreadStreaming).help(workspace.mode.summary)
                    .accessibilityIdentifier("course-chat-mode")
                memoryButton
                Button { contextPresented.toggle() } label: { Image(systemName: "info.circle") }
                    .buttonStyle(ScholiaIconButtonStyle()).help("Course context")
                    .accessibilityLabel("Course context")
                    .popover(isPresented: $contextPresented) { contextDetails }

                Button { workspace.newThread() } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(ScholiaIconButtonStyle()).help("New course conversation")
                    .accessibilityLabel("New course conversation")
            }.padding(.horizontal, 13).frame(height: 42)
            Divider()
        }
    }
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if workspace.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            if workspace.assignment != nil, !workspace.isCourseConversation {
                                ConversationActivityView(events: workspace.assignmentActivity)
                            }
                            if !workspace.automaticContextEnabled {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Choose your context.").font(.system(size: 22, design: .serif))
                                    Text("Ask a question or add project files. Each attachment shows what could be read. Turn on reading or course context to include saved materials.")
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                            } else if inlineCourse { inlineEmptyConversation } else { emptyConversation }
                        }.id("study-chat-top")
                    }
                    ForEach(workspace.messages) { message in
                        messageView(message).id(message.id)
                            .background {
                                if message.id == workspace.messages.last?.id {
                                    GeometryReader { geometry in
                                        Color.clear.preference(key: StudyChatMessageLayoutKey.self,
                                            value: StudyChatMessageLayout(id: message.id, height: geometry.size.height))
                                    }
                                }
                            }
                    }
                    Color.clear.frame(height: 1).id("study-chat-bottom")
                }.padding(.horizontal, inlineCourse ? 14 : 21).padding(.top, inlineCourse ? 12 : 20).padding(.bottom, 10)
            }
            .defaultScrollAnchor(workspace.messages.isEmpty ? .top : followOutput ? .bottom : nil)
            .onPreferenceChange(StudyChatMessageLayoutKey.self) { layout in
                guard let layout, layout.height > 0, layout != lastMessageLayout else { return }
                lastMessageLayout = layout
                // Native Markdown reports its final height after a lazy row is
                // mounted. Follow that layout, not its initial height estimate.
                if followOutput { proxy.scrollTo("study-chat-bottom", anchor: .bottom) }
            }
            .onChange(of: workspace.messages.count) { previous, count in
                followOutput = true
                let animate = count > previous && workspace.isCurrentThreadStreaming && !reduceMotion
                withAnimation(animate ? ScholiaVisualStyle.fastAnimation : nil) {
                    proxy.scrollTo("study-chat-bottom", anchor: .bottom)
                }
            }
            .onChange(of: workspace.messages.last?.content) { _, _ in
                if followOutput { proxy.scrollTo("study-chat-bottom", anchor: .bottom) }
            }
            .onChange(of: workspace.library.selectedThreadID) { _, _ in
                followOutput = true
                lastMessageLayout = nil
                proxy.scrollTo(workspace.messages.isEmpty ? "study-chat-top" : "study-chat-bottom", anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if workspace.isCurrentThreadStreaming {
                    Button {
                        followOutput.toggle()
                        if followOutput {
                            withAnimation(reduceMotion ? nil : ScholiaVisualStyle.fastAnimation) {
                                proxy.scrollTo("study-chat-bottom", anchor: .bottom)
                            }
                        }
                    } label: {
                        Image(systemName: followOutput ? "pause" : "arrow.down")
                    }.scholiaButtonStyle(.bordered).controlSize(.small).help(
                        followOutput ? "Pause following the answer" : "Follow the answer"
                    ).padding(10)
                }
            }
        }
    }
    private var inlineEmptyConversation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(workspace.mode == .chat
                ? "Ask anything, brainstorm, or talk through an idea. Course materials are available when relevant."
                : "Ask about topics, readings, or deadlines. Answers use your course information and relevant saved materials.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { inlineCourseSuggestions }
                VStack(alignment: .leading, spacing: 7) { inlineCourseSuggestions }
            }
            .controlSize(.small)
        }
    }
    @ViewBuilder private var inlineCourseSuggestions: some View {
        if workspace.mode == .chat {
            Button("Talk through an idea") {
                workspace.prepareStudyPrompt(.chat)
                composerFocused = true
            }
        } else {
            Button("Course overview") {
                workspace.askAboutCourse(question: "Give me an overview of this course and how its main topics connect.")
            }
            Button("What's due next?") {
                workspace.askAboutCourse(question: "What's due next in this course? Flag any dates that need a Canvas refresh.")
            }
            Button("Plan my studying") {
                workspace.askAboutCourse(question: "Help me plan my studying using the course topics, readings, and deadlines.")
            }
        }
    }
    private var emptyConversation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "leaf").font(.system(size: 29, weight: .light)).foregroundStyle(Color.accentColor)
                .padding(.top, 20)
            Text(workspace.mode == .chat ? "What's on your mind?" : workspace.isCourseConversation ? "Your whole course, in view."
                : workspace.assignment != nil ? "Let's work through your assignment." : "Let's make it click.")
                .font(.system(size: 24, design: .serif))
            Text(
                workspace.mode == .chat
                    ? "Ask anything, brainstorm, or talk through an idea. Course materials are available when relevant."
                    : workspace.isCourseConversation
                    ? "Ask about topics, assignments, deadlines, or connections between readings. I'll use your course information and relevant passages from saved materials."
                    : workspace.assignment != nil
                    ? "Ask about a problem, equation, or figure. I'll use the assignment instructions, this reading, and its saved included files to help you work through it."
                    : workspace.document == nil
                    ? "Open a reading and bring your questions. We can unpack an idea, work through a problem, or practise together."
                    : "Ask about a passage, equation, or figure. I'll use this page and the rest of your reading to help you understand."
            )
            .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5).fixedSize(
                horizontal: false, vertical: true)
            VStack(spacing: 8) {
                if workspace.mode == .chat {
                    suggestion(.chat, icon: "bubble.left.and.bubble.right")
                } else if workspace.isCourseConversation {
                    courseSuggestion("Give me a course overview", icon: "books.vertical",
                        question: "Give me an overview of this course: its main topics, available materials, and how the topics connect. Distinguish saved content from catalog-only information.")
                    courseSuggestion("What's due next?", icon: "calendar",
                        question: "What's due next in this course? Use the saved submission status; flag dates that need a Canvas refresh.")
                    courseSuggestion("Help me plan my studying", icon: "list.bullet.clipboard",
                        question: "Help me make a study plan for this course using the available topics, readings, and deadlines. Suggest an order and ask what you need to know about my goals.")
                } else {
                    suggestion(.explain, icon: "lightbulb")
                    suggestion(.practice, icon: "checkmark.bubble")
                }
            }.padding(.top, 7)
            Text("Grounded in your materials. Room for your curiosity.").font(.system(size: 10)).foregroundStyle(
                .tertiary
            ).lineSpacing(3)
        }
    }
    private func courseSuggestion(_ title: String, icon: String, question: String) -> some View {
        Button {
            workspace.askAboutCourse(question: question)
            composerFocused = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(Color.accentColor)
                Text(title).font(.system(size: 11))
                Spacer()
                Image(systemName: "arrow.up.left").font(.system(size: 9)).foregroundStyle(.tertiary)
            }.padding(13).background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.055), lineWidth: 1))
        }.scholiaButtonStyle(.plain)
    }
    private func suggestion(_ mode: StudyTeachingMode, icon: String) -> some View {
        Button {
            workspace.prepareStudyPrompt(mode)
            composerFocused = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(Color.accentColor)
                Text(mode.starterTitle).font(.system(size: 11))
                Spacer()
                Image(systemName: "arrow.up.left").font(.system(size: 9)).foregroundStyle(.tertiary)
            }.padding(13).background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.055), lineWidth: 1))
        }.scholiaButtonStyle(.plain).disabled(workspace.course == nil)
    }
    private func messageView(_ message: ConversationMessage) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(message.role == .user ? "YOU" : "SCHOLIA").font(.system(size: 9, weight: .semibold)).tracking(1.4)
                    .foregroundStyle(.secondary)
                Spacer()
                if !message.isStreaming {
                    if message.role == .user {
                        Button {
                            workspace.edit(message)
                            composerFocused = true
                        } label: {
                            Image(systemName: "pencil")
                        }.help("Edit and regenerate from this message").disabled(workspace.isStreaming)
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }.help("Copy message")
                }
            }.font(.system(size: 10)).scholiaButtonStyle(.plain)
            if let data = message.imageData { ConversationMessageImageView(data: data, compact: true) }
            if message.role == .user, let attachments = message.attachments, !attachments.isEmpty {
                MessageAttachmentChips(attachments: attachments)
            }
            if message.role == .user {
                Text(message.content).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled).fixedSize(
                    horizontal: false, vertical: true)
            } else {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    ProviderReasoningView(source: reasoning, compact: true)
                }
                if let activity = message.activity { ConversationActivityView(events: activity) }
                if !message.content.isEmpty {
                    let references = workspace.chatReferenceContext(for: message)
                    RichMarkdownView(source: message.content, compact: true,
                        onOpenLink: { openChatLink($0, references: references) }, references: references)
                }
                if message.isStreaming {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        HStack(alignment: .top, spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(message.metadata ?? "Preparing your answer…")
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Text("\(max(0, Int(context.date.timeIntervalSince(workspace.answerStartedAt ?? context.date))))s")
                                .monospacedDigit()
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !message.isStreaming, let sources = workspace.thread?.sources[message.id.uuidString],
                    !sources.isEmpty
                {
                    let cited = workspace.isCourseConversation ? [] : StudyContextBuilder.citedSources(in: message.content, allowed: sources)
                    if !cited.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            ForEach(cited.prefix(8)) { source in
                                Button("p. \(source.page)") { workspace.navigate(to: source) }
                                    .scholiaButtonStyle(.bordered).controlSize(.mini).help(
                                        "Read \(source.title), page \(source.page)")
                            }
                        }
                    }
                    DisclosureGroup {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 95), alignment: .leading)], alignment: .leading,
                            spacing: 6
                        ) {
                            ForEach(sources) { source in
                                Button {
                                    workspace.navigate(to: source)
                                } label: {
                                    Text(
                                        !workspace.isCourseConversation && source.documentID == workspace.document?.id
                                            ? "Page \(source.page)" : "\(source.title) · p. \(source.page)"
                                    )
                                    .font(.system(size: 10)).lineLimit(1)
                                }.scholiaButtonStyle(.bordered).controlSize(.mini).help(
                                    "\(source.title), page \(source.page)")
                            }
                        }.padding(.top, 7)
                    } label: {
                        Label("\(sources.count) pages provided", systemImage: "doc.text.magnifyingglass").font(
                            .system(size: 10)
                        ).foregroundStyle(.secondary)
                    }
                }
                if let metadata = message.metadata {
                    Text(metadata).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(2)
                }
                if !message.isStreaming {
                    ChatResponseUsageView(usage: message.usage, duration: message.responseDurationSeconds)
                }
            }
        }.padding(message.role == .user ? 13 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                message.role == .user ? Color.accentColor.opacity(dark ? 0.12 : 0.06) : .clear,
                in: RoundedRectangle(cornerRadius: 12))
    }
    private func openChatLink(_ url: URL, references: ChatReferenceContext) -> Bool {
        switch references.destination(for: url) {
        case .document(let id, let page):
            guard let document = workspace.course?.documents.first(where: { $0.id == id }) else { return true }
            workspace.navigate(to: StudySource(documentID: id, title: document.title, page: page))
            return true
        case .attachment(let id, let member):
            if let attachment = workspace.chatAttachment(id: id) {
                inspectedChatAttachment = ChatAttachmentInspection(attachment: attachment, member: member)
            }
            return true
        case nil: return workspace.openCourseLink(url)
        }
    }
    private var contextDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Text("What the tutor can see").font(.headline)
                Toggle(contextTitle, isOn: $workspace.automaticContextEnabled).font(.caption).toggleStyle(.switch)
                    .disabled(workspace.isCurrentThreadStreaming)
                    .accessibilityIdentifier("study-automatic-context")
                    .onChange(of: workspace.automaticContextEnabled) { _, _ in workspace.saveDraft() }
                if workspace.document != nil && workspace.isCourseConversation {
                    Button {
                        workspace.askAboutOpenDocument()
                        composerFocused = true
                        contextPresented = false
                    } label: {
                        Label("Use open document for this question", systemImage: "doc.text.magnifyingglass").font(.caption)
                    }.scholiaButtonStyle(.plain).foregroundStyle(Color.accentColor)
                        .disabled(workspace.isStreaming || workspace.isIngestingAttachment)
                } else if workspace.course != nil && !workspace.isCourseConversation && !assignmentFocused {
                    Button {
                        workspace.askAboutCourse()
                        composerFocused = true
                        contextPresented = false
                    } label: {
                        Label("Ask about this course", systemImage: "books.vertical").font(.caption)
                    }.scholiaButtonStyle(.plain).foregroundStyle(Color.accentColor)
                }
                Text(workspace.automaticContextEnabled
                    ? nextContextDescription
                    : "Off: no course, assignment, current document, page images, or workspace memory will be added to your next question.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Your messages, explicit attachments, and selected passages remain available. Earlier replies remain in the conversation.")
                    .font(.caption).foregroundStyle(.secondary)
                if workspace.automaticContextEnabled {
                    if let course = workspace.course { Label(course.displayName, systemImage: "books.vertical").font(.caption) }
                    if let document = workspace.document { Label(document.title, systemImage: "doc.text").font(.caption) }
                    if let assignment = workspace.assignment { Label(assignment.title, systemImage: "checklist").font(.caption) }
                    Text(
                        workspace.isCourseConversation
                            ? "Course details, the material inventory, and saved assignment deadlines and status are included. Relevant passages are selected across your saved readings. Catalog-only materials provide titles and metadata; their unread contents are not included."
                            : "Focused reading starts with your current page and selection. Every question can search the whole indexed document and bring in relevant pages, even far away. Whole document sends all extracted text when it fits. Searching a page does not mean its full contents were sent; the last-request list below shows the pages actually included."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if workspace.assignment != nil {
                        Text(
                            "This assignment's instructions and readable included files are prepared for the companion, independently of the course-materials option below. Each file shows whether its content is ready."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    if !workspace.isCourseConversation {
                        Toggle("Also use course library and memory", isOn: $workspace.includeCourseContext).font(.caption)
                            .toggleStyle(.checkbox)
                            .disabled(workspace.isCurrentThreadStreaming || workspace.includeEntirePDF)
                            .help("Optional: add relevant saved course files and workspace memory. Whole document sends the open document's text.")
                            .onChange(of: workspace.includeCourseContext) { _, _ in workspace.saveDraft() }
                        Text("Off: use the open document and your explicit messages, selections, and attachments. Assignment conversations still include their project instructions and files.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !lastContextSources.isEmpty {
                    Divider()
                    Text("Pages sent with the last question").font(.subheadline.weight(.semibold))
                    ForEach(lastContextSources) { source in
                        Button {
                            workspace.navigate(to: source)
                        } label: {
                            Label("\(source.title) · p. \(source.page)", systemImage: "doc.text.magnifyingglass")
                                .font(.caption).multilineTextAlignment(.leading)
                        }.scholiaButtonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                }
                let files = contextAttachments
                if !files.isEmpty {
                    Divider()
                    Text("Explicit attachments · \(files.count)").font(.subheadline.weight(.semibold))
                    ForEach(files) { file in
                        DisclosureGroup {
                            Text(file.readingDetailsText).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            if !file.extractedText.isEmpty {
                                Text("Saved attachment preview. Focused questions may send selected excerpts; the last-sent summary reports coverage.")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(String(file.extractedText.prefix(3_000)))
                                    .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                                if file.extractedText.count > 3_000 {
                                    Text("Preview shows the first 3,000 characters; \((file.textCorpusUTF16Count ?? file.extractedText.utf16.count).formatted()) extracted characters are saved for search.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Toggle(isOn: Binding(get: { file.includedInContext }, set: { workspace.setAttachmentIncluded(file.id, included: $0) })) {
                                    Text(file.fileName).font(.caption).lineLimit(2)
                                }.toggleStyle(.checkbox).disabled(workspace.isCurrentThreadStreaming)
                                Text(file.readStatusLabel).font(.caption2)
                                    .foregroundStyle(file.effectiveReadStatus == .complete ? Color.secondary : Color.orange)
                            }
                        }
                    }
                }
                if !workspace.contextSummary.isEmpty { Text("Last question: \(workspace.contextSummary)").font(.caption) }
                if workspace.automaticContextEnabled {
                    Text(
                        workspace.isCourseConversation
                            ? "Questions use the saved course information, which may need refreshing in Canvas. Your chosen provider receives this context only when you send a question."
                            : workspace.includeEntirePDF
                            ? "Whole document includes extracted text. Attach specific figures as images when their visual details matter. Your chosen provider receives the text only when you send a question."
                            : "For PDFs and images, vision models also receive the current page and up to three requested or relevant page images. Your chosen provider receives this context only when you send a question."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let document = workspace.document, document.unreadablePages > 0 {
                    Text(
                        "\(document.unreadablePages) pages have no extracted text after OCR. Open those pages and use a vision model to inspect them."
                    ).font(.caption).foregroundStyle(.orange)
                }
            }.padding(20)
        }.frame(width: 360).frame(maxHeight: 540)
    }
    private var contextAttachments: [MessageAttachment] {
        var seen = Set<UUID>()
        return (workspace.draftAttachments + workspace.messages.flatMap { $0.role == .user ? ($0.attachments ?? []) : [] })
            .filter { seen.insert($0.id).inserted }
    }
    private var lastContextSources: [StudySource] {
        guard let answer = workspace.messages.last(where: { $0.role == .assistant }) else { return [] }
        return workspace.thread?.sources[answer.id.uuidString] ?? []
    }
}

private struct StudyCanvasSheet: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var token = ""
    @State private var advanced = false
    @State private var downloadAll = false
    @State private var showDownloadInventory = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 12) {
                Image(systemName: "link.circle").font(.system(size: 31)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bring your courses along.").font(.system(size: 25, design: .serif))
                    Text("Every course in one library. Download at your own pace.").font(.caption).foregroundStyle(
                        .secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .help(workspace.canvasBusy ? "Close this window; downloads continue in Scholia." : "Close Canvas")
            }
            HStack {
                TextField("Canvas address", text: $workspace.canvasAddress).textFieldStyle(.roundedBorder).disabled(
                    workspace.canvasBusy || workspace.canvasSigningIn)
                Button(workspace.canvasSigningIn ? "Hide sign-in"
                    : workspace.canvasNeedsAuthentication ? workspace.canvasReconnectTitle : "Sign in") {
                    if workspace.canvasSigningIn { workspace.cancelCanvasSignIn() }
                    else { Task { await workspace.beginCanvasSignIn() } }
                }.disabled(workspace.canvasBusy || workspace.canvasChecking)
                Button(downloadAll ? "Download everything" : "Index all courses") {
                    workspace.loadCanvasCourses(downloadAll: downloadAll)
                }.disabled(workspace.canvasBusy).scholiaButtonStyle(.borderedProminent)
            }
            Text(workspace.canvasConnectionStatus).font(.caption).foregroundStyle(.secondary)
                .task { await workspace.checkCanvasConnection() }
            if workspace.canvasSigningIn, let origin = try? CanvasAddress.origin(workspace.canvasAddress) {
                CanvasSignInView(origin: origin, onSignedIn: {
                    Task { await workspace.checkCanvasConnection(allowKeychainInteraction: true) }
                }, onError: workspace.canvasSignInFailed).frame(height: 420).clipShape(RoundedRectangle(cornerRadius: 10))
                Text(
                    "Sign in on your institution’s page. Scholia does not read your password. Canvas session cookies are kept in this Mac’s Keychain; Disconnect removes them."
                ).font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("How to bring your courses into Scholia", selection: $downloadAll) {
                        Text("Index first · download on demand").tag(false)
                        Text("Download everything for offline study").tag(true)
                    }.pickerStyle(.radioGroup).scholiaPointingCursor().disabled(workspace.canvasBusy)
                    Text(
                        downloadAll
                            ? "Lists every course and downloads supported PDFs, images, pages, notes, and assignments. Large libraries can take a while; you can stop and resume."
                            : "Adds cards for all courses and a searchable list of materials. Nothing is downloaded until you open a material. Favorite the courses you use most."
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Divider().padding(.vertical, 2)
                    StudyCourseUpdatePreferences(workspace: workspace)
                    if workspace.library.canvasUserID != nil {
                        Button(workspace.newCanvasFileCount > 0 ? "Download new files · \(workspace.newCanvasFileCount)" : "Check for new files") {
                            let pending = workspace.newCanvasFileCount > 0
                            let courses = pending ? workspace.coursesWithNewCanvasFiles : workspace.automaticCanvasFileCourses()
                            workspace.checkForNewCanvasFiles(courseIDs: courses.map(\.id), download: pending ? true : nil)
                        }.disabled(workspace.canvasBusy)
                    }
                    Divider().padding(.vertical, 2)
                    Picker("Download priority", selection: $workspace.canvasDownloadPriority) {
                        Text("Background").tag(CanvasDownloadPriority.background)
                        Text("Prioritize downloads").tag(CanvasDownloadPriority.prioritized)
                    }.pickerStyle(.segmented).scholiaPointingCursor()
                    Text(
                        workspace.canvasDownloadPriority == .background
                            ? "Downloads run gently while you study. Close this window to keep working while they continue."
                            : "Uses available bandwidth for faster downloads, without pausing for study activity. Switch back to Background whenever you want; closing this window lets downloads continue."
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if workspace.library.canvasUserID != nil {
                        Button("Browse course cards") {
                            workspace.showCourseLibrary()
                            dismiss()
                        }.scholiaButtonStyle(.bordered)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            }
            if let status = workspace.canvasStatus {
                HStack(alignment: .top, spacing: 9) {
                    if workspace.canvasBusy { ProgressView().controlSize(.small) }
                    Text(status).font(.caption).textSelection(.enabled)
                    Spacer()
                    if workspace.canvasBusy {
                        Button("Stop", action: workspace.cancelCanvas).font(.caption)
                            .help("Stop downloading and keep completed materials and progress.")
                    }
                }.padding(11).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            if workspace.canvasDownloadPendingCount > 0, !workspace.canvasBusy {
                HStack(spacing: 10) {
                    Image(systemName: "pause.circle").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Downloads paused").font(.system(size: 12, weight: .semibold))
                        Text(
                            "\(workspace.canvasDownloadPendingCount) \(workspace.canvasDownloadPendingCount == 1 ? "course" : "courses") remaining. Completed materials stay saved."
                        ).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Resume downloads", action: workspace.resumeCanvasDownloads)
                        .scholiaButtonStyle(.borderedProminent)
                        .disabled(workspace.canvasChecking || workspace.canvasSigningIn)
                }.padding(11).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            downloadedMaterials
            if !workspace.canvasWarnings.isEmpty {
                DisclosureGroup("\(workspace.canvasWarnings.count) Canvas notices") {
                    ScrollView {
                        Text(workspace.canvasWarnings.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                }.font(.caption)
            }
            if !workspace.canvasSigningIn {
                DisclosureGroup("Personal development connection", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            "For your own Canvas account, a personal access token can be used if embedded sign-in is unavailable. It is stored in macOS Keychain. A distributed integration requires institution-approved OAuth."
                        ).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            SecureField("Personal access token", text: $token).textFieldStyle(.roundedBorder)
                            Button("Connect") {
                                workspace.loadCanvasCourses(token: token, downloadAll: downloadAll)
                                token = ""
                            }.disabled(
                                token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.canvasBusy)
                        }
                        if let origin = try? CanvasAddress.origin(workspace.canvasAddress) {
                            Link(
                                "Open Canvas account settings",
                                destination: origin.appendingPathComponent("profile/settings")
                            ).font(.caption)
                        }
                    }.padding(.top, 8)
                }.font(.caption)
            }
            HStack {
                Text("Course access is read-only. Nothing is submitted or changed in Canvas.").font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                if workspace.library.canvasUserID != nil {
                    Button("Disconnect", action: workspace.disconnectCanvas).font(.caption).disabled(
                        workspace.canvasBusy)
                }
            }
        }.padding(27)
        }
            .frame(width: 690, height: min(720, (NSScreen.main?.visibleFrame.height ?? 800) - 80))
            .background(StudyPalette.paper(colorScheme == .dark))
            .tint(ScholiaVisualStyle.accentColor(for: colorScheme))
            .accentColor(ScholiaVisualStyle.accentColor(for: colorScheme))
            .onAppear { workspace.verifyCanvasDownloads() }
            .onDisappear { workspace.cancelCanvasSignIn() }
    }

    private var downloadedMaterials: some View {
        let courses = workspace.canvasDownloadInventory
        let total = CanvasCourseDownloadInventory.total(courses)
        return VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $showDownloadInventory) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(courses) { course in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(course.title).font(.caption).lineLimit(1)
                                    Text("\(course.saved) saved · \(course.formattedBytes) · \(course.ready)/\(course.available) ready")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    if course.repairs > 0 {
                                        Text("\(course.repairs) need repair").font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                StudyCourseUpdateButton(workspace: workspace, courseID: course.id).font(.caption)
                                Button("View files") { workspace.selectCourse(course.id); dismiss() }.font(.caption)
                            }
                        }
                    }.padding(.top, 7)
                }.frame(maxHeight: 160)
                Text("Ready means the saved original and index passed verification and match Canvas’s current version. Unavailable materials are listed in Canvas notices. Legacy files without a saved hash are verified by downloading a fresh copy.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(total.saved) materials saved · \(total.formattedBytes)").font(.system(size: 12, weight: .semibold))
                    Text("\(total.ready) of \(total.available) known available materials ready offline")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                if workspace.canvasVerifyingDownloads {
                    ProgressView().controlSize(.small)
                    Text("Verifying saved files…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop verification", action: workspace.cancelCanvasVerification).font(.caption)
                } else {
                    Text("\(total.verified) verified · \(total.unverified) unchecked · \(total.repairs) need repair")
                        .font(.caption).foregroundStyle(total.repairs > 0 ? .orange : .secondary)
                    Spacer()
                    Button("Verify saved files", action: workspace.verifyCanvasDownloads).font(.caption)
                }
            }
            if let checked = total.checkedAt {
                Text("Last file check: \(checked.formatted(date: .abbreviated, time: .shortened)). Resume rechecks saved files; catalog totals may grow as courses are checked.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(11).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct StudyTutorComposer: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    @ObservedObject var draftState: StudyComposerDraft
    @Binding var composerFocused: Bool
    var compact = false
    @EnvironmentObject private var app: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var modelsPresented = false
    @State private var inspectedAttachment: MessageAttachment?
    private var dark: Bool { colorScheme == .dark }
    private var modelDefinition: ModelDefinition? { app.modelDefinition(for: app.activeProvider, id: app.activeModel) }
    private var visionAvailable: Bool {
        (modelDefinition?.supportsImages ?? (app.activeProvider.id != "opencode"))
            && (app.activeProvider.supportsImages || app.activeProvider.bridge?.imageSupportComesFromHealth == true)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if workspace.editingMessageID != nil {
                HStack {
                    Text("Editing · later replies will be replaced on send").font(.system(size: 10)).foregroundStyle(
                        .secondary)
                    Spacer()
                    Button("Cancel", action: workspace.cancelEdit).font(.caption).scholiaButtonStyle(.plain)
                }
            }
            if !workspace.selectedText.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.quote").foregroundStyle(Color.accentColor)
                    Text(workspace.selectedText).font(.system(size: 10)).lineLimit(3).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        workspace.selectedText = ""
                    } label: {
                        Image(systemName: "xmark")
                    }.scholiaButtonStyle(.plain)
                }.padding(9).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            }
            if let data = workspace.draftImage {
                HStack(alignment: .top) {
                    ConversationMessageImageView(data: data, compact: true).frame(maxHeight: 90)
                    Button {
                        workspace.draftImage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }.scholiaButtonStyle(.plain).help("Remove attached image")
                        .accessibilityLabel("Remove attached image")
                }
            }
            if !workspace.draftAttachments.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(workspace.draftAttachments) { file in
                            HStack(spacing: 8) {
                                Toggle(isOn: Binding(get: { file.includedInContext }, set: {
                                    workspace.setAttachmentIncluded(file.id, included: $0)
                                })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(file.sourceKindLabel) · \(file.fileName)").font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                        if let path = file.sourcePath {
                                            Text(path).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                        }
                                        Text(file.includedInContext ? file.readStatusLabel : "Excluded from context")
                                            .font(.system(size: 10))
                                            .foregroundStyle(file.effectiveReadStatus == .complete || !file.includedInContext ? Color.secondary : Color.orange)
                                        if file.includedInContext, let limitation = file.readingLimitSummary {
                                            Text(limitation).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                }.toggleStyle(.checkbox).disabled(workspace.isCurrentThreadStreaming)
                                Spacer(minLength: 0)
                                Button { inspectedAttachment = file } label: {
                                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                                }.scholiaButtonStyle(.plain).help("Show extracted-file coverage and reading limitations")
                                    .accessibilityLabel("Reading details for \(file.fileName)")
                                if file.sourcePath != nil {
                                    Button { workspace.refreshDraftAttachment(file.id) } label: {
                                        Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                                    }.scholiaButtonStyle(.plain)
                                        .disabled(workspace.isCurrentThreadStreaming || workspace.isIngestingAttachment)
                                        .help("Read the original file or folder again, including content skipped by older text limits")
                                        .accessibilityLabel("Read all available content in \(file.fileName) again")
                                }
                                Button { workspace.removeDraftAttachment(file.id) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }.scholiaButtonStyle(.plain).accessibilityLabel("Remove \(file.fileName)")
                            }.help(file.readDetail ?? file.readStatusLabel)
                                .padding(8).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(height: min(210, workspace.draftAttachments.reduce(CGFloat.zero) { $0 + ($1.readingLimitSummary == nil ? 70 : 100) }))
                    .popover(item: $inspectedAttachment) { file in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(file.fileName).font(.headline)
                                Text(file.readStatusLabel).font(.subheadline).foregroundStyle(file.effectiveReadStatus == .complete ? Color.secondary : Color.orange)
                                Text(file.readingDetailsText).font(.system(size: 11)).textSelection(.enabled)
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(width: 370).frame(maxHeight: 450)
                    }
            }
            if workspace.isIngestingAttachment {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(workspace.attachmentStatus ?? "Reading attachments…").font(.caption)
                    Spacer()
                    Button("Cancel", action: workspace.cancelAttachmentIngestion).font(.caption)
                }.foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 9) {
                ComposerTextView(
                    text: $draftState.text, isFocused: $composerFocused,
                    placeholder: workspace.course == nil
                        ? "Create a workspace to begin…" : !workspace.automaticContextEnabled
                            ? "Ask a question about your attachments…" : workspace.mode == .chat
                            ? "Ask anything, or talk through an idea…" : workspace.isCourseConversation
                            ? "Ask about this course, its topics or deadlines…" : "Ask about what you're reading…",
                    font: .systemFont(ofSize: 13), minHeight: compact ? 30 : 34, maxHeight: compact ? 120 : 180,
                    isEnabled: workspace.course != nil,
                    onSubmit: { workspace.send(using: app) },
                    onPasteAttachment: { workspace.attachFromPasteboard() },
                    onDropAttachment: { workspace.attachFromPasteboard($0, acceptingDrop: true) })
                HStack(spacing: 9) {
                    Button(action: workspace.chooseDraftAttachment) { Image(systemName: "paperclip") }.scholiaButtonStyle(
                        .plain
                    ).help("Attach any file or project folder").disabled(workspace.course == nil || workspace.isCurrentThreadStreaming)
                        .accessibilityLabel("Attach files or folder")
                    Button {
                        modelsPresented.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text(app.activeStudyModelMode == .manual
                                 ? modelDefinition?.label ?? app.activeModel : app.activeProvider.name)
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }.scholiaButtonStyle(.plain).popover(isPresented: $modelsPresented) {
                        ScholiaModelPickerPopover(isPresented: $modelsPresented, usesExplainModel: true)
                            .environmentObject(app)
                    }
                    .help(app.activeStudyModelMode == .manual ? "Choose a model"
                        : "The model is chosen for each question. Open to choose a provider or manage models.")
                    .accessibilityLabel("Choose a model")
                    Spacer(minLength: 0)
                    Button {
                        if workspace.isCurrentThreadStreaming {
                            workspace.stopAnswer()
                        } else {
                            workspace.send(using: app)
                        }
                    } label: {
                        Image(systemName: workspace.isCurrentThreadStreaming ? "stop.fill" : "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(dark ? Color.black.opacity(0.88) : Color.white).frame(
                                width: 29, height: 29
                            )
                            .background(
                                Color.accentColor.opacity(
                                    workspace.canSend || workspace.isCurrentThreadStreaming ? 1 : 0.4),
                                in: RoundedRectangle(cornerRadius: 8))
                    }.scholiaButtonStyle(.plain).disabled(!workspace.canSend && !workspace.isCurrentThreadStreaming)
                        .help(workspace.isCurrentThreadStreaming ? "Stop response" : "Send question")
                        .accessibilityLabel(workspace.isCurrentThreadStreaming ? "Stop response" : "Send question")
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { studyControls }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 8) { studyControls }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let document = workspace.document, ![.image, .preview].contains(document.kind), !workspace.isCourseConversation {
                    Toggle("Whole document · all text", isOn: $workspace.includeEntirePDF)
                        .toggleStyle(.checkbox).font(.system(size: 10)).foregroundStyle(.secondary)
                        .disabled(workspace.isStreaming || !workspace.automaticContextEnabled)
                        .help("Off: current page plus relevant pages found across the full document. On: include all extracted text within the document limit.")
                }
            }.padding(12).background(
                dark ? Color.primary.opacity(0.035) : .white, in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.13), lineWidth: 1))
            HStack(spacing: 4) {
                Image(systemName: visionAvailable ? "eye" : "text.alignleft")
                Text(
                    !workspace.automaticContextEnabled ? "Conversation, selections, and attachments" : workspace.isCourseConversation
                        ? "Course information + relevant saved text" : workspace.includeEntirePDF
                        ? "Whole document text · attach figures as needed" : workspace.includeCourseContext
                        ? "Open document + course library" : "Current page + search across the open document")
                Spacer(minLength: 0)
                Text("↵ send").foregroundStyle(.tertiary)
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, compact ? 10 : 17).padding(.top, compact ? 8 : 12).padding(.bottom, compact ? 10 : 17)
            .onChange(of: workspace.draftImage) { _, _ in workspace.saveDraft() }
            .onChange(of: workspace.mode) { _, _ in workspace.saveDraft() }
            .onChange(of: workspace.includeEntirePDF) { _, _ in workspace.saveDraft() }
    }
    @ViewBuilder private var studyControls: some View {
        AnswerLanguageMenu(selection: Binding(
            get: { app.settings.language },
            set: { app.settings.language = $0; app.persistSettings() }
        ))
        Menu {
            ForEach(StudyModelMode.allCases) { mode in
                Button {
                    app.selectStudyModelMode(mode)
                } label: {
                    if app.activeStudyModelMode == mode {
                        Label(mode.label, systemImage: "checkmark")
                    } else {
                        Text(mode.label)
                    }
                }.help(mode.detail)
            }
        } label: {
            Label(app.activeStudyModelMode.label, systemImage: "bolt")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }.menuStyle(.borderlessButton).scholiaPointingCursor().fixedSize()
            .help(app.activeStudyModelMode.detail).accessibilityLabel("Study model mode")
            .accessibilityValue(app.activeStudyModelMode.label)
            .accessibilityIdentifier("study-model-mode")
        if app.activeStudyModelMode == .manual, let definition = modelDefinition, !definition.reasoningEfforts.isEmpty {
            Menu {
                ForEach(definition.reasoningEfforts, id: \.self) { effort in
                    Button {
                        try? app.selectStudyReasoningEffort(effort)
                    } label: {
                        if effort == app.activeStudyReasoningEffort {
                            Label(effort == "xhigh" ? "Extra high" : effort.capitalized, systemImage: "checkmark")
                        } else {
                            Text(effort == "xhigh" ? "Extra high" : effort.capitalized)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "brain")
                    Text(app.activeStudyReasoningEffort == "xhigh" ? "Extra high" : (app.activeStudyReasoningEffort ?? "default").capitalized)
                }.font(.system(size: 10)).foregroundStyle(.secondary).fixedSize()
            }.menuStyle(.borderlessButton).scholiaPointingCursor().fixedSize().help(
                "Reasoning mode: \(app.activeStudyReasoningEffort ?? "default")"
            )
            .accessibilityLabel("Reasoning mode")
            .accessibilityValue(app.activeStudyReasoningEffort ?? "default")
        }
        if app.activeProvider.id == "codex" {
            CodexUsageIndicator(monitor: app.codexUsage, configuration: app.codexUsageConfiguration())
        }
    }
}

/// A saved conversation in the sidebar, with its delete action visible on hover
/// or selection rather than only in a context menu.
private struct StudySidebarThreadRow: View {
    let thread: StudyThread
    var selected: Bool
    var deletable: Bool
    var open: () -> Void
    var delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Button(action: open) {
                Label(thread.title, systemImage: "bubble.left")
                    .font(.system(size: 11)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9).contentShape(Rectangle())
            }.scholiaButtonStyle(.plain)
            if hovering || selected {
                Button(action: delete) { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(ScholiaIconButtonStyle(size: 24)).disabled(!deletable)
                    .help("Delete conversation").accessibilityLabel("Delete \(thread.title)")
                    .padding(.trailing, 4)
            }
        }
        .background(selected ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
        .contextMenu { Button("Delete conversation", role: .destructive, action: delete).disabled(!deletable) }
    }
}

/// Workspace options as labelled controls in a popover instead of a menu.
private struct StudyWorkspaceOptionsPanel: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    @Binding var presented: Bool
    var rename: () -> Void
    var remove: () -> Void
    @EnvironmentObject private var app: AppModel

    private func dismiss(then action: @escaping () -> Void) {
        presented = false
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            action()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.course?.displayName ?? "Workspace").font(.headline).lineLimit(1)
                if let code = workspace.course?.displayCode, !code.isEmpty {
                    Text(code).font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Favorite", isOn: Binding(
                get: { workspace.course?.isFavorite == true },
                set: { _ in if let id = workspace.course?.id { workspace.toggleFavorite(id) } }
            )).toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Preload frequent courses", isOn: $workspace.preloadFrequentCourses).toggleStyle(.switch)
                Text("After repeated visits, save up to three small readings in the background. Paused in Low Power Mode.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Browse materials") { dismiss(then: workspace.showCourseMaterials) }
                Button("Rename…") { dismiss(then: rename) }
            }.controlSize(.small)
            if !app.savedConversations.isEmpty {
                Divider()
                Text("Bring in a saved chat").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(app.savedConversations) { conversation in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(conversation.title).font(.system(size: 12)).lineLimit(1)
                                    Text(conversation.updatedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Button("Add") { dismiss { workspace.importConversation(conversation) } }.controlSize(.small)
                                    .accessibilityLabel("Bring in \(conversation.title)")
                            }.padding(.vertical, 3)
                        }
                    }
                }.frame(maxHeight: 160)
            }
            Divider()
            Button("Remove workspace…", role: .destructive) { dismiss(then: remove) }
                .controlSize(.small)
                .disabled(workspace.isStreaming || workspace.isImporting || workspace.canvasBusy)
        }
        .padding(16).frame(width: 300)
    }
}
