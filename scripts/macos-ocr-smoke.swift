import AppKit
import CoreText
import PDFKit
@testable import ScholiaMac

extension StudyWorkspaceSmoke {
    static func checkDocumentOCR() async throws {
        let fixture = try ocrFixture(scans: 32)
        let pdf = PDFDocument(data: fixture)!
        let original = (0..<pdf.pageCount).map { StudyPage(number: $0 + 1, text: pdf.page(at: $0)!.string ?? "") }
        let recognized = "Eigenvectors preserve direction under linear transformations. Diagonalization describes a matrix using its eigenvalues and a basis of independent eigenvectors."
        var attempted = 0, partial = original
        do {
            _ = try StudyOCRIndexing.enrich(pages: original, pdf: pdf, checkpoint: { partial = $0 }, recognizePage: { _ in
                attempted += 1
                if attempted == 10 { throw CancellationError() }
                return .init(text: recognized, confidence: 0.99)
            })
            preconditionFailure("Cancellation must propagate")
        } catch is CancellationError { }
        precondition(partial.filter { $0.ocrVersion == StudyOCRIndexing.version }.count == 10)
        attempted = 0
        let resumed = try StudyOCRIndexing.enrich(pages: partial, pdf: pdf, recognizePage: { _ in
            attempted += 1
            return .init(text: recognized, confidence: 0.99)
        })
        precondition(attempted == 23, "Resume must skip the nine already recognized scans")
        precondition(resumed.pages.dropFirst().allSatisfy { $0.text == recognized && $0.extractionMethod == "ocr" },
            "Every dense invisible OCR layer must be replaced, including pages beyond the old 24-page budget")
        precondition(resumed.pages[0].text == original[0].text && resumed.pages[0].extractionMethod == "text")
        precondition(resumed.notice?.contains("all 33 pages checked") == true)
        let lowConfidence = try StudyOCRIndexing.enrich(pages: original, pdf: pdf, recognizePage: { _ in
            .init(text: "This text must not replace a readable source.", confidence: 0.2)
        })
        precondition(zip(lowConfidence.pages, original).allSatisfy { $0.text == $1.text })

        // Exercise Vision, saved legacy-index migration, and all text consumers.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-ocr-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let small = try ocrFixture(scans: 2), smallPDF = PDFDocument(data: small)!
        let document = StudyDocument(title: "Linked scanned notes", kind: .pdf, fileName: "original.pdf", pageCount: 3,
            sourceKey: "files:42", contentHash: StudyDocumentEditing.revision(small))
        let oldIndex = StudyDocumentIndex(pages: (0..<3).map {
            StudyPage(number: $0 + 1, text: smallPDF.page(at: $0)!.string ?? "")
        }, extractionVersion: 1, extractionNotice: "Old sampled OCR")
        try store.write(document: document, index: oldIndex, data: small)
        let refreshed = try await Task.detached { try store.readingIndex(for: document) }.value
        precondition(refreshed.extractionVersion == StudyOCRIndexing.version)
        precondition(refreshed.pages.dropFirst().allSatisfy { $0.extractionMethod == "ocr" && $0.text.contains("Eigenvectors") })
        let savedOriginal = try Data(contentsOf: store.file(for: document))
        precondition(savedOriginal == small, "OCR must leave the actual PDF unchanged")
        let cache = store.enrichedIndexURL(for: document)!
        let stamp = try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        _ = try store.readingIndex(for: document)
        let cachedStamp = try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        precondition(cachedStamp == stamp)
        let course = StudyCourse(name: "Algebra", documents: [document])
        let sources = try coursePracticeSourcesForOCR(course: course, store: store)
        precondition(sources.count == 3 && sources.allSatisfy { $0.excerpt.contains("Eigenvectors") })
        let pack = StudyContextBuilder.build(document: document, index: refreshed, currentPage: 3,
            question: "Explain eigenvectors", selection: "", course: course, store: store, includeCourse: true)
        precondition(pack.text.contains("Diagonalization"), "Tutor context must use recovered text")
        let search = StudyWorkspaceSearch()
        let hits = try await search.search(courses: [course], store: store, query: "Diagonalization", mode: "content")
        precondition(hits.total == 1 && hits.results[0].passages == 2)
        let host = StudyPDFHost()
        host.pdf.document = smallPDF
        let controls = StudyPDFControls()
        controls.attach(host)
        controls.search("Eigenvectors", pages: refreshed.pages, semantic: false)
        precondition(Set(controls.matches.map(\.page)) == [1, 2, 3],
            "Native PDF hits must be combined with OCR-only pages")
        host.stopObservingEvents()
        try checkMaterialClassification()
        print("PASS: all 32 scan pages, invisible OCR replacement, cancellation/resume, confidence fallback, Vision, immutable originals, cached upgrades, search, tutor context and course practice")

        if CommandLine.arguments.contains("--real-brown") {
            try await checkBrownOCR(store: store)
        }
    }

    static func coursePracticeSourcesForOCR(course: StudyCourse, store: StudyLibraryStore) throws -> [LearningSource] {
        try StudyWorkspaceModel.coursePracticeSources(course: course, scope: "", count: 3, weak: false,
            history: LearningState(), store: store)
    }

    static func checkBrownOCR(store: StudyLibraryStore) async throws {
        let live = StudyLibraryStore(), library = try live.load()
        guard let course = library.courses.first(where: { $0.canvasID == 24659 }),
            let brown = course.documents.first(where: { $0.sourceKey == "files:1174749" }) else {
            throw StudyError.message("Brown fixture unavailable")
        }
        // Read-only copy: production updates are performed by the installed app.
        let data = try Data(contentsOf: live.file(for: brown))
        let base = try JSONDecoder().decode(StudyDocumentIndex.self,
            from: Data(contentsOf: live.directory(for: brown.id).appendingPathComponent("index.json")))
        try store.write(document: brown, index: base, data: data)
        let started = Date()
        let result = try await Task.detached { try store.readingIndex(for: brown) }.value
        let recognized = result.pages.filter { $0.extractionMethod == "ocr" }.count
        precondition(result.pages.count == 24 && result.pages.allSatisfy { $0.ocrVersion == StudyOCRIndexing.version })
        precondition(recognized == 23, "All 23 scanned Brown pages must receive fresh OCR")
        precondition(!result.pages[2].text.contains("unimpregnttted"), "The damaged old OCR must not remain appended")
        let saved = try Data(contentsOf: store.file(for: brown))
        precondition(saved == data)
        print("PASS: Brown original preserved; \(recognized) scanned pages recognized, 24/24 checked in \(Int(Date().timeIntervalSince(started)))s")
        print("Brown page 3: \(result.pages[2].text.prefix(400))")
    }

    static func ocrFixture(scans: Int) throws -> Data {
        let width = 1600, height = 1200
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw StudyError.message("Could not create scan fixture")
        }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func line(_ value: String, context: CGContext, y: CGFloat, size: CGFloat) {
            let text = NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(rawValue: kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
                NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 65, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        for (i, value) in ["Eigenvectors preserve direction", "Linear transformations map vector spaces",
            "Diagonalization uses a basis of eigenvectors", "Eigenvalues describe the scaling of each vector"].enumerated() {
            line(value, context: bitmap, y: CGFloat(1040 - i * 160), size: 52)
        }
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 800, height: 600)
        let consumer = CGDataConsumer(data: data)!, context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        line("Eigenvectors and linear transformations", context: context, y: 500, size: 20)
        for i in 0..<4 { line("Selectable digital text stays readable and unchanged.", context: context, y: CGFloat(440 - i * 50), size: 20) }
        context.endPDFPage()
        for _ in 0..<scans {
            context.beginPDFPage(nil)
            context.draw(bitmap.makeImage()!, in: box)
            context.setTextDrawingMode(.invisible)
            for i in 0..<3 { line("Garbled legacy xxxxx layer badly misread text", context: context, y: CGFloat(480 - i * 70), size: 20) }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
