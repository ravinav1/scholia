import Foundation
import XCTest
@testable import ScholiaMac

final class StudyWorkspaceMemoryTests: XCTestCase {
    func testLegacyModesMigrateWithoutDroppingConversations() throws {
        for (old, expected) in [("Guide me", StudyTeachingMode.explain), ("Chat", .chat), ("General", .chat)] {
            XCTAssertEqual(try JSONDecoder().decode(StudyTeachingMode.self, from: Data("\"\(old)\"".utf8)), expected)
        }
        XCTAssertEqual(StudyTeachingMode.allCases.map(\.rawValue), ["Explain", "Practice", "General"])
        XCTAssertFalse(PromptBuilder.systemPrompt(language: "en", mode: .chat).contains("never produce a complete submission"))
    }

    @MainActor
    func testMemoryPersistsAcrossChatsAndKeepsAssignmentsSeparate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let file = try StudyDocumentImporter.read(data: Data("Pinned motor torque constant: 0.042 Nm/A.".utf8), name: "Motor.txt", store: store)
        let assignments = ["a", "b"].map { id in
            CanvasMaterialReference(id: id, kind: .assignments, remoteID: id, title: id, sourceURL: "https://example.com/\(id)", version: "1")
        }
        let course = StudyCourse(name: "Control", documents: [file], canvasMaterials: assignments)
        try store.save(StudyLibrary(courses: [course], selectedCourseID: course.id, showingCourseLibrary: false))
        let model = StudyWorkspaceModel(store: store)
        try model.saveWorkspaceMemory(courseID: course.id, assignmentID: nil, notes: "Use SI units", documentIDs: [])
        try model.saveWorkspaceMemory(courseID: course.id, assignmentID: "a", notes: "Motor project", documentIDs: [file.id])
        try model.saveWorkspaceMemory(courseID: course.id, assignmentID: "b", notes: "Pendulum project", documentIDs: [])
        model.newThread()
        model.flush()
        let reopened = StudyWorkspaceModel(store: store)
        let saved = try XCTUnwrap(reopened.course)
        XCTAssertEqual(saved.assignmentMemories?["a"]?.documentIDs, [file.id])
        let a = StudyContextBuilder.build(document: nil, index: nil, currentPage: 1, question: "what do we know?", selection: "", course: saved, store: store, includeCourse: false, assignment: assignments[0])
        XCTAssertTrue(a.text.contains("Motor project"))
        XCTAssertTrue(a.text.contains("0.042 Nm/A"))
        XCTAssertFalse(a.text.contains("Pendulum project"))
        let b = StudyContextBuilder.build(document: nil, index: nil, currentPage: 1, question: "what do we know?", selection: "", course: saved, store: store, includeCourse: false, assignment: assignments[1])
        XCTAssertTrue(b.text.contains("Use SI units"))
        XCTAssertTrue(b.text.contains("Pendulum project"))
        XCTAssertFalse(b.text.contains("Motor project") || b.text.contains("0.042 Nm/A"))
        XCTAssertThrowsError(try model.saveWorkspaceMemory(courseID: course.id, assignmentID: "a", notes: "", documentIDs: [UUID()]))
    }

    func testFilenameSearchIsImmediateWithoutAnyIndexes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = StudyLibraryStore(root: root)
        let file = StudyDocument(title: "KybintroKompendium.pdf", kind: .pdf, fileName: "book.pdf", pageCount: 800)
        var course = StudyCourse(name: "Kybernetikk introduksjon", code: "TTK4100", documents: [file])
        let search = StudyWorkspaceSearch()
        let result = try await search.search(courses: [course], store: store, query: "ttk4100 kybtintro kompendium", mode: "files")
        XCTAssertEqual(result.results.first?.documentID, file.id.uuidString)
        XCTAssertEqual(result.results.first?.approximate, true)
        XCTAssertEqual(result.strategy, "names")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        course.documents = []
        let removed = try await search.search(courses: [course], store: store, query: "kompendium", mode: "files")
        XCTAssertEqual(removed.total, 0)
    }
}
