import CryptoKit
import Foundation

struct CanvasFeedbackAttachment: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var byteCount: Int?
    var contentType: String?
    var materialID: String { "files:\(id)" }

    init?(record: [String: Any]) {
        guard let number = CanvasAssignmentDetails.number(record["id"]), number > 0,
            number.rounded() == number, number < Double(Int.max) else { return nil }
        id = String(Int(number))
        let label = record["display_name"] as? String ?? record["filename"] as? String ?? "Feedback attachment"
        name = URL(fileURLWithPath: label).lastPathComponent
        byteCount = record["size"] as? Int
        contentType = record["content-type"] as? String ?? record["content_type"] as? String
        // Fetch a fresh download address through Canvas when opened. Signed URLs are never saved here.
    }
}

struct CanvasFeedbackComment: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var author: String
    var text: String
    var createdAt: String?
    var attempt: Int?
    var currentAttempt: Bool
    var attachments: [CanvasFeedbackAttachment]
    var mediaType: String?
}

struct CanvasRubricFeedback: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var description: String?
    var rating: String?
    var comment: String?
    var score: Double?
    var possible: Double?

    var scoreLabel: String? {
        guard let score else { return nil }
        func format(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }
        return format(score) + (possible.map { " / \(format($0))" } ?? " points")
    }
}

struct CanvasAssignmentFeedback: Codable, Equatable, Sendable {
    var comments: [CanvasFeedbackComment]
    var rubric: [CanvasRubricFeedback]
    var hasCurrentFeedback: Bool { comments.contains(where: \.currentAttempt) || !rubric.isEmpty }
    var isEmpty: Bool { comments.isEmpty && rubric.isEmpty }
    var attachments: [CanvasFeedbackAttachment] {
        var seen = Set<String>()
        return comments.flatMap(\.attachments).filter { seen.insert($0.id).inserted }
    }

    init?(record: [String: Any], submission: [String: Any], gradeVisible: Bool) {
        guard submission.keys.contains("submission_comments") || submission.keys.contains("rubric_assessment")
            || submission["assignment_visible"] as? Bool == false else { return nil }
        comments = []; rubric = []
        guard submission["assignment_visible"] as? Bool != false else { return }
        let student = submission["user_id"] as? Int
        let attempt = submission["attempt"] as? Int
        let submittedAt = CanvasAssignmentDetails.date(submission["submitted_at"] as? String)
        var seen = Set<String>()
        for item in submission["submission_comments"] as? [[String: Any]] ?? [] {
            guard let author = item["author_id"] as? Int, let student, author != student,
                item["hidden"] as? Bool != true, item["draft"] as? Bool != true else { continue }
            let text = (item["comment"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var attachmentIDs = Set<String>()
            let attachments = (item["attachments"] as? [[String: Any]] ?? [])
                .compactMap(CanvasFeedbackAttachment.init).filter { attachmentIDs.insert($0.id).inserted }
            let media = item["media_comment"] as? [String: Any]
            guard !text.isEmpty || !attachments.isEmpty || media != nil else { continue }
            let createdAt = item["created_at"] as? String
            let commentAttempt = item["attempt"] as? Int
            let earlier = (commentAttempt != nil && attempt != nil && commentAttempt != attempt)
                || (CanvasAssignmentDetails.date(createdAt).map { date in submittedAt.map { date < $0 } ?? false } ?? false)
            let fallback = "\(author):\(createdAt ?? ""):\(text):\(attachments.map(\.id).joined(separator: ","))"
            let id = (item["id"] as? Int).map(String.init)
                ?? SHA256.hash(data: Data(fallback.utf8)).map { String(format: "%02x", $0) }.joined()
            guard seen.insert(id).inserted else { continue }
            let authorName = (item["author_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            comments.append(CanvasFeedbackComment(id: id, author: authorName?.isEmpty == false ? authorName! : "Reviewer",
                text: text, createdAt: createdAt, attempt: commentAttempt, currentAttempt: !earlier,
                attachments: attachments, mediaType: media.map { $0["media_type"] as? String ?? "media" }))
        }
        comments.sort {
            if $0.currentAttempt != $1.currentAttempt { return $0.currentAttempt }
            let lhs = CanvasAssignmentDetails.date($0.createdAt) ?? .distantPast
            let rhs = CanvasAssignmentDetails.date($1.createdAt) ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        guard gradeVisible, submission["grade_matches_current_submission"] as? Bool != false,
            let assessment = submission["rubric_assessment"] as? [String: [String: Any]] else { return }
        let criteria = record["rubric"] as? [[String: Any]] ?? []
        let orderedIDs = criteria.compactMap { $0["id"] as? String }
        for id in orderedIDs + assessment.keys.filter({ !orderedIDs.contains($0) }).sorted() {
            guard let item = assessment[id] else { continue }
            let criterion = criteria.first { $0["id"] as? String == id } ?? [:]
            let ratings = criterion["ratings"] as? [[String: Any]] ?? []
            let rating = ratings.first { $0["id"] as? String == item["rating_id"] as? String }
            rubric.append(CanvasRubricFeedback(id: id, title: criterion["description"] as? String ?? "Criterion",
                description: criterion["long_description"] as? String, rating: rating?["description"] as? String,
                comment: item["comments"] as? String, score: CanvasAssignmentDetails.number(item["points"]),
                possible: CanvasAssignmentDetails.number(criterion["points"])))
        }
    }
}
