import Foundation
import PDFKit
import SwiftUI
import WebKit
@testable import ScholiaMac

extension StudyWorkspaceSmoke {
    static func checkCourseDocuments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-course-docs-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let source = "https://canvas.example/courses/24659/pages/week-35-brownian-dynamics-2"
        let html = StudyHTML.original(title: "Week 35", body: """
            <h2>Extra material</h2>
            <p><a id="brown" href="/courses/24659/files/1174749?wrap=1" target="_blank">Brown_Brownian.pdf</a></p>
            <p><a id="same" href="/courses/24659/files/1174749?wrap=1">Same window</a></p>
            <p><a id="named" href="/courses/24659/files/1174749/preview" target="canvas-preview">Preview</a></p>
            <script>bad()</script>
            """, source: source)
        let original = try StudyDocumentImporter.read(data: Data(html.utf8), name: "Week.html", store: store)
        precondition(original.isHTML)
        let bytes = try Data(contentsOf: store.file(for: original))
        precondition(bytes == Data(html.utf8))
        let text = try store.index(for: original).pages.map(\.text).joined(separator: "\n")
        precondition(text.contains("[Brown_Brownian.pdf](https://canvas.example/courses/24659/files/1174749?wrap=1)"))
        precondition(!text.contains("bad()"))
        var week = try StudyDocumentImporter.read(data: Data("Extra material\n\nBrown_Brownian.pdf".utf8), name: "Week.md", store: store)
        week.sourceKey = "pages:week-35-brownian-dynamics-2"
        var paper = try StudyDocumentImporter.read(data: Data("The Brown paper original".utf8), name: "Brown.md", store: store)
        paper.sourceKey = "files:1174749"; paper.sourceVersion = "1"
        let ref = CanvasMaterialReference(id: "files:1174749", kind: .files, remoteID: "1174749", title: "Brown_Brownian.pdf",
            sourceURL: "https://canvas.example/courses/24659/files/1174749", version: "1", linkedFromID: week.sourceKey)
        var course = StudyCourse(name: "Bionano", documents: [week, paper], canvasID: 24659, canvasOrigin: "https://canvas.example", canvasMaterials: [ref])
        precondition(StudyHTML.restoringLinks("Brown_Brownian.pdf", document: week, course: course).hasPrefix("[Brown_Brownian.pdf]"))
        try store.save(StudyLibrary(courses: [course], selectedCourseID: course.id, selectedDocumentID: week.id))
        let workspace = StudyWorkspaceModel(store: store)
        precondition(workspace.openCourseLink(URL(string: ref.sourceURL + "?wrap=1")!))
        precondition(workspace.document?.id == paper.id, "A course link opens the saved original document")
        try await checkNativeCourseLinkDispatch(original: original, workspace: workspace, paper: paper)
        course = StudyCourse(name: "Complete course")
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
            precondition(sources.count == 12 && Set(sources.map(\.documentID)).count == 12)
            for source in sources {
                precondition(visited.insert("\(source.documentID):\(source.page)").inserted)
                let q = LearningQuestion(concept: "Concept", prompt: "Explain", referenceAnswer: "Solution", rubric: ["Reasoning"],
                    hints: ["Cue", "Method", "Step"], source: source, model: "fixture")
                history.questions[q.id] = q
            }
        }
        precondition(visited.count == 72)
        try store.save(StudyLibrary(courses: [course], selectedCourseID: course.id, selectedDocumentID: course.documents[0].id))
        let model = StudyWorkspaceModel(store: store)
        model.preparePractice(count: 12, scope: "", openBook: false, configuration: practiceConfiguration, sourceScope: "course", style: "exam") { messages, _, _ in
            precondition(messages.first!.content.contains("exam-style"))
            let questions = (0..<12).map { i in
                ["concept": "Concept \(i)", "prompt": "Explain the mechanism in source \(i)", "referenceAnswer": "A justified causal explanation.",
                    "rubric": ["Identifies the cause"], "hints": ["Recall", "Apply", "First step"], "sourceIndex": i, "requiresVisual": false] as [String: Any]
            }
            let text = String(data: try JSONSerialization.data(withJSONObject: ["questions": questions]), encoding: .utf8)!
            return CompletionResult(text: text, providerID: "fixture", providerName: "Fixture", model: "fixture")
        }
        for _ in 0..<100 where model.learning.state.session == nil { try await Task.sleep(for: .milliseconds(30)) }
        guard let session = model.learning.state.session else { throw StudyError.message(model.learning.error ?? "Course practice did not generate") }
        precondition(session.questionIDs.count == 12)
        precondition(Set(model.learning.state.questions.values.map { $0.source.documentID }).count == 12)
        let coverage = model.learning.coverage(course: course)
        precondition(coverage.materials.reduce(0) { $0 + $1.pages } == 72)
        precondition(coverage.materials.reduce(0) { $0 + $1.attempted } == 0)
        print("PASS: original HTML, WebKit new-window and same-window document clicks, PDFKit links, legacy Brown link navigation, 72-page course coverage and 12-question exam sessions")
    }

    /// Exercise WebKit's actual navigation dispatch. Calling openCourseLink
    /// directly misses target="_blank", the shape used by Canvas's Brown link.
    static func checkNativeCourseLinkDispatch(original: StudyDocument, workspace: StudyWorkspaceModel,
        paper: StudyDocument) async throws {
        var opened: [URL] = []
        let reader = StudyOriginalHTML(url: workspace.store.file(for: original),
            sourceURL: "https://canvas.example/courses/24659/pages/week-35-brownian-dynamics-2") { url in
                opened.append(url)
                precondition(workspace.openCourseLink(url), "Course document clicks must be handled inside Scholia")
                return true
            }
        let coordinator = reader.makeCoordinator()
        let webView = reader.makeWebView(coordinator: coordinator)
        reader.loadOriginal(into: webView, coordinator: coordinator)
        var ready = false
        for _ in 0..<100 {
            ready = (try? await webView.callAsyncJavaScript("return !!document.getElementById('brown')",
                arguments: [:], in: nil, contentWorld: .defaultClient)) as? Bool == true
            if ready { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(ready, "The original Canvas HTML must render")
        for (offset, id) in ["brown", "same", "named"].enumerated() {
            _ = try await webView.callAsyncJavaScript("document.getElementById(id).click()",
                arguments: ["id": id], in: nil, contentWorld: .defaultClient)
            for _ in 0..<100 where opened.count < offset + 1 { try await Task.sleep(for: .milliseconds(30)) }
            precondition(opened.count == offset + 1, "The \(id) link must open exactly once through Scholia")
            precondition(workspace.document?.id == paper.id)
        }
        precondition(webView.url?.absoluteString == "about:blank", "The saved page must not navigate to Canvas")
        webView.stopLoading()

        var pdfOpened = false
        let pdfReader = StudyPDFReader(url: workspace.store.file(for: paper), page: .constant(1), selection: .constant(""),
            selectingFigure: .constant(false), zoom: 1, onFigure: { _ in }, onOpenLink: { url in
                pdfOpened = workspace.openCourseLink(url)
                return pdfOpened
            })
        let pdfCoordinator = pdfReader.makeCoordinator()
        let pdf = PDFView()
        pdf.delegate = pdfCoordinator
        pdf.perform(PDFActionURL(url: URL(string: "https://canvas.example/courses/24659/files/1174749")!))
        precondition(pdfOpened, "PDF annotations must use the same in-app document route")
    }
}
