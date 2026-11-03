import Foundation

struct CourseWebsiteSource: Sendable { var html: String; var url: String }
struct CourseWebsiteSeed: Sendable { var url: URL; var evidenceURL: String?; var filesOnly = false }

enum CourseWebsiteAddress {
    /// Verified teaching sites whose hostname does not contain the course code.
    /// Keep in sync with knownCourseWebsiteSeeds in packages/core.
    static func knownSeeds(course: StudyCourse) -> [CourseWebsiteSeed] {
        guard course.canvasOrigin == nil || course.canvasOrigin == "https://canvas.ntnu.no" else { return [] }
        let known = ["TDT4120": "https://algdat.idi.ntnu.no/"]
        let expression = try! NSRegularExpression(pattern: #"\b[A-ZÆØÅ]{2,8}\d{3,5}\b"#, options: .caseInsensitive)
        func codes(_ text: String) -> [String] {
            expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                Range(match.range, in: text).map { String(text[$0]).uppercased() }
            }
        }
        let explicit = codes(course.code)
        return Set(explicit.isEmpty ? codes(course.name) : explicit).sorted().compactMap { code in
            guard let value = known[code], let url = URL(string: value) else { return nil }
            return CourseWebsiteSeed(url: url, evidenceURL: value)
        }
    }

    static func link(_ value: String, relativeTo base: URL = MathWikiAddress.origin) -> MathWikiAddress.Link? {
        guard let url = MathWikiAddress.teachingURL(value, relativeTo: base),
            url.path.range(of: #"(?:^|/)(?:login|logout|signin|signout|wp-admin|admin|ovsys|labregistrering|forum|ripes|git-pull|hub|inginious|queue)(?:/|$)"#, options: [.regularExpression, .caseInsensitive]) == nil else { return nil }
        if let math = MathWikiAddress.link(url.absoluteString) { return math }
        guard url.host != "wiki.math.ntnu.no" else { return nil }
        if url.path.range(of: #"\.(html?|php|aspx?)$"#, options: [.regularExpression, .caseInsensitive]) != nil
            || url.path.range(of: #"\.[a-z0-9]+$"#, options: [.regularExpression, .caseInsensitive]) == nil {
            return MathWikiAddress.Link(url: url, kind: .pages)
        }
        return nil
    }

    static func root(_ url: URL) -> URL {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        parts.query = nil; parts.fragment = nil
        if parts.path.range(of: #"/[a-zæøå]{2,8}\d{3,5}\.html?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            parts.path = parts.path.replacingOccurrences(of: #"\.html?$"#, with: "/", options: [.regularExpression, .caseInsensitive])
        } else if parts.path.range(of: #"\.[a-z0-9]+$|/(?:start|index|home)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            parts.path = String(parts.path.prefix(through: parts.path.lastIndex(of: "/")!))
        } else if !parts.path.hasSuffix("/") { parts.path += "/" }
        return parts.url!
    }

    static func within(_ url: URL, seed: URL) -> Bool {
        let root = root(seed)
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return link(url.absoluteString)?.kind == .pages && url.host == root.host && (url.path == seed.path || url.path == root.path || url.path.hasPrefix(prefix))
            && url.absoluteString.range(of: #"[?&](do|action)=(edit|login|logout|delete|history)"#, options: [.regularExpression, .caseInsensitive]) == nil
            && url.path.range(of: #"/(tags?|authors?|search|feed|wp-json|wp-admin)(/|$)"#, options: [.regularExpression, .caseInsensitive]) == nil
    }

    static func semesterMatches(_ value: String, course: StudyCourse) -> Bool {
        let terms = StudySemester.memberships(term: course.term, code: course.code, name: course.name).filter { $0.year != nil }
        let found = StudySemester.memberships(term: value.removingPercentEncoding ?? value, code: "", name: "").filter { $0.year != nil }
        return terms.isEmpty || found.isEmpty || found.contains(where: terms.contains)
    }

    static func redirect(in data: Data, relativeTo base: URL) throws -> URL? {
        let doc = try MathWikiPage.htmlDocument(data)
        guard let content = try doc.nodes(forXPath: "//meta[translate(@http-equiv,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='refresh']/@content").first?.stringValue,
            let range = content.range(of: #"^\s*0(?:\.0+)?\s*;\s*url\s*=\s*"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let target = String(content[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !target.isEmpty else { return nil }
        guard let link = link(target, relativeTo: base), link.kind == .pages else {
            throw StudyError.message("The course website redirects to a sign-in service or unsupported resource.")
        }
        return link.url
    }

    static func seeds(sources: [CourseWebsiteSource], course: StudyCourse) -> [CourseWebsiteSeed] {
        let expression = try! NSRegularExpression(pattern: #"\b[A-ZÆØÅ]{2,8}\d{3,5}\b"#, options: .caseInsensitive)
        let text = course.code + " " + course.name
        let codes = expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).lowercased() }
        }
        var seeds: [URL: CourseWebsiteSeed] = [:]
        for source in sources {
            guard let page = try? MathWikiPage(data: Data("<html><body><div class='content'>\(source.html)</div></body></html>".utf8)),
                let base = URL(string: source.url) else { continue }
            for raw in page.links {
                guard let link = link(raw.href, relativeTo: base), link.kind == .pages, link.url.host != base.host,
                    link.url.host != "wiki.math.ntnu.no",
                    link.url.path.range(of: #"/(studier/emner|studies/courses|employees|ansatte|people|profile|studiekvalitetsportalen)(/|$)"#,
                        options: [.regularExpression, .caseInsensitive]) == nil,
                    (link.url.host ?? "").range(of: #"^(git\.|gitlab\.|github\.com$|tp\.educloud\.no$)"#, options: [.regularExpression, .caseInsensitive]) == nil,
                    (link.url.host ?? "").range(of: #"\b(youtube|youtu\.be|vimeo|zoom|teams\.microsoft|mazemap|panopto|piazza|edstem|ovsys|mattelab\d*[hv]?)\b"#,
                        options: [.regularExpression, .caseInsensitive]) == nil else { continue }
                let cue = #"(course|class|subject|teaching)\s*(web\s*(site|page)|home\s*page|site)|(web\s*(site|page)|home\s*page)\s*(for|of)\s*(the\s*)?course|(emne|kurs|fag)(ets|et|s)?[-\s]*(nettside|hjemmeside|webside)|(nettside|hjemmeside)\s*(for|til)\s*(emnet|kurset|faget)"#
                if codes.contains(where: { link.url.absoluteString.lowercased().contains($0) })
                    || (raw.title + " " + raw.context).range(of: cue, options: [.regularExpression, .caseInsensitive]) != nil {
                    let filesOnly = raw.title.range(of: #"(old|past|previous|tidligere|gamle).{0,25}(exam|eksamen)|exam sets|eksamensoppgaver"#, options: [.regularExpression, .caseInsensitive]) != nil
                    seeds[link.url] = CourseWebsiteSeed(url: link.url, evidenceURL: source.url, filesOnly: filesOnly)
                }
            }
        }
        return seeds.values.sorted { $0.url.absoluteString < $1.url.absoluteString }
    }
}

extension MathWikiClient {
    private func websitePage(_ url: URL, permits: @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) {
        var next = url
        for _ in 0..<4 {
            let (data, response) = try await fetch(next, permits: permits)
            guard let redirect = try CourseWebsiteAddress.redirect(in: data, relativeTo: response.url ?? next) else { return (data, response) }
            next = redirect
        }
        throw StudyError.message("The course website redirected too many times.")
    }

    private func websiteEntry(_ seed: CourseWebsiteSeed, course: StudyCourse) async throws -> (CourseWebsiteSeed, Data, HTTPURLResponse) {
        var url = seed.url
        for _ in 0..<4 {
            let (data, response) = try await websitePage(url, permits: {
                CourseWebsiteAddress.link($0.absoluteString)?.kind == .pages &&
                    (seed.filesOnly || CourseWebsiteAddress.semesterMatches($0.absoluteString, course: course))
            })
            let finalURL = response.url ?? url
            guard finalURL.host == "s.ntnu.no" else {
                return (CourseWebsiteSeed(url: finalURL, evidenceURL: seed.evidenceURL, filesOnly: seed.filesOnly), data, response)
            }
            let doc = try MathWikiPage.htmlDocument(data)
            let target = try doc.nodes(forXPath: "//a[contains(concat(' ',normalize-space(@class),' '),' action-button ')]/@href").first?.stringValue
            guard let target, let link = CourseWebsiteAddress.link(target, relativeTo: finalURL), link.kind == .pages else {
                throw StudyError.message("The course short link points to a sign-in service or unsupported resource.")
            }
            url = link.url
        }
        throw StudyError.message("The course short link redirected too many times.")
    }

    func catalogWebsites(course: StudyCourse, discovered: [CourseWebsiteSeed]) async throws -> Catalog {
        var seeds = Dictionary(discovered.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        for ref in course.materials where ref.isCourseWebsite {
            if let root = ref.websiteRootURL.flatMap(URL.init(string:)) { seeds[root] = CourseWebsiteSeed(url: root, evidenceURL: ref.websiteEvidenceURL, filesOnly: ref.websiteFilesOnly == true) }
        }
        // Use the official homepage when Canvas supplies no current teaching
        // site, including courses which only link an old-exam archive.
        if !seeds.values.contains(where: { !$0.filesOnly && CourseWebsiteAddress.semesterMatches($0.url.absoluteString, course: course) }) {
            for seed in CourseWebsiteAddress.knownSeeds(course: course) { seeds[seed.url] = seed }
        }
        var items: [String: CanvasMaterialReference] = [:], warnings: [String] = [], roots = Set<URL>()
        for discoveredSeed in seeds.values.sorted(by: { $0.url.absoluteString < $1.url.absoluteString }) {
            guard discoveredSeed.filesOnly || CourseWebsiteAddress.semesterMatches(discoveredSeed.url.absoluteString, course: course) else {
                warnings.append("Course website: skipped a different semester: \(discoveredSeed.url.absoluteString)"); continue
            }
            let seed: CourseWebsiteSeed, firstData: Data, firstResponse: HTTPURLResponse
            do { (seed, firstData, firstResponse) = try await websiteEntry(discoveredSeed, course: course) }
            catch { try Task.checkCancellation(); warnings.append("Course website \(discoveredSeed.url): \(error.localizedDescription)"); continue }
            guard roots.insert(seed.url).inserted else { continue }
            var queue = [seed.url], visited = Set<URL>(), cursor = 0
            let permitted: @Sendable (URL) -> Bool = { CourseWebsiteAddress.within($0, seed: seed.url) && (seed.filesOnly || CourseWebsiteAddress.semesterMatches($0.absoluteString, course: course)) }
            while cursor < queue.count {
                try Task.checkCancellation()
                let url = queue[cursor]; cursor += 1
                if visited.contains(url) { continue }
                if visited.count >= 100 || items.count >= 1500 { warnings.append("Course website: crawl limit reached for \(seed.url)"); break }
                visited.insert(url)
                do {
                    let (data, response) = cursor == 1 ? (firstData, firstResponse) : try await websitePage(url, permits: permitted)
                    let finalURL = response.url ?? url
                    visited.insert(finalURL)
                    let page = try MathWikiPage(data: data, website: true)
                    guard !StudyHTML.plainText(page.body).isEmpty else { throw StudyError.message("The course website has no readable content. It may require sign-in or JavaScript.") }
                    guard seed.filesOnly || CourseWebsiteAddress.semesterMatches(page.title, course: course) else { throw StudyError.message("The page title names a different semester.") }
                    let id = "course-web:" + finalURL.absoluteString, folder = "Course website · \(seed.url.host ?? "")"
                    items[id] = CanvasMaterialReference(id: id, kind: .pages, remoteID: finalURL.absoluteString,
                        title: page.title, sourceURL: finalURL.absoluteString, version: page.version,
                        folderID: -2, folderTitle: folder, websiteRootURL: seed.url.absoluteString, websiteEvidenceURL: seed.evidenceURL, websiteFilesOnly: seed.filesOnly ? true : nil)
                    for (position, raw) in page.links.enumerated() {
                        guard let link = CourseWebsiteAddress.link(raw.href, relativeTo: finalURL) else { continue }
                        if link.kind == .pages {
                            if !seed.filesOnly, permitted(link.url), !visited.contains(link.url), !queue.contains(link.url) { queue.append(link.url) }
                        } else {
                            let fileID = "course-web:" + link.url.absoluteString, name = link.fileName ?? "File"
                            if items[fileID] == nil {
                                items[fileID] = CanvasMaterialReference(id: fileID, kind: .files, remoteID: link.url.absoluteString,
                                    title: raw.title.isEmpty || raw.title == name ? name : "\(raw.title) · \(name)", fileName: name,
                                    sourceURL: link.url.absoluteString, version: "", folderID: -2, folderTitle: folder,
                                    linkedFromID: id, linkedFromTitle: page.title, linkedPosition: position, linkedOrder: [position], linkedSection: raw.section,
                                    websiteRootURL: seed.url.absoluteString, websiteEvidenceURL: seed.evidenceURL, websiteFilesOnly: seed.filesOnly ? true : nil)
                            }
                        }
                    }
                } catch { try Task.checkCancellation(); warnings.append("Course website \(url): \(error.localizedDescription)") }
            }
        }
        let files = items.values.filter { $0.kind == .files }.sorted { $0.id < $1.id }
        try await withThrowingTaskGroup(of: CanvasMaterialReference.self) { group in
            var next = 0
            for ref in files.prefix(6) { group.addTask { try await self.fileMetadata(ref) }; next += 1 }
            for try await ref in group {
                items[ref.id] = ref
                if next < files.count {
                    let file = files[next]; next += 1
                    group.addTask { try await self.fileMetadata(file) }
                }
            }
        }
        return Catalog(items: items.values.sorted { $0.id < $1.id }, warnings: warnings, complete: warnings.isEmpty)
    }

    func websiteMaterial(_ ref: CanvasMaterialReference) async throws -> CanvasMaterial {
        guard ref.isCourseWebsite, let link = CourseWebsiteAddress.link(ref.sourceURL), link.kind == ref.kind else { throw StudyError.message("Invalid course website material.") }
        if ref.kind == .files {
            return CanvasMaterial(id: ref.id, title: ref.title, fileName: ref.fileName ?? link.url.lastPathComponent,
                downloadURL: link.url, sourceURL: ref.sourceURL, version: ref.version)
        }
        let root = ref.websiteRootURL.flatMap(URL.init(string:)) ?? link.url
        let (data, response) = try await websitePage(link.url, permits: { CourseWebsiteAddress.within($0, seed: root) })
        let page = try MathWikiPage(data: data, website: true)
        return CanvasMaterial(id: ref.id, title: ref.title, fileName: ref.title + ".html",
            text: StudyHTML.original(title: ref.title, body: page.body, source: (response.url ?? link.url).absoluteString),
            sourceURL: ref.sourceURL, version: page.version)
    }
}
