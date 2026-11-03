import Foundation

/// A separate baseline survives catalog refreshes, failed downloads and app restarts.
/// Only newly discovered file IDs enter this queue; old on-demand readings stay on demand.
struct CanvasCourseFileSync: Codable, Equatable, Sendable {
    var knownFileIDs: [String]?
    var pendingFileIDs: [String] = []
    var checkedAt: Date?
    var downloadAttemptedAt: Date?
    var error: String?
    var summary: String?

    static let checkInterval: TimeInterval = 5 * 60

    static func baseline(for course: StudyCourse) -> Self {
        course.canvasFileSync ?? Self(knownFileIDs: course.canvasMaterials.map { materials in
            materials.filter { $0.kind == .files }.map(\.id)
        })
    }

    static func reconcile(course: StudyCourse, catalog: CanvasMaterialCatalog, now: Date) -> Self {
        var state = baseline(for: course)
        let listed = Set(catalog.items.filter { $0.kind == .files }.map(\.id))
        let known = state.knownFileIDs.map(Set.init)
        let added = known.map { listed.subtracting($0) } ?? []
        let saved = Set(course.documents.compactMap(\.sourceKey))
        // Absence can mean a temporary lock or hidden module, not deletion.
        let pending = Set(state.pendingFileIDs).union(added).subtracting(saved)
        state.knownFileIDs = Array((known ?? []).union(listed)).sorted()
        state.pendingFileIDs = pending.sorted()
        state.checkedAt = now
        state.error = catalog.warnings.isEmpty ? nil : catalog.warnings.joined(separator: "\n")
        state.summary = known == nil ? "File list ready. Watching for new uploads."
            : pending.isEmpty ? "No new files to download."
            : "\(pending.count) new \(pending.count == 1 ? "file" : "files") waiting to download."
        return state
    }

    func needsCheck(at now: Date, downloadAutomatically: Bool) -> Bool {
        now.timeIntervalSince(checkedAt ?? .distantPast) >= Self.checkInterval
            || (downloadAutomatically && !pendingFileIDs.isEmpty
                && now.timeIntervalSince(downloadAttemptedAt ?? .distantPast) >= Self.checkInterval)
    }
}
