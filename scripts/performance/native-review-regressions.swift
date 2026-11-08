import AppKit
import Foundation
@testable import ScholiaMac

// Independent checks of public behavior against the production release objects.
// Run with scripts/macos/run-release-check.sh after the release app is built.
private final class DraftWriteControl: @unchecked Sendable {
    private let lock = NSLock()
    private var failedIDs = Set<UUID>()
    private var shouldBlock = true
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func waitForWrite() -> Bool { entered.wait(timeout: .now() + 5) == .success }

    func fail(_ id: UUID, _ value: Bool) {
        lock.withLock { () -> Void in
            if value { failedIDs.insert(id) } else { failedIDs.remove(id) }
        }
    }
    func write(_ data: Data, _ url: URL) throws {
        let draft = try JSONDecoder().decode(StudyEditDraft.self, from: data)
        let block = lock.withLock {
            let block = shouldBlock
            shouldBlock = false
            return block
        }
        if block {
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else {
                throw StudyError.message("Test write barrier timed out")
            }
        }
        if lock.withLock({ failedIDs.contains(draft.documentID) }) {
            throw StudyError.message("Injected write failure for \(draft.documentID)")
        }
        try data.write(to: url, options: .atomic)
    }
}

@main struct NativeReviewRegressions {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-native-review-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var failures: [String] = []
        func check(_ result: Bool, _ description: String) {
            if !result { failures.append(description); print("FAIL \(description)") }
        }

        let store = StudyLibraryStore(root: root)
        let document = try StudyDocumentImporter.read(data: Data("Original reading".utf8), name: "reading.txt", store: store)
        let control = DraftWriteControl()
        let writer = StudyEditDraftWriter(root: root, write: { try control.write($0, $1) })
        let failedID = UUID(), otherID = UUID()
        func draft(_ id: UUID, _ text: String) -> StudyEditDraft {
            StudyEditDraft(documentID: id, revision: "review", source: text, cells: [])
        }
        func saved(_ id: UUID) throws -> StudyEditDraft {
            try JSONDecoder().decode(StudyEditDraft.self,
                from: Data(contentsOf: root.appendingPathComponent("Editing/\(id).json")))
        }
        writer.save(draft(document.id, "in-flight draft")) { _, _ in }
        check(control.waitForWrite(), "Writer must start its gated save")
        writer.save(draft(document.id, "superseded pending draft")) { _, _ in }
        writer.remove(document.id) { _, _ in }
        control.fail(failedID, true)
        writer.save(draft(failedID, "retry this draft")) { _, _ in }
        writer.save(draft(otherID, "independent document")) { _, _ in }
        let recovery = Task { try await writer.recover(document, store: store) }
        await Task.yield()
        control.release.signal()
        do {
            try writer.flush()
            check(false, "Flush must report an unpersisted draft")
        } catch {
            check(error.localizedDescription.contains(failedID.uuidString), "Flush identifies the failed document")
            check(!error.localizedDescription.contains(otherID.uuidString), "Successful document is absent from failure report")
        }
        check(try saved(otherID).source == "independent document", "One failed document must not prevent another save")
        check(try await recovery.value.source == "Original reading", "Recovery following tombstone must read original content")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Editing/\(document.id).json").path),
            "Pending tombstone must follow an already-running save")
        control.fail(failedID, false)
        writer.retry()
        try writer.flush()
        check(try saved(failedID).source == "retry this draft", "Retry persists the latest failed draft")
        control.fail(failedID, true)
        writer.save(draft(failedID, "obsolete failure")) { _, _ in }
        do { try writer.flush(); check(false, "Injected repeat failure must reach flush") } catch {}
        writer.remove(failedID) { _, _ in }
        writer.retry()
        try writer.flush()
        writer.retry()
        try writer.flush()
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Editing/\(failedID).json").path),
            "Retry must not resurrect a superseded failed save after removal")
        print("CHECKED ordered writes, tombstones, recovery, retry, flush and document failure isolation")

        var documents: [StudyDocument] = []
        for index in 0..<75 {
            var value = document
            value.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 75 - index))!
            value.title = "Reading \(index)"
            value.lastOpenedAt = index % 9 == 0 ? nil : Date(timeIntervalSince1970: Double(index % 7))
            documents.append(value)
        }
        let readingCourses = [StudyCourse(name: "First", code: "A", documents: Array(documents.prefix(35))),
            StudyCourse(name: "Second", code: "B", documents: Array(documents.suffix(40)))]
        let reference = readingCourses.flatMap { course in
            course.documents.filter { $0.lastOpenedAt != nil }
        }.sorted {
            if $0.lastOpenedAt != $1.lastOpenedAt { return $0.lastOpenedAt! > $1.lastOpenedAt! }
            return $0.id.uuidString < $1.id.uuidString
        }
        for limit in [-1, 0, 1, 2, 3, 12, 100] {
            let actual = StudyRecentReading.inCourses(readingCourses, limit: limit)
            check(actual.map(\.id) == Array(reference.prefix(max(0, limit))).map(\.id),
                "Recent reading top-k equals full-sort reference for limit \(limit), including timestamp ties")
        }
        print("CHECKED recent reading bounded selection against full-sort reference")

        let catalog = StudyCourseCatalog()
        var catalogCourses = [StudyCourse(name: "Course 10", code: "TEN", documents: [document]),
            StudyCourse(name: "Course 2", code: "TWO")]
        let locale = Locale(identifier: "en_US")
        check(catalog.indices(in: catalogCourses, locale: locale) == [1, 0], "Catalog preserves numeric course-name ordering")
        let catalogBuilds = catalog.rebuildCount
        catalogCourses[0].documents[0].title = "Fresh current document"
        _ = catalog.indices(in: catalogCourses, locale: locale)
        check(catalog.rebuildCount == catalogBuilds, "Current document changes must not rebuild course ordering")
        catalogCourses[0].favorite = true
        check(catalog.indices(in: catalogCourses, locale: locale) == [0, 1], "Favoriting invalidates cached ordering")
        catalogCourses[0].term = "Spring 2030"
        check(catalog.indices(in: catalogCourses, query: "spring 2030", locale: locale) == [0], "Term changes invalidate cached search metadata")
        catalogCourses[1].name = "Électronique"
        check(catalog.indices(in: catalogCourses, query: "electronique", locale: locale) == [1], "Renames invalidate accent-insensitive search")
        catalogCourses.removeFirst()
        check(catalog.indices(in: catalogCourses, query: "electronique", locale: locale) == [0], "Removal invalidates cached indices")
        let beforeLocale = catalog.rebuildCount
        _ = catalog.indices(in: catalogCourses, locale: Locale(identifier: "nb_NO"))
        check(catalog.rebuildCount == beforeLocale + 1, "Locale change rebuilds cached course ordering")
        print("CHECKED metadata cache invalidation without retaining document content")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let references: [CanvasMaterialReference] = (0..<235).map { index in
            let due = now.addingTimeInterval(Double(index - 150) * 3_600)
            return CanvasMaterialReference(id: "assignments:\(index)", kind: .assignments, remoteID: "\(index)",
                title: "Exercise \(index)", sourceURL: "https://canvas.review.test/assignments/\(index)", version: "1",
                assignment: CanvasAssignmentDetails(record: ["due_at": due.ISO8601Format(),
                    "submission_types": ["online_upload"], "submission": ["workflow_state": "unsubmitted"]]))
        }
        let assignmentCourse = StudyCourse(name: "Exercises", code: "TEST", canvasMaterials: references)
        let groups = StudyAssignmentGroup.make(courses: [assignmentCourse], filter: .due, now: now)
        let allIDs = groups.flatMap(\.items).map(\.id)
        var pagedIDs: [String] = []
        for offset in stride(from: 0, to: allIDs.count, by: 100) {
            let page = StudyAssignmentGroup.slice(groups, offset: offset, limit: 100).flatMap(\.items)
            check(page.count <= 100, "Assignment page remains bounded")
            pagedIDs += page.map(\.id)
        }
        check(pagedIDs == allIDs && Set(pagedIDs).count == 235, "Assignment pages preserve every matching row in original order")
        check(StudyAssignmentGroup.slice(groups, offset: 500, limit: 100).isEmpty, "Out-of-range assignment page is empty")
        let preview = StudyAssignmentGroup.preview(groups, limit: 12, now: now).flatMap(\.items)
        let expectedPreview = groups.flatMap(\.items).sorted {
            let left = abs(($0.dueDate ?? .distantFuture).timeIntervalSince(now))
            let right = abs(($1.dueDate ?? .distantFuture).timeIntervalSince(now))
            return left == right ? $0.id < $1.id : left < right
        }.prefix(12)
        check(preview.count == 12 && Set(preview.map(\.id)) == Set(expectedPreview.map(\.id)),
            "Preview is exactly the nearest twelve deadlines, including equal-distance ties")
        print("CHECKED complete assignment paging and nearest-deadline preview")

        var canvasCourse = StudyCourse(name: "Review course", code: "REVIEW", documents: [document], canvasID: 1)
        canvasCourse.canvasOrigin = "https://canvas.review.test"
        canvasCourse.canvasUserID = 7
        var library = StudyLibrary(courses: [canvasCourse])
        library.canvasOrigin = "https://canvas.review.test"
        library.canvasUserID = 7
        try store.save(library)
        let workspace = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in
            try await Task.sleep(for: .milliseconds(120))
            throw StudyError.message("Injected connection failure")
        })
        workspace.classificationTask?.cancel()
        let dashboard = StudyDashboardState(workspace: workspace)
        let agenda = StudyAssignmentAgendaState(workspace: workspace)
        let projectionBuilds = agenda.projectionBuildCount
        let initialRevision = dashboard.revision
        workspace.library.courses[0].threads.append(StudyThread(mode: .explain))
        workspace.library.courses[0].threads[0].draft = "A chat draft"
        workspace.library.courses[0].threads[0].messages.append(ConversationMessage(role: .assistant, content: ""))
        for index in 0..<12 {
            workspace.library.courses[0].threads[0].messages[0].content += " token \(index)"
            workspace.canvasStatus = "Download progress \(index)"
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(20))
        check(dashboard.revision == initialRevision, "Streamed content, drafts and download status cannot publish a dashboard revision")
        check(agenda.projectionBuildCount == projectionBuilds, "Streamed content, drafts and download status cannot rebuild the assignment projection")
        check(workspace.canUpdateCanvasCourseContent(canvasCourse), "Canvas fixture starts eligible for update")
        let connection = Task { await workspace.checkCanvasConnection() }
        try await Task.sleep(for: .milliseconds(30))
        check(!workspace.canUpdateCanvasCourseContent(canvasCourse), "Connection check temporarily disables update")
        check(dashboard.revision > initialRevision, "Dashboard observes Canvas eligibility changes before connection completes")
        let checkingRevision = dashboard.revision
        _ = await connection.value
        try await Task.sleep(for: .milliseconds(20))
        check(workspace.canUpdateCanvasCourseContent(canvasCourse), "Non-auth connection failure restores update eligibility")
        check(dashboard.revision > checkingRevision, "Dashboard observes restored Canvas eligibility")
        workspace.showAssignments(query: "Exercise 23", filter: .graded)
        check(workspace.assignmentViewQuery == "Exercise 23" && workspace.assignmentViewFilter == .graded,
            "View all preserves its originating query and filter")

        let editing = StudyEditingState(store: store)
        editing.drafts[document.id] = draft(document.id, "Unsaved user changes")
        workspace.canvasBusy = true
        editing.save(document.id, workspace: workspace)
        for _ in 0..<100 where editing.isBusy(document.id) { try await Task.sleep(for: .milliseconds(5)) }
        editing.flushAndWait()
        try await Task.sleep(for: .milliseconds(30))
        check(editing.drafts[document.id]?.source == "Unsaved user changes", "Rejected document save preserves editable draft")
        check(editing.documentErrors[document.id]?.contains("Wait for the current") == true,
            "Successful backup must not erase a failed Save changes error")
        check(editing.error?.contains("Wait for the current") == true,
            "Failed Save changes remains visible after backup completion")
        workspace.canvasBusy = false
        workspace.flush()
        print("CHECKED dashboard observation, assignment filters and durable save error visibility")
        if !failures.isEmpty { throw StudyError.message(failures.joined(separator: "\n")) }
        print("PASS independent native review regressions")
    }
}
