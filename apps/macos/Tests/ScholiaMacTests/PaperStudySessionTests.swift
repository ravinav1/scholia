import XCTest
@testable import ScholiaMac

@MainActor
final class PaperStudySessionTests: XCTestCase {
    @MainActor final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(_ seconds: Double = 0.5) { date = date.addingTimeInterval(seconds) }
    }
    @MainActor final class Deferred {
        var continuations: [CheckedContinuation<String, Error>] = []
        var requests: [[ConversationMessage]] = []
        var models: [String] = []
        func routed(_ messages: [ConversationMessage], _ route: PaperTutorModelRoute) async throws -> String {
            models.append(route.modelID)
            return try await call(messages)
        }
        func call(_ messages: [ConversationMessage]) async throws -> String {
            requests.append(messages)
            // Deliberately ignores cancellation: generation guards must work even
            // with an uncooperative transport that finishes an old request.
            return try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        func resolve(_ text: String) { continuations.removeFirst().resume(returning: text) }
        func reject() { continuations.removeFirst().resume(throwing: URLError(.cannotConnectToHost)) }
    }
    static let mistake = #"{"status":"mistake","transcription":"2x + 3 = 7; 2x = 10","feedback":"What happens to the 3 when you subtract it from both sides?","focus":"2x = 10","confidence":0.95,"issueKey":"subtract-constant"}"#
    static let unfinished = #"{"status":"incomplete","transcription":"2x + 3 = 7; 2x =","feedback":"","focus":"2x =","confidence":0.95,"issueKey":""}"#
    static let automaticPlan = PaperTutorRoutingPlan(
        initial: PaperTutorModelRoute(modelID: "fast", reasoningEffort: "low"),
        verification: PaperTutorModelRoute(modelID: "strong", reasoningEffort: "low"), reason: "Automatic test route")

    func frame(_ clock: Clock, value: UInt8 = 220, issue: String? = nil, hand: Bool = false) -> PaperFrame {
        PaperFrame(id: UUID(), capturedAt: clock.date, jpeg: Data([1, 2, value]), width: 1200, height: 900,
            fingerprint: Array(repeating: value, count: 6912), qualityIssue: issue, handDetected: hand)
    }
    func settle(_ session: PaperStudySession, _ clock: Clock, value: UInt8 = 220) {
        for _ in 0..<5 { session.observe(frame(clock, value: value)); clock.advance() }
    }
    func yieldUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        XCTFail("Timed out waiting for an async state transition")
    }

    func testOnRequestObservesWithoutSendingAndUsesContextForFollowup() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        XCTAssertEqual(session.mode, .proactive)
        XCTAssertEqual(session.samplingInterval, 5)
        XCTAssertEqual(session.notificationInterval, 30)
        XCTAssertTrue(session.isAnalysisPaused, "Camera connection does not authorize automatic uploads")
        session.mode = .onRequest
        session.problemStatement = "Solve 2x + 3 = 7"
        session.setAnalysisPaused(false)
        settle(session, clock)
        XCTAssertEqual(session.evidence.count, 1)
        XCTAssertEqual(session.requestsSent, 0)
        session.captureNow()
        await yieldUntil { transport.requests.count == 1 }
        XCTAssertTrue(transport.requests[0].contains { $0.imageData != nil })
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.turns.last?.role, .assistant)
        XCTAssertTrue(session.isCurrent(session.turns.last?.evidenceID))
        session.sendQuestion("Why subtract from both sides?")
        await yieldUntil { transport.requests.count == 2 }
        let prompt = transport.requests[1].map(\.content).joined(separator: "\n")
        XCTAssertTrue(prompt.contains("Solve 2x + 3 = 7"))
        XCTAssertTrue(prompt.contains("What happens to the 3"))
        XCTAssertTrue(prompt.contains("Why subtract from both sides?"))
        transport.resolve(Self.unfinished)
        await yieldUntil { !session.requestInFlight }
        session.shutdown()
    }

    func testProactiveRevisionKeepsCheckedHistoryWithoutPresentingStaleFeedback() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.setAnalysisPaused(false)
        settle(session, clock)
        await yieldUntil { transport.requests.count == 1 }
        session.observe(frame(clock, value: 170))
        XCTAssertTrue(session.requestInFlight)
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        XCTAssertFalse(session.turns.contains { $0.role == .assistant })
        XCTAssertNil(session.currentFeedback)
        XCTAssertFalse(session.isCurrent(session.turns.first?.evidenceID))
        XCTAssertEqual(session.evidence.first?.transcription, "2x + 3 = 7; 2x = 10")
        session.shutdown()
    }

    func testManualReadableSnapshotSurvivesMotionAndRepliesOnlyAboutEarlierWork() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        // A single readable frame is sufficient for an explicit question, even
        // when the live camera never settles to pixel-perfect stillness.
        session.observe(frame(clock))
        session.requestHelp(level: 1)
        await yieldUntil { transport.requests.count == 1 }
        XCTAssertTrue(transport.requests[0].last!.content.contains("Requested help level: 0"))
        let target = session.turns.last?.evidenceID
        clock.advance()
        session.observe(frame(clock, value: 170, hand: true))
        XCTAssertTrue(session.requestInFlight)
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.turns.last?.role, .assistant)
        XCTAssertEqual(session.turns.last?.evidenceID, target)
        XCTAssertFalse(session.isCurrent(target))
        XCTAssertNil(session.currentFeedback)
        XCTAssertFalse(session.pageChangeSuggested)
        XCTAssertNil(session.retryableQuestion)
        session.shutdown()
    }

    func testManualCancellationPreservesQuestionUntilExplicitRetry() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.observe(frame(clock))
        let question = "Why can I subtract 3 from each side?"
        session.sendQuestion(question)
        await yieldUntil { transport.requests.count == 1 }
        let oldTarget = session.turns.last?.evidenceID
        session.setAnalysisPaused(true)
        XCTAssertEqual(session.retryableQuestion, question)
        XCTAssertFalse(session.requestInFlight)
        transport.resolve(Self.mistake)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(session.turns.contains { $0.role == .assistant })
        XCTAssertEqual(session.requestsSent, 1, "Cancellation never automatically resends a question")
        clock.advance()
        session.observe(frame(clock, value: 190))
        session.selectEvidence(oldTarget)
        session.retryRequest()
        await yieldUntil { transport.requests.count == 2 }
        XCTAssertNil(session.selectedEvidenceID)
        XCTAssertNil(session.retryableQuestion)
        XCTAssertNotEqual(session.turns.last?.evidenceID, oldTarget)
        XCTAssertTrue(transport.requests[1].last!.content.contains(question))
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.turns.last?.role, .assistant)
        session.shutdown()
    }

    func testPinnedHistoricalDiscussionUsesOnlySelectedAndEarlierImages() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.observe(frame(clock))
        session.captureNow()
        await yieldUntil { transport.requests.count == 1 }
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        let first = session.evidence[0]
        clock.advance()
        session.observe(frame(clock, value: 190))
        session.captureNow()
        await yieldUntil { transport.requests.count == 2 }
        transport.resolve(Self.unfinished)
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.evidence.count, 2)
        session.selectEvidence(first.id)
        clock.advance()
        session.observe(frame(clock, value: 90, issue: "Blurred", hand: true))
        session.sendQuestion("Explain the subtraction in that earlier hint.")
        await yieldUntil { transport.requests.count == 3 }
        let images = transport.requests[2].filter { $0.imageData != nil }
        XCTAssertEqual(images.map(\.imageData), [Optional(first.jpeg)])
        XCTAssertTrue(images.last!.content.contains("HISTORICAL DISCUSSION TARGET"))
        XCTAssertFalse(images.last!.content.contains("CURRENT visual evidence"))
        session.startNewPage()
        session.camera.onInterruption?()
        XCTAssertTrue(session.requestInFlight, "Explicit historical discussion survives live camera/page changes")
        let pageChange = Self.unfinished.replacingOccurrences(of: "incomplete", with: "pageChange")
            .replacingOccurrences(of: "\"feedback\":\"\"", with: "\"feedback\":\"This is the selected earlier step.\"")
        transport.resolve(pageChange)
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.turns.last?.evidenceID, first.id)
        XCTAssertEqual(session.turns.last?.role, .assistant)
        XCTAssertNil(session.currentFeedback)
        XCTAssertFalse(session.pageChangeSuggested, "A historical answer cannot redirect the live page")
        XCTAssertEqual(session.selectedEvidenceID, first.id)
        session.shutdown()
    }

    func testNewPageRequiresNewEvidenceUnlessEarlierCaptureIsExplicitlySelected() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.observe(frame(clock)); session.captureNow()
        await yieldUntil { transport.requests.count == 1 }
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        let first = session.evidence[0]
        session.startNewPage()
        session.sendQuestion("Check this new page")
        XCTAssertEqual(session.requestsSent, 1)
        XCTAssertNotNil(session.error)
        session.selectEvidence(first.id)
        session.sendQuestion("What did the earlier hint mean?")
        await yieldUntil { transport.requests.count == 2 }
        session.submitCorrection("That earlier symbol is a 7")
        XCTAssertFalse(session.requestInFlight)
        XCTAssertEqual(session.turns.last?.evidenceID, first.id)
        XCTAssertEqual(session.retryableQuestion, "What did the earlier hint mean?")
        transport.resolve(Self.mistake)
        for _ in 0..<20 { await Task.yield() }
        session.retryRequest()
        XCTAssertNil(session.selectedEvidenceID)
        XCTAssertEqual(session.requestsSent, 2, "Retry targets the current page and cannot silently reuse page 1")
        session.dismissRetry()
        XCTAssertNil(session.retryableQuestion)
        session.shutdown()
    }

    func testAutomaticVerifiesBeforeShowingFeedbackUsingTheSameOriginalEvidence() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, prepareExecution: { _, _, _ in
            PaperTutorExecution(plan: Self.automaticPlan) { try await transport.routed($0, $1) }
        }, complete: { try await transport.call($0) })
        session.observe(frame(clock)); session.captureNow()
        await yieldUntil { transport.requests.count == 1 }
        transport.resolve(Self.mistake)
        await yieldUntil { transport.requests.count == 2 }
        XCTAssertFalse(session.turns.contains { $0.role == .assistant }, "A fast model's correction is never shown before review")
        XCTAssertEqual(transport.models, ["fast", "strong"])
        XCTAssertEqual(session.requestsSent, 1)
        XCTAssertEqual(session.modelCallsSent, 2)
        XCTAssertEqual(session.escalationCount, 1)
        XCTAssertTrue(session.routingStatus.contains("Verifying a possible mistake"))
        XCTAssertEqual(transport.requests[0].map(\.content), transport.requests[1].map(\.content))
        XCTAssertEqual(transport.requests[0].compactMap(\.imageData), transport.requests[1].compactMap(\.imageData))
        transport.resolve(Self.unfinished)
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.currentFeedback?.status, .incomplete)
        XCTAssertFalse(session.turns.contains { $0.role == .assistant })
        XCTAssertTrue(session.routingStatus.contains("Stronger review complete"))
        session.shutdown()
        XCTAssertEqual(session.modelCallsSent, 0)
        XCTAssertEqual(session.escalationCount, 0)
    }

    func testAutomaticCancellationBeforeOrDuringVerificationCannotShowStaleFeedback() async {
        for stage in [1, 2] {
            let clock = Clock(), transport = Deferred()
            let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, prepareExecution: { _, _, _ in
                PaperTutorExecution(plan: Self.automaticPlan) { try await transport.routed($0, $1) }
            }, complete: { try await transport.call($0) })
            session.setAnalysisPaused(false); settle(session, clock)
            await yieldUntil { transport.requests.count == 1 }
            if stage == 2 {
                transport.resolve(Self.unfinished)
                await yieldUntil { transport.requests.count == 2 }
            }
            session.submitCorrection("Use the revised problem context")
            XCTAssertFalse(session.requestInFlight)
            transport.resolve(Self.mistake)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(transport.requests.count, stage, "Cancelled first stage never launches a second model")
            XCTAssertFalse(session.turns.contains { $0.role == .assistant })
            XCTAssertNil(session.currentFeedback)
            session.shutdown()
        }
    }

    func testCancellationBeforeTaskStartsDoesNotSendAnImage() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, prepareExecution: { _, _, _ in
            PaperTutorExecution(plan: Self.automaticPlan) { try await transport.routed($0, $1) }
        }, complete: { try await transport.call($0) })
        session.observe(frame(clock)); session.captureNow()
        session.cancelRequest()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(session.modelCallsSent, 0)
        XCTAssertNotNil(session.retryableQuestion)
        session.shutdown()
    }

    func testExplicitQuestionPreemptsBackgroundObservationButNotAnotherQuestion() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.setAnalysisPaused(false); settle(session, clock)
        await yieldUntil { transport.requests.count == 1 }
        XCTAssertTrue(session.canAskQuestion)
        session.sendQuestion("Why should I subtract on both sides?")
        await yieldUntil { transport.requests.count == 2 }
        XCTAssertFalse(session.canAskQuestion)
        XCTAssertTrue(transport.requests[1].last!.content.contains("Why should I subtract on both sides?"))
        transport.resolve(Self.mistake)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(session.requestInFlight, "A cancelled background result cannot finish the student's newer request")
        XCTAssertFalse(session.turns.contains { $0.role == .assistant })
        session.sendQuestion("A second explicit question")
        XCTAssertEqual(session.requestsSent, 2)
        XCTAssertNotNil(session.error)
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        XCTAssertTrue(session.canAskQuestion)
        XCTAssertEqual(session.turns.filter { $0.role == .assistant }.count, 1)
        session.shutdown()
    }

    func testAutomaticMalformedFastOutputGetsOneReviewAndReviewFailurePreservesRetry() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, prepareExecution: { _, _, _ in
            PaperTutorExecution(plan: Self.automaticPlan) { try await transport.routed($0, $1) }
        }, complete: { try await transport.call($0) })
        session.observe(frame(clock)); session.sendQuestion("What does this symbol mean?")
        await yieldUntil { transport.requests.count == 1 }
        transport.resolve("Not valid JSON")
        await yieldUntil { transport.requests.count == 2 }
        transport.reject()
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.modelCallsSent, 2)
        XCTAssertEqual(session.retryableQuestion, "What does this symbol mean?")
        XCTAssertNotNil(session.error)
        XCTAssertTrue(session.isAnalysisPaused)
        XCTAssertFalse(session.turns.contains { $0.role == .assistant })
        session.shutdown()
    }

    func testTinyInkChangeAccumulatesAgainstReferenceNotAdjacentFrames() {
        let base = Array(repeating: UInt8(240), count: 6912)
        var revised = base
        // A small stroke can cover under 1% of the notebook crop.
        for i in 0..<50 { revised[i] = 80 }
        XCTAssertTrue(PaperFrameComparison.changed(base, revised))
        var sensorNoise = base
        for i in sensorNoise.indices { sensorNoise[i] -= UInt8(i % 2) }
        XCTAssertFalse(PaperFrameComparison.changed(base, sensorNoise))
    }

    func testBlurHandAndUnstableFramesNeverSend() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.mode = .proactive; session.setAnalysisPaused(false)
        for i in 0..<20 {
            session.observe(frame(clock, value: UInt8(100 + i * 3), issue: "Image is blurred"))
            clock.advance(1)
        }
        XCTAssertEqual(session.requestsSent, 0)
        settle(session, clock)
        await yieldUntil { transport.requests.count == 1 }
        session.observe(frame(clock, hand: true))
        XCTAssertTrue(session.requestInFlight)
        transport.resolve(Self.mistake)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(session.turns.contains { $0.role == .assistant })
        session.captureNow()
        XCTAssertNotNil(session.error)
        XCTAssertEqual(session.requestsSent, 1)
        session.shutdown()
    }

    func testAutomaticRecoversAfterTemporaryObstructionWithoutRequiringAnInkChange() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.setAnalysisPaused(false); settle(session, clock)
        await yieldUntil { transport.requests.count == 1 }
        session.observe(frame(clock, hand: true))
        XCTAssertTrue(session.requestInFlight)
        transport.resolve(Self.mistake)
        for _ in 0..<20 { await Task.yield() }
        settle(session, clock)
        XCTAssertEqual(session.requestsSent, 1, "A temporary obstruction does not bypass the minimum check interval")
        clock.advance(120)
        settle(session, clock)
        await yieldUntil { transport.requests.count == 2 }
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.turns.filter { $0.role == .assistant }.count, 1)
        XCTAssertTrue(session.isCurrent(session.turns.last?.evidenceID))
        session.shutdown()
    }

    func testAutomaticCompletionRejectsAStalledStreamBeforeInterruptionCallback() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.setAnalysisPaused(false); settle(session, clock)
        await yieldUntil { transport.requests.count == 1 }
        // Simulate no new frames while the camera interruption watchdog has
        // not yet fired. Generation and pixels have not changed.
        clock.advance(4)
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        XCTAssertNil(session.currentFeedback)
        XCTAssertFalse(session.turns.contains { $0.role == .assistant })
        clock.advance(120)
        settle(session, clock)
        await yieldUntil { transport.requests.count == 2 }
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.turns.filter { $0.role == .assistant }.count, 1,
            "A discarded stalled-stream result neither marks unchanged work checked nor suppresses its future issue")
        session.shutdown()
    }

    func testSwitchingFromLocalObservationToAutoChecksPreviouslyRetainedWork() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.mode = .onRequest; session.setAnalysisPaused(false); settle(session, clock)
        XCTAssertEqual(session.evidence.count, 1)
        XCTAssertEqual(session.requestsSent, 0)
        session.mode = .proactive
        settle(session, clock)
        await yieldUntil { transport.requests.count == 1 }
        transport.resolve(Self.unfinished)
        await yieldUntil { !session.requestInFlight }
        session.shutdown()
    }

    func testModelAndContextChangesAllowRecheckingUnchangedInkAfterCooldown() async {
        for change in ["model", "problem", "correction"] {
            let clock = Clock(), transport = Deferred()
            let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
            session.setAnalysisPaused(false); settle(session, clock)
            await yieldUntil { transport.requests.count == 1 }
            transport.resolve(Self.unfinished)
            await yieldUntil { !session.requestInFlight }
            switch change {
            case "model": session.modelMode = .thorough
            case "problem": session.problemStatement = "Solve over the complex numbers"
            default: session.submitCorrection("That symbol is a parameter, not x")
            }
            settle(session, clock)
            XCTAssertEqual(session.requestsSent, 1, "Context changes retain the minimum check interval: \(change)")
            clock.advance(120); settle(session, clock)
            await yieldUntil { transport.requests.count == 2 }
            transport.resolve(Self.unfinished)
            await yieldUntil { !session.requestInFlight }
            session.shutdown()
        }
    }

    func testExplicitCancelDoesNotAutomaticallyResendUnchangedWork() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.setAnalysisPaused(false); settle(session, clock)
        await yieldUntil { transport.requests.count == 1 }
        session.cancelRequest()
        transport.resolve(Self.mistake)
        for _ in 0..<20 { await Task.yield() }
        clock.advance(120); settle(session, clock)
        XCTAssertEqual(session.requestsSent, 1)
        XCTAssertFalse(session.turns.contains { $0.role == .assistant })
        session.shutdown()
    }

    func testContinuousChecksReadChangesBeforeTheNextCueAndUseTheLastAcceptedBaseline() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.setAnalysisPaused(false); settle(session, clock)
        await yieldUntil { transport.requests.count == 1 }
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        let accepted = session.evidence[0]
        clock.advance(5); settle(session, clock, value: 190)
        await yieldUntil { transport.requests.count == 2 }
        XCTAssertLessThan(clock.date.timeIntervalSince(accepted.capturedAt), session.notificationInterval)
        let images = transport.requests[1].filter { $0.imageData != nil }
        XCTAssertTrue(images.first!.content.contains("BEFORE; last successfully checked state"))
        XCTAssertTrue(images.first!.content.contains(accepted.id.uuidString))
        XCTAssertTrue(transport.requests[1].last!.content.contains("meaningful additions, revisions and erasures"))
        // Keep reading this snapshot while a newer unchecked view arrives.
        session.observe(frame(clock, value: 160))
        XCTAssertTrue(session.requestInFlight)
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        let checkedWhileWriting = session.evidence.last!
        clock.advance(5); settle(session, clock, value: 140)
        await yieldUntil { transport.requests.count == 3 }
        let comparison = transport.requests[2].filter { $0.imageData != nil }
        XCTAssertEqual(comparison.count, 3)
        XCTAssertEqual(comparison.first?.imageData, accepted.jpeg)
        XCTAssertTrue(comparison[1].content.contains(checkedWhileWriting.id.uuidString))
        XCTAssertEqual(comparison[1].imageData, Data([1, 2, 190]))
        XCTAssertFalse(comparison.contains { $0.imageData == Data([1, 2, 160]) })
        transport.resolve(Self.unfinished)
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.turns.filter { $0.role == .assistant }.count, 1)
        session.shutdown()
    }

    func testSustainedWritingKeepsOneRequestAndComparesOnlyTheLatestFrameNext() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.setAnalysisPaused(false); settle(session, clock)
        await yieldUntil { transport.requests.count == 1 }
        let first = session.evidence[0]
        for value: UInt8 in [190, 160, 180, 150, 170, 140] {
            clock.advance(3)
            session.observe(frame(clock, value: value, hand: value == 180))
            XCTAssertTrue(session.requestInFlight)
            XCTAssertEqual(session.requestsSent, 1)
            XCTAssertEqual(session.evidence.count, 1, "There is no frame queue behind the active snapshot")
        }
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        XCTAssertFalse(session.turns.contains { $0.role == .assistant })
        XCTAssertNil(session.currentFeedback)
        XCTAssertFalse(session.pageChangeSuggested)
        XCTAssertEqual(session.evidence.first?.transcription, "2x + 3 = 7; 2x = 10")
        settle(session, clock, value: 140)
        await yieldUntil { transport.requests.count == 2 }
        let images = transport.requests[1].filter { $0.imageData != nil }
        XCTAssertEqual(images.compactMap(\.imageData), [first.jpeg, Data([1, 2, 140])])
        XCTAssertTrue(images[0].content.contains("BEFORE; last successfully checked state"))
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.turns.filter { $0.role == .assistant }.count, 1,
            "The hidden historical error did not suppress a later current cue for the same issue")
        XCTAssertTrue(session.isCurrent(session.turns.last?.evidenceID))
        session.shutdown()
    }

    func testStrongerReviewContinuesDuringMotionButHistoricalErrorNeverBecomesACue() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, prepareExecution: { _, _, _ in
            PaperTutorExecution(plan: Self.automaticPlan) { try await transport.routed($0, $1) }
        }, complete: { try await transport.call($0) })
        session.setAnalysisPaused(false); settle(session, clock)
        await yieldUntil { transport.requests.count == 1 }
        session.observe(frame(clock, value: 190))
        transport.resolve(Self.unfinished)
        await yieldUntil { transport.requests.count == 2 }
        session.observe(frame(clock, value: 160, hand: true))
        XCTAssertTrue(session.requestInFlight)
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.modelCallsSent, 2)
        XCTAssertEqual(session.requestsSent, 1)
        XCTAssertEqual(session.escalationCount, 1)
        XCTAssertFalse(session.turns.contains { $0.role == .assistant })
        XCTAssertNil(session.currentFeedback)
        XCTAssertFalse(session.pageChangeSuggested)
        XCTAssertEqual(session.evidence.first?.transcription, "2x + 3 = 7; 2x = 10")
        session.shutdown()
    }

    func testObstructedModelResultDoesNotPollAnUnchangedUnreadableCapture() async {
        for coveredAtCompletion in [false, true] {
            let clock = Clock(), transport = Deferred()
            let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
            session.setAnalysisPaused(false); settle(session, clock)
            await yieldUntil { transport.requests.count == 1 }
            if coveredAtCompletion { session.observe(frame(clock, hand: true)) }
            transport.resolve(Self.unfinished.replacingOccurrences(of: "incomplete", with: "obstructed"))
            await yieldUntil { !session.requestInFlight }
            clock.advance(120); settle(session, clock)
            XCTAssertEqual(session.requestsSent, 1, "The same unreadable pixels are not repeatedly sent")
            XCTAssertFalse(session.turns.contains { $0.role == .assistant })
            session.captureNow()
            await yieldUntil { transport.requests.count == 2 }
            transport.resolve(Self.unfinished)
            await yieldUntil { !session.requestInFlight }
            session.shutdown()
        }
    }

    func testWarrantedCueWaitsForItsIntervalWithoutRepeatingInference() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.setAnalysisPaused(false); settle(session, clock)
        await yieldUntil { transport.requests.count == 1 }
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        clock.advance(5); settle(session, clock, value: 190)
        await yieldUntil { transport.requests.count == 2 }
        let next = Self.mistake.replacingOccurrences(of: "subtract-constant", with: "divide-coefficient")
            .replacingOccurrences(of: "2x = 10", with: "x = 10")
        transport.resolve(next)
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.turns.filter { $0.role == .assistant }.count, 1)
        XCTAssertTrue(session.analysisStatus.contains("waiting for the hint interval"))
        clock.advance(30); settle(session, clock, value: 190)
        XCTAssertEqual(session.turns.filter { $0.role == .assistant }.count, 2)
        XCTAssertTrue(session.isCurrent(session.turns.last?.evidenceID))
        XCTAssertEqual(session.requestsSent, 2, "A pending cue does not require polling the model again")
        clock.advance(120); settle(session, clock, value: 190)
        XCTAssertEqual(session.turns.filter { $0.role == .assistant }.count, 2)
        XCTAssertEqual(session.requestsSent, 2)
        session.shutdown()
    }

    func testPendingCueIsDiscardedAfterRevisionPauseOrGeometryChange() async {
        for change in ["revision", "pause", "geometry"] {
            let clock = Clock(), transport = Deferred()
            let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
            session.setAnalysisPaused(false); settle(session, clock)
            await yieldUntil { transport.requests.count == 1 }
            transport.resolve(Self.mistake)
            await yieldUntil { !session.requestInFlight }
            clock.advance(5); settle(session, clock, value: 190)
            await yieldUntil { transport.requests.count == 2 }
            transport.resolve(Self.mistake.replacingOccurrences(of: "subtract-constant", with: "another-issue")
                .replacingOccurrences(of: "2x = 10", with: "x = 10"))
            await yieldUntil { !session.requestInFlight }
            if change == "revision" { session.observe(frame(clock, value: 160)) }
            else if change == "pause" { session.setAnalysisPaused(true) }
            else { session.camera.onSourceGeometryChange?() }
            clock.advance(30); settle(session, clock, value: change == "revision" ? 160 : 190)
            if change == "revision" {
                await yieldUntil { transport.requests.count == 3 }
                transport.resolve(Self.unfinished)
                await yieldUntil { !session.requestInFlight }
            }
            XCTAssertEqual(session.turns.filter { $0.role == .assistant }.count, 1,
                "An earlier pending cue cannot appear after \(change)")
            session.shutdown()
        }
    }

    func testGeometryChangeCancelsRequestAndRequiresExplicitResume() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.observe(frame(clock)); session.captureNow()
        await yieldUntil { transport.requests.count == 1 }
        session.camera.onSourceGeometryChange?()
        XCTAssertFalse(session.requestInFlight)
        XCTAssertTrue(session.isAnalysisPaused)
        XCTAssertNil(session.latestFrame)
        XCTAssertNotNil(session.retryableQuestion)
        transport.resolve(Self.mistake)
        for _ in 0..<20 { await Task.yield() }
        clock.advance(30); settle(session, clock)
        XCTAssertEqual(session.requestsSent, 1)
        XCTAssertFalse(session.turns.contains { $0.role == .assistant })
        session.shutdown()
    }

    func testProactiveCooldownUnchangedSuppressionAndIssueDeduplication() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.mode = .proactive; session.setAnalysisPaused(false)
        settle(session, clock)
        await yieldUntil { transport.requests.count == 1 }
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.turns.filter { $0.role == .assistant }.count, 1)
        clock.advance(120)
        settle(session, clock)
        XCTAssertEqual(session.requestsSent, 1, "Unchanged work cannot trigger recurring inference")
        settle(session, clock, value: 190)
        await yieldUntil { transport.requests.count == 2 }
        transport.resolve(Self.mistake.replacingOccurrences(of: "2x = 10", with: "2x = 10 on the next line"))
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.turns.filter { $0.role == .assistant }.count, 1, "Same issue key is not repeated even if focus text changes")
        settle(session, clock, value: 170)
        XCTAssertEqual(session.requestsSent, 2, "The minimum check interval applies even after a changed frame")
        session.shutdown()
    }

    func testPauseStopCropPageCorrectionAndClearInvalidateRequests() async {
        for action in ["pause", "stop", "crop", "page", "correction", "clear", "close"] {
            let clock = Clock(), transport = Deferred()
            let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
            settle(session, clock); session.captureNow()
            await yieldUntil { transport.requests.count == 1 }
            switch action {
            case "pause": session.setAnalysisPaused(true)
            case "stop": session.stopCamera()
            case "crop": session.setRegion(CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.7))
            case "page": session.startNewPage()
            case "correction": session.submitCorrection("That symbol is a 7, not a 1")
            case "clear": session.clearSession()
            default: session.shutdown()
            }
            transport.resolve(Self.mistake)
            for _ in 0..<20 { await Task.yield() }
            XCTAssertFalse(session.turns.contains { $0.role == .assistant }, action)
            XCTAssertFalse(session.requestInFlight, action)
            if ["clear", "close"].contains(action) {
                XCTAssertTrue(session.evidence.isEmpty); XCTAssertTrue(session.turns.isEmpty)
                XCTAssertNil(session.latestFrame)
                XCTAssertNil(session.retryableQuestion)
            } else {
                XCTAssertNotNil(session.retryableQuestion, "Explicit cancelled questions stay available for deliberate retry: \(action)")
            }
            session.shutdown()
        }
    }

    func testRequestedFeedbackAlsoSuppressesRepeatedProactiveIssue() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        settle(session, clock); session.captureNow()
        await yieldUntil { transport.requests.count == 1 }
        transport.resolve(Self.mistake)
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.turns.last?.focus, "2x = 10")
        session.mode = .proactive; session.setAnalysisPaused(false)
        clock.advance(120); settle(session, clock, value: 190)
        await yieldUntil { transport.requests.count == 2 }
        XCTAssertTrue(transport.requests[1].contains { $0.content.contains("subtract-constant") })
        transport.resolve(Self.mistake.replacingOccurrences(of: "subtract-constant", with: " SUBTRACT_CONSTANT "))
        await yieldUntil { !session.requestInFlight }
        XCTAssertEqual(session.turns.filter { $0.role == .assistant }.count, 1)
        session.shutdown()
    }

    func testIncompleteWorkStaysQuietAndPageChangeNeedsConfirmation() async {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.mode = .proactive; session.setAnalysisPaused(false)
        settle(session, clock)
        await yieldUntil { transport.requests.count == 1 }
        transport.resolve(Self.unfinished)
        await yieldUntil { !session.requestInFlight }
        XCTAssertTrue(session.turns.isEmpty)
        clock.advance(120)
        settle(session, clock, value: 90)
        XCTAssertTrue(session.pageChangeSuggested)
        XCTAssertEqual(session.requestsSent, 1)
        session.startNewPage()
        settle(session, clock, value: 90)
        await yieldUntil { transport.requests.count == 2 }
        let imageMessages = transport.requests[1].filter { $0.imageData != nil }
        XCTAssertEqual(imageMessages.count, 2, "The initial image-only problem survives a new page")
        XCTAssertTrue(imageMessages[0].content.contains("INITIAL PROBLEM REFERENCE; use problem statement only"))
        XCTAssertTrue(imageMessages[1].content.contains("CURRENT visual evidence"))
        transport.resolve(Self.unfinished)
        await yieldUntil { !session.requestInFlight }
        session.shutdown()
    }

    func testErrorAndMalformedOutputPauseWithoutRetryAndCanRecover() async {
        for invalidOutput in [false, true] {
            let clock = Clock(), transport = Deferred()
            let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
            session.mode = .proactive; session.setAnalysisPaused(false)
            settle(session, clock)
            await yieldUntil { transport.requests.count == 1 }
            if invalidOutput { transport.resolve("Here is a solution without JSON") } else { transport.reject() }
            await yieldUntil { !session.requestInFlight }
            XCTAssertNotNil(session.error)
            XCTAssertTrue(session.isAnalysisPaused)
            clock.advance(120); settle(session, clock, value: 190)
            XCTAssertEqual(session.requestsSent, 1)
            session.captureNow()
            await yieldUntil { transport.requests.count == 2 }
            transport.resolve(Self.mistake)
            await yieldUntil { !session.requestInFlight }
            XCTAssertNil(session.error)
            session.shutdown()
        }
    }

    func testTimeoutReleasesPendingStateAndLateResponseIsIgnored() async throws {
        let clock = Clock(), transport = Deferred()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }, complete: { try await transport.call($0) })
        session.requestTimeout = 0.02
        settle(session, clock); session.captureNow()
        await yieldUntil { transport.requests.count == 1 }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(session.requestInFlight)
        XCTAssertTrue(session.isAnalysisPaused)
        XCTAssertTrue(session.error?.contains("too long") == true)
        transport.resolve(Self.mistake)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(session.turns.contains { $0.role == .assistant })
        session.shutdown()
    }
}
