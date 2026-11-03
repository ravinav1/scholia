import SwiftUI

enum StudyExamSearch {
    static func matches(_ value: String, query: String) -> Bool {
        let folded = normalize(value)
        return normalize(query).split(whereSeparator: \.isWhitespace).allSatisfy { folded.contains($0) }
    }

    static func matches(_ exam: StudyExam, query: String) -> Bool {
        matches([exam.courseCode, exam.courseKey, exam.courseName, exam.component, exam.kind, exam.date,
            exam.endDate, exam.startTime, exam.endTime].joined(separator: " "), query: query)
    }

    static func filter(_ exams: [StudyExam], query: String) -> [StudyExam] {
        exams.filter { matches($0, query: query) }
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "æ", with: "ae").replacingOccurrences(of: "ø", with: "o")
            .replacingOccurrences(of: "-", with: " ")
    }

    static func courses(library: [StudyCourse], catalog: [StudyPlanCatalog.Course]) -> [StudyExamCourseOption] {
        var result: [String: StudyExamCourseOption] = [:]
        for course in library {
            let option = StudyExamCourseOption(code: course.displayCode, name: course.displayName, inLibrary: true)
            if result[option.id] == nil { result[option.id] = option }
        }
        for course in catalog where course.kind == "course" {
            let option = StudyExamCourseOption(code: course.code, name: course.name, inLibrary: false)
            if result[option.id] == nil { result[option.id] = option }
        }
        return result.values.sorted {
            if $0.inLibrary != $1.inLibrary { return $0.inLibrary }
            return ($0.code, $0.name) < ($1.code, $1.name)
        }
    }
}

struct StudyExamCourseOption: Identifiable, Sendable {
    let code: String
    let name: String
    let inLibrary: Bool
    var id: String { StudyExam(courseCode: code, courseName: name).courseKey }
    var searchText: String { code + " " + id + " " + name }
}

struct StudyExamSearchField: View {
    @Binding var text: String
    var prompt = "Search course, exam component, or date"
    var identifier = "exam-plan-search"
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
                .accessibilityLabel(prompt).accessibilityIdentifier(identifier)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
            }
        }.padding(9).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StudyExamCoursePicker: View {
    let courses: [StudyCourse]
    let exams: [StudyExam]
    var onAdd: (StudyExam?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var options: [StudyExamCourseOption] = []
    @State private var loading = true
    @State private var catalogNotice = ""
    private var matches: [StudyExamCourseOption] { options.filter { StudyExamSearch.matches($0.searchText, query: query) } }

    init(courses: [StudyCourse], exams: [StudyExam], onAdd: @escaping (StudyExam?) -> Void, initialQuery: String = "") {
        self.courses = courses; self.exams = exams; self.onAdd = onAdd
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Add an exam").font(.system(size: 25, design: .serif))
            Text("Find a course in your library or the bundled study plans. Add its exam, then review the date and time before saving your plan.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            StudyExamSearchField(text: $query, prompt: "Search courses by code or name", identifier: "exam-add-search")
            if loading { ProgressView("Loading courses…").controlSize(.small) }
            if !catalogNotice.isEmpty { Text(catalogNotice).font(.caption).foregroundStyle(.secondary) }
            Text("\(matches.count) matching course\(matches.count == 1 ? "" : "s")\(matches.count > 80 ? " · showing the first 80; refine your search" : "")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if !loading && matches.isEmpty {
                        Text("No matching courses. Try another code or name, or add an exam manually.")
                            .foregroundStyle(.secondary).padding(.vertical, 25)
                    }
                    ForEach(Array(matches.prefix(80))) { option in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.code.isEmpty ? option.name : option.code).font(.system(size: 13, weight: .semibold))
                                if !option.code.isEmpty { Text(option.name).font(.system(size: 12)) }
                                let count = exams.filter { $0.courseKey == option.id }.count
                                Text(count > 0 ? "\(count) exam component\(count == 1 ? "" : "s") already in this plan"
                                    : option.inLibrary ? "In your library" : "Study-plan catalog · date to confirm")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add exam") {
                                onAdd(StudyExam(courseCode: option.code, courseName: option.name)); dismiss()
                            }.accessibilityLabel("Add exam for \(option.code.isEmpty ? option.name : option.code)")
                                .accessibilityIdentifier("exam-add-\(option.id)")
                        }.padding(12).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(maxHeight: .infinity)
            Divider()
            HStack {
                Button("Add manually") { onAdd(nil); dismiss() }.accessibilityIdentifier("exam-add-manual")
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 610, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))
            .task {
                options = StudyExamSearch.courses(library: courses, catalog: [])
                let result = await Task.detached(priority: .userInitiated) { StudyPlanIndex.bundled }.value
                guard !Task.isCancelled else { return }
                switch result {
                case .success(let index): options = StudyExamSearch.courses(library: courses, catalog: Array(index.catalog.courses.values))
                case .failure: catalogNotice = "The study-plan catalog is unavailable. Your library and manual entry are still available."
                }
                loading = false
            }
    }
}
