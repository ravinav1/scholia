import Foundation

struct CanvasCatalogChanges: Codable, Equatable, Sendable {
    var added: [String] = []
    var updated: [String] = []
    var removed: [String] = []
    var retained: [String] = []
    var count: Int { added.count + updated.count + removed.count }
    var summary: String? {
        let parts = [(added.count, "new"), (updated.count, "updated"), (removed.count, "removed")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func reconcile(previous: [CanvasMaterialReference]?, catalog: CanvasMaterialCatalog) -> (
        items: [CanvasMaterialReference], changes: Self
    ) {
        let old = Dictionary((previous ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var latest = Dictionary(catalog.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changes = Self()
        for (id, reference) in latest {
            guard let prior = old[id] else {
                // First indexing establishes a baseline, rather than calling every item new.
                if previous != nil { changes.added.append(id) }
                continue
            }
            if reference.title != prior.title
                || (!reference.version.isEmpty && !prior.version.isEmpty && reference.version != prior.version)
                || (reference.fileName != nil && prior.fileName != nil && reference.fileName != prior.fileName)
                || (catalog.moduleOrderComplete && prior.moduleID != nil
                    && (reference.moduleID != prior.moduleID || reference.modulePosition != prior.modulePosition
                        || reference.moduleItemPosition != prior.moduleItemPosition
                        || reference.moduleTitle != prior.moduleTitle || reference.moduleSection != prior.moduleSection))
                || (catalog.linkedContentComplete && prior.linkedFromID != nil
                    && (reference.linkedFromID != prior.linkedFromID || reference.linkedFromTitle != prior.linkedFromTitle
                        || reference.linkedOrder != prior.linkedOrder || reference.linkedPosition != prior.linkedPosition
                        || reference.linkedSection != prior.linkedSection))
                || (catalog.foldersComplete && prior.folderTitle != nil && reference.folderTitle != prior.folderTitle)
                || (reference.byteCount != nil && prior.byteCount != nil && reference.byteCount != prior.byteCount)
                || (reference.assignment != nil && reference.assignment != prior.assignment)
            {
                changes.updated.append(id)
            }
            // Module-only listings may omit fields present in a previous successful Files listing.
            var merged = reference
            if merged.version.isEmpty { merged.version = prior.version }
            if merged.fileName == nil { merged.fileName = prior.fileName }
            if merged.byteCount == nil { merged.byteCount = prior.byteCount }
            if merged.assignment == nil { merged.assignment = prior.assignment }
            else { merged.assignment = merged.assignment?.retainingFeedback(from: prior.assignment) }
            if (!catalog.moduleOrderComplete || !catalog.linkedContentComplete) && merged.moduleID == nil {
                merged.copyModuleGrouping(from: prior)
            }
            if (!catalog.moduleOrderComplete || !catalog.linkedContentComplete) && merged.linkedFromID == nil {
                merged.linkedFromID = prior.linkedFromID
                merged.linkedFromTitle = prior.linkedFromTitle
                merged.linkedPosition = prior.linkedPosition
                merged.linkedOrder = prior.linkedOrder
                merged.linkedSection = prior.linkedSection
            }
            if !catalog.foldersComplete && (merged.folderID == nil || merged.folderID == prior.folderID) {
                merged.folderID = prior.folderID
                merged.folderTitle = prior.folderTitle
            }
            latest[id] = merged
        }
        for (id, prior) in old where latest[id] == nil {
            let complete = prior.isMathWiki ? catalog.mathWikiComplete
                : prior.isCourseWebsite ? catalog.courseWebsitesComplete : catalog.completeKinds.contains(prior.kind)
            if complete {
                changes.removed.append(id)
            } else {
                latest[id] = prior
                changes.retained.append(id)
            }
        }
        changes.added.sort()
        changes.updated.sort()
        changes.removed.sort()
        changes.retained.sort()
        let items = latest.values.sorted {
            if ($0.kind == .syllabus) != ($1.kind == .syllabus) { return $0.kind == .syllabus }
            let order = $0.title.localizedStandardCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return (items, changes)
    }
}
