import AppKit
import Combine
import Darwin
import SwiftUI
@testable import ScholiaMac

private struct SyncAnimationFixture: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    var reduceMotion = false
    var body: some View {
        VStack {
            StudySyncStatusIcon(active: workspace.syncActivity.active, needsAttention: false, reduceMotion: reduceMotion)
            StudyAssignmentAgendaView(workspace: workspace, initialFilter: .all, dedicated: true)
        }
        .frame(width: 800, height: 600)
    }
}

@main @MainActor
struct SyncAnimationSmoke {
    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-sync-animation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let materials = (1...400).map { id in
            CanvasMaterialReference(id: "assignments:\(id)", kind: .assignments, remoteID: String(id),
                title: "Fixture assignment \(id)", sourceURL: "https://canvas.fixture.test/assignments/\(id)",
                version: "fixture", assignment: CanvasAssignmentDetails(record: ["submission_types": ["online_upload"],
                    "submission": ["workflow_state": "unsubmitted"]]))
        }
        let course = StudyCourse(name: "Fixture course", canvasMaterials: materials)
        let store = StudyLibraryStore(root: root)
        try store.save(StudyLibrary(courses: [course], selectedCourseID: course.id, showingCourseLibrary: true))
        let workspace = StudyWorkspaceModel(store: store)
        let hosting = NSHostingView(rootView: SyncAnimationFixture(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Scholia sync animation verification"
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        func indicators(in view: NSView) -> [NSProgressIndicator] {
            (view as? NSProgressIndicator).map { [$0] } ?? view.subviews.flatMap { indicators(in: $0) }
        }
        func cpuSeconds() -> Double {
            var usage = rusage()
            precondition(getrusage(RUSAGE_SELF, &usage) == 0)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        try await Task.sleep(for: .seconds(2))
        precondition(indicators(in: hosting).isEmpty, "Idle sync must show the static icon")
        let idleStart = cpuSeconds()
        try await Task.sleep(for: .seconds(1))
        let idleCPU = cpuSeconds() - idleStart
        workspace.canvasBusy = true
        try await Task.sleep(for: .seconds(1))
        precondition(indicators(in: hosting).count == 1, "Active sync must use one native progress indicator")
        precondition(indicators(in: hosting)[0].isAccessibilityElement() == false,
            "The button owns the accessible sync label; its decoration must be hidden")
        var callbacks = 0
        let observation = workspace.objectWillChange.sink { callbacks += 1 }
        let busyStart = cpuSeconds()
        try await Task.sleep(for: .seconds(1))
        let busyCPU = cpuSeconds() - busyStart
        observation.cancel()
        precondition(callbacks == 0, "Animation frames must never publish workspace state")
        precondition(busyCPU < idleCPU + 0.4,
            "Busy sync must not continuously traverse the 400-assignment SwiftUI graph")
        print("PASS: busy sync adds no model callbacks; 1s CPU idle=\(idleCPU), busy=\(busyCPU)")

        hosting.rootView = SyncAnimationFixture(workspace: workspace, reduceMotion: true)
        try await Task.sleep(for: .milliseconds(200))
        precondition(indicators(in: hosting).isEmpty, "Reduce Motion must replace animation with the static busy icon")
        hosting.rootView = SyncAnimationFixture(workspace: workspace)
        workspace.canvasBusy = false
        try await Task.sleep(for: .milliseconds(200))
        precondition(indicators(in: hosting).isEmpty, "Finishing sync must remove and stop the progress indicator")
        print("PASS: Reduce Motion and completed sync remove the native animation")
    }
}
