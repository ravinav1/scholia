import AppKit
import Darwin
import SwiftUI
@testable import ScholiaMac

private final class QuickJumpNetworkGuard: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var attempts = 0
    static var requestCount: Int { lock.withLock { attempts } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock { Self.attempts += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// Measurement only: production Quick Jump sheet in the production workspace.
/// All course data and writes use a temporary store. No AppDelegate/services run.
@main @MainActor
struct NativeQuickJumpMeasurements {
    static func main() {
        URLProtocol.registerClass(QuickJumpNetworkGuard.self)
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAIL Quick Jump measurement: \(error)"); exit(1) }
        }
        NSApplication.shared.run()
    }

    static func run() async throws {
        guard CommandLine.arguments.count == 2 else { throw StudyError.message("Pass output JSON path") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        var results: [[String: Any]] = []
        for count in [89, 500] {
            print("Starting visible Quick Jump measurement: \(count) workspaces"); fflush(nil)
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-quick-jump-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let store = StudyLibraryStore(root: root)
            let date = Date(timeIntervalSince1970: 1_794_000_000)
            let courses = (0..<count).map { i -> StudyCourse in
                let documents = (0..<20).map { j in StudyDocument(title: "Reading \(j)", kind: .text,
                    fileName: "reading.txt", pageCount: 120, lastPage: 7, addedAt: date,
                    lastOpenedAt: date.addingTimeInterval(Double(i * 20 + j))) }
                let assignments = (0..<12).map { j in CanvasMaterialReference(id: "assignments:\(j)", kind: .assignments,
                    remoteID: "\(j)", title: "Exercise \(j)", sourceURL: "https://fixture.invalid/\(i)/assignments/\(j)", version: "fixture",
                    assignment: CanvasAssignmentDetails(record: ["submission_types": ["online_upload"],
                        "due_at": "2026-11-12T12:00:00Z", "submission": ["workflow_state": "unsubmitted"]])) }
                let files = (0..<58).map { j in CanvasMaterialReference(id: "files:\(j)", kind: .files,
                    remoteID: "\(j)", title: "Reading \(j)", sourceURL: "https://fixture.invalid/\(i)/files/\(j)", version: "fixture") }
                var course = StudyCourse(name: String(format: "Workspace %03d", i + 1), code: "TEST\(4000 + i)",
                    documents: documents, canvasMaterials: assignments + files, catalogUpdatedAt: date,
                    term: i % 2 == 0 ? "2026 Autumn" : "2026 Spring")
                if i == 0 || i == count - 1 {
                    var thread = StudyThread(documentID: nil, mode: .explain)
                    thread.draft = "Preserve the Quick Jump fixture draft for \(course.code)."
                    thread.messages = (0..<50).map { j in ConversationMessage(role: j % 2 == 0 ? .user : .assistant,
                        content: String(repeating: "Saved conversation context. ", count: 40)) }
                    course.threads = [thread]
                }
                return course
            }
            try store.save(StudyLibrary(courses: courses, selectedCourseID: courses[0].id, showingCourseLibrary: false))
            let workspace = StudyWorkspaceModel(store: store,
                completionStore: StudyCourseCompletionStore(load: { _ in nil }, save: { _ in }),
                canvasClientFactory: { _, _, _ in throw URLError(.notConnectedToInternet) })
            workspace.classificationTask?.cancel()
            workspace.selectCourse(courses[0].id)
            let controller = StudyWindowController(app: AppModel.shared, workspace: workspace, autosave: false)
            let window = controller.window
            window.appearance = NSAppearance(named: .aqua)
            window.setContentSize(NSSize(width: 1280, height: 900))
            window.level = .floating
            controller.show()
            window.orderFrontRegardless()
            try await waitUntil(window: window, description: "visible key workspace") {
                window.occlusionState.contains(.visible) && window.isKeyWindow
            }
            try await Task.sleep(for: .milliseconds(300))

            var opening: [Double] = [], finalQuery: [Double] = [], burst: [Double] = [], selection: [Double] = []
            var edits: [[String: Any]] = [], sampleRows: [[String: Any]] = [], heartbeat: [Double] = []
            var cpuStart = cpu(), memoryStart = resident()
            for iteration in 0..<33 {
                if iteration == 3 { cpuStart = cpu(); memoryStart = resident() }
                let target = courses[iteration % 2 == 0 ? count - 1 : 0]
                let opened = ContinuousClock.now
                try require(window.performKeyEquivalent(with: key("K", code: 40, modifiers: [.command, .shift], in: window)),
                    "Production Command-Shift-K shortcut was not handled")
                try await waitUntil(window: window, description: "focused Quick Jump search field") {
                    guard let sheet = window.attachedSheet, let field = searchField(in: sheet) else { return false }
                    return sheet.isVisible && field.bounds.width > 0 && field.currentEditor() is NSTextView
                }
                guard let sheet = window.attachedSheet, let field = searchField(in: sheet),
                      let editor = field.currentEditor() as? NSTextView else { throw StudyError.message("Quick Jump field disappeared") }
                await paint(sheet)
                let openingMs = ms(opened.duration(to: .now))
                try require(field.stringValue.isEmpty, "Each Quick Jump presentation must start with an empty query")

                let queries = ["T", "TEST4", "zz-no-match", "TEST4", target.code]
                let burstStart = ContinuousClock.now
                var iterationEdits: [Double] = []
                for (index, query) in queries.enumerated() {
                    let typed = ContinuousClock.now
                    editor.insertText(query, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                    await paint(sheet)
                    let elapsed = ms(typed.duration(to: .now))
                    try require(field.stringValue == query, "Native editor lost a rapid query update")
                    iterationEdits.append(elapsed)
                    if iteration >= 3 { edits.append(["sample": iteration - 3, "edit": index, "query": query, "paintMs": elapsed]) }
                }
                let burstMs = ms(burstStart.duration(to: .now))
                // Outside the typing timing: verify the displayed final result,
                // not merely the field contents or a separately queried model.
                try require(accessibilityText(in: sheet).contains(where: { $0.contains(target.displayName) }),
                    "Latest query did not display the expected workspace result")
                let selected = ContinuousClock.now
                sheet.sendEvent(try key("\r", code: 36, in: sheet))
                try await waitUntil(window: window, description: "selected workspace after Enter") {
                    window.attachedSheet == nil && !sheet.isVisible && window.isKeyWindow
                        && workspace.course?.id == target.id && !workspace.isShowingLibrary
                }
                let selectionMs = ms(selected.duration(to: .now))
                try require(workspace.draft == "Preserve the Quick Jump fixture draft for \(target.code).",
                    "Keyboard selection did not restore the target workspace draft")
                if iteration >= 3 {
                    opening.append(openingMs); finalQuery.append(iterationEdits.last!); burst.append(burstMs); selection.append(selectionMs)
                    sampleRows.append(["sample": iteration - 3, "targetCode": target.code, "openingMs": openingMs,
                        "finalQueryPaintMs": iterationEdits.last!, "fiveEditBurstMs": burstMs, "enterToWorkspacePaintMs": selectionMs,
                        "correctSelection": true, "draftRestored": true])
                    let tick = ContinuousClock.now
                    try await Task.sleep(for: .milliseconds(10))
                    heartbeat.append(max(0, ms(tick.duration(to: .now)) - 10))
                }
                if iteration % 10 == 0 { print("Quick Jump \(count): iteration \(iteration + 1)/33"); fflush(nil) }
            }
            workspace.flush()
            let restored = try store.load()
            try require(restored.courses.count == count && QuickJumpNetworkGuard.requestCount == 0, "Fixture isolation check failed")
            let allEdits = edits.compactMap { $0["paintMs"] as? Double }
            results.append(["workspaces": count, "documents": count * 20, "materials": count * 70, "assignments": count * 12,
                "savedConversationMessages": 100, "warmup": 3, "samples": 30, "queryEditsPerSample": 5,
                "openingMs": opening, "openingP50Ms": percentile(opening, 0.5), "openingP95Ms": percentile(opening, 0.95),
                "queryEdits": edits, "allQueryEditsP50Ms": percentile(allEdits, 0.5), "allQueryEditsP95Ms": percentile(allEdits, 0.95),
                "finalQueryPaintMs": finalQuery, "finalQueryP50Ms": percentile(finalQuery, 0.5), "finalQueryP95Ms": percentile(finalQuery, 0.95),
                "fiveEditBurstMs": burst, "burstP50Ms": percentile(burst, 0.5), "burstP95Ms": percentile(burst, 0.95),
                "enterToWorkspacePaintMs": selection, "selectionP50Ms": percentile(selection, 0.5), "selectionP95Ms": percentile(selection, 0.95),
                "sampleRows": sampleRows, "correctSelections": 30, "restoredDrafts": 30,
                "heartbeatDelayMs": heartbeat, "cpuSeconds": cpu() - cpuStart,
                "residentBeforeBytes": memoryStart, "residentAfterBytes": resident(), "networkRequests": QuickJumpNetworkGuard.requestCount])
            window.delegate = nil
            window.close()
            let report: [String: Any] = ["status": results.count == 2 ? "complete" : "partial",
                "kind": "native-visible-production-quick-jump", "configuration": "release",
                "applicationSourceCommit": "c4492b5", "buildID": ProcessInfo.processInfo.environment["SCHOLIA_BUILD_ID"] ?? "unrecorded",
                "recordedAt": ISO8601DateFormatter().string(from: Date()), "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "processorCount": ProcessInfo.processInfo.processorCount, "physicalMemory": ProcessInfo.processInfo.physicalMemory,
                "measurement": "production StudyWorkspaceView sheet; native Command-Shift-K, NSTextView insertion, keyboard Enter; main-runloop yield and AppKit layout/displayIfNeeded; excludes compositor scanout; opening/selection include native sheet lifecycle; readiness poll interval 5ms",
                "baselineAvailable": false, "results": results]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
            print("Measured Quick Jump \(count): open p95 \(percentile(opening, 0.95))ms, query p95 \(percentile(allEdits, 0.95))ms, select p95 \(percentile(selection, 0.95))ms"); fflush(nil)
        }
    }

    static func waitUntil(window: NSWindow, description: String, condition: () -> Bool) async throws {
        let started = ContinuousClock.now
        repeat {
            await paint(window)
            if let sheet = window.attachedSheet { await paint(sheet) }
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        } while started.duration(to: .now) < .seconds(5)
        throw StudyError.message("Timed out waiting for \(description): visible=\(window.isVisible), occlusion=\(window.occlusionState.rawValue), key=\(window.isKeyWindow), active=\(NSApplication.shared.isActive), policy=\(NSApplication.shared.activationPolicy().rawValue)")
    }
    static func searchField(in window: NSWindow) -> NSSearchField? {
        guard let root = window.contentView else { return nil }
        return descendants(root).compactMap { $0 as? NSSearchField }.first { $0.accessibilityIdentifier() == "workspace-shortcuts-query" }
    }
    static func accessibilityText(in window: NSWindow) -> [String] {
        var stack: [Any] = [window], seen = Set<ObjectIdentifier>(), text: [String] = []
        while let next = stack.popLast(), seen.count < 20_000 {
            let object = next as AnyObject
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            if let label = object.accessibilityLabel?() as? String { text.append(label) }
            if let value = accessibilityValue(object) as? String { text.append(value) }
            stack.append(contentsOf: (object.accessibilityChildren?() ?? nil) ?? [])
            if let item = next as? NSWindow, let content = item.contentView { stack.append(content) }
            if let view = next as? NSView { stack.append(contentsOf: view.subviews) }
        }
        return text
    }
    static func accessibilityValue(_ object: AnyObject) -> Any? { object.accessibilityValue?() ?? nil }
    static func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        guard let keyboard = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true) else { throw StudyError.message("Could not create key event") }
        keyboard.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        guard let translated = NSEvent(cgEvent: keyboard), let event = NSEvent.keyEvent(with: .keyDown,
            location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: translated.characters ?? characters,
            charactersIgnoringModifiers: translated.charactersIgnoringModifiers ?? characters, isARepeat: false, keyCode: code)
        else { throw StudyError.message("Could not translate key event") }
        return event
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw StudyError.message(message) } }
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
