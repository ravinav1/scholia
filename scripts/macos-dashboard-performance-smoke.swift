import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI
@testable import ScholiaMac

@main @MainActor
struct DashboardPerformanceSmoke {
    static func cpuSeconds() -> Double {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); fflush(nil); exit(0) }
            catch { print("FAIL: \(error)"); fflush(nil); exit(1) }
        }
        app.run()
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-dashboard-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = "https://canvas.dashboard.test"
        var courses: [StudyCourse] = []
        for courseID in 1...89 {
            let materials = (1...70).map { materialID -> CanvasMaterialReference in
                let assignment = materialID <= 5
                return CanvasMaterialReference(id: "\(assignment ? "assignments" : "files"):\(materialID)",
                    kind: assignment ? .assignments : .files, remoteID: String(materialID),
                    title: "Material \(materialID)",
                    sourceURL: "\(origin)/courses/\(courseID)/\(assignment ? "assignments" : "files")/\(materialID)",
                    version: "fixture", assignment: assignment
                        ? CanvasAssignmentDetails(record: ["submission_types": ["online_upload"],
                            "due_at": "2026-11-01T12:00:00Z", "submission": ["workflow_state": "unsubmitted"]]) : nil)
            }
            courses.append(StudyCourse(name: "Course \(90 - courseID)", code: "TTK\(4000 + courseID)-26H",
                canvasID: courseID, canvasOrigin: origin, canvasUserID: 42, canvasMaterials: materials,
                catalogUpdatedAt: Date(), term: "2026 Autumn",
                assignmentProgress: ["assignments:1": .handedIn]))
        }
        let store = StudyLibraryStore(root: root)
        try store.save(StudyLibrary(courses: courses, selectedCourseID: courses[0].id,
            canvasOrigin: origin, canvasUserID: 42, showingCourseLibrary: true))
        let workspace = StudyWorkspaceModel(store: store,
            completionStore: StudyCourseCompletionStore(load: { _ in nil }, save: { _ in }),
            canvasClientFactory: { _, _, _ in throw URLError(.notConnectedToInternet) })
        await workspace.loadCourseCompletions()
        let eligible = workspace.library.courses[0]
        precondition(workspace.canUpdateCanvasCourseContent(eligible.id))
        precondition(!workspace.canUpdateCanvasCourseContent(UUID()), "A nonexistent course is not eligible")
        workspace.canvasSigningIn = true
        precondition(!workspace.canUpdateCanvasCourseContent(eligible.id), "Sign-in must disable updates")
        workspace.canvasSigningIn = false
        workspace.library.canvasUserID = nil
        precondition(!workspace.canUpdateCanvasCourseContent(eligible.id), "No connected user must disable updates")
        workspace.library.canvasUserID = 43
        precondition(!workspace.canUpdateCanvasCourseContent(eligible.id), "A different user must not update old courses")
        workspace.library.canvasUserID = 42
        workspace.library.canvasOrigin = "https://different.dashboard.test"
        precondition(!workspace.canUpdateCanvasCourseContent(eligible.id), "A different Canvas origin must be rejected")
        workspace.library.canvasOrigin = origin
        workspace.library.courses[1].canvasID = nil
        precondition(!workspace.canUpdateCanvasCourseContent(courses[1].id), "A local course cannot be updated from Canvas")
        workspace.library.courses[1] = courses[1]
        workspace.canvasBusy = true
        precondition(workspace.canUpdateCanvasCourseContent(eligible.id), "Busy sync must still allow queuing")
        workspace.updateCanvasCourseContent(courseIDs: [eligible.id, eligible.id])
        precondition(workspace.queuedCanvasCourseUpdateIDs == [eligible.id], "The queue must deduplicate updates")
        precondition(!workspace.canUpdateCanvasCourseContent(eligible.id), "Queued courses must be disabled")
        precondition(workspace.canUpdateCanvasCourseContent(courses[1].id), "Other courses remain eligible")
        workspace.canvasBusy = false
        print("PASS: course eligibility preserves connected-account, missing-course, sign-in and queue semantics")

        let cardCourse = workspace.library.courses[1]
        let cardBefore = StudyCourseLibraryCard(workspace: workspace, course: cardCourse)
        workspace.canvasStatus = "Unrelated progress update"
        precondition(cardBefore == StudyCourseLibraryCard(workspace: workspace, course: cardCourse),
            "Unrelated background status must not invalidate a course card")
        var changedCourse = cardCourse
        changedCourse.canvasMaterials?[0].title = "Updated assignment contents"
        precondition(cardBefore == StudyCourseLibraryCard(workspace: workspace, course: changedCourse),
            "Material contents alone must not invalidate a card showing only counts")
        changedCourse.favorite = true
        precondition(cardBefore != StudyCourseLibraryCard(workspace: workspace, course: changedCourse),
            "The favorite indicator must update")
        changedCourse = cardCourse
        changedCourse.canvasMaterials?.removeLast()
        precondition(cardBefore != StudyCourseLibraryCard(workspace: workspace, course: changedCourse),
            "The material count must update")
        workspace.canvasSigningIn = true
        precondition(cardBefore != StudyCourseLibraryCard(workspace: workspace, course: cardCourse),
            "Update eligibility must refresh the course controls")
        workspace.canvasSigningIn = false
        workspace.canvasBusy = true
        precondition(cardBefore != StudyCourseLibraryCard(workspace: workspace, course: cardCourse),
            "Busy state must refresh the course controls")
        workspace.canvasBusy = false
        print("PASS: course cards ignore irrelevant status/content changes and refresh visible fields and controls")

        let originalLibrary = workspace.library
        let agenda = StudyAssignmentAgendaState(workspace: workspace)
        var agendaPublications = 0
        let agendaObservation = agenda.$input.dropFirst().sink { _ in agendaPublications += 1 }
        workspace.canvasStatus = "Another unrelated status"
        workspace.library.courses[1].canvasMaterials?[10].title = "Updated file title"
        workspace.library.canvasAssignmentsCheckedAt = Date()
        precondition(agendaPublications == 0, "Status, non-assignment files and last-check metadata must not republish the agenda")
        func checkProjection() {
            let projected = agenda.input.courses.map(\.studyCourse)
            let actualRows = StudyAssignment.list(courses: workspace.library.courses,
                includeCompleted: true, includeHidden: true, includeNonSubmission: true)
            let projectedRows = StudyAssignment.list(courses: projected,
                includeCompleted: true, includeHidden: true, includeNonSubmission: true)
            precondition(actualRows.map(\.id) == projectedRows.map(\.id))
            precondition(zip(actualRows, projectedRows).allSatisfy { actual, projected in
                actual.material == projected.material && actual.dueDate == projected.dueDate
                    && actual.isHidden == projected.isHidden && actual.course.name == projected.course.name
                    && actual.course.code == projected.course.code && actual.course.term == projected.course.term
            }, "The reduced agenda must preserve status, dates, grades, feedback, names and local overrides")
            for filter in [StudyAssignmentFilter.due, .all, .hidden, .handedIn, .graded, .archive] {
                let actualGroups = StudyAssignmentGroup.make(courses: workspace.library.courses, filter: filter)
                let projectedGroups = StudyAssignmentGroup.make(courses: projected, filter: filter)
                precondition(actualGroups.map(\.id) == projectedGroups.map(\.id))
                precondition(actualGroups.map { $0.items.map(\.id) } == projectedGroups.map { $0.items.map(\.id) })
            }
        }
        func expectAgendaChange(_ change: () -> Void) {
            let before = agendaPublications
            change()
            precondition(agendaPublications == before + 1, "An assignment-affecting change must update the agenda once")
            checkProjection()
        }
        checkProjection()
        expectAgendaChange { workspace.library.courses[1].canvasMaterials?[0].title = "Updated assignment" }
        expectAgendaChange { workspace.library.courses[1].canvasMaterials?[1].assignment?.status = .graded }
        expectAgendaChange { workspace.library.courses[1].hiddenAssignmentIDs = ["assignments:3"] }
        expectAgendaChange { workspace.library.courses[1].assignmentProgress?["assignments:1"] = .graded }
        expectAgendaChange { workspace.library.canvasAssignmentsError = "Fixture refresh error" }
        precondition(agenda.input.error == "Fixture refresh error")
        expectAgendaChange { workspace.library.courses[1].catalogUpdatedAt = nil }
        precondition(agenda.input.incomplete)
        agendaObservation.cancel()
        workspace.library = originalLibrary
        print("PASS: selective agenda updates preserve all assignment filters/content while ignoring unrelated progress and files")

        for course in workspace.library.courses {
            precondition(workspace.canUpdateCanvasCourseContent(course) == workspace.canUpdateCanvasCourseContent(course.id))
        }
        let predicateStart = cpuSeconds()
        var checks = 0
        for _ in 0..<20 {
            for course in workspace.library.courses {
                if workspace.canUpdateCanvasCourseContent(course) { checks += 1 }
            }
        }
        let predicateCPU = cpuSeconds() - predicateStart
        precondition(checks == 20 * 88)
        precondition(predicateCPU < 0.3, "Eligibility checks must not sort all 89 courses per card")
        print("PASS: 1,780 eligibility checks use \(predicateCPU) CPU seconds")

        // Reproduce the old hot path with the retained sorted-list getter, so
        // the performance test demonstrates the cost it is guarding against.
        let legacyStart = cpuSeconds()
        var legacyChecks = 0
        for _ in 0..<20 {
            for course in workspace.library.courses {
                if !workspace.queuedCanvasCourseUpdateIDs.contains(course.id)
                    && workspace.canvasUpdatableCourses.contains(where: { $0.id == course.id }) {
                    legacyChecks += 1
                }
            }
        }
        let legacyCPU = cpuSeconds() - legacyStart
        precondition(legacyChecks == checks)
        precondition(predicateCPU < legacyCPU * 0.5,
            "Direct eligibility must materially improve on per-card full-catalog sorting")
        print("BASELINE: the previous eligibility path uses \(legacyCPU) CPU seconds for the same checks")
        fflush(nil)

        let host = NSHostingView(rootView: StudyCourseLibraryView(workspace: workspace, createCourse: {}))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1200, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Scholia 89-course dashboard performance verification"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .seconds(2))
        precondition(window.occlusionState.contains(.visible), "Dashboard performance requires a genuinely visible test window")

        var publications = 0
        let observation = workspace.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        let idleStart = cpuSeconds()
        try await Task.sleep(for: .seconds(2))
        let idleCPU = cpuSeconds() - idleStart
        precondition(publications == 0, "Isolated idle dashboard must not publish background state")
        precondition(idleCPU < 0.4, "Visible dashboard must settle instead of continuously rebuilding cards")
        workspace.canvasBusy = true
        try await Task.sleep(for: .milliseconds(400))
        let busyStart = cpuSeconds()
        try await Task.sleep(for: .seconds(2))
        let busyCPU = cpuSeconds() - busyStart
        precondition(busyCPU < 0.4, "Busy state alone must not continuously redraw the visible dashboard")
        print("PASS: visible 89-course/6,230-material dashboard CPU over 2s: idle=\(idleCPU), busy=\(busyCPU)")
        fflush(nil)

        let profile = Process()
        if CommandLine.arguments.contains("--profile") {
            profile.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            profile.arguments = [String(getpid()), "4", "-file", "/tmp/scholia-dashboard-status-sample.txt"]
            profile.standardOutput = FileHandle.nullDevice
            profile.standardError = FileHandle.nullDevice
            try profile.run()
        }
        let updatesStart = cpuSeconds()
        var longestTick = 0.0
        for index in 0..<20 {
            let start = Date()
            workspace.canvasStatus = "Fixture sync progress \(index)"
            try await Task.sleep(for: .milliseconds(50))
            longestTick = max(longestTick, Date().timeIntervalSince(start))
        }
        let updatesCPU = cpuSeconds() - updatesStart
        print("MEASURE: 20 visible dashboard status updates use \(updatesCPU) CPU seconds; longest 50ms heartbeat=\(longestTick)s")
        fflush(nil)
        while profile.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        precondition(longestTick < 0.3, "Background status updates must not stall the UI for 300ms")
        precondition(updatesCPU < 1.5, "Background status updates must not saturate the main thread")
        print("PASS: background status updates meet CPU and UI heartbeat limits")
    }
}
