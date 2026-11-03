@preconcurrency import AppKit
@preconcurrency import CoreGraphics
import Foundation

/// An active event tap sits in macOS's input delivery path. It must never wait
/// for SwiftUI, accessibility IPC, or any other work on Scholia's main thread.
@MainActor
final class QuickChatCommandTabEventTap {
    private var session: Session?
    private let onCycle: @MainActor @Sendable (QuickChatThinkingCycleDirection) -> Void

    init(onCycle: @escaping @MainActor @Sendable (QuickChatThinkingCycleDirection) -> Void) {
        self.onCycle = onCycle
    }

    func start() {
        guard session == nil else { return }
        let next = Session(onCycle: onCycle)
        session = next
        let thread = Thread { next.run() }
        thread.name = "Scholia Quick Chat shortcut"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        session?.stop()
        session = nil
    }

    deinit { session?.stop() }

    // Each start owns a separate session, so a rapid close/reopen cannot revive
    // a stopped tap. Only this lock's small routing state crosses threads.
    final class Session: @unchecked Sendable {
        private let lock = NSLock()
        private var active = true
        private var swallowedTab = false
        private var tap: CFMachPort?
        private var runLoop: CFRunLoop?
        private let onCycle: @MainActor @Sendable (QuickChatThinkingCycleDirection) -> Void

        init(onCycle: @escaping @MainActor @Sendable (QuickChatThinkingCycleDirection) -> Void) {
            self.onCycle = onCycle
        }

        var isRunning: Bool { lock.withLock { active } }

        func run() {
            let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, info in
                    guard let info else { return Unmanaged.passUnretained(event) }
                    return Unmanaged<Session>.fromOpaque(info).takeUnretainedValue().handle(type: type, event: event)
                }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                stop()
                return
            }
            let loop = CFRunLoopGetCurrent()!
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)!
            CFRunLoopAddSource(loop, source, .commonModes)
            let shouldRun = lock.withLock {
                guard active else { return false }
                tap = port
                runLoop = loop
                return true
            }
            if shouldRun { CFRunLoopRun() }
            CGEvent.tapEnable(tap: port, enable: false)
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFMachPortInvalidate(port)
            lock.withLock { active = false; tap = nil; runLoop = nil }
        }

        func stop() {
            let resources = lock.withLock {
                active = false
                swallowedTab = false
                return (tap, runLoop)
            }
            if let port = resources.0 { CGEvent.tapEnable(tap: port, enable: false) }
            if let loop = resources.1 {
                // A queued stop also works if the thread has not entered Run yet.
                CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(loop) }
                CFRunLoopWakeUp(loop)
            }
        }

        func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // Fail open. Re-enabling a timed-out tap in its callback can
                // repeatedly stall input; a subsequent panel focus may retry.
                stop()
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown || type == .keyUp,
                  event.getIntegerValueField(.keyboardEventKeycode) == 48 else {
                return Unmanaged.passUnretained(event)
            }
            var modifiers = NSEvent.ModifierFlags()
            if event.flags.contains(.maskCommand) { modifiers.insert(.command) }
            if event.flags.contains(.maskShift) { modifiers.insert(.shift) }
            if event.flags.contains(.maskAlternate) { modifiers.insert(.option) }
            if event.flags.contains(.maskControl) { modifiers.insert(.control) }
            let direction = quickChatThinkingCycleDirection(keyCode: 48, modifierFlags: modifiers)
            let consumed = lock.withLock {
                guard active else { return false }
                if type == .keyUp {
                    defer { swallowedTab = false }
                    return swallowedTab
                }
                guard direction != nil else { return false }
                swallowedTab = true
                return true
            }
            guard consumed else { return Unmanaged.passUnretained(event) }
            if type == .keyDown, let direction {
                Task { @MainActor [self] in
                    guard isRunning else { return }
                    onCycle(direction)
                }
            }
            return nil
        }
    }
}
