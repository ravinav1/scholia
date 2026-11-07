import Foundation

struct StudyDraftOwner: Codable, Equatable, Sendable {
    var courseID: UUID?
    var documentID: UUID?
    var threadID: UUID?
    var assignmentID: String?
    var page: Int
    var revision: String
}
extension StudyWorkspaceModel {
    var draftOwner: StudyDraftOwner {
        // Content-based optimistic concurrency also catches native edits without
        // coupling every SwiftUI binding to an extra revision increment.
        let content = draft + "\u{0}" + mode.rawValue + "\u{0}" + selectedText
            + "\u{0}\(automaticContextEnabled)\u{0}\(includeCourseContext)\u{0}\(includeEntirePDF)"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let attachments = (try? encoder.encode(draftAttachments)) ?? Data()
        let revision = StudyDocumentEditing.revision(Data(content.utf8) + (draftImage ?? Data()) + attachments)
        return StudyDraftOwner(
            courseID: course?.id, documentID: document?.id, threadID: thread?.id,
            assignmentID: assignment?.id, page: currentPage, revision: revision)
    }
    func validateDraftOwner(_ expected: StudyDraftOwner?) throws {
        guard let expected, expected == draftOwner else {
            throw StudyError.message(
                "The reading or draft changed in another window. Your browser draft is retained. Return to its original reading or copy it before loading the current draft."
            )
        }
    }
}
