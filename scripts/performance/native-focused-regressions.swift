import AppKit
import Foundation
import Combine
@testable import ScholiaMac

private func check(_ value: Bool, _ message: String = "", line: UInt = #line) {
    if !value { print("FAIL line \(line): \(message)"); exit(1) }
}

@main struct NativeFocusedRegressions {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-native-regression-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let provider = ProviderCatalog.provider(id: "openai")
        let prepared = try PromptBuilder.prepare(messages: [ConversationMessage(role: .user, content: "Explain feedback")], capture: nil, languagePreference: .english)
        for (modelID, requested, expected) in [("gpt-6.1-sol", "xhigh", "xhigh"), ("gpt-6.1-sol", "invalid", "medium"), ("gpt-6-sol", "high", "high")] {
            let configuration = ProviderConfiguration(provider: provider, model: modelID, endpoint: provider.endpoint,
                apiKey: "fixture", language: .english, reasoningEffort: requested, fastClaudeMode: false)
            let request = try ProviderClient().buildRequest(prepared: prepared, configuration: configuration, endpoint: URL(string: provider.endpoint)!)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            print("Checking provider", modelID, requested, body["reasoning_effort"] ?? "missing")
            check(body["reasoning_effort"] as? String == expected && body["temperature"] == nil)
        }
        print("PASS native GPT-6.1 Sol extra-high reasoning payload and metadata fallback")
        let doc = try StudyDocumentImporter.read(data: Data("Original reading".utf8), name: "reading.txt", store: store)
        let course = StudyCourse(name: "Électronics 10", code: "TTK10", documents: [doc])
        try store.save(StudyLibrary(courses: [course, StudyCourse(name: "Electronics 2", code: "TTK2")]))
        let model = StudyWorkspaceModel(store: store)
        model.classificationTask?.cancel()
        check(model.courses(matching: "electr").count == 2)
        let builds = model.courseCatalog.rebuildCount
        model.library.courses[0].documents[0].title = "Changed current reading"
        check(model.sortedCourses.first(where: { $0.id == course.id })?.documents[0].title == "Changed current reading")
        check(model.courseCatalog.rebuildCount == builds, "Document metadata cannot rebuild ordering")
        for query in ["T", "TT", "TTK", "TTK1", ""] { _ = model.courses(matching: query) }
        check(model.courseCatalog.rebuildCount == builds, "Typing must reuse prepared metadata")
        model.library.courses[0].code = "UPDATED"
        check(model.courses(matching: "updated").count == 1)
        check(model.courseCatalog.rebuildCount == builds + 1)
        model.library.courses.reverse()
        check(model.courses(matching: "updated").first?.id == course.id)
        let agenda = StudyAssignmentAgendaState(workspace: model)
        let groupingTime = Date(timeIntervalSince1970: 1_800_000_000)
        _ = agenda.groups(query: "", filter: .due, now: groupingTime)
        let groupsBuilt = agenda.groupingBuildCount
        _ = agenda.groups(query: "", filter: .due, now: groupingTime.addingTimeInterval(10))
        check(agenda.groupingBuildCount == groupsBuilt, "Repeated dashboard visits within a minute reuse deadline groups")
        _ = agenda.groups(query: "", filter: .due, now: groupingTime.addingTimeInterval(60))
        check(agenda.groupingBuildCount == groupsBuilt + 1, "Deadline groups invalidate at the next minute")
        let agendaBuilds = agenda.projectionBuildCount
        model.library.courses[0].threads.append(StudyThread(mode: .explain))
        model.library.courses[0].threads[0].draft = "Streaming and draft changes"
        check(agenda.projectionBuildCount == agendaBuilds, "Chat changes cannot reconstruct assignments")
        print("PASS native metadata cache invalidation, fresh content and assignment work counts")

        var second = try StudyDocumentImporter.read(data: Data("Second reading evidence".utf8), name: "second.txt", store: store)
        second.pageCount = 3
        try store.write(document: second, index: StudyDocumentIndex(pages: [
            StudyPage(number: 1, text: "Beginning"), StudyPage(number: 2, text: "Middle"),
            StudyPage(number: 3, text: "Second reading evidence with unique pagetarget")]), data: Data("Second reading evidence".utf8))
        let third = try StudyDocumentImporter.read(data: Data("Third reading evidence".utf8), name: "third.txt", store: store)
        let otherCourse = StudyCourse(name: "Other owner", documents: [second, third])
        model.library.courses.append(otherCourse)
        check(model.openReading(doc.id, courseID: course.id))
        model.draft = "Preserve the first reading's unsent draft"
        let oldRoute = (model.course?.id, model.document?.id)
        var invalidSelections = 0
        let observer = model.$library.sink { library in
            if let id = library.selectedDocumentID,
               library.courses.first(where: { $0.id == library.selectedCourseID })?.documents.contains(where: { $0.id == id }) != true {
                invalidSelections += 1
            }
        }
        check(!model.openReading(second.id, courseID: course.id), "Wrong ownership must leave navigation untouched")
        check(model.course?.id == oldRoute.0 && model.document?.id == oldRoute.1)
        check(model.openReading(second.id, courseID: otherCourse.id, page: 999))
        check(model.currentPage == second.pageCount && model.course?.id == otherCourse.id)
        check(model.library.courses.first(where: { $0.id == course.id })?.threads.last?.draft == "Preserve the first reading's unsent draft")
        model.goBack()
        check(model.course?.id == course.id && model.document?.id == doc.id, "One cross-course opening creates exactly one history entry")
        check(model.draft == "Preserve the first reading's unsent draft")
        model.goForward()
        check(model.document?.id == second.id)
        model.draft = "Keep this conversation when following a citation"
        model.saveDraft()
        let conversation = model.thread?.id
        model.navigate(to: StudySource(documentID: third.id, title: third.title, page: 1))
        check(model.thread?.id == conversation && model.draft == "Keep this conversation when following a citation")
        let search = try await model.fileSearch.search(courses: model.library.courses, store: store, query: "pagetarget", mode: "content")
        let hit = search.results.first!
        check(hit.documentID == second.id.uuidString && hit.page == 3)
        check(model.openReading(UUID(uuidString: hit.documentID!)!, courseID: UUID(uuidString: hit.courseID)!, page: hit.page))
        check(model.currentPage == 3, "A content-search hit opens its exact indexed page across workspaces")
        for _ in 0..<20 {
            model.openReading(doc.id, courseID: course.id)
            model.openReading(second.id, courseID: otherCourse.id)
        }
        for _ in 0..<100 where model.documentIndex == nil { try await Task.sleep(for: .milliseconds(10)) }
        check(model.currentPageText.contains("Second reading evidence"), "Late old loads must not replace the latest reading")
        var replacement = second
        replacement.fileName = third.fileName
        replacement.sourceVersion = "replaced"
        let oi = model.library.courses.firstIndex(where: { $0.id == otherCourse.id })!
        model.library.courses[oi].documents[0] = replacement
        // Same document ID and nil/equal content hash still require a new load.
        try store.write(document: replacement, index: StudyDocumentIndex(pages: [
            StudyPage(number: 1, text: "Replacement beginning"), StudyPage(number: 2, text: "Replacement middle"),
            StudyPage(number: 3, text: "Replacement evidence")]), data: Data("Replacement evidence".utf8))
        model.openReading(second.id, courseID: otherCourse.id, page: 3)
        for _ in 0..<100 where model.documentIndex == nil { try await Task.sleep(for: .milliseconds(10)) }
        check(model.currentPageText.contains("Replacement evidence"), "Replacement must load current contents on the requested page")
        model.openReading(third.id, courseID: otherCourse.id)
        model.removeDocument(third.id)
        try await Task.sleep(for: .milliseconds(30))
        check(model.document == nil && model.documentIndex == nil)
        check(!model.resumeReading(third.id, page: 1), "A stale practice source cannot open a deleted reading")
        check(invalidSelections == 0)
        observer.cancel()
        print("PASS atomic reading ownership, draft/conversation/history, citation, rapid navigation, replacement and deletion")

        let writer = StudyEditDraftWriter(root: root)
        let id = UUID(), other = UUID()
        for index in 0..<100 { writer.save(StudyEditDraft(documentID: id, revision: "r", source: "draft \(index)", cells: [])) { _, _ in } }
        writer.remove(id) { _, _ in }
        writer.save(StudyEditDraft(documentID: other, revision: "r", source: "other document", cells: [])) { _, _ in }
        try writer.flush()
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Editing/\(id).json").path), "Canceled draft cannot return after an older save")
        let saved = try JSONDecoder().decode(StudyEditDraft.self, from: Data(contentsOf: root.appendingPathComponent("Editing/\(other).json")))
        check(saved.source == "other document")
        let editing = StudyEditingState(store: store)
        editing.begin(doc)
        editing.cancel(doc.id)
        try await Task.sleep(for: .milliseconds(50))
        check(editing.drafts[doc.id] == nil, "Late recovery cannot resurrect canceled editor")
        editing.begin(doc)
        for _ in 0..<100 where editing.busy { try await Task.sleep(for: .milliseconds(10)) }
        editing.setSource("Latest restarted draft", documentID: doc.id)
        editing.flushAndWait()
        let restored = StudyEditingState(store: store)
        restored.begin(doc)
        for _ in 0..<100 where restored.busy { try await Task.sleep(for: .milliseconds(10)) }
        check(restored.drafts[doc.id]?.source == "Latest restarted draft")
        print("PASS native coalesced saves, ordered tombstones, canceled recovery and restart durability")
        model.flush()
    }
}
