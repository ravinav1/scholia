import AppKit
import CoreText
import Foundation
import PDFKit
@testable import ScholiaMac

/// Isolated validation of the attachment boundaries and real scanned-PDF OCR.
/// Does not create a window, start application services, or use a live corpus.
@main @MainActor struct NativeAttachmentRegressions {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw StudyError.message(message) }
    }
    static func attachment(_ name: String, _ text: String) -> MessageAttachment {
        MessageAttachment(fileName: name, mimeType: "text/plain", byteCount: text.utf8.count, extractedText: text)
    }
    static func prepare(_ files: [MessageAttachment]) throws -> PreparedConversation {
        try PromptBuilder.prepare(messages: [ConversationMessage(role: .user, content: "Read", attachments: files)],
            capture: nil, languagePreference: .english)
    }
    static func scan() throws -> Data {
        let width = 1_600, height = 600
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw StudyError.message("Could not create scan raster")
        }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let text = NSAttributedString(string: "Scanned attachment contains all the evidence", attributes: [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 48, nil),
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
        let line = CTLineCreateWithAttributedString(text)
        try check(CTLineGetTypographicBounds(line, nil, nil, nil) < Double(width - 100), "OCR fixture text is clipped")
        bitmap.textPosition = CGPoint(x: 50, y: 280)
        CTLineDraw(line, bitmap)
        let output = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil), let image = bitmap.makeImage() else {
            throw StudyError.message("Could not create scanned PDF")
        }
        context.beginPDFPage(nil)
        context.draw(image, in: bounds)
        context.endPDFPage(); context.closePDF()
        return output as Data
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-attachment-boundaries-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var remaining = PromptBuilder.maxConversationAttachmentCharacters
        var atLimit: [MessageAttachment] = []
        while remaining > 0 {
            let count = min(MessageAttachmentIngestion.maximumExtractedUTF16Units, remaining)
            atLimit.append(attachment("part-\(atLimit.count).txt", String(repeating: "x", count: count)))
            remaining -= count
        }
        _ = try prepare(atLimit)
        do {
            _ = try prepare(atLimit + [attachment("extra.txt", "x")])
            throw StudyError.message("Aggregate attachment limit was not enforced")
        } catch PromptBuilderError.attachmentsTooLarge {}
        do {
            _ = try prepare([attachment("invalid.txt", String(repeating: "x", count: MessageAttachmentIngestion.maximumExtractedUTF16Units + 1))])
            throw StudyError.message("Oversized inline attachment was not rejected")
        } catch PromptBuilderError.unreadableAttachment {}
        print("PASS request boundary: exactly \(PromptBuilder.maxConversationAttachmentCharacters) characters allowed; +1 and invalid inline preview rejected")

        try AttachmentTextCorpusStore.$directoryOverride.withValue(root) {
            let original = MessageAttachment(fileName: "plant.slx", mimeType: "application/zip", byteCount: 80,
                extractedText: "model source", readStatus: .partial, readDetail: "Dependency missing", isEnabled: false)
            let wire = try JSONDecoder().decode(StudyAttachmentTransfer.self, from: JSONEncoder().encode(StudyAttachmentTransfer(original)))
            let roundTrip = try wire.attachment()
            try check(roundTrip.id == original.id && roundTrip.readStatus == .partial && !roundTrip.includedInContext,
                "Transfer metadata was not preserved")
            var preview = wire
            preview.text = String(repeating: "x", count: MessageAttachmentIngestion.maximumExtractedUTF16Units + 1)
            let indexed = try preview.attachment()
            try check(indexed.extractedText.utf16.count == MessageAttachmentIngestion.maximumExtractedUTF16Units,
                "Preview is not bounded")
            try check(try AttachmentTextCorpusStore.text(for: indexed) == preview.text, "Full text beyond preview was lost")
            var full = wire
            full.text = String(repeating: "x", count: AttachmentTextCorpusStore.maximumUTF16Units)
            let accepted = try full.attachment()
            try check(accepted.textCorpusUTF16Count == AttachmentTextCorpusStore.maximumUTF16Units,
                "Full resource boundary was not indexed")
            try check(try AttachmentTextCorpusStore.text(for: accepted).utf16.count == AttachmentTextCorpusStore.maximumUTF16Units,
                "Full resource boundary was not preserved")
            full.text.append("x")
            do {
                _ = try full.attachment()
                throw StudyError.message("Full-text resource limit was not enforced")
            } catch StudyError.message(let detail) {
                try check(detail.contains("Invalid attachment"), "Unexpected full-text limit error: \(detail)")
            }
        }
        print("PASS transfer preview/corpus boundaries: full \(AttachmentTextCorpusStore.maximumUTF16Units) characters preserved in temporary corpus; +1 rejected")

        let data = try scan()
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else {
            throw StudyError.message("Scanned PDF fixture could not reopen")
        }
        try check((page.string ?? "").isEmpty, "Scanned fixture must not contain a text layer")
        let recognized = try MessageAttachmentIngestion.readPDFPage(page)
        try check(recognized.contains("all the evidence"), "Production Vision page OCR returned: \(recognized)")
        let result = try MessageAttachmentIngestion.read(data: data, fileName: "scan.pdf", mimeType: "application/pdf")
        try check(result.effectiveReadStatus == .complete && result.extractedText.contains("all the evidence"),
            "Full scanned-PDF ingestion failed: \(result.readDetail ?? "") / \(result.extractedText)")
        print("PASS real Vision: image-only fixed-pixel PDF, production page OCR and complete attachment ingestion")
        print("PASS native attachment regressions")
    }
}
