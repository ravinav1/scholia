import AppKit
import Foundation
@testable import ScholiaMac

extension CanvasDownloadSmoke {
    static func checkContentUpdates() async throws {
        let preference = "study.automaticallyUpdateCanvasContent"
        let savedPreference = UserDefaults.standard.object(forKey: preference)
        defer {
            if let savedPreference { UserDefaults.standard.set(savedPreference, forKey: preference) }
            else { UserDefaults.standard.removeObject(forKey: preference) }
        }
        let origin = "https://canvas.new-files.test"
        let now = CanvasAssignmentDetails.date("2026-09-30T12:00:00Z")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-content-update-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        var edited = try StudyDocumentImporter.read(data: Data("My local lecture notes.".utf8), name: "notes-1.txt", store: store)
        edited.sourceKey = "files:1"; edited.sourceVersion = "v1"; edited.locallyEditedAt = now
        let course = StudyCourse(name: "Content updates", code: "TTK4250-26H", documents: [edited],
            canvasID: 1, canvasOrigin: origin, canvasUserID: 42, term: "2026 HØST")
        var foreign = course; foreign.id = UUID(); foreign.canvasUserID = 99; foreign.documents = []
        try store.save(StudyLibrary(courses: [course, foreign], canvasOrigin: origin, canvasUserID: 42))
        NewCanvasFilesProtocol.state.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NewCanvasFilesProtocol.self]
        let api = CanvasClient(origin: URL(string: origin)!, token: "fixture", session: URLSession(configuration: config))
        let workspace = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, interaction in
            precondition(!interaction, "Course updates must never prompt for credentials")
            return api
        })
        workspace.canvasDownloadPriority = .prioritized
        workspace.automaticallyUpdateCanvasContent = false
        await workspace.refreshCanvasContentIfNeeded(now: now)
        precondition(NewCanvasFilesProtocol.state.paths.isEmpty, "Disabled content updates must not make requests")
        workspace.updateCanvasCourseContent(courseIDs: [course.id, course.id, foreign.id])
        try await newFilesUntil { !workspace.canvasBusy }
        workspace.flush()
        let updated = try store.load().courses[0]
        precondition(Set(updated.documents.compactMap(\.sourceKey)).isSuperset(of: ["files:1", "files:2", "files:3", "files:4", "assignments:100", "pages:lecture"]))
        precondition(updated.documents.first { $0.id == edited.id }?.sourceKey == nil)
        precondition(updated.documents.first { $0.id == edited.id }?.contentHash == edited.contentHash,
            "A changed Canvas original must preserve local edits")
        precondition(updated.documents.first { $0.sourceKey == "files:1" }?.sourceVersion == "v2")
        precondition(workspace.library.courses[1].canvasMaterials == nil, "Another account's course must not be updated")
        precondition(NewCanvasFilesProtocol.state.paths.filter { $0.hasPrefix("/downloads/") }.count == 4)
        let downloads = NewCanvasFilesProtocol.state.paths.filter { $0.hasPrefix("/downloads/") }.count
        workspace.automaticallyUpdateCanvasContent = true
        let due = Date().addingTimeInterval(301)
        await workspace.refreshCanvasContentIfNeeded(now: due)
        let requests = NewCanvasFilesProtocol.state.paths.count
        await workspace.refreshCanvasContentIfNeeded(now: due.addingTimeInterval(299))
        precondition(NewCanvasFilesProtocol.state.paths.count == requests, "Content checks must be throttled")
        precondition(NewCanvasFilesProtocol.state.paths.filter { $0.hasPrefix("/downloads/") }.count == downloads,
            "Unchanged files must not download again")
        workspace.flush()
        let reopened = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in api })
        precondition(reopened.automaticallyUpdateCanvasContent)
        await reopened.refreshCanvasContentIfNeeded(now: due.addingTimeInterval(299))
        precondition(NewCanvasFilesProtocol.state.paths.count == requests, "The throttle must survive restart")
        // Disabling the global switch cancels pending automatic work.
        NewCanvasFilesProtocol.state.delayMetadata = true
        let automatic = Task { await reopened.refreshCanvasContentIfNeeded(now: due.addingTimeInterval(301)) }
        try await newFilesUntil { reopened.canvasContentSyncRunning }
        reopened.automaticallyUpdateCanvasContent = false
        await automatic.value
        precondition(!reopened.canvasBusy && !reopened.canvasContentSyncRunning)
        NewCanvasFilesProtocol.state.reset()
        try await checkPredictedContentUpdates()
        print("PASS: one-button full content update, changed originals, preserved edits, account isolation, no repeated downloads, persisted global switch/throttle and cancellation")
    }

    private static func checkPredictedContentUpdates() async throws {
        let (prediction, time) = try trainedContentPolling()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-content-prediction-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root), origin = "https://canvas.new-files.test"
        let publicRef = CanvasMaterialReference(id: "math-wiki:notes", kind: .files, remoteID: "notes", title: "Wiki notes",
            sourceURL: "https://wiki.math.ntnu.no/notes.txt", version: "known")
        var course = StudyCourse(name: "Publishing pattern", code: "TTK4250-26H", canvasID: 1, canvasOrigin: origin,
            canvasUserID: 42, canvasMaterials: [publicRef], term: "2026 HØST")
        course.canvasPolling = prediction; course.contentUpdateAttemptedAt = time
        try store.save(StudyLibrary(courses: [course], canvasOrigin: origin, canvasUserID: 42))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [NewCanvasFilesProtocol.self]
        let api = CanvasClient(origin: URL(string: origin)!, token: "fixture", session: URLSession(configuration: config))
        let workspace = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, interaction in
            precondition(!interaction); return api
        })
        workspace.automaticallyUpdateCanvasContent = true
        await workspace.refreshCanvasContentIfNeeded(now: time.addingTimeInterval(149))
        precondition(NewCanvasFilesProtocol.state.paths.isEmpty)
        await workspace.refreshCanvasContentIfNeeded(now: time.addingTimeInterval(150))
        precondition(workspace.library.courses[0].documents.contains { $0.sourceVersion == "v2" })
        precondition(workspace.library.courses[0].materials.contains(publicRef), "Predictive Canvas checks retain public materials")
        precondition(!NewCanvasFilesProtocol.state.paths.contains { $0.contains("discussion_topics") }, "Extra Canvas checks skip public-site discovery")
        precondition(workspace.library.courses[0].canvasPolling?.extraChecks.count == 1)
        precondition(workspace.library.courses[0].contentUpdateAttemptedAt == time)
        workspace.flush()
        let saved = try store.load().courses[0]
        precondition(saved.canvasPolling?.extraChecks.count == 1)
        let downloads = NewCanvasFilesProtocol.state.paths.filter { $0.hasPrefix("/downloads/") }.count
        await workspace.refreshCanvasContentIfNeeded(now: time.addingTimeInterval(300))
        precondition(workspace.library.courses[0].contentUpdateAttemptedAt == time.addingTimeInterval(300))
        precondition(NewCanvasFilesProtocol.state.paths.filter { $0.hasPrefix("/downloads/") }.count == downloads)
        print("PASS: native predicted Canvas fetch, unchanged download reuse, preserved public sources, independent regular deadline and persisted budget")
    }

    static func checkNewFiles() async throws {
        let oldPreference = UserDefaults.standard.object(forKey: "study.automaticallyDownloadNewCanvasFiles")
        defer {
            if let oldPreference { UserDefaults.standard.set(oldPreference, forKey: "study.automaticallyDownloadNewCanvasFiles") }
            else { UserDefaults.standard.removeObject(forKey: "study.automaticallyDownloadNewCanvasFiles") }
        }
        let origin = "https://canvas.new-files.test"
        let now = CanvasAssignmentDetails.date("2026-09-29T12:00:00Z")!
        func reference(_ id: Int) -> CanvasMaterialReference {
            CanvasMaterialReference(id: "files:\(id)", kind: .files, remoteID: String(id), title: "Notes \(id)",
                fileName: "notes-\(id).txt", sourceURL: origin + "/courses/1/files/\(id)", version: "v1")
        }
        func client() -> CanvasClient {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [NewCanvasFilesProtocol.self]
            return CanvasClient(origin: URL(string: origin)!, token: "fixture", session: URLSession(configuration: config))
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-new-files-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        var existing = try StudyDocumentImporter.read(data: Data("Saved notes, with a local edit to preserve.".utf8), name: "notes-1.txt", store: store)
        existing.sourceKey = "files:1"; existing.sourceVersion = "v1"; existing.locallyEditedAt = now
        let course = StudyCourse(name: "New files", code: "TTK4250-26H", documents: [existing],
            canvasID: 1, canvasOrigin: origin, canvasUserID: 42, canvasMaterials: [reference(1), reference(2)], term: "2026 HØST")
        try store.save(StudyLibrary(courses: [course], canvasOrigin: origin, canvasUserID: 42))
        NewCanvasFilesProtocol.state.reset()
        let api = client()
        let workspace = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, interaction in
            precondition(!interaction, "Automatic discovery must never prompt for credentials")
            return api
        })
        workspace.canvasDownloadPriority = .prioritized
        workspace.automaticallyDownloadNewCanvasFiles = true
        await workspace.refreshCanvasFilesIfNeeded(now: now)
        workspace.flush()
        let saved = try store.load().courses[0]
        precondition(Set(saved.documents.compactMap(\.sourceKey)) == ["files:1", "files:3", "files:4"])
        precondition(saved.documents.first { $0.id == existing.id }?.contentHash == existing.contentHash)
        precondition(saved.canvasFileSync?.pendingFileIDs.isEmpty == true)
        let paths = NewCanvasFilesProtocol.state.paths
        precondition(paths.contains { $0.contains("page=2") }, "Discovery must check every metadata page")
        precondition(paths.contains { $0.hasPrefix("/api/v1/courses/1/modules/10/items?") }, "Module-only uploads need discovery too")
        precondition(paths.filter { $0.hasPrefix("/downloads/") }.sorted() == ["/downloads/3", "/downloads/4"])
        precondition(paths.contains { $0.contains("/pages/lecture") }, "File discovery must inspect module pages for attachments")
        precondition(paths.contains { $0.contains("syllabus") }, "Public course-site discovery also inspects the syllabus")
        precondition(!paths.contains { $0.hasPrefix("/api/v1/courses/1/files/1") || $0.hasPrefix("/api/v1/courses/1/files/2") },
            "New-file sync must skip changed saved files and older on-demand files, without checking their contents")
        let requests = paths.count
        await workspace.refreshCanvasFilesIfNeeded(now: now.addingTimeInterval(299))
        precondition(NewCanvasFilesProtocol.state.paths.count == requests, "Automatic checks must be throttled")
        await workspace.refreshCanvasFilesIfNeeded(now: now.addingTimeInterval(301))
        precondition(NewCanvasFilesProtocol.state.notModified >= 3)
        precondition(NewCanvasFilesProtocol.state.paths.filter { $0.hasPrefix("/downloads/") }.count == 2,
            "Repeated checks must not download unchanged or already saved content")
        workspace.flush()
        print("PASS: automatic new-file discovery, complete pagination, module links, conditional metadata, preserved local edits and no old-file downloads")

        // A new unindexed course establishes a baseline instead of fetching its whole history.
        var unindexed = course
        unindexed.id = UUID(); unindexed.canvasMaterials = nil; unindexed.documents = []; unindexed.canvasFileSync = nil
        let catalog = try await api.catalog(courseID: 1, filesOnly: true)
        let baseline = CanvasCourseFileSync.reconcile(course: unindexed, catalog: catalog, now: now)
        precondition(Set(baseline.knownFileIDs ?? []) == ["files:1", "files:2", "files:3", "files:4"] && baseline.pendingFileIDs.isEmpty)
        var later = catalog
        later.items.append(reference(5)); unindexed.canvasFileSync = baseline
        precondition(CanvasCourseFileSync.reconcile(course: unindexed, catalog: later, now: now).pendingFileIDs == ["files:5"])
        // Full catalog refreshes must not consume discovery before automatic downloads can see it.
        let fullIndex = CanvasCourseFileSync.reconcile(course: course, catalog: catalog, now: now)
        precondition(fullIndex.pendingFileIDs == ["files:3", "files:4"] && fullIndex.needsCheck(at: now, downloadAutomatically: true))
        var temporarilyHidden = course
        temporarilyHidden.canvasFileSync = fullIndex
        let hiddenCatalog = CanvasMaterialCatalog(items: [reference(1), reference(2)], warnings: [], completeKinds: [.files], moduleOrderComplete: true)
        precondition(CanvasCourseFileSync.reconcile(course: temporarilyHidden, catalog: hiddenCatalog, now: now).pendingFileIDs == ["files:3", "files:4"],
            "Temporarily locked or hidden uploads must remain queued for when they become accessible again")

        try store.save(StudyLibrary(courses: [course], canvasOrigin: origin, canvasUserID: 42))
        NewCanvasFilesProtocol.state.reset()
        let indexed = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client() })
        indexed.canvasDownloadPriority = .prioritized
        indexed.automaticallyDownloadNewCanvasFiles = true
        indexed.syncCanvasCourses(courseIDs: [course.id])
        try await newFilesUntil { !indexed.canvasBusy }
        precondition(indexed.library.courses[0].canvasFileSync?.pendingFileIDs == ["files:3", "files:4"])
        precondition(indexed.library.courses[0].documents.count == 1)
        await indexed.refreshCanvasFilesIfNeeded()
        indexed.flush()
        precondition(indexed.library.courses[0].canvasFileSync?.pendingFileIDs.isEmpty == true)
        precondition(NewCanvasFilesProtocol.state.paths.filter { $0.hasPrefix("/downloads/") }.sorted() == ["/downloads/3", "/downloads/4"])
        print("PASS: full catalog refresh hands new uploads to the automatic worker, without fetching older on-demand material")

        // Discovery without automatic downloads still keeps a durable, actionable queue.
        try store.save(StudyLibrary(courses: [course], canvasOrigin: origin, canvasUserID: 42))
        NewCanvasFilesProtocol.state.reset()
        let queued = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client() })
        queued.automaticallyDownloadNewCanvasFiles = false
        queued.canvasDownloadPriority = .prioritized
        await queued.refreshCanvasFilesIfNeeded(now: now)
        queued.flush()
        precondition((try? store.load())?.courses[0].canvasFileSync?.pendingFileIDs == ["files:3", "files:4"])
        precondition(!NewCanvasFilesProtocol.state.paths.contains { $0.hasPrefix("/downloads/") })
        NewCanvasFilesProtocol.state.failNew = true
        queued.checkForNewCanvasFiles(courseIDs: [course.id], download: true)
        try await newFilesUntil { !queued.canvasBusy }
        queued.flush()
        precondition((try? store.load())?.courses[0].canvasFileSync?.pendingFileIDs == ["files:3"])
        NewCanvasFilesProtocol.state.failNew = false
        NewCanvasFilesProtocol.state.clearPaths()
        let resumed = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client() })
        resumed.canvasDownloadPriority = .prioritized
        resumed.checkForNewCanvasFiles(courseIDs: [course.id], download: true)
        try await newFilesUntil { !resumed.canvasBusy }
        resumed.flush()
        precondition((try? store.load())?.courses[0].canvasFileSync?.pendingFileIDs.isEmpty == true)
        precondition(NewCanvasFilesProtocol.state.paths.filter { $0.hasPrefix("/downloads/") } == ["/downloads/3"])
        print("PASS: persisted discovery queue, manual download option, failed-file retry after restart and no repeated successful transfers")

        try store.save(StudyLibrary(courses: [course], canvasOrigin: origin, canvasUserID: 42))
        NewCanvasFilesProtocol.state.reset(); NewCanvasFilesProtocol.state.delayDownloads = true
        let cancelled = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client() })
        cancelled.canvasDownloadPriority = .prioritized
        cancelled.automaticallyDownloadNewCanvasFiles = true
        cancelled.checkForNewCanvasFiles(courseIDs: [course.id])
        try await newFilesUntil { NewCanvasFilesProtocol.state.paths.contains("/downloads/3") }
        cancelled.cancelCanvas()
        try await newFilesUntil { !cancelled.canvasBusy }
        cancelled.flush()
        precondition(!cancelled.automaticallyDownloadNewCanvasFiles, "Stop must prevent the automatic worker from immediately restarting downloads")
        let interrupted = try store.load().courses[0]
        precondition(interrupted.canvasFileSync?.pendingFileIDs == ["files:3", "files:4"] && interrupted.documents.count == 1)

        NewCanvasFilesProtocol.state.reset(); NewCanvasFilesProtocol.state.delayMetadata = true
        let isolated = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client() })
        isolated.checkForNewCanvasFiles(courseIDs: [course.id])
        try await newFilesUntil { NewCanvasFilesProtocol.state.paths.contains("/api/v1/courses/1/files?per_page=100") }
        isolated.library.canvasUserID = 99
        try await newFilesUntil { !isolated.canvasBusy }
        precondition(isolated.library.courses[0].canvasFileSync == interrupted.canvasFileSync)
        precondition(!NewCanvasFilesProtocol.state.paths.contains { $0.hasPrefix("/downloads/") })
        // Expired authentication cannot erase pending work or be reported as a clean check.
        NewCanvasFilesProtocol.state.reset(); NewCanvasFilesProtocol.state.filesStatus = 401
        let expired = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client() })
        expired.library.canvasUserID = 42
        expired.checkForNewCanvasFiles(courseIDs: [course.id])
        try await newFilesUntil { !expired.canvasBusy }
        precondition(expired.canvasNeedsAuthentication && expired.library.courses[0].canvasFileSync?.pendingFileIDs == ["files:3", "files:4"])
        // A disabled Files tab still permits visible module files; incomplete listings retain unknown items.
        NewCanvasFilesProtocol.state.reset(); NewCanvasFilesProtocol.state.filesStatus = 403
        let fallback = try await client().catalog(courseID: 1, filesOnly: true)
        precondition(fallback.items.map(\.id) == ["files:4"] && !fallback.completeKinds.contains(.files))
        precondition(CanvasCourseFileSync.reconcile(course: interrupted, catalog: fallback, now: now).pendingFileIDs == ["files:3", "files:4"])

        var archived = course; archived.id = UUID(); archived.code = "OLD-24H"; archived.term = "2024 HØST"
        var favorite = archived; favorite.id = UUID(); favorite.favorite = true
        var foreign = course; foreign.id = UUID(); foreign.canvasUserID = 999
        workspace.library.courses = [course, archived, favorite, foreign]
        workspace.library.selectedCourseID = course.id
        precondition(Set(workspace.automaticCanvasFileCourses(at: now).map(\.id)) == [course.id, favorite.id])
        workspace.library.selectedCourseID = archived.id
        precondition(workspace.automaticCanvasFileCourses(at: now).first?.id == archived.id)
        NewCanvasFilesProtocol.state.reset()
        print("PASS: cancellation, account isolation, expired login, disabled Files fallback, current/favorite/open-course scope and first-index baseline")
    }

    private static func newFilesUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw StudyError.message("New-file smoke test timed out")
    }
}

private final class NewCanvasFilesState: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    private var unchanged = 0
    private var fail = false, delay = false, metadataDelay = false
    private var status = 200
    var paths: [String] { lock.withLock { requests } }
    var notModified: Int { lock.withLock { unchanged } }
    var failNew: Bool { get { lock.withLock { fail } } set { lock.withLock { fail = newValue } } }
    var delayDownloads: Bool { get { lock.withLock { delay } } set { lock.withLock { delay = newValue } } }
    var delayMetadata: Bool { get { lock.withLock { metadataDelay } } set { lock.withLock { metadataDelay = newValue } } }
    var filesStatus: Int { get { lock.withLock { status } } set { lock.withLock { status = newValue } } }
    func record(_ path: String) { lock.withLock { requests.append(path) } }
    func recordUnchanged() { lock.withLock { unchanged += 1 } }
    func clearPaths() { lock.withLock { requests = [] } }
    func reset() { lock.withLock { requests = []; unchanged = 0; fail = false; delay = false; metadataDelay = false; status = 200 } }
}

private final class NewCanvasFilesProtocol: URLProtocol, @unchecked Sendable {
    static let state = NewCanvasFilesState()
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "canvas.new-files.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.state.record(url.path + (url.path.hasPrefix("/downloads/") ? "" : (url.query.map { "?" + $0 } ?? "")))
        var headers = ["Content-Type": "application/json"]
        var status = 200
        var body: Any = [:]
        func file(_ id: Int) -> [String: Any] {
            ["id": id, "display_name": "Notes \(id)", "filename": "notes-\(id).txt", "updated_at": "v2", "size": 100,
                "url": "https://canvas.new-files.test/downloads/\(id)?verifier=not-saved"]
        }
        let isFiles = url.path == "/api/v1/courses/1/files"
        switch url.path {
        case "/api/v1/users/self/profile": body = ["id": 42, "name": "Fixture student"]
        case "/api/v1/courses/1/files":
            status = Self.state.filesStatus
            if url.query?.contains("page=2") == true { body = [file(3)] }
            else {
                body = [file(1), file(2)]
                headers["Link"] = "<https://canvas.new-files.test/api/v1/courses/1/files?page=2&per_page=100>; rel=\"next\""
            }
        case "/api/v1/courses/1/modules":
            body = [["id": 10, "name": "This week", "position": 1, "items_count": 3, "items": []]] as [[String: Any]]
        case "/api/v1/courses/1/modules/10/items":
            body = [["id": 21, "type": "File", "content_id": 4, "title": "Notes 4"],
                ["id": 22, "type": "Assignment", "content_id": 100, "title": "Assignment"],
                ["id": 23, "type": "Page", "page_url": "lecture", "title": "Lecture page"]] as [[String: Any]]
        case "/api/v1/courses/1/pages", "/api/v1/courses/1/folders": body = [] as [String]
        case "/api/v1/courses/1/pages/lecture": body = ["url": "lecture", "title": "Lecture page", "updated_at": "v2", "body": "No attachments this week."]
        case "/api/v1/courses/1/assignments":
            body = [["id": 100, "name": "Assignment", "description": "", "submission_types": [],
                "submission": ["workflow_state": "unsubmitted"]]] as [[String: Any]]
        case "/api/v1/courses/1": body = ["syllabus_body": ""]
        case "/api/v1/courses/1/assignments/100": body = ["id": 100, "name": "Assignment", "description": "Read the lecture notes.", "updated_at": "v2", "submission_types": []]
        case "/api/v1/courses/1/files/1", "/api/v1/courses/1/files/2", "/api/v1/courses/1/files/3", "/api/v1/courses/1/files/4": body = file(Int(url.lastPathComponent)!)
        case "/downloads/1", "/downloads/2", "/downloads/3", "/downloads/4":
            if url.lastPathComponent == "3" && Self.state.failNew { status = 503 }
        default: status = 404
        }
        let listing = isFiles || url.path == "/api/v1/courses/1/modules" || url.path == "/api/v1/courses/1/modules/10/items"
        if listing && status == 200 {
            headers["ETag"] = "\"new-file-fixture\""
            if request.value(forHTTPHeaderField: "If-None-Match") != nil { status = 304; Self.state.recordUnchanged() }
        }
        let download = url.path.hasPrefix("/downloads/")
        let data: Data
        if download { headers["Content-Type"] = "text/plain"; data = Data("New lecture notes. Read the model, examine the assumptions, and compare the prediction with the measurement. A long enough paragraph provides useful study context for this course.".utf8) }
        else { data = try! JSONSerialization.data(withJSONObject: body) }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        let work = DispatchWorkItem { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if status != 304 { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        if (download && Self.state.delayDownloads) || (isFiles && Self.state.delayMetadata) {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: work)
        } else { work.perform() }
    }
    override func stopLoading() { pending?.cancel() }
}
