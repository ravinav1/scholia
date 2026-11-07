@preconcurrency import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum AttachmentReadError: LocalizedError {
    case unreadable(String)
    case tooMuchText

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail): detail
        case .tooMuchText: "This document exceeds the full-text extraction resource limit."
        }
    }
}

/// Every selected file becomes an attachment. Extraction failures are visible
/// evidence gaps, never silently dropped files or binary bytes sent as text.
enum MessageAttachmentIngestion {
    static let maximumInputBytes = 10_000_000
    static let maximumArchiveInputBytes = 100_000_000
    static let maximumPDFInputBytes = 1_000_000_000
    /// Conversation storage preview only; full extracted evidence is indexed
    /// separately by AttachmentTextCorpusStore.
    static let maximumExtractedUTF16Units = 200_000
    static let maximumAttachmentsPerMessage = 24

    static let textFileExtensions: Set<String> = StudyFileFormats.codeExtensions.union([
        "txt", "md", "markdown", "csv", "tsv", "tex", "bib", "log", "html", "htm",
        "srt", "vtt", "mdl", "ssc", "sci", "sce", "cir", "asc", "net", "dat", "out",
        "svg", "xsd", "xsl", "rels", "prj", "properties", "env", "gitignore", "lock",
        "rst", "adoc", "typ", "mermaid", "plantuml", "dxf", "step", "stp", "obj"
    ])
    static let archiveExtensions: Set<String> = ["zip", "slx", "slxp", "sltx", "mlx", "mlapp", "mlproj", "epub", "jar"]
    private static let textApplicationMIMETypes: Set<String> = [
        "application/json", "application/ld+json", "application/xml", "application/yaml",
        "application/x-yaml", "application/toml", "application/javascript", "application/sql",
        "application/x-ndjson", "application/x-matlab", "image/svg+xml"
    ]

    static func inputByteLimit(fileName: String, mimeType: String?) -> Int {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let mime = normalizedMIMEType(mimeType)
        if mime == "application/pdf" || (mime.isEmpty && ext == "pdf") { return maximumPDFInputBytes }
        if mime.hasPrefix("image/") || UTType(filenameExtension: ext)?.conforms(to: .image) == true {
            return ImageEncoding.maximumInputBytes
        }
        if archiveExtensions.contains(ext) || StudyFileFormats.officeExtensions.contains(ext)
            || ["mat", "gz", "tgz", "tar"].contains(ext) || mime == "application/zip" {
            return maximumArchiveInputBytes
        }
        return maximumInputBytes
    }

    /// Whether a format can be read/written as plain text (PDF is read-only).
    /// Archive and Office extraction is routed separately and does not broaden
    /// the local-file tool's permission to overwrite binary formats.
    static func supportsExtractedText(fileName: String, mimeType: String?) -> Bool {
        let mime = normalizedMIMEType(mimeType)
        let ext = (fileName as NSString).pathExtension.lowercased()
        if mime == "application/pdf" || (mime.isEmpty && ext == "pdf") { return true }
        if mime.hasPrefix("text/") || textApplicationMIMETypes.contains(mime) { return true }
        return mime.isEmpty && textFileExtensions.contains(ext)
    }

    static func ingest(data: Data, fileName: String, mimeType: String?) -> MessageAttachment? {
        try? read(data: data, fileName: fileName, mimeType: mimeType)
    }

    static func read(data: Data, fileName: String, mimeType: String?, archiveDepth: Int = 0) throws -> MessageAttachment {
        try Task.checkCancellation()
        let name = sanitizedFileName(fileName).isEmpty ? "Attachment" : sanitizedFileName(fileName)
        let declaredMIME = normalizedMIMEType(mimeType)
        let ext = (name as NSString).pathExtension.lowercased()
        let mime = declaredMIME.isEmpty ? inferredMIMEType(fileName: name) : declaredMIME
        let limit = inputByteLimit(fileName: name, mimeType: mimeType)
        guard data.count <= limit else {
            return unavailable(fileName: name, mimeType: mime, byteCount: data.count,
                detail: "Attached, but content exceeds the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) reading limit. Ask for the relevant section or a smaller export; this file's contents have not been read.")
        }
        guard !data.isEmpty else {
            return unavailable(fileName: name, mimeType: mime, byteCount: 0, detail: "The file is empty; it contains no readable evidence.")
        }
        do {
            if mime == "application/pdf" || (declaredMIME.isEmpty && ext == "pdf") {
                return try extractedPDF(data: data, fileName: name)
            }
            if StudyFileFormats.officeExtensions.contains(ext) {
                let contents = try StudyFileFormats.office(data, extension: ext)
                return boundedAttachment(fileName: name, mimeType: mime, byteCount: data.count,
                    text: contents.pages.map(\.text).joined(separator: "\n\n"), status: .partial,
                    detail: "Document text and tables extracted. Charts, embedded images, macros, comments, and full layout are not interpreted. " + (contents.notice ?? ""))
            }
            if archiveExtensions.contains(ext) || mime == "application/zip" || data.starts(with: [0x50, 0x4b, 0x03, 0x04]) {
                return try AttachmentProjectExtraction.archive(data: data, fileName: name, mimeType: mime, depth: archiveDepth)
            }
            if ["rtf", "doc"].contains(ext) {
                let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .docFormat
                let text = try NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil).string
                return boundedAttachment(fileName: name, mimeType: mime, byteCount: data.count, text: text,
                    status: .partial, detail: "Document text extracted. Embedded images and original layout are not included.")
            }
            if ext == "plist", let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
               let xml = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0),
               let text = String(data: xml, encoding: .utf8) {
                return boundedAttachment(fileName: name, mimeType: mime, byteCount: data.count, text: text)
            }
            if mime.hasPrefix("image/"), mime != "image/svg+xml" {
                guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1_800
                      ] as CFDictionary), let jpeg = ImageEncoding.jpegData(from: image) else {
                    throw AttachmentReadError.unreadable("The image could not be decoded. Export it as PNG or JPEG.")
                }
                return MessageAttachment(fileName: name, mimeType: "image/jpeg", byteCount: jpeg.count,
                    extractedText: "", imageData: jpeg,
                    readStatus: CGImageSourceGetCount(source) > 1 ? .partial : .complete,
                    readDetail: CGImageSourceGetCount(source) > 1
                        ? "Only the first frame/page is available for visual inspection; remaining frames/pages were not read."
                        : "Image available for visual inspection.")
            }
            // Declared container MIME types cannot masquerade as text. Unknown
            // file extensions can still contain perfectly useful UTF-8/UTF-16.
            let allowsSniffing = declaredMIME.isEmpty || declaredMIME == "application/octet-stream"
            if supportsExtractedText(fileName: name, mimeType: declaredMIME)
                || allowsSniffing && decodedText(data) != nil {
                guard let text = decodedText(data) else {
                    throw AttachmentReadError.unreadable("This file does not contain readable Unicode text. Export it as UTF-8 text or a documented format.")
                }
                let detail: String?
                if ext == "mdl" {
                    detail = "Simulink model definition read. Referenced models, external libraries, and workspace variables must be attached separately. The model has not been simulated."
                } else if ext == "m" || ext == "ssc" {
                    detail = "Source code read without execution. Values loaded from other files and computed results require those files or saved outputs."
                } else { detail = nil }
                return boundedAttachment(fileName: name, mimeType: mime, byteCount: data.count, text: text, detail: detail)
            }
            let guidance: String
            switch ext {
            case "mat", "h5", "hdf5", "sldd":
                guidance = "Binary MATLAB/HDF data is attached but has not been decoded. Export the needed variables with names, values, dimensions, and units to a MATLAB script, CSV, JSON, or text, or attach a readable workspace report."
            case "slxp": guidance = "This is a protected Simulink model. Attach the unprotected model or a report of the relevant blocks and parameters."
            case "mp3", "wav", "m4a", "mp4", "mov", "avi":
                guidance = "Audio/video is attached but has not been transcribed. Attach a transcript or relevant screenshots."
            default:
                guidance = "This format is attached, but Scholia cannot decode its contents yet. Ask for a text/PDF export or the relevant data from its original application; do not infer its contents from the filename."
            }
            return unavailable(fileName: name, mimeType: mime, byteCount: data.count, detail: guidance)
        } catch is CancellationError { throw CancellationError() }
        catch {
            return unavailable(fileName: name, mimeType: mime, byteCount: data.count,
                detail: "Attached, but content could not be read: \(error.localizedDescription)")
        }
    }

    static func ingest(fileAt url: URL) -> MessageAttachment? { try? read(fileAt: url) }

    static func read(fileAt url: URL) throws -> MessageAttachment {
        try Task.checkCancellation()
        guard url.isFileURL else { throw AttachmentReadError.unreadable("Choose a local file or folder.") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = sanitizedFileName(url.lastPathComponent)
        let mime = inferredMIMEType(fileName: name)
        var attachment: MessageAttachment
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true {
                attachment = try AttachmentProjectExtraction.folder(at: url)
            } else if values.isRegularFile != true {
                attachment = unavailable(fileName: name, mimeType: mime, byteCount: values.fileSize ?? 0,
                    detail: "This item is not a regular file. Attach the original file instead.")
            } else if (values.fileSize ?? Int.max) > inputByteLimit(fileName: name, mimeType: nil) {
                attachment = unavailable(fileName: name, mimeType: mime, byteCount: values.fileSize ?? 0,
                    detail: "File attached by reference; it exceeds the local reading limit. Its contents have not been read. Ask for the relevant section or a smaller export.")
            } else {
                attachment = try read(data: Data(contentsOf: url, options: .mappedIfSafe), fileName: name, mimeType: nil)
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            attachment = unavailable(fileName: name, mimeType: mime, byteCount: 0,
                detail: "File attached by reference, but it could not be opened: \(error.localizedDescription)")
        }
        attachment.sourcePath = url.path
        return attachment
    }

    static func unavailable(fileName: String, mimeType: String, byteCount: Int, detail: String) -> MessageAttachment {
        MessageAttachment(fileName: sanitizedFileName(fileName), mimeType: mimeType, byteCount: max(0, byteCount),
            extractedText: "", readStatus: .unreadable, readDetail: detail)
    }

    static func boundedAttachment(fileName: String, mimeType: String, byteCount: Int, text: String,
                                  status: AttachmentReadStatus = .complete, detail: String? = nil) -> MessageAttachment {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return unavailable(fileName: fileName, mimeType: mimeType, byteCount: byteCount,
                detail: [detail, "No readable text content was found."].compactMap { $0 }.joined(separator: " "))
        }
        let resourceBounded = TextInputPolicy.boundedResult(text, maximumUTF16Units: AttachmentTextCorpusStore.maximumUTF16Units)
        let bounded = TextInputPolicy.boundedResult(resourceBounded.value, maximumUTF16Units: maximumExtractedUTF16Units)
        var explanation = detail
        var result = MessageAttachment(fileName: sanitizedFileName(fileName), mimeType: mimeType, byteCount: byteCount,
            extractedText: bounded.value, readStatus: status, readDetail: explanation)
        if resourceBounded.wasTruncated {
            result.readStatus = .partial
            explanation = [explanation, "The 50-million-character extraction resource limit was reached. Text after that limit is unavailable; narrow the project scope to include it."].compactMap { $0 }.joined(separator: " ")
        }
        if bounded.wasTruncated {
            do {
                let reference = try AttachmentTextCorpusStore.store(resourceBounded.value)
                result.textCorpusID = reference.id
                result.textCorpusUTF16Count = reference.utf16Count
                explanation = [explanation, "All \(reference.utf16Count) extracted characters are indexed locally. This saved preview shows the first \(bounded.value.utf16.count) characters; questions can search the complete extracted text, including later files and pages."].compactMap { $0 }.joined(separator: " ")
            } catch {
                result.readStatus = .partial
                explanation = [explanation, "Full-text indexing failed: \(error.localizedDescription). Only the \(bounded.value.utf16.count)-character preview is retained. Read the attachment again before relying on its remaining contents."].compactMap { $0 }.joined(separator: " ")
            }
        }
        result.readDetail = explanation
        return result
    }

    static func extractPDFText(data: Data) -> String? {
        guard let attachment = try? extractedPDF(data: data, fileName: "document.pdf"), attachment.readStatus == .complete else { return nil }
        return try? AttachmentTextCorpusStore.text(for: attachment)
    }

    private static func extractedPDF(data: Data, fileName: String) throws -> MessageAttachment {
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else {
            throw AttachmentReadError.unreadable("The PDF is locked or could not be opened.")
        }
        var text = ""
        var units = 0
        var missing: [Int] = []
        var completedPages = 0
        var stoppedAtResourceLimit = false
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard units < AttachmentTextCorpusStore.maximumUTF16Units else { stoppedAtResourceLimit = true; break }
            do {
                guard let page = document.page(at: index) else { throw AttachmentReadError.unreadable("Missing PDF page") }
                let pageText = try readPDFPage(page)
                if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append(index + 1) }
                else {
                    let part = "\(text.isEmpty ? "" : "\n\n")[Page \(index + 1)]\n\(pageText)"
                    let available = AttachmentTextCorpusStore.maximumUTF16Units - units
                    let bounded = TextInputPolicy.boundedResult(part, maximumUTF16Units: available)
                    text += bounded.value
                    units += bounded.value.utf16.count
                    if bounded.wasTruncated { stoppedAtResourceLimit = true; break }
                }
                completedPages = index + 1
            } catch is CancellationError { throw CancellationError() }
            catch { missing.append(index + 1); completedPages = index + 1 }
        }
        var details: [String] = []
        if stoppedAtResourceLimit {
            details.append("The 50-million-character extraction resource limit was reached after \(completedPages) complete pages of \(document.pageCount). The next page may be partial; remaining pages have not been indexed. Read a smaller page range to include them.")
        } else { details.append("Read \(document.pageCount - missing.count) of \(document.pageCount) pages.") }
        if !missing.isEmpty { details.append("Pages with no readable text after OCR: \(missing.map(String.init).joined(separator: ", ")).") }
        details.append("PDF text/OCR is included; uncaptioned diagrams and exact layout may need a screenshot.")
        return boundedAttachment(fileName: fileName, mimeType: "application/pdf", byteCount: data.count, text: text,
            status: text.isEmpty ? .unreadable : (stoppedAtResourceLimit || !missing.isEmpty ? .partial : .complete),
            detail: details.joined(separator: " "))
    }

    /// Project images contribute OCR text to the full project index. The image
    /// itself still requires a separate visual attachment; OCR is not vision.
    static func projectImageText(_ attachment: MessageAttachment) throws -> MessageAttachment {
        try Task.checkCancellation()
        guard let data = attachment.imageData,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return unavailable(fileName: attachment.fileName, mimeType: attachment.mimeType, byteCount: attachment.byteCount,
                detail: "The project image could not be opened for OCR; its visual content is unavailable.")
        }
        let text = try recognizedImageText(image)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return unavailable(fileName: attachment.fileName, mimeType: attachment.mimeType, byteCount: attachment.byteCount,
                detail: "No readable text was found by OCR. The image itself is not included in project text; attach it separately for visual inspection.")
        }
        let frameNotice = attachment.effectiveReadStatus == .partial ? " " + (attachment.readDetail ?? "Only the first frame was inspected.") : ""
        return boundedAttachment(fileName: attachment.fileName, mimeType: attachment.mimeType, byteCount: attachment.byteCount,
            text: text, status: .partial,
            detail: "Image text indexed with OCR. Recognition may be imperfect; the image and its diagram geometry are not included in project text. Attach the image separately for visual inspection." + frameNotice)
    }

    /// Shared by full attachments and scoped local reads. OCR only touches this page.
    static func readPDFPage(_ page: PDFPage) throws -> String {
        try Task.checkCancellation()
        let text = page.string ?? ""
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        let thumbnail = page.thumbnail(of: NSSize(width: 2_000, height: 2_000), for: .mediaBox)
        var bounds = CGRect(origin: .zero, size: thumbnail.size)
        guard let image = thumbnail.cgImage(forProposedRect: &bounds, context: nil, hints: nil) else {
            throw AttachmentReadError.unreadable("A scanned PDF page could not be rendered for OCR.")
        }
        return try recognizedImageText(image)
    }

    private static func recognizedImageText(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func decodedText(_ data: Data) -> String? {
        let encoding: String.Encoding
        if data.starts(with: [0xff, 0xfe, 0, 0]) { encoding = .utf32LittleEndian }
        else if data.starts(with: [0, 0, 0xfe, 0xff]) { encoding = .utf32BigEndian }
        else if data.starts(with: [0xff, 0xfe]) { encoding = .utf16LittleEndian }
        else if data.starts(with: [0xfe, 0xff]) { encoding = .utf16BigEndian }
        else { encoding = .utf8 }
        guard let text = String(data: data, encoding: encoding) else { return nil }
        let scalars = text.unicodeScalars
        // Do not turn binary files containing printable runs into fake evidence.
        let invalid = scalars.filter { $0.value == 0 || ($0.value < 32 && $0 != "\n" && $0 != "\r" && $0 != "\t" && $0.value != 12) }.count
        guard invalid == 0 else { return nil }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
    }

    static func inferredMIMEType(fileName: String) -> String {
        UTType(filenameExtension: (fileName as NSString).pathExtension.lowercased())?.preferredMIMEType ?? "application/octet-stream"
    }

    private static func normalizedMIMEType(_ value: String?) -> String {
        String(value?.split(separator: ";", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func sanitizedFileName(_ value: String) -> String {
        let withoutControls = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(withoutControls.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(200))
    }
}
