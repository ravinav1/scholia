import Foundation
import Combine
import CoreGraphics

enum PaperHelpMode: String, CaseIterable, Identifiable {
    case onRequest, proactive
    var id: String { rawValue }
}

struct PaperHistoryItem: Identifiable {
    let id = UUID()
    let text: String
    let createdAt = Date()
}

/// Compare ink after compensating for modest exposure changes and camera drift.
/// Registration never makes a large scene change acceptable, and localized added
/// or erased strokes still count even when they occupy very little of the page.
enum PaperFrameComparison {
    static func distance(_ lhs: [UInt8], _ rhs: [UInt8]) -> (mean: Double, changed: Double) {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return (1, 1) }
        var sum = 0, changed = 0
        for (a, b) in zip(lhs, rhs) {
            let difference = abs(Int(a) - Int(b))
            sum += difference
            if difference > 20 { changed += 1 }
        }
        return (Double(sum) / Double(lhs.count * 255), Double(changed) / Double(lhs.count))
    }

    static func changed(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return true }
        if lhs == rhs { return false }
        var differences = [Int](repeating: 0, count: 511)
        for index in lhs.indices { differences[Int(lhs[index]) - Int(rhs[index]) + 255] += 1 }
        let exposure = median(differences, count: lhs.count) - 255
        // Normalize small automatic-exposure drift, not a newly covered page or
        // a substantial lighting/scene change that should be observed afresh.
        guard abs(exposure) <= 12 else { return true }
        var deviations = [Int](repeating: 0, count: 511)
        for index in lhs.indices {
            deviations[abs(Int(lhs[index]) - Int(rhs[index]) - exposure)] += 1
        }
        let noiseFloor = min(12, median(deviations, count: lhs.count) * 3)
        let corrected = lhs.indices.map { max(0, abs(Int(lhs[$0]) - Int(rhs[$0]) - exposure) - noiseFloor) }
        guard exceedsChangeThreshold(corrected) else { return false }
        let width = PaperFrameProcessor.fingerprintWidth, height = PaperFrameProcessor.fingerprintHeight
        // Opaque fingerprints without spatial dimensions can only be compared
        // photometrically; do not invent a two-dimensional shape.
        guard lhs.count == width * height else { return true }

        // Estimate only tiny global translations. Sparse scoring keeps
        // this bounded at the local 2 Hz inspection rate. Fractional edge motion
        // is handled below without blurring away an isolated new minus sign.
        func alignmentScore(dx: Int, dy: Int) -> Int {
            var sum = 0
            for y in stride(from: 2, to: height - 2, by: 4) {
                for x in stride(from: 2, to: width - 2, by: 4) {
                    sum += abs(Int(lhs[y * width + x]) - Int(rhs[(y + dy) * width + x + dx]) - exposure)
                }
            }
            return sum
        }
        var shiftX = 0, shiftY = 0, bestScore = alignmentScore(dx: 0, dy: 0)
        for dy in -2...2 {
            for dx in -2...2 {
                let score = alignmentScore(dx: dx, dy: dy)
                if score < bestScore { shiftX = dx; shiftY = dy; bestScore = score }
            }
        }
        // A thin stroke can lose contrast as it moves between sensor pixels.
        // Compare an explicitly interpolated image in either direction so that
        // this camera resampling does not look like an erased sign.
        func interpolated(_ pixels: [UInt8], x: Int, y: Int, hx: Int, hy: Int) -> Int {
            let x0 = min(width - 1, max(0, x + (hx < 0 ? -1 : 0)))
            let y0 = min(height - 1, max(0, y + (hy < 0 ? -1 : 0)))
            let x1 = min(width - 1, x0 + (hx == 0 ? 0 : 1))
            let y1 = min(height - 1, y0 + (hy == 0 ? 0 : 1))
            let fx = hx < 0 ? 4 + hx : hx, fy = hy < 0 ? 4 + hy : hy
            return ((4-fx)*(4-fy)*Int(pixels[y0*width+x0]) + fx*(4-fy)*Int(pixels[y0*width+x1])
                + (4-fx)*fy*Int(pixels[y1*width+x0]) + fx*fy*Int(pixels[y1*width+x1]) + 8) / 16
        }
        var fractionX = 0, fractionY = 0, interpolateLeft = true
        bestScore = 0
        for y in stride(from: 3, to: height - 3, by: 6) {
            for x in stride(from: 3, to: width - 3, by: 6) {
                bestScore += abs(Int(lhs[y * width + x]) - Int(rhs[(y + shiftY) * width + x + shiftX]) - exposure)
            }
        }
        for leftSide in [true, false] {
            for hy in -3...3 {
                for hx in -3...3 where hx != 0 || hy != 0 {
                    var score = 0
                    for y in stride(from: 3, to: height - 3, by: 6) {
                        for x in stride(from: 3, to: width - 3, by: 6) {
                            let l = leftSide ? interpolated(lhs, x: x, y: y, hx: hx, hy: hy) : Int(lhs[y * width + x])
                            let r = leftSide ? Int(rhs[(y + shiftY) * width + x + shiftX])
                                : interpolated(rhs, x: x + shiftX, y: y + shiftY, hx: hx, hy: hy)
                            score += abs(l - r - exposure)
                        }
                    }
                    if score < bestScore {
                        bestScore = score; fractionX = hx; fractionY = hy; interpolateLeft = leftSide
                    }
                }
            }
        }
        var leftPixels = lhs, rightPixels = rhs
        if fractionX != 0 || fractionY != 0 {
            if interpolateLeft {
                for y in 0..<height { for x in 0..<width {
                    leftPixels[y * width + x] = UInt8(interpolated(lhs, x: x, y: y, hx: fractionX, hy: fractionY))
                } }
            } else {
                for y in 0..<height { for x in 0..<width {
                    rightPixels[y * width + x] = UInt8(interpolated(rhs, x: x, y: y, hx: fractionX, hy: fractionY))
                } }
            }
        }
        var residuals: [Int] = []
        residuals.reserveCapacity(lhs.count)
        for y in max(0, -shiftY)..<min(height, height - shiftY) {
            for x in max(0, -shiftX)..<min(width, width - shiftX) {
                let rx = x + shiftX, ry = y + shiftY
                let left = Int(leftPixels[y * width + x]), right = Int(rightPixels[ry * width + rx]) + exposure
                if abs(left - right) <= noiseFloor { residuals.append(0); continue }
                var leftMin = 255, leftMax = 0, rightMin = 255, rightMax = 0
                var leftSum = 0, rightSum = 0
                for oy in -1...1 {
                    for ox in -1...1 {
                        let l = Int(leftPixels[min(height - 1, max(0, y + oy)) * width + min(width - 1, max(0, x + ox))])
                        let r = Int(rightPixels[min(height - 1, max(0, ry + oy)) * width + min(width - 1, max(0, rx + ox))])
                        leftMin = min(leftMin, l); leftMax = max(leftMax, l); leftSum += l
                        rightMin = min(rightMin, r); rightMax = max(rightMax, r); rightSum += r
                    }
                }
                // Existing stroke edges can shift or interpolate within their
                // local grayscale range. New ink in whitespace and erased ink
                // lie outside that range, in either comparison direction.
                let addedOrRemoved = max(0, leftMin - right, right - leftMax,
                                         rightMin + exposure - left, left - rightMax - exposure)
                // A one-pixel dot can spread across pixels under subpixel
                // movement. Preserve it when local ink mass is unchanged;
                // genuinely adding/removing the dot changes that mass too.
                let inkMassChange = abs(leftSum - rightSum - 9 * exposure)
                // A compact plus/exponent may touch existing ink, so novelty
                // alone is insufficient. Require net local ink beyond one
                // strong edge residual before counting that touching edit.
                let touchingInkChange = min(abs(left - right), max(0, inkMassChange - 95))
                residuals.append(max(0, max(min(addedOrRemoved, inkMassChange), touchingInkChange) - noiseFloor))
            }
        }
        return exceedsChangeThreshold(residuals)
    }

    private static func median(_ histogram: [Int], count: Int) -> Int {
        var seen = 0
        for index in histogram.indices {
            seen += histogram[index]
            if seen > count / 2 { return index }
        }
        return 0
    }

    private static func exceedsChangeThreshold(_ residuals: [Int]) -> Bool {
        guard !residuals.isEmpty else { return true }
        var sum = 0, changed = 0, strong = 0
        for residual in residuals {
            sum += residual
            if residual > 20 { changed += 1 }
            if residual >= 95 { return true }
            if residual >= 55 { strong += 1 }
            if strong >= 2 { return true }
        }
        return Double(sum) / Double(residuals.count * 255) > 0.006
            || Double(changed) / Double(residuals.count) > 0.006
    }
}

@MainActor
final class PaperStudySession: ObservableObject {
    typealias Complete = @MainActor @Sendable ([ConversationMessage]) async throws -> String
    typealias PrepareExecution = @MainActor @Sendable (PaperModelMode, String, Int) throws -> PaperTutorExecution
    let camera: PaperCamera
    @Published var problemStatement = "" {
        didSet {
            if oldValue != problemStatement {
                lastAcceptedEvidenceID = nil
                invalidate("Problem changed; the next check will use the new statement.")
            }
        }
    }
    @Published var mode: PaperHelpMode = .proactive {
        didSet {
            if oldValue != mode {
                cancelRequest()
                resetSampleMarker()
                analysisStatus = "Feedback mode changed."
            }
        }
    }
    @Published var modelMode: PaperModelMode = .automatic {
        didSet {
            if oldValue != modelMode {
                cancelRequest()
                resetSampleMarker()
                routingStatus = modelMode.detail
            }
        }
    }
    @Published private(set) var routingStatus = PaperModelMode.automatic.detail
    @Published private(set) var modelCallsSent = 0
    @Published private(set) var escalationCount = 0
    @Published var samplingInterval: Double = 5
    @Published var notificationInterval: Double = 30
    @Published private(set) var isAnalysisPaused = true
    @Published private(set) var analysisStatus = "AI paused. Connect a camera, select your page, then resume or capture."
    @Published private(set) var error: String?
    @Published private(set) var turns: [PaperTurn] = []
    @Published private(set) var evidence: [PaperEvidence] = []
    @Published private(set) var history: [PaperHistoryItem] = []
    @Published private(set) var latestFrame: PaperFrame?
    @Published private(set) var providerSummary = "Settings controls the provider; model mode controls the route"
    @Published private(set) var page = 1
    @Published private(set) var revision = 0
    @Published private(set) var pageChangeSuggested = false
    @Published private(set) var requestInFlight = false
    @Published private(set) var lastLatency: Double?
    @Published private(set) var requestsSent = 0
    @Published private(set) var currentFeedback: PaperTutorResponse?
    @Published private(set) var retryableQuestion: String?
    @Published private(set) var selectedEvidenceID: UUID?
    var latestEvidence: PaperEvidence? { evidence.last }
    var selectedEvidence: PaperEvidence? { evidence.first { $0.id == selectedEvidenceID } }
    var canAskQuestion: Bool { !requestInFlight || activeQuestion?.proactive == true }

    private struct ActiveQuestion {
        var text: String
        var helpLevel: Int
        var proactive: Bool
        var historical: Bool
    }
    private var activeQuestion: ActiveQuestion?
    private var retryableHelpLevel = 0

    private let complete: Complete
    private let prepareExecution: PrepareExecution?
    private let now: () -> Date
    private var requestTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var requestID: UUID?
    private var generation = 0
    private var referenceFingerprint: [UInt8]?
    private var previousFingerprint: [UInt8]?
    private var lastSampleFingerprint: [UInt8]?
    private var requestFingerprint: [UInt8]?
    private var stableSince: Date?
    private var lastSampleAt = Date.distantPast
    private var lastAutomaticRequest = Date.distantPast
    private var lastIntervention = Date.distantPast
    private var corrections: [String] = []
    private var deliveredIssues = Set<String>()
    private var lastAcceptedEvidenceID: UUID?
    private var pendingCue: (response: PaperTutorResponse, evidenceID: UUID)?
    private var closed = false
    private var providerLabel: (() -> String)?
    /// Override only in deterministic tests; the UI uses a two-minute deadline.
    var requestTimeout: TimeInterval = 120

    convenience init(app: AppModel) {
        self.init(camera: PaperCamera(), prepareExecution: { mode, request, helpLevel in
            var prepared = try app.studyProviderConfiguration()
            prepared.tutoringPurpose = .paperStudy
            prepared.localFileAccess = nil
            let base = prepared
            let models = app.verifiedModels(for: base.provider)
            let plan = PaperTutorRouting.plan(mode: mode, providerID: base.provider.id,
                selectedModel: base.model, reasoningEffort: base.reasoningEffort,
                availableModels: models, request: request, helpLevel: helpLevel)
            return PaperTutorExecution(plan: plan) { messages, route in
                var configuration = base
                configuration.model = route.modelID
                configuration.reasoningEffort = route.reasoningEffort
                if let definition = models.first(where: { $0.id == route.modelID }) {
                    configuration.modelSupportsImages = definition.supportsImages ?? base.provider.supportsImages
                }
                let result = try await app.completeStudy(messages: messages, configuration: configuration, onToken: { _ in })
                return result.text
            }
        }) { messages in
            var configuration = try app.studyProviderConfiguration()
            configuration.tutoringPurpose = .paperStudy
            configuration.localFileAccess = nil
            let result = try await app.completeStudy(messages: messages, configuration: configuration, onToken: { _ in })
            return result.text
        }
        providerLabel = { "\(app.activeProvider.name) · Settings controls the provider; model mode controls the route" }
        providerSummary = providerLabel!()
    }

    init(camera: PaperCamera, now: @escaping () -> Date = Date.init,
        prepareExecution: PrepareExecution? = nil, complete: @escaping Complete) {
        self.camera = camera
        self.now = now
        self.complete = complete
        self.prepareExecution = prepareExecution
        camera.onFrame = { [weak self] frame in self?.observe(frame) }
        camera.onInterruption = { [weak self] in self?.cameraInterrupted() }
        camera.onSourceGeometryChange = { [weak self] in self?.cameraGeometryChanged() }
    }

    /// Called for local 2 Hz cropped frames, never for each preview frame.
    func observe(_ frame: PaperFrame) {
        guard !closed else { return }
        latestFrame = frame
        let timestamp = now()
        if let referenceFingerprint, PaperFrameComparison.changed(referenceFingerprint, frame.fingerprint) {
            let difference = PaperFrameComparison.distance(referenceFingerprint, frame.fingerprint)
            revision += 1
            self.referenceFingerprint = frame.fingerprint
            currentFeedback = nil
            pendingCue = nil
            if difference.mean > 0.22 && difference.changed > 0.65, !evidence.isEmpty,
                frame.qualityIssue == nil, !frame.handDetected {
                pageChangeSuggested = true
            }
        } else if referenceFingerprint == nil {
            referenceFingerprint = frame.fingerprint
        }
        if requestInFlight, activeQuestion?.proactive == true, let requestFingerprint,
            frame.qualityIssue != nil || frame.handDetected || PaperFrameComparison.changed(requestFingerprint, frame.fingerprint) {
            // Keep one immutable snapshot in flight while the student writes.
            // The final freshness guard can retain its checked history without
            // presenting an old error as a current cue. No frames are queued.
            analysisStatus = "Checking the earlier captured step · watching newer writing locally"
        }
        let moving = previousFingerprint.map { PaperFrameComparison.changed($0, frame.fingerprint) } ?? true
        previousFingerprint = frame.fingerprint
        if moving || frame.qualityIssue != nil || frame.handDetected {
            stableSince = nil
            if !requestInFlight {
                analysisStatus = (isAnalysisPaused ? "AI paused · " : "")
                    + (frame.qualityIssue ?? (frame.handDetected ? "Waiting for your hand to leave the page." : "Waiting for the writing to settle…"))
            }
            return
        }
        if stableSince == nil { stableSince = timestamp }
        guard !isAnalysisPaused, !requestInFlight else { return }
        guard timestamp.timeIntervalSince(stableSince!) >= 1.5 else { return }
        guard !pageChangeSuggested else { analysisStatus = "The view changed substantially. Confirm this page before continuing."; return }
        deliverPendingCueIfReady(at: timestamp)
        let interval = min(120, max(5, samplingInterval))
        guard timestamp.timeIntervalSince(lastSampleAt) >= interval else { return }
        guard lastSampleFingerprint.map({ PaperFrameComparison.changed($0, frame.fingerprint) }) ?? true else {
            analysisStatus = "Page unchanged · no image sent"
            return
        }
        if mode == .proactive {
            // Reading new work is separate from spacing visible hints. One
            // request at a time supplies backpressure without an extra delay
            // after a slow model finishes; only the newest settled crop matters.
            guard timestamp.timeIntervalSince(lastAutomaticRequest) >= interval else {
                analysisStatus = "Watching locally · waiting for the next changed-work check"
                return
            }
            let item = retain(frame)
            submit(evidence: item, request: "Compare the latest settled working with the last checked state. Give a minimal cue only when a meaningful change warrants it.", proactive: true, helpLevel: 0)
        } else {
            _ = retain(frame)
            analysisStatus = "Step kept in memory · ask when you want help"
        }
    }

    func setRegion(_ region: CGRect) {
        camera.region = region
        lastAcceptedEvidenceID = nil
        resetObservation()
        invalidate("Notebook region changed. Check the cropped preview before asking.")
        record("Notebook region selected; future images contain only this region.")
    }

    func setAnalysisPaused(_ paused: Bool) {
        if !paused, camera.needsRegionReview {
            isAnalysisPaused = true
            analysisStatus = "Review and confirm the notebook region before restarting checks"
            return
        }
        isAnalysisPaused = paused
        if paused { cancelRequest(); pendingCue = nil }
        else {
            // Explicit resume is also a retry after a failure; do not strand an
            // unchanged frame behind the previous request's sample marker.
            lastSampleFingerprint = nil
            lastSampleAt = .distantPast
            lastAutomaticRequest = .distantPast
        }
        analysisStatus = paused ? "AI paused · camera preview stays on" : "Watching locally · waiting for a clear, steady page"
        record(paused ? "AI analysis paused." : "AI analysis resumed (\(mode == .proactive ? "proactive" : "help on request")).")
    }

    func captureNow() {
        selectEvidence(nil)
        ask("Check the current step and give one short question or minimal hint if needed.", helpLevel: 0)
    }
    func sendQuestion(_ question: String) {
        let text = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000))
        guard !text.isEmpty else { return }
        ask(text, helpLevel: 1)
    }
    func requestHelp(level: Int) {
        let request = level >= 3 ? "I explicitly request a complete worked solution to the current problem. Explain the steps."
            : level == 2 ? "Please give more explicit help on the step we were discussing, building on the previous hint."
            : "Please give me one small hint or a short question about my current step."
        ask(request, helpLevel: min(2, max(0, level - 1)))
    }
    func selectEvidence(_ id: UUID?) {
        guard id != selectedEvidenceID else { return }
        if let id, !evidence.contains(where: { $0.id == id }) {
            error = "This capture is no longer retained. Select another step or use the live page."
            return
        }
        if requestInFlight { cancelRequest() }
        selectedEvidenceID = id
        error = nil
    }
    func retryRequest() {
        guard let question = retryableQuestion else { return }
        let level = retryableHelpLevel
        selectEvidence(nil)
        ask(question, helpLevel: level)
    }
    func dismissRetry() { retryableQuestion = nil }
    func submitCorrection(_ correction: String) {
        let text = String(correction.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !text.isEmpty else { return }
        let target = selectedEvidence ?? evidence.last
        corrections.append("Page \(target?.page ?? page), revision \(target?.revision ?? revision): \(text)")
        corrections = Array(corrections.suffix(20))
        invalidate("Your correction is saved in this session. Ask again to use it.")
        turns.append(PaperTurn(role: .user, text: "Correction / intended approach: \(text)", evidenceID: target?.id))
        trimMemory()
        record("Student clarified notation or approach.")
    }

    private func ask(_ question: String, helpLevel: Int) {
        if requestInFlight {
            if activeQuestion?.proactive == true {
                // A student's direct question has priority over background
                // observation, while two explicit questions never overlap.
                cancelRequest()
            } else {
                error = "A question is pending. Cancel it before asking another question."
                return
            }
        }
        guard !closed else { return }
        let item: PaperEvidence
        let historical = selectedEvidenceID != nil
        if historical {
            guard let selected = selectedEvidence else {
                error = "This capture is no longer retained. Select another step or use the live page."
                return
            }
            item = selected
        } else if pageChangeSuggested {
            error = "Confirm New page or Same page before asking."
            return
        } else if let frame = latestFrame, now().timeIntervalSince(frame.capturedAt) < 3 {
            guard frame.qualityIssue == nil, !frame.handDetected else {
                error = frame.qualityIssue ?? "Move your hand away from the notebook, then capture again."
                return
            }
            // Explicit capture freezes one readable frame. Sensor noise and
            // ordinary handheld movement must not indefinitely block a question;
            // automatic observation still requires the settling interval.
            item = retain(frame)
        } else if let saved = evidence.last, saved.page == page {
            item = saved
        } else {
            error = "Connect a camera and hold a clear notebook region steady before asking."
            return
        }
        turns.append(PaperTurn(role: .user, text: question, evidenceID: item.id))
        trimMemory()
        submit(evidence: item, request: question, proactive: false, helpLevel: helpLevel, historical: historical)
    }

    private func retain(_ frame: PaperFrame) -> PaperEvidence {
        lastSampleAt = now()
        lastSampleFingerprint = frame.fingerprint
        if let item = evidence.last, item.page == page, item.revision == revision { return item }
        let item = PaperEvidence(page: page, revision: revision, capturedAt: frame.capturedAt, jpeg: frame.jpeg)
        evidence.append(item)
        trimMemory()
        record("Captured page \(page), step \(revision + 1) · \(frame.width) × \(frame.height)")
        return item
    }

    private func submit(evidence item: PaperEvidence, request: String, proactive: Bool, helpLevel: Int,
        historical: Bool = false) {
        let id = UUID(), ticket = generation, start = now()
        requestID = id
        requestInFlight = true
        activeQuestion = ActiveQuestion(text: request, helpLevel: helpLevel, proactive: proactive, historical: historical)
        if !proactive { retryableQuestion = nil }
        error = nil
        if let providerLabel { providerSummary = providerLabel() }
        requestsSent += 1
        if proactive { lastAutomaticRequest = start }
        requestFingerprint = historical ? nil : latestFrame?.fingerprint
        analysisStatus = "Analyzing page \(item.page), step \(item.revision + 1)… (cancel available)"
        let targetIndex = evidence.firstIndex { $0.id == item.id } ?? (evidence.count - 1)
        let eligibleEvidence = Array(evidence.prefix(targetIndex + 1))
        var visualContext = eligibleEvidence.filter { $0.page == item.page }
        if let initialProblem = evidence.first, initialProblem.page != item.page {
            // Keep an image-only problem available across confirmed notebook
            // pages. Earlier working pages are otherwise excluded.
            visualContext.insert(initialProblem, at: 0)
        }
        let messages = PaperTutor.messages(problem: problemStatement, corrections: corrections,
            evidence: visualContext, turns: turns,
            request: latestFrame == nil ? "Camera is stopped. Discuss only the retained historical evidence. \(request)" : request,
            proactive: proactive, helpLevel: helpLevel, historicalTarget: historical,
            previousEvidenceID: lastAcceptedEvidenceID, compareChanges: !historical)
        let selectedModelMode = modelMode
        requestTask = Task { [weak self, complete] in
            do {
                guard let self else { return }
                try Task.checkCancellation()
                guard self.requestID == id, self.generation == ticket, !self.closed else { return }
                let response: PaperTutorResponse
                if let execution = try self.prepareExecution?(selectedModelMode, request, helpLevel) {
                    self.routingStatus = "\(execution.plan.reason) · \(execution.plan.initial.description)"
                    self.modelCallsSent += 1
                    let raw = try await execution.complete(messages, execution.plan.initial)
                    try Task.checkCancellation()
                    guard self.requestID == id, self.generation == ticket, !self.closed else { return }
                    let first = try? PaperTutor.parse(raw)
                    let reason: String? = first == nil ? "Checking an invalid fast-model observation"
                        : first.flatMap { PaperTutorRouting.escalationReason($0, requestedHelp: !proactive) }
                    if let verification = execution.plan.verification, let reason {
                        self.routingStatus = "\(reason) · \(verification.description)"
                        self.analysisStatus = "Checking the same captured step with a stronger model…"
                        self.escalationCount += 1
                        self.modelCallsSent += 1
                        // The stronger model independently sees the same original
                        // evidence and question, not the first model's conclusion.
                        let verified = try await execution.complete(messages, verification)
                        try Task.checkCancellation()
                        guard self.requestID == id, self.generation == ticket, !self.closed else { return }
                        response = try PaperTutor.parse(verified)
                        self.routingStatus = "Stronger review complete · \(verification.description)"
                    } else {
                        response = try PaperTutor.parse(raw)
                        self.routingStatus = "Checked · \(execution.plan.initial.description) · \(execution.plan.reason)"
                    }
                } else {
                    self.modelCallsSent += 1
                    let raw = try await complete(messages)
                    response = try PaperTutor.parse(raw)
                }
                try Task.checkCancellation()
                guard self.requestID == id, self.generation == ticket, !self.closed else { return }
                self.lastLatency = self.now().timeIntervalSince(start)
                if let index = self.evidence.firstIndex(where: { $0.id == item.id }) {
                    self.evidence[index].transcription = response.transcription
                }
                let requestPixelsChanged = self.requestFingerprint.map { original in
                    self.latestFrame.map { PaperFrameComparison.changed(original, $0.fingerprint) } ?? true
                } ?? false
                if proactive, !self.isCurrent(item.id) || requestPixelsChanged {
                    // A completed earlier snapshot is useful as the comparison
                    // baseline, but it cannot create a current cue or page action.
                    // Keep only the latest live frame for the next settled check.
                    if response.status != .obstructed, response.status != .pageChange {
                        self.lastAcceptedEvidenceID = item.id
                    }
                    if response.status != .obstructed { self.lastSampleFingerprint = nil }
                    self.currentFeedback = nil
                    self.pendingCue = nil
                    self.finishRequest()
                    self.analysisStatus = "Earlier step checked · waiting for the latest clear, settled writing"
                    self.trimMemory()
                    return
                }
                self.finishRequest()
                if historical || (!proactive && !self.isCurrent(item.id)) {
                    // A selected earlier capture is a separate discussion target.
                    // Its answer never changes live-page feedback, navigation, or
                    // deduplication, even if the model describes an old mistake.
                    if !response.feedback.isEmpty {
                        self.turns.append(PaperTurn(role: .assistant, text: response.feedback,
                            evidenceID: item.id, focus: response.focus, issueKey: response.issueKey))
                        self.record("Discussed earlier page \(item.page), step \(item.revision + 1).")
                    }
                    self.analysisStatus = "Reply ready · earlier captured page \(item.page), step \(item.revision + 1)"
                    self.trimMemory()
                    return
                }
                self.currentFeedback = response
                if response.status == .pageChange {
                    self.pageChangeSuggested = true
                    self.analysisStatus = "The model noticed a possible page change. Confirm before continuing."
                    return
                }
                if response.status == .obstructed {
                    self.analysisStatus = "The model could not read this view. Clear the page and capture again."
                } else {
                    self.lastAcceptedEvidenceID = item.id
                }
                let issue = self.issueIdentity(response.issueKey, page: item.page)
                let focus = "focus:" + self.issueIdentity(response.focus, page: item.page)
                let isNewCue = response.shouldInterveneProactively
                    && !self.deliveredIssues.contains(issue)
                    && !self.deliveredIssues.contains(focus)
                let mayNotify = !proactive || (isNewCue
                    && self.now().timeIntervalSince(self.lastIntervention) >= min(300, max(20, self.notificationInterval)))
                if mayNotify, !response.feedback.isEmpty {
                    self.present(response, for: item)
                } else if proactive, isNewCue {
                    self.pendingCue = (response, item.id)
                    self.analysisStatus = "Checked changed work · a current cue is waiting for the hint interval"
                } else if response.status != .obstructed {
                    self.analysisStatus = "Checked the captured step · no interruption needed"
                }
                self.trimMemory()
            } catch {
                guard let self, self.requestID == id, self.generation == ticket, !self.closed else { return }
                self.preserveRetry()
                self.finishRequest()
                self.error = error.localizedDescription
                self.analysisStatus = "Analysis failed · no automatic retry"
                self.isAnalysisPaused = true
                self.record("Analysis stopped after an error. Resume or capture to retry.")
            }
        }
        let timeout = requestTimeout
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            guard let self, self.requestID == id else { return }
            self.cancelRequest()
            self.error = "The model took too long. No response was shown. Try again or choose a faster vision model in Settings."
            self.isAnalysisPaused = true
            self.analysisStatus = "Timed out · AI paused"
        }
    }

    func cancelRequest() {
        pendingCue = nil
        preserveRetry()
        requestTask?.cancel()
        finishRequest()
        analysisStatus = "Request cancelled · no pending response"
    }
    private func finishRequest() {
        activeQuestion = nil
        requestID = nil
        requestInFlight = false
        requestFingerprint = nil
        requestTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
    }
    private func preserveRetry() {
        guard let question = activeQuestion, !question.proactive else { return }
        retryableQuestion = question.text
        retryableHelpLevel = question.helpLevel
    }
    private func invalidate(_ reason: String, preservingHistorical: Bool = false) {
        let keepDiscussion = preservingHistorical && activeQuestion?.historical == true
        if !keepDiscussion { generation += 1 }
        revision += 1
        currentFeedback = nil
        pendingCue = nil
        // A changed problem, correction or camera context makes the prior
        // sample insufficient even when the visible ink itself is unchanged.
        resetSampleMarker()
        if !keepDiscussion { cancelRequest() }
        analysisStatus = reason
    }
    private func resetSampleMarker() {
        lastSampleFingerprint = nil
        lastSampleAt = .distantPast
    }
    private func resetObservation() {
        referenceFingerprint = nil
        previousFingerprint = nil
        lastSampleFingerprint = nil
        latestFrame = nil
        stableSince = nil
        lastSampleAt = .distantPast
    }
    private func cameraInterrupted() {
        resetObservation()
        invalidate("Camera interrupted · reconnect, then resume analysis", preservingHistorical: true)
        isAnalysisPaused = true
        record("Camera interrupted; pending response discarded.")
    }
    private func cameraGeometryChanged() {
        resetObservation()
        lastAcceptedEvidenceID = nil
        invalidate("Camera orientation or dimensions changed · review and confirm the notebook region")
        isAnalysisPaused = true
        record("Camera geometry changed; analysis paused until the notebook region is reviewed.")
    }
    func stopCamera() {
        cancelRequest()
        camera.stop()
        analysisStatus = "Camera stopped · retained captures remain available for questions"
    }
    func startNewPage() {
        page += 1
        revision = 0
        invalidate("New page · the problem and conversation remain available", preservingHistorical: true)
        resetObservation()
        pageChangeSuggested = false
        record("Started page \(page). Initial problem reference retained; earlier working pages excluded.")
    }
    func continuePage() {
        pageChangeSuggested = false
        lastSampleFingerprint = nil
        corrections.append("The student confirmed that the current view on page \(page), revision \(revision), is still the same page and problem.")
        corrections = Array(corrections.suffix(20))
        analysisStatus = "Same page confirmed · waiting for a steady view"
    }
    func isCurrent(_ evidenceID: UUID?) -> Bool {
        guard let id = evidenceID, let item = evidence.first(where: { $0.id == id }) else { return false }
        return latestFrame.map { now().timeIntervalSince($0.capturedAt) < 3
            && $0.qualityIssue == nil && !$0.handDetected } == true
            && item.page == page && item.revision == revision
    }
    func clearSession() {
        cancelRequest()
        camera.stop()
        resetObservation()
        problemStatement = ""
        generation += 1
        page = 1; revision = 0
        turns = []; evidence = []; history = []; corrections = []; deliveredIssues = []
        lastAcceptedEvidenceID = nil; pendingCue = nil
        selectedEvidenceID = nil; retryableQuestion = nil
        currentFeedback = nil; error = nil; lastLatency = nil; requestsSent = 0
        modelCallsSent = 0; escalationCount = 0; routingStatus = modelMode.detail
        pageChangeSuggested = false; isAnalysisPaused = true
        lastAutomaticRequest = .distantPast; lastIntervention = .distantPast
        analysisStatus = "Session cleared · camera stopped · nothing saved by Scholia"
    }
    func shutdown() {
        clearSession()
        closed = true
        camera.onFrame = nil
        camera.onInterruption = nil
        camera.onSourceGeometryChange = nil
    }
    private func record(_ text: String) {
        history.append(PaperHistoryItem(text: text))
        history = Array(history.suffix(80))
    }
    private func issueIdentity(_ text: String, page: Int) -> String {
        let normalized = text.lowercased().replacingOccurrences(of: "versus", with: "vs")
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        return "\(page):\(normalized)"
    }
    private func present(_ response: PaperTutorResponse, for item: PaperEvidence) {
        pendingCue = nil
        turns.append(PaperTurn(role: .assistant, text: response.feedback, evidenceID: item.id,
            focus: response.focus, issueKey: response.issueKey))
        if response.status == .mistake {
            deliveredIssues.insert(issueIdentity(response.issueKey, page: item.page))
            deliveredIssues.insert("focus:" + issueIdentity(response.focus, page: item.page))
        }
        lastIntervention = now()
        record("\(response.status.rawValue.capitalized): \(response.focus.isEmpty ? "captured step" : response.focus)")
        analysisStatus = "Feedback ready · tied to page \(item.page), step \(item.revision + 1)"
    }
    private func deliverPendingCueIfReady(at timestamp: Date) {
        guard let pendingCue else { return }
        guard let item = evidence.first(where: { $0.id == pendingCue.evidenceID }), isCurrent(item.id) else {
            self.pendingCue = nil
            return
        }
        guard timestamp.timeIntervalSince(lastIntervention) >= min(300, max(20, notificationInterval)) else { return }
        let response = pendingCue.response
        guard !deliveredIssues.contains(issueIdentity(response.issueKey, page: item.page)),
            !deliveredIssues.contains("focus:" + issueIdentity(response.focus, page: item.page)) else {
            self.pendingCue = nil
            return
        }
        present(response, for: item)
    }
    private func trimMemory() {
        turns = Array(turns.suffix(60))
        // Preserve the initial visual problem and the most recent steps, bounded
        // by both count and encoded bytes. No image is written to the library.
        while evidence.count > 24 || (evidence.reduce(0) { $0 + $1.jpeg.count } > 20_000_000 && evidence.count > 1) {
            let currentPageStart = evidence.firstIndex { $0.page == page }
            let removable = evidence.indices.dropFirst().dropLast().first {
                $0 != currentPageStart && evidence[$0].id != selectedEvidenceID
                    && evidence[$0].id != lastAcceptedEvidenceID
            }
            evidence.remove(at: removable ?? 0)
        }
    }
}
