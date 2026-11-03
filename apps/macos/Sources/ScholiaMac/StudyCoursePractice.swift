import Foundation

enum CoursePracticeStyle: String, CaseIterable, Identifiable {
    case concepts, recall, application, exam
    var id: String { rawValue }
    var title: String {
        switch self {
        case .concepts: "Understand concepts"
        case .recall: "Active recall"
        case .application: "Apply & solve"
        case .exam: "Exam practice"
        }
    }
    var instruction: String {
        switch self {
        case .concepts: "Test conceptual understanding: explain why, contrast related ideas, expose a common misconception, and connect to prerequisites. The worked solution should teach the idea with a concrete example."
        case .recall: "Use focused active-recall questions about essential ideas, relationships and formulas, asking for justification rather than isolated trivia."
        case .application: "Ask the student to apply the material to a new concrete situation, calculation, derivation, interpretation or problem. Include all necessary givens, units and assumptions."
        case .exam: "Create exam-style questions with explicit parts and marking criteria appropriate to the source. Use past papers when supplied as evidence of format and level. Give a fully worked model answer. Label generated questions as practice; never claim to predict the exam."
        }
    }
}

struct CoursePracticeMaterial: Encodable, Identifiable {
    var id: UUID
    var title: String
    var pages: Int
    var attempted: Int
    var independent: Int
    var needsReview: Int
}
struct CoursePracticeConcept: Encodable, Identifiable {
    var id: UUID
    var title: String
    var attempts: Int
    var independent: Bool
    var needsReview: Bool
}
struct CoursePracticeCoverage: Encodable {
    var courseID: UUID
    var title: String
    var saved: Int
    var missing: Int
    var materials: [CoursePracticeMaterial]
    var concepts: [CoursePracticeConcept]
}

extension StudyLearningModel {
    func coverage(course: StudyCourse) -> CoursePracticeCoverage {
        let questions = state.questions.values.filter { $0.source.courseID == course.id }
        let current = questions.filter { !Self.stale($0.source, library: StudyLibrary(courses: [course])) }
        let questionIDs = Set(current.map(\.id))
        let attempts = state.attempts.filter { questionIDs.contains($0.questionID) }
        let byQuestion = Dictionary(grouping: attempts, by: \.questionID)
        let materials = course.documents.map { doc in
            let sourced = current.filter { $0.source.documentID == doc.id }
            let byPage = Dictionary(grouping: sourced, by: { $0.source.page })
            var attempted = 0, independent = 0, needsReview = 0
            for (_, qs) in byPage {
                let evidence = qs.flatMap { byQuestion[$0.id] ?? [] }.sorted { $0.createdAt < $1.createdAt }
                if let latest = evidence.last {
                    attempted += 1
                    if latest.independentSuccess { independent += 1 } else { needsReview += 1 }
                }
            }
            return CoursePracticeMaterial(id: doc.id, title: doc.title, pages: max(0, doc.pageCount - doc.unreadablePages),
                attempted: attempted, independent: independent, needsReview: needsReview)
        }
        let concepts = state.concepts.values.filter { $0.courseID == course.id }.map { concept in
            let evidence = attempts.filter { concept.questionIDs.contains($0.questionID) }.sorted { $0.createdAt < $1.createdAt }
            return CoursePracticeConcept(id: concept.id, title: concept.description, attempts: evidence.count,
                independent: evidence.last?.independentSuccess == true,
                needsReview: !evidence.isEmpty && evidence.last?.independentSuccess != true)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return CoursePracticeCoverage(courseID: course.id, title: course.displayName, saved: course.documents.count,
            missing: course.materials.filter { ref in !course.documents.contains { $0.sourceKey == ref.id } }.count,
            materials: materials, concepts: concepts)
    }
}

extension StudyWorkspaceModel {
    nonisolated static func coursePracticeSources(course: StudyCourse, scope: String, count: Int, weak: Bool,
        history: LearningState, store: StudyLibraryStore,
        indexed: (StudyDocument, StudyDocumentIndex) -> Void = { _, _ in }) throws -> [LearningSource] {
        let words = scope.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 2 }
        let questions = history.questions.values.filter { $0.source.courseID == course.id }
        let bySource = Dictionary(grouping: questions) { "\($0.source.documentID):\($0.source.page)" }
        let byQuestion = Dictionary(grouping: history.attempts, by: \.questionID)
        struct Candidate {
            var doc: StudyDocument; var page: StudyPage; var generated: Int; var weak: Bool; var relevance: Int
        }
        var candidates: [Candidate] = []
        for doc in course.documents {
            try Task.checkCancellation()
            let index: StudyDocumentIndex
            do { index = try store.readingIndex(for: doc) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
            indexed(doc, index)
            for page in index.pages where !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let qs = (bySource["\(doc.id):\(page.number)"] ?? []).filter {
                    $0.source.contentHash == doc.contentHash && $0.source.sourceVersion == doc.sourceVersion
                }
                let attempts = qs.flatMap { byQuestion[$0.id] ?? [] }.sorted { $0.createdAt < $1.createdAt }
                let text = (doc.title + " " + page.text).lowercased()
                let relevance = words.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
                if !words.isEmpty && relevance == 0 { continue }
                candidates.append(Candidate(doc: doc, page: page, generated: qs.count,
                    weak: attempts.last.map { !$0.independentSuccess } ?? false, relevance: relevance))
            }
        }
        // Cycle across every saved document and every readable page. Previously
        // generated pages move back; an explicit gap session prioritizes weaker evidence.
        var result: [LearningSource] = [], selectedByDocument: [UUID: Int] = [:]
        let generatedByDocument = Dictionary(grouping: questions, by: { $0.source.documentID }).mapValues(\.count)
        while !candidates.isEmpty && result.count < count {
            candidates.sort { a, b in
                if weak && a.weak != b.weak { return a.weak }
                if a.relevance != b.relevance { return a.relevance > b.relevance }
                if a.generated != b.generated { return a.generated < b.generated }
                let left = (selectedByDocument[a.doc.id] ?? 0) * 100000 + (generatedByDocument[a.doc.id] ?? 0)
                let right = (selectedByDocument[b.doc.id] ?? 0) * 100000 + (generatedByDocument[b.doc.id] ?? 0)
                if left != right { return left < right }
                if a.page.number != b.page.number { return a.page.number < b.page.number }
                return a.doc.title == b.doc.title ? a.doc.id.uuidString < b.doc.id.uuidString : a.doc.title < b.doc.title
            }
            let candidate = candidates.removeFirst(), doc = candidate.doc
            let hash = try doc.contentHash ?? StudyDocumentEditing.revision(Data(contentsOf: store.file(for: doc)))
            result.append(LearningSource(courseID: course.id, documentID: doc.id, title: doc.title,
                page: candidate.page.number, contentHash: hash, sourceVersion: doc.sourceVersion,
                excerpt: String(candidate.page.text.prefix(8000))))
            selectedByDocument[doc.id, default: 0] += 1
        }
        return result
    }
}
