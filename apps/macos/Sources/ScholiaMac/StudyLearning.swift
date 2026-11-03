import Foundation
import SQLite3

// Learning history has its own transaction log. It never rewrites library.json.
// Question/rubric/source revisions are immutable; every learner action is an event.
struct LearningSource: Codable, Equatable, Sendable {
    var courseID: UUID
    var documentID: UUID
    var title: String
    var page: Int
    var contentHash: String
    var sourceVersion: String?
    var excerpt: String
    var image: Data?
}
struct LearningQuestion: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var revision = 1
    var conceptID = UUID()
    var concept: String
    var prompt: String
    var referenceAnswer: String
    var rubric: [String]
    var hints: [String]
    var requiresVisual = false
    var source: LearningSource
    var model: String
    var createdAt = Date()
    // Structural checks do not establish educational correctness.
    var validation = "Generated · not independently verified"
}
struct LearningConcept: Sendable {
    var id: UUID
    var courseID: UUID
    var description: String
    var questionIDs: [UUID]
    var prerequisites: [UUID] = []
}
struct LearningAssessment: Codable, Equatable, Sendable {
    var verdict: String  // correct, partial, incorrect, uncertain
    var correct: String
    var issue: String
    var nextStep: String
    var origin: String = "model"
    var model: String = ""
}
struct LearningAttempt: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var questionID: UUID
    var questionRevision: Int
    var sessionID: UUID
    var answer: String
    var confidence: Int?
    var createdAt: Date
    var hintCount: Int
    var revealed: Bool
    var openBook: Bool
    var previousAttemptID: UUID?
    var assessment: LearningAssessment?
    var dispute: String?
    var sourceStale: Bool = false
    var selfAssessment: String?
    var independent: Bool { hintCount == 0 && !revealed && !openBook && previousAttemptID == nil }
    var independentSuccess: Bool {
        independent && !sourceStale && assessment?.verdict == "correct" && assessment?.origin == "model"
            && dispute == nil
    }
}
struct LearningSession: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var courseID: UUID
    var questionIDs: [UUID]
    var position = 0
    var stage = "question"
    var hintCount = 0
    var revealed = false
    var openBook = false
    var finished = false
    var finishedAt: Date?
    var review = false
    var createdAt = Date()
    var version = 1
    var currentQuestionID: UUID? { questionIDs.indices.contains(position) ? questionIDs[position] : nil }
}
struct LearningReview: Codable, Identifiable, Equatable, Sendable {
    var id: UUID  // question ID
    var dueAt: Date
    var lastReviewedAt: Date?
    var intervalDays = 1
    var version = 1
    var schedulerVersion = 1
    var evidenceAttemptID: UUID?
    var lastSessionID: UUID?
    var reason = "Saved for a first delayed check"
}
struct LearningCommand: Codable, Equatable, Sendable {
    var id = UUID()
    var action: String
    var sessionID: UUID?
    var questionID: UUID?
    var expectedVersion: Int?
    var attemptID: UUID?
    var text: String?
    var confidence: Int?
    var days: Int?
    var openBook: Bool?
    var sourceStale: Bool?
}
struct LearningEvent: Codable, Sendable {
    var schema = 1
    var command: LearningCommand
    var date = Date()
    var questions: [LearningQuestion]?
    var session: LearningSession?
    var assessment: LearningAssessment?
}
enum LearningError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}
struct LearningState: Sendable {
    var concepts: [UUID: LearningConcept] = [:]
    var questions: [UUID: LearningQuestion] = [:]
    var sessions: [UUID: LearningSession] = [:]
    var attempts: [LearningAttempt] = []
    var reviews: [UUID: LearningReview] = [:]
    var events: [UUID: LearningCommand] = [:]
    var activeSessionID: UUID?
    var dailyLimit = 10
    var sequence = 0
    var session: LearningSession? { activeSessionID.flatMap { sessions[$0] } }
    func attempts(for session: LearningSession) -> [LearningAttempt] {
        attempts.filter { $0.sessionID == session.id && $0.questionID == session.currentQuestionID }
    }
    func due(at date: Date = Date()) -> [LearningReview] {
        let completed = sessions.values.filter {
            $0.review && $0.finished && Calendar.current.isDate($0.finishedAt ?? $0.createdAt, inSameDayAs: date)
        }.count
        return Array(
            reviews.values.filter { $0.dueAt <= date }.sorted { $0.dueAt < $1.dueAt }.prefix(
                max(0, dailyLimit - completed)))
    }
    mutating func apply(_ event: LearningEvent) throws {
        let c = event.command
        if let previous = events[c.id] {
            guard previous == c else {
                throw LearningError.invalid("This event ID already belongs to a different action.")
            }
            return
        }
        guard event.schema == 1 else { throw LearningError.invalid("Learning history needs a newer Scholia version.") }
        if c.action == "create" {
            guard let session = event.session, sessions[session.id] == nil, let questions = event.questions,
                !questions.isEmpty, questions.count <= 12, session.questionIDs == questions.map(\.id),
                Set(questions.map(\.id)).count == questions.count,
                questions.allSatisfy({ self.questions[$0.id] == nil && $0.source.courseID == session.courseID })
            else {
                throw LearningError.invalid(
                    "Invalid practice session or an attempt to overwrite an existing question revision.")
            }
            for question in questions {
                self.questions[question.id] = question
                var concept =
                    concepts[question.conceptID]
                    ?? LearningConcept(
                        id: question.conceptID, courseID: question.source.courseID, description: question.concept,
                        questionIDs: [])
                concept.questionIDs.append(question.id)
                concepts[concept.id] = concept
            }
            sessions[session.id] = session
            activeSessionID = session.id
        } else if c.action == "resume" {
            guard let id = c.sessionID, sessions[id] != nil else {
                throw LearningError.invalid("Practice session not found.")
            }
            activeSessionID = id
        } else if c.action == "revealSaved" {
            guard let id = c.sessionID, var session = sessions[id], let qid = c.questionID,
                session.finished, session.questionIDs.contains(qid), session.version == c.expectedVersion
            else { throw LearningError.invalid("Reopen the session recap to see this solution.") }
            session.version += 1
            sessions[id] = session
        } else if c.action == "limit" {
            guard let limit = c.days, (1...30).contains(limit) else {
                throw LearningError.invalid("Choose a daily limit between 1 and 30.")
            }
            dailyLimit = limit
        } else if c.action == "renameConcept" {
            guard let qid = c.questionID, let q = questions[qid],
                let text = c.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 200
            else { throw LearningError.invalid("Enter a concept description of up to 200 characters.") }
            concepts[q.conceptID]?.description = text
        } else if c.action == "review" {
            guard let id = c.questionID, let question = questions[id], reviews[id] != nil else {
                throw LearningError.invalid("Review question not found.")
            }
            let existing = sessions.values.first { $0.review && !$0.finished && $0.currentQuestionID == id }
            guard existing != nil || due(at: event.date).contains(where: { $0.id == id }) else {
                throw LearningError.invalid(
                    "This question is not due or today's workload limit has been reached. You can change the limit or return later."
                )
            }
            let session =
                existing
                ?? LearningSession(
                    id: c.id, courseID: question.source.courseID, questionIDs: [id], openBook: false, review: true,
                    createdAt: event.date)
            sessions[session.id] = session
            activeSessionID = session.id
        } else if ["saveReview", "snooze", "removeReview"].contains(c.action) {
            guard let id = c.questionID, questions[id] != nil else {
                throw LearningError.invalid("Question not found.")
            }
            if c.action == "saveReview" {
                if reviews[id] == nil {
                    reviews[id] = LearningReview(id: id, dueAt: event.date.addingTimeInterval(86_400))
                }
            } else {
                guard var review = reviews[id], review.version == c.expectedVersion else {
                    throw LearningError.invalid("The review schedule changed. Refresh and try again.")
                }
                if c.action == "removeReview" {
                    reviews.removeValue(forKey: id)
                } else {
                    guard let days = c.days, (1...30).contains(days) else {
                        throw LearningError.invalid("Choose 1–30 days to snooze.")
                    }
                    review.dueAt = event.date.addingTimeInterval(Double(days) * 86_400)
                    review.version += 1
                    review.reason = "Snoozed by you for \(days) day(s)"
                    reviews[id] = review
                }
            }
        } else if ["assess", "dispute", "selfAssess"].contains(c.action) {
            guard let id = c.sessionID, var session = sessions[id], let qid = c.questionID,
                let index = attempts.firstIndex(where: {
                    $0.id == c.attemptID && $0.sessionID == id && $0.questionID == qid
                })
            else { throw LearningError.invalid("Attempt not found.") }
            if c.action != "assess", session.version != c.expectedVersion {
                throw LearningError.invalid("Feedback changed in another window. Refresh before continuing.")
            }
            if c.action == "assess" {
                guard let assessment = event.assessment,
                    ["correct", "partial", "incorrect", "uncertain"].contains(assessment.verdict)
                else { throw LearningError.invalid("Invalid assessment.") }
                if attempts[index].assessment == nil { attempts[index].assessment = assessment }
                if !session.finished && session.currentQuestionID == qid
                    && attempts(for: session).last?.id == c.attemptID
                {
                    session.stage = "feedback"
                }
            } else if c.action == "dispute" {
                guard attempts[index].assessment != nil else { throw LearningError.invalid("Choose feedback to flag.") }
                attempts[index].dispute = String(
                    (c.text?.isEmpty == false ? c.text! : "Assessment unresolved").prefix(4_000))
                if var review = reviews[qid], review.evidenceAttemptID == c.attemptID {
                    review.reason = "Feedback disputed; schedule unchanged"
                    review.version += 1
                    reviews[qid] = review
                }
            } else {
                let revealed = events.values.contains {
                    $0.action == "reveal" && $0.sessionID == id && $0.questionID == qid
                }
                guard revealed, let verdict = c.text,
                    ["correct", "partial", "incorrect", "uncertain"].contains(verdict)
                else {
                    throw LearningError.invalid(
                        "Reveal the reference solution after an attempt to record your self-check.")
                }
                attempts[index].selfAssessment = verdict
            }
            session.version += 1
            sessions[id] = session
        } else {
            guard let id = c.sessionID, var session = sessions[id], !session.finished,
                session.currentQuestionID == c.questionID, let qid = c.questionID, let question = questions[qid]
            else {
                throw LearningError.invalid(
                    "This question is no longer active. Your answer is retained in this window; reopen the session to continue."
                )
            }
            if session.version != c.expectedVersion {
                throw LearningError.invalid(
                    "Practice changed in another window. Refresh before continuing; your draft is retained.")
            }
            let previous = attempts(for: session).last
            switch c.action {
            case "attempt":
                guard ["question", "revision"].contains(session.stage),
                    let text = c.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                    text.count <= 20_000,
                    c.confidence == nil || (1...5).contains(c.confidence!)
                else {
                    throw LearningError.invalid(
                        "Enter an answer of up to 20,000 characters and optional confidence from 1 to 5.")
                }
                attempts.append(
                    LearningAttempt(
                        id: c.id, questionID: qid, questionRevision: question.revision, sessionID: id,
                        answer: text, confidence: c.confidence, createdAt: event.date, hintCount: session.hintCount,
                        revealed: session.revealed, openBook: session.openBook, previousAttemptID: previous?.id,
                        sourceStale: c.sourceStale ?? false))
                session.stage = "attempt"
            case "hint":
                guard session.hintCount < question.hints.count else {
                    throw LearningError.invalid("All hints are already visible.")
                }
                session.hintCount += 1
            case "reveal": session.revealed = true
            case "source": session.openBook = true
            case "revise":
                guard previous != nil else { throw LearningError.invalid("Submit an attempt first.") }
                session.stage = "revision"
            case "next", "finish":
                if session.review, var review = reviews[qid], review.lastSessionID != id {
                    // One schedule transition per review session. Uncertain/disputed judgments
                    // preserve the interval; reveals/self-checks never count as independent recall.
                    let unresolved =
                        c.sourceStale == true || previous?.sourceStale == true || previous?.dispute != nil
                        || previous?.assessment?.verdict == "uncertain"
                        || previous != nil && previous?.assessment == nil
                    let success =
                        previous?.independentSuccess == true && !session.revealed && !session.openBook
                        && session.hintCount == 0 && c.sourceStale != true
                    if !unresolved { review.intervalDays = success ? min(30, max(3, review.intervalDays * 2)) : 1 }
                    review.dueAt = event.date.addingTimeInterval(Double(review.intervalDays) * 86_400)
                    review.lastReviewedAt = event.date
                    review.evidenceAttemptID = previous?.id
                    review.lastSessionID = id
                    review.version += 1
                    review.reason =
                        unresolved
                        ? "Judgment unresolved; interval unchanged"
                        : success
                            ? "Independent recall; next check in \(review.intervalDays) days"
                            : "Assisted or incomplete; a short follow-up"
                    reviews[qid] = review
                }
                if c.action == "finish" || session.position + 1 >= session.questionIDs.count {
                    session.finished = true
                    session.finishedAt = event.date
                    session.stage = "recap"
                } else {
                    session.position += 1
                    session.stage = "question"
                    session.hintCount = 0
                    session.revealed = false
                }
            default: throw LearningError.invalid("Unknown learning action.")
            }
            session.version += 1
            sessions[id] = session
        }
        events[c.id] = c
        sequence += 1
    }
}

/// SQLite supplies crash-safe append and compare-and-swap across writers. The
/// model publishes only committed state. Duplicate IDs must have identical commands.
struct LearningStore: Sendable {
    let url: URL
    init(root: URL) { url = root.appendingPathComponent("Learning/events.sqlite") }
    private func database<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        guard sqlite3_open(url.path, &pointer) == SQLITE_OK, let db = pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw LearningError.invalid("Could not open local learning history.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2_000)
        try sql(
            db,
            "CREATE TABLE IF NOT EXISTS events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, payload BLOB NOT NULL)"
        )
        return try body(db)
    }
    private func sql(_ db: OpaquePointer, _ query: String) throws {
        guard sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK else {
            throw LearningError.invalid("Could not save learning history: \(String(cString: sqlite3_errmsg(db)))")
        }
    }
    func load() throws -> LearningState {
        try database { db in
            var statement: OpaquePointer?
            guard
                sqlite3_prepare_v2(db, "SELECT payload FROM events ORDER BY sequence", -1, &statement, nil) == SQLITE_OK
            else { throw LearningError.invalid("Could not read learning history.") }
            defer { sqlite3_finalize(statement) }
            var state = LearningState()
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                guard let bytes = sqlite3_column_blob(statement, 0), sqlite3_column_bytes(statement, 0) > 0 else {
                    throw LearningError.invalid("An event is unreadable; learning history has been preserved.")
                }
                let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
                try state.apply(JSONDecoder().decode(LearningEvent.self, from: data))
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else {
                throw LearningError.invalid("Learning history is unreadable; the original has been preserved.")
            }
            return state
        }
    }
    func append(_ event: LearningEvent, sequence: Int) throws {
        try database { db in
            try sql(db, "BEGIN IMMEDIATE")
            do {
                var count: OpaquePointer?
                guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events", -1, &count, nil) == SQLITE_OK else {
                    throw LearningError.invalid("Could not check learning history.")
                }
                let row = sqlite3_step(count)
                let actual = Int(sqlite3_column_int64(count, 0))
                sqlite3_finalize(count)
                guard row == SQLITE_ROW, actual == sequence else {
                    throw LearningError.invalid(
                        "Learning history changed in another process. Reopen practice before continuing.")
                }
                var statement: OpaquePointer?
                guard
                    sqlite3_prepare_v2(db, "INSERT INTO events(id,payload) VALUES (?,?)", -1, &statement, nil)
                        == SQLITE_OK
                else { throw LearningError.invalid("Could not prepare a learning event.") }
                defer { sqlite3_finalize(statement) }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, event.command.id.uuidString, -1, transient)
                let data = try JSONEncoder().encode(event)
                _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) }
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw LearningError.invalid("Could not append this learning event.")
                }
                try sql(db, "COMMIT")
            } catch {
                try? sql(db, "ROLLBACK")
                throw error
            }
        }
    }
}
