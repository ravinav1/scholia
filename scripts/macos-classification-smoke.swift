import AppKit
import CoreText
import PDFKit
@testable import ScholiaMac

struct StudyClassificationSmoke {
    func testContentHeadingsBeatMisleadingFilenameAndRetainTopic() {
        let analysis = classify("Lecture 3.pdf", text: "# Final exam: Linear algebra\nAllowed aids: none\nCandidate number: 123\nExamination time: 3 hours")
        requireEqual(analysis.categoryID, "exams")
        precondition(analysis.basis.contains("content headings"))
        requireNotNil(analysis.topic)
    }
    func testCourseCodeAndDocumentTypeBoilerplateAreNotTopics() {
        let analysis = classify("scan.pdf", text: "# TMA4115 / LECTURE NOTES\n## Linear transformations\nToday we study linear maps")
        requireEqual(analysis.categoryID, "lectures")
        requireEqual(analysis.topic, "Linear transformations")
    }
    func testIncidentalExamMentionDoesNotTurnReadingIntoExam() {
        let analysis = classify("download.pdf", text: "# Eigenvectors and diagonalization\nWe discuss a complete example of finding eigenvectors. You may see this on an exam, but it is not an exam paper.\nAbstract\nA journal article about linear maps.\nReferences\nDOI: 10.123/example")
        requireEqual(analysis.categoryID, "readings")
        requireEqual(analysis.topic, "Eigenvectors and diagonalization")
    }
    func testSolutionsAreDistinctWithoutTreatingMathematicalSolutionsAsAnswerKeys() {
        requireEqual(classify("download.pdf", text: "# Solutions to Exercise 4\nSuggested solution\nProblem 1: matrices").categoryID, "solutions")
        for heading in ["Solutions of differential equations", "A solution to the heat equation"] {
            let result = classify("download.pdf", text: "# \(heading)\nExistence and uniqueness on a bounded domain")
            requireEqual(result.categoryID, "documents")
            requireEqual(result.topic, heading)
        }
    }
    func testReadableImageDoesNotGetHiddenAsCourseAsset() {
        let result = StudyMaterialClassifier.analyze(title: "logo", fileName: "logo.png", kind: .image,
            pages: [StudyPage(number: 1, text: "Lecture 4: Eigenvectors\nToday we discuss linear maps", extractionMethod: "ocr", ocrConfidence: 0.92)])
        requireEqual(result.categoryID, "lectures")
        requireEqual(result.extractionMethod, "ocr")
        requireEqual(result.topic, "Eigenvectors")
        requireEqual(StudyMaterialClassifier.analyze(title: "logo", fileName: "logo.png", kind: .image).categoryID, "assets")
    }
    func testUnreliableOCRDoesNotInventCategoryOrTopic() {
        let result = StudyMaterialClassifier.analyze(title: "scan", fileName: "scan.pdf", kind: .pdf,
            pages: [StudyPage(number: 1, text: "Final exam: Linear algebra", extractionMethod: "ocr", ocrConfidence: 0.4)])
        requireEqual(result.categoryID, "documents")
        requireEqual(result.confidence, "low")
        requireNil(result.topic)
    }
    func testAmbiguousStrongHeadingsStayInDocuments() {
        let result = classify("download.pdf", text: "Lecture 4\nExercise 4\nLinear algebra")
        requireEqual(result.categoryID, "documents")
        requireEqual(result.confidence, "low")
    }
    func testSamplingIsBoundedAndCoversWholeLongDocument() {
        let indices = StudyMaterialClassifier.sampleIndices(count: 4_000)
        requireAtMost(indices.count, 12)
        requireEqual(Array(indices.prefix(3)), [0, 1, 2])
        requireEqual(indices.last, 3_999)
        let pages = (0..<4_000).map { StudyPage(number: $0 + 1, text: $0 % 2 == 0 ? "Typed footer" : String(repeating: "Full digital content. ", count: 30)) }
        let ocr = StudyOCRIndexing.candidateIndices(pages: pages)
        requireEqual(ocr.count, 2_000)
        precondition(ocr.allSatisfy { $0 % 2 == 0 })
        requireEqual(ocr.last, 3_998)
    }
    func testOCRMergePreservesNativeTextAndAvoidsDuplicateLines() {
        requireEqual(StudyOCRIndexing.merge(text: "Lecture 4\nEigenvectors", recognized: "Lecture 4\nEigenvectors\nHandwritten example"), "Lecture 4\nEigenvectors\nHandwritten example")
    }
    func testImportedClassificationPersistsAndOrganizedSearchFindsTopic() throws {
        try withStore { store in
            let doc = try StudyDocumentImporter.read(data: Data("# Lecture 4: Eigenvectors\nToday we discuss matrix diagonalization.".utf8), name: "scan.txt", store: store)
            requireEqual(doc.classification?.categoryID, "lectures")
            var ref = CanvasMaterialReference(id: "files:4", kind: .files, remoteID: "4", title: "scan", fileName: "scan.txt", sourceURL: "https://canvas.example/files/4", version: "1")
            ref.moduleID = 7; ref.moduleTitle = "Week 1"; ref.modulePosition = 1; ref.moduleItemPosition = 4
            var linked = doc; linked.sourceKey = ref.id
            let course = StudyCourse(name: "Algebra", documents: [linked], canvasMaterials: [ref])
            try store.save(StudyLibrary(courses: [course]))
            let restored = try store.load().courses[0]
            let groups = StudyMaterialOrganizer.groups(for: restored, query: "Eigenvectors")
            requireEqual(groups.first?.id, "module:7")
            requireEqual(groups.first?.items.first?.categoryID, "lectures")
            requireEqual(StudyMaterialOrganizer.files(for: restored, query: "Eigenvectors").count, 1)
            requireEqual(try store.index(for: linked).extractionVersion, StudyOCRIndexing.version)
        }
    }
    func testRevisionKeyedOCRSidecarNeverMasksEditedIndex() throws {
        try withStore { store in
            let original = Data("original".utf8)
            let old = StudyDocument(title: "old", kind: .pdf, fileName: "original.pdf", pageCount: 1, contentHash: StudyDocumentEditing.revision(original))
            try store.write(document: old, index: StudyDocumentIndex(pages: [StudyPage(number: 1, text: "Original index")]), data: original)
            let enriched = StudyDocumentIndex(pages: [StudyPage(number: 1, text: "Old OCR text")], extractionVersion: StudyOCRIndexing.version)
            try JSONEncoder().encode(enriched).write(to: unwrap(store.enrichedIndexURL(for: old)))
            requireEqual(try store.index(for: old).pages[0].text, "Old OCR text")
            var edited = old; edited.contentHash = StudyDocumentEditing.revision(Data("edited".utf8))
            try store.write(document: edited, index: StudyDocumentIndex(pages: [StudyPage(number: 1, text: "Edited index")]), data: Data("edited".utf8))
            requireEqual(try store.index(for: edited).pages[0].text, "Edited index")
        }
    }
    func testScannedImageUsesLocalOCRForClassification() throws {
        try withStore { store in
            let cg = try renderedImage(["Final exam: Linear algebra", "Allowed aids: none", "Candidate number: 123456"])
            let data = try unwrap(ImageEncoding.jpegData(from: cg))
            let document = try StudyDocumentImporter.read(data: data, name: "scan.jpg", store: store)
            let index = try store.index(for: document)
            precondition(index.pages[0].text.localizedCaseInsensitiveContains("Final exam"))
            requireEqual(index.pages[0].extractionMethod, "ocr")
            requireEqual(document.classification?.categoryID, "exams")
            precondition(document.contentNotice?.contains("Handwriting") == true)
        }
    }
    func testSparsePDFRetainsTypedFooterAndRecognizesScan() throws {
        try withStore { store in
            let scanned = try renderedImage(["Lecture 4: Eigenvectors", "Today we study linear maps", "Learning objectives"])
            let data = NSMutableData()
            let consumer = try unwrap(CGDataConsumer(data: data))
            var box = CGRect(x: 0, y: 0, width: 600, height: 800)
            let context = try unwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
            context.beginPDFPage(nil)
            context.draw(scanned, in: CGRect(x: 20, y: 300, width: 560, height: 400))
            draw("TMA4115 - 2026", at: CGPoint(x: 30, y: 30), in: context, size: 12)
            context.endPDFPage(); context.closePDF()
            let document = try StudyDocumentImporter.read(data: data as Data, name: "download.pdf", store: store)
            let index = try store.index(for: document)
            precondition(index.pages[0].text.contains("TMA4115"))
            precondition(index.pages[0].text.localizedCaseInsensitiveContains("Eigenvectors"))
            requireEqual(index.pages[0].extractionMethod, "mixed")
            requireEqual(document.classification?.categoryID, "lectures")
        }
    }
    private func classify(_ file: String, text: String) -> StudyMaterialClassification {
        StudyMaterialClassifier.analyze(title: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent,
            fileName: file, kind: .pdf, pages: [StudyPage(number: 1, text: text)])
    }
    private func withStore(_ body: (StudyLibraryStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(StudyLibraryStore(root: root))
    }
    private func renderedImage(_ lines: [String]) throws -> CGImage {
        let context = try unwrap(CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        for (index, line) in lines.enumerated() { draw(line, at: CGPoint(x: 80, y: 1020 - index * 120), in: context, size: 58) }
        return try unwrap(context.makeImage())
    }
    private func draw(_ line: String, at point: CGPoint, in context: CGContext, size: CGFloat) {
        let string = NSAttributedString(string: line, attributes: [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ])
        context.textPosition = point
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
}

private func requireEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}
private func requireAtMost<T: Comparable>(_ actual: T, _ expected: T, file: StaticString = #filePath, line: UInt = #line) {
    precondition(actual <= expected, file: file, line: line)
}
private func requireNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { precondition(value == nil, file: file, line: line) }
private func requireNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { precondition(value != nil, file: file, line: line) }
private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw StudyError.message("Missing classification fixture value") }
    return value
}

extension StudyWorkspaceSmoke {
    static func checkMaterialClassification() throws {
        let checks = StudyClassificationSmoke()
        checks.testContentHeadingsBeatMisleadingFilenameAndRetainTopic()
        checks.testIncidentalExamMentionDoesNotTurnReadingIntoExam()
        checks.testCourseCodeAndDocumentTypeBoilerplateAreNotTopics()
        checks.testSolutionsAreDistinctWithoutTreatingMathematicalSolutionsAsAnswerKeys()
        checks.testReadableImageDoesNotGetHiddenAsCourseAsset()
        checks.testUnreliableOCRDoesNotInventCategoryOrTopic()
        checks.testAmbiguousStrongHeadingsStayInDocuments()
        checks.testSamplingIsBoundedAndCoversWholeLongDocument()
        checks.testOCRMergePreservesNativeTextAndAvoidsDuplicateLines()
        try checks.testImportedClassificationPersistsAndOrganizedSearchFindsTopic()
        try checks.testRevisionKeyedOCRSidecarNeverMasksEditedIndex()
        try checks.testScannedImageUsesLocalOCRForClassification()
        try checks.testSparsePDFRetainsTypedFooterAndRecognizesScan()
        print("PASS: evidence-based classification, conservative ambiguity, persisted topics, module order, complete OCR candidates, scanned image and mixed PDF recognition, revision-keyed cache isolation")
    }
}
