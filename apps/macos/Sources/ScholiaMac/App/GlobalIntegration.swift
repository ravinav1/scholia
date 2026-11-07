@preconcurrency import AppKit
@preconcurrency import Carbon
import Foundation

struct ShortcutModifiers: OptionSet, Codable, Equatable, Hashable, Sendable {
    let rawValue: UInt8

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let shift = ShortcutModifiers(rawValue: 1 << 1)
    static let option = ShortcutModifiers(rawValue: 1 << 2)
    static let control = ShortcutModifiers(rawValue: 1 << 3)
}

struct KeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    var modifiers: ShortcutModifiers
    var keyLabel: String

    static let explainDefault = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_E), modifiers: [.command, .shift], keyLabel: "E"
    )
    static let captureDefault = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_S), modifiers: [.command, .shift], keyLabel: "S"
    )
    static let quickAskDefault = KeyboardShortcut(
        keyCode: UInt32(kVK_Space), modifiers: [.command, .shift], keyLabel: "Space"
    )
    static let toggleSelectionPopupDefault = KeyboardShortcut(
        keyCode: UInt32(kVK_ANSI_P), modifiers: [.command, .shift], keyLabel: "P"
    )

    var displayName: String {
        var value = ""
        if modifiers.contains(.command) { value += "⌘" }
        if modifiers.contains(.shift) { value += "⇧" }
        if modifiers.contains(.option) { value += "⌥" }
        if modifiers.contains(.control) { value += "⌃" }
        return value + keyLabel
    }

    var isValid: Bool {
        guard !keyLabel.isEmpty else { return false }
        let hasPrimaryModifier = !modifiers.intersection([.command, .option, .control]).isEmpty
        return hasPrimaryModifier || keyLabel.hasPrefix("F")
    }

    init(keyCode: UInt32, modifiers: ShortcutModifiers, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = String(keyLabel.prefix(12))
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var capturedModifiers: ShortcutModifiers = []
        if flags.contains(.command) { capturedModifiers.insert(.command) }
        if flags.contains(.shift) { capturedModifiers.insert(.shift) }
        if flags.contains(.option) { capturedModifiers.insert(.option) }
        if flags.contains(.control) { capturedModifiers.insert(.control) }
        modifiers = capturedModifiers
        keyLabel = Self.label(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
    }

    private static func label(keyCode: UInt16, characters: String?) -> String {
        let labels: [UInt16: String] = [
            UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥", UInt16(kVK_Space): "Space",
            UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦", UInt16(kVK_Escape): "⎋",
            UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘", UInt16(kVK_PageUp): "⇞",
            UInt16(kVK_PageDown): "⇟", UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
            UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
            UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
            UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
            UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
            UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
            UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
            UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20"
        ]
        if let label = labels[keyCode] { return label }
        return characters?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .prefix(1)
            .description ?? ""
    }
}

enum GlobalAction: UInt32, CaseIterable, Hashable, Sendable {
    case explainSelection = 1
    case captureRegion = 2
    case quickAsk = 3
    case toggleSelectionPopup = 4
}

func scholiaGlobalActions(
    selectionExplainEnabled: Bool,
    captureRegionEnabled: Bool
) -> Set<GlobalAction> {
    var actions: Set<GlobalAction> = [.quickAsk, .toggleSelectionPopup]
    if selectionExplainEnabled { actions.insert(.explainSelection) }
    if captureRegionEnabled { actions.insert(.captureRegion) }
    return actions
}

@MainActor
final class GlobalHotKeyController {
    private static let signature: OSType = 0x5343484C // SCHL
    private var handlerReference: EventHandlerRef?
    private var hotKeyReferences: [EventHotKeyRef] = []
    private var actionHandler: ((GlobalAction) -> Void)?

    private static let carbonHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr, identifier.signature == signature,
              let action = GlobalAction(rawValue: identifier.id) else {
            return OSStatus(eventNotHandledErr)
        }
        let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async { controller.actionHandler?(action) }
        return noErr
    }

    @discardableResult
    func start(
        explainShortcut: KeyboardShortcut,
        captureShortcut: KeyboardShortcut,
        quickAskShortcut: KeyboardShortcut,
        toggleSelectionPopupShortcut: KeyboardShortcut,
        enabledActions: Set<GlobalAction> = Set(GlobalAction.allCases),
        handler: @escaping (GlobalAction) -> Void
    ) -> Bool {
        stop()
        actionHandler = handler
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.carbonHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerReference
        )
        guard installStatus == noErr else { return false }

        let registrations = [
            (GlobalAction.explainSelection, explainShortcut),
            (GlobalAction.captureRegion, captureShortcut),
            (GlobalAction.quickAsk, quickAskShortcut),
            (GlobalAction.toggleSelectionPopup, toggleSelectionPopupShortcut)
        ]
        let requestedRegistrations = registrations.filter {
            enabledActions.contains($0.0) && $0.1.isValid
        }
        for (action, shortcut) in requestedRegistrations {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let result = RegisterEventHotKey(
                shortcut.keyCode,
                carbonModifiers(for: shortcut.modifiers),
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if result == noErr, let reference { hotKeyReferences.append(reference) }
        }
        return hotKeyReferences.count == requestedRegistrations.count
    }

    func stop() {
        for reference in hotKeyReferences { UnregisterEventHotKey(reference) }
        hotKeyReferences.removeAll()
        if let handlerReference { RemoveEventHandler(handlerReference) }
        handlerReference = nil
        actionHandler = nil
    }

    private func carbonModifiers(for modifiers: ShortcutModifiers) -> UInt32 {
        var value: UInt32 = 0
        if modifiers.contains(.command) { value |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { value |= UInt32(shiftKey) }
        if modifiers.contains(.option) { value |= UInt32(optionKey) }
        if modifiers.contains(.control) { value |= UInt32(controlKey) }
        return value
    }

}

struct ExternalApplication: Equatable, Sendable {
    var processIdentifier: pid_t
    var bundleIdentifier: String?
    var name: String
}

@MainActor
final class ExternalApplicationTracker: NSObject {
    private(set) var lastExternalApplication: ExternalApplication?
    var onApplicationChanged: ((ExternalApplication?) -> Void)?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    override init() {
        super.init()
        remember(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    var preferredPID: pid_t? {
        preferredApplication?.processIdentifier
    }

    var preferredApplication: ExternalApplication? {
        guard let current = NSWorkspace.shared.frontmostApplication,
              current.processIdentifier != ownPID else {
            return lastExternalApplication
        }
        return snapshot(of: current)
    }

    func refresh() {
        remember(NSWorkspace.shared.frontmostApplication)
    }

    @objc private func applicationActivated(_ notification: Notification) {
        let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        remember(application)
    }

    private func remember(_ application: NSRunningApplication?) {
        guard let application, application.processIdentifier != ownPID else { return }
        let next = snapshot(of: application)
        guard next != lastExternalApplication else { return }
        lastExternalApplication = next
        onApplicationChanged?(next)
    }

    private func snapshot(of application: NSRunningApplication) -> ExternalApplication {
        ExternalApplication(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            name: application.localizedName
                ?? application.bundleIdentifier
                ?? "Application"
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

enum SelectionWatcherDecision: Equatable {
    case show
    case hide
    case unchanged
}

enum SelectionWatcherEventAction: Equatable {
    case capture, clear, ignore

    static func action(type: NSEvent.EventType, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Self {
        if type == .leftMouseUp { return .capture }
        // Typing cancels a pending read immediately. Only selection gestures
        // should send accessibility requests to the application being used.
        if type == .keyDown { return .clear }
        guard type == .keyUp else { return .ignore }
        let flags = modifiers.intersection([.command, .shift, .option, .control])
        if keyCode == UInt16(kVK_ANSI_A), flags == [.command] { return .capture }
        let navigation: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121]
        return flags.contains(.shift) && navigation.contains(keyCode) ? .capture : .ignore
    }
}

struct SelectionWatcherState {
    private static let handledSelectionSuppressionDuration: TimeInterval = 30

    private struct Signature: Equatable {
        struct Bounds: Equatable {
            let x: Int
            let y: Int
            let width: Int
            let height: Int

            init(_ rect: CGRect) {
                // Accessibility bounds can drift by sub-pixels between otherwise identical reads.
                // A two-point grid keeps those reads stable while distinguishing a fresh selection
                // of the same words elsewhere in the document.
                x = Int((rect.minX / 2).rounded())
                y = Int((rect.minY / 2).rounded())
                width = Int((rect.width / 2).rounded())
                height = Int((rect.height / 2).rounded())
            }
        }

        let pid: pid_t
        let text: String
        let bounds: Bounds?
    }

    private var lastSignature: Signature?
    private var suppressedSignature: Signature?
    private var suppressionExpiresAt: Date?

    mutating func suppress(
        text: String?,
        pid: pid_t?,
        bounds: CGRect? = nil,
        now: Date = Date()
    ) {
        guard let text, text.count >= 2 else { return }
        let signature = Signature(
            pid: pid ?? 0,
            text: text,
            bounds: bounds.map(Signature.Bounds.init)
        )
        lastSignature = signature
        suppressedSignature = signature
        suppressionExpiresAt = now.addingTimeInterval(Self.handledSelectionSuppressionDuration)
    }

    mutating func update(
        text: String?,
        pid: pid_t?,
        bounds: CGRect? = nil,
        now: Date = Date()
    ) -> SelectionWatcherDecision {
        if let suppressionExpiresAt, now >= suppressionExpiresAt {
            suppressedSignature = nil
            self.suppressionExpiresAt = nil
        }
        guard let text, text.count >= 2 else {
            lastSignature = nil
            return .hide
        }
        let signature = Signature(
            pid: pid ?? 0,
            text: text,
            bounds: bounds.map(Signature.Bounds.init)
        )
        if signature == suppressedSignature {
            lastSignature = signature
            return .hide
        }
        if suppressedSignature != nil {
            suppressedSignature = nil
            suppressionExpiresAt = nil
        }
        guard signature != lastSignature else { return .unchanged }
        lastSignature = signature
        return .show
    }
}

@MainActor
final class SelectionWatcher {
    private var monitor: Any?
    private var pending: Task<Void, Never>?
    private var state = SelectionWatcherState()
    private let applicationTracker: ExternalApplicationTracker
    private let shouldCapture: (ExternalApplication?) -> Bool
    private let shouldIgnore: (NSPoint) -> Bool
    private let onSelectionCleared: () -> Void
    private let onSelection: (CapturedContent, NSPoint) -> Void

    init(
        applicationTracker: ExternalApplicationTracker,
        shouldCapture: @escaping (ExternalApplication?) -> Bool = { _ in true },
        shouldIgnore: @escaping (NSPoint) -> Bool = { _ in false },
        onSelectionCleared: @escaping () -> Void = {},
        onSelection: @escaping (CapturedContent, NSPoint) -> Void
    ) {
        self.applicationTracker = applicationTracker
        self.shouldCapture = shouldCapture
        self.shouldIgnore = shouldIgnore
        self.onSelectionCleared = onSelectionCleared
        self.onSelection = onSelection
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp, .keyDown, .keyUp]) { [weak self] event in
            let respectPopupHitArea = event.type == .leftMouseUp
            let action = SelectionWatcherEventAction.action(type: event.type, keyCode: event.keyCode,
                modifiers: event.modifierFlags)
            Task { @MainActor in
                switch action {
                case .capture: self?.selectionMayHaveChanged(respectPopupHitArea: respectPopupHitArea)
                case .clear: self?.clearSelection()
                case .ignore: break
                }
            }
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        state = SelectionWatcherState()
    }

    func suppress(_ capture: CapturedContent, now: Date = Date()) {
        pending?.cancel()
        pending = nil
        state.suppress(
            text: capture.text,
            pid: capture.applicationPID,
            bounds: capture.selectionBounds,
            now: now
        )
    }

    private func clearSelection() {
        pending?.cancel()
        pending = nil
        _ = state.update(text: nil, pid: nil)
        onSelectionCleared()
    }

    private func selectionMayHaveChanged(respectPopupHitArea: Bool) {
        pending?.cancel()
        let point = NSEvent.mouseLocation
        guard !respectPopupHitArea || !shouldIgnore(point) else { return }
        guard shouldCapture(applicationTracker.preferredApplication) else {
            state = SelectionWatcherState()
            onSelectionCleared()
            return
        }
        let pid = applicationTracker.preferredPID
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self else { return }
            guard !respectPopupHitArea || !self.shouldIgnore(point) else { return }
            let capture = try? await SelectionReader.capture(
                preferredPID: pid,
                allowClipboardFallback: false
            )
            guard !Task.isCancelled, self.applicationTracker.preferredPID == pid,
                  self.shouldCapture(self.applicationTracker.preferredApplication) else { return }
            switch self.state.update(
                text: capture?.text,
                pid: pid,
                bounds: capture?.selectionBounds
            ) {
            case .show:
                guard let capture else { return }
                self.onSelection(capture, point)
            case .hide:
                self.onSelectionCleared()
            case .unchanged:
                break
            }
        }
    }
}
