import Combine
import Foundation

/// This observer owns only values displayed by the dashboard. Token, selection,
/// provider activity and draft changes cannot publish a new dashboard value.
@MainActor
final class StudyDashboardState: ObservableObject {
    private struct Course: Equatable {
        var metadata: StudyCourseCatalog.Input
        var documents: [StudyDocument]
        var materialCount: Int
        var indexed: Bool
        var pending: Int
        var canUpdate: Bool
        var updateTitle: String
        var passed: Bool
        var canvasURL: URL?
    }
    private struct Input: Equatable {
        var courses: [Course]
        var view: StudyCourseLibraryViewMode
        var semester: String
        var exams: [StudyExam]
        var busy: Bool
        var filesRunning: Bool
        var hasCompletions: Bool
        var locale: String
    }
    @Published private(set) var revision = 0
    private var input: Input
    private var observers: [AnyCancellable] = []
    private var scheduled = false
    init(workspace: StudyWorkspaceModel) {
        input = Self.capture(workspace)
        func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
            observers.append(publisher.dropFirst().sink { [weak self, weak workspace] _ in
                guard let self, let workspace, !self.scheduled else { return }
                self.scheduled = true
                Task { @MainActor [weak self, weak workspace] in
                    guard let self, let workspace else { return }
                    self.scheduled = false
                    let next = Self.capture(workspace)
                    if self.input != next { self.input = next; self.revision += 1 }
                }
            })
        }
        observe(workspace.$library)
        observe(workspace.$courseCompletions)
        observe(workspace.$canvasBusy)
        observe(workspace.$canvasSigningIn)
        observe(workspace.$canvasChecking)
        observe(workspace.$canvasNeedsSignIn)
        observe(workspace.$canvasNeedsKeychainAccess)
        observe(workspace.$canvasContentSyncRunning)
        observe(workspace.$canvasActivityCourseID)
        observe(workspace.$canvasFileSyncRunning)
        observe(workspace.$queuedCanvasCourseUpdateIDs)
        observe(workspace.$manualCanvasCourseUpdateID)
        observers.append(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.revision += 1 } })
    }
    private static func capture(_ workspace: StudyWorkspaceModel) -> Input {
        Input(courses: workspace.library.courses.map { course in
            Course(metadata: StudyCourseCatalog.Input(course), documents: course.documents,
                materialCount: course.canvasMaterials?.count ?? 0, indexed: course.catalogUpdatedAt != nil,
                pending: course.canvasFileSync?.pendingFileIDs.count ?? 0,
                canUpdate: workspace.canUpdateCanvasCourseContent(course),
                updateTitle: workspace.canvasCourseUpdateTitle(course.id),
                passed: workspace.coursePassed(course.displayCode) == true, canvasURL: course.canvasURL)
        }, view: workspace.courseLibraryView, semester: workspace.library.selectedSemesterID ?? "all",
            exams: workspace.library.examPlan ?? [], busy: workspace.canvasBusy, filesRunning: workspace.canvasFileSyncRunning,
            hasCompletions: !workspace.courseCompletions.isEmpty, locale: Locale.current.identifier)
    }
}
