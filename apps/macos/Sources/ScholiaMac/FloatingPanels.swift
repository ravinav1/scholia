@preconcurrency import AppKit
@preconcurrency import CoreGraphics
import SwiftUI
import Combine

enum QuickChatThinkingCycleDirection: Equatable, Sendable {
    case forward
    case backward
}

func quickChatThinkingCycleDirection(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags
) -> QuickChatThinkingCycleDirection? {
    guard keyCode == 48 else { return nil }
    let relevantFlags = modifierFlags.intersection([.command, .shift, .option, .control])
    if relevantFlags == [.command] { return .forward }
    if relevantFlags == [.command, .shift] { return .backward }
    return nil
}

func quickChatWindowCollectionBehavior() -> NSWindow.CollectionBehavior {
    [
        .canJoinAllSpaces,
        // Unlike fullScreenAuxiliary alone, this lets the overlay join a different app's full-screen set.
        .canJoinAllApplications,
        .fullScreenAuxiliary,
        .participatesInCycle
    ]
}

@MainActor
final class ExplanationPanelController: NSWindowController, NSWindowDelegate {
    private let panel: ExplanationWindow
    private let selectionRegions: AnswerSelectionRegistry
    private weak var model: AppModel?
    private var participatesInWindowSwitcher = false
    private var hasPositioned = false
    private var visibilityAnimationID = UUID()
    private var localEventMonitor: Any?
    private var responseSelectionTask: Task<Void, Never>?
    private var responseSelectionDragMessageID: UUID?
    private var selectedResponseMessageID: UUID?
    private lazy var responseSelectionPill = SelectionPillController(
        initialOffset: .zero,
        onMove: { _ in },
        onExplain: { [weak self] capture, point, question in
            guard let self, let messageID = self.selectedResponseMessageID else { return }
            self.selectedResponseMessageID = nil
            self.model?.explainConversationResponseSelection(
                capture: capture,
                parentMessageID: messageID,
                near: point,
                question: question
            )
        }
    )

    init(model: AppModel) {
        self.model = model
        let selectionRegions = AnswerSelectionRegistry()
        self.selectionRegions = selectionRegions
        panel = ExplanationWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Scholia"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 440, height: 420)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentViewController = PanelContentController(
            rootView: ExplanationPanelView(selectionRegions: selectionRegions).environmentObject(model),
            size: panel.contentLayoutRect.size
        )
        super.init(window: panel)
        panel.delegate = self
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .scrollWheel]
        ) { [weak self] event in
            self?.handleLocalEvent(event)
            return event
        }
        updateWindowBehavior(
            alwaysOnTop: model.settings.resolvedKeepExplanationWindowOnTop,
            participatesInWindowSwitcher: model.settings.resolvedShowExplanationWindowInWindowSwitcher
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(near point: NSPoint?) {
        model?.applicationWindowOpened()
        let wasVisible = panel.isVisible
        if !wasVisible, !participatesInWindowSwitcher || !hasPositioned {
            position(near: point ?? NSEvent.mouseLocation)
            hasPositioned = true
        }
        NSApp.activate()
        visibilityAnimationID = UUID()
        if !wasVisible, ScholiaVisualStyle.appKitAnimationsEnabled { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        guard !wasVisible else { return }
        guard ScholiaVisualStyle.appKitAnimationsEnabled else {
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
        }
    }

    func updateWindowBehavior(alwaysOnTop: Bool, participatesInWindowSwitcher: Bool) {
        self.participatesInWindowSwitcher = participatesInWindowSwitcher
        panel.participatesInNormalWindowManagement = participatesInWindowSwitcher
        panel.level = alwaysOnTop ? .floating : .normal
        panel.isExcludedFromWindowsMenu = !participatesInWindowSwitcher
        panel.collectionBehavior = participatesInWindowSwitcher
            ? [.managed, .participatesInCycle, .fullScreenAuxiliary]
            : [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        for buttonType in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton
        ] {
            panel.standardWindowButton(buttonType)?.isHidden = !participatesInWindowSwitcher
        }
    }

    func hide() {
        hideResponseSelection()
        guard panel.isVisible else { return }
        guard ScholiaVisualStyle.appKitAnimationsEnabled else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        let animationID = UUID()
        visibilityAnimationID = animationID
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.visibilityAnimationID == animationID else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model?.closeConversation()
        return false
    }

    private func hideResponseSelection() {
        responseSelectionTask?.cancel()
        responseSelectionTask = nil
        responseSelectionDragMessageID = nil
        selectedResponseMessageID = nil
        responseSelectionPill.hide()
    }

    private func handleLocalEvent(_ event: NSEvent) {
        guard panel.isVisible else { return }
        if event.type == .scrollWheel {
            hideResponseSelection()
            return
        }
        guard event.window === panel, let model, !model.isStreaming else { return }
        let answerIDs = Set(model.messages.lazy
            .filter { $0.role == .assistant && !$0.isStreaming }
            .map(\.id))
        if event.type == .leftMouseDown {
            hideResponseSelection()
            responseSelectionDragMessageID = selectionRegions.messageID(
                at: NSEvent.mouseLocation,
                among: answerIDs
            )
            return
        }
        let point = NSEvent.mouseLocation
        let messageID = selectionRegions.messageID(at: point, among: answerIDs)
            ?? responseSelectionDragMessageID
        responseSelectionDragMessageID = nil
        guard let messageID else {
            hideResponseSelection()
            return
        }
        responseSelectionTask?.cancel()
        responseSelectionPill.hide()
        selectedResponseMessageID = nil
        responseSelectionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self,
                  self.panel.isVisible,
                  self.model?.isStreaming != true,
                  self.model?.messages.contains(where: {
                      $0.id == messageID && $0.role == .assistant && !$0.isStreaming
                  }) == true,
                  let capture = self.selectionRegions.capture(
                      for: messageID,
                      windowTitle: "Chat response"
                  ),
                  let text = capture.text, text.count >= 2 else { return }
            self.selectedResponseMessageID = messageID
            self.responseSelectionPill.show(capture: capture, near: point)
        }
    }

    private func position(near point: NSPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        let preferredX = point.x + 18
        let x = min(max(preferredX, visible.minX + 12), visible.maxX - size.width - 12)
        let preferredY = point.y - size.height / 2
        let y = min(max(preferredY, visible.minY + 12), visible.maxY - size.height - 12)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
private final class ExplanationWindow: NSWindow {
    var participatesInNormalWindowManagement = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { participatesInNormalWindowManagement }
}

@MainActor
private final class QuickChatWindow: NSPanel {
    var commandTabHandler: ((QuickChatThinkingCycleDirection) -> Bool)?
    var closeHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let relevantFlags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if relevantFlags == [.command], event.charactersIgnoringModifiers?.lowercased() == "w" {
            closeHandler?()
            return true
        }
        if let direction = quickChatThinkingCycleDirection(
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags
        ), commandTabHandler?(direction) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class AnswerSelectionRegistry {
    private final class WeakView {
        weak var value: SelfSizingTextView?
        init(_ value: SelfSizingTextView) { self.value = value }
    }

    private var views: [UUID: WeakView] = [:]

    func register(_ view: SelfSizingTextView, for messageID: UUID) {
        views = views.filter { $0.key == messageID || $0.value.value !== view }
        views[messageID] = WeakView(view)
    }

    func capture(for messageID: UUID, windowTitle: String) -> CapturedContent? {
        guard let text = views[messageID]?.value?.selectedPlainText() else { return nil }
        return CapturedContent(
            kind: SelectionReader.kind(for: text),
            text: text,
            applicationName: "Scholia",
            applicationBundleIdentifier: Bundle.main.bundleIdentifier,
            applicationPID: ProcessInfo.processInfo.processIdentifier,
            windowTitle: windowTitle
        )
    }

    func messageID(at screenPoint: NSPoint, among allowedMessageIDs: Set<UUID>) -> UUID? {
        views = views.filter { $0.value.value != nil }
        return views.first { messageID, reference in
            guard allowedMessageIDs.contains(messageID) else { return false }
            guard let view = reference.value,
                  let window = view.window,
                  !view.isHidden,
                  !view.visibleRect.isEmpty else { return false }
            let windowRect = view.convert(view.visibleRect, to: nil)
            return window.convertToScreen(windowRect).contains(screenPoint)
        }?.key
    }
}

@MainActor
final class QuickAskPanelController: NSWindowController, NSWindowDelegate {
    private enum LayoutMode {
        case prompt
        case answer
    }

    private static let panelWidth: CGFloat = 520
    private static let promptHeight: CGFloat = 224
    private static let answerHeight: CGFloat = 480
    private static let minimumAnswerSize = NSSize(width: 480, height: 420)
    private static let maximumAnswerSize = NSSize(width: 680, height: 580)
    private static let answerWidthDefaultsKey = "quickAskPanel.answerWidth.v3"
    private static let answerHeightDefaultsKey = "quickAskPanel.answerHeight.v3"
    private let panel: QuickChatWindow
    private let selectionRegions: AnswerSelectionRegistry
    private weak var model: AppModel?
    private var layoutMode = LayoutMode.prompt
    private var preferredAnswerSize: NSSize
    private var visibilityAnimationID = UUID()
    private var localEventMonitor: Any?
    private var promptLayoutObservation: AnyCancellable?
    private var commandTabObservation: AnyCancellable?
    private var acceptsCommandTab = false
    private lazy var commandTabEventTap = QuickChatCommandTabEventTap { [weak self] direction in
        guard let self, self.panel.isVisible, self.panel.isKeyWindow,
              let model = self.model, model.quickAskThinkingIsAvailable,
              !model.isQuickAskStreaming else { return }
        model.cycleQuickAskThinkingProfile(reverse: direction == .backward)
    }
    private var responseSelectionTask: Task<Void, Never>?
    private var responseSelectionDragMessageID: UUID?
    private var selectedResponseMessageID: UUID?
    private lazy var responseSelectionPill = SelectionPillController(
        initialOffset: .zero,
        onMove: { _ in },
        onExplain: { [weak self] capture, _, question in
            guard let self, let messageID = self.selectedResponseMessageID else { return }
            self.selectedResponseMessageID = nil
            self.model?.explainQuickResponseSelection(
                capture: capture,
                parentMessageID: messageID,
                question: question
            )
        }
    )

    init(model: AppModel) {
        self.model = model
        preferredAnswerSize = Self.loadPreferredAnswerSize()
        let selectionRegions = AnswerSelectionRegistry()
        self.selectionRegions = selectionRegions
        panel = QuickChatWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.promptHeight),
            // A nonactivating panel can take keyboard focus in another app's full-screen Space.
            // This must be set at creation time so AppKit installs the panel's focus behavior.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Scholia Quick Chat"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        // Quick Ask remains available from its global shortcut while a workspace
        // sheet is open. Otherwise AppKit shows the panel but blocks its input.
        panel.worksWhenModal = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = false
        panel.collectionBehavior = quickChatWindowCollectionBehavior()
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.contentViewController = PanelContentController(
            rootView: QuickAskPanelView(selectionRegions: selectionRegions).environmentObject(model),
            size: NSSize(width: Self.panelWidth, height: Self.promptHeight)
        )
        super.init(window: panel)
        panel.delegate = self
        panel.commandTabHandler = { [weak model] direction in
            guard let model,
                  model.quickAskThinkingIsAvailable,
                  !model.isQuickAskStreaming else { return false }
            model.cycleQuickAskThinkingProfile(reverse: direction == .backward)
            return true
        }
        panel.closeHandler = { [weak model] in model?.dismissQuickAsk() }
        commandTabObservation = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.updateCommandTabEventTap() }
        promptLayoutObservation = model.$quickDraftAttachments.map { !$0.isEmpty }
            .combineLatest(model.$quickAskError.map { $0 != nil })
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] state in
                DispatchQueue.main.async {
                    self?.resizePrompt(hasAttachments: state.0, hasError: state.1)
                }
            }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .leftMouseUp, .scrollWheel]
        ) { [weak self] event in
            if self?.handleQuickChatKeyEvent(event) == true { return nil }
            self?.handleLocalEvent(event)
            return event
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showPrompt() {
        acceptsCommandTab = true
        hideResponseSelection()
        layoutMode = .prompt
        panel.styleMask.remove(.resizable)
        resizePrompt(hasAttachments: model?.quickDraftAttachments.isEmpty == false, hasError: model?.quickAskError != nil)
        position()
        model?.quickChatWindowVisibilityDidChange(true)
        panel.deminiaturize(nil)
        presentPanel()
        updateCommandTabEventTap()
    }

    func showAnswer() {
        acceptsCommandTab = true
        layoutMode = .answer
        panel.styleMask.insert(.resizable)
        panel.maxSize = Self.maximumAnswerSize
        panel.minSize = Self.minimumAnswerSize
        resize(to: answerSizeFittedToActiveScreen())
        position()
        model?.quickChatWindowVisibilityDidChange(true)
        panel.deminiaturize(nil)
        presentPanel()
        updateCommandTabEventTap()
    }

    func hide() {
        hideResponseSelection()
        acceptsCommandTab = false
        commandTabEventTap.stop()
        model?.quickChatWindowVisibilityDidChange(false)
        animatePanelOut()
    }

    func hideResponseSelection() {
        responseSelectionTask?.cancel()
        responseSelectionTask = nil
        responseSelectionDragMessageID = nil
        selectedResponseMessageID = nil
        responseSelectionPill.hide()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        acceptsCommandTab = false
        model?.cancelQuickAsk()
        hideResponseSelection()
        commandTabEventTap.stop()
        model?.quickChatWindowVisibilityDidChange(false)
        animatePanelOut()
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateCommandTabEventTap()
    }

    func windowDidResignKey(_ notification: Notification) {
        commandTabEventTap.stop()
    }

    private func updateCommandTabEventTap() {
        if acceptsCommandTab, panel.isVisible, panel.isKeyWindow,
           model?.quickAskThinkingIsAvailable == true, model?.isQuickAskStreaming == false {
            commandTabEventTap.start()
        } else {
            commandTabEventTap.stop()
        }
    }

    private func handleQuickChatKeyEvent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              panel.isVisible,
              panel.isKeyWindow,
              event.window == nil || event.window === panel,
              let direction = quickChatThinkingCycleDirection(
                  keyCode: event.keyCode,
                  modifierFlags: event.modifierFlags
              ) else { return false }
        guard let model,
              model.quickAskThinkingIsAvailable,
              !model.isQuickAskStreaming else { return false }
        model.cycleQuickAskThinkingProfile(reverse: direction == .backward)
        return true
    }

    private func handleLocalEvent(_ event: NSEvent) {
        guard panel.isVisible else { return }
        if event.type == .scrollWheel {
            hideResponseSelection()
            return
        }
        guard layoutMode == .answer, event.window === panel else { return }
        guard model?.isQuickAskStreaming != true, let model else {
            hideResponseSelection()
            return
        }
        let answerIDs = Set(model.quickMessages.lazy
            .filter { $0.role == .assistant && !$0.isStreaming }
            .map(\.id))
        if event.type == .leftMouseDown {
            hideResponseSelection()
            responseSelectionDragMessageID = selectionRegions.messageID(
                at: NSEvent.mouseLocation,
                among: answerIDs
            )
            return
        }
        let point = NSEvent.mouseLocation
        let messageID = selectionRegions.messageID(at: point, among: answerIDs)
            ?? responseSelectionDragMessageID
        responseSelectionDragMessageID = nil
        guard let messageID else {
            hideResponseSelection()
            return
        }
        responseSelectionTask?.cancel()
        responseSelectionPill.hide()
        selectedResponseMessageID = nil
        responseSelectionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self,
                  self.panel.isVisible,
                  self.model?.isQuickAskStreaming != true,
                  self.model?.quickMessages.contains(where: {
                      $0.id == messageID && $0.role == .assistant && !$0.isStreaming
                  }) == true,
                  let capture = self.selectionRegions.capture(
                      for: messageID,
                      windowTitle: "Quick Chat explanation layer \((self.model?.quickLayerDepth ?? 0) + 1)"
                  ),
                  let text = capture.text, text.count >= 2 else { return }
            self.selectedResponseMessageID = messageID
            self.responseSelectionPill.show(capture: capture, near: point)
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard layoutMode == .answer else { return }
        preferredAnswerSize = panel.frame.size
        let defaults = UserDefaults.standard
        defaults.set(Double(preferredAnswerSize.width), forKey: Self.answerWidthDefaultsKey)
        defaults.set(Double(preferredAnswerSize.height), forKey: Self.answerHeightDefaultsKey)
    }

    private func resize(to size: NSSize) {
        var frame = panel.frame
        let top = frame.maxY
        frame.size = size
        frame.origin.y = top - size.height
        guard panel.isVisible else {
            panel.setFrame(frame, display: true)
            return
        }
        guard ScholiaVisualStyle.appKitAnimationsEnabled else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func resizePrompt(hasAttachments: Bool, hasError: Bool) {
        guard layoutMode == .prompt else { return }
        // AppKit owns the size; only actual attachment/error rows add height.
        let height = Self.promptHeight + (hasAttachments ? 40 : 0) + (hasError ? 58 : 0)
        let size = NSSize(width: Self.panelWidth, height: height)
        panel.minSize = size
        panel.maxSize = size
        if panel.frame.size != size { resize(to: size) }
    }

    private func presentPanel() {
        // Keep the current application/Space active; the panel takes key focus on its own.
        // Activating Scholia here can switch back to a desktop before the overlay is ordered.
        let wasVisible = panel.isVisible
        visibilityAnimationID = UUID()
        panel.collectionBehavior = quickChatWindowCollectionBehavior()
        if !wasVisible, ScholiaVisualStyle.appKitAnimationsEnabled { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        guard !wasVisible else { return }
        guard ScholiaVisualStyle.appKitAnimationsEnabled else {
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
        }
    }

    private func animatePanelOut() {
        guard panel.isVisible else { return }
        guard ScholiaVisualStyle.appKitAnimationsEnabled else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        let animationID = UUID()
        visibilityAnimationID = animationID
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.visibilityAnimationID == animationID else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
        })
    }

    private func answerSizeFittedToActiveScreen() -> NSSize {
        guard let visible = activeScreen?.visibleFrame else { return preferredAnswerSize }
        return NSSize(
            width: min(
                preferredAnswerSize.width,
                Self.maximumAnswerSize.width,
                max(Self.minimumAnswerSize.width, visible.width - 24)
            ),
            height: min(
                preferredAnswerSize.height,
                Self.maximumAnswerSize.height,
                max(Self.minimumAnswerSize.height, visible.height - 24)
            )
        )
    }

    private static func loadPreferredAnswerSize() -> NSSize {
        let defaults = UserDefaults.standard
        let storedWidth = defaults.object(forKey: answerWidthDefaultsKey) == nil
            ? panelWidth
            : CGFloat(defaults.double(forKey: answerWidthDefaultsKey))
        let storedHeight = defaults.object(forKey: answerHeightDefaultsKey) == nil
            ? answerHeight
            : CGFloat(defaults.double(forKey: answerHeightDefaultsKey))
        return NSSize(
            width: min(maximumAnswerSize.width, max(minimumAnswerSize.width, storedWidth)),
            height: min(maximumAnswerSize.height, max(minimumAnswerSize.height, storedHeight))
        )
    }

    private var activeScreen: NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }

    private func position() {
        guard let visible = activeScreen?.visibleFrame else {
            panel.center()
            return
        }
        let x = visible.midX - panel.frame.width / 2
        let y = visible.maxY - panel.frame.height - 72
        panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY + 12, y)))
    }
}

private struct QuickAskPanelView: View {
    let selectionRegions: AnswerSelectionRegistry
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var promptFocused = false
    @State private var followUpFocused = false
    @State private var modelPickerPresented = false

    var body: some View {
        AttachmentDropContainer(onDrop: { model.attachFromPasteboard(isQuickAsk: true, pasteboard: $0, acceptingDrop: true) }) {
            panelBody.environmentObject(model)
        }
    }

    private var panelBody: some View {
        ZStack {
            if model.quickMessages.isEmpty {
                promptBar
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            } else {
                quickChat
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scholiaFloatingSurface()
        .tint(accentColor)
        .animation(
            reduceMotion ? nil : ScholiaVisualStyle.panelAnimation,
            value: model.quickMessages.isEmpty
        )
        .onExitCommand(perform: model.dismissQuickAsk)
        .onChange(of: model.quickMessages.isEmpty) { _, isEmpty in
            DispatchQueue.main.async {
                promptFocused = isEmpty
                followUpFocused = !isEmpty
            }
        }
        .onChange(of: model.quickLayerID) { _, _ in
            // Hiding an NSPanel does not recreate this SwiftUI view. Reopening
            // a fresh prompt must request focus again, not rely on onAppear.
            DispatchQueue.main.async {
                promptFocused = model.quickMessages.isEmpty
                followUpFocused = !model.quickMessages.isEmpty
            }
        }
    }

    private var promptBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                ScholiaMark(size: 25)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Quick Ask")
                        .font(.system(.headline, design: .serif, weight: .bold))
                    Text("Temporary conversation")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: model.dismissQuickAsk) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(ScholiaIconButtonStyle(size: 25))
                .help("Close Quick Ask")
            }
            .background(WindowDragArea())

            if !model.quickDraftAttachments.isEmpty {
                MessageAttachmentChips(
                    attachments: model.quickDraftAttachments,
                    compact: true,
                    onRemove: model.removeQuickDraftAttachment
                )
                .frame(height: 30)
            }

            HStack(spacing: 10) {
                quickAttachmentButton
                quickDraftImageThumbnail
                ComposerTextView(
                    text: $model.quickDraft,
                    isFocused: $promptFocused,
                    placeholder: model.quickDraftImageData == nil
                        ? "Ask Scholia anything…"
                        : "Ask about the pasted image…",
                    font: .systemFont(ofSize: 17, weight: .medium),
                    minHeight: 42, maxHeight: 120,
                    onSubmit: model.submitQuickAsk,
                    onPasteAttachment: { model.attachFromPasteboard(isQuickAsk: true) },
                    onDropAttachment: { model.attachFromPasteboard(isQuickAsk: true, pasteboard: $0, acceptingDrop: true) }
                )
                .layoutPriority(1)
                Button(action: model.submitQuickAsk) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 25, height: 25)
                }
                .scholiaButtonStyle(.borderedProminent)
                .disabled(quickDraftIsEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(inputBackground)
            .overlay(inputBorder(focused: promptFocused))

            quickChatOptions
            if let error = model.quickAskError {
                ScrollView {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 48)
            }
            Text(model.quickAskThinkingIsAvailable
                ? "↩ send · ⇧↩ new line · ⌘⇥ thinking"
                : "↩ send · ⇧↩ new line")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .onAppear { DispatchQueue.main.async { promptFocused = true } }
    }

    private var quickChat: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                if model.canReturnToParentQuickChat {
                    Button(action: model.returnToParentQuickChat) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 23, height: 23)
                    }
                    .scholiaButtonStyle(.borderless)
                    .help("Back to previous Quick Chat explanation")
                }
                ScholiaMark(size: 27)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.quickLayerDepth == 0 ? "Quick chat" : "Nested explanation \(model.quickLayerDepth + 1)")
                        .font(.system(.headline, design: .serif, weight: .bold))
                    Text(model.quickLayerDepth == 0
                        ? "Temporary · select answer text to explain it again"
                        : "Select any answer text to explain it again")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isQuickAskStreaming { ProgressView().controlSize(.small) }
                Button(action: model.dismissQuickAsk) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(ScholiaIconButtonStyle(size: 26))
                .help("Close Quick Chat")
            }
            .background(WindowDragArea())
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .overlay(alignment: .bottom) { Divider().opacity(0.7) }

            if let selection = model.quickSelectionExcerpt {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.quote")
                        .font(.caption)
                        .foregroundStyle(accentColor)
                    ScrollView(.vertical) {
                        Text(selection)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 66)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(accentColor.opacity(colorScheme == .dark ? 0.1 : 0.055))
                .overlay(alignment: .bottom) { Divider() }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.quickMessages) { message in
                            quickMessage(message)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(15)
                }
                .id(model.quickLayerID)
                .onAppear {
                    guard let target = model.quickMessages.last?.id else { return }
                    proxy.scrollTo(target, anchor: .bottom)
                }
                .onChange(of: model.quickMessages.count) { _, _ in
                    guard let target = model.quickMessages.last?.id else { return }
                    proxy.scrollTo(target, anchor: .bottom)
                }
                .onChange(of: model.isQuickAskStreaming) { wasStreaming, isStreaming in
                    guard wasStreaming, !isStreaming,
                          let target = model.quickMessages.last?.id else { return }
                    proxy.scrollTo(target, anchor: .bottom)
                }
                .animation(
                    reduceMotion ? nil : ScholiaVisualStyle.fastAnimation,
                    value: model.quickMessages.count
                )
            }

            VStack(spacing: 8) {
                if !model.quickDraftAttachments.isEmpty {
                    MessageAttachmentChips(
                        attachments: model.quickDraftAttachments,
                        compact: true,
                        onRemove: model.removeQuickDraftAttachment
                    )
                }
                HStack(spacing: 9) {
                    quickAttachmentButton
                    quickDraftImageThumbnail
                    ComposerTextView(
                        text: $model.quickDraft,
                        isFocused: $followUpFocused,
                        placeholder: model.quickDraftImageData == nil
                            ? "Ask a follow-up…"
                            : "Ask about the pasted image…",
                        font: .systemFont(ofSize: 14, weight: .medium),
                        minHeight: 36, maxHeight: 120,
                        onSubmit: model.submitQuickAsk,
                        onPasteAttachment: { model.attachFromPasteboard(isQuickAsk: true) },
                    onDropAttachment: { model.attachFromPasteboard(isQuickAsk: true, pasteboard: $0, acceptingDrop: true) }
                    )
                    .layoutPriority(1)
                    Button(action: submitOrStopQuickAsk) {
                        Image(systemName: model.isQuickAskStreaming ? "stop.fill" : "arrow.up")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .scholiaButtonStyle(.borderedProminent)
                    .disabled(!model.isQuickAskStreaming && quickDraftIsEmpty)
                    .help(model.isQuickAskStreaming ? "Stop response" : "Send follow-up")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(inputBackground)
                .overlay(inputBorder(focused: followUpFocused))

                quickChatOptions

                HStack(spacing: 8) {
                    Spacer(minLength: 6)
                    Button("Copy", action: model.copyQuickAnswer)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(model.latestQuickAnswer.isEmpty)
                    Button("Move to saved chat", action: model.moveQuickAskToChat)
                        .scholiaButtonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(model.isQuickAskStreaming || model.latestQuickAnswer.isEmpty)
                }

                if let error = model.quickAskError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(11)
            .background(.thinMaterial)
            .overlay(alignment: .top) { Divider().opacity(0.7) }
        }
        .onAppear { DispatchQueue.main.async { followUpFocused = true } }
        .onChange(of: model.isQuickAskStreaming) { wasStreaming, isStreaming in
            guard wasStreaming, !isStreaming else { return }
            DispatchQueue.main.async { followUpFocused = true }
        }
    }

    private func quickMessage(_ message: ConversationMessage) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            if message.role == .user { Spacer(minLength: 70) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if message.role == .assistant {
                        Image(systemName: "sparkles")
                            .foregroundStyle(accentColor)
                    }
                    Text(message.role == .user ? "You" : "Scholia")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if message.role == .assistant,
                   let reasoning = message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !reasoning.isEmpty {
                    ProviderReasoningView(source: reasoning, compact: true)
                }
                if let activity = message.activity { ConversationActivityView(events: activity) }
                if message.role == .user, let imageData = message.imageData {
                    ConversationMessageImageView(data: imageData, compact: true)
                }
                if message.role == .user, let attachments = message.attachments, !attachments.isEmpty {
                    MessageAttachmentChips(attachments: attachments, compact: true)
                }
                if message.content.isEmpty && message.isStreaming {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…").foregroundStyle(.secondary)
                    }
                } else if message.role == .assistant {
                    RichMarkdownView(
                        source: message.content,
                        compact: true,
                        registerSelectionView: { selectionRegions.register($0, for: message.id) }
                    )
                } else if model.editingQuickMessageID == message.id {
                    ConversationMessageEditor(
                        text: $model.quickMessageEditDraft,
                        compact: true,
                        cancel: model.cancelQuickMessageEdit,
                        resend: model.resendEditedQuickMessage
                    )
                } else {
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(message.content)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            model.beginEditingQuickMessage(message.id)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                                .font(.caption2.weight(.semibold))
                        }
                        .scholiaButtonStyle(.plain)
                        .disabled(model.isQuickAskStreaming)
                        .help("Edit this message and regenerate from here")
                    }
                }
                if message.isStreaming && !message.content.isEmpty {
                    ProgressView().controlSize(.mini)
                }
                if let metadata = message.metadata, !metadata.isEmpty {
                    Text(metadata).font(.caption2).foregroundStyle(.tertiary)
                }
                if message.role == .assistant, !message.isStreaming {
                    ChatResponseUsageView(usage: message.usage, duration: message.responseDurationSeconds)
                }
            }
            .font(.callout)
            .padding(.horizontal, message.role == .user ? 11 : 14)
            .padding(.vertical, message.role == .user ? 9 : 13)
            .frame(maxWidth: message.role == .user ? 460 : 550, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: message.role == .user ? 11 : 14)
                    .fill(message.role == .user
                        ? accentColor.opacity(colorScheme == .dark ? 0.17 : 0.09)
                        : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: message.role == .user ? 11 : 14)
                    .stroke(message.role == .user
                        ? accentColor.opacity(0.3)
                        : .clear, lineWidth: 1)
            )
            if message.role == .assistant { Spacer(minLength: 18) }
        }
        .frame(maxWidth: .infinity)
        .id(message.id)
    }

    private var quickChatOptions: some View {
        VStack(alignment: .leading, spacing: 7) {
            modelMenu
            if model.activeQuickAskProvider.id == "codex" {
                CodexUsageIndicator(monitor: model.codexUsage, configuration: model.codexUsageConfiguration(quickChat: true))
            }
            HStack(spacing: 7) {
                thinkingProfileMenu
                contextModeButton.fixedSize()
                fullContextButton.fixedSize()
                noContextButton.fixedSize()
                AnswerLanguageMenu(selection: Binding(
                    get: { model.settings.language },
                    set: { model.settings.language = $0; model.persistSettings() }
                ))
                Spacer(minLength: 0)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var modelMenu: some View {
        Button {
            modelPickerPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                Text(quickAskMenuLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
            }
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
            .background(.primary.opacity(colorScheme == .dark ? 0.09 : 0.06), in: Capsule())
            .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 1))
        }
        .scholiaButtonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .disabled(model.isQuickAskStreaming)
        .help("Quick Ask provider & model")
        .accessibilityLabel("Choose Quick Ask model")
        .accessibilityValue(quickAskMenuLabel)
        .popover(isPresented: $modelPickerPresented, arrowEdge: .bottom) {
            ScholiaModelPickerPopover(isPresented: $modelPickerPresented)
        }
    }

    private var contextModeButton: some View {
        contextButton(
            "Compact", icon: "doc.text.magnifyingglass",
            selected: model.quickContextEnabled && model.quickCompactContextEnabled,
            help: "Use compact screen and related-tab context (up to about 8,000 characters). Attachments are always included."
        ) {
            model.quickContextEnabled = true
            model.quickCompactContextEnabled = true
        }
    }

    private var fullContextButton: some View {
        contextButton(
            "Full", icon: "doc.text",
            selected: model.quickContextEnabled && !model.quickCompactContextEnabled,
            help: "Use full application context (up to 24,000 characters). Attachments are always included."
        ) {
            model.quickContextEnabled = true
            model.quickCompactContextEnabled = false
        }
    }

    private var noContextButton: some View {
        contextButton(
            "None", icon: "nosign", selected: !model.quickContextEnabled,
            help: "Send no automatic context. Explicit selections and attachments are still included."
        ) { model.quickContextEnabled = false }
    }

    private func contextButton(
        _ title: String, icon: String, selected: Bool, help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(selected ? accentColor : .secondary)
                .padding(.horizontal, 9)
                .frame(height: 27)
                .background(
                    selected ? accentColor.opacity(colorScheme == .dark ? 0.18 : 0.1)
                        : .primary.opacity(colorScheme == .dark ? 0.06 : 0.04),
                    in: Capsule()
                )
                .overlay(Capsule().stroke(
                    selected ? accentColor.opacity(0.35) : .primary.opacity(0.12), lineWidth: 1
                ))
        }
        .scholiaButtonStyle(.plain)
        .disabled(model.isQuickAskStreaming)
        .help(help)
        .accessibilityLabel("\(title) context")
        .accessibilityValue(selected ? "On" : "Off")
    }

    private var quickAskMenuLabel: String {
        let providerName = model.activeQuickAskProvider.shortName
        let modelLabel = model.modelDefinition(for: model.activeQuickAskProvider, id: model.activeQuickAskModel)?.label
            ?? model.activeQuickAskModel
        let prefix = model.modelIsVerified(model.activeQuickAskModel, for: model.activeQuickAskProvider)
            ? providerName
            : "Unverified"
        return "\(prefix) · \(modelLabel)"
    }

    private var thinkingProfileMenu: some View {
        Menu {
            ForEach(QuickAskThinkingProfile.allCases) { profile in
                Button {
                    model.setQuickAskThinkingProfile(profile)
                } label: {
                    if model.activeQuickAskThinkingProfile == profile {
                        Label(thinkingProfileMenuTitle(profile), systemImage: "checkmark")
                    } else {
                        Text(thinkingProfileMenuTitle(profile))
                    }
                }
                .disabled(!model.quickAskThinkingProfileIsAvailable(
                    profile,
                    provider: model.activeQuickAskProvider
                ))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                Text(model.activeQuickAskReasoningEffort == nil
                    ? "No modes"
                    : model.activeQuickAskThinkingProfile.label)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.down")
            }
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .frame(height: 27, alignment: .leading)
            .background(.primary.opacity(colorScheme == .dark ? 0.09 : 0.06), in: Capsule())
            .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 1))
        }
        .menuStyle(.borderlessButton).scholiaPointingCursor()
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isQuickAskStreaming || !model.quickAskThinkingIsAvailable)
        .help(model.quickAskThinkingIsAvailable
            ? "Thinking profile · ⌘Tab cycles supported modes, ⇧⌘Tab cycles backward"
            : "The selected model does not expose thinking modes")
    }

    private func thinkingProfileMenuTitle(_ profile: QuickAskThinkingProfile) -> String {
        let provider = model.activeQuickAskProvider
        let modelID = model.settings.resolvedQuickAskThinkingModel(for: profile, provider: provider)
        let modelLabel = model.modelDefinition(for: provider, id: modelID)?.label ?? modelID
        let effort = model.quickAskReasoningEffort(
            for: profile,
            provider: provider
        )
        return [profile.label, modelLabel, effort ?? "Unavailable"].joined(separator: " · ")
    }

    private var activeThinkingModelIsOverridden: Bool {
        model.settings.quickAskThinkingConfiguration(
            for: model.activeQuickAskThinkingProfile,
            provider: model.activeQuickAskProvider
        )?.modelID != nil
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 13)
            .fill(accentColor.opacity(colorScheme == .dark ? 0.16 : 0.08))
    }

    private func inputBorder(focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 13)
            .stroke(focused ? accentColor.opacity(0.9) : .primary.opacity(0.16), lineWidth: focused ? 1.5 : 1)
            .allowsHitTesting(false)
    }

    private var accentColor: Color {
        ScholiaVisualStyle.accentColor(for: colorScheme)
    }

    private var quickDraftIsEmpty: Bool {
        model.isIngestingQuickAttachment
            || (model.quickDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && model.quickDraftImageData == nil
                && model.quickDraftAttachments.isEmpty)
    }

    private var quickAttachmentButton: some View {
        Button { model.chooseDraftAttachment(isQuickAsk: true) } label: {
            if model.isIngestingQuickAttachment {
                ProgressView().controlSize(.small).frame(width: 20, height: 20)
            } else {
                Image(systemName: "paperclip").frame(width: 20, height: 20)
            }
        }
        .scholiaButtonStyle(.bordered)
        .controlSize(.small)
        .disabled(model.isQuickAskStreaming || model.isIngestingQuickAttachment)
        .help("Attach any file or project folder")
    }

    @ViewBuilder
    private var quickDraftImageThumbnail: some View {
        if let image = model.quickDraftImage {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.primary.opacity(0.18), lineWidth: 1)
                    }
                    .accessibilityLabel("Image ready to send")
                Button(action: model.removeQuickDraftImage) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 16, height: 16)
                        .background(.ultraThickMaterial, in: Circle())
                }
                .scholiaButtonStyle(.plain)
                .offset(x: 5, y: -5)
                .help("Remove pasted image")
                .accessibilityLabel("Remove pasted image")
            }
            .frame(width: 45, height: 42)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    private func submitOrStopQuickAsk() {
        if model.isQuickAskStreaming { model.cancelQuickAsk() }
        else { model.submitQuickAsk() }
    }

}

struct ScholiaModelPickerPopover: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Binding var isPresented: Bool
    var usesExplainModel = false
    var providerID: String? = nil
    var onTestModel: ((String, String) -> Void)? = nil
    /// Shown when a study mode picks the model itself, so the list below is
    /// understood as the catalog, not the active choice.
    var routeNote: String? = nil
    @State private var query = ""
    @State private var displayedModels: [String: [ModelDefinition]] = [:]
    @State private var displayedRecentModels: [RecentProviderModel] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Models")
                        .font(.headline)
                    Text("Recently used · all models by provider")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Your most recently used models appear first. The remaining catalog keeps verified models first within each provider.")
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)

            if let routeNote {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "bolt").foregroundStyle(Color.accentColor)
                    Text("\(routeNote). Choose Manual in the mode menu to pick a model yourself.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .padding(.horizontal, 10).padding(.top, 10)
                .accessibilityIdentifier("model-route-note")
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search models or providers", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .scholiaButtonStyle(.plain)
                    .help("Clear model search")
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 38)
            .background(.primary.opacity(colorScheme == .dark ? 0.07 : 0.045), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.12), lineWidth: 1))
            .padding(10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if hasVisibleModels {
                        if !recentModels.isEmpty {
                            Text("RECENTLY USED")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(9)
                            ForEach(recentModels) { recent in
                                let provider = ProviderCatalog.provider(id: recent.providerID)
                                if let definition = visibleModels(for: provider).first(where: { $0.id == recent.modelID }) {
                                    modelRow(definition, provider: provider, showsProvider: true)
                                }
                            }
                            Divider().padding(.vertical, 5)
                        }
                        ForEach(providers) { provider in
                            let definitions = visibleModels(for: provider).filter { definition in
                                !recentModels.contains { $0.providerID == provider.id && $0.modelID == definition.id }
                            }
                            if !definitions.isEmpty {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: 8) {
                                        Text(provider.name)
                                            .font(.caption2.weight(.bold))
                                            .textCase(.uppercase)
                                            .tracking(0.45)
                                        Spacer(minLength: 8)
                                        Text("\(definitions.count) model\(definitions.count == 1 ? "" : "s")")
                                            .font(.caption2.weight(.semibold))
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 7)
                                    .background(.primary.opacity(colorScheme == .dark ? 0.06 : 0.035))

                                    Divider()

                                    ForEach(definitions) { definition in
                                        modelRow(definition, provider: provider)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.11), lineWidth: 1))
                                .padding(.top, 6)
                            }
                        }
                    } else {
                        ContentUnavailableView(
                            query.isEmpty ? "No models" : "No models found",
                            systemImage: "magnifyingglass",
                            description: Text(query.isEmpty
                                ? "Add a model ID in Provider settings to test it."
                                : "Try a different model or provider name.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 38)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.bottom, 9)
            }
            .frame(height: 330)

            if !usesExplainModel && (activeThinkingModelIsOverridden
                || model.quickAskProviderIsOverridden
                || model.quickAskBaseModel != model.activeModel) {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    if activeThinkingModelIsOverridden {
                        Button("Use default model for \(model.activeQuickAskThinkingProfile.label)") {
                            model.setQuickAskThinkingModel(nil)
                            isPresented = false
                        }
                    }
                    if model.quickAskProviderIsOverridden || model.quickAskBaseModel != model.activeModel {
                        Button("Match Explain provider & model") {
                            model.setQuickAskThinkingModel(nil)
                            model.matchQuickAskModelToExplain()
                            isPresented = false
                        }
                    }
                }
                .scholiaButtonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack(spacing: 8) {
                if let attempt = model.modelVerification.activeTest {
                    ProgressView().controlSize(.small)
                    Text("Testing \(attempt.target.modelID)…")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Cancel") { model.cancelModelTest() }
                        .scholiaButtonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.shield")
                    Text(model.providerTestStatus ?? "Test a model to verify access")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.providerTestStatus ?? "Test a model to verify access")
                    Spacer(minLength: 0)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 38)

            if providerID == nil {
                Divider()
                SettingsLink {
                    Label("Provider settings and custom models", systemImage: "gearshape")
                        .font(.caption.weight(.semibold))
                }
                .scholiaButtonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .simultaneousGesture(TapGesture().onEnded { isPresented = false })
            }
        }
        .frame(width: 430)
        .onAppear {
            query = ""
            // Keep the clicked row under the pointer as verification changes.
            // Reapply verified-first ordering the next time the picker opens.
            displayedModels = Dictionary(uniqueKeysWithValues: providers.map {
                ($0.id, model.availableModels(for: $0))
            })
            displayedRecentModels = Array(model.settings.recentModels.prefix(8))
            model.refreshModelCatalogs()
            DispatchQueue.main.async { searchFocused = true }
        }
        .onChange(of: model.discoveredProviderModels) { _, _ in
            displayedModels = Dictionary(uniqueKeysWithValues: providers.map {
                ($0.id, model.availableModels(for: $0))
            })
        }
        .onExitCommand { isPresented = false }
    }

    private func modelRow(
        _ definition: ModelDefinition,
        provider: ProviderDefinition,
        showsProvider: Bool = false
    ) -> some View {
        let selected = provider.id == (usesExplainModel ? model.activeProvider.id : model.activeQuickAskProvider.id)
            && definition.id == (usesExplainModel ? model.activeModel : model.activeQuickAskModel)
        let verified = model.modelIsVerified(definition.id, for: provider)
        let testStatus = model.modelTestStatus(definition.id, for: provider)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 9) {
                Button {
                    if usesExplainModel {
                        model.selectStudyModel(definition.id, providerID: provider.id)
                    } else {
                        model.setQuickAskThinkingModel(
                            definition.id,
                            for: model.activeQuickAskThinkingProfile,
                            providerID: provider.id
                        )
                    }
                    isPresented = false
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(definition.label)
                                .font(.callout.weight(selected ? .semibold : .regular))
                                .lineLimit(1)
                            Text(showsProvider ? "\(provider.name) · \(definition.id)" : definition.id)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 7) {
                                if case .failed(let message) = testStatus {
                                    Label("Test failed", systemImage: "exclamationmark.circle")
                                        .foregroundStyle(.red).help(message)
                                } else {
                                    Label(testStatus == .cancelled ? "Test cancelled" : verified ? "Verified" : "Not verified",
                                          systemImage: verified ? "checkmark.shield.fill" : "shield")
                                        .foregroundStyle(verified ? Color.green : Color.secondary)
                                }
                                if let supportsImages = definition.supportsImages {
                                    Text(supportsImages ? "Vision" : "Text only")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption2)
                        }
                        Spacer(minLength: 0)
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .scholiaButtonStyle(.plain)
                .disabled(!verified || (!usesExplainModel && model.isQuickAskStreaming))
                .help(model.modelVerificationDetail(definition.id, for: provider)
                    ?? "Test this model before selecting it")

                Button {
                    if let onTestModel { onTestModel(definition.id, provider.id) }
                    else { model.testModel(definition.id, providerID: provider.id) }
                } label: {
                    Text(testStatus == .testing ? "Testing…" : verified ? "Retest" : "Test")
                        .frame(width: 54)
                }
                .scholiaButtonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isTestingProvider)
                .accessibilityLabel("\(verified ? "Retest" : "Test") \(definition.label) with \(provider.name)")
                .help("Send a short test request using the saved provider connection")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            selected ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private func visibleModels(for provider: ProviderDefinition) -> [ModelDefinition] {
        let models = displayedModels[provider.id] ?? model.availableModels(for: provider)
        let terms = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return models }
        return models.filter { definition in
            let searchable = normalized("\(definition.label) \(definition.id) \(provider.name)")
            return terms.allSatisfy(searchable.contains)
        }
    }

    private var hasVisibleModels: Bool {
        providers.contains { !visibleModels(for: $0).isEmpty }
    }

    private var recentModels: [RecentProviderModel] {
        displayedRecentModels.filter { recent in
            providers.contains { $0.id == recent.providerID }
                && visibleModels(for: ProviderCatalog.provider(id: recent.providerID)).contains { $0.id == recent.modelID }
        }
    }

    private var providers: [ProviderDefinition] {
        ProviderCatalog.providers.filter { providerID == nil || $0.id == providerID }
    }

    private var activeThinkingModelIsOverridden: Bool {
        model.settings.quickAskThinkingConfiguration(
            for: model.activeQuickAskThinkingProfile,
            provider: model.activeQuickAskProvider
        )?.modelID != nil
    }

    private func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }
}

@MainActor
final class SelectionPillController: NSObject, NSWindowDelegate {
    private static let panelSize = NSSize(width: 372, height: 116)
    private let panel: SelectionPillPanel
    private var currentCapture: CapturedContent?
    private var currentPoint = NSPoint.zero
    private var anchorOrigin: NSPoint?
    private var rememberedOffset: NSSize
    private var isPositioning = false
    private var isAnimatingPresentation = false
    private var hideTask: Task<Void, Never>?
    private let onMove: (NSSize) -> Void
    private let onExplain: (CapturedContent, NSPoint, String) -> Void

    init(
        initialOffset: NSSize,
        onMove: @escaping (NSSize) -> Void,
        onExplain: @escaping (CapturedContent, NSPoint, String) -> Void
    ) {
        rememberedOffset = initialOffset
        self.onMove = onMove
        self.onExplain = onExplain
        panel = SelectionPillPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        panel.delegate = self
        updateContent()
    }

    func show(capture: CapturedContent, near point: NSPoint) {
        currentCapture = capture
        currentPoint = point
        updateContent()
        position(near: point, selectionBounds: capture.selectionBounds)
        hideTask?.cancel()
        let targetOrigin = panel.frame.origin
        guard ScholiaVisualStyle.appKitAnimationsEnabled else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            scheduleHide()
            return
        }
        isAnimatingPresentation = true
        isPositioning = true
        panel.setFrameOrigin(NSPoint(x: targetOrigin.x, y: targetOrigin.y - 5))
        isPositioning = false
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(targetOrigin)
        }, completionHandler: { [weak self] in
            DispatchQueue.main.async { self?.isAnimatingPresentation = false }
        })
        scheduleHide()
    }

    func contains(_ point: NSPoint) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -4, dy: -4).contains(point)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPositioning, !isAnimatingPresentation, let anchorOrigin else { return }
        let nextOffset = NSSize(
            width: panel.frame.origin.x - anchorOrigin.x,
            height: panel.frame.origin.y - anchorOrigin.y
        )
        guard abs(nextOffset.width - rememberedOffset.width) >= 0.5
                || abs(nextOffset.height - rememberedOffset.height) >= 0.5 else { return }
        rememberedOffset = nextOffset
        hideTask?.cancel()
        hideTask = nil
        onMove(nextOffset)
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard panel.isVisible else { return }
        guard ScholiaVisualStyle.appKitAnimationsEnabled else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.allowsImplicitAnimation = true
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            DispatchQueue.main.async { panel?.orderOut(nil) }
        })
    }

    private func explain(question: String) {
        guard let currentCapture else { return }
        let point = currentPoint
        hide()
        onExplain(currentCapture, point, question)
    }

    private func scheduleHide() {
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled, self?.panel.isKeyWindow != true else { return }
            self?.hide()
        }
    }

    private func updateContent() {
        panel.contentViewController = PanelContentController(rootView: SelectionPillView(
            selection: currentCapture?.text ?? "",
            kind: currentCapture?.kind ?? .text,
            focusQuestion: { [weak panel] in panel?.makeKey() },
            explain: { [weak self] question in self?.explain(question: question) },
            dismiss: { [weak self] in self?.hide() }
        ), size: Self.panelSize)
    }

    private func position(near point: NSPoint, selectionBounds: CGRect?) {
        let convertedSelection = selectionBounds.flatMap(convertAccessibilityBounds)
        let screen = convertedSelection?.screen
            ?? NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let gap: CGFloat = 12
        let edge: CGFloat = 8
        let anchor = convertedSelection?.rect
        let horizontalAnchor = anchor?.midX ?? point.x
        var baseOrigin = NSPoint(
            x: horizontalAnchor - size.width / 2,
            y: (anchor?.minY ?? point.y) - size.height - gap
        )
        if baseOrigin.y < visible.minY + edge {
            baseOrigin.y = (anchor?.maxY ?? point.y) + gap
        }
        baseOrigin.x = min(max(baseOrigin.x, visible.minX + edge), visible.maxX - size.width - edge)
        baseOrigin.y = min(max(baseOrigin.y, visible.minY + edge), visible.maxY - size.height - edge)
        anchorOrigin = baseOrigin

        var origin = NSPoint(
            x: baseOrigin.x + rememberedOffset.width,
            y: baseOrigin.y + rememberedOffset.height
        )
        origin.x = min(max(origin.x, visible.minX + edge), visible.maxX - size.width - edge)
        origin.y = min(max(origin.y, visible.minY + edge), visible.maxY - size.height - edge)
        isPositioning = true
        panel.setFrameOrigin(origin)
        isPositioning = false
    }

    private func convertAccessibilityBounds(_ bounds: CGRect) -> (rect: NSRect, screen: NSScreen)? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            guard displayBounds.intersects(bounds) else { continue }
            let rect = NSRect(
                x: screen.frame.minX + bounds.minX - displayBounds.minX,
                y: screen.frame.maxY - (bounds.maxY - displayBounds.minY),
                width: bounds.width,
                height: bounds.height
            )
            return (rect, screen)
        }
        return nil
    }
}

@MainActor
private final class SelectionPillPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct SelectionPillView: View {
    let selection: String
    let kind: CaptureKind
    var focusQuestion: () -> Void
    var explain: (String) -> Void
    var dismiss: () -> Void
    @State private var question = ""

    private var isMail: Bool { kind == .mail }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    WindowDragArea()
                        .help("Drag to move this popup")
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 3)
                        Text(selection)
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScholiaIconButtonStyle(size: 22))
                .help("Dismiss")
            }

            HStack(spacing: 7) {
                TextField(
                    isMail ? "Add tone, length, or a key point…" : "Ask about this…",
                    text: $question
                )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onTapGesture(perform: focusQuestion)
                    .onSubmit(submit)
                    .onChange(of: question) { _, value in
                        let bounded = TextInputPolicy.bounded(value)
                        if bounded != value { question = bounded }
                    }
                Button(action: submit) {
                    Label(
                        isMail ? "Draft reply" : "Explain",
                        systemImage: isMail ? "envelope" : "sparkles"
                    )
                        .font(.system(size: 12, weight: .semibold))
                        .frame(height: 22)
                }
                .scholiaButtonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .padding(10)
        .frame(width: 372, height: 116)
        .scholiaFloatingSurface(cornerRadius: 15)
        .tint(Color(red: 49 / 255, green: 89 / 255, blue: 78 / 255))
        .onExitCommand(perform: dismiss)
    }

    private func submit() {
        explain(question.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView {
        WindowDragView(frame: .zero)
    }

    func updateNSView(_ view: WindowDragView, context: Context) {}
}

@MainActor
final class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}
