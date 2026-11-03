import Foundation

struct StudyMaterialEntry: Encodable, Identifiable, Sendable {
    var id: String
    var title: String
    var documentID: UUID?
    var materialID: String?
    var sourceURL: String?
    var symbol: String
    var detail: String
    var badge: String?
    var updateAvailable: Bool
    var order: Int
    var submissionStatus: CanvasSubmissionStatus?
    var requiresSubmission: Bool?
    var assignment: CanvasAssignmentDetails?
    var categoryID: String
    var categoryTitle: String
    var classificationConfidence: String
    var classificationBasis: String
    var topic: String?
    var extractionMethod: String
    var canvasHeading: String?
    var canvasSubheading: String?
    var linkedPosition: Int?
    var linkedOrder: [Int]?
}
struct StudyMaterialGroup: Encodable, Identifiable, Sendable {
    var id: String
    var title: String
    var basis: String
    var order: Int
    var items: [StudyMaterialEntry]
}

enum StudyMaterialOrganizer {
    static func groups(for course: StudyCourse, query: String = "") -> [StudyMaterialGroup] {
        var groups: [String: StudyMaterialGroup] = [:]
        let materials = course.materials
        let saved = Dictionary(
            course.documents.compactMap { doc in doc.sourceKey.map { ($0, doc) } },
            uniquingKeysWith: { first, _ in first })
        let references = Dictionary(materials.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func add(document: StudyDocument?, reference: CanvasMaterialReference?) {
            let title = document?.title ?? reference?.title ?? "Untitled material"
            let analysis: StudyMaterialClassification
            if let cached = document?.classification, cached.version == StudyMaterialClassifier.version,
               reference?.kind != .assignments, reference?.kind != .syllabus {
                analysis = cached
            } else {
                analysis = StudyMaterialClassifier.analyze(title: title,
                    fileName: reference?.fileName ?? document?.originalFileName ?? document?.fileName,
                    kind: document?.kind, materialKind: reference?.kind)
            }
            let externalWebsite = reference?.isMathWiki == true || reference?.isCourseWebsite == true
            let grouping: (String, String, Int, String)
            if let id = reference?.moduleID, let name = reference?.moduleTitle, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                grouping = ("module:\(id)", name, (reference?.modulePosition ?? 0) + 1, "Canvas module order")
            } else if let id = reference?.linkedFromID, let name = reference?.linkedFromTitle, !name.isEmpty {
                grouping = ("canvas-page:\(id)", name, 5_000, externalWebsite ? "Linked from course website" : "Linked from Canvas")
            } else if let id = reference?.folderID, let name = reference?.folderTitle, !name.isEmpty {
                grouping = ("folder:\(id)", name, 7_500, externalWebsite ? "Course website" : "Canvas folder")
            } else {
                grouping = (analysis.categoryID, analysis.categoryTitle, 10_000 + analysis.categoryOrder,
                    "Grouped by content, document headings and file metadata")
            }
            let changed = reference.flatMap { ref in
                course.catalogChanges?.added.contains(ref.id) == true
                    ? "New" : course.catalogChanges?.updated.contains(ref.id) == true ? "Updated" : nil
            }
            let update = document.map { saved in
                reference.map { !$0.version.isEmpty && $0.version != saved.sourceVersion } ?? false
            } ?? false
            let entry = StudyMaterialEntry(
                id: document.map { "saved:\($0.id)" } ?? "canvas:\(reference!.id)", title: title,
                documentID: document?.id, materialID: reference?.id,
                sourceURL: reference?.sourceURL ?? document?.sourceURL,
                symbol: document?.kind.symbol ?? reference?.symbol ?? "doc.text",
                detail: document.map {
                    "\($0.pageCount) \([StudyDocumentKind.office, .notebook, .code].contains($0.kind) ? "sections" : "pages") · Saved offline"
                } ?? reference?.unavailableReason ?? "Download to read",
                badge: update ? "Update available" : changed, updateAvailable: update,
                order: reference?.moduleItemPosition ?? Int.max,
                submissionStatus: reference?.assignment?.status,
                requiresSubmission: reference?.assignment?.requiresSubmission, assignment: reference?.assignment,
                categoryID: analysis.categoryID, categoryTitle: analysis.categoryTitle,
                classificationConfidence: analysis.confidence, classificationBasis: analysis.basis,
                topic: analysis.topic, extractionMethod: analysis.extractionMethod,
                canvasHeading: reference?.linkedFromTitle ?? reference?.moduleSection,
                canvasSubheading: reference?.linkedSection, linkedPosition: reference?.linkedPosition,
                linkedOrder: reference?.linkedOrder)
            guard matches(entry, reference: reference, query: needle) else { return }
            if groups[grouping.0] == nil {
                groups[grouping.0] = StudyMaterialGroup(
                    id: grouping.0, title: grouping.1, basis: grouping.3, order: grouping.2, items: [])
            }
            groups[grouping.0]?.items.append(entry)
        }
        for reference in materials { add(document: saved[reference.id], reference: reference) }
        for document in course.documents where document.sourceKey.flatMap({ references[$0] }) == nil {
            add(document: document, reference: nil)
        }
        return groups.values.map { group in
            var sorted = group
            // Parse teaching numbers once per row, not on every sort comparison.
            let numbers = ["lectures", "exercises"].contains(group.id)
                ? Dictionary(group.items.map { ($0.id, teachingNumber($0.title, group: group.id)) },
                    uniquingKeysWith: { first, _ in first }) : [:]
            sorted.items.sort {
                if $0.order != $1.order { return $0.order < $1.order }
                if $0.linkedOrder != $1.linkedOrder { return ($0.linkedOrder ?? []).lexicographicallyPrecedes($1.linkedOrder ?? []) }
                if $0.linkedPosition != $1.linkedPosition { return ($0.linkedPosition ?? -1) < ($1.linkedPosition ?? -1) }
                if !numbers.isEmpty {
                    let left = numbers[$0.id] ?? .max
                    let right = numbers[$1.id] ?? .max
                    if left != right { return left < right }
                }
                let comparison = $0.title.localizedStandardCompare($1.title)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
            return sorted
        }.sorted {
            $0.order == $1.order
                ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.order < $1.order
        }
    }

    static func filterGroups(_ groups: [StudyMaterialGroup], query: String,
                             references: [String: CanvasMaterialReference]) -> [StudyMaterialGroup] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            var filtered = group
            filtered.items = group.items.filter { matches($0, reference: references[$0.materialID ?? ""], query: needle) }
            return filtered.items.isEmpty ? nil : filtered
        }
    }

    private static func matches(_ entry: StudyMaterialEntry, reference: CanvasMaterialReference?, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [entry.title, reference?.fileName ?? "", reference?.moduleTitle ?? "",
            reference?.moduleSection ?? "", reference?.folderTitle ?? "",
            reference?.linkedFromTitle ?? "", reference?.linkedSection ?? "",
            entry.categoryTitle, entry.topic ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(query)
    }

    /// A flat inventory of original files, including remote files and course assets.
    /// Reuse the organized entries so downloaded Canvas files appear only once.
    static func files(for course: StudyCourse, query: String = "", groups: [StudyMaterialGroup]? = nil) -> [StudyMaterialEntry] {
        let references = Dictionary(course.materials.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let documents = Dictionary(course.documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (groups ?? self.groups(for: course)).flatMap(\.items).compactMap { entry in
            let reference = entry.materialID.flatMap { references[$0] }
            let document = entry.documentID.flatMap { documents[$0] }
            if let reference {
                guard reference.kind == .files else { return nil }
            } else if let sourceKey = document?.sourceKey, !sourceKey.hasPrefix("files:") {
                return nil
            }
            var file = entry
            let ext = document.map { URL(fileURLWithPath: $0.fileName).pathExtension } ?? ""
            let localName =
                document?.originalFileName
                ?? (ext.isEmpty || entry.title.lowercased().hasSuffix(".\(ext.lowercased())")
                    ? entry.title : "\(entry.title).\(ext)")
            file.title = reference?.fileName.flatMap { $0.isEmpty ? nil : $0 } ?? localName
            guard needle.isEmpty || [file.title, entry.title, entry.categoryTitle, entry.topic ?? "",
                reference?.moduleTitle ?? "", reference?.folderTitle ?? "", entry.canvasHeading ?? "", entry.canvasSubheading ?? ""].joined(separator: " ")
                .localizedCaseInsensitiveContains(needle) else { return nil }
            return file
        }.sorted {
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// Explicit lecture/exercise numbers are reliable even with prefixes such
    /// as demo_forel5 or lf_oving3. Canvas module order remains authoritative.
    private static let lectureNumber = try! NSRegularExpression(pattern: "\\b(?:forel|forelesning|lecture|lec|l)[ -]*(\\d+)\\b")
    private static let exerciseNumber = try! NSRegularExpression(pattern: "\\b(?:oving|øving|exercise|assignment|lab)[ -]*(\\d+)\\b")

    private static func teachingNumber(_ title: String, group: String) -> Int {
        let text = title.lowercased().replacingOccurrences(of: "_", with: " ")
        let expression = group == "lectures" ? lectureNumber : exerciseNumber
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            let range = Range(match.range(at: 1), in: text)
        else { return .max }
        return Int(text[range]) ?? .max
    }

    static func category(title: String, fileName: String?, kind: CanvasMaterialKind?, documentKind: StudyDocumentKind?)
        -> (String, String, Int)
    {
        let result = StudyMaterialClassifier.analyze(title: title, fileName: fileName, kind: documentKind, materialKind: kind)
        return (result.categoryID, result.categoryTitle, result.categoryOrder)
    }
}
