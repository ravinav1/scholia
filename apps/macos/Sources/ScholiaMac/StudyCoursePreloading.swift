import Foundation

struct StudyNavigation: Equatable {
    var library: Bool
    var course: UUID?
    var document: UUID?
    var assignment: String?
    var assignmentFile: String?
    var thread: UUID?
    var page: Int
    var libraryView: StudyCourseLibraryViewMode = .all
}

enum StudyCoursePreloading {
    /// Preload a few small, useful readings after repeated course visits.
    static func candidates(in course: StudyCourse) -> [CanvasMaterialReference] {
        guard (course.visitCount ?? 0) >= 3, course.canvasID != nil else { return [] }
        let saved = Set(course.documents.compactMap(\.sourceKey))
        let extensions: Set<String> = [
            "pdf", "txt", "md", "ipynb", "py", "r", "jl", "js", "ts", "c", "cpp", "h", "java", "m",
        ]
        let items = course.materials.filter {
            $0.kind == .files && !saved.contains($0.id) && $0.unavailableReason == nil
                && ($0.byteCount ?? 0) > 0 && ($0.byteCount ?? Int.max) <= 10_000_000
                && extensions.contains(URL(fileURLWithPath: $0.fileName ?? $0.title).pathExtension.lowercased())
        }.sorted {
            if $0.modulePosition != $1.modulePosition {
                return ($0.modulePosition ?? Int.max) < ($1.modulePosition ?? Int.max)
            }
            if $0.moduleItemPosition != $1.moduleItemPosition {
                return ($0.moduleItemPosition ?? Int.max) < ($1.moduleItemPosition ?? Int.max)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        var bytes = 0
        return Array(
            items.filter { item in
                let size = item.byteCount ?? 0
                guard bytes + size <= 20_000_000 else { return false }
                bytes += size
                return true
            }.prefix(3))
    }
}
