import AppKit
import Foundation
@testable import ScholiaMac

@main
@MainActor
struct CanvasDownloadSmoke {
    static func main() async throws {
        try checkContentPolling()
        if CommandLine.arguments.contains("--wiki-only") {
            try await checkMathWiki()
            return
        }
        if CommandLine.arguments.contains("--updates-only") {
            try await checkContentUpdates()
            try await checkSavedSessions()
            return
        }
        if CommandLine.arguments.contains("--catalog-only") {
            try await checkCatalogCrawl()
            return
        }
        if CommandLine.arguments.contains("--new-files-only") {
            try await checkNewFiles()
            return
        }
        if CommandLine.arguments.contains("--manual-updates-only") {
            try await checkManualCourseUpdates()
            return
        }
        try await checkNewFiles()
        try await checkContentUpdates()
        try await checkSavedSessions()
        try await checkCatalogCrawl()
        try await checkMathWiki()
        try await checkScheduling()
        try await checkConcurrentScheduling()
        try await checkResume()
        try await checkManualCourseUpdates()
        try await checkInventory()
        print("PASS: full-speed parallel Canvas scheduling, live network priority, background pacing, cancelled partial transfers, durable resume, cache integrity and unchanged exam selections")
    }

    static func checkInventory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-inventory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        var valid = try StudyDocumentImporter.read(data: Data("verified notes".utf8), name: "valid.txt", store: store)
        valid.sourceKey = "files:1"; valid.sourceVersion = "v1"
        var damaged = try StudyDocumentImporter.read(data: Data("complete original".utf8), name: "damaged.txt", store: store)
        damaged.sourceKey = "files:2"; damaged.sourceVersion = "v1"
        try Data("partial".utf8).write(to: store.file(for: damaged))
        var legacy = try StudyDocumentImporter.read(data: Data("old notes".utf8), name: "legacy.txt", store: store)
        legacy.sourceKey = "files:3"; legacy.contentHash = nil
        let origin = "https://canvas.inventory.test"
        let course = StudyCourse(name: "Inventory", code: "TEST", documents: [valid, damaged, legacy], canvasID: 1, canvasOrigin: origin, canvasUserID: 42)
        try store.save(StudyLibrary(courses: [course], canvasOrigin: origin, canvasUserID: 42))
        let workspace = StudyWorkspaceModel(store: store)
        workspace.verifyCanvasDownloads()
        try await until { !workspace.canvasVerifyingDownloads }
        let saved = try store.load().courses[0].documents
        precondition(saved[0].contentIntegrity == .verified && saved[0].contentBytes == 14)
        precondition(saved[1].contentIntegrity == .needsRepair && saved[1].contentBytes == 7)
        precondition(saved[2].contentIntegrity == .unverified, "Legacy files must not be called verified without a reference hash")
        let resumed = StudyWorkspaceModel(store: store)
        let summary = CanvasCourseDownloadInventory.total(resumed.canvasDownloadInventory)
        precondition(summary.saved == 3 && summary.verified == 1 && summary.repairs == 1 && summary.unverified == 1 && summary.bytes == 30)
        try FileManager.default.removeItem(at: store.file(for: valid))
        resumed.verifyCanvasDownloads()
        try await until { !resumed.canvasVerifyingDownloads }
        let missing = CanvasCourseDownloadInventory.total(resumed.canvasDownloadInventory)
        precondition(missing.saved == 2 && missing.repairs == 2 && missing.bytes == 16, "Counts must come from actual files, including after restart or external deletion")
        print("PASS: persistent downloaded byte counts, full file/index verification, corruption and deletion detection, legacy verification status and restart inventory")
    }

    static func checkScheduling() async throws {
        var priority = CanvasDownloadPriority.background
        var waits = 0
        try await CanvasDownloadScheduling.checkpoint(priority: { priority }, foregroundBusy: { false }, constrained: { false },
            sleep: { _ in waits += 1 })
        precondition(waits == 4, "Background mode must actually pace work")
        waits = 0
        try await CanvasDownloadScheduling.checkpoint(priority: { priority }, foregroundBusy: { false }, constrained: { false },
            sleep: { _ in waits += 1; priority = .prioritized })
        precondition(waits == 1, "Changing priority during a pause must release the remaining delay")
        waits = 0
        var foreground = true
        try await CanvasDownloadScheduling.checkpoint(priority: { .prioritized }, foregroundBusy: { foreground }, constrained: { false },
            sleep: { _ in waits += 1; if waits == 2 { foreground = false } })
        precondition(waits == 0, "Prioritized downloads must not wait for study activity")
        try await CanvasDownloadScheduling.checkpoint(priority: { .background }, foregroundBusy: { foreground }, constrained: { false },
            sleep: { _ in waits += 1; if waits == 2 { foreground = false } })
        precondition(waits == 6, "Background mode must yield to foreground work and keep its pacing")
        priority = .background; foreground = true; waits = 0
        try await CanvasDownloadScheduling.checkpoint(priority: { priority }, foregroundBusy: { foreground }, constrained: { true },
            sleep: { _ in waits += 1; priority = .prioritized })
        precondition(waits == 1, "Prioritizing must release an existing foreground or low-power wait")
        var began = false
        let cancellation = Task {
            try await CanvasDownloadScheduling.checkpoint(priority: { .background }, foregroundBusy: { false }, constrained: { false },
                sleep: { duration in began = true; try await Task.sleep(for: duration) })
        }
        while !began { await Task.yield() }
        cancellation.cancel()
        do { try await cancellation.value; preconditionFailure("Pacing ignored cancellation") }
        catch is CancellationError { }
    }

    static func checkConcurrentScheduling() async throws {
        var priority = CanvasDownloadPriority.background
        var started: [Int] = [], released: Set<Int> = [], completed: [Int] = []
        var active = 0, peak = 0, callbacks = 0
        let run = Task {
            try await CanvasDownloadScheduling.run(count: 12, priority: { priority }, operation: { index in
                active += 1; peak = max(peak, active); started.append(index)
                defer { active -= 1 }
                while !released.contains(index) { try await Task.sleep(for: .milliseconds(10)) }
                return index
            }, completed: { index, result in
                callbacks += 1
                precondition(callbacks == 1 && index == result, "Checkpoint callbacks must stay serialized")
                try await Task.sleep(for: .milliseconds(5))
                completed.append(index); callbacks -= 1
            })
        }
        try await until { started.count == 1 }
        try await Task.sleep(for: .milliseconds(150))
        precondition(active == 1 && started.count == 1, "Background downloads must remain serial")
        priority = .prioritized
        try await until { active == CanvasDownloadScheduling.maximumConcurrentDownloads }
        precondition(started.count == 6, "Prioritizing must open slots while the first transfer is still running")
        priority = .background
        released.formUnion(0..<5)
        try await until { active == 1 && completed.count == 5 }
        try await Task.sleep(for: .milliseconds(150))
        precondition(started.count == 6, "Background mode must drain existing work before starting another material")
        released.insert(5)
        try await until { started.count == 7 }
        precondition(active == 1)
        priority = .prioritized
        try await until { started.count == 12 }
        released.formUnion(0..<12)
        try await run.value
        precondition(Set(completed) == Set(0..<12) && peak == 6 && active == 0)

        let cancelled = Task {
            try await CanvasDownloadScheduling.run(count: 12, priority: { .prioritized }, operation: { index in
                active += 1
                defer { active -= 1 }
                try await Task.sleep(for: .seconds(10))
                return index
            }, completed: { _, _ in preconditionFailure("Cancelled work must not advance its checkpoint") })
        }
        try await until { active == 6 }
        cancelled.cancel()
        do { try await cancelled.value; preconditionFailure("The parallel queue ignored Stop") }
        catch is CancellationError { }
        precondition(active == 0)

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://canvas.priority.test/file")!)
        let control = CanvasDownloadTaskPriority(.background)
        control.register(task)
        precondition(task.priority == URLSessionTask.lowPriority)
        control.update(.prioritized)
        precondition(task.priority == URLSessionTask.highPriority, "Active transfers must be promoted without restarting")
        control.update(.background)
        precondition(task.priority == URLSessionTask.lowPriority)
        control.remove(task)
        control.update(.prioritized)
        precondition(task.priority == URLSessionTask.lowPriority, "Finished transfers must leave the controller")
    }

    static func checkResume() async throws {
        let preloadPreference = UserDefaults.standard.object(forKey: "study.preloadFrequentCourses")
        defer {
            if let preloadPreference { UserDefaults.standard.set(preloadPreference, forKey: "study.preloadFrequentCourses") }
            else { UserDefaults.standard.removeObject(forKey: "study.preloadFrequentCourses") }
        }
        let origin = URL(string: "https://canvas.download.test")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CanvasDownloadProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = CanvasClient(origin: origin, token: "fixture", session: session)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-download-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        var cached = try StudyDocumentImporter.read(data: Data("cached content".utf8), name: "01 notes.txt", store: store)
        cached.sourceKey = "files:1"; cached.sourceVersion = "v2"
        let originalData = Data("previous good contents".utf8)
        var original = try StudyDocumentImporter.read(data: originalData, name: "02 notes.txt", store: store)
        original.sourceKey = "files:2"; original.sourceVersion = "v1"
        let course = StudyCourse(name: "Fixture course", code: "TEST1000", documents: [cached, original],
            canvasID: 11, canvasOrigin: origin.absoluteString, canvasUserID: 42)
        var exams: [StudyExam] = []
        for index in 0..<91 {
            exams.append(StudyExam(id: "exam-\(index)", courseCode: "TEST\(1000 + index)",
                date: "2026-12-10", selected: index < 34, flexible: index % 4 == 0))
        }
        try store.save(StudyLibrary(courses: [course], canvasOrigin: origin.absoluteString,
            canvasUserID: 42, canvasUserName: "Fixture", examPlan: exams))
        let workspace = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client })
        workspace.preloadFrequentCourses = false
        workspace.canvasDownloadPriority = .prioritized
        CanvasDownloadProtocol.state.holdDownloads(true)
        workspace.syncCanvasCourses(courseIDs: [course.id], downloadAll: true)
        try await until { CanvasDownloadProtocol.state.downloadCount(2) == 1 }
        precondition(workspace.canvasBusy && workspace.canvasDownloadPendingCount == 1)
        let initialJournal = try CanvasDownloadProgressStore.load(root: root)
        let initialLibrary = try store.load()
        precondition(initialJournal?.remainingCourseIDs.allSatisfy { id in initialLibrary.courses.contains { $0.id == id } } == true,
            "A durable journal must only refer to courses already persisted in the library")
        precondition(CanvasDownloadProtocol.state.downloadCount(1) == 0, "Resume must skip a complete unchanged file")
        workspace.cancelCanvas()
        try await until { !workspace.canvasBusy }
        let stillOriginal = try Data(contentsOf: store.file(for: original))
        precondition(stillOriginal == originalData, "A cancelled partial transfer must leave the last good original intact")
        workspace.flush()
        let stopped = try store.load()
        precondition(stopped.examPlan == exams && stopped.courses[0].documents.contains { $0.id == cached.id }
            && stopped.courses[0].documents.first { $0.id == original.id }?.sourceVersion == "v1")
        let progress = try CanvasDownloadProgressStore.load(root: root)
        precondition(progress?.remainingCourseIDs == [course.id]
            && progress?.pendingMaterialIDs[course.id]?.contains("files:2") == true)

        let resumed = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client })
        resumed.preloadFrequentCourses = false
        precondition(resumed.canvasDownloadPendingCount == 1 && !resumed.canvasBusy,
            "Restart must offer resume without starting an unexpected download")
        resumed.canvasDownloadPriority = .prioritized
        CanvasDownloadProtocol.state.holdDownloads(false)
        resumed.resumeCanvasDownloads()
        try await until { !resumed.canvasBusy }
        precondition(resumed.canvasDownloadPendingCount == 0 && resumed.library.examPlan == exams)
        let completed = try store.load()
        let downloaded = completed.courses[0].documents.first { $0.sourceKey == "files:2" }!
        precondition(downloaded.id == original.id && downloaded.sourceVersion == "v2")
        let complete = try store.isComplete(downloaded)
        let newData = try Data(contentsOf: store.file(for: downloaded))
        precondition(complete && newData == Data("new contents 2".utf8))
        precondition(CanvasDownloadProtocol.state.downloadCount(1) == 0)
        let cleared = try CanvasDownloadProgressStore.load(root: root)
        precondition(cleared == nil)

        // A matching version is insufficient when its index disappeared or its original was damaged.
        try FileManager.default.removeItem(at: store.directory(for: cached.id).appendingPathComponent("index.json"))
        try Data("truncated".utf8).write(to: store.file(for: downloaded))
        resumed.syncCanvasCourses(courseIDs: [course.id], downloadAll: true)
        try await until { !resumed.canvasBusy }
        let repaired = try store.load()
        let repairs = try repaired.courses[0].documents.map { try store.isComplete($0) }
        precondition(repairs.allSatisfy { $0 } && CanvasDownloadProtocol.state.downloadCount(1) == 1
            && CanvasDownloadProtocol.state.downloadCount(2) == 3 && repaired.examPlan == exams)

        // Foreground preparation shares the same transfer; stopping bulk must not stop the requested file.
        resumed.library.courses[0].documents.removeAll { $0.sourceKey == "files:2" }
        CanvasDownloadProtocol.state.holdDownloads(true)
        resumed.syncCanvasCourses(courseIDs: [course.id], downloadAll: true)
        try await until { CanvasDownloadProtocol.state.downloadCount(2) == 4 }
        let assignment = resumed.library.courses[0].materials.first { $0.kind == .assignments }!
        resumed.openAssignment(assignment, courseID: course.id, fileID: "files:2", clientOverride: client)
        try await until { resumed.assignmentPreparingFileID == "files:2" }
        precondition(resumed.assignmentPreparing && resumed.canvasBusy)
        resumed.cancelCanvas()
        try await until { !resumed.canvasBusy }
        precondition(resumed.assignmentPreparing && resumed.canvasDownloadPendingCount == 1,
            "Stop must promptly end bulk work while a requested assignment keeps its shared transfer")
        CanvasDownloadProtocol.state.holdDownloads(false)
        try await until { !resumed.assignmentPreparing }
        precondition(CanvasDownloadProtocol.state.downloadCount(2) == 4
            && resumed.library.courses[0].documents.contains { $0.sourceKey == "files:2" },
            "The foreground file must finish with one shared download")
        resumed.resumeCanvasDownloads()
        try await until { !resumed.canvasBusy }
        precondition(resumed.canvasDownloadPendingCount == 0 && CanvasDownloadProtocol.state.downloadCount(2) == 4
            && resumed.library.examPlan == exams)

        let removed = UUID()
        let journalStore = CanvasDownloadProgressStore(root: root)
        try await journalStore.save(CanvasDownloadProgress(origin: origin.absoluteString, userID: 42,
            remainingCourseIDs: [removed, course.id]))
        let surviving = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client })
        surviving.canvasDownloadPriority = .prioritized
        surviving.resumeCanvasDownloads()
        try await until { !surviving.canvasBusy }
        precondition(surviving.canvasDownloadPendingCount == 0 && surviving.library.examPlan == exams,
            "A removed first course must not prevent the remaining queue from resuming")
        try await journalStore.save(CanvasDownloadProgress(origin: origin.absoluteString, userID: 42,
            remainingCourseIDs: [removed]))
        let removedOnly = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client })
        removedOnly.resumeCanvasDownloads()
        try await until { !removedOnly.canvasBusy }
        precondition(removedOnly.canvasDownloadPendingCount == 0 && removedOnly.library.examPlan == exams,
            "A queue containing only removed courses must clear safely instead of getting stuck")
    }

    static func checkManualCourseUpdates() async throws {
        let preference = "study.automaticallyUpdateCanvasContent"
        let savedPreference = UserDefaults.standard.object(forKey: preference)
        defer {
            if let savedPreference { UserDefaults.standard.set(savedPreference, forKey: preference) }
            else { UserDefaults.standard.removeObject(forKey: preference) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-manual-updates-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = "https://canvas.download.test"
        let store = StudyLibraryStore(root: root)
        let downloading = StudyCourse(name: "Downloading", code: "TEST1100", canvasID: 11, canvasOrigin: origin, canvasUserID: 42)
        let requested = StudyCourse(name: "Requested", code: "TEST1200", canvasID: 12, canvasOrigin: origin, canvasUserID: 42)
        let untouched = StudyCourse(name: "Untouched", code: "TEST1300", canvasID: 13, canvasOrigin: origin, canvasUserID: 42)
        let foreign = StudyCourse(name: "Other account", code: "TEST1400", canvasID: 14, canvasOrigin: origin, canvasUserID: 99)
        try store.save(StudyLibrary(courses: [downloading, requested, untouched, foreign], canvasOrigin: origin, canvasUserID: 42))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CanvasDownloadProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = CanvasClient(origin: URL(string: origin)!, token: "fixture", session: session)
        let workspace = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, interaction in
            precondition(!interaction, "Manual course updates must use the saved connection without credential prompts")
            return client
        })
        workspace.automaticallyUpdateCanvasContent = false
        precondition(Set(workspace.canvasUpdatableCourses.map(\.id)) == [downloading.id, requested.id, untouched.id])
        let previousDownloads = CanvasDownloadProtocol.state.downloadCount(2)
        let previousRequested = CanvasDownloadProtocol.state.downloadCount(3)
        CanvasDownloadProtocol.state.holdDownloads(true)
        defer { CanvasDownloadProtocol.state.holdDownloads(false) }
        workspace.syncCanvasCourses(courseIDs: [downloading.id], downloadAll: true)
        try await until { CanvasDownloadProtocol.state.downloadCount(2) > previousDownloads }
        precondition(workspace.canUpdateCanvasCourseContent(requested.id))
        workspace.updateCanvasCourseContent(courseIDs: [requested.id, requested.id, foreign.id])
        workspace.updateCanvasCourseContent(courseIDs: [requested.id])
        precondition(workspace.queuedCanvasCourseUpdateIDs == [requested.id])
        precondition(workspace.canvasCourseUpdateTitle(requested.id) == "Queued")
        precondition(!workspace.canUpdateCanvasCourseContent(requested.id))
        precondition(CanvasDownloadProtocol.state.downloadCount(3) == previousRequested,
            "A manual request must wait for the running download, without interrupting or overlapping it")
        CanvasDownloadProtocol.state.holdDownloads(false)
        try await until { !workspace.canvasBusy }
        workspace.flush()
        let updated = try store.load()
        precondition(updated.courses[1].documents.contains { $0.sourceKey == "files:3" })
        precondition(updated.courses[2].canvasMaterials == nil && updated.courses[3].canvasMaterials == nil,
            "Manual updates must only touch the requested course in the connected account")
        precondition(CanvasDownloadProtocol.state.downloadCount(3) == previousRequested + 1)
        precondition(workspace.queuedCanvasCourseUpdateIDs.isEmpty && workspace.manualCanvasCourseUpdateID == nil)
        precondition(workspace.canvasDownloadPriority == .background && !workspace.automaticallyUpdateCanvasContent,
            "Manual updates must respect download priority and work with automatic updates off")

        // An immediate second click must not enqueue the currently connecting course.
        workspace.updateCanvasCourseContent(courseIDs: [requested.id])
        precondition(workspace.canvasCourseUpdateTitle(requested.id) == "Updating…")
        workspace.updateCanvasCourseContent(courseIDs: [requested.id])
        precondition(workspace.queuedCanvasCourseUpdateIDs.isEmpty)
        try await until { !workspace.canvasBusy }
        precondition(CanvasDownloadProtocol.state.downloadCount(3) == previousRequested + 1,
            "Repeating a manual update must reuse verified unchanged originals")

        // Turning off scheduled work must still allow an explicitly requested update to run.
        workspace.library.selectedCourseID = downloading.id
        let savedFile = workspace.library.courses[0].documents.firstIndex { $0.sourceKey == "files:2" }!
        workspace.library.courses[0].documents[savedFile].sourceVersion = "older"
        workspace.automaticallyUpdateCanvasContent = true
        CanvasDownloadProtocol.state.holdDownloads(true)
        let countBeforeAutomatic = CanvasDownloadProtocol.state.downloadCount(2)
        let automatic = Task { await workspace.refreshCanvasContentIfNeeded(now: Date().addingTimeInterval(601)) }
        try await until { CanvasDownloadProtocol.state.downloadCount(2) > countBeforeAutomatic }
        workspace.updateCanvasCourseContent(courseIDs: [requested.id])
        precondition(workspace.queuedCanvasCourseUpdateIDs == [requested.id])
        workspace.automaticallyUpdateCanvasContent = false
        await automatic.value
        precondition(workspace.manualCanvasCourseUpdateID == requested.id,
            "Disabling automatic updates must not discard a queued manual request")
        CanvasDownloadProtocol.state.holdDownloads(false)
        try await until { !workspace.canvasBusy }

        // Stop must clear waiting requests before the current task unwinds.
        workspace.syncCanvasCourses(courseIDs: [downloading.id])
        workspace.updateCanvasCourseContent(courseIDs: [untouched.id])
        precondition(workspace.queuedCanvasCourseUpdateIDs == [untouched.id])
        workspace.cancelCanvas()
        try await until { !workspace.canvasBusy }
        precondition(workspace.queuedCanvasCourseUpdateIDs.isEmpty && workspace.library.courses[2].canvasMaterials == nil)

        // Queued requests belong to the account that requested them.
        workspace.syncCanvasCourses(courseIDs: [downloading.id])
        workspace.updateCanvasCourseContent(courseIDs: [untouched.id])
        workspace.library.canvasUserID = 99
        try await until { !workspace.canvasBusy }
        precondition(workspace.queuedCanvasCourseUpdateIDs.isEmpty && workspace.library.courses[2].canvasMaterials == nil)
        workspace.library.canvasUserID = 42
        workspace.syncCanvasCourses(courseIDs: [downloading.id])
        workspace.updateCanvasCourseContent(courseIDs: [untouched.id])
        workspace.library.courses.removeAll { $0.id == untouched.id }
        try await until { !workspace.canvasBusy }
        precondition(workspace.queuedCanvasCourseUpdateIDs.isEmpty && workspace.manualCanvasCourseUpdateID == nil,
            "Removed courses must leave the manual queue safely")
        print("PASS: scoped manual course updates with automatic updates off, serial queueing, deduplication, unchanged download reuse, Stop, account changes and removed courses")
    }

    static func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for Canvas fixture")
    }
}

private final class CanvasDownloadFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var holding = false
    private var counts: [Int: Int] = [:]
    private var continuations: [UUID: @Sendable () -> Void] = [:]
    func holdDownloads(_ value: Bool) {
        let pending = lock.withLock { () -> [@Sendable () -> Void] in
            holding = value
            guard !value else { return [] }
            let pending = Array(continuations.values); continuations.removeAll(); return pending
        }
        for finish in pending { finish() }
    }
    func started(_ id: Int, ticket: UUID, finish: @escaping @Sendable () -> Void) {
        let held = lock.withLock {
            counts[id, default: 0] += 1
            guard holding && id == 2 else { return false }
            continuations[ticket] = finish
            return true
        }
        if !held { finish() }
    }
    func cancelled(_ ticket: UUID) { lock.withLock { continuations[ticket] = nil } }
    func downloadCount(_ id: Int) -> Int { lock.withLock { counts[id] ?? 0 } }
}

private final class CanvasDownloadProtocol: URLProtocol, @unchecked Sendable {
    static let state = CanvasDownloadFixture()
    private let ticket = UUID()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "canvas.download.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.path.hasPrefix("/download/") {
            let id = Int(url.lastPathComponent)!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/plain"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("new ".utf8))
            Self.state.started(id, ticket: ticket) { [self] in
                client?.urlProtocol(self, didLoad: Data("contents \(id)".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        func file(_ id: Int) -> [String: Any] {
            ["id": id, "display_name": "0\(id) notes.txt", "filename": "0\(id) notes.txt",
                "updated_at": "v2", "size": 14, "url": "https://canvas.download.test/download/\(id)"]
        }
        let body: Any
        let assignment: [String: Any] = ["id": 7, "name": "Assignment", "updated_at": "v2",
            "submission_types": ["online_upload"],
            "description": "<a href='https://canvas.download.test/courses/11/files/2/download'>Included file</a>"]
        switch url.path {
        case "/api/v1/users/self/profile": body = ["id": 42, "name": "Fixture"]
        case "/api/v1/courses/11/files": body = [file(1), file(2)]
        case "/api/v1/courses/11/files/1": body = file(1)
        case "/api/v1/courses/11/files/2": body = file(2)
        case "/api/v1/courses/12/files": body = [file(3)]
        case "/api/v1/courses/12/files/3": body = file(3)
        case "/api/v1/courses/12": body = ["id": 12]
        case "/api/v1/courses/11/assignments": body = [assignment]
        case "/api/v1/courses/11/assignments/7": body = assignment
        case "/api/v1/courses/11": body = ["id": 11]
        default: body = []
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.state.cancelled(ticket) }
}
