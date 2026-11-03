import Foundation

/// Only saved conversation sources become local links. Model output never grants
/// permission to open an arbitrary path, and page numbers stay bound to the answer's document.
struct ChatReferenceContext: Equatable {
    struct Attachment: Equatable {
        var id: UUID
        var fileName: String
        var sourcePath: String?
        var members: [String]

        init(_ attachment: MessageAttachment) {
            id = attachment.id
            fileName = attachment.fileName
            sourcePath = attachment.sourcePath
            members = AttachmentReadingCoverage(fileName: attachment.fileName, text: attachment.extractedText)?
                .entries.map(\.name) ?? []
        }
    }
    enum Destination: Equatable {
        case document(UUID, page: Int)
        case attachment(UUID, member: String?)
    }
    struct Link: Equatable {
        var range: NSRange
        var url: URL
        var help: String
        var isPage: Bool
    }

    var documents: [StudyDocument] = []
    var attachments: [Attachment] = []
    var defaultDocumentID: UUID?

    private var aliases: [String: Set<URL>] {
        var values: [String: Set<URL>] = [:]
        for doc in documents {
            let url = Self.url(.document(doc.id, page: 1))
            for label in Set([doc.fileName, doc.originalFileName, doc.title].compactMap { $0 }) where label.count >= 4 {
                values[label, default: []].insert(url)
            }
        }
        for attachment in attachments {
            let url = Self.url(.attachment(attachment.id, member: nil))
            for label in [attachment.fileName, attachment.sourcePath, attachment.id.uuidString].compactMap({ $0 }) where !label.isEmpty {
                values[label, default: []].insert(url)
            }
            for member in attachment.members {
                values[member, default: []].insert(Self.url(.attachment(attachment.id, member: member)))
            }
        }
        return values
    }

    func links(in text: String) -> [Link] {
        let string = text as NSString
        let full = NSRange(location: 0, length: string.length)
        var links: [Link] = []
        let known = aliases
        let labels = known.keys.sorted { $0.count > $1.count }
        if !labels.isEmpty, let regex = try? NSRegularExpression(pattern:
            #"(?<![\p{L}\p{N}_./-])(?:"# + labels.map(NSRegularExpression.escapedPattern).joined(separator: "|") + #")(?![\p{L}\p{N}_/-]|\.[\p{L}\p{N}_])"#) {
            for match in regex.matches(in: text, range: full) {
                let label = string.substring(with: match.range)
                guard let candidates = known[label], candidates.count == 1, let url = candidates.first else { continue }
                links.append(Link(range: match.range, url: url, help: help(for: url), isPage: false))
            }
        }
        // Plain page references are meaningful only with an unambiguous source.
        // Printed-page prose is deliberately excluded: these links use PDF page indices.
        guard let id = defaultDocumentID, let doc = documents.first(where: { $0.id == id && $0.kind == .pdf }) else { return links }
        let pattern = #"(?i)(?:\[(?:PDF\s+)?(?:pp?\.?|pages?)\s*(\d+)(?:\s*[-–—]\s*(\d+))?\]|\bPDF\s+(?:pp?\.?|pages?)\s*(\d+)(?:\s*[-–—]\s*(\d+))?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return links }
        for match in regex.matches(in: text, range: full) {
            let firstGroup = match.range(at: 1).location == NSNotFound ? 3 : 1
            guard let start = Int(string.substring(with: match.range(at: firstGroup))), start > 0, start <= doc.pageCount else { continue }
            let endRange = match.range(at: firstGroup + 1)
            let end = endRange.location == NSNotFound ? start : Int(string.substring(with: endRange)) ?? start
            guard end >= start, end <= doc.pageCount else { continue }
            let url = Self.url(.document(id, page: start))
            let pages = end == start ? "page \(start)" : "pages \(start)–\(end) (opens page \(start))"
            links.append(Link(range: match.range, url: url, help: "Read \(doc.title), PDF \(pages)", isPage: true))
        }
        return links
    }

    func destination(for url: URL) -> Destination? {
        guard url.scheme == "scholia-source", url.user == nil, url.password == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = UUID(uuidString: url.lastPathComponent) else { return nil }
        let query = components.queryItems ?? []
        switch url.host {
        case "document":
            guard let doc = documents.first(where: { $0.id == id }),
                  let page = Int(query.first(where: { $0.name == "page" })?.value ?? "1"),
                  page > 0, page <= max(1, doc.pageCount) else { return nil }
            return .document(id, page: page)
        case "attachment":
            guard let attachment = attachments.first(where: { $0.id == id }) else { return nil }
            let member = query.first(where: { $0.name == "member" })?.value
            guard member == nil || attachment.members.contains(member!) else { return nil }
            return .attachment(id, member: member)
        default: return nil
        }
    }

    /// Resolve explicit file Markdown links only when they match a saved source.
    func localURL(for url: URL) -> URL? {
        if destination(for: url) != nil { return url }
        guard url.isFileURL || url.scheme == nil else { return nil }
        let label = url.isFileURL ? url.path : url.relativePath.removingPercentEncoding ?? url.relativePath
        guard let candidates = aliases[label], candidates.count == 1, let resolved = candidates.first else { return nil }
        return resolved
    }

    private func help(for url: URL) -> String {
        switch destination(for: url) {
        case .document(let id, _): return "Open \(documents.first { $0.id == id }?.title ?? "document")"
        case .attachment(let id, let member):
            let file = attachments.first { $0.id == id }?.fileName ?? "attachment"
            return member.map { "Inspect \($0) in \(file)" } ?? "Inspect attached \(file)"
        case nil: return "Open source"
        }
    }

    static func url(_ destination: Destination) -> URL {
        var parts = URLComponents()
        parts.scheme = "scholia-source"
        switch destination {
        case .document(let id, let page):
            parts.host = "document"; parts.path = "/\(id.uuidString)"
            parts.queryItems = [URLQueryItem(name: "page", value: String(page))]
        case .attachment(let id, let member):
            parts.host = "attachment"; parts.path = "/\(id.uuidString)"
            parts.queryItems = member.map { [URLQueryItem(name: "member", value: $0)] }
        }
        return parts.url!
    }
}

extension StudyWorkspaceModel {
    func chatReferenceContext(for message: ConversationMessage) -> ChatReferenceContext {
        let sources = thread?.sources[message.id.uuidString] ?? []
        let sourceIDs = Set(sources.map(\.documentID))
        let defaultID = sourceIDs.count == 1 ? sourceIDs.first : sourceIDs.isEmpty ? thread?.documentID : nil
        // Only attachments that already existed when this answer was produced.
        let preceding = messages.prefix { $0.id != message.id }
        var seen = Set<UUID>()
        let attachments = preceding.flatMap { $0.attachments ?? [] }.filter { seen.insert($0.id).inserted }
        return ChatReferenceContext(documents: course?.documents ?? [], attachments: attachments.map(ChatReferenceContext.Attachment.init),
            defaultDocumentID: defaultID)
    }

    func chatAttachment(id: UUID) -> MessageAttachment? {
        messages.flatMap { $0.attachments ?? [] }.first { $0.id == id }
    }
}
