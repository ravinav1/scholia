@preconcurrency import ApplicationServices
@preconcurrency import AppKit
import Foundation

enum SelectionReaderError: LocalizedError {
    case permissionRequired
    case noFocusedElement
    case noSelection
    case protectedField

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            "Allow Scholia in System Settings → Privacy & Security → Accessibility."
        case .noFocusedElement:
            "Scholia could not read the focused application."
        case .noSelection:
            "Select some text in another app, then try again."
        case .protectedField:
            "Scholia never reads selections from protected text fields."
        }
    }
}

struct ApplicationContextSnapshot: Equatable, Sendable {
    var applicationName: String?
    var applicationBundleIdentifier: String?
    var applicationPID: pid_t?
    var windowTitle: String?
    var sourceURL: String?
    var context: String?
}

// Accessibility IPC can wait on another app. Serialize reads away from the
// UI thread, and let cancellation discard queued/outdated selection requests.
private actor AccessibilitySelectionWorker {
    static let shared = AccessibilitySelectionWorker()
    func capture(pid: pid_t?) throws -> CapturedContent {
        try Task.checkCancellation()
        return try SelectionReader.captureWithAccessibility(pid: pid)
    }
}

@MainActor
enum SelectionReader {
    nonisolated static let maximumSelectionLength = TextInputPolicy.maximumMessageUTF16Units
    nonisolated static let maximumApplicationContextLength = 24_000
    private nonisolated static let maximumApplicationContextNodes = 800

    nonisolated static func kind(for text: String) -> CaptureKind {
        likelyLatex(text) ? .latex : .text
    }

    nonisolated static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func capture(
        preferredPID: pid_t? = nil,
        allowClipboardFallback: Bool = true
    ) async throws -> CapturedContent {
        guard isTrusted else { throw SelectionReaderError.permissionRequired }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pid = preferredPID ?? frontmostPID

        do {
            return try await AccessibilitySelectionWorker.shared.capture(pid: pid)
        } catch SelectionReaderError.noSelection where allowClipboardFallback && pid == frontmostPID {
            if let copied = await captureByCopying(pid: pid) { return copied }
            throw SelectionReaderError.noSelection
        } catch SelectionReaderError.noFocusedElement where allowClipboardFallback && pid == frontmostPID {
            if let copied = await captureByCopying(pid: pid) { return copied }
            throw SelectionReaderError.noFocusedElement
        }
    }

    static func captureLocalSelection() async -> CapturedContent? {
        guard NSApp.isActive else { return nil }
        return await captureByCopying(
            pid: ProcessInfo.processInfo.processIdentifier,
            requireFrontmost: false
        )
    }

    static func captureApplicationContext(preferredPID: pid_t? = nil) -> ApplicationContextSnapshot {
        let pid = preferredPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let application = pid.flatMap(NSRunningApplication.init(processIdentifier:))
        var snapshot = ApplicationContextSnapshot(
            applicationName: application?.localizedName,
            applicationBundleIdentifier: application?.bundleIdentifier,
            applicationPID: pid,
            windowTitle: nil,
            sourceURL: nil,
            context: nil
        )
        guard isTrusted, let pid else {
            snapshot.windowTitle = frontWindowTitle(for: pid)
            return snapshot
        }

        let root = AXUIElementCreateApplication(pid)
        let focusedWindow: AXUIElement? = attribute(kAXFocusedWindowAttribute, from: root)
        let focusedElement: AXUIElement? = attribute(kAXFocusedUIElementAttribute, from: root)
        snapshot.windowTitle = focusedWindow.flatMap { attribute(kAXTitleAttribute, from: $0) }
            ?? frontWindowTitle(for: pid)
        snapshot.sourceURL = documentLocation(
            from: [focusedElement, focusedWindow, root].compactMap { $0 }
        )
        let contextRoots = [focusedElement, focusedWindow].compactMap { $0 }
        snapshot.context = visibleApplicationContext(from: contextRoots.isEmpty ? [root] : contextRoots)
        return snapshot
    }

    nonisolated static func captureVisibleWorkspaceContextAsync(
        question: String,
        preferredPID: pid_t? = nil,
        includeChatGptDesktopContext: Bool = false
    ) async -> String? {
        let task = Task.detached(priority: .userInitiated) {
            captureVisibleWorkspaceContext(
                question: question,
                preferredPID: preferredPID,
                includeChatGptDesktopContext: includeChatGptDesktopContext
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated static func captureVisibleWorkspaceContext(
        question: String,
        preferredPID: pid_t? = nil,
        includeChatGptDesktopContext: Bool = false
    ) -> String? {
        guard !Task.isCancelled, AXIsProcessTrusted() else { return nil }
        let metadata = visibleWindowMetadata(
            preferredPID: preferredPID,
            includeChatGptDesktopContext: includeChatGptDesktopContext
        )
        guard !metadata.isEmpty else { return nil }
        let questionTerms = VisibleWorkspaceContext.questionTerms(question)
        let ranked = metadata.sorted { left, right in
            let leftScore = VisibleWorkspaceContext.relevanceScore(
                left,
                questionTerms: questionTerms
            )
            let rightScore = VisibleWorkspaceContext.relevanceScore(
                right,
                questionTerms: questionTerms
            )
            if leftScore != rightScore { return leftScore > rightScore }
            return left.frontToBackIndex < right.frontToBackIndex
        }
        var captureOrder = Array(ranked.prefix(5))
        if includeChatGptDesktopContext,
           let chatGptWindow = ranked.first(where: VisibleWorkspaceContext.isChatGptDesktopWindow),
           !captureOrder.contains(where: {
               $0.applicationPID == chatGptWindow.applicationPID
                   && $0.windowTitle == chatGptWindow.windowTitle
           }) {
            if captureOrder.count == 5 { captureOrder.removeLast() }
            captureOrder.append(chatGptWindow)
        }

        var windowsByPID: [pid_t: [AXUIElement]] = [:]
        var captured: [VisibleWindowContext] = []
        for var candidate in captureOrder {
            guard !Task.isCancelled else { return nil }
            let root = AXUIElementCreateApplication(candidate.applicationPID)
            AXUIElementSetMessagingTimeout(root, 0.25)
            let windows: [AXUIElement]
            if let cached = windowsByPID[candidate.applicationPID] {
                windows = cached
            } else {
                let value: [AXUIElement] = attribute(kAXWindowsAttribute, from: root) ?? []
                windowsByPID[candidate.applicationPID] = value
                windows = value
            }
            guard let window = accessibilityWindow(
                matching: candidate,
                in: windows,
                root: root
            ) else {
                captured.append(candidate)
                continue
            }
            candidate.windowTitle = attribute(kAXTitleAttribute, from: window)
                ?? candidate.windowTitle
            candidate.sourceURL = documentLocation(from: [window, root])
            candidate.accessibleText = visibleApplicationContext(
                from: [window],
                maximumNodes: 130,
                maximumCharacters: 2_200
            )
            candidate.openTabTitles = browserTabTitles(from: window)
            captured.append(candidate)
        }
        return VisibleWorkspaceContext.formatted(
            candidates: captured,
            question: question,
            includeChatGptDesktopContext: includeChatGptDesktopContext
        )
    }

    nonisolated static func captureWithAccessibility(pid: pid_t?) throws -> CapturedContent {
        try Task.checkCancellation()
        guard isTrusted else { throw SelectionReaderError.permissionRequired }
        let root = pid.map(AXUIElementCreateApplication) ?? AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(root, 0.15)
        guard let focused: AXUIElement = attribute(kAXFocusedUIElementAttribute, from: root) else {
            throw SelectionReaderError.noFocusedElement
        }

        if let subrole: String = attribute(kAXSubroleAttribute, from: focused),
           subrole == (kAXSecureTextFieldSubrole as String) {
            throw SelectionReaderError.protectedField
        }
        guard let selection = boundedSelection(startingAt: focused) else {
            throw SelectionReaderError.noSelection
        }
        let text = selection.text
        return content(
            text: text,
            pid: pid,
            root: root,
            selectionElement: selection.element,
            selectionBounds: selectedTextBounds(from: selection.element)
        )
    }

    private nonisolated static func content(
        text: String,
        pid: pid_t?,
        root: AXUIElement? = nil,
        selectionElement: AXUIElement? = nil,
        selectionBounds: CGRect? = nil
    ) -> CapturedContent {
        let application = pid.flatMap(NSRunningApplication.init(processIdentifier:))
        let root = root ?? pid.map(AXUIElementCreateApplication)
        let focusedWindow: AXUIElement? = root.flatMap { attribute(kAXFocusedWindowAttribute, from: $0) }
        let focusedElement: AXUIElement? = root.flatMap {
            attribute(kAXFocusedUIElementAttribute, from: $0)
        }
        let windowTitle: String? = focusedWindow.flatMap { attribute(kAXTitleAttribute, from: $0) }
        let isMail = NativeMailContext.isMailApplication(
            bundleIdentifier: application?.bundleIdentifier,
            name: application?.localizedName
        )
        let mailRoot = isMail
            ? mailConversationRoot(
                startingAt: selectionElement ?? focusedElement,
                focusedWindow: focusedWindow
            )
            : nil
        let mailContext = mailRoot.flatMap {
            visibleApplicationContext(from: [$0], includeNonVisibleChildren: true)
        }.flatMap {
            NativeMailContext.formattedConversation(
                accessibleText: $0,
                selectedText: text,
                conversationTitle: windowTitle
            )
        }
        let sourceURL = isMail ? documentLocation(
            from: [selectionElement, focusedElement, focusedWindow, root].compactMap { $0 }
        ) : nil
        return CapturedContent(
            kind: isMail ? .mail : kind(for: text),
            text: text,
            applicationName: application?.localizedName,
            applicationBundleIdentifier: application?.bundleIdentifier,
            applicationPID: pid,
            windowTitle: windowTitle,
            sourceURL: sourceURL,
            context: mailContext,
            selectionBounds: selectionBounds
        )
    }

    private nonisolated static func selectedTextBounds(from element: AXUIElement) -> CGRect? {
        guard let selectedRange = selectedTextRange(from: element),
              let rangeValue = accessibilityValue(for: CFRange(
                  location: selectedRange.location,
                  length: min(selectedRange.length, maximumSelectionLength)
              )) else { return nil }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        ) == .success,
        let boundsValue,
        CFGetTypeID(boundsValue) == AXValueGetTypeID() else { return nil }

        let accessibilityValue = unsafeDowncast(boundsValue, to: AXValue.self)
        guard AXValueGetType(accessibilityValue) == .cgRect else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(accessibilityValue, .cgRect, &bounds),
              bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              !bounds.isEmpty else { return nil }
        return bounds
    }

    private nonisolated static func boundedSelection(
        startingAt focusedElement: AXUIElement
    ) -> (text: String, element: AXUIElement)? {
        func selection(in element: AXUIElement) -> (text: String, element: AXUIElement)? {
            guard !Task.isCancelled, !isProtectedTextElement(element) else { return nil }
            guard let rawText = boundedSelectedText(from: element),
                  let text = TextInputPolicy.preparedMessage(
                      rawText,
                      maximumUTF16Units: maximumSelectionLength
                  ) else { return nil }
            return (text, element)
        }
        // Most selections are directly on the focused text control. Do not
        // eagerly enumerate its entire accessibility subtree before checking it.
        if let selected = selection(in: focusedElement) { return selected }
        if let range = selectedTextRange(from: focusedElement), range.length == 0 { return nil }
        for element in selectionCandidates(startingAt: focusedElement).dropFirst() {
            guard !Task.isCancelled else { return nil }
            if let selected = selection(in: element) { return selected }
        }
        return nil
    }

    private nonisolated static func selectionCandidates(startingAt focusedElement: AXUIElement) -> [AXUIElement] {
        var candidates = [focusedElement]
        var parent = focusedElement
        for _ in 0..<5 {
            guard !Task.isCancelled else { return candidates }
            guard let next: AXUIElement = attribute(kAXParentAttribute, from: parent) else { break }
            candidates.append(next)
            parent = next
        }

        let children: [AXUIElement] = attribute(kAXChildrenAttribute, from: focusedElement) ?? []
        var queue = Array(children.prefix(40 - candidates.count))
        var cursor = 0
        while cursor < queue.count, candidates.count < 40, !Task.isCancelled {
            let element = queue[cursor]
            cursor += 1
            candidates.append(element)
            guard !isProtectedTextElement(element) else { continue }
            let children: [AXUIElement] = attribute(kAXChildrenAttribute, from: element) ?? []
            let remaining = 40 - candidates.count - queue.count + cursor
            if remaining > 0 { queue.append(contentsOf: children.prefix(remaining)) }
        }
        return candidates
    }

    private nonisolated static func isProtectedTextElement(_ element: AXUIElement) -> Bool {
        let subrole: String? = attribute(kAXSubroleAttribute, from: element)
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    private nonisolated static func boundedSelectedText(from element: AXUIElement) -> String? {
        if let selectedRange = selectedTextRange(from: element), selectedRange.length > 0 {
            let boundedRange = CFRange(
                location: selectedRange.location,
                length: min(selectedRange.length, maximumSelectionLength)
            )
            if let text = parameterizedText(
                kAXStringForRangeParameterizedAttribute,
                range: boundedRange,
                from: element
            ) ?? parameterizedText(
                kAXAttributedStringForRangeParameterizedAttribute,
                range: boundedRange,
                from: element
            ) {
                return TextInputPolicy.bounded(text)
            }
            if let value = textAttribute(kAXValueAttribute, from: element),
               let selected = boundedTextSelection(in: value, range: selectedRange) {
                return selected
            }
        }
        return textAttribute(kAXSelectedTextAttribute, from: element)
            .map { TextInputPolicy.bounded($0) }
    }

    nonisolated static func boundedTextSelection(
        in value: String,
        range: CFRange,
        maximumUTF16Units: Int = TextInputPolicy.maximumMessageUTF16Units
    ) -> String? {
        guard range.location >= 0, range.length > 0, maximumUTF16Units > 0 else { return nil }
        let text = value as NSString
        guard range.location < text.length else { return nil }
        var boundedLength = min(range.length, maximumUTF16Units, text.length - range.location)
        let finalCodeUnit = text.character(at: range.location + boundedLength - 1)
        if finalCodeUnit >= 0xD800 && finalCodeUnit <= 0xDBFF { boundedLength -= 1 }
        guard boundedLength > 0 else { return nil }
        let boundedRange = NSRange(location: range.location, length: boundedLength)
        return TextInputPolicy.preparedMessage(
            text.substring(with: boundedRange),
            maximumUTF16Units: maximumUTF16Units
        )
    }

    private nonisolated static func parameterizedText(
        _ attributeName: String,
        range: CFRange,
        from element: AXUIElement
    ) -> String? {
        guard let rangeValue = accessibilityValue(for: range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            attributeName as CFString,
            rangeValue,
            &value
        ) == .success else { return nil }
        return plainText(from: value)
    }

    private nonisolated static func textAttribute(_ name: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return plainText(from: value)
    }

    private nonisolated static func plainText(from value: CFTypeRef?) -> String? {
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string
    }

    private nonisolated static func selectedTextRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let accessibilityValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(accessibilityValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(accessibilityValue, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return range
    }

    private nonisolated static func accessibilityValue(for range: CFRange) -> AXValue? {
        var range = range
        return AXValueCreate(.cfRange, &range)
    }

    private static func captureByCopying(
        pid: pid_t?,
        requireFrontmost: Bool = true
    ) async -> CapturedContent? {
        guard let pid,
              !requireFrontmost || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        let oldChangeCount = pasteboard.changeCount

        if requireFrontmost {
            guard let source = CGEventSource(stateID: .hidSystemState),
                  let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
                return nil
            }
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        } else {
            guard NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) else { return nil }
        }

        for _ in 0..<8 where pasteboard.changeCount == oldChangeCount {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        guard pasteboard.changeCount != oldChangeCount else { return nil }
        let copiedChangeCount = pasteboard.changeCount
        let text = normalized(pasteboard.string(forType: .string) ?? "")
        if pasteboard.changeCount == copiedChangeCount { snapshot.restore(to: pasteboard) }
        guard !text.isEmpty else { return nil }
        return content(text: text, pid: pid)
    }

    private static func normalized(_ value: String) -> String {
        TextInputPolicy.preparedMessage(
            value,
            maximumUTF16Units: maximumSelectionLength
        ) ?? ""
    }

    private nonisolated static func visibleApplicationContext(
        from roots: [AXUIElement],
        includeNonVisibleChildren: Bool = false,
        maximumNodes: Int = maximumApplicationContextNodes,
        maximumCharacters: Int = maximumApplicationContextLength
    ) -> String? {
        guard !roots.isEmpty else { return nil }
        var queue = roots
        var cursor = 0
        var visited = 0
        var fragments: [String] = []
        var seenFragments = Set<String>()
        var characterCount = 0

        while cursor < queue.count,
              !Task.isCancelled,
              visited < maximumNodes,
              characterCount < maximumCharacters {
            let element = queue[cursor]
            cursor += 1
            visited += 1

            let subrole: String? = attribute(kAXSubroleAttribute, from: element)
            if subrole == (kAXSecureTextFieldSubrole as String) { continue }
            let role: String = attribute(kAXRoleAttribute, from: element) ?? ""
            let textRoles: Set<String> = [
                "AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink",
                "AXWebArea", "AXPDFPage", "AXDocument", "AXImage"
            ]
            let labelledRoles = textRoles.union(["AXList", "AXOutline", "AXRow", "AXCell"])
            var candidates: [String] = []
            if labelledRoles.contains(role), let title: String = attribute(kAXTitleAttribute, from: element) {
                candidates.append(title)
            }
            if textRoles.contains(role), let description: String = attribute(kAXDescriptionAttribute, from: element) {
                candidates.append(description)
            }
            if textRoles.contains(role), let value = boundedTextValue(
                from: element,
                maximumLength: min(6_000, maximumCharacters)
            ) {
                candidates.append(value)
            }
            for candidate in candidates {
                let fragment = normalizedContextFragment(candidate)
                guard !fragment.isEmpty, seenFragments.insert(fragment).inserted else { continue }
                let remaining = maximumCharacters - characterCount
                guard remaining > 0 else { break }
                let bounded = String(fragment.prefix(remaining))
                fragments.append(bounded)
                characterCount += bounded.count + 1
            }

            let visibleChildren: [AXUIElement]? = attribute(kAXVisibleChildrenAttribute, from: element)
            let allChildren: [AXUIElement]? = attribute(kAXChildrenAttribute, from: element)
            let children: [AXUIElement] = if includeNonVisibleChildren {
                allChildren ?? visibleChildren ?? []
            } else if let visibleChildren, !visibleChildren.isEmpty {
                visibleChildren
            } else {
                allChildren ?? []
            }
            let remainingNodes = maximumNodes - queue.count
            if remainingNodes > 0 { queue.append(contentsOf: children.prefix(remainingNodes)) }
        }

        let context = fragments.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return context.isEmpty ? nil : context
    }

    private nonisolated static func browserTabTitles(
        from window: AXUIElement,
        maximumNodes: Int = 320,
        maximumTabs: Int = 24
    ) -> [String] {
        var queue = [window]
        var cursor = 0
        var visited = 0
        var titles: [String] = []
        var seen = Set<String>()

        while cursor < queue.count,
              !Task.isCancelled,
              visited < maximumNodes,
              titles.count < maximumTabs {
            let element = queue[cursor]
            cursor += 1
            visited += 1
            let subrole: String = attribute(kAXSubroleAttribute, from: element) ?? ""
            let roleDescription: String = attribute(kAXRoleDescriptionAttribute, from: element) ?? ""
            let identity = "\(subrole) \(roleDescription)".lowercased()
            if identity.contains("tab") {
                let candidates: [String?] = [
                    attribute(kAXTitleAttribute, from: element),
                    attribute(kAXDescriptionAttribute, from: element),
                    attribute(kAXValueAttribute, from: element)
                ]
                if let title = candidates.compactMap({ $0 })
                    .map(normalizedContextFragment)
                    .first(where: { !$0.isEmpty && $0.lowercased() != "tab" }) {
                    let bounded = String(title.prefix(180))
                    if seen.insert(bounded.lowercased()).inserted { titles.append(bounded) }
                }
            }
            let visibleChildren: [AXUIElement]? = attribute(kAXVisibleChildrenAttribute, from: element)
            let allChildren: [AXUIElement]? = attribute(kAXChildrenAttribute, from: element)
            let children = visibleChildren?.isEmpty == false ? visibleChildren! : allChildren ?? []
            let remaining = maximumNodes - queue.count
            if remaining > 0 { queue.append(contentsOf: children.prefix(remaining)) }
        }
        return titles
    }

    private nonisolated static func mailConversationRoot(
        startingAt element: AXUIElement?,
        focusedWindow: AXUIElement?
    ) -> AXUIElement? {
        guard let element else { return nil }
        var current = element
        var nearestScrollArea: AXUIElement?
        var nearestGroup: AXUIElement?

        for _ in 0..<12 {
            if let focusedWindow, CFEqual(current, focusedWindow) { break }
            if isProtectedTextElement(current) { return nil }
            let role: String = attribute(kAXRoleAttribute, from: current) ?? ""
            if role == "AXWebArea" || role == "AXDocument" || role == "AXTextArea" {
                return current
            }
            if role == "AXScrollArea", nearestScrollArea == nil {
                nearestScrollArea = current
            }
            if role == "AXGroup", nearestGroup == nil {
                nearestGroup = current
            }
            guard let parent: AXUIElement = attribute(kAXParentAttribute, from: current) else {
                break
            }
            current = parent
        }

        return nearestScrollArea ?? nearestGroup ?? element
    }

    private nonisolated static func normalizedContextFragment(_ value: String) -> String {
        let collapsed = TextInputPolicy.bounded(value, maximumUTF16Units: 6_000)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed
    }

    private nonisolated static func boundedTextValue(
        from element: AXUIElement,
        maximumLength: Int = 6_000
    ) -> String? {
        if let characterCount: NSNumber = attribute(kAXNumberOfCharactersAttribute, from: element),
           characterCount.intValue > 0,
           let rangeValue = accessibilityValue(for: CFRange(
               location: 0,
               length: min(characterCount.intValue, maximumLength)
           )) {
            var textValue: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForRangeParameterizedAttribute as CFString,
                rangeValue,
                &textValue
            ) == .success,
            let text = textValue as? String {
                return text
            }
        }
        let fallback: String? = attribute(kAXValueAttribute, from: element)
        return fallback.map {
            TextInputPolicy.bounded($0, maximumUTF16Units: maximumLength)
        }
    }

    private nonisolated static func documentLocation(from elements: [AXUIElement]) -> String? {
        for element in elements {
            if let url: URL = attribute(kAXURLAttribute, from: element),
               let location = sanitizedDocumentLocation(url.absoluteString) {
                return location
            }
            if let rawURL: String = attribute(kAXURLAttribute, from: element),
               let location = sanitizedDocumentLocation(rawURL) {
                return location
            }
            if let document: String = attribute(kAXDocumentAttribute, from: element),
               let location = sanitizedDocumentLocation(document) {
                return location
            }
        }
        return nil
    }

    nonisolated static func sanitizedDocumentLocation(_ value: String) -> String? {
        let clean = TextInputPolicy.bounded(value, maximumUTF16Units: 4_096)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let parsed = clean.hasPrefix("/") ? URL(fileURLWithPath: clean) : URL(string: clean)
        guard let parsed, let scheme = parsed.scheme?.lowercased() else { return nil }
        if scheme == "file" {
            let name = parsed.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return "file://" }
            return URL(fileURLWithPath: "/\(name)").absoluteString
        }
        guard scheme == "http" || scheme == "https",
              var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url.map { String($0.absoluteString.prefix(2_048)) }
    }

    private static func frontWindowTitle(for pid: pid_t?) -> String? {
        guard let pid,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else { return nil }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { continue }
            let title = (window[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !title.isEmpty { return title }
        }
        return nil
    }

    private nonisolated static func visibleWindowMetadata(
        preferredPID: pid_t?,
        includeChatGptDesktopContext: Bool = false
    ) -> [VisibleWindowContext] {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var seen = Set<String>()
        var countsByPID: [pid_t: Int] = [:]
        var candidates: [VisibleWindowContext] = []

        for (index, window) in windows.enumerated() {
            guard !Task.isCancelled else { return [] }
            guard let pidNumber = window[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let pid = pidNumber.int32Value
            guard pid != ownPID,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.05 else {
                continue
            }
            let owner = (window[kCGWindowOwnerName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !owner.isEmpty else { continue }
            let application = NSRunningApplication(processIdentifier: pid)
            let bundleIdentifier = application?.bundleIdentifier
            guard !excludedWorkspaceApplication(
                name: owner,
                bundleIdentifier: bundleIdentifier
            ) else { continue }
            if let bounds = window[kCGWindowBounds as String] as? [String: Any] {
                let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
                let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
                guard width >= 160, height >= 100 else { continue }
            }
            guard countsByPID[pid, default: 0] < 2 else { continue }
            let title = (window[kCGWindowName as String] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(pid):\(title ?? "")"
            guard seen.insert(key).inserted else { continue }
            countsByPID[pid, default: 0] += 1
            candidates.append(VisibleWindowContext(
                applicationName: application?.localizedName ?? owner,
                applicationBundleIdentifier: bundleIdentifier,
                applicationPID: pid,
                windowTitle: title?.isEmpty == false ? title : nil,
                sourceURL: nil,
                accessibleText: nil,
                frontToBackIndex: index,
                isPreferred: pid == preferredPID
            ))
        }
        let ranked = candidates.sorted { left, right in
            if left.isPreferred != right.isPreferred { return left.isPreferred }
            return left.frontToBackIndex < right.frontToBackIndex
        }
        var bounded = Array(ranked.prefix(12))
        if includeChatGptDesktopContext,
           let chatGptWindow = ranked.first(where: VisibleWorkspaceContext.isChatGptDesktopWindow),
           !bounded.contains(where: {
               $0.applicationPID == chatGptWindow.applicationPID
                   && $0.windowTitle == chatGptWindow.windowTitle
           }) {
            if bounded.count == 12 { bounded.removeLast() }
            bounded.append(chatGptWindow)
        }
        return bounded
    }

    private nonisolated static func accessibilityWindow(
        matching candidate: VisibleWindowContext,
        in windows: [AXUIElement],
        root: AXUIElement
    ) -> AXUIElement? {
        let usable = windows.filter {
            let minimized: Bool = attribute(kAXMinimizedAttribute, from: $0) ?? false
            return !minimized
        }
        if let expected = candidate.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !expected.isEmpty,
           let exact = usable.first(where: {
               let title: String = attribute(kAXTitleAttribute, from: $0) ?? ""
               return title.compare(expected, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
           }) {
            return exact
        }
        if candidate.isPreferred,
           let focused: AXUIElement = attribute(kAXFocusedWindowAttribute, from: root) {
            return focused
        }
        return usable.first
    }

    private nonisolated static func excludedWorkspaceApplication(
        name: String,
        bundleIdentifier: String?
    ) -> Bool {
        let identity = "\(name) \(bundleIdentifier ?? "")".lowercased()
        let excluded = [
            "scholia", "windowserver", "window server", "control center", "notificationcenter",
            "notification center", "systemuiserver", "dock", "1password", "bitwarden", "lastpass",
            "dashlane", "keepass", "keychain", "password"
        ]
        return excluded.contains { identity.contains($0) }
    }

    private nonisolated static func likelyLatex(_ value: String) -> Bool {
        guard value.count < 4_000 else { return false }
        let signals = ["\\frac", "\\sum", "\\int", "\\sqrt", "$$", "∫", "∑", "√", "≤", "≥", "≠"]
        return signals.contains { value.contains($0) }
            || (value.count >= 3 && value.hasPrefix("$") && value.hasSuffix("$"))
            || (value.hasPrefix("\\(") && value.hasSuffix("\\)"))
            || (value.hasPrefix("\\[") && value.hasSuffix("\\]"))
            || (value.contains("^") && value.contains("_"))
    }

    private nonisolated static func attribute<T>(_ name: String, from element: AXUIElement) -> T? {
        guard !Task.isCancelled else { return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard result == .success else { return nil }
        return value as? T
    }
}

@MainActor
private struct PasteboardSnapshot {
    private struct Item {
        var values: [(NSPasteboard.PasteboardType, Data)]
    }

    private var items: [Item]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored: [NSPasteboardItem] = items.map { item in
            let pasteboardItem = NSPasteboardItem()
            for (type, data) in item.values { pasteboardItem.setData(data, forType: type) }
            return pasteboardItem
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
