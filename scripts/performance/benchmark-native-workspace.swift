import AppKit
import Darwin
import SwiftUI
@testable import ScholiaMac

/// A separate full-workspace series. The original dashboard-component series
/// remains unchanged so before/after measurements have the same boundary.
private final class MeasurementCanvasProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "canvas.measurement.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { lock.withLock { stopped = true } }
    override func startLoading() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.025) { [self] in
            guard !lock.withLock({ stopped }), let url = request.url else { return }
            let json = url.path.hasSuffix("/users/self") ? #"{"id":42,"name":"Measurement fixture"}"# : #"[{"id":1,"name":"Updated exercise","html_url":"https://canvas.measurement.invalid/assignments/1","submission_types":["online_upload"],"submission":{"workflow_state":"submitted"}}]"#
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@main @MainActor struct NativeWorkspaceMeasurements {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL full workspace measurement: \(error)"); exit(1) }
        }
        NSApplication.shared.run()
    }
    static func run() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var results: [[String: Any]] = []
        for count in [6, 89, 500] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-full-measurement-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = StudyLibraryStore(root: root)
            let source = try StudyDocumentImporter.read(data: Data(String(repeating: "Feedback connects an observation with a response.\n", count: 100).utf8), name: "reading.txt", store: store)
            let origin = "https://canvas.measurement.invalid"
            let courses = (0..<count).map { i -> StudyCourse in
                let references = (1...12).map { j in CanvasMaterialReference(id: "assignments:\(j)", kind: .assignments,
                    remoteID: "\(j)", title: "Exercise \(j)", sourceURL: origin + "/assignments/\(j)", version: "fixture",
                    assignment: CanvasAssignmentDetails(record: ["submission_types": ["online_upload"],
                        "due_at": "2026-11-12T12:00:00Z", "submission": ["workflow_state": "unsubmitted"]])) }
                var documents = (0..<20).map { j in StudyDocument(title: "Reading \(j)", kind: .text,
                    fileName: source.fileName, pageCount: source.pageCount, lastOpenedAt: Date(timeIntervalSince1970: Double(i * 20 + j))) }
                if i == 0 { documents[0] = source }
                var course = StudyCourse(name: "Workspace \(count - i)", code: "TEST\(4000 + i)", documents: documents, canvasID: i + 1,
                    canvasOrigin: origin, canvasUserID: 42, canvasMaterials: references,
                    catalogUpdatedAt: Date(), term: "2026 Autumn")
                if i == 0 {
                    var thread = StudyThread(documentID: source.id, mode: .explain)
                    thread.messages = (0..<50).map { ConversationMessage(role: $0 % 2 == 0 ? .user : .assistant,
                        content: String(repeating: "This is a saved explanation with supporting context. ", count: 40)) }
                    course.threads = [thread]
                }
                return course
            }
            try store.save(StudyLibrary(courses: courses, selectedCourseID: courses[0].id, canvasOrigin: origin,
                canvasUserID: 42, showingCourseLibrary: true))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MeasurementCanvasProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let canvas = CanvasClient(origin: URL(string: origin)!, token: "fixture", session: session)
            let workspace = StudyWorkspaceModel(store: store,
                completionStore: StudyCourseCompletionStore(load: { _ in nil }, save: { _ in }),
                canvasClientFactory: { _, _, _ in canvas })
            workspace.classificationTask?.cancel()
            let started = ContinuousClock.now
            let controller = StudyWindowController(app: AppModel.shared, workspace: workspace, autosave: false)
            let window = controller.window
            window.level = .floating
            window.orderFrontRegardless()
            for _ in 0..<300 where !window.occlusionState.contains(.visible) { try await Task.sleep(for: .milliseconds(10)) }
            await paint(window)
            precondition(window.occlusionState.contains(.visible))
            let cold = ms(started.duration(to: .now))
            var navigation: [Double] = [], typing: [Double] = [], heartbeat: [Double] = []
            for _ in 0..<6 {
                workspace.openReading(source.id, courseID: courses[0].id)
                await paint(window)
                let start = ContinuousClock.now
                workspace.showCourseLibrary()
                await paint(window)
                navigation.append(ms(start.duration(to: .now)))
            }
            workspace.openReading(source.id, courseID: courses[0].id)
            workspace.newThread()
            workspace.draft = "Explain this reading"
            let provider = ProviderCatalog.provider(id: "ollama")
            let providerConfiguration = ProviderConfiguration(provider: provider, model: "fixture", endpoint: "http://127.0.0.1:1",
                apiKey: "", language: .english, fastClaudeMode: false)
            var tokens = 0
            workspace.submit(configuration: providerConfiguration) { _, _, token in
                for i in 0..<100 {
                    try Task.checkCancellation()
                    token("Streamed explanation \(i). ")
                    tokens += 1
                    try await Task.sleep(for: .milliseconds(25))
                }
                return CompletionResult(text: "Completed fixture explanation.", providerID: "fixture", providerName: "Fixture", model: "fixture")
            }
            for _ in 0..<200 where tokens == 0 { try await Task.sleep(for: .milliseconds(10)) }
            var visibleStreamTyping: [Double] = []
            for i in 0..<10 {
                await paint(window)
                guard let editor = descendants(window.contentView!).compactMap({ $0 as? BoundedComposerTextView }).first,
                      workspace.isCurrentThreadStreaming else { throw StudyError.message("Active streaming composer was not visible") }
                let start = ContinuousClock.now
                editor.insertText("during stream \(i) ", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
                await paint(window)
                visibleStreamTyping.append(ms(start.duration(to: .now)))
                try await Task.sleep(for: .milliseconds(10))
            }
            let sync = Task { await workspace.refreshCanvasAssignmentsIfNeeded(force: true) }
            var importURLs: [URL] = []
            for i in 0..<12 {
                let url = root.appendingPathComponent("import-\(i).txt")
                try Data(String(repeating: "Imported course reading \(i).\n", count: 8_000).utf8).write(to: url)
                importURLs.append(url)
            }
            workspace.importDocuments(importURLs)
            let cpuStart = cpu()
            let memoryStart = resident()
            var overlappingSamples = 0, streamSamples = 0, importSamples = 0, syncSamples = 0
            for i in 0..<30 {
                await paint(window)
                guard let editor = descendants(window.contentView!).compactMap({ $0 as? BoundedComposerTextView }).first else {
                    throw StudyError.message("Full workspace composer not found")
                }
                let stream = workspace.isStreaming, importing = workspace.isImporting, syncing = workspace.assignmentRefreshBusy
                if stream { streamSamples += 1 }; if importing { importSamples += 1 }; if syncing { syncSamples += 1 }
                if stream && importing && syncing { overlappingSamples += 1 }
                window.makeFirstResponder(editor)
                let start = ContinuousClock.now
                editor.insertText("fixture \(i) ", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
                await paint(window)
                typing.append(ms(start.duration(to: .now)))
                let tick = ContinuousClock.now
                try await Task.sleep(for: .milliseconds(10))
                heartbeat.append(max(0, ms(tick.duration(to: .now)) - 10))
            }
            let canceledWhileActive = workspace.isStreaming
            workspace.stopAnswer()
            workspace.cancelImport()
            sync.cancel()
            _ = await sync.value
            for _ in 0..<300 where workspace.isStreaming || workspace.isImporting { try await Task.sleep(for: .milliseconds(10)) }
            let stopCompleted = !workspace.isStreaming && !workspace.isImporting
            workspace.newThread()
            workspace.draft = "Restart after cancellation"
            workspace.submit(configuration: providerConfiguration) { _, _, token in
                token("Restarted.")
                return CompletionResult(text: "Restarted.", providerID: "fixture", providerName: "Fixture", model: "fixture")
            }
            for _ in 0..<300 where workspace.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
            let restarted = workspace.messages.last?.content == "Restarted."
            workspace.saveDraft()
            workspace.flush()
            let restored = try store.load()
            precondition(restored.courses.count == count && stopCompleted && tokens > 0 && restarted)
            let screenshot = output.deletingLastPathComponent().appendingPathComponent("native-workspace-\(count).png")
            if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: screenshot)
            }
            results.append(["workspaces": count, "documentsBeforeImport": count * 20, "assignments": count * 12,
                "conversationMessages": 50, "coldWorkspaceMs": cold, "returnPaintMs": navigation,
                "returnP50Ms": percentile(navigation, 0.5), "returnP95Ms": percentile(navigation, 0.95),
                "typingPaintMs": typing, "typingP50Ms": percentile(typing, 0.5), "typingP95Ms": percentile(typing, 0.95),
                "visibleStreamTypingMs": visibleStreamTyping, "visibleStreamTypingP95Ms": percentile(visibleStreamTyping, 0.95),
                "heartbeatDelayMs": heartbeat, "cpuSeconds": cpu() - cpuStart,
                "residentBeforeBytes": memoryStart, "residentAfterBytes": resident(), "streamTokens": tokens,
                "samplesDuringStream": streamSamples, "samplesDuringImport": importSamples, "samplesDuringSync": syncSamples,
                "samplesDuringAllThree": overlappingSamples, "cancellationCompleted": stopCompleted,
                "canceledStreamWhileActive": canceledWhileActive, "providerRestartCompleted": restarted,
                "restartLibraryVerified": true, "remainingImportedDocuments": restored.courses[0].documents.count - 20])
            window.close()
            try JSONSerialization.data(withJSONObject: ["kind": "native-full-workspace", "configuration": "release",
                "buildID": ProcessInfo.processInfo.environment["SCHOLIA_BUILD_ID"] ?? "unrecorded",
                "measurement": "visible production StudyWorkspaceView; AppKit insertion through layout/display, excluding compositor scanout; injected provider stream and URLProtocol Canvas transport; real import pipeline",
                "results": results], options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
            print("Measured full native workspace \(count)"); fflush(nil)
        }
    }
    static func paint(_ window: NSWindow) async { await Task.yield(); window.contentView?.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func ms(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
    static func percentile(_ values: [Double], _ p: Double) -> Double { values.sorted()[min(values.count - 1, Int(ceil(Double(values.count) * p)) - 1)] }
    static func cpu() -> Double { var value = rusage(); getrusage(RUSAGE_SELF, &value); return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6 }
    static func resident() -> UInt64 {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
