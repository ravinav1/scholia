@preconcurrency import AppKit
import Foundation
@testable import ScholiaMac

@main @MainActor
struct ResponsivenessSmoke {
    static func main() async throws {
        checkSelectionGestures()
        try await checkKeyboardRouting()
        try await checkOCRScheduling()
    }

    static func checkSelectionGestures() {
        for key: UInt16 in [0, 1, 2, 36, 48, 49, 51, 53, 123, 126] {
            for modifiers: NSEvent.ModifierFlags in [[], .shift, .option, .command] {
                precondition(SelectionWatcherEventAction.action(type: .keyDown, keyCode: key, modifiers: modifiers) == .clear,
                    "Typing must cancel an outstanding selection read before key-up")
            }
        }
        for key: UInt16 in [0, 1, 2, 36, 48, 49, 51, 53, 123, 126] {
            precondition(SelectionWatcherEventAction.action(type: .keyUp, keyCode: key, modifiers: []) == .ignore)
        }
        precondition(SelectionWatcherEventAction.action(type: .keyUp, keyCode: 0, modifiers: [.command]) == .capture)
        precondition(SelectionWatcherEventAction.action(type: .keyUp, keyCode: 0, modifiers: [.command, .shift]) == .ignore)
        for key: UInt16 in [123, 124, 125, 126, 115, 119, 116, 121] {
            precondition(SelectionWatcherEventAction.action(type: .keyUp, keyCode: key, modifiers: [.shift]) == .capture)
            precondition(SelectionWatcherEventAction.action(type: .keyUp, keyCode: key, modifiers: [.shift, .option]) == .capture)
        }
        precondition(SelectionWatcherEventAction.action(type: .leftMouseUp, keyCode: 0, modifiers: []) == .capture)
        print("PASS: ordinary typing performs no selection capture; mouse, Select All and selection navigation still capture")
    }

    static func checkKeyboardRouting() async throws {
        var cycles: [QuickChatThinkingCycleDirection] = []
        let session = QuickChatCommandTabEventTap.Session { cycles.append($0) }
        let completed = DispatchSemaphore(value: 0)
        // Deliberately keep the main actor blocked. Exercise the same callback
        // as the real tap without posting any keystrokes to the user's apps.
        let started = ContinuousClock.now
        Thread.detachNewThread {
            autoreleasepool {
                let ordinary = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
                ordinary.flags = []
                for _ in 0..<10_000 {
                    precondition(session.handle(type: .keyDown, event: ordinary) != nil)
                    precondition(session.handle(type: .keyUp, event: ordinary) != nil)
                }
                let tab = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true)!
                tab.flags = []
                precondition(session.handle(type: .keyDown, event: tab) != nil)
                precondition(session.handle(type: .keyUp, event: tab) != nil)
                tab.flags = .maskCommand
                precondition(session.handle(type: .keyDown, event: tab) == nil)
                // The matching key-up stays consumed if Command was released first.
                tab.flags = []
                precondition(session.handle(type: .keyUp, event: tab) == nil)
                tab.flags = [.maskCommand, .maskShift]
                precondition(session.handle(type: .keyDown, event: tab) == nil)
                precondition(session.handle(type: .keyUp, event: tab) == nil)
                tab.flags = [.maskCommand, .maskAlternate]
                precondition(session.handle(type: .keyDown, event: tab) != nil)
                completed.signal()
            }
        }
        precondition(completed.wait(timeout: .now() + 0.5) == .success,
            "Global input delivery must not wait for the main actor")
        let elapsed = started.duration(to: .now)
        for _ in 0..<50 where cycles.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        precondition(cycles == [.forward, .backward])
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true)!
        event.flags = .maskCommand
        precondition(session.handle(type: .tapDisabledByTimeout, event: event) != nil)
        precondition(!session.isRunning && session.handle(type: .keyDown, event: event) != nil,
            "Timed-out taps must fail open")
        session.stop()
        let reopened = QuickChatCommandTabEventTap.Session { _ in }
        precondition(reopened.handle(type: .keyDown, event: event) == nil)
        reopened.stop()
        precondition(reopened.handle(type: .keyUp, event: event) != nil)
        print("PASS: 20,000 keyboard callbacks with main actor blocked in \(elapsed); chord routing, timeout and stop/reopen")
    }

    static func checkOCRScheduling() async throws {
        let gate = StudyOCRRecognitionGate()
        let probe = RecognitionProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try gate.withSlot {
                        probe.begin()
                        Thread.sleep(forTimeInterval: 0.02)
                        probe.end()
                    }
                }
            }
            try await group.waitForAll()
        }
        precondition(probe.peak == 1 && probe.completed == 6,
            "Concurrent downloads must share one recognition slot")

        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let holder = Task.detached {
            try gate.withSlot { entered.signal(); _ = release.wait(timeout: .now() + 2) }
        }
        precondition(entered.wait(timeout: .now() + 1) == .success)
        let waiter = Task.detached { try gate.withSlot { preconditionFailure("Cancelled waiter started OCR") } }
        try await Task.sleep(for: .milliseconds(80))
        let cancelled = ContinuousClock.now
        waiter.cancel()
        do { _ = try await waiter.value; preconditionFailure("Cancellation must throw") }
        catch is CancellationError { }
        precondition(cancelled.duration(to: .now) < .milliseconds(300), "Cancellation must not wait for an active page")
        release.signal()
        try await holder.value
        do { try gate.withSlot { throw CancellationError() } }
        catch is CancellationError { }
        let recovered = try gate.withSlot { 42 }
        precondition(recovered == 42, "Thrown work must release the recognition slot")
        print("PASS: six OCR clients serialized; waiting cancellation and failure release")
    }
}

private final class RecognitionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0, maximum = 0, finished = 0
    var peak: Int { lock.withLock { maximum } }
    var completed: Int { lock.withLock { finished } }
    func begin() { lock.withLock { active += 1; maximum = max(maximum, active) } }
    func end() { lock.withLock { active -= 1; finished += 1 } }
}
