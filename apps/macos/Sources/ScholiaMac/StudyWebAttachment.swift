import Foundation

/// Full extractions are stored locally; browser state carries a preview plus an
/// opaque reference which is accepted only for this draft's existing attachment.
struct StudyWebAttachment: Codable, Sendable {
    var id: String?
    var name: String
    var mimeType: String
    var size: Int
    var text: String
    var status: String?
    var notice: String?
    var enabled: Bool?
    var truncated: Bool?
    var textCorpusID: String?
    var textCorpusUTF16Count: Int?
    /// Display-only on the wire. Incoming paths never grant native file access.
    var sourcePath: String?

    init(_ file: MessageAttachment) {
        id = file.id.uuidString
        name = file.fileName
        mimeType = file.mimeType
        size = file.byteCount
        text = file.extractedText
        status = switch file.effectiveReadStatus {
        case .complete: "readable"
        case .partial: "partial"
        case .unreadable: "unavailable"
        }
        notice = file.readDetail
        enabled = file.includedInContext
        truncated = file.effectiveReadStatus == .partial
        textCorpusID = file.textCorpusID
        textCorpusUTF16Count = file.textCorpusUTF16Count
        sourcePath = file.sourcePath
    }

    func attachment(existing: MessageAttachment? = nil) throws -> MessageAttachment {
        guard size >= 0, name.utf16.count <= 1_000, mimeType.count <= 100,
              text.utf16.count <= AttachmentTextCorpusStore.maximumUTF16Units,
              (notice?.utf16.count ?? 0) <= 4_000,
              status == nil || ["readable", "partial", "unavailable"].contains(status!) else {
            throw StudyError.message("Invalid attachment or attachment text exceeds its limit.")
        }
        if let existing {
            guard existing.id.uuidString.lowercased() == id?.lowercased(), existing.fileName == name else {
                throw StudyError.message("This attachment identity changed. Attach the new source as a separate file.")
            }
            if let textCorpusID,
               existing.textCorpusID != textCorpusID || existing.textCorpusUTF16Count != textCorpusUTF16Count {
                throw StudyError.message("This full-text reference does not match the saved attachment. Reopen the conversation.")
            }
            // Browser state is a preview, never replacement evidence. Even an
            // older browser which drops corpus metadata can only toggle inclusion.
            var saved = existing
            saved.isEnabled = enabled
            return saved
        }
        guard textCorpusID == nil else {
            throw StudyError.message("This full-text attachment is no longer in the current draft. Reopen the conversation or attach the file again.")
        }
        let readingStatus: AttachmentReadStatus = status == "unavailable" || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .unreadable : status == "partial" || truncated == true ? .partial : .complete
        var result = readingStatus == .unreadable
            ? MessageAttachmentIngestion.unavailable(fileName: name, mimeType: mimeType,
                byteCount: size, detail: notice ?? "No readable attachment content is available.")
            : MessageAttachmentIngestion.boundedAttachment(fileName: name, mimeType: mimeType,
                byteCount: size, text: text, status: readingStatus, detail: notice)
        result.id = id.flatMap(UUID.init(uuidString:)) ?? UUID()
        result.isEnabled = enabled
        return result
    }
}
