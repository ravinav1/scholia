import AppKit
import Darwin
import SwiftUI
@testable import ScholiaMac

/// Measurements, never timing assertions in CI. The visible component is
/// the production dashboard; all library files and provider clients are isolated.
@main @MainActor
struct NativePerformanceMeasurements {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await NativePerformanceMeasurements().testVisibleDashboardMeasurements(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        app.run()
    }
    @MainActor
    func testVisibleDashboardMeasurements() async throws {
        guard let output = CommandLine.arguments.dropFirst().first ?? ProcessInfo.processInfo.environment["SCHOLIA_NATIVE_PERFORMANCE_OUTPUT"] else {
            throw StudyError.message("Set SCHOLIA_NATIVE_PERFORMANCE_OUTPUT to collect native release measurements")
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        var results: [[String: Any]] = []
        for count in [6, 89, 500] {
            print("Starting \(count)-workspace release measurement"); fflush(nil)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-native-performance-\(UUID())")
            let store = StudyLibraryStore(root: root)
            defer { try? FileManager.default.removeItem(at: root) }
            let fixtureDate = Date(timeIntervalSince1970: 1_794_000_000)
            var courses: [StudyCourse] = []
            for i in 0..<count {
                let assignments = (0..<12).map { j in
                    CanvasMaterialReference(id: "assignments:\(j)", kind: .assignments, remoteID: String(j),
                        title: "Exercise \(j)", sourceURL: "https://fixture.invalid/courses/\(i)/assignments/\(j)", version: "fixture",
                        assignment: CanvasAssignmentDetails(record: ["submission_types": ["online_upload"],
                            "due_at": "2026-11-12T12:00:00Z", "submission": ["workflow_state": "unsubmitted"]]))
                }
                let files = (0..<58).map { j in CanvasMaterialReference(id: "files:\(j)", kind: .files,
                    remoteID: String(j), title: "Reading \(j)", sourceURL: "https://fixture.invalid/\(i)/\(j)", version: "fixture") }
                let documents = (0..<20).map { j in StudyDocument(title: "Reading \(j)", kind: .text,
                    fileName: "reading.txt", pageCount: 120, lastPage: 7, addedAt: fixtureDate,
                    lastOpenedAt: fixtureDate.addingTimeInterval(Double(i * 20 + j))) }
                var course = StudyCourse(name: "Workspace \(count - i)", code: "TEST\(4000 + i)", documents: documents,
                    canvasMaterials: assignments + files, catalogUpdatedAt: fixtureDate, term: i % 2 == 0 ? "2026 Autumn" : "2026 Spring")
                if i == 0 {
                    var thread = StudyThread(documentID: documents[0].id, mode: .explain)
                    thread.messages = (0..<200).map { ConversationMessage(role: $0 % 2 == 0 ? .user : .assistant,
                        content: String(repeating: "Long conversation evidence. ", count: 100)) }
                    course.threads = [thread]
                    let index = StudyDocumentIndex(pages: (1...120).map { StudyPage(number: $0,
                        text: "Page \($0). " + String(repeating: "Deterministic source contents. ", count: 200)) })
                    try store.write(document: documents[0], index: index, data: Data("Fixture reading".utf8))
                }
                courses.append(course)
            }
            try store.save(StudyLibrary(courses: courses, selectedCourseID: courses[0].id, showingCourseLibrary: true))
            let startup = ContinuousClock.now
            let workspace = StudyWorkspaceModel(store: store,
                completionStore: StudyCourseCompletionStore(load: { _ in nil }, save: { _ in }),
                canvasClientFactory: { _, _, _ in throw URLError(.notConnectedToInternet) })
            workspace.classificationTask?.cancel()
            let host = NSHostingView(rootView: MeasurementDashboard(workspace: workspace))
            host.sizingOptions = []
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1280, height: 900),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.level = .floating
            window.center()
            window.orderFrontRegardless()
            for _ in 0..<300 where !window.occlusionState.contains(.visible) {
                try await Task.sleep(for: .milliseconds(10))
            }
            await paint(window)
            let coldMs = milliseconds(startup.duration(to: .now))
            precondition(window.occlusionState.contains(.visible), "Measurement requires a visible test window")
            try await Task.sleep(for: .milliseconds(300))
            var navigation: [Double] = [], filtering: [Double] = [], stalls: [Double] = []
            let cpuBefore = cpu(), residentBefore = resident()
            for i in 0..<33 {
                if startup.duration(to: .now) > .seconds(60) { break }
                workspace.selectCourse(courses[0].id)
                workspace.selectDocument(courses[0].documents[0].id)
                await paint(window)
                let started = ContinuousClock.now
                workspace.showCourseLibrary()
                await paint(window)
                if i >= 3 { navigation.append(milliseconds(started.duration(to: .now))) }
                guard let input = fields(host).first(where: { $0.placeholderString == "Find a workspace" }) else {
                    throw StudyError.message("Production workspace search field is missing")
                }
                window.makeFirstResponder(input)
                let query = i % 2 == 0 ? "TEST40" : ""
                let typed = ContinuousClock.now
                input.stringValue = query
                NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: input)
                await paint(window)
                if i >= 3 { filtering.append(milliseconds(typed.duration(to: .now))) }
                let tick = ContinuousClock.now
                workspace.canvasStatus = "Sync progress \(i)"
                try await Task.sleep(for: .milliseconds(10))
                if i >= 3 { stalls.append(max(0, milliseconds(tick.duration(to: .now)) - 10)) }
            }
            workspace.flush()
            results.append(["workspaces": count, "materials": count * 70, "documents": count * 20,
                "assignmentCount": count * 12, "conversationMessages": 200, "warmup": 3, "samples": navigation.count, "fixtureBudgetSeconds": 60, "completedTargetSamples": navigation.count == 30,
                "coldDashboardMs": coldMs, "returnPaintMs": navigation, "searchPaintMs": filtering,
                "heartbeatDelayMs": stalls, "cpuSeconds": cpu() - cpuBefore,
                "residentBeforeBytes": residentBefore, "residentAfterBytes": resident(),
                "returnP50Ms": percentile(navigation, 0.5), "returnP95Ms": percentile(navigation, 0.95),
                "searchP50Ms": percentile(filtering, 0.5), "searchP95Ms": percentile(filtering, 0.95)])
            try JSONSerialization.data(withJSONObject: ["partial": true, "results": results], options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
            window.close()
            print("Measured \(count) native workspaces"); fflush(nil)
        }
        let report: [String: Any] = ["kind": "native-production-dashboard-component",
            "measurement": "input/model mutation through AppKit displayIfNeeded after a main-runloop turn; excludes compositor scanout and full app shell",
            "configuration": "release", "buildID": ProcessInfo.processInfo.environment["SCHOLIA_BUILD_ID"] ?? "unrecorded", "recordedAt": ISO8601DateFormatter().string(from: Date()), "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processorCount": ProcessInfo.processInfo.processorCount, "physicalMemory": ProcessInfo.processInfo.physicalMemory,
            "results": results]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
    }
    @MainActor private func paint(_ window: NSWindow) async {
        await Task.yield()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }
    @MainActor private func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
    private func percentile(_ samples: [Double], _ p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }; return samples.sorted()[min(samples.count - 1, Int(ceil(Double(samples.count) * p)) - 1)]
    }
    private func cpu() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    private func resident() -> UInt64 {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}

private struct MeasurementDashboard: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    var body: some View {
        if workspace.isShowingLibrary { StudyCourseLibraryView(workspace: workspace, createCourse: {}) }
        else { Text(workspace.currentPageText).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}
