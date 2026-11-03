import CryptoKit
import Foundation

struct StudyCourseCompletionStore: Sendable {
    var load: @Sendable (Bool) async throws -> Data?
    var save: @Sendable (Data?) async throws -> Void

    static func keychain(root: URL) -> Self {
        // Separate local libraries must never pick up one another's statuses.
        // No course code, identity, institution, URL or grade in Keychain metadata.
        let account = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return Self(load: { interactive in
            try await ProviderKeychain.courseCompletionData(account: account, allowInteraction: interactive)
        }, save: { data in
            _ = try await ProviderKeychain.courseCompletionData(account: account, replacement: data,
                writing: true, allowInteraction: true)
        })
    }
}

enum StudyCourseCompletionRules {
    static func status(for code: String, in rows: [StudyCourseCompletion]) -> Bool? {
        // Strip ONLY the library's known semester suffix. Never match titles,
        // substrings or similar-looking courses.
        let code = code.uppercased().replacingOccurrences(of: #"-(?:\d{2}[HV])(?:-\d{2}[HV])*$"#,
            with: "", options: .regularExpression)
        guard StudentwebResults.validCode(code) else { return nil }
        return rows.first { $0.courseCode == code }?.passed
    }

    static func filtering(_ recommendation: StudyExamRecommendation, completions: [StudyCourseCompletion],
        exams: [StudyExam]) -> StudyExamRecommendation {
        guard recommendation.advice == nil else { return recommendation }
        var result = recommendation
        let completed = Set(exams.filter { status(for: $0.courseCode, in: completions) == true }.map(\.courseKey))
        let removed = result.choices.filter { completed.contains($0.courseKey) }
        result.choices.removeAll { completed.contains($0.courseKey) }
        result.excluded += removed.map {
            var choice = $0
            choice.reason = "Already passed · checked on this Mac. Select it manually if you intend to retake it."
            return choice
        }
        let removedIDs = Set(exams.filter { completed.contains($0.courseKey) }.map(\.id))
        result.selectedExamIDs.removeAll { removedIDs.contains($0) }
        return result
    }
}

extension StudyWorkspaceModel {
    func coursePassed(_ code: String) -> Bool? {
        StudyCourseCompletionRules.status(for: code, in: courseCompletions)
    }

    func loadCourseCompletions(allowInteraction: Bool = false) async {
        guard !courseCompletionsBusy, !courseCompletionsLoaded || allowInteraction else { return }
        courseCompletionsBusy = true
        defer { courseCompletionsBusy = false }
        do {
            if let data = try await completionStore.load(allowInteraction) {
                guard data.count <= StudentwebResults.maximumBytes, let text = String(data: data, encoding: .utf8) else {
                    throw StudentwebResults.invalid
                }
                courseCompletions = try StudentwebResults.parse(text)
            } else { courseCompletions = [] }
            courseCompletionsLoaded = true
            courseCompletionsError = nil
        } catch {
            courseCompletions = []
            courseCompletionsError = "Local pass statuses could not be opened. Open Studentweb results settings to retry Keychain access."
        }
    }

    func replaceCourseCompletions(_ rows: [StudyCourseCompletion]) async throws {
        guard !courseCompletionsBusy else { throw StudyError.message("Wait for the local pass-status operation to finish.") }
        courseCompletionsBusy = true
        defer { courseCompletionsBusy = false }
        // Validate even native callers. Only code + Bool are encodable here.
        let data = try JSONEncoder().encode(rows)
        let checked = try StudentwebResults.parse(String(decoding: data, as: UTF8.self))
        do {
            try await completionStore.save(checked.isEmpty ? nil : try JSONEncoder().encode(checked))
        } catch {
            throw StudyError.message("Could not update local pass statuses in Keychain. Your previous saved statuses were kept.")
        }
        courseCompletions = checked
        courseCompletionsLoaded = true
        courseCompletionsError = nil
    }
}
