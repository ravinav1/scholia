@preconcurrency import AppKit
import Foundation
import ImageIO
import PDFKit
import Vision

enum StudyDocumentKind: String, Codable, Sendable {
    case pdf, text, image, code, notebook, office, preview
    var symbol: String {
        switch self {
        case .pdf, .office: "doc.richtext"
        case .text, .preview: "doc.text"
        case .image: "photo"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .notebook: "book.closed"
        }
    }
}

struct StudyPage: Codable, Equatable, Sendable {
    var number: Int
    var text: String
    var images: [String]?
    var extractionMethod: String?
    var ocrConfidence: Double?
    var ocrVersion: Int?
    var ocrStatus: String?
}

struct StudyDocument: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var kind: StudyDocumentKind
    var fileName: String
    var pageCount: Int
    var unreadablePages: Int = 0
    var lastPage: Int = 1
    var addedAt = Date()
    var sourceURL: String?
    var sourceKey: String?
    var sourceVersion: String?
    var contentHash: String?
    var contentBytes: Int?
    var contentCheckedAt: Date?
    var contentIntegrity: CanvasSavedFileIntegrity?
    var contentNotice: String?
    var locallyEditedAt: Date?
    var lastOpenedAt: Date?
    var originalFileName: String?
    var classification: StudyMaterialClassification?

    var readingPosition: String {
        let unit = kind == .notebook ? "Cell" : [.code, .office].contains(kind) ? "Section" : "Page"
        return "\(unit) \(min(max(1, lastPage), max(1, pageCount))) of \(max(1, pageCount))"
    }
}

struct StudyRecentReading: Identifiable {
    let courseID: UUID
    let courseName: String
    let document: StudyDocument
    var id: UUID { document.id }

    static func inCourses(_ courses: [StudyCourse], limit: Int = 3) -> [Self] {
        courses.flatMap { course in
            course.documents.filter { $0.lastOpenedAt != nil }.map {
                Self(
                    courseID: course.id, courseName: course.code.isEmpty ? course.displayName : course.code,
                    document: $0)
            }
        }.sorted {
            if $0.document.lastOpenedAt != $1.document.lastOpenedAt {
                return $0.document.lastOpenedAt! > $1.document.lastOpenedAt!
            }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(max(0, limit)).map { $0 }
    }
}

struct StudyDocumentIndex: Codable, Sendable {
    var pages: [StudyPage]
    var extractionVersion: Int?
    var extractionNotice: String?
}

struct StudySource: Codable, Equatable, Identifiable, Sendable {
    var documentID: UUID
    var title: String
    var page: Int
    var id: String { "\(documentID.uuidString):\(page)" }
}

enum StudyTeachingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case explain = "Explain"
    case practice = "Practice"
    case chat = "General"
    // Decode existing conversations without losing their history or drafts.
    static func migrated(_ value: String) -> StudyTeachingMode? {
        if value == "Guide me" || value == "guide" { return .explain }
        if value == "Chat" || value == "chat" { return .chat }
        return Self(rawValue: value)
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let mode = Self.migrated(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown conversation mode")
        }
        self = mode
    }
    var id: String { rawValue }
    var summary: String {
        switch self {
        case .explain: "Clear explanations and step-by-step help when you need it."
        case .practice: "Try a question, then get feedback on your answer."
        case .chat: "Direct answers and open conversation, with your course as context."
        }
    }
    var starterTitle: String {
        switch self {
        case .explain: "Explain the key idea"
        case .practice: "Check my understanding"
        case .chat: "Talk through an idea"
        }
    }
    func starter(document: StudyDocument?) -> String {
        let scope =
            document.map {
                $0.kind == .notebook
                    ? "this notebook cell" : [.code, .office].contains($0.kind) ? "this section" : "this page"
            } ?? "the downloaded course materials"
        switch self {
        case .chat: return "Help me brainstorm and talk through an idea."
        case .explain: return "Explain the key idea in \(scope), with an intuitive example."
        case .practice:
            return
                "Ask me one question to test my understanding of \(scope). Wait for my answer before giving feedback or a solution."
        }
    }
    var instruction: String { TutoringPolicy.instructions(mode: self) }

}

struct StudyThread: Codable, Identifiable, Sendable {
    var id = UUID()
    var title = "New conversation"
    var documentID: UUID?
    var assignmentID: String?
    var mode: StudyTeachingMode = .explain
    var entirePDF: Bool?
    var automaticContextEnabled: Bool?
    var includeCourseContext: Bool?
    var messages: [ConversationMessage] = []
    var sources: [String: [StudySource]] = [:]
    var draft = ""
    var draftImage: Data?
    var draftAttachments: [MessageAttachment]?
    var updatedAt = Date()
    /// A hidden one-shot thread that answers passage explanations in the
    /// reader popover. Never listed as a conversation.
    var isSelectionScratch: Bool?
}

struct StudyCourse: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var code: String = ""
    var documents: [StudyDocument] = []
    var threads: [StudyThread] = []
    var canvasID: Int?
    var canvasOrigin: String?
    var canvasUserID: Int?
    var syncedAt: Date?
    // Optional additions keep version-1 libraries readable without losing local work.
    var favorite: Bool?
    var examFavorite: Bool?
    var canvasFavorite: Bool?
    var canvasMaterials: [CanvasMaterialReference]?
    var catalogUpdatedAt: Date?
    var catalogWarnings: [String]?
    var term: String?
    var canvasAvailable: Bool?
    var catalogChanges: CanvasCatalogChanges?
    var catalogChangedAt: Date?
    var visitCount: Int?
    var lastVisitedAt: Date?
    var hiddenAssignmentIDs: [String]?
    var assignmentProgress: [String: StudyAssignmentProgress]?
    var canvasFileSync: CanvasCourseFileSync?
    var contentUpdateAttemptedAt: Date?
    var mathWikiUpdateAttemptedAt: Date?
    var mathWikiCheckedAt: Date?
    var mathWikiWarnings: [String]?
    var canvasPolling: ContentPollingModel?
    var mathWikiPolling: ContentPollingModel?
    var aiMemory: StudyAIMemory?
    var assignmentMemories: [String: StudyAIMemory]?

    var displayName: String {
        let prefix = code + " :: "
        guard !code.isEmpty, name.hasPrefix(prefix) else { return name }
        let title = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? name : title
    }
    var isFavorite: Bool { favorite ?? canvasFavorite ?? false }
    var displayCode: String {
        code.replacingOccurrences(
            of: "-(?:\\d{2}[HV])(?:-\\d{2}[HV])*$", with: "", options: [.regularExpression, .caseInsensitive])
    }
    var materials: [CanvasMaterialReference] {
        guard let assignmentProgress, !assignmentProgress.isEmpty else { return canvasMaterials ?? [] }
        return (canvasMaterials ?? []).map { reference in
            var reference = reference
            reference.assignment?.progressOverride = assignmentProgress[reference.id]
            return reference
        }
    }
    var canvasURL: URL? {
        guard let canvasOrigin, let canvasID, let origin = try? CanvasAddress.origin(canvasOrigin) else { return nil }
        return origin.appendingPathComponent("courses/\(canvasID)")
    }
    var remoteOnlyMaterials: [CanvasMaterialReference] {
        let cached = Set(documents.compactMap(\.sourceKey))
        return materials.filter { !cached.contains($0.id) }
    }
    func updateAvailable(for document: StudyDocument) -> CanvasMaterialReference? {
        guard let key = document.sourceKey, let reference = materials.first(where: { $0.id == key }),
            !reference.version.isEmpty, reference.version != document.sourceVersion
        else { return nil }
        return reference
    }
}

struct StudyLibrary: Codable, Sendable {
    var version = 1
    var courses: [StudyCourse] = []
    var selectedCourseID: UUID?
    var selectedDocumentID: UUID?
    var selectedThreadID: UUID?
    var canvasOrigin = "https://canvas.ntnu.no"
    var canvasUserID: Int?
    var canvasUserName: String?
    var showingCourseLibrary: Bool?
    var courseLibraryView: StudyCourseLibraryViewMode?
    var selectedSemesterID: String?
    var canvasCheckedAt: Date?
    var canvasAssignmentsCheckedAt: Date?
    var canvasAssignmentsError: String?
    var canvasRefreshSummary: String?
    var selectedAssignmentID: String?
    var selectedAssignmentFileID: String?
    var examPlan: [StudyExam]?
}

enum StudyError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { message } else { nil } }
}

struct StudyLibraryStore: Sendable {
    let root: URL

    init(root: URL? = nil) {
        self.root =
            root
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scholia/Study", isDirectory: true)
    }

    func load() throws -> StudyLibrary {
        let file = root.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return StudyLibrary() }
        var library = try JSONDecoder().decode(StudyLibrary.self, from: Data(contentsOf: file))
        guard library.version == 1 else {
            throw StudyError.message("This library was created by a newer Scholia version.")
        }
        for ci in library.courses.indices {
            for ti in library.courses[ci].threads.indices {
                library.courses[ci].threads[ti].messages = library.courses[ci].threads[ti].messages.compactMap {
                    message in
                    guard message.isStreaming else { return message }
                    guard !message.content.isEmpty else { return nil }
                    var copy = message
                    copy.isStreaming = false
                    copy.metadata = "Response interrupted when Scholia closed"
                    return copy
                }
            }
        }
        return library
    }

    func save(_ library: StudyLibrary) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(library).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }

    func directory(for id: UUID) -> URL { root.appendingPathComponent("Documents/\(id.uuidString)", isDirectory: true) }
    func file(for document: StudyDocument) -> URL {
        directory(for: document.id).appendingPathComponent(URL(fileURLWithPath: document.fileName).lastPathComponent)
    }
    /// Run on an import worker: a filename alone does not prove a download finished.
    func isComplete(_ document: StudyDocument) throws -> Bool {
        try Task.checkCancellation()
        do {
            guard let hash = document.contentHash, !hash.isEmpty else { return false }
            let originalURL = file(for: document)
            let attributes = try originalURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard attributes.isRegularFile == true, let size = attributes.fileSize,
                size <= StudyDocumentImporter.maximumBytes else { return false }
            let original = try Data(contentsOf: originalURL, options: .mappedIfSafe)
            guard StudyDocumentEditing.revision(original) == hash else { return false }
            try Task.checkCancellation()
            // Validate the base index, not an optional OCR cache that could hide its absence.
            let indexURL = directory(for: document.id).appendingPathComponent("index.json")
            let index = try JSONDecoder().decode(StudyDocumentIndex.self, from: Data(contentsOf: indexURL))
            guard document.pageCount > 0, index.pages.count == document.pageCount,
                index.pages.enumerated().allSatisfy({ $0.element.number == $0.offset + 1 }) else { return false }
            for name in Set(index.pages.flatMap { $0.images ?? [] }) {
                guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent else { return false }
                let image = try directory(for: document.id).appendingPathComponent(name)
                    .resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard image.isRegularFile == true, (image.fileSize ?? 0) > 0 else { return false }
            }
            try Task.checkCancellation()
            return true
        } catch is CancellationError { throw CancellationError() }
        catch { return false }
    }
    func enrichedIndexURL(for document: StudyDocument) -> URL? {
        guard let hash = document.contentHash else { return nil }
        let key = StudyDocumentEditing.revision(Data(hash.utf8))
        return directory(for: document.id).appendingPathComponent("index-ocr-v\(StudyOCRIndexing.version)-\(key).json")
    }
    func index(for document: StudyDocument) throws -> StudyDocumentIndex {
        if let cached = enrichedIndexURL(for: document),
           let index = try? StudyDocumentIndexCache.shared.index(at: cached) { return index }
        return try StudyDocumentIndexCache.shared.index(
            at: directory(for: document.id).appendingPathComponent("index.json"))
    }
    /// Opening a legacy scan improves its index once. A revision-keyed sidecar cannot overwrite a concurrent edit.
    func readingIndex(for document: StudyDocument, progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> StudyDocumentIndex {
        try autoreleasepool { try enrichedReadingIndex(for: document, progress: progress) }
    }
    private func enrichedReadingIndex(for document: StudyDocument, progress: @Sendable (Int, Int) -> Void) throws -> StudyDocumentIndex {
        guard [.pdf, .image].contains(document.kind), let cache = enrichedIndexURL(for: document) else {
            return try index(for: document)
        }
        try StudyOCRJobs.shared.begin(cache.path)
        defer { StudyOCRJobs.shared.finish(cache.path) }
        var index = try self.index(for: document)
        guard index.extractionVersion != StudyOCRIndexing.version,
              let hash = document.contentHash else { return index }
        let original = try Data(contentsOf: file(for: document))
        guard StudyDocumentEditing.revision(original) == hash else { return index }
        if document.kind == .pdf, let pdf = PDFDocument(data: original) {
            let enriched = try StudyOCRIndexing.enrich(pages: index.pages, pdf: pdf, progress: progress, checkpoint: { pages in
                guard FileManager.default.fileExists(atPath: file(for: document).path) else { return }
                if let data = try? Data(contentsOf: cache),
                    let saved = try? JSONDecoder().decode(StudyDocumentIndex.self, from: data),
                    saved.extractionVersion == StudyOCRIndexing.version { return }
                let completed = pages.filter { $0.ocrVersion == StudyOCRIndexing.version }.count
                let partial = StudyDocumentIndex(pages: pages,
                    extractionNotice: "Recognizing text: \(completed) of \(pages.count) pages checked. OCR resumes when this document is opened.")
                try? JSONEncoder().encode(partial).write(to: cache, options: .atomic)
            })
            index.pages = enriched.pages
            index.extractionNotice = enriched.notice
        } else if document.kind == .image,
                  let source = CGImageSourceCreateWithData(original as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2_200,
                  ] as CFDictionary) {
            do {
                let result = try StudyOCRIndexing.recognize(image: image)
                if !result.text.isEmpty {
                    index.pages = [StudyPage(number: 1, text: result.text, extractionMethod: "ocr", ocrConfidence: result.confidence)]
                    index.extractionNotice = "Text recognized on this Mac. Handwriting and equations may not be fully recognized."
                }
            } catch is CancellationError { throw CancellationError() }
            catch { /* Keep the original index when Vision cannot read an image. */ }
        }
        try Task.checkCancellation()
        guard index.pages.reduce(0, { $0 + $1.text.utf16.count }) <= StudyDocumentImporter.maximumCharacters else { return try self.index(for: document) }
        index.extractionVersion = StudyOCRIndexing.version
        // Never recreate a removed document directory. Hash-specific names remain harmless if the directory is
        // concurrently replaced with a newer revision, and the reader only accepts its own revision's cache.
        if FileManager.default.fileExists(atPath: file(for: document).path) {
            try? JSONEncoder().encode(index).write(to: cache, options: .atomic)
        }
        return index
    }
    func write(document: StudyDocument, index: StudyDocumentIndex, data: Data) throws {
        try FileManager.default.createDirectory(at: directory(for: document.id), withIntermediateDirectories: true)
        try data.write(to: file(for: document), options: .atomic)
        try JSONEncoder().encode(index).write(
            to: directory(for: document.id).appendingPathComponent("index.json"), options: .atomic)
    }
}

enum StudyDocumentImporter {
    static let maximumBytes = 100_000_000
    static let maximumCharacters = 8_000_000
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "tex", "csv", "json", "html", "htm"]
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "tiff"]
    static var supportedExtensions: Set<String> {
        textExtensions.union(imageExtensions).union(StudyFileFormats.codeExtensions).union(
            StudyFileFormats.officeExtensions
        ).union(StudyFileFormats.previewExtensions).union(["pdf", "tsv", "log", "bib", "srt", "vtt"])
    }

    static func read(url: URL, store: StudyLibraryStore) throws -> StudyDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes else {
            throw StudyError.message("Choose a document smaller than 100 MB.")
        }
        return try read(data: Data(contentsOf: url), name: url.lastPathComponent, store: store)
    }

    static func read(data: Data, name: String, store: StudyLibraryStore, id: UUID = UUID(), displayTitle: String? = nil) throws -> StudyDocument {
        // Detached import tasks do not have AppKit's per-event autorelease pool.
        // Release PDFKit/Vision temporaries at each completed document.
        try autoreleasepool { try importDocument(data: data, name: name, store: store, id: id, displayTitle: displayTitle) }
    }

    private static func importDocument(data: Data, name: String, store: StudyLibraryStore, id: UUID, displayTitle: String?) throws -> StudyDocument {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw StudyError.message("The document is empty or exceeds 100 MB.")
        }
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let title = displayTitle ?? URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        var pages: [StudyPage] = []
        var unreadable = 0
        let kind: StudyDocumentKind
        let original: Data
        let fileName: String
        var extractedImages: [String: Data] = [:]
        var contentNotice: String?
        if ext == "pdf" {
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0, pdf.pageCount <= 4_000 else {
                throw StudyError.message(
                    "This PDF is locked, damaged, or exceeds 4,000 pages. Unlock it before importing.")
            }
            kind = .pdf
            original = data
            fileName = "original.pdf"
            var characters = 0
            for i in 0..<pdf.pageCount {
                try Task.checkCancellation()
                let text = try autoreleasepool {
                    guard let page = pdf.page(at: i) else {
                        throw StudyError.message("PDF page \(i + 1) could not be opened.")
                    }
                    return (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                }
                characters += text.utf16.count
                guard characters <= maximumCharacters else {
                    throw StudyError.message(
                        "The document exceeds 8 million text characters. Split it into smaller documents.")
                }
                pages.append(StudyPage(number: i + 1, text: text, extractionMethod: "text"))
            }
            let enriched = try StudyOCRIndexing.enrich(pages: pages, pdf: pdf)
            pages = enriched.pages
            contentNotice = enriched.notice
            unreadable = pages.filter { $0.text.isEmpty }.count
            guard pages.reduce(0, { $0 + $1.text.utf16.count }) <= maximumCharacters else {
                throw StudyError.message("The document exceeds 8 million text characters after OCR.")
            }
        } else if imageExtensions.contains(ext) {
            guard
                let source = CGImageSourceCreateWithData(
                    data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                let cg = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2_200,
                    ] as CFDictionary),
                let jpeg = ImageEncoding.jpegData(from: cg)
            else { throw StudyError.message("This image could not be decoded.") }
            kind = .image
            original = jpeg
            fileName = "original.jpg"
            let recognition: StudyOCRIndexing.Recognition
            do { recognition = try StudyOCRIndexing.recognize(image: cg) }
            catch is CancellationError { throw CancellationError() }
            catch { recognition = .init(text: "", confidence: 0) }
            pages = [StudyPage(number: 1, text: recognition.text, extractionMethod: "ocr", ocrConfidence: recognition.confidence)]
            unreadable = recognition.text.isEmpty ? 1 : 0
            contentNotice = recognition.text.isEmpty ? "On-device OCR could not read this image. The original is available in the reader."
                : "Text recognized on this Mac. Handwriting and equations may not be fully recognized."
        } else if ext == "ipynb" {
            let contents = try StudyFileFormats.notebook(data)
            kind = .notebook
            original = data
            fileName = "original.ipynb"
            pages = contents.pages
            extractedImages = contents.images
            contentNotice = contents.notice
        } else if StudyFileFormats.officeExtensions.contains(ext) {
            let contents = try StudyFileFormats.office(data, extension: ext)
            kind = .office
            original = data
            fileName = "original.\(ext)"
            pages = contents.pages
            extractedImages = contents.images
            contentNotice = contents.notice
        } else if StudyFileFormats.codeExtensions.contains(ext)
            || ["makefile", "dockerfile", ".gitignore"].contains(name.lowercased())
        {
            guard let text = String(data: data, encoding: .utf8), !text.contains("\0"),
                text.utf16.count <= maximumCharacters
            else { throw StudyError.message("Choose a UTF-8 source file smaller than 8 million characters.") }
            kind = .code
            original = data
            fileName = "original" + (ext.isEmpty ? ".txt" : ".\(ext)")
            pages = StudyFileFormats.code(text, name: name)
            unreadable = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? pages.count : 0
        } else if textExtensions.contains(ext) || ["tsv", "log", "bib", "srt", "vtt"].contains(ext)
            || (ext.isEmpty && String(data: data, encoding: .utf8)?.contains("\0") == false)
        {
            guard var text = String(data: data, encoding: .utf8), text.utf16.count <= maximumCharacters else {
                throw StudyError.message("Choose a UTF-8 text document with fewer than 8 million characters.")
            }
            let isHTML = ["html", "htm"].contains(ext)
            if isHTML { text = StudyHTML.markdown(text) }
            kind = .text
            original = isHTML ? data : Data(text.utf8)
            fileName = isHTML ? "original.html" : "original.md"
            // Stable, paragraph-sized reading pages also give text sources useful citations.
            var chunk = ""
            for rawParagraph in text.components(separatedBy: "\n\n") {
                var paragraph = rawParagraph[...]
                while let end = paragraph.index(paragraph.startIndex, offsetBy: 5_000, limitedBy: paragraph.endIndex),
                    end < paragraph.endIndex
                {
                    if !chunk.isEmpty {
                        pages.append(StudyPage(number: pages.count + 1, text: chunk))
                        chunk = ""
                    }
                    pages.append(StudyPage(number: pages.count + 1, text: String(paragraph[..<end])))
                    paragraph = paragraph[end...]
                }
                if chunk.count + paragraph.count > 5_000 && !chunk.isEmpty {
                    pages.append(StudyPage(number: pages.count + 1, text: chunk))
                    chunk = ""
                }
                chunk += (chunk.isEmpty ? "" : "\n\n") + String(paragraph)
            }
            if !chunk.isEmpty { pages.append(StudyPage(number: pages.count + 1, text: chunk)) }
            if pages.isEmpty { pages = [StudyPage(number: 1, text: "")] }
        } else if !StudyFileFormats.previewExtensions.contains(ext), let text = safePlainText(data) {
            // Simulation inputs and tables often use course-specific extensions.
            // Display their contents as source text; never execute or interpret them.
            kind = .code
            original = data
            fileName = "original" + (ext.isEmpty ? ".txt" : ".\(ext)")
            pages = StudyFileFormats.code(text, name: name)
            unreadable = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? pages.count : 0
        } else {
            kind = .preview
            original = data
            fileName = "original" + (ext.isEmpty ? ".bin" : ".\(ext)")
            contentNotice =
                "This file is available in the Mac app's original preview. Its contents have not been text-indexed; attach a screenshot or export to PDF for visual questions."
            pages = [StudyPage(number: 1, text: "")]
        }
        let classification = StudyMaterialClassifier.analyze(title: title, fileName: name, kind: kind, pages: pages)
        let document = StudyDocument(
            id: id, title: title, kind: kind, fileName: fileName, pageCount: pages.count, unreadablePages: unreadable,
            contentHash: StudyDocumentEditing.revision(original), contentNotice: contentNotice,
            originalFileName: URL(fileURLWithPath: name).lastPathComponent, classification: classification)
        try store.write(document: document, index: StudyDocumentIndex(pages: pages, extractionVersion: StudyOCRIndexing.version, extractionNotice: contentNotice), data: original)
        for (name, image) in extractedImages {
            try image.write(to: store.directory(for: id).appendingPathComponent(name), options: .atomic)
        }
        return document
    }

    static func safePlainText(_ data: Data) -> String? {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8),
            text.utf16.count <= maximumCharacters,
            text.unicodeScalars.allSatisfy({ scalar in
                !CharacterSet.controlCharacters.contains(scalar) || [9, 10, 12, 13].contains(scalar.value)
            })
        else { return nil }
        return text
    }


}

enum StudyHTML {
    /// Never uses WebKit/NSAttributedString HTML import: imported course markup cannot execute or fetch resources.
    static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: "(?is)<(script|style|iframe|object)\\b[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "(?i)<(?:br|/p|/div|/li|/h[1-6]|/tr)\\b[^>]*>", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, value) in [
            ("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&"),
        ] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: text), let digitsRange = Range(match.range(at: 1), in: text)
                else { continue }
                let digits = String(text[digitsRange])
                let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let value, let scalar = UnicodeScalar(value) { text.replaceSubrange(range, with: String(scalar)) }
            }
        }
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression).trimmingCharacters(
            in: .whitespacesAndNewlines)
    }
}
