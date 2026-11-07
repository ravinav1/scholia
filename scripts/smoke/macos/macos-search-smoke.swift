import Foundation
@testable import ScholiaMac

@main
struct SearchSmoke {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-search-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root), search = StudyWorkspaceSearch()
        var a = StudyCourse(name: "Linear algebra"), b = StudyCourse(name: "Other workspace")
        let texts = ["Eigenvectors and a change\nof basis", "C++ x.y [a-z] 100% _id", "CAFÉ cafe\u{0301} ＡＢＣ naïve",
                     "日本語の資料 😀🐈🐕 Ångström İSTANBUL", "a ab xy", "needle unrelated haystack"]
        for i in 0..<30 {
            let doc = StudyDocument(title: "Lecture \(i)", kind: .text, fileName: "lecture-\(i).txt", pageCount: 3)
            let pages = (0..<3).map { StudyPage(number: $0 + 1, text: texts[(i + $0) % texts.count]) }
            try store.write(document: doc, index: StudyDocumentIndex(pages: pages), data: Data())
            if i % 2 == 0 { a.documents.append(doc) } else { b.documents.append(doc) }
        }
        a.canvasMaterials = [CanvasMaterialReference(id: "files:1", kind: .files, remoteID: "1", title: "Cloud lecture",
            sourceURL: "https://canvas.example/files/1", version: "1")]
        let scoped = try await search.search(courses: [a, b], store: store, query: "basis", courseID: a.id.uuidString)
        precondition(scoped.updatedFiles == a.documents.count + 1)
        let other = try await search.search(courses: [a, b], store: store, query: "basis", courseID: b.id.uuidString)
        precondition(other.updatedFiles == b.documents.count)
        let queries = ["basis", "Eigenvectors basis", "\"change of basis\"", "\"change of basis", "a", "xy", "absent",
                       "C++", "x.y", "[a-z]", "100%", "_id", "CAFE\u{0301}", "ＡＢＣ", "日本語", "😀🐈🐕", "ångström",
                       "İSTANBUL", "needle haystack", "Lecture 12", "OR", "\"\"", "", "x'); DROP TABLE files; --"]
        func signature(_ result: StudySearchResponse) -> [String] {
            result.results.map { "\($0.id):\($0.page):\($0.passages)" }
        }
        for query in queries {
            for scope in ["", a.id.uuidString] {
                for mode in ["all", "files", "content"] {
                    let indexed = try await search.search(courses: [a, b], store: store, query: query, courseID: scope, mode: mode)
                    let scan = try await search.search(courses: [a, b], store: store, query: query, courseID: scope, mode: mode, scan: true, accelerated: false)
                    precondition(signature(indexed) == signature(scan), "Candidate recall: \(query), \(mode)")
                    precondition(indexed.total == scan.total)
                }
            }
        }
        let doc = a.documents[0]
        var result = try await search.search(courses: [a, b], store: store, query: "cloud")
        precondition(result.results.first?.materialID == "files:1")
        precondition(result.coverage["remoteFiles"] == 1)
        precondition(result.updatedFiles == 0)
        try store.write(document: doc, index: StudyDocumentIndex(pages: [StudyPage(number: 3, text: "unique replacement evidence")]), data: Data())
        result = try await search.search(courses: [a, b], store: store, query: "replacement")
        precondition(result.results.first?.page == 3 && result.updatedFiles == 1)
        let reopened = StudyWorkspaceSearch()
        result = try await reopened.search(courses: [a, b], store: store, query: "replacement")
        precondition(result.updatedFiles == 0 && result.total == 1)
        try FileManager.default.removeItem(at: store.directory(for: doc.id).appendingPathComponent("index.json"))
        result = try await search.search(courses: [a, b], store: store, query: "replacement")
        precondition(result.total == 0 && result.coverage["unavailableFiles"] == 1)
        a.documents.removeFirst()
        result = try await search.search(courses: [a, b], store: store, query: "lecture-0.txt")
        precondition(result.total == 0)
        print("PASS: native Needle, \(queries.count * 6) NEON/index versus SQLite instr comparisons, scopes, Unicode, cloud names, edits, deletion, missing text and persistence")
        if CommandLine.arguments.contains("--semantic") {
            let semanticRoot = root.appendingPathComponent("semantic")
            let semanticStore = StudyLibraryStore(root: semanticRoot)
            var course = StudyCourse(name: "Semantic search fixture")
            for (title, text) in [
                ("Control systems", "A PID regulator compares measurements with a reference. Negative feedback corrects errors and stabilizes a closed loop system."),
                ("Genetic ethics", "Editing the DNA of embryos raises ethical concerns about consent and inherited disorders."),
                ("Cooking", "Bread is baked using yeast, flour and water.")
            ] {
                let document = StudyDocument(title: title, kind: .text, fileName: "\(title).txt", pageCount: 3)
                try semanticStore.write(document: document, index: StudyDocumentIndex(pages: [StudyPage(number: 3, text: text)]), data: Data())
                course.documents.append(document)
            }
            let deadline = Date().addingTimeInterval(180)
            for (query, expected) in [("How can I keep a motor stable?", "Control systems"),
                                      ("Is it right to change a baby’s genes?", "Genetic ethics")] {
                while true {
                    let result = try await search.search(courses: [course], store: semanticStore, query: query, mode: "semantic")
                    precondition(result.semantic?.state != "error", result.semantic?.message ?? "Semantic search failed")
                    if result.semantic?.state == "ready" {
                        precondition(result.results.first?.title == expected)
                        precondition(result.results.first?.page == 3)
                        print("Native semantic search: \(query) → \(expected), \(result.totalMs) ms")
                        break
                    }
                    precondition(Date() < deadline, "Semantic indexing timed out")
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            for _ in 0..<10 {
                let repeated = try await search.search(courses: [course], store: semanticStore,
                    query: "How can I keep a motor stable?", mode: "semantic")
                precondition(repeated.updatedFiles == 0, "IPC encoding order must not invalidate a file revision")
                precondition(repeated.semantic?.state == "ready")
                precondition(repeated.results.first?.title == "Control systems")
            }
            print("PASS: native semantic IPC, real local model, progress, relevance and page navigation")
        }
    }
}
