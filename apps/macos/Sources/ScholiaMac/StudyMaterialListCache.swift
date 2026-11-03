import Foundation

/// One active catalog is shared by the sidebar, overview and local web server.
/// Searching filters its prepared rows instead of reclassifying and sorting
/// every material on each keystroke. Only the latest query per layout is kept.
@MainActor
final class StudyMaterialListCache {
    private struct Catalog: Equatable {
        var courseID: UUID
        var documents: [StudyDocument]
        var materials: [CanvasMaterialReference]
        var assignmentProgress: [String: StudyAssignmentProgress]?
        var changes: CanvasCatalogChanges?

        init(_ course: StudyCourse) {
            courseID = course.id
            documents = course.documents
            materials = course.canvasMaterials ?? []
            assignmentProgress = course.assignmentProgress
            changes = course.catalogChanges
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.courseID == rhs.courseID, lhs.materials == rhs.materials,
                  lhs.assignmentProgress == rhs.assignmentProgress, lhs.changes == rhs.changes else { return false }
            // Equal arrays have a fast shared-storage path during chat updates.
            if lhs.documents == rhs.documents { return true }
            // Page turns and integrity checks change the saved document record,
            // but none of these fields affect the catalog entries or their order.
            return lhs.documents.elementsEqual(rhs.documents) { left, right in
                left.id == right.id && left.title == right.title && left.kind == right.kind
                    && left.fileName == right.fileName && left.originalFileName == right.originalFileName
                    && left.pageCount == right.pageCount && left.sourceURL == right.sourceURL
                    && left.sourceKey == right.sourceKey && left.sourceVersion == right.sourceVersion
                    && left.classification == right.classification
            }
        }
    }

    private var catalog: Catalog?
    private var allGroups: [StudyMaterialGroup]?
    private var grouped: (query: String, value: [StudyMaterialGroup])?
    private var flat: (query: String, value: [StudyMaterialEntry])?
    private var references: [String: CanvasMaterialReference] = [:]

    private func update(_ course: StudyCourse) {
        let next = Catalog(course)
        guard catalog != next else { return }
        catalog = next
        allGroups = nil
        grouped = nil
        flat = nil
        references = Dictionary(course.materials.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func groups(for course: StudyCourse, query: String = "") -> [StudyMaterialGroup] {
        update(course)
        if allGroups == nil { allGroups = StudyMaterialOrganizer.groups(for: course) }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { return allGroups! }
        if let grouped, grouped.query == query { return grouped.value }
        let value = StudyMaterialOrganizer.filterGroups(allGroups!, query: query, references: references)
        grouped = (query, value)
        return value
    }

    func files(for course: StudyCourse, query: String = "") -> [StudyMaterialEntry] {
        update(course)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let flat, flat.query == query { return flat.value }
        let value = StudyMaterialOrganizer.files(for: course, query: query, groups: groups(for: course))
        flat = (query, value)
        return value
    }

    func references(for course: StudyCourse) -> [String: CanvasMaterialReference] {
        update(course)
        return references
    }
}
