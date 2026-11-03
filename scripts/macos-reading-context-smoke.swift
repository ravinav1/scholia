import Foundation
@testable import ScholiaMac

private func check(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: "ReadingContextSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main
struct ReadingContextSmoke {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-reading-context-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let course = StudyCourse(name: "Cybernetics", code: "TTK4100")
        let document = StudyDocument(title: "Cybernetics compendium", kind: .pdf, fileName: "compendium.pdf", pageCount: 120)
        let index = StudyDocumentIndex(pages: (1...120).map { number in
            StudyPage(number: number, text: (number == 93 ? "Zebraquantum stability theorem. The distinctive cross-page result is 42.\n" : "")
                + (number == 7 ? "Current reader page. Proportional feedback compares a reference and measurement.\n" : "")
                + "Chapter \(number) topic. " + String(repeating: "Ordinary background with examples and definitions. ", count: 50))
        })
        func build(_ question: String, previous: [String] = [], current: Int = 7, using value: StudyDocumentIndex? = nil) -> StudyContextPack {
            StudyContextBuilder.build(document: document, index: value ?? index, currentPage: current,
                question: question, selection: "", course: course, store: store, includeCourse: false,
                budget: StudyContextBuilder.requestBudget(question), previousQuestions: previous)
        }
        let local = build("Explain this equation on the current page")
        try check(Set(local.sources.map(\.page)) == Set([6, 7, 8]), "local reading must stay on current page and immediate neighbors")
        try check(!local.wholeDocument && !local.text.contains("Zebraquantum"), "local question must not send the whole compendium")
        try check(local.summary.contains("Current p. 7") && local.text.utf16.count < 12_000, "local coverage must be compact and visible")
        let far = build("Explain the zebraquantum stability theorem")
        try check(far.sources.contains { $0.page == 93 } && far.sources.contains { $0.page == 7 }, "search must reach distant page while retaining reader anchor")
        try check(far.text.contains("distinctive cross-page result is 42") && far.text.contains("all 120 indexed pages"), "distant source and whole-index search scope must be explicit")
        try check(far.summary.contains("93") && !far.wholeDocument, "context summary must identify related pages without claiming whole document")
        let why = build("Why?", previous: ["Explain the zebraquantum stability theorem"])
        try check(why.sources.contains { $0.page == 93 } && why.text.contains("previous question's topic"), "short follow-up must retain distant topic")
        let reset = build("Summarize this page", previous: ["Explain the zebraquantum stability theorem"], current: 15)
        try check(Set(reset.sources.map(\.page)) == Set([14, 15, 16]) && !reset.text.contains("Zebraquantum"), "explicit local request resets previous distant topic")
        print("PASS compact current-page reading, whole-index distant search, and follow-up continuity")

        let requested = build("Explain pages 40-48")
        try check(Set(40...48).isSubset(of: Set(requested.sources.map(\.page))), "requested ranges beyond former six-page cap must all be represented")
        try check(requested.sources.contains { $0.page == 7 }, "requested distant range must retain current reader anchor")
        let priorRequested = build("Why?", previous: ["Explain page 87"])
        try check(priorRequested.sources.contains { $0.page == 87 }, "explicit prior page must survive generic follow-up")
        let newRequested = build("Explain page 20", previous: ["Explain zebraquantum on page 93"])
        try check(newRequested.sources.contains { $0.page == 20 } && !newRequested.sources.contains { $0.page == 93 }, "new explicit page must replace earlier topic and page")
        for text in ["Compare pages 10 and 50", "Sammenlign sider 10 og 50", "Compare pages 10, 50–52"] {
            let requestedList = build(text)
            try check(Set([10, 50]).isSubset(of: Set(requestedList.sources.map(\.page))), "page lists must retain every requested page: \(text)")
        }
        let linkedSelection = StudyContextBuilder.build(document: document, index: index, currentPage: 7,
            question: "How does this equation connect to zebraquantum?", selection: "Proportional feedback",
            course: course, store: store, includeCourse: false)
        try check(linkedSelection.sources.contains { $0.page == 93 }, "local selection must not suppress a meaningful distant topic")
        let crossWithExplicit = build("Explain zebraquantum and the formula on page 20")
        try check(Set([7, 20, 93]).isSubset(of: Set(crossWithExplicit.sources.map(\.page))), "explicit page and distant concept must coexist")
        var longPageIndex = index
        longPageIndex.pages[92].text = String(repeating: "Unrelated code comments. ", count: 900) + "\nlate_parameter = 81;\n" + String(repeating: "Other details. ", count: 100)
        let centered = build("What is late_parameter?", using: longPageIndex)
        try check(centered.text.contains("late_parameter = 81") && centered.text.contains("Excerpt from page text characters"), "matched text beyond a long page's prefix must survive excerpting")
        print("PASS explicit ranges, explicit-page follow-ups, and independent cross-page matches")

        let distraction = try StudyDocumentImporter.read(data: Data("UNRELATED COURSE SENTINEL. what does the use for".utf8), name: "Unrelated background.txt", store: store)
        let relevant = try StudyDocumentImporter.read(data: Data("Zebraquantum is supported by this separate experiment.".utf8), name: "Measurements.txt", store: store)
        let loadedCourse = StudyCourse(name: "Cybernetics", documents: [document, distraction, relevant])
        let defaultLocal = StudyContextBuilder.build(document: document, index: index, currentPage: 7,
            question: "Explain this equation", selection: "", course: loadedCourse, store: store, includeCourse: true)
        try check(!defaultLocal.text.contains("UNRELATED COURSE SENTINEL") && !defaultLocal.text.contains("separate experiment"), "default course context must not flood local questions")
        let relevantCourse = StudyContextBuilder.build(document: document, index: index, currentPage: 7,
            question: "What does zebraquantum use?", selection: "", course: loadedCourse, store: store, includeCourse: true)
        try check(relevantCourse.text.contains("separate experiment") && !relevantCourse.text.contains("UNRELATED COURSE SENTINEL"), "specific cross-course retrieval must require meaningful body matches")
        let broadCourse = StudyContextBuilder.build(document: nil, index: nil, currentPage: 1,
            question: "Overview", selection: "", course: loadedCourse, store: store, includeCourse: true)
        try check(broadCourse.sources.contains { $0.documentID == relevant.id } && broadCourse.sources.contains { $0.documentID == distraction.id }, "course-wide overviews must still span saved documents")
        print("PASS local course-noise suppression and meaningful cross-document evidence")

        let missing = build("Where is the absentquasar theorem discussed?")
        try check(missing.sources.count <= 3, "a vocabulary miss must not spam irrelevant pages")
        try check(missing.text.contains("not evidence that the topic is absent") && missing.text.contains("Ask for a specific term"), "search miss must disclose uncertainty and ask for missing evidence")
        try check(missing.summary.contains("No clear document match"), "search uncertainty must be visible in coverage summary")
        var incomplete = index; incomplete.pages = Array(index.pages.prefix(50))
        let partialIndex = build("Explain zebraquantum", using: incomplete)
        try check(partialIndex.text.contains("50 of 120 pages") && !partialIndex.wholeDocument, "incomplete index must not claim complete search or reading")
        print("PASS vocabulary-miss and incomplete-index honesty")

        let overview = build("Give an overview of the whole compendium")
        try check(overview.sources.contains { $0.page == 120 } && overview.sources.contains { $0.page == 93 }, "overview must cover distant chapters, not only opening pages")
        try check(overview.sources.count == 120 && !overview.wholeDocument && overview.text.contains("shortened"), "large overview must identify full distribution with partial page text")
        for question in ["What parts of the compendium is relevant for understanding the simulink diagram?",
                         "Which chapters apply to the attached project?",
                         "What sections of the compendium connect to this equation?",
                         "Hvilke deler av kompendiet er relevante for å forstå Simulink-diagrammet?"] {
            let mapping = build(question)
            try check(mapping.sources.contains { $0.page == 120 } && mapping.sources.contains { $0.page == 93 }
                && mapping.sources.contains { $0.page == 7 } && mapping.summary.contains("Overview"),
                "reading-to-project mapping needs distributed chapter coverage beyond literal product-name hits: \(question)")
        }
        try check(!StudyReadingRetrieval.isBroad("Which parts of this equation are relevant?"),
            "a question about one selected equation must remain local")
        print("PASS English/Norwegian compendium-to-project mapping preserves later chapter coverage")
        let small = StudyDocument(title: "Project notes", kind: .text, fileName: "notes.txt", pageCount: 8)
        let smallIndex = StudyDocumentIndex(pages: (1...8).map { StudyPage(number: $0, text: "Exact section \($0) evidence.") })
        let smallLocal = StudyContextBuilder.build(document: small, index: smallIndex, currentPage: 4,
            question: "Explain this page", selection: "", course: course, store: store, includeCourse: false)
        try check(Set(smallLocal.sources.map(\.page)) == Set([3, 4, 5]), "even short documents should compact for a local question")
        let smallWhole = StudyContextBuilder.build(document: small, index: smallIndex, currentPage: 4,
            question: "Explain the whole document", selection: "", course: course, store: store, includeCourse: false)
        try check(smallWhole.wholeDocument && smallWhole.sources.count == 8 && smallWhole.text.contains("Exact section 8 evidence"), "whole-document question must retain all short-document evidence")
        for kind in [StudyDocumentKind.text, .office, .notebook, .code, .pdf] {
            var generic = small; generic.kind = kind
            let full = try StudyContextBuilder.entireDocument(document: generic, index: smallIndex)
            try check(full.wholeDocument && full.sources.count == 8 && full.text.contains("Exact section 8 evidence"), "whole-document control must work for \(kind)")
        }
        let wholePDF = try StudyContextBuilder.entirePDF(document: document, index: index)
        try check(wholePDF.wholeDocument && wholePDF.text.contains("PDF page 120 of 120"), "legacy entire-PDF behavior retained")
        let selectedWhole = try StudyContextBuilder.entireDocument(document: small, index: smallIndex, selection: "EXPLICIT SELECTED EVIDENCE")
        try check(selectedWhole.text.contains("EXPLICIT SELECTED EVIDENCE") && selectedWhole.wholeDocument, "whole-document context must preserve explicit selection")
        let huge = StudyDocument(title: "Huge reading", kind: .pdf, fileName: "huge.pdf", pageCount: 900)
        let hugeIndex = StudyDocumentIndex(pages: (1...900).map { StudyPage(number: $0, text: String(repeating: "Useful page \($0) content. ", count: 50)) })
        let hugeRange = StudyContextBuilder.build(document: huge, index: hugeIndex, currentPage: 900,
            question: "Explain pages 1-500", selection: "", course: course, store: store, includeCourse: false, budget: 40_000)
        try check(hugeRange.sources.contains { $0.page == 900 } && hugeRange.text.contains("requested pages are not included"), "huge requested range must reserve current page and disclose omitted requests")
        print("PASS broad overviews across chapters and full text/Office/notebook/code/PDF control")

        let before = StudyReadingRetrieval.statistics
        var timings: [Double] = []
        for _ in 0..<12 {
            let start = Date()
            _ = build("Explain zebraquantum stability")
            timings.append(Date().timeIntervalSince(start) * 1_000)
        }
        let after = StudyReadingRetrieval.statistics
        try check(after.builds == before.builds && after.hits >= before.hits + 12, "warm requests must reuse tokenized full-index cache")
        var changed = index
        changed.pages[92].text = "Updated replacement-nebula evidence."
        let refreshed = build("Explain replacement nebula", using: changed)
        try check(refreshed.text.contains("Updated replacement-nebula evidence") && !refreshed.text.contains("distinctive cross-page result"), "edited/OCR index content must invalidate cache")
        let median = timings.sorted()[timings.count / 2]
        try check(median < 250, "warm retrieval must remain responsive")
        print("READING_CONTEXT_BENCHMARK indexed_pages=120 warm_median_ms=\(median) cache_hits=\(after.hits - before.hits) additional_source_file_reads=0 local_sent_chars=\(local.text.utf16.count) distant_sent_chars=\(far.text.utf16.count) full_text_chars=\(index.pages.reduce(0) { $0 + $1.text.utf16.count })")
        print("PASS all adaptive reading-context checks")
    }
}
