import AppKit
import Darwin
import SwiftUI
@testable import ScholiaMac

private final class StartupRequestLog: @unchecked Sendable {
    static let shared = StartupRequestLog()
    private let lock = NSLock()
    private var requests = 0
    func record() { lock.withLock { requests += 1 } }
    var count: Int { lock.withLock { requests } }
}

private final class StartupNoNetworkProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        StartupRequestLog.shared.record()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// Fresh-process startup observations, not a packaged-app or compositor benchmark.
/// The parent creates all disposable SQLite fixtures before recording launch time.
@main @MainActor struct NativeStartupMeasurements {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--open-root" {
            let entered = ProcessInfo.processInfo.systemUptime
            URLProtocol.registerClass(StartupNoNetworkProtocol.self)
            NSApplication.shared.setActivationPolicy(.accessory)
            Task { @MainActor in
                do {
                    guard CommandLine.arguments.count == 3 else { throw StudyError.message("Pass --open-root ROOT") }
                    try await open(root: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true), entered: entered)
                    _exit(0)
                } catch { fail(error) }
            }
            NSApplication.shared.run()
        } else {
            do {
                guard CommandLine.arguments.count == 2 else { throw StudyError.message("Pass the startup report output path") }
                try measure(output: URL(fileURLWithPath: CommandLine.arguments[1]))
            } catch { fail(error) }
        }
    }

    static func open(root: URL, entered: TimeInterval) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StartupNoNetworkProtocol.self]
        let session = URLSession(configuration: configuration)
        let workspace = StudyWorkspaceModel(store: StudyLibraryStore(root: root),
            completionStore: StudyCourseCompletionStore(load: { _ in nil }, save: { _ in }),
            mathWikiSession: session,
            canvasClientFactory: { _, _, _ in throw URLError(.notConnectedToInternet) })
        workspace.classificationTask?.cancel()
        guard !workspace.library.courses.isEmpty, workspace.error == nil else {
            throw StudyError.message(workspace.error ?? "The startup fixture did not load")
        }
        let modelLoaded = ProcessInfo.processInfo.systemUptime
        let controller = StudyWindowController(app: AppModel.shared, workspace: workspace, autosave: false)
        let window = controller.window
        window.level = .floating
        window.orderFrontRegardless()
        for _ in 0..<300 where !window.occlusionState.contains(.visible) {
            try await Task.sleep(for: .milliseconds(10))
        }
        await Task.yield()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let displayed = ProcessInfo.processInfo.systemUptime
        let residentAtDisplay = resident()
        guard window.occlusionState.contains(.visible), let view = window.contentView,
              fields(view).contains(where: { $0.placeholderString == "Find a workspace" }) else {
            throw StudyError.message("First useful startup requires a visible production dashboard and its workspace search field")
        }
        guard StartupRequestLog.shared.count == 0 else {
            throw StudyError.message("Startup unexpectedly attempted network access; every request was blocked")
        }
        let report: [String: Any] = [
            "kind": "native-startup-child", "pid": ProcessInfo.processInfo.processIdentifier,
            "workspaces": workspace.library.courses.count,
            "processEnteredSystemUptime": entered, "modelLoadedSystemUptime": modelLoaded,
            "firstUsefulSystemUptime": displayed, "residentAtFirstUsefulBytes": residentAtDisplay,
            "windowVisible": true, "workspaceSearchPresent": true, "networkAttempts": StartupRequestLog.shared.count
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data([10])
        FileHandle.standardOutput.write(data)
        // Exit without triggering AppDelegate services or mutating global settings.
        // The library and window belong only to this disposable child process.
        withExtendedLifetime(controller) {}
        session.invalidateAndCancel()
    }

    static func measure(output: URL) throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-startup-fixtures-\(UUID())")
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let sizes = [6, 89, 500]
        let roots = try sizes.map { count -> URL in
            let root = fixtureRoot.appendingPathComponent(String(count), isDirectory: true)
            try createFixture(count: count, root: root)
            return root
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var results: [[String: Any]] = []
        let base: [String: Any] = [
            "kind": "native-fresh-process-startup", "configuration": "release",
            "buildID": ProcessInfo.processInfo.environment["SCHOLIA_BUILD_ID"] ?? "unrecorded",
            "recordedAt": ISO8601DateFormatter().string(from: Date()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processorCount": ProcessInfo.processInfo.processorCount, "physicalMemory": ProcessInfo.processInfo.physicalMemory,
            "measurement": "Parent systemUptime immediately before Process.run to child systemUptime immediately after visible production StudyWindowController layout/displayIfNeeded; excludes compositor scanout and app services/AppDelegate outside the window",
            "method": "Five fresh child processes per fixture, no warmup or discarded samples; isolated SQLite fixtures created before all measured launches; OS filesystem cache remains warm",
            "isolation": "Temporary library roots, disabled window autosave, canceled classification, failing Canvas factory and blocked HTTP/HTTPS; AppModel.shared reads existing preferences/conversation metadata but does not start app services or save global settings"
        ]
        for (index, count) in sizes.enumerated() {
            var samples: [[String: Any]] = []
            for sample in 0..<5 {
                let child = Process(), stdout = Pipe(), stderr = Pipe()
                child.executableURL = executable
                child.arguments = ["--open-root", roots[index].path]
                child.standardOutput = stdout
                child.standardError = stderr
                let launched = ProcessInfo.processInfo.systemUptime
                try child.run()
                let timeout = DispatchWorkItem { if child.isRunning { child.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                child.waitUntilExit()
                timeout.cancel()
                guard child.terminationStatus == 0 else {
                    let detail = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    throw StudyError.message("Startup child failed (\(child.terminationStatus)): \(detail)")
                }
                guard let report = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let firstUseful = report["firstUsefulSystemUptime"] as? Double,
                      report["workspaces"] as? Int == count else {
                    throw StudyError.message("Startup child returned an invalid measurement")
                }
                var row = report
                row["sample"] = sample + 1
                row["parentLaunchSystemUptime"] = launched
                row["launchToFirstUsefulMs"] = (firstUseful - launched) * 1000
                samples.append(row)
                print("Measured startup \(count) workspaces, process \(sample + 1)/5"); fflush(nil)
            }
            let timings = samples.compactMap { $0["launchToFirstUsefulMs"] as? Double }
            results.append(["workspaces": count, "documents": count * 20, "materials": count * 70,
                "assignmentCount": count * 12, "conversationMessages": 200, "sampleCount": samples.count,
                "samples": samples, "launchToFirstUsefulP50Ms": percentile(timings, 0.5),
                "launchToFirstUsefulP95Ms": percentile(timings, 0.95)])
            var report = base
            report["results"] = results
            report["complete"] = index == sizes.count - 1
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        }
    }

    static func createFixture(count: Int, root: URL) throws {
        let store = StudyLibraryStore(root: root)
        let date = Date(timeIntervalSince1970: 1_794_000_000)
        var courses: [StudyCourse] = []
        for i in 0..<count {
            let assignments = (0..<12).map { j in CanvasMaterialReference(id: "assignments:\(j)", kind: .assignments,
                remoteID: String(j), title: "Exercise \(j)", sourceURL: "https://fixture.invalid/\(i)/assignments/\(j)", version: "fixture",
                assignment: CanvasAssignmentDetails(record: ["submission_types": ["online_upload"],
                    "due_at": "2026-11-12T12:00:00Z", "submission": ["workflow_state": "unsubmitted"]])) }
            let files = (0..<58).map { j in CanvasMaterialReference(id: "files:\(j)", kind: .files,
                remoteID: String(j), title: "Reading \(j)", sourceURL: "https://fixture.invalid/\(i)/\(j)", version: "fixture") }
            let documents = (0..<20).map { j in StudyDocument(title: "Reading \(j)", kind: .text,
                fileName: "reading.txt", pageCount: 120, lastPage: 7, addedAt: date,
                lastOpenedAt: date.addingTimeInterval(Double(i * 20 + j))) }
            var course = StudyCourse(name: "Workspace \(count - i)", code: "TEST\(4000 + i)", documents: documents,
                canvasMaterials: assignments + files, catalogUpdatedAt: date, term: i % 2 == 0 ? "2026 Autumn" : "2026 Spring")
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
    }

    static func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    static func percentile(_ samples: [Double], _ p: Double) -> Double {
        samples.sorted()[min(samples.count - 1, Int(ceil(Double(samples.count) * p)) - 1)]
    }
    static func resident() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    static func fail(_ error: Error) -> Never {
        FileHandle.standardError.write(Data("FAIL native startup measurement: \(error)\n".utf8))
        exit(1)
    }
}
