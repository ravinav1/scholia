import Foundation

enum StudyCourseLibraryViewMode: String, Codable, CaseIterable, Sendable {
    case all, favorites, semesters, assignments
}

/// A course can belong to more than one semester (Canvas uses e.g.
/// "2026 HØST|2027 VÅR"). Keep that membership instead of guessing one term.
struct StudySemester: Hashable, Sendable {
    var id: String
    var title: String
    var year: Int?
    var half: Int?

    static let unassigned = StudySemester(id: "unassigned", title: "No semester")

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    static func academic(year: Int, autumn: Bool) -> Self {
        Self(
            id: "\(year)-\(autumn ? "autumn" : "spring")",
            title: "\(autumn ? "Autumn" : "Spring") \(year)", year: year, half: autumn ? 2 : 1)
    }

    static func current(at date: Date = Date(), calendar: Calendar = .current) -> Self {
        academic(year: calendar.component(.year, from: date), autumn: calendar.component(.month, from: date) >= 8)
    }

    static func memberships(term: String?, code: String, name: String) -> [Self] {
        let raw = (term ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let explicit = parse(raw)
        if !explicit.isEmpty { return explicit }
        // NTNU course codes remain useful when Canvas calls a term "Default term".
        let fallback = parse(code + " " + name)
        if !fallback.isEmpty { return fallback }
        let generic = ["", "default term", "default", "standard", "standard term"]
        if generic.contains(raw.lowercased()) { return [.unassigned] }
        return [Self(id: "term:\(raw.lowercased())", title: raw)]
    }

    private static let patterns: [(NSRegularExpression, Bool)] = {
        let definitions = [
            (#"(?<![A-Z0-9])((?:19|20)[0-9]{2})[\s_/-]*(HOST|AUTUMN|FALL|VAR|SPRING|[HV])(?=$|[^A-Z0-9])"#, false),
            (#"(?<![A-Z0-9])(HOST|AUTUMN|FALL|VAR|SPRING|[HV])[\s_/-]*((?:19|20)[0-9]{2})(?=$|[^A-Z0-9])"#, true),
            (#"(?<![A-Z0-9])([0-9]{2})([HV])(?=$|[^A-Z0-9])"#, false),
        ]
        return definitions.compactMap { pattern, reversed in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, reversed)
        }
    }()

    private static func parse(_ text: String) -> [Self] {
        let normalized = text.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")
        )
        .uppercased().replacingOccurrences(of: "Ø", with: "O")
        var found = Set<Self>()
        for (regex, reversed) in patterns {
            for match in regex.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) {
                guard let yearRange = Range(match.range(at: reversed ? 2 : 1), in: normalized),
                    let seasonRange = Range(match.range(at: reversed ? 1 : 2), in: normalized),
                    var year = Int(normalized[yearRange])
                else { continue }
                if year < 100 { year += year >= 80 ? 1900 : 2000 }
                let season = String(normalized[seasonRange])
                found.insert(academic(year: year, autumn: ["H", "HOST", "AUTUMN", "FALL"].contains(season)))
            }
        }
        return found.sorted(by: newestFirst)
    }

    static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.year != rhs.year { return (lhs.year ?? 0) > (rhs.year ?? 0) }
        if lhs.half != rhs.half { return (lhs.half ?? 0) > (rhs.half ?? 0) }
        if lhs.id == unassigned.id || rhs.id == unassigned.id { return rhs.id == unassigned.id && lhs.id != rhs.id }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

struct StudySemesterGroup: Encodable, Identifiable, Sendable {
    var id: String
    var title: String
    var isCurrent: Bool
    var courseIDs: [UUID]

    static func make(courses: [StudyCourse], date: Date = Date()) -> [Self] {
        var groups: [StudySemester: [UUID]] = [:]
        for course in courses {
            for semester in StudySemester.memberships(term: course.term, code: course.code, name: course.name) {
                groups[semester, default: []].append(course.id)
            }
        }
        let current = StudySemester.current(at: date)
        return groups.keys.sorted(by: StudySemester.newestFirst).map {
            Self(id: $0.id, title: $0.title, isCurrent: $0 == current, courseIDs: groups[$0] ?? [])
        }
    }
}
