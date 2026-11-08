import SwiftUI

struct StudyAssignmentsPageView: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Assignments").font(.system(size: 29, design: .serif))
                    Text("Every workspace. Upcoming work, submissions, grades, and feedback.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await workspace.refreshCanvasAssignmentsIfNeeded(force: true) }
                } label: {
                    Label(workspace.assignmentRefreshBusy ? "Refreshing…" : "Refresh status", systemImage: "arrow.clockwise")
                }.disabled(workspace.canvasBusy || workspace.assignmentRefreshBusy)
            }
            StudyAssignmentAgendaView(workspace: workspace, initialFilter: workspace.assignmentViewFilter,
                initialQuery: workspace.assignmentViewQuery, dedicated: true).equatable()
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct StudySubmissionBadge: View {
    var status: CanvasSubmissionStatus?
    var grade: String? = nil
    var feedback = false
    var corrected = false
    var body: some View {
        let value = status ?? .unknown
        let color = value == .graded ? Color.green : value == .submitted ? Color.blue : Color.secondary
        Label(
            value.submissionLabel + (grade.map { " · Grade: \($0)" } ?? "") + (feedback ? " · Feedback available" : ""),
            systemImage: value == .graded ? "checkmark.seal.fill" : value == .submitted ? "clock"
                : value == .excused ? "minus.circle" : value == .unknown ? "questionmark.circle" : "circle"
        )
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(color.opacity(0.08), in: Capsule())
        .help(corrected ? "Status set in Scholia. Choose Use Canvas status to resume automatic status updates."
            : value == .submitted ? "Submitted in Canvas; a grade for this attempt is not available yet." : value.submissionLabel)
    }
}

struct StudyAssignmentStatusMenu: View {
    // The owning row already observes workspace changes. Passing its small
    // display value avoids a subscriber and a full course scan for every menu.
    let workspace: StudyWorkspaceModel
    let courseID: UUID
    let assignmentID: String
    let progress: StudyAssignmentProgress?

    var body: some View {
        Menu {
            Button {
                workspace.setAssignmentProgress(nil, id: assignmentID, courseID: courseID)
            } label: {
                Label("Use Canvas status", systemImage: progress == nil ? "checkmark" : "arrow.triangle.2.circlepath")
            }
            Divider()
            ForEach(StudyAssignmentProgress.allCases) { value in
                Button {
                    workspace.setAssignmentProgress(value, id: assignmentID, courseID: courseID)
                } label: {
                    Label(value.title, systemImage: progress == value ? "checkmark" : "circle")
                }
            }
        } label: {
            Label(progress == nil ? "Status" : "Status set in Scholia", systemImage: "slider.horizontal.3")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 10)).menuStyle(.borderlessButton).tint(.primary).fixedSize()
        .help("Correct the status in Scholia without changing Canvas")
        .accessibilityLabel("Assignment status")
    }
}

struct StudyAssignmentAgendaView: View, Equatable {
    let workspace: StudyWorkspaceModel
    @StateObject private var agenda: StudyAssignmentAgendaState
    @State private var query = ""
    @State private var filter: StudyAssignmentFilter
    private let initialFilter: StudyAssignmentFilter
    private let initialQuery: String
    @State private var pageIndex = 0
    let dedicated: Bool
    @Environment(\.colorScheme) private var scheme

    init(workspace: StudyWorkspaceModel, initialFilter: StudyAssignmentFilter = .due, initialQuery: String = "", dedicated: Bool = false) {
        self.workspace = workspace
        self.dedicated = dedicated
        self.initialFilter = initialFilter
        self.initialQuery = initialQuery
        _query = State(initialValue: initialQuery)
        _agenda = StateObject(wrappedValue: StudyAssignmentAgendaState(workspace: workspace))
        _filter = State(initialValue: initialFilter)
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.workspace === rhs.workspace && lhs.initialFilter == rhs.initialFilter && lhs.initialQuery == rhs.initialQuery && lhs.dedicated == rhs.dedicated
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let courses = agenda.input.courses.map(\.studyCourse)
            let allGroups = StudyAssignmentGroup.make(
                courses: courses, query: query, filter: filter, now: context.date)
            let count = allGroups.reduce(0) { $0 + $1.items.count }
            let page = min(pageIndex, max(0, (count - 1) / 100))
            let groups = dedicated ? StudyAssignmentGroup.slice(allGroups, offset: page * 100, limit: 100)
                : StudyAssignmentGroup.preview(allGroups, limit: 12, now: context.date)
            let assignments = StudyAssignment.list(courses: courses, includeCompleted: true)
            let handedIn = assignments.filter { $0.details?.status == .submitted }.count
            let graded = assignments.filter { $0.details?.status == .graded }.count
            let timeline = StudyAssignmentTimeline(groups: groups)
            let showTimeline = filter != .all && (filter == .due || !timeline.past.isEmpty || !timeline.upcoming.isEmpty)
            let sections: [StudyAssignmentTimeframe] = filter == .all
                ? [.upcoming, .overdue, .handedIn, .graded, .excused, .undated]
                : [.undated, .handedIn, .graded, .excused, .archive]
            ScrollViewReader { scroll in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(dedicated ? "Your assignments" : "Assignments").font(.system(size: 21, design: .serif))
                    Text("\(count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if !dedicated {
                        Button("View all") { workspace.showAssignments(query: query, filter: filter) }
                            .font(.system(size: 11)).scholiaButtonStyle(.plain)
                    }
                    if showTimeline {
                        Button("Today") {
                            if dedicated {
                                let before = allGroups.filter { $0.timeframe == .overdue }.reduce(0) { $0 + $1.items.count }
                                pageIndex = before / 100
                            }
                            Task { @MainActor in
                                await Task.yield()
                                scrollToToday(scroll)
                            }
                        }
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                            .scholiaButtonStyle(.plain).help("Jump to today in assignments")
                            .accessibilityLabel("Jump to today in assignments")
                    } else {
                        Image(systemName: "calendar.badge.clock").font(.system(size: 19, weight: .light))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack {
                        submissionCounts(handedIn: handedIn, graded: graded)
                        Spacer(minLength: 4)
                        assignmentFilter
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        submissionCounts(handedIn: handedIn, graded: graded)
                        assignmentFilter
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find an assignment", text: $query).textFieldStyle(.plain)
                        .accessibilityLabel("Find an assignment")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .scholiaButtonStyle(.plain).foregroundStyle(.secondary)
                            .help("Clear assignment search").accessibilityLabel("Clear assignment search")
                    }
                }.font(.system(size: 12)).padding(10)
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                if agenda.input.incomplete {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath").padding(.top, 1)
                        Text("Sync Canvas to refresh deadlines and submission status.").fixedSize(
                            horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Canvas…") { workspace.canvasPresented = true }.scholiaButtonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Divider()
                ScrollView {
                    // Bounded pages preserve exact Today/section anchors without
                    // asking SwiftUI to measure thousands of variable-height rows.
                    VStack(alignment: .leading, spacing: 22) {
                        Color.clear.frame(height: 0).id("assignment-start")
                        if showTimeline {
                            agendaDays(timeline.past, isPast: true)
                            HStack(alignment: .firstTextBaseline) {
                                Text("Today").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                Spacer(minLength: 8)
                                Text(context.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 11)
                            .overlay(alignment: .top) { Rectangle().fill(Color.accentColor).frame(height: 2) }
                            .overlay(alignment: .bottom) { Divider() }
                            .id("assignment-today")
                            agendaDays(timeline.upcoming)
                            if !allGroups.contains(where: { $0.timeframe == .upcoming }) && count > 0 {
                                Text("No upcoming deadlines.").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        if groups.isEmpty { emptyState }
                        ForEach(sections) { timeframe in
                            let sections = groups.filter { $0.timeframe == timeframe }
                            if !sections.isEmpty {
                                VStack(alignment: .leading, spacing: 14) {
                                    if timeframe != .archive {
                                        HStack {
                                            Text(timeframe.title).font(.system(size: 17, design: .serif))
                                            Spacer()
                                            Text("\(sections.reduce(0) { $0 + $1.items.count })").font(
                                                .system(size: 10))
                                        }.foregroundStyle(timeframe == .overdue ? Color.orange : Color.primary)
                                    }
                                    ForEach(sections) { group in
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(group.semester.title.uppercased()).tracking(1)
                                                .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                                            agendaDays(StudyAssignmentDateGroup.make(group.items))
                                        }
                                    }
                                }
                            }
                        }
                    }.padding(.trailing, 3).padding(.vertical, 3)
                }
                .onAppear {
                    if filter == .due && query.isEmpty { scrollToToday(scroll) }
                }
                .onChange(of: "\(filter.id):\(query)") { _, _ in
                    pageIndex = 0
                    if dedicated { workspace.assignmentViewQuery = query; workspace.assignmentViewFilter = filter }
                    if filter == .due && query.isEmpty {
                        scrollToToday(scroll)
                    } else {
                        scroll.scrollTo("assignment-start", anchor: .top)
                    }
                }
                if dedicated && count > 100 {
                    HStack {
                        Button("Previous") { pageIndex = max(0, page - 1); scroll.scrollTo("assignment-start", anchor: .top) }
                            .disabled(page == 0)
                        Spacer()
                        Text("\(page * 100 + 1)–\(min(count, (page + 1) * 100)) of \(count)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Next") { pageIndex = page + 1; scroll.scrollTo("assignment-start", anchor: .top) }
                            .disabled((page + 1) * 100 >= count)
                    }.controlSize(.small)
                } else if !dedicated && count > 12 {
                    Button("View all \(count) matching assignments") { workspace.showAssignments(query: query, filter: filter) }
                        .font(.system(size: 11)).scholiaButtonStyle(.plain).foregroundStyle(Color.accentColor)
                }
                Text(
                    "\(filter == .hidden ? "Unhide assignments to show them in other lists" : filter == .due ? "Earlier deadlines above · Upcoming below" : filter == .handedIn ? "Handed in · awaiting a grade" : filter == .graded ? "Graded work · feedback marked when available" : filter == .all ? "Complete list, including hidden assignments" : "Undated & completed") · \(TimeZone.current.identifier)"
                )
                .font(.system(size: 10)).foregroundStyle(.secondary)
                if agenda.input.hasCanvasCourses {
                    Text(agenda.input.error ?? "Canvas status refreshes automatically every 2 minutes.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if agenda.input.error != nil {
                        Button("Reconnect Canvas") { workspace.canvasPresented = true }.font(.caption)
                    }
                }
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    scheme == .dark ? Color.white.opacity(0.02) : Color.accentColor.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.065), lineWidth: 1))
            }
        }
    }

    private func scrollToToday(_ scroll: ScrollViewProxy) {
        scroll.scrollTo("assignment-today", anchor: UnitPoint(x: 0, y: 0.18))
    }

    private func submissionCounts(handedIn: Int, graded: Int) -> some View {
        HStack(spacing: 12) {
            Button { filter = .handedIn } label: {
                Label("\(handedIn) awaiting grade", systemImage: "clock")
                    .foregroundStyle(Color.blue)
            }.scholiaButtonStyle(.plain).help("Show handed-in assignments awaiting a grade")
            Button { filter = .graded } label: {
                Label("\(graded) graded", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Color.green)
            }.scholiaButtonStyle(.plain).help("Show graded assignments")
        }.font(.system(size: 11, weight: .medium)).fixedSize()
    }

    private var assignmentFilter: some View {
        Picker("Assignment filter", selection: $filter) {
            ForEach(StudyAssignmentFilter.allCases) { Text($0.rawValue).tag($0) }
        }.labelsHidden().pickerStyle(.menu).scholiaPointingCursor().fixedSize()
            .accessibilityLabel("Assignment filter")
    }

    private func agendaDays(_ days: [StudyAssignmentDateGroup], isPast: Bool = false) -> some View {
        ForEach(days) { day in
            VStack(alignment: .leading, spacing: 6) {
                Text(day.title).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPast ? Color.orange : Color.secondary).padding(.top, 7)
                ForEach(day.items) { item in agendaRow(item) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "checklist").font(.system(size: 24, weight: .light)).foregroundStyle(Color.accentColor)
            Text(
                !query.isEmpty
                    ? "No matching assignments."
                    : filter == .hidden
                        ? "No hidden assignments."
                        : filter == .handedIn || filter == .graded
                            ? (filter == .graded ? "No graded assignments yet." : "No submissions awaiting a grade.")
                            : filter == .all
                                ? "No assignments yet."
                                : filter == .archive ? "Nothing in the archive." : "No outstanding deadlines."
            )
            .font(.system(size: 19, design: .serif))
            Text(
                !query.isEmpty
                    ? "Try an assignment title or course code."
                    : filter == .hidden
                        ? "Assignments you hide remain available here and in All assignments."
                        : filter == .handedIn || filter == .graded || filter == .all
                            ? "Sync Canvas to refresh submission status."
                            : filter == .archive
                                ? "Undated and completed assignments will be kept here."
                                : "Use Handed in for submitted work, or All assignments to see everything."
            )
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 20)
    }

    private func agendaRow(_ item: StudyAssignment) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Button {
                    workspace.openAssignment(item.material, courseID: item.course.id)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.material.title).font(.system(size: 12, weight: .medium)).lineLimit(2).padding(
                            .trailing, 24)
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(item.course.displayCode.isEmpty ? item.course.displayName : item.course.displayCode)
                                .foregroundStyle(Color.accentColor).lineLimit(1)
                            Spacer(minLength: 0)
                            if let date = item.dueDate {
                                Text(date.formatted(.dateTime.hour().minute())).monospacedDigit().foregroundStyle(
                                    .secondary
                                ).fixedSize()
                            } else {
                                Text(item.details == nil ? "Deadline not synced" : "No due date").foregroundStyle(
                                    .tertiary
                                ).fixedSize()
                            }
                        }.font(.system(size: 10))
                        HStack(spacing: 6) {
                            StudySubmissionBadge(status: item.details?.status, grade: item.details?.gradeLabel,
                                feedback: item.details?.hasFeedback == true, corrected: item.details?.progressOverride != nil)
                            if item.isHidden {
                                Label("Hidden", systemImage: "eye.slash")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        if let availability = item.details?.availability(at: .now) {
                            Text(availability).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.scholiaButtonStyle(.plain)
                    .help("Read \(item.material.title)").accessibilityLabel("Read assignment: \(item.material.title)")
                if let url = URL(string: item.material.sourceURL), url.scheme == "https", url.user == nil,
                    url.password == nil
                {
                    Link(destination: url) { Image(systemName: "arrow.up.right").font(.system(size: 10)).padding(10) }
                        .scholiaButtonStyle(.plain)
                        .help("Open \(item.material.title) in Canvas")
                }
            }
            HStack {
            StudyAssignmentStatusMenu(workspace: workspace, courseID: item.course.id, assignmentID: item.material.id,
                progress: item.course.assignmentProgress?[item.material.id])
                .disabled(item.details == nil)
            Spacer(minLength: 8)
            Button {
                workspace.setAssignmentHidden(item.material.id, courseID: item.course.id, hidden: !item.isHidden)
            } label: {
                Label(
                    item.isHidden ? "Unhide" : "Hide",
                    systemImage: item.isHidden ? "eye" : "eye.slash"
                )
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }.scholiaButtonStyle(.plain)
                .help(
                    item.isHidden
                        ? "Show this assignment in other lists"
                        : "Hide this assignment. It remains in All assignments and Hidden.")
            }.padding(.horizontal, 10).padding(.bottom, 9)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .background(
                scheme == .dark ? Color.white.opacity(0.025) : .white.opacity(0.8),
                in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StudyAssignmentsView: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    let courses: [StudyCourse]
    var query = ""
    var showCourse = true
    var dashboard = false
    @State private var includeCompleted = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let assignments = StudyAssignment.list(
                courses: courses, query: query, includeCompleted: !dashboard && includeCompleted, dueOnly: dashboard,
                includeHidden: !dashboard && includeCompleted, includeNonSubmission: !dashboard && includeCompleted)
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        heading(assignments.count)
                        Spacer()
                        if !dashboard { filter }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        heading(assignments.count)
                        if !dashboard { filter }
                    }
                }
                Text(
                    dashboard
                        ? "Upcoming and overdue assignments from all workspaces, earliest deadline first. Times in \(TimeZone.current.identifier)."
                        : "Exercises and assignments, earliest deadline first. Times in \(TimeZone.current.identifier)."
                )
                .font(.system(size: 11)).foregroundStyle(.secondary)
                if courses.contains(where: {
                    $0.canvasID != nil
                        && ($0.catalogUpdatedAt == nil
                            || !$0.materials.filter { $0.kind == .assignments && $0.assignment == nil }.isEmpty
                            || !($0.catalogWarnings ?? []).isEmpty)
                }) {
                    Text("Some deadlines may be missing or out of date. Check Canvas for changes to refresh the list.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if assignments.isEmpty {
                    Text(
                        query.isEmpty
                            ? dashboard
                                ? "No upcoming or overdue assignments in your indexed workspaces."
                                : "No \(includeCompleted ? "assignments" : "assignments to submit") in the indexed materials for these courses."
                            : "No matching assignments."
                    )
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 18)
                } else {
                    LazyVStack(spacing: 9) {
                        ForEach(assignments) { assignment in row(assignment, now: context.date) }
                    }
                }
            }
        }
    }

    private func heading(_ count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(dashboard ? "Due across your workspaces" : "Assignment due dates").font(
                .system(size: 23, design: .serif))
            Text("\(count)").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
    private var filter: some View {
        Picker("Assignments", selection: $includeCompleted) {
            Text("To submit").tag(false)
            Text("All assignments").tag(true)
        }.labelsHidden().pickerStyle(.segmented).scholiaPointingCursor().frame(width: 215).accessibilityLabel(
            "Assignments")
    }
    private func row(_ item: StudyAssignment, now: Date) -> some View {
        let status = item.details?.statusLabel(at: now) ?? "Check Canvas"
        let overdue = status == "Overdue" || status == "Missing"
        return VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.material.title).font(.system(size: 14, weight: .medium)).fixedSize(
                        horizontal: false, vertical: true)
                    if showCourse {
                        Button(item.course.code.isEmpty ? item.course.displayName : item.course.code) {
                            workspace.selectCourse(item.course.id)
                        }
                        .scholiaButtonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
                    }
                    if let date = item.dueDate {
                        Text("Due \(date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 12))
                    } else {
                        Text(
                            item.details == nil
                                ? "Refresh to load due date"
                                : item.details?.dueAt != nil ? "Due date unavailable" : "No due date"
                        ).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 5) {
                    StudySubmissionBadge(status: item.details?.status, grade: item.details?.gradeLabel,
                                feedback: item.details?.hasFeedback == true, corrected: item.details?.progressOverride != nil)
                    if item.isHidden {
                        Label("Hidden", systemImage: "eye.slash")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if overdue { Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.orange) }
                }
            }
            HStack(spacing: 12) {
                if let availability = item.details?.availability(at: now) {
                    Text(availability).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(item.isHidden ? "Unhide" : "Hide") {
                    workspace.setAssignmentHidden(item.material.id, courseID: item.course.id, hidden: !item.isHidden)
                }.help(
                    item.isHidden
                        ? "Show this assignment in other lists"
                        : "Hide this assignment. It remains in All assignments and Hidden.")
                Button("Read assignment") {
                    workspace.openAssignment(item.material, courseID: item.course.id)
                }
                if let url = URL(string: item.material.sourceURL), url.scheme == "https" {
                    Link("Open Canvas ↗", destination: url)
                }
                StudyAssignmentStatusMenu(workspace: workspace, courseID: item.course.id, assignmentID: item.material.id,
                    progress: item.course.assignmentProgress?[item.material.id])
                    .disabled(item.details == nil)
            }.font(.system(size: 11)).controlSize(.small)
        }.padding(16).background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    }
}
