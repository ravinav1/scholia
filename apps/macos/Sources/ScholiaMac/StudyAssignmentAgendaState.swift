import Combine
import Foundation

/// The agenda needs assignment content, not downloads, chat drafts or sync
/// progress. Keep a small comparable projection instead of observing every
/// change in the workspace and rebuilding hundreds of rows each time.
struct StudyAssignmentAgendaInput: Equatable, Sendable {
    struct Course: Equatable, Sendable {
        var id: UUID
        var name: String
        var code: String
        var term: String?
        var canvasID: Int?
        var assignments: [CanvasMaterialReference]
        var hiddenIDs: [String]?
        var progress: [String: StudyAssignmentProgress]?

        var studyCourse: StudyCourse {
            StudyCourse(id: id, name: name, code: code, canvasID: canvasID,
                canvasMaterials: assignments, term: term, hiddenAssignmentIDs: hiddenIDs,
                assignmentProgress: progress)
        }
    }
    var courses: [Course]
    var incomplete: Bool
    var hasCanvasCourses: Bool
    var error: String?

    init(_ library: StudyLibrary) {
        var incomplete = false
        courses = library.courses.map { course in
            let assignments = (course.canvasMaterials ?? []).filter { $0.kind == .assignments }
            if course.canvasID != nil {
                incomplete = incomplete || course.catalogUpdatedAt == nil
                    || (course.catalogWarnings ?? []).contains { $0.localizedCaseInsensitiveContains("assignments:") }
                    || assignments.contains {
                        $0.assignment == nil
                            || (course.assignmentProgress?[$0.id]?.status ?? $0.assignment?.status) == .unknown
                    }
            }
            return Course(id: course.id, name: course.name, code: course.code, term: course.term,
                canvasID: course.canvasID, assignments: assignments,
                hiddenIDs: course.hiddenAssignmentIDs, progress: course.assignmentProgress)
        }
        self.incomplete = incomplete
        hasCanvasCourses = library.courses.contains { $0.canvasID != nil }
        error = library.canvasAssignmentsError
    }
}

@MainActor
final class StudyAssignmentAgendaState: ObservableObject {
    @Published private(set) var input: StudyAssignmentAgendaInput
    private var observation: AnyCancellable?
    private struct Source: Equatable {
        var metadata: StudyCourseCatalog.Input
        var canvasID: Int?
        var materials: [CanvasMaterialReference]?
        var hidden: [String]?
        var progress: [String: StudyAssignmentProgress]?
        var indexed: Bool
        var warnings: [String]?
        init(_ course: StudyCourse) {
            metadata = StudyCourseCatalog.Input(course); canvasID = course.canvasID
            materials = course.canvasMaterials; hidden = course.hiddenAssignmentIDs
            progress = course.assignmentProgress; indexed = course.catalogUpdatedAt != nil
            warnings = course.catalogWarnings
        }
    }
    private var sources: [Source]
    private var sourceError: String?
    private(set) var projectionBuildCount = 1
    private struct GroupKey: Equatable {
        var query: String
        var filter: StudyAssignmentFilter
        var minute: Int64
    }
    private var groupCache: [(GroupKey, [StudyAssignmentGroup])] = []
    private var countCache: (Int, Int)?
    private(set) var groupingBuildCount = 0

    /// Keep the minute-granularity deadline projection across dashboard visits.
    /// A small bounded cache lets the full list and preview share common filters.
    func groups(query: String, filter: StudyAssignmentFilter, now: Date) -> [StudyAssignmentGroup] {
        let key = GroupKey(query: query, filter: filter, minute: Int64(now.timeIntervalSince1970 / 60))
        if let cached = groupCache.first(where: { $0.0 == key }) { return cached.1 }
        let result = StudyAssignmentGroup.make(courses: input.courses.map(\.studyCourse), query: query, filter: filter, now: now)
        groupingBuildCount += 1
        groupCache.insert((key, result), at: 0)
        if groupCache.count > 4 { groupCache.removeLast() }
        return result
    }
    var submissionCounts: (Int, Int) {
        if let countCache { return countCache }
        let assignments = StudyAssignment.list(courses: input.courses.map(\.studyCourse), includeCompleted: true)
        let counts = (assignments.filter { $0.details?.status == .submitted }.count,
            assignments.filter { $0.details?.status == .graded }.count)
        countCache = counts
        return counts
    }

    init(workspace: StudyWorkspaceModel) {
        input = StudyAssignmentAgendaInput(workspace.library)
        sources = workspace.library.courses.map(Source.init)
        sourceError = workspace.library.canvasAssignmentsError
        observation = workspace.$library.dropFirst().sink { [weak self] library in
            guard let self else { return }
            // Shared Array storage makes the unchanged-material comparison cheap.
            // Do not re-filter every course's files on each streamed token.
            let nextSources = library.courses.map(Source.init)
            guard nextSources != sources || sourceError != library.canvasAssignmentsError else { return }
            sources = nextSources
            sourceError = library.canvasAssignmentsError
            projectionBuildCount += 1
            let next = StudyAssignmentAgendaInput(library)
            if next != input {
                groupCache.removeAll()
                countCache = nil
                input = next
            }
        }
    }
}
