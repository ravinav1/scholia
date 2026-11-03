@preconcurrency import AppKit
import Foundation
import PDFKit
import Vision

/// Reading, tutor preparation and course practice can request the same legacy
/// PDF together. Share its completed cache instead of running competing OCR.
final class StudyOCRJobs: @unchecked Sendable {
    static let shared = StudyOCRJobs()
    private let condition = NSCondition()
    private var active: Set<String> = []
    func begin(_ key: String) throws {
        condition.lock()
        defer { condition.unlock() }
        while active.contains(key) {
            try Task.checkCancellation()
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
        }
        try Task.checkCancellation()
        active.insert(key)
    }
    func finish(_ key: String) {
        condition.lock()
        active.remove(key)
        condition.broadcast()
        condition.unlock()
    }
}

/// Downloads, reader upgrades and tutor preparation share one recognition slot.
/// Per-document deduplication alone allowed six different PDFs to run Vision at
/// once. Acquire before rendering so waiting jobs do not retain page bitmaps.
final class StudyOCRRecognitionGate: @unchecked Sendable {
    static let shared = StudyOCRRecognitionGate()
    private let condition = NSCondition()
    private var occupied = false

    func withSlot<T>(_ work: () throws -> T) throws -> T {
        condition.lock()
        do {
            while occupied {
                try Task.checkCancellation()
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
            }
            try Task.checkCancellation()
            occupied = true
            condition.unlock()
        } catch {
            condition.unlock()
            throw error
        }
        defer {
            condition.lock()
            occupied = false
            condition.signal()
            condition.unlock()
        }
        return try autoreleasepool(invoking: work)
    }
}

/// All recognition stays on the Mac, one page at a time. Checkpoints let long
/// scans resume without treating a small sample as a complete text index.
enum StudyOCRIndexing {
    static let version = 2
    struct Recognition {
        var text: String
        var confidence: Double
    }
    struct Result {
        var pages: [StudyPage]
        var notice: String?
    }
    static func sparse(_ text: String) -> Bool {
        // Character count alone misses a scanned page with a typed footer/title.
        text.unicodeScalars.lazy.filter { CharacterSet.letters.contains($0) }.prefix(121).count < 120
    }
    static func candidateIndices(pages: [StudyPage]) -> [Int] {
        pages.indices.filter { sparse(pages[$0].text) }
    }
    static func enrich(pages original: [StudyPage], pdf: PDFDocument,
        progress: (Int, Int) -> Void = { _, _ in }, checkpoint: ([StudyPage]) -> Void = { _ in },
        recognizePage: (PDFPage) throws -> Recognition = recognize(page:)) throws -> Result {
        var pages = original
        var characters = pages.reduce(0) { $0 + $1.text.utf16.count }
        var completed = pages.filter { $0.ocrVersion == version }.count
        progress(completed, pages.count)
        do {
            for index in pages.indices {
                try Task.checkCancellation()
                if pages[index].ocrVersion == version { continue }
                let updated = try autoreleasepool { () throws -> StudyPage in
                    guard let page = pdf.page(at: index) else {
                        throw StudyError.message("PDF page \(index + 1) could not be opened for OCR.")
                    }
                    // Re-read the original text layer when upgrading: older indexes
                    // may already contain garbled OCR appended to the native text.
                    let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let layer = StudyPDFTextLayer.inspect(page)
                    var updated = StudyPage(number: pages[index].number, text: text,
                        extractionMethod: text.isEmpty ? "none" : "text", ocrVersion: version)
                    if layer.hasImage || layer.hasInvisibleText || sparse(text) {
                        do {
                            let result = try recognizePage(page)
                            try Task.checkCancellation()
                            if result.confidence >= 0.55 && letterCount(result.text) >= 12 {
                                let replace = text.isEmpty || (layer.hasInvisibleText && !layer.hasVisibleText
                                    && letterCount(result.text) >= letterCount(text) / 2)
                                updated.text = replace ? result.text : merge(text: text, recognized: result.text)
                                updated.extractionMethod = replace ? "ocr" : updated.text == text ? "text" : "mixed"
                                updated.ocrConfidence = result.confidence
                                updated.ocrStatus = "recognized"
                            } else { updated.ocrStatus = "unreadable" }
                        } catch is CancellationError { throw CancellationError() }
                        catch { updated.ocrStatus = "failed" }
                    }
                    return updated
                }
                characters += updated.text.utf16.count - pages[index].text.utf16.count
                guard characters <= StudyDocumentImporter.maximumCharacters else {
                    throw StudyError.message("The document exceeds 8 million text characters after OCR.")
                }
                pages[index] = updated
                completed += 1
                progress(completed, pages.count)
                if completed % 8 == 0 { checkpoint(pages) }
            }
        } catch {
            checkpoint(pages)
            throw error
        }
        let recognized = pages.filter { ["ocr", "mixed"].contains($0.extractionMethod ?? "") }.count
        let failed = pages.filter { $0.ocrStatus == "failed" }.count
        let unreadable = pages.filter { $0.ocrStatus == "unreadable" }.count
        var notices: [String] = []
        if recognized > 0 {
            notices.append("On-device OCR indexed \(recognized) page\(recognized == 1 ? "" : "s"); all \(pages.count) pages checked. Handwriting and equations may not be fully recognized.")
        }
        if failed > 0 { notices.append("OCR failed on \(failed) page\(failed == 1 ? "" : "s"); any existing text was kept.") }
        if unreadable > 0 { notices.append("OCR found no reliable additional text on \(unreadable) page\(unreadable == 1 ? "" : "s").") }
        return Result(pages: pages, notice: notices.isEmpty ? nil : notices.joined(separator: " "))
    }
    static func letterCount(_ text: String) -> Int {
        text.unicodeScalars.lazy.filter { CharacterSet.letters.contains($0) }.count
    }
    static func merge(text: String, recognized: String) -> String {
        guard !text.isEmpty else { return recognized }
        func key(_ line: String) -> String {
            line.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        }
        let known = Set(text.components(separatedBy: .newlines).map(key).filter { !$0.isEmpty })
        var seen = known
        let novel = recognized.components(separatedBy: .newlines).filter { line in
            let value = key(line)
            return value.count > 2 && seen.insert(value).inserted
        }
        return novel.isEmpty ? text : text + "\n" + novel.joined(separator: "\n")
    }
    static func recognize(page: PDFPage) throws -> Recognition {
        try StudyOCRRecognitionGate.shared.withSlot {
            let image = page.thumbnail(of: NSSize(width: 2_200, height: 2_200), for: .mediaBox)
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return Recognition(text: "", confidence: 0)
            }
            return try performRecognition(image: cg)
        }
    }
    static func recognize(image: CGImage) throws -> Recognition {
        try StudyOCRRecognitionGate.shared.withSlot { try performRecognition(image: image) }
    }
    private static func performRecognition(image: CGImage) throws -> Recognition {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        // Vision otherwise favors throughput and may contend with WindowServer.
        request.preferBackgroundProcessing = true
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.004
        // Vision recognizes supported handwriting where legible; never promote low-confidence OCR noise to labels.
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        let candidates = (request.results ?? []).compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.35 }
        return Recognition(text: candidates.map(\.string).joined(separator: "\n"),
            confidence: candidates.isEmpty ? 0 : Double(candidates.reduce(0) { $0 + $1.confidence }) / Double(candidates.count))
    }
}

/// A scan can contain thousands of selectable characters from an older OCR
/// layer. PDF rendering mode 3 identifies that invisible text without guessing
/// its quality from spelling (which would penalize formulas and foreign text).
private final class StudyPDFTextLayer {
    var hasImage = false
    var hasVisibleText = false
    var hasInvisibleText = false
    var mode = 0
    var stack: [Int] = []
    var depth = 0
    var operations = 0
    static func inspect(_ page: PDFPage) -> StudyPDFTextLayer {
        let state = StudyPDFTextLayer()
        if let page = page.pageRef { state.scan(CGPDFContentStreamCreateWithPage(page)) }
        return state
    }
    static func state(_ scanner: CGPDFScannerRef, _ info: UnsafeMutableRawPointer?) -> StudyPDFTextLayer? {
        guard let info else { return nil }
        let state = Unmanaged<StudyPDFTextLayer>.fromOpaque(info).takeUnretainedValue()
        state.operations += 1
        if state.operations > 100_000 || Task.isCancelled { CGPDFScannerStop(scanner); return nil }
        return state
    }
    func scan(_ stream: CGPDFContentStreamRef) {
        guard depth < 8, let table = CGPDFOperatorTableCreate() else { return }
        depth += 1
        defer { depth -= 1 }
        CGPDFOperatorTableSetCallback(table, "q") { scanner, info in
            if let state = StudyPDFTextLayer.state(scanner, info) { state.stack.append(state.mode) }
        }
        CGPDFOperatorTableSetCallback(table, "Q") { scanner, info in
            if let state = StudyPDFTextLayer.state(scanner, info) { state.mode = state.stack.popLast() ?? 0 }
        }
        CGPDFOperatorTableSetCallback(table, "Tr") { scanner, info in
            guard let state = StudyPDFTextLayer.state(scanner, info) else { return }
            var mode: CGPDFInteger = 0
            if CGPDFScannerPopInteger(scanner, &mode) { state.mode = mode }
        }
        for op in ["Tj", "TJ", "'", "\""] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                guard let state = StudyPDFTextLayer.state(scanner, info) else { return }
                if state.mode == 3 { state.hasInvisibleText = true }
                else if state.mode != 7 { state.hasVisibleText = true }
            }
        }
        CGPDFOperatorTableSetCallback(table, "BI") { scanner, info in
            StudyPDFTextLayer.state(scanner, info)?.hasImage = true
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let state = StudyPDFTextLayer.state(scanner, info) else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            let parent = CGPDFScannerGetContentStream(scanner)
            guard let object = CGPDFContentStreamGetResource(parent, "XObject", name) else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            if String(cString: subtype) == "Image" { state.hasImage = true }
            else if String(cString: subtype) == "Form" {
                var resources: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                let mode = state.mode, stack = state.stack
                state.scan(CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, parent))
                state.mode = mode; state.stack = stack
            }
        }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(self).toOpaque())
        _ = CGPDFScannerScan(scanner)
    }
}
