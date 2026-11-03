import Foundation
@preconcurrency import PDFKit

/// PDFKit's file parsing runs away from the main actor, one document at a time.
/// Once returned, the worker never accesses the document again: the receiving
/// reader has sole ownership. PDFView itself always remains on the main actor.
actor StudyPDFDocumentLoader {
    static let shared = StudyPDFDocumentLoader()

    struct LoadedDocument: @unchecked Sendable {
        let document: PDFDocument?
    }

    func load(_ url: URL) throws -> LoadedDocument {
        try Task.checkCancellation()
        let document = autoreleasepool { PDFDocument(url: url) }
        try Task.checkCancellation()
        return LoadedDocument(document: document)
    }
}
