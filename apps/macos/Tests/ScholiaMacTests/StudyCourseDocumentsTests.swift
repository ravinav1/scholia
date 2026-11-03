import XCTest
@testable import ScholiaMac

final class StudyCourseDocumentsTests: XCTestCase {
    func testOriginalHTMLAndBrownLinksSurviveImport() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let source = "https://canvas.example/courses/24659/pages/week-35-brownian-dynamics-2"
        let html = StudyHTML.original(title: "Week 35", body: "<h2>Extra material</h2><p><a href=\"/courses/24659/files/1174749?wrap=1\">Brown_Brownian.pdf</a></p><a href=\"https://doi.org/example\">Original article</a><script>bad()</script>", source: source)
        let doc = try StudyDocumentImporter.read(data: Data(html.utf8), name: "Week.html", store: store)
        XCTAssertTrue(doc.isHTML)
        XCTAssertEqual(try Data(contentsOf: store.file(for: doc)), Data(html.utf8))
        let text = try store.index(for: doc).pages.map(\.text).joined(separator: "\n")
        XCTAssertTrue(text.contains("[Brown_Brownian.pdf](https://canvas.example/courses/24659/files/1174749?wrap=1)"))
        XCTAssertTrue(text.contains("[Original article](https://doi.org/example)"))
        XCTAssertFalse(text.contains("bad()"))
        XCTAssertFalse(StudyHTML.markdown("<a href=\"javascript:alert(1)\">Unsafe</a>").contains("javascript:"))
    }
    func testLegacyWeeklyPageRestoresOnlyCatalogBackedLinks() {
        let doc = StudyDocument(title: "Week", kind: .text, fileName: "original.md", pageCount: 1,
            sourceKey: "pages:week-35-brownian-dynamics-2")
        let ref = CanvasMaterialReference(id: "files:1174749", kind: .files, remoteID: "1174749", title: "Brown_Brownian.pdf",
            sourceURL: "https://canvas.example/courses/24659/files/1174749", version: "1", linkedFromID: doc.sourceKey)
        let course = StudyCourse(name: "Bionano", canvasMaterials: [ref])
        XCTAssertTrue(doc.needsCanvasHTMLUpgrade)
        XCTAssertEqual(StudyHTML.restoringLinks("Extra material\n\nBrown_Brownian.pdf", document: doc, course: course),
            "Extra material\n\n[Brown_Brownian.pdf](https://canvas.example/courses/24659/files/1174749)")
    }
    func testPracticeRotatesThroughEveryPageBeyondFirstThirtyDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        var course = StudyCourse(name: "Bionano")
        for i in 0..<36 {
            let doc = StudyDocument(title: "Lecture \(i)", kind: .text, fileName: "original.md", pageCount: 2, contentHash: "hash-\(i)")
            try store.write(document: doc, index: StudyDocumentIndex(pages: [1, 2].map {
                StudyPage(number: $0, text: "Concept from lecture \(i), page \($0)")
            }), data: Data("Fixture".utf8))
            course.documents.append(doc)
        }
        var history = LearningState(), visited = Set<String>()
        for _ in 0..<6 {
            let sources = try StudyWorkspaceModel.coursePracticeSources(course: course, scope: "", count: 12,
                weak: false, history: history, store: store)
            XCTAssertEqual(sources.count, 12)
            XCTAssertEqual(Set(sources.map(\.documentID)).count, 12)
            for source in sources {
                XCTAssertTrue(visited.insert("\(source.documentID):\(source.page)").inserted)
                let question = LearningQuestion(concept: "Concept", prompt: "Explain", referenceAnswer: "Solution",
                    rubric: ["Reasoning"], hints: ["Cue", "Method", "Step"], source: source, model: "fixture")
                history.questions[question.id] = question
            }
        }
        XCTAssertEqual(visited.count, 72)
    }
}
