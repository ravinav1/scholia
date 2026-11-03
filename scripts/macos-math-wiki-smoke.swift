import Foundation
@testable import ScholiaMac

extension CanvasDownloadSmoke {
    static func checkMathWiki() async throws {
        let origin = URL(string: "https://canvas.ntnu.no")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MathWikiFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = CanvasClient(origin: origin, token: "private-canvas-fixture", session: session)
        let remote = StudyCourse(name: "Number theory", code: "MA1301-26H", canvasID: 1,
            canvasOrigin: origin.absoluteString, canvasUserID: 42, term: "2026 HØST")
        precondition(MathWikiScope.course(remote)?.terms == ["2026h"])
        precondition(MathWikiScope.course(StudyCourse(name: "Math", code: "TMA4145-25H"))?.terms == ["2025h"])
        precondition(MathWikiScope.course(StudyCourse(name: "Math", code: "TMA4121", term: "2026 VÅR"))?.terms == ["2026v"])
        precondition(MathWikiScope.course(StudyCourse(name: "Math", code: "MA1301"))?.terms == [])
        precondition(MathWikiScope.course(StudyCourse(name: "Other", code: "TDT4100-26H")) == nil)
        let catalog = try await client.catalog(course: remote)
        precondition(catalog.warnings.isEmpty, "\(catalog.warnings)")
        precondition(catalog.items.count == 5, "Expected Canvas file, two wiki pages, two wiki files: \(catalog.items.map(\.id))")
        precondition(catalog.items.filter { $0.isMathWiki && $0.kind == .files }.count == 2)
        let notes = catalog.items.first { $0.fileName == "notes.txt" }!
        precondition(notes.version == "v1" && notes.linkedFromTitle == "Number theory")
        let headAlias = MathWikiAddress.link("https://wiki.math.ntnu.no/lib/exe/fetch.php?media=ma1301:2026h:notes.txt")!
        precondition(headAlias.url.absoluteString == notes.sourceURL)
        let page = catalog.items.first { $0.isMathWiki && $0.kind == .pages }!
        let pageMaterial = try await client.material(page, courseID: 1)
        precondition(pageMaterial.text!.contains("<base href="))
        let retained = CanvasCatalogChanges.reconcile(previous: catalog.items,
            catalog: CanvasMaterialCatalog(items: [], warnings: ["Wiki unavailable"], completeKinds: [.files, .pages]))
        precondition(retained.items.count == 4 && retained.items.allSatisfy(\.isMathWiki), "Canvas completeness must not delete wiki entries")
        let removed = CanvasCatalogChanges.reconcile(previous: catalog.items,
            catalog: CanvasMaterialCatalog(items: [], warnings: [], mathWikiComplete: true))
        precondition(removed.items.count == 1 && !removed.items[0].isMathWiki)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-wiki-smoke-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        try store.save(StudyLibrary(courses: [remote], canvasOrigin: origin.absoluteString, canvasUserID: 42))
        let workspace = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client })
        workspace.canvasDownloadPriority = .prioritized
        workspace.syncCanvasCourses(courseIDs: [remote.id], downloadAll: true)
        try await until { !workspace.canvasBusy }
        workspace.flush()
        let saved = try store.load().courses[0]
        precondition(saved.documents.count == 5, "Wiki + Canvas imports failed: \(workspace.canvasWarnings)")
        for document in saved.documents {
            precondition(FileManager.default.fileExists(atPath: store.file(for: document).path))
            let index = try store.index(for: document)
            precondition(!index.pages.isEmpty)
        }
        let savedIDs = Set(saved.documents.map(\.id))
        workspace.syncCanvasCourses(courseIDs: [remote.id], downloadAll: true)
        try await until { !workspace.canvasBusy }
        workspace.flush()
        let reloaded = try store.load().courses[0]
        precondition(Set(reloaded.documents.map(\.id)) == savedIDs, "Repeated wiki imports must preserve document identity")
        print("PASS: exact-semester wiki + Canvas discovery, menu/staff attachments, credential isolation, alias deduplication, independent reconciliation, native offline imports and repeat sync")
        try await checkDedicatedWebsite(session: session)
        try await checkKnownDedicatedWebsite(session: session)
        try await checkAutomaticMathWiki()
        if CommandLine.arguments.contains("--wiki-live") {
            let live = try await MathWikiClient().catalog(course: StudyCourse(name: "Linear Methods", code: "TMA4145-26H", term: "2026 HØST"))
            precondition(live.warnings.isEmpty && live.items.count > 50, "Live wiki parse failed: \(live.warnings)")
            let first = live.items.first { $0.kind == .files && $0.fileName == "lecture_notes.pdf" }!
            let data = try await MathWikiClient().download(URL(string: first.sourceURL)!, limit: 100_000_000)
            precondition(data.starts(with: Data("%PDF-".utf8)))
            print("PASS: live TMA4145 2026h native crawl (\(live.items.count) materials) and PDF download (\(data.count) bytes)")
        }
        if CommandLine.arguments.contains("--website-live") {
            let client = MathWikiClient()
            let live = try await client.catalogWebsites(course: StudyCourse(name: "Algorithms", code: "TDT4120-26H", term: "2026 HØST"), discovered: [])
            precondition(live.items.contains { $0.sourceURL == "https://algdat.idi.ntnu.no/forelesn.html" })
            precondition(live.items.contains { $0.sourceURL.contains("%C3%B8vinger.html") || $0.sourceURL.contains("øvinger.html") })
            let syllabus = live.items.first { $0.fileName == "pensumhefte.pdf" }!
            let data = try await client.download(URL(string: syllabus.sourceURL)!, limit: 100_000_000)
            precondition(data.starts(with: Data("%PDF-".utf8)))
            print("PASS: live TDT4120 dedicated site (\(live.items.count) materials), exercise redirect and syllabus PDF (\(data.count) bytes). Site notices: \(live.warnings)")
        }
    }

    private static func checkKnownDedicatedWebsite(session: URLSession) async throws {
        let origin = "https://canvas.ntnu.no", website = "https://algdat.idi.ntnu.no/"
        let client = CanvasClient(origin: URL(string: origin)!, token: "private-canvas-fixture", session: session)
        let course = StudyCourse(name: "Algorithms", code: "TDT4120-26H", canvasID: 3,
            canvasOrigin: origin, canvasUserID: 42, term: "2026 HØST")
        precondition(CourseWebsiteAddress.knownSeeds(course: course).map(\.url.absoluteString) == [website])
        precondition(CourseWebsiteAddress.knownSeeds(course: StudyCourse(name: "TDT4120 Algorithms")).count == 1)
        precondition(CourseWebsiteAddress.knownSeeds(course: StudyCourse(name: "Algorithms", code: "TDT41201")).isEmpty)
        precondition(CourseWebsiteAddress.knownSeeds(course: StudyCourse(name: "Follow-up to TDT4120", code: "TDT4121")).isEmpty)
        precondition(CourseWebsiteAddress.knownSeeds(course: StudyCourse(name: "Algorithms", code: "TDT4120", canvasOrigin: "https://canvas.other.edu")).isEmpty)
        precondition(CourseWebsiteAddress.link(website + "inginious/course/TDT4120-2026") == nil)
        precondition(CourseWebsiteAddress.link(website + "queue/lectures") == nil)
        let norwegian = try MathWikiPage(data: Data("<!doctype html><html><head><meta charset='utf-8'></head><body><main><h1>Grådighet</h1><a href='/øvinger.html'>Øvinger</a></main></body></html>".utf8), website: true)
        precondition(norwegian.title == "Grådighet")
        precondition(CourseWebsiteAddress.link(norwegian.links[0].href, relativeTo: URL(string: website)!)?.url.path == "/øvinger.html",
            "HTML5 UTF-8 links must not be double encoded as Latin-1")
        let redirect = try CourseWebsiteAddress.redirect(in: Data("<html><head><meta http-equiv='refresh' content='0; url=/øvinger.html'></head></html>".utf8), relativeTo: URL(string: website)!)
        precondition(redirect?.path == "/øvinger.html")
        let catalog = try await client.catalog(course: course)
        precondition(catalog.warnings.isEmpty, "\(catalog.warnings)")
        precondition(catalog.items.count == 5 && catalog.items.allSatisfy { $0.isCourseWebsite && $0.websiteEvidenceURL == website })
        precondition(!catalog.items.contains { $0.sourceURL == website + "ovinger.html" }, "Redirect stubs must not become readings")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-algdat-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        try store.save(StudyLibrary(courses: [course], canvasOrigin: origin, canvasUserID: 42))
        let workspace = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client })
        workspace.canvasDownloadPriority = .prioritized
        workspace.syncCanvasCourses(courseIDs: [course.id], downloadAll: true)
        try await until { !workspace.canvasBusy }
        workspace.flush()
        let saved = try store.load().courses[0]
        precondition(saved.documents.count == 5, "Known site imports failed: \(workspace.canvasWarnings)")
        let search = try await workspace.fileSearch.search(courses: [saved], store: store, query: "greedy")
        precondition(search.total > 0, "Dedicated-site contents must participate in coursework search")
        print("PASS: native TDT4120 direct discovery without Canvas links, exact code/institution matching, public redirects, offline imports and coursework search")
    }

    private static func checkDedicatedWebsite(session: URLSession) async throws {
        let origin = URL(string: "https://canvas.ntnu.no")!
        let client = CanvasClient(origin: origin, token: "private-canvas-fixture", session: session)
        let remote = StudyCourse(name: "Algorithms", code: "TDT4120-26H", canvasID: 2,
            canvasOrigin: origin.absoluteString, canvasUserID: 42, term: "2026 HØST")
        let catalog = try await client.catalog(course: remote)
        precondition(catalog.warnings.isEmpty, "\(catalog.warnings)")
        precondition(catalog.items.count == 4 && catalog.items.allSatisfy(\.isCourseWebsite), "\(catalog.items.map(\.id))")
        precondition(catalog.items.allSatisfy { $0.websiteEvidenceURL?.contains("announcements") == true })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-website-smoke-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        try store.save(StudyLibrary(courses: [remote], canvasOrigin: origin.absoluteString, canvasUserID: 42))
        let workspace = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client })
        workspace.canvasDownloadPriority = .prioritized
        workspace.syncCanvasCourses(courseIDs: [remote.id], downloadAll: true)
        try await until { !workspace.canvasBusy }
        workspace.flush()
        let saved = try store.load().courses[0]
        precondition(saved.documents.count == 4, "Website import: \(workspace.canvasWarnings)")
        precondition(!CourseWebsiteAddress.within(URL(string: "https://teaching.ntnu.no/tdt4120/2026h-other/")!, seed: URL(string: "https://teaching.ntnu.no/tdt4120/2026h/")!))
        precondition(!CourseWebsiteAddress.within(URL(string: "https://teaching.ntnu.no/hub/login")!, seed: URL(string: "https://teaching.ntnu.no/")!))
        precondition((try? MathWikiPage(data: Data("<html><head><title>JupyterHub</title></head><body>Sign in with Feide</body></html>".utf8), website: true)) == nil)
        let documentURL = CourseWebsiteAddress.link("https://www.ntnu.no/documents/10422/123/Exam.pdf/abcd-1234?t=123")!
        precondition(documentURL.kind == .files && documentURL.fileName == "Exam.pdf")
        precondition(CourseWebsiteAddress.link("https://github.com/teacher/notes/edit/main/chapter.ipynb") == nil)
        precondition(CourseWebsiteAddress.link("https://colab.research.google.com/github/teacher/notes/blob/main/chapter.ipynb")?.url.absoluteString == "https://raw.githubusercontent.com/teacher/notes/main/chapter.ipynb")
        let retained = CanvasCatalogChanges.reconcile(previous: catalog.items,
            catalog: CanvasMaterialCatalog(items: [], warnings: [], completeKinds: [.pages, .files], mathWikiComplete: true))
        precondition(retained.items.count == 4)
        print("PASS: native discovery from older paginated announcements, bounded dedicated-site crawl, semester isolation and offline page/file imports")
    }

    private static func checkAutomaticMathWiki() async throws {
        let preference = UserDefaults.standard.object(forKey: "study.automaticallyUpdateMathWiki")
        defer {
            if let preference { UserDefaults.standard.set(preference, forKey: "study.automaticallyUpdateMathWiki") }
            else { UserDefaults.standard.removeObject(forKey: "study.automaticallyUpdateMathWiki") }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MathWikiRefreshProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-wiki-refresh-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root), origin = "https://canvas.ntnu.no"
        let canvasRef = CanvasMaterialReference(id: "files:1", kind: .files, remoteID: "1", title: "Canvas notes", sourceURL: origin + "/files/1", version: "canvas-1")
        let course = StudyCourse(name: "Number theory", code: "MA1301-26H", canvasID: 1, canvasOrigin: origin,
            canvasUserID: 42, canvasMaterials: [canvasRef], term: "2026 HØST")
        let archive = StudyCourse(name: "Old number theory", code: "MA1301-25H", canvasID: 2, canvasOrigin: origin, canvasUserID: 42, term: "2025 HØST")
        try store.save(StudyLibrary(courses: [course, archive], canvasOrigin: origin, canvasUserID: 42))
        var credentialReads = 0
        let workspace = StudyWorkspaceModel(store: store, mathWikiSession: session, canvasClientFactory: { _, _, _ in
            credentialReads += 1
            throw StudyError.message("Canvas is disconnected")
        })
        workspace.automaticallyUpdateMathWiki = true
        let now = ISO8601DateFormatter().date(from: "2026-10-04T12:00:00Z")!
        await workspace.refreshMathWikiIfNeeded(now: now)
        precondition(credentialReads == 0 && workspace.library.courses[0].documents.count == 2)
        precondition(workspace.library.courses[0].materials.contains(canvasRef))
        let ids = Set(workspace.library.courses[0].documents.map(\.id))
        let before = MathWikiRefreshProtocol.state.snapshot()
        await workspace.refreshMathWikiIfNeeded(now: now.addingTimeInterval(119))
        precondition(MathWikiRefreshProtocol.state.snapshot().requests == before.requests)
        let first = Task { await workspace.refreshMathWikiIfNeeded(now: now.addingTimeInterval(120)) }
        let second = Task { await workspace.refreshMathWikiIfNeeded(now: now.addingTimeInterval(120)) }
        await first.value; await second.value
        let after = MathWikiRefreshProtocol.state.snapshot()
        precondition(after.heads == before.heads && after.fileGets == before.fileGets && after.notModified > 0,
            "Unchanged wiki polls must use conditional pages and reuse attachment metadata")
        precondition(Set(workspace.library.courses[0].documents.map(\.id)) == ids)
        let noteIndex = workspace.library.courses[0].documents.firstIndex { $0.sourceURL?.hasSuffix("notes.txt") == true }!
        workspace.library.courses[0].documents[noteIndex].locallyEditedAt = now
        MathWikiRefreshProtocol.state.change()
        await workspace.refreshMathWikiIfNeeded(now: now.addingTimeInterval(240))
        precondition(workspace.library.courses[0].documents.count == 3, "Local edits must be preserved separately")
        precondition(workspace.library.courses[0].documents.contains { $0.sourceVersion == "file-2" })
        precondition(MathWikiRefreshProtocol.state.snapshot().heads == before.heads + 1,
            "Changed teaching pages must recheck their files immediately")
        var (prediction, _) = try trainedContentPolling()
        prediction.observe(at: now.addingTimeInterval(240), signature: "baseline", complete: true, interval: 120)
        prediction.attempt(at: now.addingTimeInterval(240), reason: .regular)
        workspace.library.courses[0].mathWikiPolling = prediction
        let beforePrediction = MathWikiRefreshProtocol.state.snapshot().requests
        await workspace.refreshMathWikiIfNeeded(now: now.addingTimeInterval(300))
        precondition(MathWikiRefreshProtocol.state.snapshot().requests > beforePrediction, "A learned window adds a check halfway to the regular deadline")
        precondition(workspace.library.courses[0].mathWikiUpdateAttemptedAt == now.addingTimeInterval(240))
        precondition(workspace.library.courses[0].mathWikiPolling?.extraChecks == [now.addingTimeInterval(300).timeIntervalSince1970])
        let checked = workspace.library.courses[0].mathWikiCheckedAt
        MathWikiRefreshProtocol.state.fail()
        await workspace.refreshMathWikiIfNeeded(now: now.addingTimeInterval(360))
        precondition(workspace.library.courses[0].mathWikiCheckedAt == checked && workspace.library.courses[0].materials.count == 3)
        precondition(workspace.library.courses[0].mathWikiWarnings?.joined().contains("503") == true)
        let failed = MathWikiRefreshProtocol.state.snapshot().requests
        await workspace.refreshMathWikiIfNeeded(now: now.addingTimeInterval(361))
        workspace.automaticallyUpdateMathWiki = false
        await workspace.refreshMathWikiIfNeeded(now: now.addingTimeInterval(600))
        precondition(MathWikiRefreshProtocol.state.snapshot().requests == failed && !workspace.canvasBusy)
        precondition(workspace.library.courses[1].mathWikiUpdateAttemptedAt == nil && credentialReads == 0)
        workspace.flush()
        let saved = try store.load().courses[0]
        precondition(saved.mathWikiPolling?.extraChecks.count == 1, "Prediction budget must persist")
        print("PASS: native two-minute wiki refresh without Canvas credentials, HTTP 304 reuse, file metadata pacing, single refresh, local-edit preservation, failed-source retention and opt-out")
    }
}

private final class MathWikiRefreshState: @unchecked Sendable {
    struct Snapshot { var requests = 0; var heads = 0; var fileGets = 0; var notModified = 0 }
    private let lock = NSLock()
    private var version = 1, failed = false, counts = Snapshot()
    func change() { lock.lock(); defer { lock.unlock() }; version += 1 }
    func fail() { lock.lock(); defer { lock.unlock() }; failed = true }
    func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return counts }
    func response(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.lock(); defer { lock.unlock() }
        counts.requests += 1
        precondition(request.url?.host == "wiki.math.ntnu.no", "No Canvas calls are allowed")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil)
        if failed { return (503, [:], Data()) }
        let url = request.url!
        if url.path.hasSuffix(".txt") {
            if request.httpMethod == "HEAD" { counts.heads += 1 } else { counts.fileGets += 1 }
            return (200, ["ETag": "file-\(version)", "Content-Type": "text/plain"], Data("Note \(version)".utf8))
        }
        let archive = url.path == "/ma1301", etag = archive ? "archive" : "page-\(version)"
        if request.value(forHTTPHeaderField: "If-None-Match") == etag {
            counts.notModified += 1
            return (304, ["ETag": etag], Data())
        }
        let body = archive ? "<a href='/ma1301/2026h/start'>Autumn 2026</a>"
            : "<h1>Number theory \(version)</h1><a href='/_media/ma1301/2026h/notes.txt'>Notes</a>"
        return (200, ["ETag": etag, "Content-Type": "text/html"], Data("<html><body><article><div class='content'>\(body)</div></article></body></html>".utf8))
    }
}

private final class MathWikiRefreshProtocol: URLProtocol, @unchecked Sendable {
    static let state = MathWikiRefreshState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, data) = Self.state.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class MathWikiFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        var headers = ["Content-Type": "text/html"], data = Data(), status = 200
        func html(_ body: String, menu: String = "") -> Data {
            Data("<html><head><title>Number theory</title></head><body><nav>\(menu)</nav><article><div class='content'>\(body)</div></article></body></html>".utf8)
        }
        if url.host == "canvas.ntnu.no" {
            precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer private-canvas-fixture")
            headers["Content-Type"] = "application/json"
            var object: Any = []
            switch url.path {
            case "/api/v1/users/self/profile": object = ["id": 42, "name": "Test"]
            case "/api/v1/courses/1": object = ["syllabus_body": ""]
            case "/api/v1/courses/2": object = ["syllabus_body": ""]
            case "/api/v1/courses/3": object = ["syllabus_body": ""]
            case "/api/v1/courses/2/discussion_topics":
                if url.query?.contains("page=2") == true {
                    object = [["message": "<p>Our course website for the lectures is <a href='https://s.ntnu.no/tdt4120'>here</a>.</p>", "html_url": "https://canvas.ntnu.no/courses/2/announcements/1"]]
                } else {
                    object = [["message": "Recent notice"]]
                    headers["Link"] = "<https://canvas.ntnu.no/api/v1/courses/2/discussion_topics?only_announcements=true&page=2>; rel=\"next\""
                }
            case "/api/v1/courses/1/files": object = [["id": 1, "display_name": "Canvas.txt", "filename": "Canvas.txt", "updated_at": "v1"]]
            case "/api/v1/courses/1/files/1": object = ["id": 1, "display_name": "Canvas.txt", "filename": "Canvas.txt", "updated_at": "v1", "url": "https://canvas.ntnu.no/download/1"]
            case "/download/1": headers["Content-Type"] = "text/plain"; data = Data("Canvas course notes".utf8)
            default: break
            }
            if data.isEmpty { data = try! JSONSerialization.data(withJSONObject: object) }
        } else {
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil)
            if request.httpMethod == "HEAD" { headers["ETag"] = "v1"; headers["Content-Length"] = "20" }
            else if url.host == "algdat.idi.ntnu.no" {
                switch url.path {
                case "", "/": data = html("<h1>TDT4120 Algorithms</h1><a href='forelesn.html'>Lectures</a><a href='pensum.txt'>Syllabus</a><a href='ovinger.html'>Exercises</a><a href='inginious/course/TDT4120-2026'>Private exercises</a><a href='queue/'>Queue</a>")
                case "/forelesn.html": data = html("<h1>Forelesninger</h1><a href='notes.txt'>Lecture notes</a>")
                case "/ovinger.html": data = Data("<html><head><meta http-equiv='refresh' content='0; url=/%C3%B8vinger.html'></head><body>Redirecting</body></html>".utf8)
                case "/øvinger.html": data = html("<h1>Øvinger</h1><p>Weekly exercises.</p>")
                case "/pensum.txt", "/notes.txt": headers["Content-Type"] = "text/plain"; data = Data("Greedy algorithms and dynamic programming.".utf8)
                default: preconditionFailure("Unexpected dedicated-site request: \(url)")
                }
            } else {
                switch url.path {
                case "/tdt4120": data = Data("<html><head><title>Shorty · Shorty</title></head><body><a class='action-button' href='https://teaching.ntnu.no/tdt4120/2026h/'>Yes, take me there!</a></body></html>".utf8)
                case "/ma1301": data = html("<a href='/ma1301/2027h/start'>Wrong</a><a href='/ma1301/2026h/start'>Correct</a>")
                case "/ma1301/2026h/start": data = html("""
                    <h1>Number theory</h1><a href='/_media/ma1301/2026h/notes.txt'>Notes</a>
                    <a href='/lib/exe/fetch.php?media=ma1301:2026h:notes.txt'>Same notes</a>
                    <a href='/ma1301/2025h/start'>Wrong semester</a><a href='/tma4145/2026h/start'>Wrong course</a>
                    <a href='/ma1301/2026h/start?do=edit'>Edit</a><script><a href='/ma1301/2026h/bad'>Bad</a></script>
                    """, menu: "<a href='/ma1301/2026h/exercises'>Exercises</a>")
                case "/ma1301/2026h/exercises": data = html("<h1>Exercises</h1><a href='start'>Cycle</a><a href='http://folk.ntnu.no/teacher/exercise.txt'>Exercise</a>")
                case "/tdt4120/2026h": data = html("<h1>Algorithms Autumn 2026</h1><a href='week1.html'>Week one</a><a href='notes.txt'>Notes</a><a href='../2025h/'>Wrong semester</a>")
                case "/tdt4120/2026h/week1.html": data = html("<h1>Week one</h1><a href='./'>Home</a><a href='https://folk.ntnu.no/teacher/exercise.txt'>Exercise</a>")
                case "/tdt4120/2026h/notes.txt": headers["Content-Type"] = "text/plain"; data = Data("Sorting algorithms and complexity".utf8)
                case "/_media/ma1301/2026h/notes.txt", "/teacher/exercise.txt": headers["Content-Type"] = "text/plain"; data = Data("Euclidean algorithm and modular arithmetic".utf8)
                default: status = 404; preconditionFailure("Unexpected wiki request: \(url)")
                }
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
