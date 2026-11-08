import Foundation

/// Metadata-only cache. Indices resolve against the caller's current library;
/// cached ordering can never retain stale documents or conversations.
@MainActor
final class StudyCourseCatalog {
    struct Input: Equatable {
        var id: UUID
        var name: String
        var code: String
        var term: String?
        var favorite: Bool
        init(_ course: StudyCourse) {
            id = course.id; name = course.name; code = course.code; term = course.term; favorite = course.isFavorite
        }
    }
    private var input: [Input] = []
    private var localeID = ""
    private var order: [Int] = []
    private var searchable: [String] = []
    private(set) var rebuildCount = 0

    func indices(in courses: [StudyCourse], query: String = "", locale: Locale = .current) -> [Int] {
        let next = courses.map(Input.init)
        if next != input || locale.identifier != localeID {
            input = next
            localeID = locale.identifier
            searchable = next.map { normalize($0.name + " " + $0.code + " " + ($0.term ?? ""), locale: locale) }
            order = next.indices.sorted {
                if next[$0].favorite != next[$1].favorite { return next[$0].favorite }
                let result = next[$0].name.compare(next[$1].name,
                    options: [.caseInsensitive, .diacriticInsensitive, .numeric, .widthInsensitive], locale: locale)
                return result == .orderedSame ? $0 < $1 : result == .orderedAscending
            }
            rebuildCount += 1
        }
        let needle = normalize(query, locale: locale)
        return needle.isEmpty ? order : order.filter { searchable[$0].contains(needle) }
    }
    private func normalize(_ value: String, locale: Locale) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
    }
}
