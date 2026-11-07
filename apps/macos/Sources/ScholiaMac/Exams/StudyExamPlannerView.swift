import SwiftUI

struct StudyExamPlannerView: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    var onClose: () -> Void = {}
    var startAdding = false
    var initialSearch = ""
    @State private var exams: [StudyExam] = []
    @State private var baseline: [StudyExam] = []
    @State private var pasted = ""
    @State private var importing = false
    @State private var signingIn = false
    @State private var resultsPresented = false
    @State private var notice = ""
    @State private var error = ""
    @State private var loaded = false
    @State private var grouping: [String: String] = [:]
    @State private var byCourse = false
    @State private var query = ""
    @State private var adding = false

    @State private var analysis = StudyExamPlanAnalysis()
    @State private var validation = StudyExamValidationCache()
    private var conflicts: [StudyExamCollision] { analysis.conflicts }
    private var visibleExams: [StudyExam] { StudyExamSearch.filter(exams, query: query) }
    private var courseCodes: [String] { Array(Set(visibleExams.map { grouping[$0.id] ?? $0.courseKey })).sorted() }
    private var selectedCount: Int { exams.filter(\.selected).count }
    private var dirty: Bool { exams != baseline }
    private var valid: Bool { validation.valid }
    private var summary: String {
        if !valid { return "Correct the highlighted fields before checking collisions." }
        if selectedCount == 0 { return "Select the exams you intend to take." }
        let overlaps = conflicts.filter { !$0.possible }.count
        let uncertain = conflicts.filter(\.possible).count
        if overlaps > 0 { return "\(overlaps) collision\(overlaps == 1 ? "" : "s") in your selected exams\(uncertain > 0 ? " · \(uncertain) possible" : "")" }
        if uncertain > 0 { return "\(uncertain) possible collision\(uncertain == 1 ? "" : "s") · add missing dates and times" }
        if exams.contains(where: { $0.selected && $0.needsTiming }) {
            return "No confirmed collisions · add missing dates and times to complete the check"
        }
        if exams.contains(where: { $0.selected && $0.flexible }) { return "No fixed-time collisions · arrange flexible exams with your professor" }
        return selectedCount == 1 ? "One exam selected · no collisions" : "Your selected exams do not collide"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Exam planner").font(.system(size: 29, design: .serif))
                    Text("Exams in date order. Choose what you intend to take.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Studentweb results…") { resultsPresented = true }
                Button { signingIn = true } label: { Label("Sign in to Studentweb", systemImage: "lock.shield") }
                Button { importing.toggle() } label: { Label("Paste details", systemImage: "doc.on.clipboard") }
                Button { adding = true } label: { Label("Add exam", systemImage: "plus") }
                    .accessibilityIdentifier("exam-add-picker")
            }
            if importing { importPanel }
            Picker("Show exams", selection: $byCourse) {
                Text("Date order").tag(false)
                Text("By course").tag(true)
            }.pickerStyle(.segmented).frame(width: 240)
            HStack {
                StudyExamSearchField(text: $query)
                Text("\(visibleExams.count) of \(exams.count) exams").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Label(summary, systemImage: conflicts.isEmpty ? (selectedCount == 0 ? "calendar" : "checkmark.circle") : "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(conflicts.contains(where: { !$0.possible }) ? Color.red : conflicts.isEmpty ? Color.accentColor : Color.orange)
                Text("\(selectedCount) of \(exams.count) selected · Europe/Oslo · only selected exams are compared. Back-to-back exams do not overlap.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            if !notice.isEmpty { Text(notice).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if exams.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "calendar.badge.plus").font(.system(size: 28)).foregroundStyle(Color.accentColor)
                            Text("Give your exam season a little room.").font(.system(size: 22, design: .serif))
                            Text("Sign in to Studentweb to extract your exam dates, paste copied details, or add an exam manually. Review and edit every date before saving.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !exams.isEmpty && visibleExams.isEmpty {
                        Text("No exams match your search. Clear the search or add another exam.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).padding(24)
                    }
                    if byCourse {
                        ForEach(courseCodes, id: \.self) { code in courseGroup(code) }
                    } else {
                        ForEach(visibleExams.sorted(by: StudyExamPlanner.chronological)) { exam in
                            if let index = exams.firstIndex(where: { $0.id == exam.id }) {
                                examRow(index).padding(15)
                                    .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
                            }
                        }
                    }
                    if !conflicts.isEmpty { conflictPanel }
                }.padding(.trailing, 4)
            }.frame(maxHeight: .infinity)
            Divider()
            HStack {
                Text("Planning only. Verify dates in Studentweb; this does not register you for exams.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Reload saved plan") {
                    baseline = workspace.library.examPlan ?? []; exams = baseline
                    pasted = ""; notice = ""; error = ""; regroup()
                }
                Button(dirty ? "Discard changes" : "Close") { onClose() }.keyboardShortcut(.cancelAction)
                Button("Save plan", action: save).keyboardShortcut(.defaultAction).disabled(!dirty || !valid)
            }
        }.padding(25).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                guard !loaded else { return }
                baseline = workspace.library.examPlan ?? []
                exams = baseline
                analysis = StudyExamPlanAnalysis(exams)
                validation.update(exams)
                regroup()
                loaded = true
                query = initialSearch
                adding = startAdding
                openRequestedImport()
            }
            .onChange(of: exams) { _, updated in
                analysis = StudyExamPlanAnalysis(updated)
                validation.update(updated)
            }
            .onChange(of: workspace.studentwebImportRequested) { _, _ in openRequestedImport() }
            .sheet(isPresented: $signingIn) { StudentwebImportView(onImport: addImport) }
            .sheet(isPresented: $resultsPresented) { StudyCourseCompletionsView(workspace: workspace, checkOnOpen: true) }
            .sheet(isPresented: $adding) { StudyExamCoursePicker(courses: workspace.library.courses, exams: exams,
                onAdd: { addExam(course: $0) }, initialQuery: query) }
            .task { await workspace.loadCourseCompletions() }
    }

    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Copy the exam rows from Studentweb’s opening page (Kommende hendelser) and paste them here.")
                .font(.system(size: 12, weight: .medium))
            Text("Your Studentweb login stays in your browser. Scholia reads this text locally and saves only the exam fields you review below. Leave out personal details.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            TextEditor(text: $pasted).font(.system(size: 11, design: .monospaced)).frame(height: 88)
                .padding(4).overlay(RoundedRectangle(cornerRadius: 5).stroke(.primary.opacity(0.15)))
                .accessibilityLabel("Studentweb exam details")
            HStack {
                Text("Example: TDT4100 · Final exam · 15.12.2026 · 09:00–13:00")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Preview exams", action: previewImport).disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(14).background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private func courseGroup(_ code: String) -> some View {
        let members = visibleExams.filter { (grouping[$0.id] ?? $0.courseKey) == code }.sorted(by: StudyExamPlanner.chronological)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(members.first?.courseCode.isEmpty == false ? members.first!.courseCode : members.first?.courseName.isEmpty == false ? members.first!.courseName : "New course").font(.system(size: 17, weight: .semibold, design: .serif))
                if let name = members.first?.courseName, !name.isEmpty { Text(name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                Button(query.isEmpty ? "Select course" : "Select matches") { setCourse(code, selected: true) }.controlSize(.small)
                Button("Clear selection") { setCourse(code, selected: false) }.controlSize(.small)
                Button { addExam(course: members.first) } label: { Label("Add component", systemImage: "plus") }.controlSize(.small)
            }
            ForEach(members) { exam in
                if let index = exams.firstIndex(where: { $0.id == exam.id }) {
                    examRow(index)
                }
            }
        }.padding(15).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
    }

    private func examRow(_ index: Int) -> some View {
        let exam = exams[index]
        let matches = analysis.conflictsByID[exam.id] ?? []
        return VStack(alignment: .leading, spacing: 9) {
            if workspace.coursePassed(exam.courseCode) == true {
                Label("Already passed · select only if you intend to retake it", systemImage: "checkmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Toggle("Intend to take", isOn: $exams[index].selected).toggleStyle(.checkbox).font(.system(size: 11)).frame(width: 105, alignment: .leading)
                TextField("Course code", text: $exams[index].courseCode).frame(width: 105).accessibilityLabel("Course code").onSubmit { regroup() }
                TextField("Course name (optional)", text: $exams[index].courseName).frame(maxWidth: .infinity).accessibilityLabel("Course name")
                TextField("Exam component", text: $exams[index].component).frame(width: 145).accessibilityLabel("Exam component")
                    .onChange(of: exams[index].component) { old, new in
                        if !StudyExam.isOralComponent(old), StudyExam.isOralComponent(new) { exams[index].flexible = true }
                    }
                Picker("Type", selection: $exams[index].kind) {
                    Text("Midterm").tag("midterm")
                    Text("Final").tag("final")
                    Text("Other").tag("other")
                }.labelsHidden().frame(width: 93)
                Button { exams.remove(at: index) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Remove \(exam.title)").accessibilityLabel("Remove \(exam.title)")
            }
            HStack(spacing: 10) {
                dateField("Date", value: $exams[index].date)
                labeledField("Start", placeholder: "HH:mm", text: $exams[index].startTime).frame(width: 67)
                labeledField("End", placeholder: "HH:mm", text: $exams[index].endTime).frame(width: 67)
                dateField("End date (if different)", value: $exams[index].endDate)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(rowStatus(exam, matches: matches)).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(matches.contains(where: { !$0.possible }) ? Color.red : matches.isEmpty ? Color.secondary : Color.orange)
                    Text(exam.source == "studentweb" ? "From Studentweb · review details" : "Manually added")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Toggle("Flexible timing · agree with professor", isOn: $exams[index].flexible)
                .toggleStyle(.checkbox).font(.system(size: 11))
                .help("Keeps this date for reference and excludes this exam from overlap checks. Agree the actual timing with your professor.")
            if exam.isOral {
                Text("Oral exams default to flexible timing. Turn this off if the timing is fixed.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if exam.flexible {
                Text("Overlap override is on. The date is kept for reference; arrange the actual timing with your professor.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let validation = validationMessage(exam) {
                Text(validation).font(.system(size: 10)).foregroundStyle(.red)
            }
        }.textFieldStyle(.roundedBorder).padding(11)
            .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func dateField(_ title: String, value: Binding<String>) -> some View {
        StudyExamDateField(title: title, value: value)
    }

    private func labeledField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).accessibilityLabel(title + " time")
        }
    }

    private var conflictPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check these pairs").font(.system(size: 16, design: .serif))
            ForEach(Array(conflicts.prefix(30))) { conflict in
                if let a = exams.first(where: { $0.id == conflict.first }), let b = exams.first(where: { $0.id == conflict.second }) {
                    Label("\(a.title) ↔ \(b.title): \(conflict.possible ? "possible collision; add missing dates or times" : "times overlap")",
                        systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(conflict.possible ? Color.orange : Color.red)
                }
            }
            if conflicts.count > 30 { Text("And \(conflicts.count - 30) more pairs.").font(.caption).foregroundStyle(.secondary) }
        }.padding(13)
    }

    private func rowStatus(_ exam: StudyExam, matches: [StudyExamCollision]) -> String {
        if !exam.selected { return "Not selected" }
        if validationMessage(exam) != nil { return "Check date / time" }
        if exam.flexible { return "Flexible · arrange with professor" }
        if matches.contains(where: { !$0.possible }) { return "Collision" }
        if !matches.isEmpty { return "Possible collision" }
        if exam.date.isEmpty { return "Date missing" }
        if exam.startTime.isEmpty || exam.endTime.isEmpty { return "Times incomplete" }
        return "No collision"
    }

    private func validationMessage(_ exam: StudyExam) -> String? {
        validation.errors[exam.id]
    }

    private func setCourse(_ code: String, selected: Bool) {
        for index in exams.indices where (grouping[exams[index].id] ?? exams[index].courseKey) == code
            && StudyExamSearch.matches(exams[index], query: query) { exams[index].selected = selected }
    }

    private func regroup() {
        grouping = Dictionary(uniqueKeysWithValues: exams.map { ($0.id, $0.courseKey.isEmpty ? "new-\($0.id)" : $0.courseKey) })
    }

    private func addExam(course: StudyExam? = nil) {
        guard exams.count < StudyExamPlanner.maximumExams else { error = "An exam plan can contain at most 500 exams."; return }
        let existing = course.map { value in exams.filter { $0.courseKey == value.courseKey } } ?? []
        let nextKind = existing.contains(where: { $0.kind == "final" }) ? "midterm" : "final"
        exams.append(StudyExam(courseCode: course?.courseCode ?? workspace.course?.displayCode ?? "",
            courseName: course?.courseName ?? workspace.course?.displayName ?? "",
            component: nextKind == "midterm" ? "Midterm" : "Final exam", kind: nextKind, selected: true))
        query = ""
        regroup()
    }

    private func previewImport() {
        addImport(StudyExamPlanner.parseStudentweb(pasted))
    }

    private func openRequestedImport() {
        if workspace.studentwebImportRequested {
            workspace.studentwebImportRequested = false
            signingIn = true
        }
    }

    private func addImport(_ parsed: StudyExamImport) {
        do {
            let oldCount = exams.count
            exams = try StudyExamPlanner.importing(parsed, into: exams)
            regroup()
            if parsed.replacesStudentweb {
                notice = "Refreshed from \(parsed.exams.count) exams on Studentweb’s opening page. Previous Studentweb entries were replaced; manual entries were kept. "
            } else {
                notice = "\(exams.count - oldCount) exams added to your preview. Identical entries were skipped. "
            }
            notice += parsed.warnings.joined(separator: " ")
            if !parsed.exams.isEmpty { pasted = ""; importing = false }
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        do {
            try workspace.replaceExamPlan(exams, base: baseline)
            onClose()
        } catch { self.error = error.localizedDescription }
    }
}

private struct StudyExamDateField: View {
    let title: String
    @Binding var value: String
    @State private var choosing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                TextField("YYYY-MM-DD", text: $value).frame(width: 101).accessibilityLabel(title)
                Button { choosing = true } label: { Image(systemName: "calendar") }
                    .buttonStyle(.borderless).help("Choose " + title.lowercased())
                    .accessibilityLabel("Choose " + title.lowercased())
                    .popover(isPresented: $choosing) {
                        VStack(spacing: 12) {
                            DatePicker(title, selection: Binding(get: { StudyExamPlanner.day(value) ?? Date() },
                                set: { value = StudyExamPlanner.dayString($0) }), displayedComponents: .date)
                                .datePickerStyle(.graphical).environment(\.timeZone, StudyExamPlanner.calendar.timeZone)
                            HStack {
                                Button("Clear date") { value = ""; choosing = false }
                                Spacer()
                                Button("Done") {
                                    if value.isEmpty { value = StudyExamPlanner.dayString(Date()) }
                                    choosing = false
                                }
                            }
                        }.padding(15).frame(width: 285)
                    }
            }
        }
    }
}
