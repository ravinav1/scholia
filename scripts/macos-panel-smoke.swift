@preconcurrency import AppKit
import SwiftUI
@testable import ScholiaMac

@main
@MainActor
struct PanelLayoutSmoke {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        URLProtocol.registerClass(QuickChatStreamFixtureProtocol.self)
        Task { @MainActor in
            do {
                let smoke = PanelLayoutSmoke()
                if CommandLine.arguments.contains("--rich-code-only") {
                    try await smoke.testRichCodeAndActivity(); exit(0)
                }
                let modelIDs = ["gpt-5-mini", "gpt-6-luna", "gpt-6-astra", "gpt-5.6", "gpt-6-sol"]
                let modelOrder = ModelPickerOrder.sorted(modelIDs.map { ModelDefinition(id: $0, label: $0) }, verified: ["gpt-5-mini", "gpt-6-sol"])
                precondition(modelOrder.map(\.id) == ["gpt-6-sol", "gpt-5-mini", "gpt-6-astra", "gpt-5.6", "gpt-6-luna"], "Verified models lead; capacity and newest versions order each group")
                let opusOrder = ModelPickerOrder.sorted(["claude-opus-4-7", "claude-opus-4-10", "claude-opus-4-8"].map { ModelDefinition(id: $0, label: $0) }, verified: [])
                precondition(opusOrder.first?.id == "claude-opus-4-10", "Version ordering must be numeric")
                try await smoke.testContentChangesCannotResizeAppKitOwnedPanel()
                try await smoke.testQuickChatPromptAndAnswerKeepTheirExplicitSizes()
                try await smoke.testQuickAskReceivesTypingDuringModalSession()
                try await smoke.testQuickAskFocusReturnsOnReopen()
                try await smoke.testQuickAskComposerReceivesClicks()
                try await smoke.testQuickAskDraftWhileResponseStreams()
                try await smoke.testRichCodeAndActivity()
                try await smoke.testModelTestingKeepsPopoverAnchored()
                print("PASS: panel sizes, compact prompt, modal/reopen/click typing, paste and editable drafts while answers stream")
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        app.run()
    }

    func testRichCodeAndActivity() async throws {
        let code = "\nfunc square(_ value: Int) -> Int {\n    value * value\n}\n"
        let source = "# Code and equations\n\nInline math: $E = mc^2$.\n\n```swift\n" + code + "\n```\n\n```latex\n\\frac{a}{b} + \\sqrt{x}\n```\n\n$$\\int_0^1 x^2 \\, dx = \\frac{1}{3}$$"
        let rendered = RichMarkdownDocumentRenderer(compact: false, colorScheme: .light, availableWidth: 570).render(source)
        var copied: [String] = []
        rendered.enumerateAttribute(NSAttributedString.Key("ScholiaCodeSource"), in: NSRange(location: 0, length: rendered.length)) { value, _, _ in
            if let value = value as? String { copied.append(value) }
        }
        precondition(copied.first == code && copied.count == 2, "Code copy must preserve indentation, leading/trailing blank lines and literal LaTeX")
        precondition(!NativeCodeHighlight.runs(code, language: "swift").isEmpty)
        precondition(!NativeCodeHighlight.runs("\\frac{a}{b}", language: "latex").isEmpty)
        var message = ConversationMessage(role: .assistant, content: source)
        message.recordActivity("Read saved file", detail: "Assignment.pdf · page 2")
        message.recordActivity("Read saved file", detail: "Assignment.pdf · page 2")
        message.recordActivity("Answer complete", detail: "Fixture model")
        precondition(message.activity?.count == 2)
        let roundtrip = try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(message))
        precondition(roundtrip.activity == message.activity && StoredConversation.sanitizedMessages([message]).first?.activity == message.activity)
        let size = NSSize(width: 630, height: 600)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let pasteboard = NSPasteboard.general
        let previous = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        var copyChange = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == copyChange {
                pasteboard.clearContents()
                pasteboard.writeObjects(previous.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                })
            }
        }
        for scheme in [ColorScheme.light, .dark] {
            var codeView: SelfSizingTextView?
            panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            panel.contentViewController = PanelContentController(rootView: ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ConversationActivityView(events: message.activity ?? [])
                    RichMarkdownView(source: source, registerSelectionView: { codeView = $0 })
                }.padding(22)
            }.background(scheme == .dark ? Color(white: 0.12) : .white).environment(\.colorScheme, scheme), size: size)
            panel.center(); panel.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(350))
            let textView = try unwrap(codeView)
            let storage = try unwrap(textView.textStorage)
            let layout = try unwrap(textView.layoutManager)
            let container = try unwrap(textView.textContainer)
            layout.ensureLayout(for: container)
            var controls: [(NSRange, String)] = []
            storage.enumerateAttribute(NSAttributedString.Key("ScholiaCodeSource"), in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                if let value = value as? String { controls.append((range, value)) }
            }
            precondition(controls.count == 2)
            for (range, expected) in controls {
                let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                let bounds = layout.boundingRect(forGlyphRange: glyphs, in: container)
                let point = NSPoint(x: bounds.midX + textView.textContainerOrigin.x, y: bounds.midY + textView.textContainerOrigin.y)
                precondition(textView.codeSource(at: point) == expected, "The visible Copy code label must have a working hit target")
                precondition(textView.codeSource(at: NSPoint(x: point.x, y: point.y + bounds.height + 4)) == nil, "Code selection must not trigger copy")
                let click = try unwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: textView.convert(point, to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                precondition(textView.acceptsFirstMouse(for: click), "Copy must work on the first click in an inactive window")
                textView.setSelectedRange(NSRange(location: 0, length: 4))
                panel.sendEvent(click)
                copyChange = pasteboard.changeCount
                precondition(pasteboard.string(forType: .string) == expected, "A real mouse click must copy the exact source")
                precondition(textView.selectedRange() == NSRange(location: 0, length: 4), "Copy must preserve text selection")
            }
            try savePreview(panel, name: scheme == .dark ? "rich-code-activity-native-dark.png" : "rich-code-activity-native.png")
        }
        print("PASS: native verified-first model sorting, shared programming/LaTeX highlighting, exact code copy and persisted activity timeline")
    }
    @MainActor
    func testContentChangesCannotResizeAppKitOwnedPanel() async throws {
        _ = NSApplication.shared
        let state = LayoutState()
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: 520, height: 230),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        let controller = PanelContentController(
            rootView: ChangingContent(state: state),
            size: panel.frame.size
        )
        panel.contentViewController = controller
        panel.minSize = NSSize(width: 480, height: 200)
        panel.maxSize = NSSize(width: 680, height: 580)
        panel.orderFrontRegardless()
        defer { panel.close() }

        // Exercise actual display cycles: synchronous layoutIfNeeded alone misses
        // the windowDidLayout -> updateAnimatedWindowSize crash from macOS 27.
        for index in 0..<12 {
            let size = index.isMultiple(of: 2)
                ? NSSize(width: 520, height: 230)
                : NSSize(width: 640, height: 480)
            panel.setContentSize(size)
            let expectedFrame = panel.frame
            state.expanded.toggle()
            try await Task.sleep(for: .milliseconds(80))

            expectEqual(panel.frame, expectedFrame)
            expectEqual(panel.minSize, NSSize(width: 480, height: 200))
            expectEqual(panel.maxSize, NSSize(width: 680, height: 580))
            let hostedView = try unwrap(controller.view.subviews.first)
            expectEqual(hostedView.frame, controller.view.bounds)
        }
    }

    @MainActor
    func testQuickChatPromptAndAnswerKeepTheirExplicitSizes() async throws {
        _ = NSApplication.shared
        let controller = QuickAskPanelController(model: AppModel.shared)
        let panel = try unwrap(controller.window)
        defer {
            controller.hide()
            panel.orderOut(nil)
        }

        for _ in 0..<3 {
            controller.showPrompt()
            try await Task.sleep(for: .milliseconds(350))
            expectEqual(panel.frame.size, NSSize(width: 520, height: 224))
            expectEqual(panel.maxSize, panel.minSize)

            controller.showAnswer()
            try await Task.sleep(for: .milliseconds(350))
            precondition(panel.frame.width >= 480)
            precondition(panel.frame.height >= 420)
            precondition(panel.frame.width <= 680)
            precondition(panel.frame.height <= 580)
            precondition(panel.styleMask.contains(.resizable))
        }
    }

    @MainActor
    func testModelTestingKeepsPopoverAnchored() async throws {
        let model = AppModel.shared, saved = model.settings
        model.settings = AppSettings()
        model.settings.providerID = "ollama"
        model.settings.endpoints["ollama"] = "https://scholia-quick-chat.invalid/api/chat"
        let controller = QuickAskPanelController(model: model)
        controller.showPrompt()
        let panel = try unwrap(controller.window), anchor = try unwrap(panel.contentView)
        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView:
            ScholiaModelPickerPopover(isPresented: .constant(true), providerID: "ollama").environmentObject(model))
        try await Task.sleep(for: .milliseconds(300))
        popover.show(relativeTo: NSRect(x: 200, y: 60, width: 100, height: 22), of: anchor, preferredEdge: .minY)
        defer {
            model.cancelModelTest(); popover.close(); controller.hide()
            model.settings = saved; AppSettingsStore.save(saved)
        }
        try await Task.sleep(for: .milliseconds(250))
        let window = try unwrap(popover.contentViewController?.view.window)
        let promptFrame = panel.frame, popupFrame = window.frame
        model.testModel(model.activeModel, providerID: "ollama")
        try await Task.sleep(for: .milliseconds(250))
        precondition(model.isTestingProvider)
        expectEqual(panel.frame, promptFrame)
        expectEqual(window.frame, popupFrame)
        model.cancelModelTest()
        try await Task.sleep(for: .milliseconds(250))
        expectEqual(panel.frame, promptFrame)
        expectEqual(window.frame, popupFrame)
        try savePreview(window, name: "quick-ask-model-test-native.png")
        print("PASS: model testing and cancellation keep both Quick Ask and its model picker anchored")
    }

    @MainActor
    func testQuickAskReceivesTypingDuringModalSession() async throws {
        let app = NSApplication.shared
        let modal = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 250),
            styleMask: [.titled], backing: .buffered, defer: false)
        modal.isReleasedWhenClosed = false
        let session = app.beginModalSession(for: modal)
        let model = AppModel.shared
        model.quickDraft = ""
        let controller = QuickAskPanelController(model: model)
        let panel = try unwrap(controller.window)
        defer {
            model.quickDraft = ""
            controller.hide()
            panel.orderOut(nil)
            app.endModalSession(session)
            modal.close()
        }
        _ = app.runModalSession(session)
        controller.showPrompt()
        try await Task.sleep(for: .milliseconds(350))
        guard let editor = panel.firstResponder as? BoundedComposerTextView else {
            preconditionFailure("Quick Ask did not focus its composer")
        }
        let event = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        let nativePanel = try unwrap(panel as? NSPanel)
        precondition(nativePanel.worksWhenModal, "Quick Ask must accept input while a modal dialog is open")
        app.postEvent(event, atStart: false)
        _ = app.runModalSession(session)
        try await Task.sleep(for: .milliseconds(80))
        expectEqual(editor.string, "x")
        expectEqual(model.quickDraft, "x")
    }

    @MainActor
    func testQuickAskFocusReturnsOnReopen() async throws {
        let model = AppModel.shared
        defer { model.dismissQuickAsk() }
        for _ in 0..<3 {
            model.showQuickAsk()
            try await Task.sleep(for: .milliseconds(350))
            let panel = try unwrap(NSApplication.shared.windows.first {
                $0.title == "Scholia Quick Chat" && $0.isVisible
            })
            guard let editor = panel.firstResponder as? BoundedComposerTextView else {
                preconditionFailure("Reopening Quick Ask did not restore composer focus")
            }
            let event = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
            panel.sendEvent(event)
            expectEqual(editor.string, "x")
            expectEqual(model.quickDraft, "x")
            let selectAll = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
            precondition(panel.performKeyEquivalent(with: selectAll), "Quick Ask did not handle Command-A")
            expectEqual(editor.selectedRange(), NSRange(location: 0, length: 1))
            editor.insertText("replacement", replacementRange: editor.selectedRange())
            expectEqual(model.quickDraft, "replacement")
            var attachmentPasteCount = 0
            editor.onPasteAttachment = { attachmentPasteCount += 1; return true }
            let paste = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
            precondition(panel.performKeyEquivalent(with: paste), "Quick Ask did not handle Command-V")
            expectEqual(attachmentPasteCount, 1)
            model.dismissQuickAsk()
            // The hosted view survives hiding. Reopening must focus it even
            // after another responder displaced the editor in the meantime.
            panel.makeFirstResponder(nil)
            try await Task.sleep(for: .milliseconds(180))
        }
    }

    @MainActor
    func testQuickAskComposerReceivesClicks() async throws {
        let model = AppModel.shared
        model.showQuickAsk()
        defer { model.dismissQuickAsk() }
        try await Task.sleep(for: .milliseconds(350))
        let panel = try unwrap(NSApplication.shared.windows.first {
            $0.title == "Scholia Quick Chat" && $0.isVisible
        })
        let editor = try unwrap(panel.firstResponder as? BoundedComposerTextView)
        let scroll = try unwrap(editor.enclosingScrollView)
        try savePreview(panel, name: "quick-ask-prompt-native.png")
        let point = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        panel.makeFirstResponder(nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try unwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApplication.shared.postEvent(event, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(100))
        precondition(panel.firstResponder === editor,
            "Clicking the empty Quick Chat composer must restore its keyboard focus")
        let key = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        NSApplication.shared.postEvent(key, atStart: false)
        try await Task.sleep(for: .milliseconds(80))
        expectEqual(model.quickDraft, "x")
    }

    @MainActor
    func testQuickAskDraftWhileResponseStreams() async throws {
        let model = AppModel.shared
        let settings = model.settings
        defer {
            model.dismissQuickAsk()
            model.settings = settings
            model.quickDraft = ""
        }
        model.settings = AppSettings()
        model.settings.providerID = "ollama"
        model.settings.endpoints["ollama"] = "https://scholia-quick-chat.invalid/api/chat"
        model.showQuickAsk()
        model.quickContextEnabled = false
        model.quickDraft = "Controlled local input fixture"
        model.submitQuickAsk()
        try await Task.sleep(for: .milliseconds(500))
        precondition(model.isQuickAskStreaming, "The isolated streaming fixture must still be active")
        let panel = try unwrap(NSApplication.shared.windows.first {
            $0.title == "Scholia Quick Chat" && $0.isVisible
        })
        let editor = try unwrap(panel.firstResponder as? BoundedComposerTextView)
        precondition(editor.isEditable, "A running answer must not disable the next Quick Chat draft")
        let key = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        NSApplication.shared.postEvent(key, atStart: false)
        try await Task.sleep(for: .milliseconds(80))
        expectEqual(model.quickDraft, "x")
        let pasteboard = NSPasteboard.general
        let previous = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        pasteboard.clearContents()
        pasteboard.setString(" pasted draft", forType: .string)
        let pasteChange = pasteboard.changeCount
        defer {
            if pasteboard.changeCount == pasteChange {
                pasteboard.clearContents()
                pasteboard.writeObjects(previous.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                })
            }
        }
        let paste = try unwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
            context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        precondition(panel.performKeyEquivalent(with: paste))
        expectEqual(model.quickDraft, "x pasted draft")
        let messageCount = model.quickMessages.count
        model.submitQuickAsk()
        expectEqual(model.quickMessages.count, messageCount)
        expectEqual(model.quickDraft, "x pasted draft")
        try savePreview(panel, name: "quick-chat-streaming-draft-native.png")
        model.cancelQuickAsk()
        try await Task.sleep(for: .milliseconds(80))
        expectEqual(model.quickDraft, "x pasted draft")
        precondition(editor.isEditable)
    }

    @MainActor
    private func savePreview(_ panel: NSWindow, name: String) throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "apps/macos/.build/verification", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let view = try unwrap(panel.contentView)
        let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try unwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name))
    }
}

/// No external provider is contacted; keep an isolated Ollama-format response open until Cancel.
private final class QuickChatStreamFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "scholia-quick-chat.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/x-ndjson"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"message\":{\"role\":\"assistant\",\"content\":\"A fixture answer is still arriving.\"},\"done\":false}\n".utf8))
    }
    override func stopLoading() {}
}

@MainActor
private final class LayoutState: ObservableObject {
    @Published var expanded = false
}

private struct ChangingContent: View {
    @ObservedObject var state: LayoutState

    var body: some View {
        VStack {
            Text(state.expanded ? String(repeating: "Wide content ", count: 30) : "Prompt")
                .fixedSize()
            if state.expanded {
                Color.clear.frame(width: 900, height: 700)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.04), value: state.expanded)
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T) {
    precondition(actual == expected, "Expected \(expected), got \(actual)")
}

private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw CocoaError(.validationMissingMandatoryProperty) }
    return value
}
