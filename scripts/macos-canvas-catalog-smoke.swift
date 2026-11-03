import Foundation
import CoreGraphics
import CoreText
@testable import ScholiaMac

extension CanvasDownloadSmoke {
    static func checkCatalogCrawl() async throws {
        let origin = URL(string: "https://canvas.catalog.test")!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CanvasCatalogProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = CanvasClient(origin: origin, token: "fixture", session: session)
        let catalog = try await client.catalog(courseID: 24659)
        let ids = [1213943, 1213956, 1290422, 1267641, 1174749, 1174756, 1144828]
        precondition(Set(catalog.items.filter { $0.kind == .files }.map(\.remoteID)) == Set((ids + [77, 88, 99]).map(String.init)))
        let notebook = catalog.items.first { $0.id == "files:1213956" }!
        precondition(notebook.fileName == "Brownian.ipynb" && notebook.moduleTitle == "Weekly Plan")
        precondition(notebook.linkedFromTitle == "Week 35 - Brownian dynamics" && notebook.linkedSection == "Attachments")
        precondition(notebook.sourceURL == "https://canvas.catalog.test/courses/24659/files/1213956")
        let course = StudyCourse(name: "Canvas crawl", canvasMaterials: catalog.items)
        let groups = StudyMaterialOrganizer.groups(for: course)
        let weekly = groups.first { $0.id == "module:10" }!
        precondition(weekly.items.map(\.materialID) == ["pages:week-35-brownian-dynamics-2"]
            + ids.map { "files:\($0)" } + ["pages:nested", "files:88", "files:77"])
        precondition(groups.first { $0.id == "folder:2" }?.title == "Handouts")
        precondition(StudyMaterialOrganizer.groups(for: course, query: "Extra material").flatMap(\.items).count == 3)
        precondition(StudyMaterialOrganizer.files(for: course).count == 10)
        let fileCatalog = try await client.catalog(courseID: 24659, filesOnly: true)
        precondition(fileCatalog.items.allSatisfy { $0.kind == .files } && fileCatalog.items.count == 10)
        precondition(fileCatalog.items.first { $0.id == notebook.id }?.linkedFromTitle == notebook.linkedFromTitle)

        // Incomplete crawls must retain both link-only files and their grouping.
        var bare = notebook
        bare.moduleID = nil; bare.moduleTitle = nil; bare.moduleSection = nil
        bare.linkedFromID = nil; bare.linkedFromTitle = nil; bare.linkedOrder = nil
        bare.linkedPosition = nil; bare.linkedSection = nil
        let retained = CanvasCatalogChanges.reconcile(previous: [notebook, catalog.items.first { $0.id == "files:88" }!],
            catalog: CanvasMaterialCatalog(items: [bare], warnings: ["Page unavailable"], linkedContentComplete: false))
        precondition(retained.items.count == 2 && retained.changes.removed.isEmpty)
        precondition(retained.items.first { $0.id == notebook.id }?.linkedFromTitle == notebook.linkedFromTitle)
        let legacy = Data(#"{"id":"files:1","kind":"files","remoteID":"1","title":"Lecture 1.pdf","sourceURL":"https://canvas.catalog.test/files/1","version":"v1"}"#.utf8)
        let oldReference = try JSONDecoder().decode(CanvasMaterialReference.self, from: legacy)
        precondition(StudyMaterialOrganizer.groups(for: StudyCourse(name: "Old catalog", canvasMaterials: [oldReference])).first?.id == "lectures")
        let links = CanvasContentLinks.links(in: """
            <script>"<a href='/files/9'>"</script><a href='/files/1?wrap=1' data-api-endpoint='/api/v1/files/1'>one</a>
            <iframe src=/files/2/preview></iframe><a href='https://user@canvas.catalog.test/files/3'>bad</a>
            <a href='/courses/99/files/4'>wrong course</a>
            """, origin: origin, courseID: 24659)
        precondition(links.map(\.id) == ["files:1", "files:2"])
        print("PASS: Canvas module/page/folder grouping, all seven Brownian-style attachments, notebook and iframe discovery, nested pages, deduplication, file-only crawling, partial-refresh retention and old-catalog fallback")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-catalog-download-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let remoteCourse = StudyCourse(name: "Canvas crawl", canvasID: 24659, canvasOrigin: origin.absoluteString, canvasUserID: 42)
        try store.save(StudyLibrary(courses: [remoteCourse], canvasOrigin: origin.absoluteString, canvasUserID: 42))
        let workspace = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client })
        workspace.canvasDownloadPriority = .prioritized
        workspace.syncCanvasCourses(courseIDs: [remoteCourse.id], downloadAll: true)
        try await until { !workspace.canvasBusy }
        workspace.flush()
        let downloaded = try store.load().courses[0]
        precondition(downloaded.documents.count == 12, "Download all must include nested PDFs, notebook and both pages: \(workspace.canvasWarnings)")
        for id in ids + [88] {
            let document = downloaded.documents.first { $0.sourceKey == "files:\(id)" }!
            precondition(FileManager.default.fileExists(atPath: store.file(for: document).path))
            let text = try store.index(for: document).pages.map(\.text).joined(separator: "\n")
            precondition(text.contains("Brownian diffusion"), "Attachment \(id) must have a searchable text index")
            precondition(document.kind == (id == 1213956 ? .notebook : .pdf))
        }
        precondition(StudyMaterialOrganizer.files(for: downloaded).count == 10, "Saved attachments must not duplicate remote entries")
        print("PASS: native Download all saves and indexes every nested PDF and notebook attachment for offline reading and search")
    }
}

private final class CanvasCatalogProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "canvas.catalog.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, prefix = "/api/v1/courses/24659"
        var body: Any = [], status = 200, headers = ["Content-Type": "application/json"]
        switch url.path {
        case "/api/v1/users/self/profile": body = ["id": 42, "name": "Fixture student"]
        case prefix + "/files": body = [["id": 99, "display_name": "Lecture 99.pdf", "filename": "lecture99.pdf", "folder_id": 2]] as [[String: Any]]
        case prefix + "/pages": body = [["url": "week-35-brownian-dynamics-2", "title": "Week 35 - Brownian dynamics"]]
        case prefix + "/assignments": body = [] as [String]
        case prefix + "/modules":
            body = [["id": 10, "name": "Weekly Plan", "position": 1, "items_count": 3, "items": []]] as [[String: Any]]
        case prefix + "/modules/10/items":
            if url.query?.contains("page=2") == true {
                body = [["type": "File", "content_id": 77, "title": "Direct file", "position": 3]] as [[String: Any]]
            } else {
                body = [["type": "SubHeader", "title": "Weekly readings", "position": 1],
                    ["type": "Page", "page_url": "week-35-brownian-dynamics-2", "title": "Week 35 - Brownian dynamics", "position": 2]] as [[String: Any]]
                headers["Link"] = "<https://canvas.catalog.test\(prefix)/modules/10/items?page=2>; rel=\"next\""
            }
        case prefix + "/pages/week-35-brownian-dynamics-2":
            body = ["url": "week-35-brownian-dynamics-2", "title": "Week 35 - Brownian dynamics", "body": """
                <h3>Attachments</h3><a href='/courses/24659/files/1213943?wrap=1' data-api-endpoint='/api/v1/files/1213943'>Slides</a>
                <a href='../files/1213956?wrap=1'>Notebook</a><a href='/files/1290422/download'>Lecture</a>
                <h4>Partial answers</h4><a href='/files/1267641'>Answers</a>
                <h4>Extra material</h4><a href='/files/1174749'>Brown</a><a href='/files/1174756'>Einstein</a>
                <iframe src='/courses/24659/files/1144828/preview'></iframe>
                <h4>More</h4><a href='/courses/24659/pages/nested'>More</a>
                <a href='/courses/99/files/900'>Foreign course</a><a href='https://external.example/files/901'>External</a>
                """]
        case prefix + "/pages/nested":
            body = ["url": "nested", "title": "Further reading", "body": "<a href='week-35-brownian-dynamics-2'>Cycle</a><a href='/files/88/preview'>PDF</a>"]
        case prefix + "/folders":
            body = [["id": 1, "name": "course files"], ["id": 2, "name": "Handouts", "parent_folder_id": 1]] as [[String: Any]]
        case prefix: body = ["syllabus_body": ""]
        default:
            if url.path.hasPrefix(prefix + "/files/") { status = 403 }
            else if url.path.hasPrefix("/api/v1/files/"), let id = Int(url.lastPathComponent) {
                precondition(![900, 901].contains(id), "Never follow foreign course or external file IDs")
                body = ["id": id, "display_name": "Lecture \(id).pdf", "filename": id == 1213956 ? "Brownian.ipynb" : "lecture-\(id).pdf",
                    "hidden_for_user": true, "updated_at": "v1", "url": "https://canvas.catalog.test/downloads/\(id)"] as [String: Any]
            } else { status = 404 }
        }
        if url.path.hasPrefix("/downloads/") {
            let notebook = url.lastPathComponent == "1213956"
            headers["Content-Type"] = notebook ? "application/json" : "application/pdf"
            let data = notebook ? Data(##"{"cells":[{"cell_type":"markdown","source":["# Brownian diffusion\n","The diffusion coefficient controls mean squared displacement."]},{"cell_type":"code","source":["raise Exception('Never execute while indexing')"],"outputs":[]}],"nbformat":4,"nbformat_minor":5,"metadata":{}}"##.utf8) : Self.pdf()
            respond(url: url, status: 200, headers: headers, data: data)
            return
        }
        respond(url: url, status: status, headers: headers, data: try! JSONSerialization.data(withJSONObject: body))
    }
    private func respond(url: URL, status: Int, headers: [String: String], data: Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    private static func pdf() -> Data {
        let data = NSMutableData(), consumer = CGDataConsumer(data: data)!
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        for (index, line) in ["Brownian diffusion describes random motion and mean squared displacement.",
            "The diffusion coefficient connects molecular fluctuations with thermal energy.",
            "Compare the model assumptions with the measurements in the laboratory notebook."].enumerated() {
            let text = NSAttributedString(string: line,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)])
            context.textPosition = CGPoint(x: 30, y: 700 - 20 * index)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        context.endPDFPage(); context.closePDF()
        return data as Data
    }
    override func stopLoading() {}
}
