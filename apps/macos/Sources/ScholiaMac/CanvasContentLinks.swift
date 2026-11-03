import Foundation

struct CanvasContentLink: Sendable {
    var kind: CanvasMaterialKind
    var remoteID: String
    var section: String?
    var id: String { "\(kind.rawValue):\(remoteID)" }
}

enum CanvasContentLinks {
    static func resolve(_ value: String, origin: URL, courseID: Int, sourceURL: URL? = nil) -> CanvasContentLink? {
        let value = value.replacingOccurrences(of: "&amp;", with: "&")
        guard let url = URL(string: value, relativeTo: sourceURL ?? origin)?.absoluteURL,
            CanvasAddress.sameOrigin(url, origin) else { return nil }
        var parts = url.path.split(separator: "/").map(String.init)
        if parts.starts(with: ["api", "v1"]) { parts.removeFirst(2) }
        let scoped = parts.first == "courses"
        if scoped {
            guard parts.count >= 4, parts[1] == String(courseID) else { return nil }
            parts.removeFirst(2)
        }
        guard parts.count >= 2, let kind = CanvasMaterialKind(rawValue: parts[0]),
            [.files, .pages, .assignments].contains(kind),
            (kind == .files && (parts.count == 2 || (parts.count == 3 && ["download", "preview"].contains(parts[2]))))
                || (scoped && kind != .files && parts.count == 2)
        else { return nil }
        let id = parts[1]
        guard !id.isEmpty, !id.contains("/"), id.rangeOfCharacter(from: .controlCharacters) == nil,
            kind == .pages || (Int(id) ?? 0) > 0 else { return nil }
        return CanvasContentLink(kind: kind, remoteID: id)
    }

    /// Include preview iframes, images and Canvas's data-api-endpoint links;
    /// keep file identity before converting rich course pages to plain text.
    static func links(in html: String, origin: URL, courseID: Int, sourceURL: URL? = nil) -> [CanvasContentLink] {
        let clean = html.replacingOccurrences(of: #"(?is)<!--.*?-->|<(script|style)\b[^>]*>.*?</\1\s*>"#,
            with: "", options: .regularExpression)
        let tokens = try! NSRegularExpression(pattern: #"(?is)<h[1-6]\b[^>]*>(.*?)</h[1-6]\s*>|<[a-z][^>]*>"#)
        let attributes = try! NSRegularExpression(pattern: #"(?is)\s(?:href|src|data-api-endpoint)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
        let text = clean as NSString
        var result: [CanvasContentLink] = [], seen: Set<String> = []
        var section: String?
        for token in tokens.matches(in: clean, range: NSRange(location: 0, length: text.length)) {
            if token.range(at: 1).location != NSNotFound {
                let heading = StudyHTML.plainText(text.substring(with: token.range(at: 1)))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                section = heading.isEmpty ? nil : heading
            }
            let tag = text.substring(with: token.range) as NSString
            for attribute in attributes.matches(in: tag as String, range: NSRange(location: 0, length: tag.length)) {
                let range = (1...3).map { attribute.range(at: $0) }.first { $0.location != NSNotFound }!
                guard var link = resolve(tag.substring(with: range), origin: origin, courseID: courseID, sourceURL: sourceURL),
                    seen.insert(link.id).inserted else { continue }
                link.section = section
                result.append(link)
            }
        }
        return result
    }

    static func folderTitle(_ id: Int?, folders: [Int: [String: Any]]) -> String? {
        var folder = id.flatMap { folders[$0] }, names: [String] = [], seen: Set<Int> = []
        while let current = folder, let id = current["id"] as? Int, seen.insert(id).inserted,
            let parent = current["parent_folder_id"] as? Int {
            if let name = current["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                names.insert(name, at: 0)
            }
            folder = folders[parent]
        }
        return names.isEmpty ? nil : names.joined(separator: " / ")
    }
}

extension CanvasMaterialReference {
    mutating func inheritGrouping(from parent: Self, position: Int, section: String?) {
        guard moduleID == nil, linkedFromID == nil, id != parent.id else { return }
        copyModuleGrouping(from: parent)
        linkedFromID = parent.id
        linkedFromTitle = parent.title
        linkedPosition = position
        linkedOrder = (parent.linkedOrder ?? []) + [position]
        linkedSection = section
    }
    mutating func copyModuleGrouping(from other: Self) {
        moduleID = other.moduleID
        moduleTitle = other.moduleTitle
        modulePosition = other.modulePosition
        moduleItemPosition = other.moduleItemPosition
        moduleSection = other.moduleSection
    }
}
