import Foundation

/// Only reviewed exam fields are retained; pasted Studentweb pages and credentials are never stored.
struct StudyExam: Codable, Equatable, Identifiable, Sendable {
    var id = UUID().uuidString
    var courseCode = ""
    var courseName = ""
    var component = "Final exam"
    var kind = "final"
    var date = ""
    var startTime = ""
    var endTime = ""
    var endDate = ""
    var selected = false
    var source = "manual"
    var flexible = false

    var needsTiming: Bool { !flexible && (date.isEmpty || startTime.isEmpty || endTime.isEmpty) }
    var isOral: Bool { Self.isOralComponent(component) }
    static func isOralComponent(_ value: String) -> Bool {
        value.range(of: #"(?i)\b(oral|muntlig)\b"#, options: .regularExpression) != nil
    }

    var courseKey: String {
        let code = courseCode.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        return code.isEmpty ? (courseName.isEmpty ? "draft-" + id : courseName.lowercased()) : code
    }
    var title: String { "\(courseCode.isEmpty ? courseName : courseCode) · \(component)" }
}

extension StudyExam {
    // Older saved plans predate the explicit flexible-timing override.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        courseCode = try values.decode(String.self, forKey: .courseCode)
        courseName = try values.decode(String.self, forKey: .courseName)
        component = try values.decode(String.self, forKey: .component)
        kind = try values.decode(String.self, forKey: .kind)
        date = try values.decode(String.self, forKey: .date)
        startTime = try values.decode(String.self, forKey: .startTime)
        endTime = try values.decode(String.self, forKey: .endTime)
        endDate = try values.decode(String.self, forKey: .endDate)
        selected = try values.decode(Bool.self, forKey: .selected)
        source = try values.decode(String.self, forKey: .source)
        flexible = try values.decodeIfPresent(Bool.self, forKey: .flexible) ?? Self.isOralComponent(component)
    }
}

struct StudyExamCollision: Identifiable, Equatable {
    let first: String
    let second: String
    let possible: Bool
    var id: String { first + ":" + second }
}

struct StudyExamImport {
    var exams: [StudyExam] = []
    var warnings: [String] = []
    var replacesStudentweb = false
    var sourceCount: Int?
}

/// Reused by the views until the plan changes, including during Canvas sync.
struct StudyExamPlanAnalysis {
    var selected: [StudyExam]
    var groups: [String: [StudyExam]]
    var days: [String: [StudyExam]]
    var byID: [String: StudyExam]
    var conflicts: [StudyExamCollision]
    var choices: [StudyExamCollision]
    var conflictsByID: [String: [StudyExamCollision]] = [:]
    var unknown: Int
    var flexibleCount: Int

    init(_ exams: [StudyExam] = []) {
        selected = exams.filter(\.selected).sorted(by: StudyExamPlanner.chronological)
        groups = Dictionary(grouping: exams, by: \.courseKey)
        days = Dictionary(grouping: selected, by: \.date)
        let lookup = Dictionary(exams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        byID = lookup
        // Keep a set-aside exam available to select after timing becomes flexible.
        // Once both exams are selected, the flexible pair is resolved and hidden.
        let referenceDates = exams.map { value in
            var exam = value
            exam.selected = true
            exam.flexible = false
            return exam
        }
        choices = selected.isEmpty ? [] : StudyExamPlanner.collisions(referenceDates).filter { pair in
            guard let a = lookup[pair.first], let b = lookup[pair.second] else { return false }
            if a.flexible || b.flexible { return a.selected != b.selected }
            return a.selected && b.selected
        }
        conflicts = choices.filter { pair in
            lookup[pair.first]?.flexible == false && lookup[pair.second]?.flexible == false
        }
        for pair in conflicts {
            conflictsByID[pair.first, default: []].append(pair)
            conflictsByID[pair.second, default: []].append(pair)
        }
        unknown = selected.filter(\.needsTiming).count
        flexibleCount = selected.filter(\.flexible).count
    }
}

/// Selection changes do not invalidate date/name validation for every row.
struct StudyExamValidationCache {
    private var inputs: [String: StudyExam] = [:]
    var errors: [String: String] = [:]
    var valid = true

    mutating func update(_ exams: [StudyExam]) {
        let ids = Set(exams.map(\.id))
        inputs = inputs.filter { ids.contains($0.key) }
        errors = errors.filter { ids.contains($0.key) }
        for exam in exams {
            var input = exam
            input.selected = false; input.flexible = false
            guard inputs[exam.id] != input else { continue }
            inputs[exam.id] = input
            do { _ = try StudyExamPlanner.normalized([input]); errors[exam.id] = nil }
            catch { errors[exam.id] = error.localizedDescription }
        }
        valid = errors.isEmpty && ids.count == exams.count && exams.count <= StudyExamPlanner.maximumExams
    }
}

enum StudyExamPlanner {
    static let maximumExams = 500
    /// A fresh opening-page snapshot replaces previous Studentweb candidates.
    /// Preserve manually entered rows and intent only for exactly matching exams.
    static func importing(_ result: StudyExamImport, into existing: [StudyExam]) throws -> [StudyExam] {
        var rows = result.replacesStudentweb ? existing.filter { $0.source != "studentweb" } : existing
        var unmatched = result.replacesStudentweb ? rows + existing.filter { $0.source == "studentweb" } : existing
        for candidate in result.exams {
            var exam = candidate
            if result.replacesStudentweb {
                if let index = unmatched.firstIndex(where: { duplicate($0, candidate) }) {
                    let previous = unmatched.remove(at: index)
                    if previous.source != "studentweb" { continue }
                    exam.id = previous.id
                    exam.selected = previous.selected
                    exam.courseName = previous.courseName
                    exam.flexible = previous.flexible
                }
            } else if rows.contains(where: { duplicate($0, candidate) }) {
                continue
            }
            rows.append(exam)
        }
        guard rows.count <= maximumExams else { throw StudyError.message("An exam plan can contain at most 500 exams. Import fewer rows.") }
        return rows
    }
    static func chronological(_ a: StudyExam, _ b: StudyExam) -> Bool {
        (a.date.isEmpty ? "9999" : a.date, a.startTime.isEmpty ? "99:99" : a.startTime, a.courseKey, a.id)
            < (b.date.isEmpty ? "9999" : b.date, b.startTime.isEmpty ? "99:99" : b.startTime, b.courseKey, b.id)
    }
    static func isPast(_ exam: StudyExam, today: String = StudyExamPlanner.dayString(Date())) -> Bool {
        let lastDay = exam.endDate.isEmpty ? exam.date : exam.endDate
        return !lastDay.isEmpty && lastDay < today
    }

    static func focusCourses(_ exams: [StudyExam], courses: [StudyCourse],
        today: String = StudyExamPlanner.dayString(Date())) -> [StudyCourse] {
        let ready = favoriteCourseIDs(exams, courses: courses)
        let upcoming = exams.filter { $0.selected && !isPast($0, today: today) }.sorted(by: chronological)
        let next = Dictionary(upcoming.map { ($0.courseKey, $0) }, uniquingKeysWith: { first, _ in first })
        func key(_ course: StudyCourse) -> String { StudyExam(courseCode: course.displayCode, courseName: course.name).courseKey }
        return courses.filter { ready.contains($0.id) && next[key($0)] != nil }
            .sorted { chronological(next[key($0)]!, next[key($1)]!) }
    }
    static let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Oslo")!
        return value
    }()

    static func day(_ value: String) -> Date? {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1900...2200).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]),
            let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        guard actual.year == parts[0], actual.month == parts[1], actual.day == parts[2] else { return nil }
        return calendar.startOfDay(for: date)
    }

    static func dayString(_ value: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: value)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func minute(_ value: String) -> Int? {
        guard value.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }

    // All inputs are campus-local civil times. Civil minutes avoid browser/device timezone differences.
    private static func civilMinute(_ date: String, _ time: String) -> Int? {
        guard let day = day(date), let minute = minute(time) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let utcDay = utc.date(from: components) else { return nil }
        return Int(utcDay.timeIntervalSince1970 / 60) + minute
    }

    static func normalized(_ exams: [StudyExam]) throws -> [StudyExam] {
        guard exams.count <= maximumExams else { throw StudyError.message("An exam plan can contain at most 500 exams.") }
        var ids = Set<String>()
        return try exams.map { original in
            var exam = original
            func clean(_ value: String) -> String {
                value.replacingOccurrences(of: #"[\x00-\x1f\x7f]"#, with: " ", options: .regularExpression)
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            exam.id = clean(exam.id)
            exam.courseCode = exam.courseCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().replacingOccurrences(of: "[\\s-]+", with: "", options: .regularExpression)
            exam.courseName = clean(exam.courseName)
            exam.component = clean(exam.component)
            for (label, value, maxLength) in [("Identifier", exam.id, 100), ("Course code", exam.courseCode, 40),
                ("Course name", exam.courseName, 180), ("Exam component", exam.component, 120)] {
                guard value.count <= maxLength, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw StudyError.message("\(label) is too long or contains unsupported characters.")
                }
            }
            guard !exam.id.isEmpty, ids.insert(exam.id).inserted else { throw StudyError.message("Every exam must have a unique identifier.") }
            guard !exam.courseCode.isEmpty || !exam.courseName.isEmpty else { throw StudyError.message("Add a course code or course name for every exam.") }
            if exam.component.isEmpty { exam.component = exam.kind == "midterm" ? "Midterm" : exam.kind == "final" ? "Final exam" : "Exam" }
            guard ["midterm", "final", "other"].contains(exam.kind), ["studentweb", "manual"].contains(exam.source) else {
                throw StudyError.message("Unknown exam type or source.")
            }
            guard exam.date.isEmpty || day(exam.date) != nil, exam.endDate.isEmpty || day(exam.endDate) != nil else {
                throw StudyError.message("Use valid dates in YYYY-MM-DD format for \(exam.title).")
            }
            guard exam.startTime.isEmpty || minute(exam.startTime) != nil,
                exam.endTime.isEmpty || minute(exam.endTime) != nil else {
                throw StudyError.message("Use 24-hour times in HH:mm format for \(exam.title).")
            }
            guard !exam.date.isEmpty || (exam.endDate.isEmpty && exam.startTime.isEmpty && exam.endTime.isEmpty) else {
                throw StudyError.message("Add an exam date before entering times or an end date.")
            }
            guard exam.endDate.isEmpty || (!exam.date.isEmpty && exam.endDate >= exam.date) else {
                throw StudyError.message("The end date must be on or after the exam date for \(exam.title).")
            }
            if !exam.startTime.isEmpty, !exam.endTime.isEmpty,
                (exam.endDate.isEmpty || exam.endDate == exam.date), exam.endTime <= exam.startTime {
                throw StudyError.message("The end must follow the start for \(exam.title). Add an end date for an overnight exam.")
            }
            if exam.endDate == exam.date { exam.endDate = "" }
            return exam
        }
    }

    static func collisions(_ exams: [StudyExam]) -> [StudyExamCollision] {
        // Parse dates and times once per exam, rather than for every pair.
        struct Window { var id: String; var start: Int; var end: Int; var certain: Bool }
        var days: [String: Int] = [:]
        func dayMinute(_ date: String) -> Int? {
            if let cached = days[date] { return cached }
            guard let parsed = civilMinute(date, "00:00") else { return nil }
            days[date] = parsed
            return parsed
        }
        let selected: [Window] = exams.compactMap { exam in
            guard exam.selected, !exam.flexible, let startDay = dayMinute(exam.date),
                let lastDay = dayMinute(exam.endDate.isEmpty ? exam.date : exam.endDate) else { return nil }
            let start = minute(exam.startTime), end = minute(exam.endTime)
            return Window(id: exam.id, start: startDay + (start ?? 0), end: lastDay + (end ?? 1440),
                certain: start != nil && end != nil)
        }
        var results: [StudyExamCollision] = []
        for i in selected.indices {
            for j in selected.indices where j > i {
                let a = selected[i], b = selected[j]
                if a.start < b.end && b.start < a.end {
                    results.append(StudyExamCollision(first: a.id, second: b.id, possible: !a.certain || !b.certain))
                }
            }
        }
        return results
    }

    static func duplicate(_ a: StudyExam, _ b: StudyExam) -> Bool {
        a.courseKey == b.courseKey && a.component.lowercased() == b.component.lowercased()
            && a.kind == b.kind && a.date == b.date && a.startTime == b.startTime && a.endTime == b.endTime && a.endDate == b.endDate
    }

    static func favoriteCourseIDs(_ exams: [StudyExam], courses: [StudyCourse], conflicts: [StudyExamCollision]? = nil) -> Set<UUID> {
        let conflicts = conflicts ?? collisions(exams)
        let blocked = Set(conflicts.flatMap { [$0.first, $0.second] })
        let groups = Dictionary(grouping: exams.filter(\.selected), by: \.courseKey)
        let ready = Set(groups.filter { _, members in
            members.allSatisfy { !blocked.contains($0.id) && ($0.flexible || (day($0.date) != nil
                && minute($0.startTime) != nil && minute($0.endTime) != nil)) }
        }.keys)
        return Set(courses.filter { course in
            let key = StudyExam(courseCode: course.displayCode, courseName: course.name).courseKey
            return ready.contains(key)
        }.map(\.id))
    }

    static func resolveConflict(_ exams: [StudyExam], keep: String, drop: String) throws -> [StudyExam] {
        let rows = try normalized(exams)
        guard collisions(rows).contains(where: { ($0.first == keep && $0.second == drop) || ($0.first == drop && $0.second == keep) }),
            let kept = rows.first(where: { $0.id == keep }), let removed = rows.first(where: { $0.id == drop }) else {
            throw StudyError.message("This pair no longer conflicts. Review the updated schedule.")
        }
        return rows.map { value in
            var exam = value
            if kept.courseKey == removed.courseKey ? exam.id == drop : exam.courseKey == removed.courseKey { exam.selected = false }
            return exam
        }
    }

    static func setFlexibleTiming(_ exams: [StudyExam], id: String, flexible: Bool) throws -> [StudyExam] {
        var rows = try normalized(exams)
        guard let index = rows.firstIndex(where: { $0.id == id }) else {
            throw StudyError.message("This exam is no longer in your plan. Review the updated schedule.")
        }
        rows[index].flexible = flexible
        return rows
    }

    static func setSelected(_ exams: [StudyExam], id: String, selected: Bool) throws -> [StudyExam] {
        var rows = try normalized(exams)
        guard let index = rows.firstIndex(where: { $0.id == id }) else {
            throw StudyError.message("This exam is no longer in your plan. Review the updated schedule.")
        }
        rows[index].selected = selected
        return rows
    }

    /// Conservative line parser: only rows under a recognized course code become candidates.
    static func parseStudentweb(_ pasted: String) -> StudyExamImport {
        var result = StudyExamImport()
        guard pasted.utf8.count <= 1_000_000 else {
            result.warnings = ["Paste only the exam details (at most 1 MB)."]
            return result
        }
        var code = "", name = "", component = "Exam", kind = "other"
        var pendingIndex: Int?
        let lines = pasted.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var awaitingDate = false
        for line in lines where !line.isEmpty {
            if line.range(of: #"(?i)(frist|deadline|fødsels|birth|studentnummer|kandidatnummer|candidate|e-?post|e-?mail|telefon|phone|registrering|registration|results? date|sensur|publisert|published|oppmelding|avmelding)"#, options: .regularExpression) != nil {
                awaitingDate = false; continue
            }
            let courseMatch = captures(#"(?i)\b((?!(?:januar|january|jan|februar|february|feb|mars|march|mar|april|apr|mai|may|juni|june|jun|juli|july|jul|august|aug|september|sep|oktober|october|okt|oct|november|nov|desember|december|des|dec|spring|summer|autumn|winter|fall|vår|høst|semester)[- ]?\d{3,5}\b)[A-ZÆØÅ]{2,8}[- ]?\d{3,5}[A-Z]?)\b"#, line).first
            if let match = courseMatch {
                code = match[1].uppercased().replacingOccurrences(of: "[ -]", with: "", options: .regularExpression)
                name = ""
                component = "Exam"
                kind = "other"
                pendingIndex = nil
                if let range = line.range(of: match[0], options: .caseInsensitive) {
                    let suffix = String(line[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " \t:–—-"))
                    let firstCell = suffix.components(separatedBy: "\t").first ?? ""
                    if parsedDates(firstCell).isEmpty, firstCell.count <= 200, !firstCell.contains(":") { name = firstCell }
                }
            }
            guard !code.isEmpty else { continue }
            let examHeading = line.range(of: #"(?i)\b(midterm|midtsemester|midtveis|deleksamen|underveis|partial|final|slutteksamen|skoleeksamen|skriftlig|written|hjemmeeksamen|home exam|muntlig|oral|vurdering|vurderingsform|vurderingsdel|assessment|component)\b"#, options: .regularExpression) != nil
            if line.range(of: #"(?i)\b(midterm|midtsemester|midtveis|deleksamen|underveis|partial)\b"#, options: .regularExpression) != nil {
                component = "Midterm"; kind = "midterm"; pendingIndex = nil
            } else if line.range(of: #"(?i)\b(final|slutteksamen|skoleeksamen|skriftlig|written|hjemmeeksamen|home exam|muntlig|oral)\b"#, options: .regularExpression) != nil {
                component = "Final exam"; kind = "final"; pendingIndex = nil
                if line.localizedCaseInsensitiveContains("muntlig") || line.localizedCaseInsensitiveContains("oral") { component = "Oral exam" }
                if line.localizedCaseInsensitiveContains("hjemmeeksamen") || line.localizedCaseInsensitiveContains("home exam") { component = "Home exam" }
            }
            let dates = parsedDates(line)
            let times = captures(#"\b([01]?\d|2[0-3])[:.]([0-5]\d)\b"#, line).filter { match in
                // Dotted dates must not be mistaken for times.
                !line.contains(match[0] + ".") && !line.contains(match[0] + "/")
            }.map { String(format: "%02d:%02d", Int($0[1])!, Int($0[2])!) }
            let dateLabel = line.range(of: #"(?i)^\s*(dato|date|eksamensdato|exam date)\b"#, options: .regularExpression) != nil
            let bareDate = line.range(of: #"^\d{1,4}([./-]|\.?\s)[\p{L}\d]"#, options: .regularExpression) != nil
            if let date = dates.first, courseMatch != nil || examHeading || dateLabel || (awaitingDate && bareDate) {
                var exam = StudyExam(courseCode: code, courseName: name, component: component, kind: kind,
                    date: date, startTime: times.first ?? "", endTime: times.dropFirst().first ?? "", source: "studentweb", flexible: StudyExam.isOralComponent(component))
                if dates.count > 1 { exam.endDate = dates[1] }
                if !result.exams.contains(where: { duplicate($0, exam) }) { result.exams.append(exam); pendingIndex = result.exams.count - 1 }
            } else if let index = pendingIndex, !times.isEmpty {
                if line.range(of: #"(?i)\b(end|slutt|slutttid)\b"#, options: .regularExpression) != nil, times.count == 1 {
                    result.exams[index].endTime = times[0]
                } else {
                    result.exams[index].startTime = times[0]
                    if times.count > 1 { result.exams[index].endTime = times[1] }
                }
            }
            if let index = pendingIndex, result.exams[index].endTime.isEmpty,
                let start = minute(result.exams[index].startTime),
                let duration = captures(#"(?i)\b(\d+(?:[.,]\d+)?)\s*(timer?|hours?|minutter?|minutes?)\b"#, line).first,
                let quantity = Double(duration[1].replacingOccurrences(of: ",", with: ".")), quantity > 0 {
                let durationMinutes = quantity * (duration[2].lowercased().hasPrefix("min") ? 1 : 60)
                if durationMinutes <= 10080, durationMinutes.rounded() == durationMinutes,
                    let startDay = day(result.exams[index].date),
                    let endDay = calendar.date(byAdding: .day, value: (start + Int(durationMinutes)) / 1440, to: startDay) {
                    let end = (start + Int(durationMinutes)) % 1440
                    result.exams[index].endTime = String(format: "%02d:%02d", end / 60, end % 60)
                    let endDate = dayString(endDay)
                    if endDate != result.exams[index].date { result.exams[index].endDate = endDate }
                }
            }
            awaitingDate = dates.isEmpty && (courseMatch != nil || examHeading || dateLabel)
            if result.exams.count >= maximumExams { result.warnings.append("Only the first 500 exam entries were imported."); break }
        }
        if result.exams.isEmpty { result.warnings.append("No dated exams found. Include a course code, exam date with year, and times, or add an exam manually.") }
        else { result.warnings.append("Review each course, exam component, date and time against Studentweb. Select the exams you intend to take.") }
        if result.exams.contains(where: { $0.startTime.isEmpty || $0.endTime.isEmpty }) {
            result.warnings.append("Some times are missing. Collisions on those dates remain uncertain until you add both times.")
        }
        return result
    }

    private static func captures(_ pattern: String, _ text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let value = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: value.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : value.substring(with: match.range(at: $0)) }
        }
    }

    private static func parsedDates(_ text: String) -> [String] {
        var values = captures(#"\b(\d{4})-(\d{2})-(\d{2})\b"#, text).map { "\($0[1])-\($0[2])-\($0[3])" }
        values += captures(#"\b(\d{1,2})[./](\d{1,2})[./](\d{4})\b"#, text).map {
            String(format: "%04d-%02d-%02d", Int($0[3])!, Int($0[2])!, Int($0[1])!)
        }
        let months = ["januar": 1, "january": 1, "jan": 1, "februar": 2, "february": 2, "feb": 2,
            "mars": 3, "march": 3, "mar": 3, "april": 4, "apr": 4, "mai": 5, "may": 5,
            "juni": 6, "june": 6, "jun": 6, "juli": 7, "july": 7, "jul": 7, "august": 8, "aug": 8,
            "september": 9, "sep": 9, "oktober": 10, "october": 10, "okt": 10, "oct": 10,
            "november": 11, "nov": 11, "desember": 12, "december": 12, "des": 12, "dec": 12]
        for match in captures(#"(?i)\b(\d{1,2})\.?\s+([a-zæøå]+)\.?\s+(\d{4})\b"#, text) {
            if let month = months[match[2].lowercased()] { values.append(String(format: "%04d-%02d-%02d", Int(match[3])!, month, Int(match[1])!)) }
        }
        return values.filter { day($0) != nil }
    }
}

extension StudyWorkspaceModel {
    func replaceExamPlan(_ exams: [StudyExam], base: [StudyExam]) throws {
        guard (library.examPlan ?? []) == base else {
            throw StudyError.message("Your exam plan changed elsewhere. Reload the saved plan before saving.")
        }
        let normalized = try StudyExamPlanner.normalized(exams)
        let favorites = StudyExamPlanner.favoriteCourseIDs(normalized, courses: library.courses)
        var updated = library
        updated.examPlan = normalized
        for index in updated.courses.indices {
            if favorites.contains(updated.courses[index].id) && !updated.courses[index].isFavorite {
                updated.courses[index].favorite = true
                updated.courses[index].examFavorite = true
            } else if !favorites.contains(updated.courses[index].id) && updated.courses[index].examFavorite == true {
                updated.courses[index].favorite = false
                updated.courses[index].examFavorite = false
            }
        }
        // Publish once, including bulk selection and its automatic favorites.
        library = updated
        save()
    }
}
