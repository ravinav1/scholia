import CryptoKit
import Foundation

extension CanvasMaterialReference {
    var isMathWiki: Bool { id.hasPrefix("math-wiki:") }
    var isCourseWebsite: Bool { id.hasPrefix("course-web:") }
}

struct MathWikiScope: Sendable {
    var code: String
    var terms: [String]

    static func course(_ course: StudyCourse) -> Self? {
        guard course.canvasOrigin == nil || course.canvasOrigin == "https://canvas.ntnu.no" else { return nil }
        let text = course.code + " " + course.name
        guard let range = text.range(of: #"\b(?:TMA|MA)\d{4}\b"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let terms = StudySemester.memberships(term: course.term, code: course.code, name: course.name).compactMap { semester -> String? in
            guard let year = semester.year, let half = semester.half else { return nil }
            return "\(year)\(half == 2 ? "h" : "v")"
        }
        return Self(code: text[range].lowercased(), terms: terms.sorted())
    }

    func permitsPage(_ url: URL, term: String) -> Bool {
        guard url.host == "wiki.math.ntnu.no" else { return false }
        let parts = url.path.lowercased().split(separator: "/").map(String.init)
        guard parts.count >= 2, parts.first == code else { return false }
        if parts.count == 2 && ["sidebar", "menu", "start"].contains(parts.last!) { return false }
        return !parts.contains { part in
            part.range(of: #"^(?:19|20)\d{2}$"#, options: .regularExpression) != nil
                || (part.range(of: #"^(?:19|20)\d{2}[hv]$"#, options: .regularExpression) != nil && part != term)
        }
    }
}

enum MathWikiAddress {
    static let origin = URL(string: "https://wiki.math.ntnu.no")!

    static func teachingURL(_ value: String, relativeTo base: URL = origin) -> URL? {
        guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: true),
            ["http", "https"].contains(parts.scheme), let host = parts.host?.lowercased(),
            parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
            host.contains("."), !host.contains(":"),
            host.range(of: #"^[\d.]+$|(?:^|\.)(?:localhost|local|internal|lan|home|test|invalid|example)$"#, options: .regularExpression) == nil
        else { return nil }
        parts.scheme = "https"
        parts.fragment = nil
        return parts.url
    }

    struct Link: Sendable {
        var url: URL
        var kind: CanvasMaterialKind
        var fileName: String? {
            guard kind == .files else { return nil }
            if url.path.hasPrefix("/documents/"), ["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx", "zip"].contains(url.deletingLastPathComponent().pathExtension.lowercased()) {
                return url.deletingLastPathComponent().lastPathComponent
            }
            return url.lastPathComponent
        }
    }

    static func link(_ value: String, relativeTo base: URL = origin) -> Link? {
        guard let safe = teachingURL(value, relativeTo: base), var parts = URLComponents(url: safe, resolvingAgainstBaseURL: true) else { return nil }
        if safe.host == "github.com", parts.path.range(of: #"^/[^/]+/[^/]+/edit/"#, options: .regularExpression) != nil { return nil }
        if safe.host == "colab.research.google.com", parts.path.range(of: #"^/github/[^/]+/[^/]+/blob/"#, options: .regularExpression) != nil {
            parts.host = "raw.githubusercontent.com"
            parts.path = String(parts.path.dropFirst("/github".count)).replacingOccurrences(of: "/blob/", with: "/")
            parts.query = nil
        }
        if safe.host == "github.com", parts.path.range(of: #"^/[^/]+/[^/]+/blob/"#, options: .regularExpression) != nil {
            parts.host = "raw.githubusercontent.com"
            parts.path = parts.path.replacingOccurrences(of: "/blob/", with: "/")
        }
        if parts.path.range(of: #"^/documents/\d+/\d+/[^/]+\.(pdf|docx?|pptx?|xlsx?|zip)/[^/]+/?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            parts.queryItems = parts.queryItems?.filter { $0.name != "t" }
            if parts.queryItems?.isEmpty == true { parts.query = nil }
            return parts.url.map { Link(url: $0, kind: .files) }
        }
        if safe.host == origin.host {
            let query = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            if let action = query["do"], !["", "show"].contains(action) { return nil }
            if query["rev"] != nil { return nil }
            if let media = query["media"], ["/lib/exe/fetch.php", "/lib/exe/detail.php"].contains(parts.path) {
                if media.hasPrefix("https://") || media.hasPrefix("http://") { return link(media, relativeTo: base) }
                parts.path = "/_media/" + media.trimmingCharacters(in: CharacterSet(charactersIn: ":")).replacingOccurrences(of: ":", with: "/")
            } else if parts.path.hasPrefix("/_detail/") {
                parts.path = parts.path.replacingOccurrences(of: "/_detail/", with: "/_media/")
            } else if let id = query["id"] { parts.path = "/" + id.replacingOccurrences(of: ":", with: "/") }
            if parts.path.hasPrefix("/_media/") {
                parts.query = nil
                return parts.url.map { Link(url: $0, kind: .files) }
            }
            if parts.path.range(of: #"\.[a-z0-9]+$"#, options: [.regularExpression, .caseInsensitive]) == nil {
                parts.query = nil
                parts.path = "/" + parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                return parts.url.map { Link(url: $0, kind: .pages) }
            }
        }
        guard parts.path.range(of: #"\.(pdf|ipynb|py|r|m|jl|txt|md|tex|csv|tsv|json|zip|docx?|pptx?|xlsx?|odt|ods|odp|png|jpe?g|webp|svg)$"#,
            options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return parts.url.map { Link(url: $0, kind: .files) }
    }
}

struct MathWikiPage: Sendable {
    struct Link: Sendable { var href: String; var title: String; var section: String?; var context: String = "" }
    var title: String
    var body: String
    var links: [Link]
    var version: String { SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined() }

    static func htmlDocument(_ data: Data) throws -> XMLDocument {
        // libxml's HTML4 parser ignores HTML5 <meta charset="utf-8"> and
        // otherwise treats Norwegian titles and URLs as Latin-1. A UTF-8 BOM
        // declares the encoding without changing HTML parsing to XML mode.
        let marker = Data([0xEF, 0xBB, 0xBF])
        let encoded = data.starts(with: marker) ? data : marker + data
        return try XMLDocument(data: encoded, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
    }

    init(data: Data, website: Bool = false) throws {
        // Foundation's inert HTML parser does not run scripts or load resources.
        // libxml's HTML4 parser flattens HTML5 nav elements. Preserve the
        // semester navigation as a div before parsing (without executing HTML).
        let markup = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: #"(?i)<nav\b"#, with: "<div data-scholia-menu=\"true\"", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</nav\s*>"#, with: "</div>", options: .regularExpression)
        let doc = try Self.htmlDocument(Data(markup.utf8))
        if website, !(try doc.nodes(forXPath: "//input[translate(@type,'PASSWORD','password')='password']")).isEmpty {
            throw StudyError.message("This course website requires a separate sign-in.")
        }
        if website, let heading = try doc.nodes(forXPath: "//title").first?.stringValue,
            heading.range(of: #"^\s*(JupyterHub|Shorty)(\s|·|$)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            throw StudyError.message("The website returned a sign-in or link-shortener page instead of course content.")
        }
        for node in try doc.nodes(forXPath: "//script|//style|//form|//iframe") { node.detach() }
        let preferred = try doc.nodes(forXPath: website ? "//main|//article|//*[@role='main']" : "//article//*[contains(concat(' ',normalize-space(@class),' '),' content ')]|//div[contains(concat(' ',normalize-space(@class),' '),' content ')]|//main").first
        let fallback = website ? try doc.nodes(forXPath: "//body").first : nil
        guard let content = preferred ?? fallback,
            (content.stringValue ?? "").range(of: #"does not exist yet|doesn't exist yet|finnes ikke ennå|finnes ikke enda"#,
                options: [.regularExpression, .caseInsensitive]) == nil
        else { throw StudyError.message("The wiki page is missing or unavailable.") }
        body = (content.children ?? []).map(\.xmlString).joined()
        let heading = try content.nodes(forXPath: ".//h1").first?.stringValue
        let documentTitle = try doc.nodes(forXPath: "//title").first?.stringValue?.replacingOccurrences(of: " - wiki.math.ntnu.no", with: "")
        title = (heading ?? documentTitle ?? "Math wiki").trimmingCharacters(in: .whitespacesAndNewlines)
        links = []
        var seen = Set<String>()
        let menus = try doc.nodes(forXPath: website ? "//body" : "//*[@data-scholia-menu='true']|//*[@id='menuframe']|//*[contains(concat(' ',normalize-space(@class),' '),' menuframe ')]")
        for scope in [content] + menus {
            var section: String?
            for node in try scope.nodes(forXPath: ".//h1|.//h2|.//h3|.//h4|.//h5|.//h6|.//a[@href]") {
                let text = (node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard node.name == "a", let element = node as? XMLElement else { section = text; continue }
                guard let href = element.attribute(forName: "href")?.stringValue,
                    !(element.attribute(forName: "class")?.stringValue ?? "").components(separatedBy: " ").contains("wikilink2"),
                    seen.insert(href).inserted else { continue }
                links.append(Link(href: href, title: text, section: section, context: String((node.parent?.stringValue ?? "").prefix(1500))))
            }
        }
    }
}

actor MathWikiClient {
    static let checkInterval: TimeInterval = 2 * 60
    static let fileCheckInterval: TimeInterval = 5 * 60
    struct Catalog: Sendable { var items: [CanvasMaterialReference]; var warnings: [String]; var complete: Bool; var websiteSources: [CourseWebsiteSource] = [] }
    private let session: URLSession
    private var pages: [URL: (Data, HTTPURLResponse)] = [:]
    private var files: [String: (Date, CanvasMaterialReference)] = [:]

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = session ?? URLSession(configuration: config)
    }

    func fetch(_ url: URL, method: String = "GET", limit: Int = 8_000_000, conditional: Bool = false,
        permits: @Sendable (URL) -> Bool = { _ in true }) async throws -> (Data, HTTPURLResponse) {
        var next = url
        for _ in 0..<6 {
            try Task.checkCancellation()
            guard let safe = MathWikiAddress.teachingURL(next.absoluteString), permits(safe) else {
                throw StudyError.message("The wiki redirected to an invalid address or a different course semester.")
            }
            var request = URLRequest(url: safe, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = method
            request.httpShouldHandleCookies = false
            let cached = conditional && method == "GET" ? pages[safe] : nil
            if let cached {
                request.setValue(cached.1.value(forHTTPHeaderField: "ETag"), forHTTPHeaderField: "If-None-Match")
                request.setValue(cached.1.value(forHTTPHeaderField: "Last-Modified"), forHTTPHeaderField: "If-Modified-Since")
            }
            // This session is deliberately separate from Canvas authorization.
            let (data, response) = try await CanvasDataTransfer(limit: limit, downloads: false).receive(request, session: session)
            if response.statusCode == 304, let cached, cached.0.count <= limit { return cached }
            if [301, 302, 303, 307, 308].contains(response.statusCode),
                let location = response.value(forHTTPHeaderField: "Location"), let redirected = URL(string: location, relativeTo: safe)?.absoluteURL {
                next = redirected
                continue
            }
            guard (200..<300).contains(response.statusCode) else {
                throw StudyError.message("Math wiki returned HTTP \(response.statusCode): \(safe.absoluteString)")
            }
            if conditional && method == "GET" {
                pages[safe] = (data, response)
                while pages.count > 200 || pages.values.reduce(0, { $0 + $1.0.count }) > 32_000_000 {
                    if let key = pages.keys.first { pages.removeValue(forKey: key) }
                }
            }
            return (data, response)
        }
        throw StudyError.message("The math wiki redirected too many times.")
    }

    func catalog(course: StudyCourse, fileRecheckInterval: TimeInterval = 0) async throws -> Catalog {
        guard let scope = MathWikiScope.course(course) else { return Catalog(items: [], warnings: [], complete: true) }
        guard !scope.terms.isEmpty else {
            return Catalog(items: [], warnings: ["Math wiki: no unambiguous course semester was found."], complete: false)
        }
        var items: [String: CanvasMaterialReference] = [:], warnings: [String] = [], websiteSources: [CourseWebsiteSource] = []
        for term in scope.terms {
            let prefix = MathWikiAddress.origin.appendingPathComponent("\(scope.code)/\(term)")
            do {
                let archiveURL = MathWikiAddress.origin.appendingPathComponent(scope.code)
                let archive = try MathWikiPage(data: await fetch(archiveURL, conditional: true, permits: {
                    $0 == archiveURL || $0 == archiveURL.appendingPathComponent("start")
                }).0)
                let linked = archive.links.compactMap { MathWikiAddress.link($0.href, relativeTo: archiveURL) }.first {
                    $0.kind == .pages && ($0.url == prefix || $0.url.absoluteString.hasPrefix(prefix.absoluteString + "/"))
                }
                var queue = [linked?.url ?? prefix.appendingPathComponent("start")], visited = Set<URL>(), cursor = 0
                while cursor < queue.count {
                    try Task.checkCancellation()
                    let url = queue[cursor]; cursor += 1
                    if visited.contains(url) { continue }
                    if visited.count >= 100 || items.count >= 1500 {
                        warnings.append("Math wiki \(term): the course crawl reached its limit.")
                        break
                    }
                    visited.insert(url)
                    do {
                        let (data, response) = try await fetch(url, conditional: true, permits: { scope.permitsPage($0, term: term) })
                        let finalURL = response.url ?? url
                        visited.insert(finalURL)
                        let page = try MathWikiPage(data: data), id = "math-wiki:" + finalURL.absoluteString
                        let navigation = page.links.map { "<p><a href=\"\(StudyHTML.escape($0.href))\">\(StudyHTML.escape($0.title))</a></p>" }.joined()
                        websiteSources.append(CourseWebsiteSource(html: page.body + navigation, url: finalURL.absoluteString))
                        items[id] = CanvasMaterialReference(id: id, kind: .pages, remoteID: finalURL.absoluteString,
                            title: page.title, sourceURL: finalURL.absoluteString, version: page.version,
                            folderID: -1, folderTitle: "Math wiki")
                        for (position, raw) in page.links.enumerated() {
                            guard let link = MathWikiAddress.link(raw.href, relativeTo: finalURL) else { continue }
                            if link.kind == .pages {
                                if scope.permitsPage(link.url, term: term), !visited.contains(link.url), !queue.contains(link.url) { queue.append(link.url) }
                            } else {
                                let fileID = "math-wiki:" + link.url.absoluteString, name = link.fileName ?? "File"
                                if items[fileID] == nil {
                                    items[fileID] = CanvasMaterialReference(id: fileID, kind: .files, remoteID: link.url.absoluteString,
                                        title: raw.title.isEmpty || raw.title == name ? name : "\(raw.title) · \(name)", fileName: name,
                                        sourceURL: link.url.absoluteString, version: "", folderID: -1, folderTitle: "Math wiki",
                                        linkedFromID: id, linkedFromTitle: page.title, linkedPosition: position,
                                        linkedOrder: [position], linkedSection: raw.section)
                                }
                            }
                        }
                    } catch {
                        try Task.checkCancellation()
                        warnings.append("Math wiki \(term): \(error.localizedDescription)")
                    }
                }
            } catch {
                try Task.checkCancellation()
                warnings.append("Math wiki \(term): \(error.localizedDescription)")
            }
        }
        let files = items.values.filter { $0.kind == .files }.sorted { $0.id < $1.id }
        let previous = Dictionary(course.materials.map { ($0.id, $0.version) }, uniquingKeysWith: { first, _ in first })
        let intervals = Dictionary(uniqueKeysWithValues: files.map { ref in
            (ref.id, ref.linkedFromID.map { previous[$0] == items[$0]?.version } == true ? fileRecheckInterval : 0)
        })
        try await withThrowingTaskGroup(of: CanvasMaterialReference.self) { group in
            var next = 0
            for ref in files.prefix(6) { let age = intervals[ref.id]!; group.addTask { try await self.fileMetadata(ref, recheckInterval: age) }; next += 1 }
            for try await ref in group {
                items[ref.id] = ref
                if next < files.count {
                    let file = files[next]; next += 1
                    let age = intervals[file.id]!
                    group.addTask { try await self.fileMetadata(file, recheckInterval: age) }
                }
            }
        }
        return Catalog(items: items.values.sorted { $0.id < $1.id }, warnings: warnings, complete: warnings.isEmpty, websiteSources: websiteSources)
    }

    func fileMetadata(_ reference: CanvasMaterialReference, recheckInterval: TimeInterval = 0) async throws -> CanvasMaterialReference {
        var ref = reference
        if let (checked, cached) = files[ref.id], Date().timeIntervalSince(checked) < recheckInterval {
            ref.version = cached.version; ref.byteCount = cached.byteCount
            return ref
        }
        do {
            let (_, response) = try await fetch(URL(string: ref.sourceURL)!, method: "HEAD", limit: StudyDocumentImporter.maximumBytes)
            ref.version = response.value(forHTTPHeaderField: "ETag") ?? response.value(forHTTPHeaderField: "Last-Modified") ?? ""
            ref.byteCount = response.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init)
        } catch { try Task.checkCancellation() }
        if ref.version.isEmpty { ref.version = "unvalidated:\(Date().timeIntervalSince1970)" }
        files[ref.id] = (Date(), ref)
        if files.count > 2000, let oldest = files.min(by: { $0.value.0 < $1.value.0 })?.key { files.removeValue(forKey: oldest) }
        return ref
    }

    func material(_ ref: CanvasMaterialReference) async throws -> CanvasMaterial {
        guard ref.isMathWiki, let link = MathWikiAddress.link(ref.sourceURL), link.kind == ref.kind else {
            throw StudyError.message("Invalid math wiki material.")
        }
        if ref.kind == .files {
            return CanvasMaterial(id: ref.id, title: ref.title, fileName: ref.fileName ?? link.url.lastPathComponent,
                downloadURL: link.url, sourceURL: ref.sourceURL, version: ref.version)
        }
        let (data, response) = try await fetch(link.url, conditional: true, permits: { $0 == link.url || $0 == link.url.appendingPathComponent("start") })
        let page = try MathWikiPage(data: data)
        return CanvasMaterial(id: ref.id, title: ref.title, fileName: ref.title + ".html",
            text: StudyHTML.original(title: ref.title, body: page.body, source: (response.url ?? link.url).absoluteString),
            sourceURL: ref.sourceURL, version: page.version)
    }

    func download(_ url: URL, limit: Int) async throws -> Data {
        let (data, response) = try await fetch(url, limit: min(limit, StudyDocumentImporter.maximumBytes))
        guard response.mimeType != "text/html" else { throw StudyError.message("The wiki file returned a sign-in or error page.") }
        return data
    }
}
