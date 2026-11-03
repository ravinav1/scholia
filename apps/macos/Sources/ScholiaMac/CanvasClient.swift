import CryptoKit
import Foundation
import SwiftUI
import WebKit

struct CanvasHTTPError: LocalizedError {
    let status: Int
    var requiresSignIn: Bool { [401, 301, 302, 303, 307, 308].contains(status) }
    var errorDescription: String? {
        switch status {
        case 401, 301, 302, 303, 307, 308: "Your Canvas sign-in has expired. Reconnect Canvas."
        case 403: "Canvas has not granted access to this resource."
        default: "Canvas returned HTTP \(status)."
        }
    }
}

struct CanvasAccount: Sendable {
    var id: Int
    var name: String
}
struct CanvasCourseSummary: Identifiable, Sendable {
    var id: Int
    var name: String
    var code: String
    var term: String?
    var favorite: Bool? = nil
}
enum CanvasMaterialKind: String, Codable, Hashable, Sendable {
    case syllabus, pages, files, assignments
}

/// A catalog entry contains no downloaded content or expiring signed URLs.
struct CanvasMaterialReference: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var kind: CanvasMaterialKind
    var remoteID: String
    var title: String
    var fileName: String?
    var sourceURL: String
    var version: String
    var byteCount: Int?
    var moduleID: Int?
    var moduleTitle: String?
    var modulePosition: Int?
    var moduleItemPosition: Int?
    var moduleSection: String?
    var folderID: Int?
    var folderTitle: String?
    var linkedFromID: String?
    var linkedFromTitle: String?
    var linkedPosition: Int?
    var linkedOrder: [Int]?
    var linkedSection: String?
    var assignment: CanvasAssignmentDetails?
    var websiteRootURL: String?
    var websiteEvidenceURL: String?
    var websiteFilesOnly: Bool?

    var unavailableReason: String? {
        if assignment?.locked == true { return "Locked in Canvas" }
        guard kind == .files else { return nil }
        if let byteCount, byteCount > StudyDocumentImporter.maximumBytes { return "Larger than 100 MB" }
        return nil  // Other files retain their original for the Mac app's Quick Look preview.
    }
    var symbol: String { kind == .files ? "doc.richtext" : kind == .assignments ? "checklist" : "doc.text" }
}
struct CanvasMaterialCatalog: Sendable {
    var items: [CanvasMaterialReference]
    var warnings: [String]
    var completeKinds: Set<CanvasMaterialKind> = []
    var moduleOrderComplete = false
    var linkedContentComplete = true
    var foldersComplete = false
    var mathWikiComplete = false
    var courseWebsitesComplete = false
    var websiteSources: [CourseWebsiteSource] = []
    var websiteDiscoveryComplete = true
}
struct CanvasMaterial: Identifiable, Sendable {
    var id: String
    var title: String
    var fileName: String
    var text: String?
    var downloadURL: URL?
    var sourceURL: String
    var version: String
    var assignment: CanvasAssignmentDetails?
}
struct CanvasMaterialList: Sendable {
    var items: [CanvasMaterial]
    var warnings: [String]
}

enum CanvasAddress {
    static func origin(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
            parts.scheme == "https", let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443
        else {
            throw StudyError.message("Enter your Canvas HTTPS address, such as canvas.ntnu.no.")
        }
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        guard let url = parts.url else { throw StudyError.message("This Canvas address is invalid.") }
        return url
    }
    static func sameOrigin(_ url: URL, _ origin: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == origin.host?.lowercased()
            && (url.port ?? 443) == (origin.port ?? 443) && url.user == nil && url.password == nil
    }
    static func nextPage(_ header: String?, current: URL, origin: URL) -> URL? {
        guard
            let part = header?.components(separatedBy: ",").first(where: {
                $0.range(of: ";\\s*rel=\"?next\"?", options: .regularExpression) != nil
            }),
            let left = part.firstIndex(of: "<"), let right = part.firstIndex(of: ">"), left < right,
            let url = URL(string: String(part[part.index(after: left)..<right]), relativeTo: current)?.absoluteURL,
            sameOrigin(url, origin), url.path == current.path
        else { return nil }
        return url
    }
}

/// API redirects are refused. Download redirects may use signed HTTPS storage
/// URLs, but never carry a Canvas credential to another host.
final class CanvasRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    let downloads: Bool
    init(downloads: Bool) { self.downloads = downloads }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard downloads, let url = request.url, url.scheme == "https", url.user == nil, url.password == nil else {
            completionHandler(nil)
            return
        }
        let safe = redirectedRequest(request, response: response, original: task.originalRequest)
        completionHandler(safe)
    }
    func redirectedRequest(_ request: URLRequest, response: HTTPURLResponse, original: URLRequest?) -> URLRequest? {
        guard downloads, let url = request.url, url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        var safe = request
        let sameOrigin = original?.url.map { origin in
            response.url.map { CanvasAddress.sameOrigin($0, origin) } == true && CanvasAddress.sameOrigin(url, origin)
        } == true
        for field in ["Authorization", "Cookie"] {
            safe.setValue(sameOrigin ? original?.value(forHTTPHeaderField: field) : nil, forHTTPHeaderField: field)
        }
        safe.httpShouldHandleCookies = false
        return safe
    }
}

actor CanvasClient {
    private struct CachedResponse: Sendable {
        var data: Data
        var response: HTTPURLResponse
    }
    let origin: URL
    private let cookieHeader: String
    private let token: String
    private let cookies: (@Sendable (URL) async throws -> String)?
    private let receiveCookies: (@Sendable (URL, [String: String]) async throws -> Void)?
    private let apiSession: URLSession
    private let downloadSession: URLSession
    private let mathWiki: MathWikiClient
    private var metadataCache: [String: CachedResponse] = [:]
    private var cacheOrder: [String] = []
    private var cacheBytes = 0
    private var retryAfter: Date?

    /// Only called after both clients have authenticated as the same account.
    func reuseMetadata(from previous: CanvasClient) async {
        guard previous !== self, previous.origin == origin else { return }
        let (entries, order, bytes) = await previous.cachedMetadata()
        metadataCache = entries
        cacheOrder = order
        cacheBytes = bytes
    }
    private func cachedMetadata() -> ([String: CachedResponse], [String], Int) {
        (metadataCache, cacheOrder, cacheBytes)
    }
    private func cache(_ data: Data, response: HTTPURLResponse, key: String) {
        cacheBytes -= metadataCache.removeValue(forKey: key)?.data.count ?? 0
        cacheOrder.removeAll { $0 == key }
        guard
            response.value(forHTTPHeaderField: "ETag") != nil
                || response.value(forHTTPHeaderField: "Last-Modified") != nil
        else { return }
        metadataCache[key] = CachedResponse(data: data, response: response)
        cacheBytes += data.count
        cacheOrder.append(key)
        while cacheBytes > 32_000_000 || cacheOrder.count > 600 {
            let oldest = cacheOrder.removeFirst()
            cacheBytes -= metadataCache.removeValue(forKey: oldest)?.data.count ?? 0
        }
    }

    init(origin: URL, cookieHeader: String = "", token: String = "", session: URLSession? = nil,
        mathWikiClient: MathWikiClient? = nil,
        cookies: (@Sendable (URL) async throws -> String)? = nil,
        receiveCookies: (@Sendable (URL, [String: String]) async throws -> Void)? = nil) {
        self.origin = origin
        self.cookieHeader = cookieHeader
        self.token = token
        self.cookies = cookies
        self.receiveCookies = receiveCookies
        self.mathWiki = mathWikiClient ?? MathWikiClient(session: session)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 40
        config.timeoutIntervalForResource = 180
        config.httpMaximumConnectionsPerHost = CanvasDownloadScheduling.maximumConcurrentDownloads
        apiSession =
            session
            ?? URLSession(configuration: config, delegate: CanvasRedirectPolicy(downloads: false), delegateQueue: nil)
        downloadSession =
            session
            ?? URLSession(configuration: config, delegate: CanvasRedirectPolicy(downloads: true), delegateQueue: nil)
    }

    func account() async throws -> CanvasAccount {
        let item = try await object("/api/v1/users/self/profile")
        guard let id = item["id"] as? Int, let name = item["name"] as? String else {
            throw StudyError.message("Canvas did not return an account. Sign in and try again.")
        }
        return CanvasAccount(id: id, name: name)
    }

    func courses() async throws -> [CanvasCourseSummary] {
        // No enrollment-state filter: include accessible past courses as well as current ones.
        // include[]=favorites returns the user's explicit stars, not Canvas's default dashboard selection.
        let records = try await list(
            "/api/v1/courses?include[]=term&include[]=favorites&state[]=available&state[]=completed")
        var seen = Set<Int>()
        return records.compactMap { item in
            guard let id = item["id"] as? Int, let name = item["name"] as? String,
                item["workflow_state"] as? String != "deleted", seen.insert(id).inserted
            else { return nil }
            return CanvasCourseSummary(
                id: id, name: name, code: item["course_code"] as? String ?? "",
                term: (item["term"] as? [String: Any])?["name"] as? String,
                favorite: item["is_favorite"] as? Bool)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func assignmentUpdates(courseID: Int) async throws -> [CanvasMaterialReference] {
        // Submission state can change without the assignment's updated_at or
        // Last-Modified value changing. Always fetch the current student state.
        let records = try await assignmentRecords(courseID: courseID)
        return records.compactMap { assignmentReference($0, courseID: courseID) }
    }

    func assignmentUpdate(courseID: Int, id: String) async throws -> CanvasMaterialReference {
        let record = try await assignmentRecord(courseID: courseID, id: id)
        guard let reference = assignmentReference(record, courseID: courseID) else {
            throw StudyError.message("This assignment is no longer available in Canvas.")
        }
        return reference
    }

    private func assignmentReference(_ record: [String: Any], courseID: Int) -> CanvasMaterialReference? {
        guard let id = record["id"] as? Int, Self.listable(record, kind: .assignments) else { return nil }
        return CanvasMaterialReference(id: "assignments:\(id)", kind: .assignments, remoteID: String(id),
            title: record["name"] as? String ?? "Assignment \(id)",
            sourceURL: origin.absoluteString + "/courses/\(courseID)/assignments/\(id)",
            version: Self.materialVersion(record, kind: .assignments),
            assignment: CanvasAssignmentDetails(record: record, origin: origin, courseID: courseID))
    }

    private func assignmentRecords(courseID: Int) async throws -> [[String: Any]] {
        let records = try await list("/api/v1/courses/\(courseID)/assignments?include[]=submission", revalidate: false)
        return try await withSubmissionDetails(records, courseID: courseID)
    }

    private func assignmentRecord(courseID: Int, id: String) async throws -> [String: Any] {
        let record = try await object("/api/v1/courses/\(courseID)/assignments/\(Self.component(id))?include[]=submission")
        return try await withSubmissionDetails([record], courseID: courseID, assignmentID: id).first ?? record
    }

    func assignmentDetails(courseID: Int, id: String) async throws -> CanvasAssignmentDetails {
        let record = try await assignmentRecord(courseID: courseID, id: id)
        return CanvasAssignmentDetails(record: record, origin: origin, courseID: courseID)
    }

    private func withSubmissionDetails(_ records: [[String: Any]], courseID: Int, assignmentID: String? = nil)
        async throws -> [[String: Any]] {
        guard !records.isEmpty else { return records }
        // Omitting student_ids limits this endpoint to the signed-in student's own submissions.
        // Fetch comments once per course, independently of assignment content/version caching.
        let filter = assignmentID.map { "&assignment_ids[]=\(Self.component($0))" } ?? ""
        let submissions: [[String: Any]]
        do {
            submissions = try await list(
                "/api/v1/courses/\(courseID)/students/submissions?include[]=submission_comments&include[]=rubric_assessment" + filter,
                revalidate: false)
        } catch let error as CanvasHTTPError where [403, 404].contains(error.status) {
            // Some enrollments/token scopes allow assignment status but not submission comments.
            guard let assignmentID else { return records }
            do {
                submissions = [try await object("/api/v1/courses/\(courseID)/assignments/\(Self.component(assignmentID))/submissions/self?include[]=submission_comments&include[]=rubric_assessment")]
            } catch {
                try Task.checkCancellation()
                if (error as? CanvasHTTPError)?.requiresSignIn == true { throw error }
                return records
            }
        } catch {
            try Task.checkCancellation()
            if (error as? CanvasHTTPError)?.requiresSignIn == true { throw error }
            // Feedback is optional. Its endpoint can fail while the assignment
            // response already contains a newer deadline and submission state.
            return records
        }
        var byAssignment: [Int: [String: Any]] = [:]
        for submission in submissions {
            if let id = submission["assignment_id"] as? Int { byAssignment[id] = submission }
        }
        return records.map { record in
            guard let id = record["id"] as? Int, let submission = byAssignment[id] else { return record }
            var record = record
            var combined = record["submission"] as? [String: Any] ?? [:]
            combined.merge(submission) { _, current in current }
            record["submission"] = combined
            return record
        }
    }

    func catalog(course: StudyCourse, filesOnly: Bool = false, includePublic: Bool = true) async throws -> CanvasMaterialCatalog {
        guard let courseID = course.canvasID else { throw StudyError.message("Course not found.") }
        var result = try await catalog(courseID: courseID, filesOnly: filesOnly, discoverWebsites: includePublic)
        guard includePublic else { return result }
        let wiki = try await mathWiki.catalog(course: course)
        result.items += wiki.items.filter { !filesOnly || $0.kind == .files }
        result.warnings += wiki.warnings
        result.mathWikiComplete = wiki.complete && !filesOnly
        let seeds = CourseWebsiteAddress.seeds(sources: result.websiteSources + wiki.websiteSources, course: course)
        let sites = try await mathWiki.catalogWebsites(course: course, discovered: seeds)
        let wikiURLs = Set(wiki.items.map(\.sourceURL))
        result.items += sites.items.filter { (!filesOnly || $0.kind == .files) && !wikiURLs.contains($0.sourceURL) }
        result.warnings += sites.warnings
        result.courseWebsitesComplete = sites.complete && result.websiteDiscoveryComplete && !filesOnly
        return result
    }

    func catalog(courseID: Int, filesOnly: Bool = false, discoverWebsites: Bool = false) async throws -> CanvasMaterialCatalog {
        let prefix = "/api/v1/courses/\(courseID)"
        let source = origin.absoluteString + "/courses/\(courseID)"
        var warnings: [String] = []
        var completeKinds: Set<CanvasMaterialKind> = []
        var moduleOrderComplete = false
        var linkedContentComplete = true
        var foldersComplete = false
        var candidates: [String: CanvasMaterialReference] = [:]
        var bodies: [String: String] = [:]
        var websiteSources: [CourseWebsiteSource] = []
        var websiteDiscoveryComplete = true
        func add(_ kind: CanvasMaterialKind, _ id: String, _ record: [String: Any], linkedFile: Bool = false) {
            let key = "\(kind.rawValue):\(id)"
            guard candidates[key] == nil,
                linkedFile ? Self.accessible(record, linkedFile: true) : Self.listable(record, kind: kind) else { return }
            let title =
                record["title"] as? String ?? record["display_name"] as? String ?? record["name"] as? String ?? id
            candidates[key] = CanvasMaterialReference(
                id: key, kind: kind, remoteID: id, title: title,
                fileName: record["filename"] as? String, sourceURL: source + "/\(kind.rawValue)/\(Self.component(id))",
                version: Self.materialVersion(record, kind: kind), byteCount: record["size"] as? Int,
                folderID: kind == .files ? record["folder_id"] as? Int : nil,
                assignment: kind == .assignments && record["submission_types"] != nil
                    ? CanvasAssignmentDetails(record: record, origin: origin, courseID: courseID) : nil)
            if kind == .pages, let body = record["body"] as? String { bodies[key] = body }
            if kind == .assignments, record["submission_types"] != nil || record["description"] != nil {
                bodies[key] = record["locked_for_user"] as? Bool == true ? "" : record["description"] as? String ?? ""
            }
        }
        // Even file-only discovery must read pages/assignments: a hidden Files
        // tab can leave their embedded links as the only source of attachments.
        for collection in ["pages", "files", "assignments", "modules"] {
            try Task.checkCancellation()
            do {
                let include =
                    collection == "modules"
                    ? "?include[]=items&include[]=content_details" : collection == "assignments" && !filesOnly ? "?include[]=submission" : ""
                var records = try await collection == "assignments" && !filesOnly
                    ? assignmentRecords(courseID: courseID)
                    : list(prefix + "/" + collection + include)
                if collection == "modules" {
                    moduleOrderComplete = true
                    records.sort { ($0["position"] as? Int ?? 0) < ($1["position"] as? Int ?? 0) }
                }
                if let kind = CanvasMaterialKind(rawValue: collection), !filesOnly || kind == .files { completeKinds.insert(kind) }
                for record in records where Self.listable(record, kind: CanvasMaterialKind(rawValue: collection)) {
                    if collection == "modules" {
                        guard let moduleID = record["id"] as? Int, record["state"] as? String != "locked" else {
                            continue
                        }
                        do {
                            let inline = record["items"] as? [[String: Any]] ?? []
                            let listedItems =
                                inline.count >= (record["items_count"] as? Int ?? Int.max)
                                ? inline : try await list(prefix + "/modules/\(moduleID)/items?include[]=content_details")
                            let items = listedItems.sorted { ($0["position"] as? Int ?? 0) < ($1["position"] as? Int ?? 0) }
                            var section: String?
                            for (itemIndex, item) in items.enumerated() where Self.accessible(item) {
                                if (item["content_details"] as? [String: Any])?["locked_for_user"] as? Bool == true {
                                    continue
                                }
                                if item["type"] as? String == "SubHeader" {
                                    section = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                                    continue
                                }
                                var key: String?
                                switch item["type"] as? String {
                                case "Page":
                                    if let slug = item["page_url"] as? String {
                                        add(.pages, slug, item)
                                        key = "pages:\(slug)"
                                    }
                                case "File":
                                    if let id = item["content_id"] as? Int {
                                        add(.files, String(id), item)
                                        key = "files:\(id)"
                                    }
                                case "Assignment":
                                    if let id = item["content_id"] as? Int {
                                        let assignmentKey = "assignments:\(id)"
                                        key = assignmentKey
                                        if candidates[assignmentKey] == nil {
                                            do {
                                                let detail = try await assignmentRecord(courseID: courseID, id: String(id))
                                                add(.assignments, String(id), detail)
                                            } catch {
                                                try Task.checkCancellation()
                                                add(.assignments, String(id), item)
                                                warnings.append("Assignment \(id): \(error.localizedDescription)")
                                            }
                                        }
                                    }
                                case "ExternalUrl":
                                    if let value = item["external_url"] as? String {
                                        websiteSources.append(CourseWebsiteSource(html: "<a href=\"\(StudyHTML.escape(value))\">\(StudyHTML.escape(item["title"] as? String ?? ""))</a>", url: source + "/modules"))
                                    }
                                    if let value = item["external_url"] as? String,
                                        let link = CanvasContentLinks.resolve(value, origin: origin, courseID: courseID) {
                                        add(link.kind, link.remoteID, item)
                                        key = link.id
                                    }
                                default: break
                                }
                                if let key, candidates[key]?.moduleID == nil {
                                    candidates[key]?.moduleID = moduleID
                                    candidates[key]?.moduleTitle = record["name"] as? String ?? "Module \(moduleID)"
                                    candidates[key]?.modulePosition =
                                        record["position"] as? Int ?? records.firstIndex(where: {
                                            ($0["id"] as? Int) == moduleID
                                        }) ?? 0
                                    candidates[key]?.moduleItemPosition = item["position"] as? Int ?? itemIndex
                                    candidates[key]?.moduleSection = section
                                }
                            }
                        } catch {
                            moduleOrderComplete = false
                            try Task.checkCancellation()
                            if filesOnly, (error as? CanvasHTTPError)?.requiresSignIn == true
                                || (error as? KeychainStoreError)?.needsInteraction == true { throw error }
                            warnings.append("Module \(moduleID): \(error.localizedDescription)")
                        }
                    } else if collection == "pages", let slug = record["url"] as? String {
                        add(.pages, slug, record)
                    } else if let id = record["id"] as? Int, let kind = CanvasMaterialKind(rawValue: collection) {
                        add(kind, String(id), record)
                    }
                }
            } catch {
                try Task.checkCancellation()
                if filesOnly, (error as? CanvasHTTPError)?.requiresSignIn == true
                    || (error as? KeychainStoreError)?.needsInteraction == true { throw error }
                warnings.append("\(collection.capitalized): \(error.localizedDescription)")
                if collection == "pages" || collection == "assignments" { linkedContentComplete = false }
            }
        }
        if !filesOnly || discoverWebsites {
            do {
                let info = try await object(prefix + "?include[]=syllabus_body", revalidate: true)
                completeKinds.insert(.syllabus)
                if let body = info["syllabus_body"] as? String,
                    !StudyHTML.plainText(body).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    candidates["syllabus"] = CanvasMaterialReference(
                        id: "syllabus", kind: .syllabus, remoteID: "syllabus", title: "Course syllabus",
                        sourceURL: source + "/assignments/syllabus",
                        version: SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined())
                    bodies["syllabus"] = body
                }
            } catch {
                try Task.checkCancellation()
                warnings.append("Syllabus: \(error.localizedDescription)")
                linkedContentComplete = false
            }
        }
        var queue = candidates.values.filter { $0.kind != .files }.sorted {
            if $0.modulePosition != $1.modulePosition { return ($0.modulePosition ?? .max) < ($1.modulePosition ?? .max) }
            if $0.moduleItemPosition != $1.moduleItemPosition { return ($0.moduleItemPosition ?? .max) < ($1.moduleItemPosition ?? .max) }
            return $0.id < $1.id
        }.map(\.id)
        var visited: Set<String> = [], failed: Set<String> = []
        var cursor = 0
        while cursor < queue.count {
            try Task.checkCancellation()
            let key = queue[cursor]
            cursor += 1
            guard visited.insert(key).inserted, var parent = candidates[key] else { continue }
            do {
                if bodies[key] == nil {
                    let detail = try await object(prefix + "/\(parent.kind.rawValue)/\(Self.component(parent.remoteID))", revalidate: true)
                    guard Self.accessible(detail) else { candidates.removeValue(forKey: key); continue }
                    parent.title = detail["title"] as? String ?? detail["name"] as? String ?? parent.title
                    parent.version = Self.materialVersion(detail, kind: parent.kind)
                    candidates[key] = parent
                    bodies[key] = detail["body"] as? String ?? detail["description"] as? String ?? ""
                }
                let links = CanvasContentLinks.links(in: bodies[key] ?? "", origin: origin, courseID: courseID,
                    sourceURL: URL(string: parent.sourceURL))
                for (position, link) in links.enumerated() {
                    guard link.id != key, !visited.contains(link.id), !failed.contains(link.id) else { continue }
                    if candidates[link.id] == nil {
                        do {
                            if link.kind == .files {
                                candidates[link.id] = try await fileReference(id: link.remoteID, courseID: courseID)
                            } else {
                                let detail = try await object(prefix + "/\(link.kind.rawValue)/\(Self.component(link.remoteID))", revalidate: true)
                                add(link.kind, link.remoteID, detail)
                            }
                        } catch {
                            try Task.checkCancellation()
                            if filesOnly, (error as? CanvasHTTPError)?.requiresSignIn == true
                                || (error as? KeychainStoreError)?.needsInteraction == true { throw error }
                            failed.insert(link.id)
                            linkedContentComplete = false
                            warnings.append("\(parent.title) → \(link.id): \(error.localizedDescription)")
                            continue
                        }
                    }
                    candidates[link.id]?.inheritGrouping(from: parent, position: position, section: link.section)
                    if link.kind != .files, candidates[link.id] != nil { queue.append(link.id) }
                }
            } catch {
                try Task.checkCancellation()
                if filesOnly, (error as? CanvasHTTPError)?.requiresSignIn == true
                    || (error as? KeychainStoreError)?.needsInteraction == true { throw error }
                linkedContentComplete = false
                warnings.append("\(parent.title): \(error.localizedDescription)")
            }
        }
        do {
            let records = try await list(prefix + "/folders")
            let folders = Dictionary(records.compactMap { record in (record["id"] as? Int).map { ($0, record) } },
                uniquingKeysWith: { first, _ in first })
            for key in Array(candidates.keys) {
                let title = CanvasContentLinks.folderTitle(candidates[key]?.folderID, folders: folders)
                candidates[key]?.folderTitle = title
            }
            foldersComplete = true
        } catch {
            try Task.checkCancellation()
            if filesOnly, (error as? CanvasHTTPError)?.requiresSignIn == true
                || (error as? KeychainStoreError)?.needsInteraction == true { throw error }
            if ![403, 404].contains((error as? CanvasHTTPError)?.status ?? 0) {
                warnings.append("Folders: \(error.localizedDescription)")
            }
        }
        if filesOnly && !completeKinds.contains(.files) && !moduleOrderComplete && candidates.isEmpty {
            throw StudyError.message(warnings.joined(separator: "\n"))
        }
        if !linkedContentComplete || !moduleOrderComplete { completeKinds.subtract([.files, .pages, .assignments]) }
        if discoverWebsites {
            for (key, body) in bodies {
                websiteSources.append(CourseWebsiteSource(html: body, url: candidates[key]?.sourceURL ?? source))
            }
            do {
                for record in try await list(prefix + "/discussion_topics?only_announcements=true", revalidate: true) where Self.accessible(record) {
                    if let body = record["message"] as? String {
                        websiteSources.append(CourseWebsiteSource(html: body, url: record["html_url"] as? String ?? source + "/announcements"))
                    }
                }
            } catch {
                try Task.checkCancellation()
                websiteDiscoveryComplete = false
                if ![403, 404].contains((error as? CanvasHTTPError)?.status ?? 0) {
                    warnings.append("Course website discovery: \(error.localizedDescription)")
                }
            }
        }
        let items = candidates.values.filter { !filesOnly || $0.kind == .files }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return CanvasMaterialCatalog(
            items: items, warnings: warnings, completeKinds: completeKinds, moduleOrderComplete: moduleOrderComplete,
            linkedContentComplete: linkedContentComplete, foldersComplete: foldersComplete,
            websiteSources: websiteSources, websiteDiscoveryComplete: websiteDiscoveryComplete && linkedContentComplete && moduleOrderComplete)
    }

    func material(_ reference: CanvasMaterialReference, courseID: Int) async throws -> CanvasMaterial {
        if reference.isMathWiki { return try await mathWiki.material(reference) }
        if reference.isCourseWebsite { return try await mathWiki.websiteMaterial(reference) }
        let prefix = "/api/v1/courses/\(courseID)"
        if reference.kind == .syllabus {
            let info = try await object(prefix + "?include[]=syllabus_body")
            let body = info["syllabus_body"] as? String ?? ""
            let text = StudyHTML.plainText(body)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw StudyError.message("This course has no syllabus text.")
            }
            return CanvasMaterial(
                id: reference.id, title: reference.title, fileName: "Course syllabus.html",
                text: StudyHTML.original(title: reference.title, body: body, source: reference.sourceURL),
                sourceURL: reference.sourceURL,
                version: SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined())
        }
        let item = try await reference.kind == .files
            ? fileMetadata(id: reference.remoteID, courseID: courseID)
            : reference.kind == .assignments ? assignmentRecord(courseID: courseID, id: reference.remoteID)
            : object(prefix + "/\(reference.kind.rawValue)/\(Self.component(reference.remoteID))")
        guard Self.accessible(item, linkedFile: reference.kind == .files) else {
            throw StudyError.message("This material is not currently available in Canvas.")
        }
        let title =
            item["title"] as? String ?? item["display_name"] as? String ?? item["name"] as? String ?? reference.title
        let version = Self.materialVersion(item, kind: reference.kind)
        if reference.kind == .files {
            let name = item["filename"] as? String ?? title
            var resolved = reference
            resolved.fileName = name
            resolved.byteCount = item["size"] as? Int
            if let reason = resolved.unavailableReason { throw StudyError.message(reason) }
            guard let value = item["url"] as? String, let url = URL(string: value), url.scheme == "https",
                url.user == nil, url.password == nil
            else {
                throw StudyError.message("Canvas did not provide a valid download address.")
            }
            return CanvasMaterial(
                id: reference.id, title: title, fileName: name, downloadURL: url, sourceURL: reference.sourceURL,
                version: version)
        }
        let body = item[reference.kind == .pages ? "body" : "description"] as? String ?? ""
        let due = (item["due_at"] as? String).map { "\n\nDue: \($0)" } ?? ""
        return CanvasMaterial(
            id: reference.id, title: title, fileName: "\(title).html",
            text: StudyHTML.original(title: title, body: body + (due.isEmpty ? "" : "<p>\(StudyHTML.escape(due))</p>"), source: reference.sourceURL), sourceURL: reference.sourceURL, version: version,
            assignment: reference.kind == .assignments
                ? CanvasAssignmentDetails(record: item, origin: origin, courseID: courseID) : nil)
    }

    func fileReference(id: String, courseID: Int) async throws -> CanvasMaterialReference {
        guard let number = Int(id), number > 0 else { throw StudyError.message("Invalid Canvas file.") }
        let item = try await fileMetadata(id: String(number), courseID: courseID)
        guard Self.accessible(item, linkedFile: true) else {
            throw StudyError.message("This attachment is not currently available in Canvas.")
        }
        let name = item["filename"] as? String ?? item["display_name"] as? String ?? "File \(number)"
        return CanvasMaterialReference(
            id: "files:\(number)", kind: .files, remoteID: String(number),
            title: item["display_name"] as? String ?? name, fileName: name,
            sourceURL: origin.absoluteString + "/courses/\(courseID)/files/\(number)",
            version: Self.materialVersion(item, kind: .files), byteCount: item["size"] as? Int,
            folderID: item["folder_id"] as? Int)
    }

    private func fileMetadata(id: String, courseID: Int) async throws -> [String: Any] {
        guard let number = Int(id), number > 0 else { throw StudyError.message("Invalid Canvas file.") }
        do { return try await object("/api/v1/courses/\(courseID)/files/\(number)") }
        catch let error as CanvasHTTPError where error.status == 403 || error.status == 404 {
            // A disabled Files tab does not revoke access to an assignment's linked attachment.
            // Canvas still enforces file locks and enrollment on the file endpoint.
            return try await object("/api/v1/files/\(number)")
        }
    }

    private static func component(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? value
    }
    private static func materialVersion(_ item: [String: Any], kind: CanvasMaterialKind) -> String {
        let version = item["updated_at"] as? String ?? item["modified_at"] as? String ?? ""
        // A student's deadline override can change without updated_at changing.
        // Invalidate the downloaded description's appended Due line as well.
        guard kind == .assignments, item["submission_types"] != nil else { return version }
        return version + "|due:" + (item["due_at"] as? String ?? "none")
    }

    func download(_ url: URL, limit: Int = StudyDocumentImporter.maximumBytes,
        priority: CanvasDownloadTaskPriority? = nil, mathWikiFile: Bool = false) async throws -> Data {
        if mathWikiFile { return try await mathWiki.download(url, limit: limit) }
        guard url.scheme == "https", url.user == nil, url.password == nil else {
            throw StudyError.message("Canvas returned an invalid download address.")
        }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        if CanvasAddress.sameOrigin(url, origin) { try await authorize(&request) }
        return try await fetch(
            request, session: downloadSession, limit: min(limit, StudyDocumentImporter.maximumBytes), downloads: true,
            priority: priority
        ).0
    }

    private static func accessible(_ item: [String: Any], linkedFile: Bool = false) -> Bool {
        item["published"] as? Bool != false && item["locked_for_user"] as? Bool != true
            && (linkedFile || item["hidden_for_user"] as? Bool != true)
    }
    private static func listable(_ item: [String: Any], kind: CanvasMaterialKind?) -> Bool {
        // A locked assignment still has a useful deadline; its content stays locked.
        kind == .assignments
            ? item["published"] as? Bool != false && item["hidden_for_user"] as? Bool != true
            : accessible(item)
    }
    private func authorize(_ request: inout URLRequest) async throws {
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            let header: String
            if let url = request.url, let cookies { header = try await cookies(url) }
            else { header = cookieHeader }
            request.setValue(header.isEmpty ? nil : header, forHTTPHeaderField: "Cookie")
        }
    }
    private func request(_ path: String, revalidate: Bool = false) async throws -> (Any, HTTPURLResponse) {
        guard let url = URL(string: path, relativeTo: origin)?.absoluteURL, CanvasAddress.sameOrigin(url, origin),
            url.path.hasPrefix("/api/v1/")
        else {
            throw StudyError.message("Canvas returned an invalid API address.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try await authorize(&request)
        let cached = revalidate ? metadataCache[url.absoluteString] : nil
        if let tag = cached?.response.value(forHTTPHeaderField: "ETag") {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        } else if let modified = cached?.response.value(forHTTPHeaderField: "Last-Modified") {
            request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
        }
        let (data, response) = try await fetch(
            request, session: apiSession, limit: 8_000_000, allowNotModified: cached != nil)
        if response.statusCode == 304, let cached {
            let oldHeaders = cached.response.allHeaderFields.reduce(into: [String: String]()) {
                $0[String(describing: $1.key).lowercased()] = String(describing: $1.value)
            }
            let headers = response.allHeaderFields.reduce(into: oldHeaders) {
                $0[String(describing: $1.key).lowercased()] = String(describing: $1.value)
            }
            let merged =
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
                ?? cached.response
            cache(cached.data, response: merged, key: url.absoluteString)
            return (try JSONSerialization.jsonObject(with: cached.data), merged)
        }
        guard response.mimeType?.contains("json") == true else {
            throw CanvasHTTPError(status: 401)
        }
        let value = try JSONSerialization.jsonObject(with: data)
        if revalidate { cache(data, response: response, key: url.absoluteString) }
        return (value, response)
    }
    private func object(_ path: String, revalidate: Bool = false) async throws -> [String: Any] {
        guard let value = try await request(path, revalidate: revalidate).0 as? [String: Any] else {
            throw StudyError.message("Canvas returned an invalid object.")
        }
        return value
    }
    private func list(_ path: String, revalidate: Bool = true) async throws -> [[String: Any]] {
        var next: String? = path + (path.contains("?") ? "&" : "?") + "per_page=100"
        var result: [[String: Any]] = []
        var visited = Set<String>()
        while let page = next {
            guard visited.insert(page).inserted, visited.count <= 50 else {
                throw StudyError.message("Canvas pagination exceeded its limit. Some course items could not be listed.")
            }
            let (value, response) = try await request(page, revalidate: revalidate)
            guard let items = value as? [[String: Any]], let current = response.url else {
                throw StudyError.message("Canvas returned an invalid list.")
            }
            result += items
            let link = response.value(forHTTPHeaderField: "Link")
            let nextURL = CanvasAddress.nextPage(link, current: current, origin: origin)
            if link?.contains("rel=\"next\"") == true && nextURL == nil {
                throw StudyError.message("Canvas returned an unsafe pagination address.")
            }
            next = nextURL?.absoluteString
        }
        return result
    }
    private func fetch(
        _ request: URLRequest, session: URLSession, limit: Int, allowNotModified: Bool = false, downloads: Bool = false,
        attempt: Int = 0, priority: CanvasDownloadTaskPriority? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        if attempt > 0, let url = request.url, CanvasAddress.sameOrigin(url, origin) { try await authorize(&request) }
        if let retryAfter, retryAfter > Date() {
            throw StudyError.message("Canvas is rate limiting requests. Wait a moment before refreshing again.")
        }
        let (data, http) = try await CanvasDataTransfer(limit: limit, downloads: downloads, priority: priority).receive(
            request, session: session)
        if let url = http.url, CanvasAddress.sameOrigin(url, origin), token.isEmpty, let receiveCookies {
            let headers = http.allHeaderFields.reduce(into: [String: String]()) {
                $0[String(describing: $1.key)] = String(describing: $1.value)
            }
            try await receiveCookies(url, headers)
        }
        if http.statusCode == 429 {
            let raw = http.value(forHTTPHeaderField: "Retry-After") ?? ""
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            let requested = Double(raw) ?? formatter.date(from: raw)?.timeIntervalSinceNow ?? Double(2 << attempt)
            let delay = requested.isFinite ? max(1, min(86_400, requested)) : 60
            retryAfter = Date().addingTimeInterval(delay)
            guard attempt < 2, delay <= 60 else {
                throw StudyError.message(
                    "Canvas is rate limiting requests. Try refreshing again in \(Int(delay)) seconds.")
            }
            try await Task.sleep(for: .seconds(delay))
            return try await fetch(
                request, session: session, limit: limit, allowNotModified: allowNotModified, downloads: downloads,
                attempt: attempt + 1, priority: priority)
        }
        if allowNotModified && http.statusCode == 304 { return (Data(), http) }
        guard (200..<300).contains(http.statusCode) else {
            throw CanvasHTTPError(status: http.statusCode)
        }
        return (data, http)
    }
}

struct CanvasSignInView: NSViewRepresentable {
    let origin: URL
    var onSignedIn: () -> Void = {}
    var onError: (String) -> Void = { _ in }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.preparation = Task { @MainActor in
            do {
                try await CanvasSession.prepare(origin: origin, allowKeychainInteraction: true)
                guard !Task.isCancelled else { return }
                webView.load(URLRequest(url: origin))
            } catch {
                if !Task.isCancelled { context.coordinator.onError(error.localizedDescription) }
            }
        }
        return webView
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.preparation?.cancel()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.stopLoading()
    }
    func makeCoordinator() -> Coordinator { Coordinator(origin: origin, onSignedIn: onSignedIn, onError: onError) }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let origin: URL
        let onSignedIn: () -> Void
        let onError: (String) -> Void
        var preparation: Task<Void, Never>?
        init(origin: URL, onSignedIn: @escaping () -> Void, onError: @escaping (String) -> Void) {
            self.origin = origin; self.onSignedIn = onSignedIn; self.onError = onError
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { onError(error.localizedDescription) }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Institutional sign-in links sometimes request a new window.
            if navigationAction.targetFrame == nil, navigationAction.request.url?.scheme == "https" {
                webView.load(navigationAction.request)
            }
            return nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url, CanvasAddress.sameOrigin(url, origin), !url.path.hasPrefix("/login") {
                onSignedIn()
            }
        }
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme
            decisionHandler(scheme == "https" || scheme == "about" ? .allow : .cancel)
        }
    }
}
