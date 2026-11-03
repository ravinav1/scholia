import Foundation

extension MessageAttachment {
    /// A static model can have its complete graph read while its thumbnail or
    /// executable workspace remains unavailable. Keep that distinction visible.
    var modelStructureAvailable: Bool {
        guard ["slx", "sltx"].contains((fileName as NSString).pathExtension.lowercased()),
              let coverage = AttachmentReadingCoverage(fileName: fileName, text: extractedText),
              !coverage.textLimitReached, !coverage.additionalEntries,
              !(readDetail ?? "").localizedCaseInsensitiveContains("resource limit"),
              !(readDetail ?? "").localizedCaseInsensitiveContains("indexing failed"),
              !(readDetail ?? "").localizedCaseInsensitiveContains("could not be saved") else { return false }
        let systems = coverage.entries.filter { $0.name.hasPrefix("simulink/systems/") && $0.name.hasSuffix(".xml") }
        return !systems.isEmpty && systems.allSatisfy { $0.state == "complete" }
    }

    var sourceKindLabel: String {
        if mimeType == "inode/directory" { return "Folder" }
        if ["slx", "slxp", "sltx", "mdl"].contains((fileName as NSString).pathExtension.lowercased()) { return "Simulink model" }
        return isImage ? "Image" : "File"
    }

    /// Explains a saved attachment's limits without reopening its source or
    /// replacing the evidence that was actually attached to the conversation.
    var readingLimitSummary: String? {
        if let count = textCorpusUTF16Count, textCorpusID != nil, effectiveReadStatus == .complete {
            return "All \(count.formatted()) characters saved · searchable for every question"
        }
        guard effectiveReadStatus != .complete else { return nil }
        if let coverage = AttachmentReadingCoverage(fileName: fileName, text: extractedText) {
            var parts = [coverage.summary]
            let ext = (fileName as NSString).pathExtension.lowercased()
            if ["slx", "slxp", "sltx"].contains(ext) {
                parts.append("Static model; not simulated")
            } else if coverage.unavailableCount + coverage.notReadCount + coverage.partialCount == 0 {
                if mimeType == "inode/directory" { parts.append("Hidden files and links excluded") }
                else if ["mlx", "mlapp"].contains(ext) { parts.append("Code not executed; outputs may be unavailable") }
            }
            return parts.joined(separator: " · ")
        }
        guard let detail = readDetail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty else {
            return effectiveReadStatus == .unreadable ? "No readable contents were extracted" : "Some content is unavailable; inspect the attachment details"
        }
        return Self.shortReadingDetail(detail)
    }

    /// The saved manifest and limitations, never the potentially huge model or
    /// document body. Nested partial-file descriptions explain, for example,
    /// why a readable Simulink model is still marked partial inside a folder.
    var readingDetailsText: String {
        var parts = ["\(sourceKindLabel): \(fileName)"]
        if let sourcePath { parts.append("Original source: \(sourcePath)") }
        parts.append("Attachment ID: \(id.uuidString)")
        if let count = textCorpusUTF16Count, textCorpusID != nil {
            parts.append("All \(count.formatted()) extracted characters are saved locally and available for search. The preview and each answer use selected text; a shorter preview does not discard the rest of the extraction.")
        }
        if let summary = readingLimitSummary { parts.append(summary) }
        if let detail = readDetail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
            parts.append(detail)
        }
        if let coverage = AttachmentReadingCoverage(fileName: fileName, text: extractedText) {
            parts.append(coverage.header)
            let nested = coverage.partialFileDetails(in: extractedText)
            if !nested.isEmpty { parts.append("Included files with limitations\n\n" + nested.joined(separator: "\n\n")) }
        }
        if parts.isEmpty { parts.append(readStatusLabel) }
        let text = parts.joined(separator: "\n\n")
        let bounded = TextInputPolicy.boundedResult(text, maximumUTF16Units: 32_000)
        return bounded.value + (bounded.wasTruncated ? "\n[Additional attachment details are not displayed.]" : "")
    }

    private static func shortReadingDetail(_ detail: String) -> String {
        let line = detail.components(separatedBy: .newlines).filter { !$0.isEmpty }.joined(separator: " ")
        let bounded = TextInputPolicy.boundedResult(line, maximumUTF16Units: 200)
        return bounded.value + (bounded.wasTruncated ? "…" : "")
    }
}

/// Reads only the generated outer manifest. Counts are deliberately not inferred
/// from nested manifests, source bodies, filenames, or the old generic readDetail.
struct AttachmentReadingCoverage {
    struct Entry {
        var name: String
        var state: String
        var textLimited: Bool
    }
    var header: String
    var entries: [Entry]
    var additionalEntries: Bool
    var textLimitReached: Bool
    var otherOmissions: Bool

    var fullReadCount: Int { entries.filter { $0.state == "complete" }.count }
    var partialCount: Int { entries.filter { $0.state == "partial" }.count }
    var unavailableCount: Int { entries.filter { $0.state == "unreadable" }.count }
    var notReadCount: Int { entries.filter { $0.state == "notRead" }.count }

    var summary: String {
        var parts: [String] = []
        if textLimitReached { parts.append("Text limit reached") }
        if fullReadCount > 0 { parts.append("\(fullReadCount) file\(fullReadCount == 1 ? "" : "s") fully read") }
        if partialCount > 0 { parts.append("\(partialCount) partly read") }
        if unavailableCount > 0 { parts.append("\(unavailableCount) unavailable") }
        if notReadCount > 0 { parts.append("\(notReadCount) not read") }
        if additionalEntries { parts.append("More entries not listed") }
        else if otherOmissions { parts.append("Other items excluded") }
        if parts.isEmpty { parts.append("No file contents included") }
        return parts.joined(separator: " · ")
    }

    init?(fileName: String, text: String) {
        let prefixes = ["Project folder: \(fileName)\n\nFILE MANIFEST\n", "Contents of \(fileName)\n\nFILE MANIFEST\n"]
        guard let prefix = prefixes.first(where: { text.hasPrefix($0) }) else { return nil }
        // Generated headers are bounded by the extractor. Avoid scanning an
        // arbitrary document body when interpreting an old/malformed attachment.
        let beginning = TextInputPolicy.bounded(text, maximumUTF16Units: 28_000)
        guard let end = beginning.range(of: "\n\nEXTRACTED CONTENT\n") else { return nil }
        header = String(beginning[..<end.lowerBound])
        let rows = header.dropFirst(prefix.count).components(separatedBy: "\n\nLIMITATIONS\n").first ?? ""
        var parsed: [Entry] = []
        for row in rows.components(separatedBy: "\n") {
            guard let separator = row.range(of: " — ", options: .backwards) else { continue }
            let name = String(row[..<separator.lowerBound])
            let status = String(row[separator.upperBound...])
            let state: String
            if status == "complete" { state = "complete" }
            else if status == "partial" || status == "partial (text budget)" || status == "partial (resource limit)" { state = "partial" }
            else if status.hasPrefix("UNREADABLE: ") { state = "unreadable" }
            else if status.hasPrefix("NOT READ: ") { state = "notRead" }
            else { continue }
            parsed.append(Entry(name: name, state: state,
                textLimited: status == "partial (text budget)" || status.contains("Attachment text budget reached")))
        }
        entries = parsed
        textLimitReached = parsed.contains(where: \.textLimited)
        additionalEntries = header.contains("[Manifest truncated;") || header.contains("additional archive members were not inspected")
            || header.contains("Folder listing stopped at") || header.contains("Folder traversal stopped at")
        otherOmissions = header.contains("symbolic link not followed") || header.contains("deeper than")
            || header.contains(": inaccessible") || header.contains("folder could not be listed")
            || header.contains("resource limit")
    }

    func partialFileDetails(in text: String) -> [String] {
        var details: [String] = []
        for entry in entries.filter({ $0.state == "partial" }).prefix(8) {
            let marker = "--- File: \(entry.name) [partial]"
            guard let start = text.range(of: marker) else { continue }
            let tail = text[start.lowerBound...]
            let line = String(tail.prefix(2_500).split(separator: "\n", maxSplits: 1).first ?? "")
            if line.hasSuffix(" ---") { details.append(line) }
        }
        return details
    }
}
