import Foundation
import Darwin
@testable import ScholiaMac

/// Uses only the explicitly downloaded verification fixtures, not user documents
/// or saved settings. Run through smoke-macos-paper-live.sh after codex login.
@main
enum PaperLiveVerification {
    struct Record: Codable {
        var name: String
        var model: String
        var seconds: Double
        var images: Int
        var imageBytes: Int
        var passed: Bool
        var expectation: String
        var response: PaperTutorResponse?
        var error: String?
    }

    @MainActor
    static func main() async {
        do { try await verify() }
        catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(EXIT_FAILURE)
        }
    }

    @MainActor
    static func verify() async throws {
        let environment = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: environment["PAPER_LIVE_OUTPUT"] ?? "output/paper-study")
        let model = environment["PAPER_LIVE_MODEL"] ?? "gpt-6-astra"
        let onlyCase = environment["PAPER_LIVE_CASE"]
        let reportName = "live-\(model)" + (onlyCase.map { "-\($0)" } ?? "") + ".json"
        let endpoint = environment["PAPER_LIVE_ENDPOINT"] ?? "http://127.0.0.1:8796/v1/chat/completions"
        let config = ProviderConfiguration(provider: ProviderCatalog.provider(id: "codex"), model: model,
            endpoint: endpoint, apiKey: environment["PAPER_LIVE_TOKEN"] ?? "", language: .english,
            reasoningEffort: "low", fastClaudeMode: false, tutoringPurpose: .paperStudy)
        let provider = ProviderClient()
        if onlyCase == "routing" {
            try await verifyRouting(output: output, configuration: config, provider: provider)
            return
        }
        if onlyCase == "continuous" {
            try await verifyContinuous(output: output, configuration: config, provider: provider)
            return
        }
        var records: [Record] = []
        var turns: [PaperTurn] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        func image(_ name: String, page: Int = 1, revision: Int) throws -> PaperEvidence {
            PaperEvidence(page: page, revision: revision, jpeg: try Data(contentsOf: output.appendingPathComponent(name + ".jpg")))
        }
        func save() throws {
            try encoder.encode(records).write(to: output.appendingPathComponent(reportName), options: .atomic)
        }
        func run(_ name: String, problem: String, evidence: [PaperEvidence],
            history: [PaperTurn] = [], corrections: [String] = [], question: String = "", proactive: Bool = true,
            helpLevel: Int = 0, historicalTarget: Bool = false, expectation: String,
            check: (PaperTutorResponse) -> Bool) async throws -> PaperTutorResponse? {
            if let onlyCase, name != onlyCase, !name.hasPrefix(onlyCase + "-") { return nil }
            let messages = PaperTutor.messages(problem: problem, corrections: corrections, evidence: evidence,
                turns: history, request: question, proactive: proactive, helpLevel: helpLevel,
                historicalTarget: historicalTarget)
            let images = messages.compactMap(\.imageData)
            let started = Date()
            do {
                let completion = try await provider.complete(capture: nil, messages: messages,
                    configuration: config, onToken: { _ in })
                try completion.text.write(to: output.appendingPathComponent("\(model)-\(name)-raw.json"), atomically: true, encoding: .utf8)
                let response = try PaperTutor.parse(completion.text)
                let record = Record(name: name, model: model, seconds: Date().timeIntervalSince(started),
                    images: images.count, imageBytes: images.map(\.count).reduce(0, +),
                    passed: check(response), expectation: expectation, response: response)
                records.append(record)
                try save()
                print("\(record.passed ? "PASS" : "REVIEW") \(name): \(String(format: "%.2f", record.seconds)) s; \(response.status.rawValue); \(response.feedback)")
                return response
            } catch {
                records.append(Record(name: name, model: model, seconds: Date().timeIntervalSince(started),
                    images: images.count, imageBytes: images.map(\.count).reduce(0, +), passed: false,
                    expectation: expectation, error: error.localizedDescription))
                try save()
                print("FAIL \(name): \(error.localizedDescription)")
                return nil
            }
        }

        let problem = "Find the inverse FUNCTION of f(x) = x² for x >= 0. I am working on paper."
        var mistaken = try image("inverse-mistake", revision: 1)
        let first = try await run("new-mistake", problem: problem, evidence: [mistaken],
            expectation: "Identify inverse-function/reciprocal confusion with one short hint, tied to the handwritten expression; no complete solution.") {
                $0.status == .mistake && $0.shouldInterveneProactively
                    && $0.feedback.count < 350 && !$0.feedback.contains("sqrt") && !$0.feedback.contains("√")
            }
        if let first {
            mistaken.transcription = first.transcription
            turns.append(PaperTurn(role: .assistant, text: first.feedback, evidenceID: mistaken.id))
        }
        let followup = "Why isn't taking the reciprocal the same as undoing this function? Give one conceptual hint."
        _ = try await run("contextual-followup", problem: problem, evidence: [mistaken], history: turns,
            question: followup, proactive: false, helpLevel: 1,
            expectation: "Explain inverse versus reciprocal using the retained handwritten step; avoid a full solution.") {
                !$0.feedback.isEmpty && $0.feedback.count < 1300
            }
        turns.append(PaperTurn(role: .user, text: followup, evidenceID: mistaken.id))
        var corrected = try image("inverse-correct", revision: 2)
        let correctedResult = try await run("revised-correct-work", problem: problem, evidence: [mistaken, corrected], history: turns,
            corrections: ["I replaced the reciprocal with the square-root inverse and changed the input variable to y."],
            expectation: "Accept the correction and changed variable; no repeated proactive feedback.") {
                $0.status == .ok && $0.feedback.isEmpty && !$0.shouldInterveneProactively
            }
        if let correctedResult { corrected.transcription = correctedResult.transcription }
        _ = try await run("historical-step-followup", problem: problem, evidence: [mistaken],
            history: [PaperTurn(role: .user,
                text: "I have since corrected the current page to the square-root inverse. This question is specifically about my earlier reciprocal attempt.",
                evidenceID: corrected.id)],
            question: "Why was my earlier reciprocal step not the inverse function? Give one conceptual hint about the selected earlier capture.",
            proactive: false, helpLevel: 0, historicalTarget: true,
            expectation: "Discuss the selected earlier reciprocal attempt even though the live page was corrected; do not claim the mistake is still present or reveal the whole solution.") {
                let text = $0.feedback.lowercased()
                return !$0.feedback.isEmpty && $0.feedback.count < 700
                    && (text.contains("reciprocal") || text.contains("undo") || text.contains("reverse"))
                    && !$0.feedback.contains("\\sqrt") && !$0.feedback.contains("√")
            }
        _ = try await run("crossed-out-revision", problem: problem,
            evidence: [mistaken, try image("inverse-crossed-out", revision: 3)], history: turns,
            expectation: "Ignore the crossed-out reciprocal assertion and assess the active square-root inverse below it without repeating an error.") {
                [.ok, .incomplete].contains($0.status) && $0.feedback.isEmpty
            }
        let initialProblemPage = try image("inverse-problem-page", revision: 1)
        let nextPageWork = try image("inverse-correct", page: 2, revision: 2)
        let confirmed = try await run("confirmed-next-page", problem: "", evidence: [initialProblemPage, nextPageWork],
            expectation: "Recover the problem only from the initial-page image, accept current square-root work on confirmed page2, and do not flag old reciprocal work or ask to confirm the page again.") {
                $0.status == .ok && $0.feedback.isEmpty && !$0.shouldInterveneProactively
            }
        let confirmedHistory = confirmed.map { [PaperTurn(role: .assistant, text: $0.feedback,
            evidenceID: nextPageWork.id)] } ?? []
        _ = try await run("confirmed-next-page-followup", problem: "", evidence: [initialProblemPage, nextPageWork],
            history: confirmedHistory, question: "Why is the positive square-root branch appropriate in my latest line?",
            proactive: false, helpLevel: 1,
            expectation: "Use the domain in the historical image-only problem to explain the current positive-root branch; no stale reciprocal correction or repeated page-change request.") {
                let text = $0.feedback.lowercased()
                return $0.status == .ok && !text.isEmpty && (text.contains("domain")
                    || text.contains("nonnegative") || text.contains("non-negative") || text.contains("\\ge") || text.contains("≥"))
            }
        let polynomial = try image("polynomial-valid", revision: 1)
        _ = try await run("valid-alternative-order", problem: "Expand f(y) = (y + 1)² + 1.", evidence: [polynomial],
            question: "I put the constant first. Is that order of terms valid?", proactive: false,
            expectation: "Accept 2 + 2y + y² as equivalent; do not insist on descending powers.") {
                $0.status == .ok && !$0.feedback.isEmpty
            }
        _ = try await run("incomplete-writing", problem: problem,
            evidence: [try image("inverse-incomplete", revision: 1)],
            expectation: "Unfinished partial strokes are not a mathematical error; stay quiet.") {
                [.incomplete, .unclear, .obstructed].contains($0.status) && $0.feedback.isEmpty
            }
        _ = try await run("obscured-writing", problem: problem,
            evidence: [try image("inverse-obscured", revision: 1)],
            expectation: "Mask covering the writing is obstruction/uncertainty, never an error; stay quiet.") {
                [.obstructed, .unclear, .incomplete].contains($0.status) && $0.feedback.isEmpty
            }
        _ = try await run("unclear-notation", problem: problem,
            evidence: [try image("inverse-unclear", revision: 1)],
            question: "Can you check this step? The photo is hard to read.", proactive: false,
            expectation: "Request clarification instead of confidently correcting illegible notation.") {
                [.unclear, .obstructed].contains($0.status) && !$0.feedback.isEmpty && !$0.shouldInterveneProactively
            }
        _ = try await run("page-change", problem: problem,
            evidence: [mistaken, corrected, try image("polynomial-valid", page: 2, revision: 3)],
            expectation: "Recognize a different problem/page and avoid combining it with the inverse problem.") {
                [.pageChange, .unclear].contains($0.status) && $0.feedback.isEmpty
            }
        let explicit = "Please now give the complete worked solution, including the inverse and its domain."
        _ = try await run("explicit-solution", problem: problem, evidence: [mistaken, corrected], history: turns,
            question: explicit, proactive: false, helpLevel: 2,
            expectation: "An explicit complete-solution request is answered, with the square-root inverse and domain.") {
                !$0.feedback.isEmpty && ($0.feedback.contains("sqrt") || $0.feedback.contains("√") || $0.feedback.lowercased().contains("square root"))
            }
        let passed = records.filter(\.passed).count
        print("Live verification: \(passed)/\(records.count) automated expectations. Inspect saved responses for qualitative tutoring quality.")
        print("Provider transport does not expose per-call token usage or cost; no monetary estimate is asserted.")
        if passed != records.count || records.isEmpty { throw NSError(domain: "PaperLiveVerification", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Some live expectations require review; see output/paper-study/\(reportName). Check PAPER_LIVE_CASE if no cases ran."]) }
    }

    /// Real handwriting/model transport with a controlled clock and motion fingerprints.
    /// This checks the session's before/after flow, not optical motion detection.
    @MainActor
    private static func verifyContinuous(output: URL, configuration: ProviderConfiguration,
        provider: ProviderClient) async throws {
        final class Clock { var date = Date() }
        final class Trace { var stages: [[String: String]] = [] }
        let clock = Clock(), trace = Trace()
        let choices = ProviderCatalog.provider(id: "codex").models.filter {
            ["gpt-6-luna", "gpt-6-astra"].contains($0.id)
        }
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date },
            prepareExecution: { mode, request, level in
                let plan = PaperTutorRouting.plan(mode: mode, providerID: "codex",
                    selectedModel: "gpt-6-astra", reasoningEffort: "low", availableModels: choices,
                    request: request, helpLevel: level)
                return PaperTutorExecution(plan: plan) { messages, route in
                    var routed = configuration
                    routed.model = route.modelID
                    routed.reasoningEffort = route.reasoningEffort
                    let started = Date()
                    let completion = try await provider.complete(capture: nil, messages: messages,
                        configuration: routed, onToken: { _ in })
                    let response = try? PaperTutor.parse(completion.text)
                    trace.stages.append(["model": route.modelID,
                        "status": response?.status.rawValue ?? "invalid",
                        "seconds": String(format: "%.2f", Date().timeIntervalSince(started)),
                        "images": String(messages.compactMap(\.imageData).count)])
                    try completion.text.write(to: output.appendingPathComponent("continuous-\(trace.stages.count)-raw.json"),
                        atomically: true, encoding: .utf8)
                    return completion.text
                }
            }, complete: { _ in throw StudyError.message("The session router must handle this request.") })
        defer { session.shutdown() }
        session.problemStatement = "Find the inverse FUNCTION of f(x) = x² for x >= 0."
        session.modelMode = .automatic
        session.mode = .proactive
        session.setAnalysisPaused(false)
        var report: [[String: String]] = []
        var fingerprint = Array(repeating: UInt8(220), count: 49_152)
        let cases = ["inverse-incomplete", "inverse-mistake", "inverse-correct"]
        for (index, name) in cases.enumerated() {
            if index > 0 {
                // A localized new stroke, not a fabricated broad page transition.
                for y in (30 + index * 35)..<(40 + index * 35) {
                    for x in 80..<92 { fingerprint[y * 256 + x] = 25 }
                }
            }
            let jpeg = try Data(contentsOf: output.appendingPathComponent(name + ".jpg"))
            let requestsBefore = session.requestsSent
            let assistantBefore = session.turns.filter { $0.role == .assistant }.count
            let started = Date()
            for _ in 0..<12 where session.requestsSent == requestsBefore {
                session.observe(PaperFrame(id: UUID(), capturedAt: clock.date, jpeg: jpeg,
                    width: 1200, height: 500, fingerprint: fingerprint,
                    qualityIssue: nil, handDetected: false))
                clock.date = clock.date.addingTimeInterval(0.5)
                await Task.yield()
            }
            if index == 0 {
                // Continue writing before the first real model call finishes.
                // Its eventual result may become BEFORE context, never a cue
                // about the newer live view. Only the latest frame is retained.
                let newer = try Data(contentsOf: output.appendingPathComponent("inverse-mistake.jpg"))
                for y in 65..<75 { for x in 80..<92 { fingerprint[y * 256 + x] = 25 } }
                for _ in 0..<3 {
                    clock.date = clock.date.addingTimeInterval(0.5)
                    session.observe(PaperFrame(id: UUID(), capturedAt: clock.date, jpeg: newer,
                        width: 1200, height: 500, fingerprint: fingerprint,
                        qualityIssue: nil, handDetected: false))
                }
                guard session.requestInFlight, session.requestsSent == 1 else {
                    throw StudyError.message("New writing cancelled or duplicated the background check.")
                }
            }
            while session.requestInFlight, Date().timeIntervalSince(started) < 130 {
                try await Task.sleep(for: .milliseconds(100))
            }
            let assistantAfter = session.turns.filter { $0.role == .assistant }.count
            let passed = session.error == nil && session.requestsSent == requestsBefore + 1
                && (index == 1 ? session.currentFeedback?.status == .mistake && assistantAfter == assistantBefore + 1
                    : session.currentFeedback?.shouldInterveneProactively != true && assistantAfter == assistantBefore)
            report.append(["step": name, "passed": String(passed),
                "seconds": String(format: "%.2f", Date().timeIntervalSince(started)),
                "logicalChecks": String(session.requestsSent), "modelCalls": String(session.modelCallsSent),
                "feedback": session.currentFeedback?.feedback ?? "", "error": session.error ?? ""])
            let data = try JSONSerialization.data(withJSONObject: ["steps": report, "stages": trace.stages],
                options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("live-continuous.json"), options: .atomic)
            print("\(passed ? "PASS" : "FAIL") continuous \(name): \(session.requestsSent) checks; \(session.modelCallsSent) model calls; \(session.currentFeedback?.status.rawValue ?? "quiet")")
            guard passed else { throw StudyError.message("Continuous live expectation failed; inspect live-continuous.json.") }
            clock.date = clock.date.addingTimeInterval(5)
        }
        let requestsBefore = session.requestsSent
        let jpeg = try Data(contentsOf: output.appendingPathComponent("inverse-correct.jpg"))
        for _ in 0..<70 {
            session.observe(PaperFrame(id: UUID(), capturedAt: clock.date, jpeg: jpeg,
                width: 1200, height: 500, fingerprint: fingerprint, qualityIssue: nil, handDetected: false))
            clock.date = clock.date.addingTimeInterval(0.5)
        }
        guard session.requestsSent == requestsBefore else { throw StudyError.message("Unchanged work caused another model request.") }
        print("PASS: writing continued during a real check; unfinished → new mistake → correction; revised work checked inside the hint interval; unchanged work stayed quiet.")
    }

    @MainActor
    private static func verifyRouting(output: URL, configuration: ProviderConfiguration,
        provider: ProviderClient) async throws {
        final class Clock { var date = Date() }
        final class Trace { var stages: [[String: String]] = [] }
        var report: [[String: String]] = []
        let choices = ProviderCatalog.provider(id: "codex").models.filter {
            ["gpt-6-luna", "gpt-6-astra"].contains($0.id)
        }
        guard choices.count == 2 else { throw StudyError.message("The routing test needs both known vision model definitions.") }
        for mode in [PaperModelMode.automatic, .fast, .thorough] {
            let clock = Clock(), trace = Trace()
            let session = PaperStudySession(camera: PaperCamera(), now: { clock.date },
                prepareExecution: { selectedMode, request, level in
                    let plan = PaperTutorRouting.plan(mode: selectedMode, providerID: "codex",
                        selectedModel: "gpt-6-astra", reasoningEffort: "low", availableModels: choices,
                        request: request, helpLevel: level)
                    return PaperTutorExecution(plan: plan) { messages, route in
                        var routed = configuration
                        routed.model = route.modelID
                        routed.reasoningEffort = route.reasoningEffort
                        let started = Date()
                        let completion = try await provider.complete(capture: nil, messages: messages,
                            configuration: routed, onToken: { _ in })
                        let response = try? PaperTutor.parse(completion.text)
                        trace.stages.append(["model": route.modelID, "status": response?.status.rawValue ?? "invalid",
                            "seconds": String(format: "%.2f", Date().timeIntervalSince(started))])
                        try completion.text.write(to: output.appendingPathComponent("routing-\(mode.rawValue)-\(trace.stages.count)-raw.json"),
                            atomically: true, encoding: .utf8)
                        return completion.text
                    }
                }, complete: { _ in throw StudyError.message("The configured router must handle this request.") })
            session.modelMode = mode
            session.problemStatement = "Find the inverse FUNCTION of f(x) = x² for x >= 0."
            session.mode = .proactive
            session.setAnalysisPaused(false)
            let jpeg = try Data(contentsOf: output.appendingPathComponent("inverse-mistake.jpg"))
            // Freeze a known clear human-handwriting fixture; physical camera
            // behavior is verified separately. Exercise the real session router.
            for _ in 0..<5 {
                session.observe(PaperFrame(id: UUID(), capturedAt: clock.date, jpeg: jpeg,
                    width: 1200, height: 500, fingerprint: Array(repeating: 220, count: 49_152),
                    qualityIssue: nil, handDetected: false))
                clock.date = clock.date.addingTimeInterval(0.5)
            }
            let started = Date()
            while session.requestInFlight, Date().timeIntervalSince(started) < 130 {
                try await Task.sleep(for: .milliseconds(100))
            }
            let expectedModels = mode == .automatic ? ["gpt-6-luna", "gpt-6-astra"]
                : [mode == .fast ? "gpt-6-luna" : "gpt-6-astra"]
            let models = trace.stages.compactMap { $0["model"] }
            let passed = session.error == nil && models == expectedModels
                && session.modelCallsSent == expectedModels.count
                && (mode == .fast || (session.currentFeedback?.status == .mistake
                    && session.turns.filter { $0.role == .assistant }.count == 1))
            report.append(["mode": mode.rawValue, "passed": String(passed),
                "models": models.joined(separator: " → "), "seconds": String(format: "%.2f", Date().timeIntervalSince(started)),
                "escalations": String(session.escalationCount), "status": session.currentFeedback?.status.rawValue ?? "none",
                "feedback": session.turns.last?.text ?? "", "error": session.error ?? "",
                "stages": String(data: try JSONSerialization.data(withJSONObject: trace.stages), encoding: .utf8) ?? ""])
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent("live-routing.json"), options: .atomic)
            print("\(passed ? "PASS" : "FAIL") routing \(mode.label): \(models.joined(separator: " → ")); \(session.routingStatus)")
            session.shutdown()
            if !passed { throw StudyError.message("Live routing expectation failed; inspect live-routing.json.") }
        }
        print("PASS: 3 live session-routing modes; Automatic independently verified the suspected/misread error before showing one cue.")
    }
}
