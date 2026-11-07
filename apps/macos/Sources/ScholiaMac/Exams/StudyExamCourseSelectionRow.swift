import SwiftUI

struct StudyExamCourseSelectionRow: View {
    let exams: [StudyExam]
    let selectExam: (StudyExam, Bool) -> Void
    let selectCourse: (Bool) -> Void
    @State private var expanded: Bool

    init(exams: [StudyExam], selectExam: @escaping (StudyExam, Bool) -> Void, selectCourse: @escaping (Bool) -> Void) {
        self.exams = exams.sorted(by: StudyExamPlanner.chronological)
        self.selectExam = selectExam
        self.selectCourse = selectCourse
        let count = exams.filter(\.selected).count
        _expanded = State(initialValue: count > 0 && count < exams.count)
    }

    private var selectedCount: Int { exams.filter(\.selected).count }

    var body: some View {
        if let course = exams.first {
            Group {
                if exams.count > 1 {
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Button("Select all") { selectCourse(true) }
                                    .disabled(selectedCount == exams.count)
                                    .accessibilityLabel("Select all exams for \(course.courseCode.isEmpty ? course.courseName : course.courseCode)")
                                Button("Clear") { selectCourse(false) }
                                    .disabled(selectedCount == 0)
                                    .accessibilityLabel("Clear exam selection for \(course.courseCode.isEmpty ? course.courseName : course.courseCode)")
                            }.controlSize(.small)
                            ForEach(exams) { exam in
                                examToggle(exam)
                            }
                        }.padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        courseLabel(course)
                    }
                    .accessibilityIdentifier("exam-course-expand-\(course.courseKey)")
                } else {
                    Toggle(isOn: selection(course)) {
                        VStack(alignment: .leading, spacing: 5) {
                            courseLabel(course)
                            Text("\(course.component) · \(timing(course))")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }.toggleStyle(.checkbox)
                        .accessibilityLabel("Take \(course.title), \(timing(course))")
                        .accessibilityIdentifier("exam-course-take-\(course.id)")
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func courseLabel(_ course: StudyExam) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(course.courseCode.isEmpty ? course.courseName : course.courseCode)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                Text("\(selectedCount) of \(exams.count) selected")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if !course.courseCode.isEmpty && !course.courseName.isEmpty {
                Text(course.courseName).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func examToggle(_ exam: StudyExam) -> some View {
        Toggle(isOn: selection(exam)) {
            VStack(alignment: .leading, spacing: 3) {
                Text(exam.component).font(.system(size: 12, weight: .medium))
                Text(timing(exam)).font(.system(size: 10)).foregroundStyle(.secondary)
                if exam.flexible {
                    Text("Flexible timing · arrange with professor")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }.toggleStyle(.checkbox)
            .accessibilityLabel("Take \(exam.title), \(timing(exam))")
            .accessibilityIdentifier("exam-course-take-\(exam.id)")
    }

    private func selection(_ exam: StudyExam) -> Binding<Bool> {
        Binding(get: { exam.selected }, set: { selectExam(exam, $0) })
    }

    private func timing(_ exam: StudyExam) -> String {
        let date = formatted(exam.date)
        let start = exam.startTime.isEmpty ? "Time TBC" : exam.startTime
        let end = exam.endTime.isEmpty ? "" : "–\(exam.endTime)"
        return "\(date) · \(start)\(end)" + (exam.endDate.isEmpty ? "" : " · ends \(formatted(exam.endDate))")
    }

    private func formatted(_ date: String) -> String {
        guard let date = StudyExamPlanner.day(date) else { return "Date to confirm" }
        return Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = StudyExamPlanner.calendar.timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()
}
