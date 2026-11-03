import SwiftUI

/// A reading-first schedule in the workspace. Date editing is an inline subview.
struct StudyExamScheduleView: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    @Environment(\.colorScheme) private var scheme
    @State private var editing = false
    @State private var addingExam = false
    @State private var query = ""
    @State private var resultsPresented = false
    @State private var message = ""
    @State private var undo: [StudyExam]?
    @State private var undoBase: [StudyExam]?
    @State private var selecting = false
    @State private var showingPast = false
    @State private var today = StudyExamPlanner.dayString(Date())
    @State private var past: [StudyExam] = []
    @State private var upcoming: [StudyExam] = []
    @State private var focusCourses: [StudyCourse] = []
    @State private var visibleChoiceCount = 12
    @State private var analysis = StudyExamPlanAnalysis()
    @State private var ready: Set<UUID> = []
    private var exams: [StudyExam] { workspace.library.examPlan ?? [] }
    private var selected: [StudyExam] { analysis.selected }
    private var conflicts: [StudyExamCollision] { analysis.conflicts }
    private var choices: [StudyExamCollision] { analysis.choices }
    private var unknown: Int { analysis.unknown }
    private var flexibleCount: Int { analysis.flexibleCount }
    private var groups: [String: [StudyExam]] { analysis.groups }
    private var visibleSelected: [StudyExam] { StudyExamSearch.filter(selected, query: query) }
    private var visibleUpcoming: [StudyExam] { StudyExamSearch.filter(upcoming, query: query) }
    private var visiblePast: [StudyExam] { StudyExamSearch.filter(past, query: query) }
    private var visibleChoices: [StudyExamCollision] { choices.filter { pair in
        [analysis.byID[pair.first], analysis.byID[pair.second]].compactMap { $0 }.contains { StudyExamSearch.matches($0, query: query) }
    } }

    var body: some View {
        Group {
            if editing {
                StudyExamPlannerView(workspace: workspace, onClose: { editing = false; addingExam = false }, startAdding: addingExam, initialSearch: query)
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 23) {
                            header
                            HStack {
                                StudyExamSearchField(text: $query, identifier: "exam-schedule-search")
                                Text("\(StudyExamSearch.filter(exams, query: query).count) of \(exams.count) exams")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            if !visiblePast.isEmpty { pastExams }
                            overview
                            StudyExamRecommendationView(workspace: workspace, apply: { save($0) })
                            if !message.isEmpty { Text(message).font(.system(size: 12)).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
                            if let undo, undoBase == exams {
                                Button("Undo last change") { save(undo, remember: false) }.controlSize(.small)
                                    .accessibilityIdentifier("exam-choice-undo")
                            }
                            if geometry.size.width >= 1080 {
                                HStack(alignment: .top, spacing: 35) {
                                    timeline.frame(maxWidth: .infinity)
                                    decisions.frame(width: 410)
                                }
                            } else {
                                timeline
                                Divider()
                                decisions
                            }
                            Text("Europe/Oslo · Your personal plan. Verify final dates in Studentweb; choices here do not change exam registrations.")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(30).frame(maxWidth: 1380, alignment: .leading).frame(maxWidth: .infinity)
                    }
                }
            }
        }.background(StudyPalette.paper(scheme == .dark))
            .task { await workspace.loadCourseCompletions() }
            .sheet(isPresented: $resultsPresented) { StudyCourseCompletionsView(workspace: workspace, checkOnOpen: true) }
            .onAppear {
                refreshAnalysis()
                if workspace.studentwebImportRequested { editing = true }
                if workspace.library.courses.contains(where: { ready.contains($0.id) && !$0.isFavorite }) { save(exams, remember: false) }
            }
            .onChange(of: exams) { _, _ in refreshAnalysis() }
            .onChange(of: workspace.library.courses.map { $0.id.uuidString + $0.displayCode + $0.name }) { _, _ in
                refreshAnalysis()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in refreshAnalysis() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if today != StudyExamPlanner.dayString(Date()) { refreshAnalysis() }
            }
            .onChange(of: workspace.studentwebImportRequested) { _, requested in if requested { editing = true } }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR SEMESTER, AT A GLANCE").font(.system(size: 9, weight: .medium)).tracking(1.1).foregroundStyle(Color.accentColor)
                Text("Exam dates").font(.system(size: 36, design: .serif))
                Text("A little space to see what fits.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Studentweb results…") { resultsPresented = true }
            Button(exams.isEmpty ? "Add exam dates" : "Manage dates") { editing = true }
            Button { addingExam = true; editing = true } label: { Label("Add exam", systemImage: "plus") }
                .accessibilityIdentifier("exam-schedule-add")
        }
    }
    private var pastExams: some View {
        DisclosureGroup("Past exams (\(visiblePast.count))", isExpanded: Binding(get: { showingPast || !query.isEmpty }, set: { showingPast = $0 })) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(visiblePast) { exam in
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text((exam.courseCode.isEmpty ? exam.courseName : exam.courseCode)
                                + (exam.courseCode.isEmpty || exam.courseName.isEmpty ? "" : " · " + exam.courseName))
                                .font(.system(size: 12, weight: .medium))
                            Text("\(exam.component) · \(formatted(exam.date)) · \(time(exam))")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            if exam.flexible {
                                Text("Flexible timing · date kept for reference").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(exam.selected ? "Selected" : "Set aside").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.vertical, 5)
                }
            }.padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 12, weight: .medium)).padding(15)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("exam-past")
    }
    private var overview: some View {
        HStack(spacing: 35) {
            metric("\(selected.count)", "upcoming exams selected")
            metric(conflicts.isEmpty ? "✓" : "\(conflicts.count)", conflicts.isEmpty ? (flexibleCount > 0 ? "no fixed-time overlaps" : "no overlaps found") : "overlaps to review", warning: !conflicts.isEmpty)
            metric("\(unknown)", "dates / times to check")
            if flexibleCount > 0 { metric("\(flexibleCount)", "flexible · to arrange") }
            Spacer()
        }.padding(.vertical, 19).overlay(alignment: .top) { Divider() }.overlay(alignment: .bottom) { Divider() }
    }
    private func metric(_ value: String, _ title: String, warning: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(value).font(.system(size: 31, design: .serif)).foregroundStyle(warning ? Color.orange : Color.accentColor)
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: 100, alignment: .leading)
        }
    }
    private var timeline: some View {
        let matchingDays = Dictionary(grouping: visibleSelected, by: \.date)
        let days = matchingDays.keys.sorted { ($0.isEmpty ? "9999" : $0) < ($1.isEmpty ? "9999" : $1) }
        return VStack(alignment: .leading, spacing: 17) {
            Text("Your schedule").font(.system(size: 24, design: .serif))
            if !query.isEmpty && visibleSelected.isEmpty {
                Text("No selected upcoming exams match your search. Check Course selection or clear the search.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if selected.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "calendar").font(.system(size: 27)).foregroundStyle(Color.accentColor)
                    Text(upcoming.isEmpty && !past.isEmpty ? "No upcoming exams." : "Make room for your exams.").font(.system(size: 23, design: .serif))
                    Text(upcoming.isEmpty && !past.isEmpty ? "Your earlier dates are in Past exams above. Add new dates in Manage dates."
                        : exams.isEmpty ? "Add your dates from Studentweb to see your semester in one place." : "Select a course below to see how its dates fit.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(25).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            }
            ForEach(days, id: \.self) { day in
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 4) {
                        Text(day.isEmpty ? "DATE" : formatted(day, "MMM yyyy").uppercased()).font(.system(size: 9)).foregroundStyle(.secondary)
                        Text(day.isEmpty ? "?" : String(day.suffix(2))).font(.system(size: 34, design: .serif)).foregroundStyle(Color.accentColor)
                        Text(day.isEmpty ? "To confirm" : formatted(day, "EEEE")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }.frame(width: 72).padding(.top, 12)
                    VStack(spacing: 9) {
                        ForEach(matchingDays[day] ?? []) { exam in scheduleRow(exam) }
                    }
                }
            }
            if !upcoming.isEmpty {
                DisclosureGroup("Course selection", isExpanded: Binding(get: { selecting || !query.isEmpty }, set: { selecting = $0 })) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Expand a course to choose individual exams. You can take a midterm without its final.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack {
                            Button(query.isEmpty ? (workspace.courseCompletions.isEmpty ? "Select all" : "Select unfinished courses") : "Select matching exams") {
                                selectUpcoming(true)
                            }.disabled(visibleUpcoming.allSatisfy(\.selected))
                            Button(query.isEmpty ? "Clear selection" : "Clear matching selection") {
                                selectUpcoming(false)
                            }.disabled(visibleSelected.isEmpty)
                        }.controlSize(.small)
                        if visibleUpcoming.isEmpty { Text("No upcoming exams match.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(groups.keys.filter { key in (groups[key] ?? []).contains { StudyExamSearch.matches($0, query: query) } }.sorted(), id: \.self) { key in
                            if let code = groups[key]?.first?.courseCode, workspace.coursePassed(code) == true {
                                Label("\(code) · already passed. You can select a retake below.", systemImage: "checkmark.circle")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            StudyExamCourseSelectionRow(exams: groups[key] ?? [], selectExam: setSelected) { chosen in
                                selectUpcoming(chosen, courseKey: key)
                            }
                        }
                    }.padding(.top, 13).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.system(size: 12)).padding(.vertical, 10)
            }
            Text("Only selected exams with fixed timing are compared. Arrange flexible exams with your professor. Missing times remain uncertain. Back-to-back exams may still need travel time.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private func scheduleRow(_ exam: StudyExam) -> some View {
        let matches = analysis.conflictsByID[exam.id] ?? []
        let uncertain = exam.needsTiming
        let color: Color = matches.contains(where: { !$0.possible }) ? .orange : !matches.isEmpty || uncertain ? .secondary : .accentColor
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(exam.courseCode.isEmpty ? exam.courseName : exam.courseCode).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
                Text(exam.courseName.isEmpty ? exam.component : exam.courseName).font(.system(size: 18, design: .serif))
                Text("\(exam.component) · \(time(exam))").font(.system(size: 11)).foregroundStyle(.secondary)
                if exam.flexible {
                    Text("Date kept for reference · arrange with professor").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 7) {
                Text(exam.flexible ? "Flexible timing" : matches.contains(where: { !$0.possible }) ? "Overlaps" : !matches.isEmpty ? "Possible overlap" : uncertain ? "Time / date TBC" : "No overlap")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(color).padding(6).background(color.opacity(0.08), in: Capsule())
                if exam.flexible {
                    Button("Use fixed timing") { setFlexible(exam, false) }.controlSize(.small)
                        .help("Restore overlap checks for \(exam.title)")
                }
            }
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 8) }
    }
    private var decisions: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text(choices.isEmpty ? "Looking good" : "Make a choice").font(.system(size: 24, design: .serif))
            if choices.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: unknown == 0 && !selected.isEmpty ? "checkmark.circle" : "clock").font(.system(size: 28)).foregroundStyle(Color.accentColor)
                    Text(selected.isEmpty ? "Your choices, together." : unknown > 0 ? "A few details to confirm." : flexibleCount > 0 ? "Flexible exams to arrange." : "Room for every selected exam.").font(.system(size: 23, design: .serif))
                    Text(unknown > 0 ? "Add the missing dates or times to complete the conflict check." : flexibleCount > 0 ? "Your fixed exam times fit together. Agree the flexible exams with your professor; their displayed dates are kept for reference." : "Your selected exam times fit together. Keep an eye on the gaps for revision and travel.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            } else {
                Text("Keep one course, remove an exam, or mark its timing as flexible. Flexible pairs disappear once both exams are selected; arrange the flexible exam with your professor.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(Array(visibleChoices.prefix(visibleChoiceCount))) { pair in
                    if let a = analysis.byID[pair.first], let b = analysis.byID[pair.second] {
                        let canTakeBoth = a.flexible || b.flexible
                        let color: Color = canTakeBoth ? .accentColor : .orange
                        VStack(alignment: .leading, spacing: 13) {
                            HStack {
                                Text(canTakeBoth ? "Both exams can be selected" : pair.possible ? "Possible overlap" : "Overlapping exams")
                                Spacer()
                                Text(formatted(a.date))
                            }.font(.system(size: 11, weight: .medium)).foregroundStyle(color)
                            if pair.possible && !canTakeBoth { Text("A time is missing. Check the details before setting a course aside.").font(.system(size: 11)).foregroundStyle(.secondary) }
                            HStack(alignment: .top, spacing: 14) {
                                option(a, dropping: b, canTakeBoth: canTakeBoth)
                                Divider()
                                option(b, dropping: a, canTakeBoth: canTakeBoth)
                            }.fixedSize(horizontal: false, vertical: true)
                        }.padding(16).background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(color.opacity(0.4)))
                    }
                }
            }
            if visibleChoices.count > visibleChoiceCount {
                Button("Show more exam pairs (\(visibleChoices.count - visibleChoiceCount) remaining)") { visibleChoiceCount += 12 }
                    .controlSize(.small)
            }
            if focusCourses.contains(where: { StudyExamSearch.matches($0.displayCode + " " + $0.displayName, query: query) }) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("READY TO FOCUS ON", systemImage: "star.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.accentColor)
                    Text("Selected courses with complete or flexible timing and no fixed-time overlaps are saved to favorites.").font(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(focusCourses.filter { StudyExamSearch.matches($0.displayCode + " " + $0.displayName, query: query) }) { course in
                        Button(course.displayCode.isEmpty ? course.name : course.displayCode) { workspace.selectCourse(course.id) }.controlSize(.small)
                    }
                }.padding(.top, 10)
            }
        }
    }
    private func option(_ keep: StudyExam, dropping drop: StudyExam, canTakeBoth: Bool) -> some View {
        // Preview a choice using the existing conflict graph. Validate only on click.
        let sameCourse = keep.courseKey == drop.courseKey
        let removedIDs = Set(selected.filter { sameCourse ? $0.id == drop.id : $0.courseKey == drop.courseKey }.map(\.id))
        let removed = removedIDs.count
        let remaining = conflicts.filter { !removedIDs.contains($0.first) && !removedIDs.contains($0.second) }.count
        return VStack(alignment: .leading, spacing: 9) {
            Text(keep.courseCode.isEmpty ? keep.courseName : keep.courseCode).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
            Text(keep.courseName.isEmpty ? keep.component : keep.courseName).font(.system(size: 18, design: .serif))
            Text("\(keep.component) · \(formatted(keep.date))\n\(time(keep))").font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            if canTakeBoth {
                Text(keep.flexible ? "Flexible timing · arrange with professor" : "Fixed exam time")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Toggle("Take this exam", isOn: Binding(get: { keep.selected }, set: { chosen in
                    setSelected(keep, chosen)
                })).toggleStyle(.checkbox).controlSize(.small)
                    .accessibilityLabel("Take \(keep.title)")
                    .accessibilityIdentifier("exam-choice-take-\(keep.id)")
            } else {
                Text("Sets aside \(drop.courseCode.isEmpty ? drop.courseName : drop.courseCode) · \(removed) selected exam\(removed == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(remaining == 0 ? "Resolves all current overlaps" : "\(remaining) overlaps still to review").font(.system(size: 10)).foregroundStyle(Color.accentColor)
                Button("Keep \(keep.courseKey == drop.courseKey ? keep.component : keep.courseCode.isEmpty ? keep.courseName : keep.courseCode)") {
                    do { save(try StudyExamPlanner.resolveConflict(exams, keep: keep.id, drop: drop.id)) }
                    catch { message = error.localizedDescription }
                }.controlSize(.small)
            }
            Button(keep.flexible ? "Use fixed timing" : "Mark timing flexible") { setFlexible(keep, !keep.flexible) }.controlSize(.small)
                .help(keep.flexible ? "Restore overlap checks for \(keep.title)" : "Keep both exams and arrange \(keep.title) with your professor")
                .accessibilityIdentifier("exam-choice-flexible-\(keep.id)")
            Button("Remove exam", role: .destructive) {
                save(exams.filter { $0.id != keep.id })
            }.controlSize(.small)
                .help("Remove \(keep.title) from your plan. You can undo this change.")
                .accessibilityLabel("Remove \(keep.title) from exam plan")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func refreshAnalysis() {
        today = StudyExamPlanner.dayString(Date())
        past = exams.filter { StudyExamPlanner.isPast($0, today: today) }
            .sorted { StudyExamPlanner.chronological($1, $0) }
        upcoming = exams.filter { !StudyExamPlanner.isPast($0, today: today) }
        analysis = StudyExamPlanAnalysis(upcoming)
        ready = StudyExamPlanner.favoriteCourseIDs(exams, courses: workspace.library.courses)
        focusCourses = StudyExamPlanner.focusCourses(exams, courses: workspace.library.courses, today: today)
    }
    private func selectUpcoming(_ selected: Bool, courseKey: String? = nil) {
        let ids = Set(upcoming.filter {
            (courseKey == nil || $0.courseKey == courseKey)
                && (courseKey != nil || StudyExamSearch.matches($0, query: query))
                && (!selected || courseKey != nil || workspace.coursePassed($0.courseCode) != true)
        }.map(\.id))
        save(exams.map { value in var exam = value; if ids.contains(exam.id) { exam.selected = selected }; return exam })
    }
    private func setFlexible(_ exam: StudyExam, _ flexible: Bool) {
        do { save(try StudyExamPlanner.setFlexibleTiming(exams, id: exam.id, flexible: flexible)) }
        catch { message = error.localizedDescription }
    }
    private func setSelected(_ exam: StudyExam, _ selected: Bool) {
        do { save(try StudyExamPlanner.setSelected(exams, id: exam.id, selected: selected)) }
        catch { message = error.localizedDescription }
    }
    private func save(_ next: [StudyExam], remember: Bool = true) {
        let previous = exams
        do {
            try workspace.replaceExamPlan(next, base: previous)
            undo = remember ? previous : nil
            undoBase = exams
            message = "Saved. Conflict-free selected courses are favorited."
        } catch { message = error.localizedDescription }
    }
    private func formatted(_ date: String, _ format: String = "d MMM yyyy") -> String {
        guard let value = StudyExamPlanner.day(date) else { return "Date to confirm" }
        let formatter = Self.dateFormatters[format]!
        return formatter.string(from: value)
    }
    private static let dateFormatters: [String: DateFormatter] = Dictionary(uniqueKeysWithValues: ["d MMM yyyy", "MMM yyyy", "EEEE"].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = StudyExamPlanner.calendar.timeZone
        formatter.dateFormat = format
        return (format, formatter)
    })
    private func time(_ exam: StudyExam) -> String {
        let start = exam.startTime.isEmpty ? "Time TBC" : exam.startTime
        let end = exam.endTime.isEmpty ? "" : "–\(exam.endTime)"
        return start + end + (exam.endDate.isEmpty ? "" : " · ends \(formatted(exam.endDate))")
    }
}
