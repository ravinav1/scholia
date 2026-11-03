import Foundation
import CoreFoundation

enum CanvasSubmissionStatus: String, Codable, Sendable {
    case unknown, notSubmitted, submitted, graded, excused
    var isHandedIn: Bool { self == .submitted || self == .graded }
    var isComplete: Bool { isHandedIn || self == .excused }
    var submissionLabel: String {
        switch self {
        case .submitted: "Handed in · awaiting grade"
        case .graded: "Graded"
        case .excused: "Excused"
        case .notSubmitted: "Not handed in"
        case .unknown: "Status not synced"
        }
    }
}

enum StudyAssignmentProgress: String, Codable, CaseIterable, Identifiable, Sendable {
    case handedIn, graded, feedback
    var id: String { rawValue }
    var title: String {
        switch self {
        case .handedIn: "Handed in · awaiting grade"
        case .graded: "Graded"
        case .feedback: "Graded · feedback available"
        }
    }
    var status: CanvasSubmissionStatus { self == .handedIn ? .submitted : .graded }
}

/// Assignment dates are already adjusted by Canvas for the requesting student.
/// Keep the ISO timestamps intact for both the native and browser views.
struct CanvasAssignmentDetails: Codable, Equatable, Sendable {
    var dueAt: String?
    var unlockAt: String?
    var lockAt: String?
    var submissionTypes: [String]
    private var canvasStatus: CanvasSubmissionStatus
    // Course-local corrections are applied to display copies, never encoded as Canvas metadata.
    var progressOverride: StudyAssignmentProgress? = nil
    var status: CanvasSubmissionStatus {
        get {
            if let progressOverride { return progressOverride.status }
            // Older caches trusted workflow_state even when Canvas withheld the result.
            if canvasStatus == .graded && (gradeVisible == false || gradeMatchesCurrentSubmission == false) {
                return .submitted
            }
            return canvasStatus
        }
        set { canvasStatus = newValue }
    }
    var missing: Bool
    var locked: Bool
    var linkedFileIDs: [String]?
    var grade: String?
    var score: Double?
    var pointsPossible: Double?
    var gradingType: String?
    var gradeVisible: Bool?
    var gradeMatchesCurrentSubmission: Bool?
    var feedbackAvailable: Bool?
    var feedback: CanvasAssignmentFeedback?
    var submissionAttempt: Int?
    var submittedAt: String?
    var hasFeedback: Bool {
        if progressOverride == .handedIn { return false }
        return progressOverride == .feedback || feedbackAvailable == true
    }

    private enum CodingKeys: String, CodingKey {
        case dueAt, unlockAt, lockAt, submissionTypes, missing, locked, linkedFileIDs
        case canvasStatus = "status"
        case grade, score, pointsPossible, gradingType, gradeVisible, gradeMatchesCurrentSubmission, feedbackAvailable
        case feedback, submissionAttempt, submittedAt
    }

    init(record: [String: Any], origin: URL? = nil, courseID: Int? = nil) {
        dueAt = record["due_at"] as? String
        unlockAt = record["unlock_at"] as? String
        lockAt = record["lock_at"] as? String
        submissionTypes = record["submission_types"] as? [String] ?? []
        locked = record["locked_for_user"] as? Bool == true
        if let origin, let courseID, record.keys.contains("description") {
            linkedFileIDs = Self.linkedFiles(
                in: record["description"] as? String ?? "", origin: origin, courseID: courseID)
        }
        let submission = record["submission"] as? [String: Any] ?? [:]
        submissionAttempt = submission["attempt"] as? Int
        submittedAt = submission["submitted_at"] as? String
        let posted = (submission["posted_at"] as? String)?.isEmpty == false
        let visible = submission["excused"] as? Bool != true
            && submission["grade_hidden"] as? Bool != true
            && record["muted"] as? Bool != true
            && record["hide_in_gradebook"] as? Bool != true
            && submission["assignment_visible"] as? Bool != false
            && !(submission.keys.contains("posted_at") && !posted)
            && !(record["post_manually"] as? Bool == true && !posted)
        gradeVisible = visible
        grade = visible ? (submission["grade"] as? String ?? (submission["grade"] as? NSNumber)?.stringValue) : nil
        score = visible ? Self.number(submission["score"]) : nil
        pointsPossible = Self.number(record["points_possible"])
        gradingType = record["grading_type"] as? String
        gradeMatchesCurrentSubmission = submission["grade_matches_current_submission"] as? Bool
        feedback = CanvasAssignmentFeedback(record: record, submission: submission, gradeVisible: visible)
        feedbackAvailable = feedback?.hasCurrentFeedback
        missing = submission["missing"] as? Bool == true
        let workflow = submission["workflow_state"] as? String
        if submission["excused"] as? Bool == true {
            canvasStatus = .excused
        }
        // A missing assignment can be automatically graded zero without a submission.
        else if workflow == "graded" && !missing && visible && gradeMatchesCurrentSubmission != false
            && (score != nil || grade?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) {
            canvasStatus = .graded
        } else if submission["submitted_at"] as? String != nil
            || ["submitted", "pending_review"].contains(workflow ?? "") || (workflow == "graded" && !missing)
        {
            canvasStatus = .submitted
        } else if workflow == "unsubmitted" || missing {
            canvasStatus = .notSubmitted
        } else {
            canvasStatus = .unknown
        }
    }

    func retainingFeedback(from previous: Self?) -> Self {
        guard feedback == nil, let previous else { return self }
        var result = self
        result.feedback = previous.feedback
        if gradeVisible == false || gradeMatchesCurrentSubmission == false { result.feedback?.rubric = [] }
        if var feedback = result.feedback {
            let changedAttempt = submissionAttempt != nil && previous.submissionAttempt != nil
                && submissionAttempt != previous.submissionAttempt
            for index in feedback.comments.indices {
                let comment = feedback.comments[index]
                let differentAttempt = comment.attempt != nil && submissionAttempt != nil && comment.attempt != submissionAttempt
                let beforeSubmission = Self.date(comment.createdAt).map { created in
                    Self.date(submittedAt).map { created < $0 } ?? false
                } ?? false
                if differentAttempt || beforeSubmission || (changedAttempt && comment.attempt == nil && comment.createdAt == nil) {
                    feedback.comments[index].currentAttempt = false
                }
            }
            result.feedback = feedback
        }
        result.feedbackAvailable = result.feedback?.hasCurrentFeedback ?? previous.feedbackAvailable
        return result
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
        guard let raw = value as? String, let number = Double(raw), number.isFinite else { return nil }
        return number
    }

    var gradeLabel: String? {
        guard gradeVisible != false, status != .excused, gradingType != "not_graded" else { return nil }
        guard progressOverride != .handedIn || gradeMatchesCurrentSubmission == false else { return nil }
        let raw = grade?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        func format(_ number: Double) -> String { number.formatted(.number.precision(.fractionLength(0...2))) }
        var label = raw
        if gradingType == "pass_fail" {
            label = ["complete": "Complete", "pass": "Pass", "incomplete": "Incomplete", "fail": "Fail"][
                raw.lowercased()] ?? raw
        } else if gradingType == "points" || (raw.isEmpty && gradingType != "percent") {
            if let score {
                label = format(score) + (pointsPossible.map { " / \(format($0))" } ?? " points")
            }
        } else if gradingType == "percent", raw.isEmpty, let score, let pointsPossible, pointsPossible > 0 {
            label = "\(format(score / pointsPossible * 100))%"
        }
        guard !label.isEmpty else { return nil }
        return gradeMatchesCurrentSubmission == false ? "\(label) (previous attempt)" : label
    }

    /// Keep Canvas file identity before the assignment HTML becomes plain text.
    /// Only follow explicit links on this Canvas origin, never similarly named files.
    static func linkedFiles(in html: String, origin: URL, courseID: Int) -> [String] {
        let pattern = #"(?i)\b(?:href|src|data-api-endpoint)\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = html as NSString
        var result: [String] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: text.length)) {
            let value = text.substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: value, relativeTo: origin)?.absoluteURL, CanvasAddress.sameOrigin(url, origin)
            else { continue }
            var parts = url.path.split(separator: "/").map(String.init)
            if parts.starts(with: ["api", "v1"]) { parts.removeFirst(2) }
            if parts.first == "courses" {
                guard parts.count >= 4, parts[1] == String(courseID) else { continue }
                parts.removeFirst(2)
            }
            guard parts.count >= 2, parts[0] == "files", let id = Int(parts[1]), id > 0,
                parts.count == 2 || (parts.count == 3 && ["download", "preview"].contains(parts[2]))
            else { continue }
            let key = String(id)
            if !result.contains(key) { result.append(key) }
        }
        return result
    }

    var requiresSubmission: Bool { submissionTypes.contains { !["none", "not_graded"].contains($0) } }
    var dueDate: Date? { Self.date(dueAt) }

    /// Older downloaded instructions contain a generated Due line. Reconcile
    /// only that exact trailing line, identified by the saved source version.
    static func refreshingCachedDeadline(_ text: String, sourceVersion: String?, dueAt: String?) -> String {
        guard let version = sourceVersion, let marker = version.range(of: "|due:", options: .backwards) else { return text }
        let previous = String(version[marker.upperBound...])
        guard date(previous) != nil else { return text }
        let line = "Due: " + previous
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == line || trimmed.hasSuffix("\n" + line) else { return text }
        let body = String(trimmed.dropLast(line.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return [body, dueAt.map { "Due: " + $0 }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    private static let dateStyle = Date.ISO8601FormatStyle()
    private static let fractionalDateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? dateStyle.parse(value)) ?? (try? fractionalDateStyle.parse(value))
    }
    func availability(at now: Date) -> String? {
        if let date = Self.date(lockAt), date <= now { return "Closed" }
        if let date = Self.date(unlockAt), date > now { return "Not open yet" }
        return locked ? "Locked in Canvas" : nil
    }
    func statusLabel(at now: Date) -> String {
        switch status {
        case .submitted, .graded, .unknown: return status.submissionLabel
        case .excused: return "Excused"
        case .notSubmitted:
            if let dueDate, dueDate < now { return "Overdue" }
            if missing { return "Missing" }
            if let dueDate, Calendar.current.isDate(dueDate, inSameDayAs: now) { return "Due today" }
            return "To submit"
        }
    }
}

struct StudyAssignment: Identifiable {
    let course: StudyCourse
    let material: CanvasMaterialReference
    let dueDate: Date?
    var id: String { "\(course.id):\(material.id)" }
    var details: CanvasAssignmentDetails? { material.assignment }
    var isHidden: Bool { course.hiddenAssignmentIDs?.contains(material.id) == true }

    func isUpcoming(at now: Date) -> Bool {
        guard let dueDate else { return false }
        return dueDate > now && details?.status.isComplete != true
    }

    static func list(
        courses: [StudyCourse], query: String = "", includeCompleted: Bool = false, dueOnly: Bool = false,
        includeHidden: Bool = false, hiddenOnly: Bool = false, includeNonSubmission: Bool = false
    ) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return courses.flatMap { course in
            course.materials.filter {
                $0.kind == .assignments
                    && (includeNonSubmission || $0.assignment?.requiresSubmission != false
                        || $0.assignment?.status.isComplete == true)
                    && (hiddenOnly
                        ? course.hiddenAssignmentIDs?.contains($0.id) == true
                        : includeHidden || course.hiddenAssignmentIDs?.contains($0.id) != true)
                    && (includeCompleted || $0.assignment?.status.isComplete != true)
                    && (!dueOnly || $0.assignment?.dueDate != nil)
                    && (query.isEmpty
                        || "\(course.name) \(course.code) \($0.title)".localizedCaseInsensitiveContains(query))
            }.map { Self(course: course, material: $0, dueDate: $0.assignment?.dueDate) }
        }.sorted {
            let lhs = $0.dueDate ?? .distantFuture
            let rhs = $1.dueDate ?? .distantFuture
            if lhs != rhs { return lhs < rhs }
            let order = $0.material.title.localizedStandardCompare($1.material.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }
}

struct StudyAssignmentGroup: Identifiable {
    let semester: StudySemester
    let timeframe: StudyAssignmentTimeframe
    let items: [StudyAssignment]
    var id: String { "\(timeframe.rawValue):\(semester.id)" }
    private struct Key: Hashable {
        var semester: StudySemester
        var timeframe: StudyAssignmentTimeframe
    }

    static func make(
        courses: [StudyCourse], query: String = "", filter: StudyAssignmentFilter = .due, now: Date = Date()
    ) -> [Self] {
        let memberships = Dictionary(
            uniqueKeysWithValues: courses.map {
                ($0.id, StudySemester.memberships(term: $0.term, code: $0.code, name: $0.name))
            })
        var groups: [Key: [StudyAssignment]] = [:]
        for item in StudyAssignment.list(
            courses: courses, query: query, includeCompleted: true, includeHidden: filter == .all,
            hiddenOnly: filter == .hidden, includeNonSubmission: [.all, .archive, .hidden].contains(filter))
        {
            let hasDeadline = item.dueDate != nil && item.details?.status.isComplete != true
            switch filter {
            case .due: guard hasDeadline else { continue }
            case .handedIn: guard item.details?.status == .submitted else { continue }
            case .graded: guard item.details?.status == .graded else { continue }
            case .archive: guard !hasDeadline else { continue }
            case .all, .hidden: break
            }
            let terms = memberships[item.course.id] ?? [.unassigned]
            // A year-long course appears once, in the matching deadline semester.
            let dueSemester = item.dueDate.map { StudySemester.current(at: $0) }
            let semester = terms.first { $0 == dueSemester } ?? terms.first ?? .unassigned
            let timeframe: StudyAssignmentTimeframe
            if filter == .archive {
                timeframe = .archive
            } else if item.details?.status == .graded {
                timeframe = .graded
            } else if item.details?.status == .submitted {
                timeframe = .handedIn
            } else if item.details?.status == .excused {
                timeframe = .excused
            } else if item.dueDate == nil {
                timeframe = .undated
            } else {
                timeframe = item.isUpcoming(at: now) ? .upcoming : .overdue
            }
            groups[Key(semester: semester, timeframe: timeframe), default: []].append(item)
        }
        return groups.map { key, rows in
            let items =
                key.timeframe == .upcoming || key.timeframe == .overdue
                ? rows
                : rows.sorted {
                    let lhs = $0.dueDate ?? .distantPast
                    let rhs = $1.dueDate ?? .distantPast
                    if lhs != rhs { return lhs > rhs }
                    return $0.material.title.localizedStandardCompare($1.material.title) == .orderedAscending
                }
            return Self(semester: key.semester, timeframe: key.timeframe, items: items)
        }.sorted {
            if $0.timeframe != $1.timeframe { return $0.timeframe.rawValue < $1.timeframe.rawValue }
            if ($0.timeframe == .upcoming || $0.timeframe == .overdue),
                $0.items.first?.dueDate != $1.items.first?.dueDate
            {
                return ($0.items.first?.dueDate ?? .distantFuture) < ($1.items.first?.dueDate ?? .distantFuture)
            }
            return StudySemester.newestFirst($0.semester, $1.semester)
        }
    }
}

enum StudyAssignmentTimeframe: Int, CaseIterable, Identifiable {
    case overdue, upcoming, undated, handedIn, graded, excused, archive
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .upcoming: "Upcoming"
        case .overdue: "Overdue"
        case .undated: "No deadline"
        case .handedIn: "Handed in · awaiting grade"
        case .graded: "Graded"
        case .excused: "Excused"
        case .archive: "Archive"
        }
    }
}

enum StudyAssignmentFilter: String, CaseIterable, Identifiable {
    case due = "Due & overdue"
    case handedIn = "Handed in"
    case graded = "Graded"
    case all = "All assignments"
    case archive = "Archive"
    case hidden = "Hidden"
    var id: String { rawValue }
}

struct StudyAssignmentDateGroup: Identifiable {
    let date: Date?
    var items: [StudyAssignment]
    var id: String { date.map { String($0.timeIntervalSince1970) } ?? "undated" }
    var title: String {
        date?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()) ?? "No due date"
    }

    static func make(_ items: [StudyAssignment], calendar: Calendar = .current) -> [Self] {
        var groups: [Self] = []
        for item in items {
            let day = item.dueDate.map { calendar.startOfDay(for: $0) }
            if let index = groups.firstIndex(where: { $0.date == day }) {
                groups[index].items.append(item)
            } else {
                groups.append(Self(date: day, items: [item]))
            }
        }
        return groups
    }
}

struct StudyAssignmentTimeline {
    let past: [StudyAssignmentDateGroup]
    let upcoming: [StudyAssignmentDateGroup]

    init(groups: [StudyAssignmentGroup], calendar: Calendar = .current) {
        func days(_ timeframe: StudyAssignmentTimeframe) -> [StudyAssignmentDateGroup] {
            let items = groups.filter { $0.timeframe == timeframe }.flatMap(\.items).sorted {
                let lhs = $0.dueDate ?? .distantFuture
                let rhs = $1.dueDate ?? .distantFuture
                if lhs != rhs { return lhs < rhs }
                let order = $0.material.title.localizedStandardCompare($1.material.title)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            return StudyAssignmentDateGroup.make(items, calendar: calendar)
        }
        past = days(.overdue)
        upcoming = days(.upcoming)
    }
}
