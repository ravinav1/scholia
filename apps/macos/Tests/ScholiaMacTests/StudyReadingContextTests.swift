import Foundation
import XCTest
@testable import ScholiaMac

final class StudyReadingContextTests: XCTestCase {
    func testLocalReadingStaysCompactAndDistantQuestionSearchesFullIndex() {
        let document = StudyDocument(title: "Compendium", kind: .pdf, fileName: "book.pdf", pageCount: 100)
        let index = StudyDocumentIndex(pages: (1...100).map {
            StudyPage(number: $0, text: $0 == 87 ? "Zebraquantum gain is 42." : "Ordinary background \($0).")
        })
        let local = pack(document, index, "Explain this equation")
        XCTAssertEqual(Set(local.sources.map(\.page)), Set([6, 7, 8]))
        XCTAssertFalse(local.wholeDocument)
        let distant = pack(document, index, "What is zebraquantum?")
        XCTAssertTrue(distant.sources.contains { $0.page == 87 })
        XCTAssertTrue(distant.sources.contains { $0.page == 7 })
        XCTAssertTrue(distant.summary.contains("87"))
        XCTAssertTrue(distant.text.contains("all 100 indexed pages"))
        let followup = pack(document, index, "Why?", previous: ["What is zebraquantum?"])
        XCTAssertTrue(followup.sources.contains { $0.page == 87 })
        var otherTheorem = index
        otherTheorem.pages[86].text += " The theorem and its proof give this result."
        let missingTheorem = pack(document, otherTheorem, "Where is the absentquasar theorem discussed?")
        XCTAssertEqual(Set(missingTheorem.sources.map(\.page)), Set([6, 7, 8]))
        XCTAssertTrue(missingTheorem.text.contains("not evidence that the topic is absent"))
        let explicitNew = pack(document, index, "Explain page 20", previous: ["What is zebraquantum on page 87?"])
        XCTAssertTrue(explicitNew.sources.contains { $0.page == 20 })
        XCTAssertFalse(explicitNew.sources.contains { $0.page == 87 })
    }

    func testSpecificSelectionCanReachAnotherPageAndLongPageExcerptKeepsMatch() {
        let document = StudyDocument(title: "Notebook", kind: .notebook, fileName: "book.ipynb", pageCount: 12)
        let index = StudyDocumentIndex(pages: (1...12).map {
            StudyPage(number: $0, text: $0 == 12 ? String(repeating: "Earlier code. ", count: 1_000) + "zebraquantum = 42" : "Background \($0)")
        })
        let result = pack(document, index, "How does this equation connect to zebraquantum?", selection: "A = B")
        XCTAssertTrue(result.sources.contains { $0.page == 12 })
        XCTAssertTrue(result.text.contains("zebraquantum = 42"))
        XCTAssertTrue(result.text.contains("Excerpt from page text characters"))
    }

    func testPageListsNoMatchAndGenericWholeDocument() throws {
        XCTAssertEqual(StudyContextBuilder.explicitPages(in: "Compare pages 10 and 50", count: 80), [10, 50])
        XCTAssertEqual(StudyContextBuilder.explicitPages(in: "Sider 10 og 50–52", count: 80), [10, 50, 51, 52])
        let document = StudyDocument(title: "Notes", kind: .text, fileName: "notes.txt", pageCount: 8)
        let index = StudyDocumentIndex(pages: (1...8).map { StudyPage(number: $0, text: "Chapter \($0) exact evidence.") })
        let missing = pack(document, index, "Where is absentquasar?")
        XCTAssertTrue(missing.text.contains("not evidence that the topic is absent"))
        XCTAssertTrue(missing.text.contains("Ask for a specific term"))
        let broad = pack(document, index, "Explain the whole document")
        XCTAssertTrue(broad.wholeDocument)
        XCTAssertEqual(broad.sources.count, 8)
        let full = try StudyContextBuilder.entireDocument(document: document, index: index, selection: "Explicit selection")
        XCTAssertTrue(full.wholeDocument)
        XCTAssertTrue(full.text.contains("Explicit selection"))
        XCTAssertTrue(full.text.contains("Chapter 8 exact evidence"))
    }

    private func pack(_ document: StudyDocument, _ index: StudyDocumentIndex, _ question: String,
                      previous: [String] = [], selection: String = "") -> StudyContextPack {
        StudyContextBuilder.build(document: document, index: index, currentPage: 7, question: question,
            selection: selection, course: StudyCourse(name: "Test"),
            store: StudyLibraryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            includeCourse: false, budget: StudyContextBuilder.requestBudget(question), previousQuestions: previous)
    }
}
