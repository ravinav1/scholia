@preconcurrency import AppKit
import Foundation
import SwiftUI
@testable import ScholiaMac

/// Native rendering and interaction smoke. No camera is started and all model
/// completions are fixtures; this does not substitute for physical-device QA.
@main
@MainActor
struct PaperUISmoke {
    private final class Clock { var date = Date() }
    private final class Calls {
        var count = 0
        var delayNext = false
        var pending: CheckedContinuation<Void, Never>?
        var requests: [[ConversationMessage]] = []
    }

    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await run()
                print("PASS: native paper-study setup, local observation, capture, evidence links, typed follow-up, pinned historical discussion, preserved interrupted request and explicit retry, correction, pause, light/dark/narrow rendering, and clear-on-close. Fixture model only; no camera permission requested.")
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        NSApplication.shared.run()
    }

    static func run() async throws {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("output/paper-study")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let clock = Clock(), calls = Calls(), image = try visualFixture()
        let session = PaperStudySession(camera: PaperCamera(), now: { clock.date }) { messages in
            calls.count += 1
            calls.requests.append(messages)
            try require(messages.contains { $0.imageData != nil }, "A capture must reach the injected vision completion")
            if calls.count > 1 {
                try require(messages.contains { $0.content.contains("differentiate") }, "Follow-up must retain the earlier tutor hint")
            }
            if calls.delayNext {
                calls.delayNext = false
                // Ignore cancellation to prove discarded transport output never
                // replaces the question-preservation UI with a stale answer.
                await withCheckedContinuation { calls.pending = $0 }
            } else {
                try await Task.sleep(for: .milliseconds(30))
            }
            return #"{"status":"mistake","transcription":"u = x², du = 2x dx; ∫ cos(u) du = −sin(u) + C","feedback":"Look at the sign in your last line. What do you get if you differentiate $-\\sin(u)$?","focus":"Last line: ∫ cos(u) du = −sin(u) + C","confidence":0.98,"issueKey":"antiderivative-sign"}"#
        }
        let controller = PaperStudyWindowController(session: session, autosave: false)
        controller.show(app: AppModel.shared)
        guard let window = controller.window else { throw StudyError.message("Paper window did not open") }
        window.setContentSize(NSSize(width: 1200, height: 850))
        await settle(window)
        try require(session.isAnalysisPaused && !session.camera.isRunning && calls.count == 0,
                    "Opening must neither capture nor send images")
        for id in ["paper.problem", "paper.cameraPicker", "paper.connectCamera", "paper.rotateCamera", "paper.helpMode", "paper.modelMode", "paper.question", "paper.send"] {
            _ = try await waitForElement(id, in: window)
        }
        try require(session.samplingInterval == 5 && session.notificationInterval == 30,
                    "Default changed-work checks must be five seconds apart with thirty seconds between cues")
        try require(session.camera.rotationDegrees == 0, "Camera orientation starts unrotated")
        try require(session.modelMode == .automatic, "Tutor model mode must default to Automatic")
        try await pressLabel(PaperModelMode.fast.label, in: window)
        try require(session.modelMode == .fast, "Fast model mode must be selectable without starting a request")
        try await pressLabel(PaperModelMode.thorough.label, in: window)
        try require(session.modelMode == .thorough, "Thorough model mode must be selectable without starting a request")
        try await pressLabel(PaperModelMode.automatic.label, in: window)
        try require(session.modelMode == .automatic && calls.count == 0,
                    "Changing model mode must not send notebook images")
        try await snapshot(window, name: "setup-light", appearance: .aqua, output: output)
        try require(session.mode == .proactive, "Paper study should offer auto-check by default while remaining paused")
        session.mode = .onRequest
        let unsent = "Can you check my work when the camera is ready?"
        try await editField("paper.question", value: unsent, in: window)
        try await press("paper.send", in: window)
        try require(session.error != nil && session.turns.isEmpty && calls.count == 0,
                    "A question without evidence must fail locally")
        let draftField = elements(in: window).compactMap { $0.object as? NSTextField }
            .first { $0.accessibilityIdentifier() == "paper.question" || $0.placeholderString == "Ask about this step…" }
        try require(draftField?.stringValue == unsent, "Rejected questions must preserve the student's draft")
        try await editField("paper.question", value: "", in: window)

        session.problemStatement = "Evaluate ∫ 2x cos(x²) dx using a substitution."
        // The generated image is a layout fixture, not actual handwritten validation.
        func observe(value: UInt8 = 170, hand: Bool = false) {
            session.observe(PaperFrame(id: UUID(), capturedAt: clock.date, jpeg: image,
                width: 1100, height: 760, fingerprint: [UInt8](repeating: value, count: 1024),
                qualityIssue: nil, handDetected: hand))
        }
        observe()
        clock.date = clock.date.addingTimeInterval(0.5); observe()
        clock.date = clock.date.addingTimeInterval(2); observe()
        session.setAnalysisPaused(false)
        clock.date = clock.date.addingTimeInterval(2); observe()
        try require(!session.evidence.isEmpty && calls.count == 0,
                    "On-request observation keeps evidence in memory without model calls")
        await settle(window)
        guard let inspect = elements(in: window).first(where: { $0.label == "Inspect crop at full size" })
        else { throw StudyError.message("Missing local legibility inspection") }
        try require(inspect.press(), "Local crop inspector must open before sending")
        await settle(window)
        guard let inspection = window.attachedSheet else { throw StudyError.message("Local crop inspector did not open") }
        try require(calls.count == 0, "Inspecting the crop must not send it")
        try await snapshot(inspection, name: "local-inspection", appearance: .aqua, output: output)
        guard let done = elements(in: inspection).first(where: { $0.label == "Done" })
        else { throw StudyError.message("Local crop inspector needs a close control") }
        try require(done.press(), "Inspector Done control must dismiss")
        await settle(window)
        try await press("paper.capture", in: window)
        for _ in 0..<40 where session.requestInFlight { try await Task.sleep(for: .milliseconds(50)) }
        try require(session.turns.contains { $0.role == .assistant } && calls.count == 1,
                    "Capture control should produce contextual feedback")
        try require(session.turns.last?.evidenceID == session.evidence.last?.id,
                    "Response must link to its visual evidence")
        for (name, appearance, size) in [
            ("session-light", NSAppearance.Name.aqua, NSSize(width: 1200, height: 850)),
            ("session-dark", NSAppearance.Name.darkAqua, NSSize(width: 1200, height: 850)),
            ("session-minimum", NSAppearance.Name.aqua, NSSize(width: 1060, height: 720))
        ] {
            window.setContentSize(size)
            try await snapshot(window, name: name, appearance: appearance, output: output)
            let composer = try element("paper.question", in: window)
            try require(composer.frame.width >= 220 && composer.frame.height > 0, "Composer must remain usable at \(name)")
        }
        try await editField("paper.question", value: "Why is differentiating a useful check?", in: window)
        try await press("paper.send", in: window)
        for _ in 0..<40 where session.requestInFlight { try await Task.sleep(for: .milliseconds(50)) }
        try require(calls.count == 2 && session.turns.count == 4, "Contextual follow-up should preserve the first exchange")
        try require(session.turns.contains { $0.role == .user && $0.text == "Why is differentiating a useful check?" },
                    "The typed composer question must reach the conversation")

        guard let discussedTurn = session.turns.last(where: { $0.role == .assistant }),
              let discussedEvidenceID = discussedTurn.evidenceID else { throw StudyError.message("Missing step to discuss") }
        try await press("paper.discuss.\(discussedTurn.id.uuidString)", in: window)
        try require(session.selectedEvidenceID == discussedEvidenceID,
                    "Discuss this step must pin its visual evidence")
        observe(value: 190, hand: true)
        try await editField("paper.question", value: "Why does that derivative change the sign?", in: window)
        try await press("paper.send", in: window)
        for _ in 0..<40 where session.requestInFlight { try await Task.sleep(for: .milliseconds(50)) }
        try require(calls.count == 3 && session.turns.last?.role == .assistant
                    && session.turns.last?.evidenceID == discussedEvidenceID,
                    "Pinned follow-up must work while a hand covers the live page and keep its original evidence")
        try await snapshot(window, name: "discuss-captured-step", appearance: .aqua, output: output)
        try await press("paper.clearDiscussedStep", in: window)
        try require(session.selectedEvidenceID == nil, "Use live page must clear the pinned context")

        for _ in 0..<6 { clock.date = clock.date.addingTimeInterval(0.5); observe(value: 190) }
        calls.delayNext = true
        try await editField("paper.question", value: "Check the step I just captured while I continue writing.", in: window)
        try await press("paper.send", in: window)
        try require(session.requestInFlight && calls.pending != nil, "The delayed fixture request must be pending")
        let responsesBeforeRevision = session.turns.filter { $0.role == .assistant }.count
        let requestedEvidenceID = session.turns.last?.evidenceID
        clock.date = clock.date.addingTimeInterval(0.5); observe(value: 210)
        try require(session.requestInFlight, "A requested snapshot must remain discussable while the student writes")
        calls.pending?.resume(); calls.pending = nil
        await settle(window)
        try require(session.turns.filter { $0.role == .assistant }.count == responsesBeforeRevision + 1
                    && session.turns.last?.evidenceID == requestedEvidenceID
                    && !session.isCurrent(requestedEvidenceID) && session.currentFeedback == nil,
                    "A completed snapshot response must stay tied to earlier work and never become current feedback")

        for _ in 0..<6 { clock.date = clock.date.addingTimeInterval(0.5); observe(value: 210) }
        calls.delayNext = true
        let interruptedQuestion = "Can you recheck the sign after my revision?"
        try await editField("paper.question", value: interruptedQuestion, in: window)
        try await press("paper.send", in: window)
        try require(session.requestInFlight && calls.pending != nil, "The second delayed fixture request must be pending")
        let responsesBeforePause = session.turns.filter { $0.role == .assistant }.count
        try await press("paper.pauseAnalysis", in: window)
        try require(session.retryableQuestion == interruptedQuestion && !session.requestInFlight,
                    "Explicitly pausing a manual request must preserve its question for retry")
        calls.pending?.resume(); calls.pending = nil
        await settle(window)
        try require(session.turns.filter { $0.role == .assistant }.count == responsesBeforePause,
                    "A response must not appear after the student pauses the request")
        _ = try await waitForElement("paper.retryRequest", in: window)
        try await snapshot(window, name: "saved-question-retry", appearance: .aqua, output: output)
        for _ in 0..<6 { clock.date = clock.date.addingTimeInterval(0.5); observe(value: 210) }
        try await press("paper.retryRequest", in: window)
        for _ in 0..<40 where session.requestInFlight { try await Task.sleep(for: .milliseconds(50)) }
        try require(calls.count == 6 && session.retryableQuestion == nil
                    && session.turns.filter { $0.role == .assistant }.count == responsesBeforePause + 1,
                    "Explicit retry must use the settled current page and complete the saved question")

        session.submitCorrection("That symbol is u, not v. I am using substitution.")
        try require(session.turns.last?.text.contains("using substitution") == true, "Correction must be visible in the conversation")
        if !session.isAnalysisPaused { try await press("paper.pauseAnalysis", in: window) }
        try require(session.isAnalysisPaused, "Pause control must pause observation")
        session.mode = .proactive
        try await press("paper.autoCheck", in: window)
        try require(!session.isAnalysisPaused && !session.camera.isRunning,
                    "Start auto-check must enable observation separately from camera connection")
        try await snapshot(window, name: "auto-check-active", appearance: .aqua, output: output)
        try require(try element("paper.question", in: window).frame.width >= 220,
                    "The composer must remain usable with visible auto-check status")
        try await press("paper.autoCheck", in: window)
        try require(session.isAnalysisPaused, "Pause auto-check must visibly pause observation")

        // Exercise the enlarged evidence through the actual accessibility button.
        if let evidenceButton = elements(in: window).first(where: { $0.label?.contains("Page 1 · step") == true && $0.frame.height > 0 }) {
            _ = evidenceButton.press()
            await settle(window)
            if let sheet = window.attachedSheet {
                try await snapshot(sheet, name: "evidence-detail", appearance: .aqua, output: output)
                window.endSheet(sheet)
            }
        }
        window.performClose(nil)
        await settle(window)
        try require(controller.window == nil && controller.session == nil,
                    "Closing must release the hosted view and session")
        try require(session.turns.isEmpty && session.evidence.isEmpty && session.latestFrame == nil
                    && session.problemStatement.isEmpty && !session.camera.isRunning,
                    "Closing must clear every retained image and conversation and stop capture")
    }

    private static func visualFixture() throws -> Data {
        let image = NSImage(size: NSSize(width: 1100, height: 760))
        image.lockFocus()
        NSColor(calibratedRed: 0.99, green: 0.98, blue: 0.93, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1100, height: 760).fill()
        NSColor(calibratedRed: 0.76, green: 0.82, blue: 0.86, alpha: 0.5).setStroke()
        for y in stride(from: 70, through: 700, by: 60) {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 40, y: y)); line.line(to: NSPoint(x: 1060, y: y)); line.stroke()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Georgia-Italic", size: 42) ?? NSFont.systemFont(ofSize: 42),
            .foregroundColor: NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.35, alpha: 1)
        ]
        for (index, text) in ["∫ 2x cos(x²) dx", "u = x²     du = 2x dx", "∫ cos(u) du", "= −sin(u) + C"].enumerated() {
            (text as NSString).draw(at: NSPoint(x: 100 + index * 7, y: 610 - index * 120), withAttributes: attributes)
        }
        ("Generated layout fixture — not a handwriting accuracy test" as NSString).draw(
            at: NSPoint(x: 70, y: 25), withAttributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.secondaryLabelColor])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { throw StudyError.message("Could not create visual fixture") }
        return data
    }

    private static func snapshot(_ window: NSWindow, name: String, appearance: NSAppearance.Name, output: URL) async throws {
        window.appearance = NSAppearance(named: appearance)
        await settle(window)
        guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { throw StudyError.message("Could not render \(name)") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw StudyError.message("No PNG for \(name)") }
        try png.write(to: output.appendingPathComponent("\(name).png"))
    }

    private static func settle(_ window: NSWindow) async {
        try? await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private struct Element {
        let object: AnyObject
        var id: String? { object.accessibilityIdentifier?() ?? nil }
        var label: String? { object.accessibilityLabel?() ?? nil }
        var frame: NSRect { object.accessibilityFrame?() ?? .zero }
        var children: [Any] { (object.accessibilityChildren?() ?? nil) ?? [] }
        func press() -> Bool { object.accessibilityPerformPress?() ?? false }
    }
    private static func elements(in root: Any) -> [Element] {
        var stack: [Any] = [root], seen = Set<ObjectIdentifier>(), result: [Element] = []
        while let item = stack.popLast(), seen.count < 20_000 {
            let object = item as AnyObject
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            let value = Element(object: object)
            result.append(value)
            stack.append(contentsOf: value.children)
            if let window = item as? NSWindow, let content = window.contentView { stack.append(content) }
            if let view = item as? NSView { stack.append(contentsOf: view.subviews) }
        }
        return result
    }
    private static func element(_ id: String, in window: NSWindow) throws -> Element {
        guard let value = elements(in: window).filter({ $0.id == id }).max(by: { $0.frame.height < $1.frame.height })
        else { throw StudyError.message("Missing native control \(id)") }
        return value
    }
    private static func press(_ id: String, in window: NSWindow) async throws {
        let control = try await waitForElement(id, in: window)
        try require(control.press(), "Could not activate \(id)")
        await settle(window)
    }
    private static func pressLabel(_ label: String, in window: NSWindow) async throws {
        for candidate in elements(in: window).filter({ $0.label == label }) {
            if candidate.press() { await settle(window); return }
        }
        throw StudyError.message("Could not activate native option \(label)")
    }
    private static func waitForElement(_ id: String, in window: NSWindow) async throws -> Element {
        for _ in 0..<40 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let value = try? element(id, in: window) { return value }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try element(id, in: window)
    }
    private static func editField(_ id: String, value: String, in window: NSWindow) async throws {
        let fields = elements(in: window).compactMap { $0.object as? NSTextField }
        guard let field = fields.first(where: { $0.accessibilityIdentifier() == id })
                ?? fields.first(where: { id == "paper.question" && $0.placeholderString == "Ask about this step…" }) else {
            throw StudyError.message("Missing editable native field \(id); fields: \(fields.map { $0.accessibilityIdentifier() + ":" + ($0.placeholderString ?? "") })")
        }
        try require(window.makeFirstResponder(field), "Could not focus \(id)")
        field.selectText(nil)
        for _ in 0..<20 {
            if let editor = field.currentEditor() as? NSTextView {
                editor.selectAll(nil)
                editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                await settle(window)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw StudyError.message("The question field did not acquire a native editor")
    }
    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw StudyError.message(message) }
    }
}
