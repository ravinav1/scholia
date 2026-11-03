@preconcurrency import AppKit
@preconcurrency import Carbon
import SwiftUI

struct AnswerLanguageMenu: View {
    @Binding var selection: AnswerLanguage

    var body: some View {
        Menu {
            Picker("Default response language", selection: $selection) {
                ForEach(AnswerLanguage.allCases) { language in
                    Text(language.label).tag(language)
                }
            }
        } label: {
            Label(selection == .automatic ? "Auto" : selection.label, systemImage: "globe")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton).scholiaPointingCursor().fixedSize()
        .help("Default response language for all chats. Auto follows the language of your prompt.")
        .accessibilityLabel("Response language")
        .accessibilityValue(selection.label)
        .accessibilityIdentifier("response-language")
    }
}

struct MenuContent: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                ScholiaMark(size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("Scholia")
                            .font(.system(.title2, design: .serif, weight: .bold))
                        Text("v\(Bundle.main.scholiaDisplayVersion)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    Text(model.isAnswering
                        ? (model.capture?.kind == .mail ? "Drafting an email reply…" : "Writing an explanation…")
                        : (model.isStartingBridge ? "Connecting the local provider…" : "Quiet until you need it."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isAnswering || model.isStartingBridge { ProgressView().controlSize(.small) }
            }

            VStack(spacing: 7) {
                MenuActionButton(
                    title: "Study Workspace", icon: "books.vertical",
                    shortcut: "⌘1", action: model.openStudyWorkspace
                )
                MenuActionButton(
                    title: "Open in Browser", icon: "globe",
                    shortcut: "⌘2", action: model.openStudyWebsite
                )
                MenuActionButton(
                    title: "Study on Paper", icon: "camera.viewfinder",
                    shortcut: "⌘3", action: { PaperStudyWindowController.shared.show(app: model) }
                )
                MenuActionButton(
                    title: "Quick Ask", icon: "sparkles",
                    shortcut: model.settings.resolvedQuickAskShortcut.displayName,
                    action: model.showQuickAsk
                )
                MenuActionButton(
                    title: "Explain selected text", icon: "text.cursor",
                    shortcut: model.selectionPillIsEnabledForActiveApplication
                        ? model.settings.resolvedExplainShortcut.displayName
                        : "Handed off",
                    action: model.explainSelectedText
                )
                MenuActionButton(
                    title: "Capture a screen region", icon: "viewfinder",
                    shortcut: model.captureRegionIsEnabledForActiveApplication
                        ? model.settings.resolvedCaptureShortcut.displayName
                        : "Handed off",
                    action: model.captureRegion
                )
                MenuActionButton(
                    title: "Explain clipboard", icon: "doc.on.clipboard",
                    shortcut: nil, action: model.explainClipboard
                )
            }

            Divider()

            if !model.savedConversations.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text("RECENT CHATS").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                    ForEach(model.savedConversations.prefix(3)) { conversation in
                        Button { model.openSavedConversation(conversation.id) } label: {
                            HStack {
                                Image(systemName: "bubble.left.and.bubble.right")
                                Text(conversation.title).lineLimit(1)
                                Spacer()
                                Text(conversation.updatedAt, style: .relative)
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .scholiaButtonStyle(.plain)
                    }
                }
                Divider()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(model.activeProvider.name, systemImage: model.hasConfiguredProvider ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(model.hasConfiguredProvider ? Color.secondary : Color.orange)
                    Spacer()
                    Text(model.activeModel).lineLimit(1).foregroundStyle(.tertiary)
                }
                .font(.caption)

                Divider()

                Text("ACTIVE APP")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)

                HStack(spacing: 9) {
                    Group {
                        if let icon = model.activeApplicationIcon {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: "app").resizable().scaledToFit()
                        }
                    }
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.activeApplication?.name ?? "No active application")
                            .lineLimit(1)
                        Text("Choose which native tools own their shortcuts here")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Toggle(isOn: Binding(
                        get: { model.selectionPillIsEnabledForActiveApplication },
                        set: { model.setSelectionPillEnabledForActiveApplication($0) }
                    )) {
                        HStack {
                            Text("Selection Explain")
                            Spacer()
                            Text(model.settings.resolvedExplainShortcut.displayName)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Toggle(isOn: Binding(
                        get: { model.captureRegionIsEnabledForActiveApplication },
                        set: { model.setCaptureRegionEnabledForActiveApplication($0) }
                    )) {
                        HStack {
                            Text("Screen region clip")
                            Spacer()
                            Text(model.settings.resolvedCaptureShortcut.displayName)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .toggleStyle(.switch).scholiaPointingCursor()
                .controlSize(.small)
                .disabled(!model.canConfigureActiveApplication)

                if model.activeApplicationHasSelectionPopupOverride {
                    Button(action: model.removeActiveApplicationSelectionPopupPreference) {
                        Text("Use defaults (selection \(model.settings.showSelectionPill ? "on" : "off"), clip \(model.settings.resolvedCaptureRegionEnabled ? "on" : "off"))")
                            .font(.caption2)
                    }
                    .scholiaButtonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if !model.accessibilityGranted {
                PermissionNotice(
                    icon: "hand.raised.fill",
                    message: "Selected-text access is off.",
                    actionTitle: "Allow",
                    action: model.requestAccessibility
                )
            }
            if !model.screenCaptureGranted {
                PermissionNotice(
                    icon: "record.circle",
                    message: model.screenCaptureNeedsRelaunch
                        ? "Screen capture needs a relaunch."
                        : "Screen capture access is off.",
                    actionTitle: model.screenCaptureNeedsRelaunch ? "Relaunch" : "Allow",
                    action: model.screenCaptureNeedsRelaunch ? model.relaunch : model.requestScreenCapture
                )
            }

            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Update Scholia…", action: ScholiaAppUpdater.open)
                .font(.caption)
                .help("Build and install the latest changes from your Scholia folder, then reopen the app.")

            Divider()
            HStack {
                Button("Open Scholia", action: model.openConversation)
                    .scholiaButtonStyle(.plain)
                Spacer()
                ForegroundSettingsButton("Settings…")
                    .scholiaButtonStyle(.plain)
                Button("Quit") { NSApp.terminate(nil) }
                    .scholiaButtonStyle(.plain)
            }
            .font(.caption)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            model.refreshActiveApplication()
            model.refreshPermissions()
        }
    }
}

@MainActor
private final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()

    private weak var window: NSWindow?

    func register(_ window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        self.window = window
    }

    func bringToFront(attempt: Int = 0) {
        NSApp.activate()
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            return
        }

        guard attempt < 12 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in
            self?.bringToFront(attempt: attempt + 1)
        }
    }
}

@MainActor
private struct ForegroundSettingsButton: View {
    var title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        SettingsLink { Text(title) }
    }
}

@MainActor
private final class SettingsWindowTrackingView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        SettingsWindowPresenter.shared.register(window)
    }
}

@MainActor
private struct SettingsWindowTracker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SettingsWindowTrackingView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        SettingsWindowPresenter.shared.register(nsView.window)
    }
}

private struct MenuActionButton: View {
    var title: String
    var icon: String
    var shortcut: String?
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .scholiaButtonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            .primary.opacity(isHovering ? 0.1 : 0.045),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .scaleEffect(!reduceMotion && isHovering ? 1.006 : 1)
        .animation(reduceMotion ? nil : ScholiaVisualStyle.fastAnimation, value: isHovering)
        .onHover { isHovering = $0 }
    }
}

private struct PermissionNotice: View {
    var icon: String
    var message: String
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(.orange)
            Text(message).font(.caption)
            Spacer()
            Button(actionTitle, action: action).controlSize(.small)
        }
        .padding(9)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ExplanationPanelView: View {
    let selectionRegions: AnswerSelectionRegistry
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var composerFocused = false

    var body: some View {
        AttachmentDropContainer(onDrop: { model.attachFromPasteboard(isQuickAsk: false, pasteboard: $0, acceptingDrop: true) }) {
            panelBody.environmentObject(model)
        }
    }

    private var panelBody: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            composer
        }
        .frame(minWidth: 440, minHeight: 420)
        .scholiaFloatingSurface()
        .tint(ScholiaVisualStyle.accentColor(for: colorScheme))
        .animation(
            reduceMotion ? nil : ScholiaVisualStyle.fastAnimation,
            value: model.messages.count
        )
        .animation(
            reduceMotion ? nil : ScholiaVisualStyle.fastAnimation,
            value: model.errorMessage
        )
    }

    private var header: some View {
        HStack(spacing: 10) {
            ScholiaMark(size: 29)
            VStack(alignment: .leading, spacing: 1) {
                Text("Scholia").font(.system(.headline, design: .serif, weight: .bold))
                Text(model.capture?.sourceTitle.nonEmpty ?? "Ask about anything")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.capture?.applicationPID != nil {
                Button(action: model.returnToSource) {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(ScholiaIconButtonStyle())
                .help("Return to source app")
            }
            Button(action: model.copyLatestAnswer) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(ScholiaIconButtonStyle())
            .disabled(!model.messages.contains { $0.role == .assistant && !$0.content.isEmpty })
            .help("Copy latest answer")
            Menu {
                if model.savedConversations.isEmpty {
                    Text("No saved chats")
                } else {
                    ForEach(model.savedConversations) { conversation in
                        Button(conversation.title) { model.openSavedConversation(conversation.id) }
                    }
                    Divider()
                    Button("Clear saved chats", role: .destructive, action: model.clearSavedConversations)
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton).scholiaPointingCursor()
            .help("Saved chats")
            Button(action: model.newConversation) {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(ScholiaIconButtonStyle())
            .help("New conversation")
            if !model.settings.resolvedShowExplanationWindowInWindowSwitcher {
                Button(action: model.closeConversation) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(ScholiaIconButtonStyle())
                .help("Close Scholia")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, model.settings.resolvedShowExplanationWindowInWindowSwitcher ? 28 : 11)
        .padding(.bottom, 10)
        .background(WindowDragArea())
        .background(.thinMaterial)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let capture = model.capture { CaptureCard(capture: capture) }
                    if model.capture == nil && model.messages.isEmpty && model.errorMessage == nil {
                        EmptyConversation()
                    }
                    ForEach(model.messages) { message in
                        MessageView(
                            message: message,
                            selectionRegions: selectionRegions,
                            isEditing: model.editingMessageID == message.id,
                            editDraft: $model.messageEditDraft,
                            canEdit: !model.isStreaming,
                            beginEdit: { model.beginEditingMessage(message.id) },
                            cancelEdit: model.cancelMessageEdit,
                            resendEdit: model.resendEditedMessage
                        )
                            .id(message.id)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if let error = model.errorMessage {
                        ErrorCard(message: error, retry: model.retryLastQuestion)
                            .id("error")
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(18)
            }
            .onChange(of: model.messages.count) { _, _ in
                withAnimation(reduceMotion ? nil : ScholiaVisualStyle.fastAnimation) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onChange(of: model.messages.last?.content) { _, _ in
                // Keep up with streaming without restarting an animated scroll
                // (or comparing the entire conversation) for every text delta.
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onChange(of: model.errorMessage) { _, _ in
                withAnimation(reduceMotion ? nil : ScholiaVisualStyle.fastAnimation) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 7) {
            if model.draftImageData != nil || !model.draftAttachments.isEmpty {
                HStack(spacing: 7) {
                    if model.draftImageData != nil {
                        AttachmentKindChip(
                            label: "Image",
                            detail: nil,
                            systemImage: "photo",
                            remove: model.removeDraftImage
                        )
                    }
                    MessageAttachmentChips(
                        attachments: model.draftAttachments,
                        compact: true,
                        onRemove: model.removeDraftAttachment
                    )
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Button { model.chooseDraftAttachment(isQuickAsk: false) } label: {
                    if model.isIngestingDraftAttachment {
                        ProgressView().controlSize(.small).frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "paperclip").frame(width: 24, height: 24)
                    }
                }
                .scholiaButtonStyle(.bordered)
                .disabled(model.isStreaming || model.isIngestingDraftAttachment)
                .help("Attach any file or project folder")

                ComposerTextView(
                    text: $model.draft,
                    isFocused: $composerFocused,
                    placeholder: model.capture?.kind == .mail
                        ? (model.messages.isEmpty
                            ? "Add tone, length, or key points…"
                            : "Refine the reply or ask for another tone…")
                        : model.capture?.kind == .image && model.messages.isEmpty
                            ? "Ask about this image…"
                        : (model.messages.isEmpty
                            ? "What would you like to understand?"
                            : "Ask a follow-up…"),
                    font: .systemFont(ofSize: NSFont.systemFontSize),
                    height: 52,
                    onSubmit: {
                        if !model.isStreaming { model.askDraft() }
                    },
                    onPasteAttachment: { model.attachFromPasteboard(isQuickAsk: false) },
                    onDropAttachment: { model.attachFromPasteboard(isQuickAsk: false, pasteboard: $0, acceptingDrop: true) }
                )

                if model.isStreaming {
                    Button(action: model.cancelResponse) {
                        Image(systemName: "stop.fill").frame(width: 24, height: 24)
                    }
                    .scholiaButtonStyle(.borderedProminent)
                    .tint(.secondary)
                    .help("Stop")
                } else {
                    if model.canExplainCapturedImageDirectly {
                        Button(action: model.askDraft) {
                            Label("Explain", systemImage: "sparkles")
                                .frame(height: 24)
                        }
                        .scholiaButtonStyle(.borderedProminent)
                        .disabled(model.isIngestingDraftAttachment)
                        .help("Explain the captured image without adding a question")
                    } else {
                        Button(action: model.askDraft) {
                            Image(systemName: "arrow.up").frame(width: 24, height: 24)
                        }
                        .scholiaButtonStyle(.borderedProminent)
                        .disabled(
                            model.isIngestingDraftAttachment
                                || (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    && model.draftImageData == nil
                                    && model.draftAttachments.isEmpty)
                        )
                        .help("Send")
                    }
                }
            }

            HStack(spacing: 7) {
                AnswerLanguageMenu(selection: Binding(
                    get: { model.settings.language },
                    set: { model.settings.language = $0; model.persistSettings() }
                ))
                Button {
                    if model.conversationContextEnabled {
                        model.conversationCompactContextEnabled.toggle()
                    } else {
                        model.conversationContextEnabled = true
                        model.conversationCompactContextEnabled = true
                    }
                } label: {
                    Label("Compact", systemImage: model.conversationContextEnabled
                        && model.conversationCompactContextEnabled
                        ? "doc.text.magnifyingglass"
                        : "doc")
                }
                .scholiaButtonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isStreaming)
                .help(model.conversationContextEnabled && model.conversationCompactContextEnabled
                    ? "Compact screen and related-tab context is on (about 8,000 characters maximum)"
                    : "Use compact context; when it is off Scholia sends the previous full context")
                Button {
                    if model.conversationContextEnabled {
                        model.conversationContextEnabled = false
                    } else {
                        model.conversationContextEnabled = true
                        model.conversationCompactContextEnabled = false
                    }
                } label: {
                    Label("None", systemImage: "nosign")
                }
                .scholiaButtonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isStreaming)
                .help(model.conversationContextEnabled
                    ? "Send no automatic context; explicit selections and images remain"
                    : "Restore full automatic context")
                Text(!model.conversationContextEnabled
                    ? "No context"
                    : model.conversationCompactContextEnabled ? "Compact" : "Full")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(
            .primary.opacity(colorScheme == .dark ? 0.075 : 0.045),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(
                    composerFocused
                        ? ScholiaVisualStyle.accentColor(for: colorScheme).opacity(0.65)
                        : .primary.opacity(0.1),
                    lineWidth: composerFocused ? 1.5 : 1
                )
        }
        .padding(11)
        .background(.thinMaterial)
        .animation(reduceMotion ? nil : ScholiaVisualStyle.fastAnimation, value: composerFocused)
        .onAppear(perform: focusComposerForImageDraft)
        .onChange(of: model.capture?.id) { _, _ in focusComposerForImageDraft() }
    }

    private func focusComposerForImageDraft() {
        guard model.capture?.kind == .image, model.messages.isEmpty else { return }
        DispatchQueue.main.async { composerFocused = true }
    }
}

private struct CaptureCard: View {
    let capture: CapturedContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(
                    capture.kind == .image
                        ? "Captured region"
                        : capture.kind == .mail
                            ? "Selected email + conversation"
                            : capture.kind == .latex ? "Selected mathematics" : "Selected text",
                    systemImage: capture.kind == .image
                        ? "viewfinder"
                        : capture.kind == .mail ? "envelope" : "quote.opening"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Spacer()
                if capture.text?.count ?? 0 > 500 {
                    Button(expanded ? "Less" : "More") {
                        withAnimation(reduceMotion ? nil : ScholiaVisualStyle.panelAnimation) {
                            expanded.toggle()
                        }
                    }
                        .scholiaButtonStyle(.plain)
                        .font(.caption)
                }
            }

            if let data = capture.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: expanded ? 320 : 170)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let text = capture.text {
                Text(expanded ? text : String(text.prefix(500)) + (text.count > 500 ? "…" : ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(expanded ? nil : 8)
            }
        }
        .padding(12)
        .scholiaCardSurface()
    }
}

struct ConversationMessageImageView: View {
    let data: Data
    var compact = false
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    var body: some View {
        if let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: compact ? 240 : 320, maxHeight: compact ? 155 : 220)
                .background(.black.opacity(colorScheme == .dark ? 0.16 : 0.035))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.primary.opacity(0.13), lineWidth: 1)
                }
                .accessibilityLabel("Attached image")
        }
    }
}

struct AttachmentKindChip: View {
    let label: String
    let detail: String?
    let systemImage: String
    var remove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(label).lineLimit(1).truncationMode(.middle)
            if let detail { Text(detail).foregroundStyle(.secondary) }
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .scholiaButtonStyle(.plain)
                .accessibilityLabel("Remove \(label)")
            }
        }
        .font(.caption2)
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(.primary.opacity(0.07), in: Capsule())
        .overlay(Capsule().stroke(.primary.opacity(0.11), lineWidth: 1))
    }
}

struct MessageAttachmentChips: View {
    let attachments: [MessageAttachment]
    var compact = false
    var onRemove: ((UUID) -> Void)? = nil
    @State private var inspectedAttachment: MessageAttachment?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    VStack(alignment: .leading, spacing: 3) {
                    AttachmentKindChip(
                        label: attachment.mimeType == "inode/directory" ? "Folder · \(attachment.fileName)" : attachment.fileName,
                        detail: compact ? attachment.readStatusLabel : "\(attachment.readStatusLabel) · \(attachment.formattedByteCount)",
                        systemImage: attachment.mimeType == "inode/directory" ? "folder" : attachment.isImage ? "photo"
                            : attachment.mimeType == "application/pdf" ? "doc.richtext" : "doc.text",
                        remove: onRemove.map { action in { action(attachment.id) } }
                    )
                    .help(attachment.readingDetailsText)
                    .onTapGesture { inspectedAttachment = attachment }
                    .accessibilityAction(named: Text("Show source and reading details")) { inspectedAttachment = attachment }
                    if !compact, let path = attachment.sourcePath {
                        Text(path).font(.system(size: 9)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head).frame(maxWidth: 360, alignment: .leading)
                    }
                    }
                }
            }
        }
        .popover(item: $inspectedAttachment) { attachment in
            ScrollView {
                Text(attachment.readingDetailsText).font(.system(size: 11)).textSelection(.enabled)
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(width: 370).frame(maxHeight: 450)
        }
    }
}

private struct MessageView: View {
    let message: ConversationMessage
    let selectionRegions: AnswerSelectionRegistry
    let isEditing: Bool
    @Binding var editDraft: String
    let canEdit: Bool
    let beginEdit: () -> Void
    let cancelEdit: () -> Void
    let resendEdit: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 52) }
            VStack(alignment: .leading, spacing: 7) {
                if message.role == .assistant {
                    HStack(spacing: 7) {
                        Image(systemName: "sparkles").foregroundStyle(.tint)
                        Text("Explanation").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if message.isStreaming { ProgressView().controlSize(.mini) }
                    }
                }
                if message.role == .assistant,
                   let reasoning = message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !reasoning.isEmpty {
                    ProviderReasoningView(source: reasoning)
                }
                if let activity = message.activity { ConversationActivityView(events: activity) }
                if message.role == .user, let imageData = message.imageData {
                    ConversationMessageImageView(data: imageData)
                }
                if message.role == .user, let attachments = message.attachments, !attachments.isEmpty {
                    MessageAttachmentChips(attachments: attachments)
                }
                if !message.content.isEmpty {
                    if message.role == .assistant {
                        RichMarkdownView(
                            source: message.content,
                            registerSelectionView: { selectionRegions.register($0, for: message.id) }
                        )
                    } else if isEditing {
                        ConversationMessageEditor(
                            text: $editDraft,
                            compact: false,
                            cancel: cancelEdit,
                            resend: resendEdit
                        )
                    } else {
                        VStack(alignment: .trailing, spacing: 6) {
                            Text(message.content)
                                .font(.body)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(action: beginEdit) {
                                Label("Edit", systemImage: "pencil")
                                    .font(.caption2.weight(.semibold))
                            }
                            .scholiaButtonStyle(.plain)
                            .disabled(!canEdit)
                            .help("Edit this message and regenerate from here")
                        }
                    }
                }
                if let metadata = message.metadata {
                    Text(metadata).font(.caption2).foregroundStyle(.tertiary)
                }
                if message.role == .assistant, !message.isStreaming {
                    ChatResponseUsageView(usage: message.usage, duration: message.responseDurationSeconds)
                }
            }
            .padding(message.role == .user ? 10 : 2)
            .background(
                RoundedRectangle(cornerRadius: message.role == .user ? 10 : 14)
                    .fill(message.role == .user
                        ? Color.accentColor.opacity(colorScheme == .dark ? 0.18 : 0.1)
                        : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: message.role == .user ? 10 : 14)
                    .stroke(message.role == .user
                        ? Color.accentColor.opacity(0.2)
                        : .clear, lineWidth: 1)
            )
            if message.role == .assistant { Spacer(minLength: 8) }
        }
    }

}

struct ConversationMessageEditor: View {
    @Binding var text: String
    var compact: Bool
    var cancel: () -> Void
    var resend: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            TextEditor(text: $text)
                .font(compact ? .callout : .body)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(minHeight: compact ? 58 : 76, maxHeight: compact ? 130 : 180)
                .padding(5)
                .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.primary.opacity(0.16), lineWidth: 1)
                )
                .onChange(of: text) { _, value in
                    let bounded = TextInputPolicy.bounded(value)
                    if bounded != value { text = bounded }
                }

            HStack(spacing: 8) {
                Text("Later replies will be replaced.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Button("Cancel", action: cancel)
                Button(action: resend) {
                    Label("Resend", systemImage: "arrow.clockwise")
                }
                .scholiaButtonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .controlSize(.small)
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onExitCommand(perform: cancel)
    }
}

private struct ErrorCard: View {
    var message: String
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Scholia needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            HStack {
                if !message.localizedCaseInsensitiveContains("Accessibility") {
                    Button("Try again", action: retry).controlSize(.small)
                }
                ForegroundSettingsButton("Open Settings").controlSize(.small)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct EmptyConversation: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Understand what’s in front of you")
                .font(.system(.title3, design: .serif, weight: .semibold))
            Text("Press \(model.settings.resolvedQuickAskShortcut.displayName) for Quick Ask, select text and press \(model.settings.resolvedExplainShortcut.displayName), capture a region with \(model.settings.resolvedCaptureShortcut.displayName), or ask below.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var apiKey = ""
    @State private var keyStatus: String?
    @State private var pendingSessionDeletion: OpenCodePoisonedAttachment?
    @State private var modelPickerPresented = false

    private var provider: ProviderDefinition { model.activeProvider }
    private var quickAskProvider: ProviderDefinition { model.activeQuickAskProvider }

    var body: some View {
        TabView {
            providerSettings
                .tabItem { Label("Provider", systemImage: "network") }
            behaviorSettings
                .tabItem { Label("Behavior", systemImage: "switch.2") }
            PersonalizationSettingsView(sync: .shared)
                .tabItem { Label("Personalization", systemImage: "person.crop.circle") }
            Form {
                Section("Course content") {
                    StudyCourseUpdatePreferences(workspace: model.studyWorkspace, showsStatus: true)
                }
            }.formStyle(.grouped)
                .tabItem { Label("Courses", systemImage: "books.vertical") }
            privacySettings
                .tabItem { Label("Privacy", systemImage: "lock.shield") }
        }
        .padding(20)
        .frame(width: 700, height: 680)
        .background(SettingsWindowTracker().frame(width: 0, height: 0))
        .confirmationDialog(
            "Delete this entire opencode session?",
            isPresented: Binding(
                get: { pendingSessionDeletion != nil },
                set: { if !$0 { pendingSessionDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let finding = pendingSessionDeletion {
                Button("Delete session", role: .destructive) {
                    pendingSessionDeletion = nil
                    model.deleteOpencodeSession(finding)
                }
            }
            Button("Cancel", role: .cancel) { pendingSessionDeletion = nil }
        } message: {
            Text("Scholia creates a complete SQLite backup first. The selected session and all of its messages will then be removed from opencode.")
        }
        .onAppear {
            model.settingsWindowVisibilityDidChange(true)
            SettingsWindowPresenter.shared.bringToFront()
            model.refreshActiveApplication()
            model.refreshPermissions()
            model.refreshActiveBridgeStatus(showProgress: false)
            loadAPIKey()
            if provider.id == "opencode" { model.scanOpencodeSessions() }
        }
        .onChange(of: model.settings.providerID) { _, _ in
            model.persistSettings()
            keyStatus = nil
            loadAPIKey()
            model.prepareActiveLocalProvider()
            if provider.id == "opencode" { model.scanOpencodeSessions() }
        }
        .onChange(of: model.settings.quickAskProviderID) { _, _ in
            model.persistSettings()
            model.prepareActiveLocalProvider()
        }
        .onDisappear {
            model.persistSettings()
            model.settingsWindowVisibilityDidChange(false)
        }
    }

    private var providerSettings: some View {
        Form {
            Section("Explanation provider") {
                Picker("Provider", selection: $model.settings.providerID) {
                    ForEach(ProviderCatalog.providers) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }

                LabeledContent("Model") {
                    HStack(spacing: 8) {
                        TextField("", text: modelBinding, prompt: Text("Model ID"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 260)
                            .onSubmit { model.persistSettings() }
                        Menu {
                            let verified = model.verifiedModels(for: provider)
                            if verified.isEmpty {
                                Text("No tested models yet")
                            } else {
                                Section("Verified") {
                                    ForEach(verified) { item in
                                        Button(modelPickerLabel(item)) {
                                            model.settings.models[provider.id] = item.id
                                            model.persistSettings()
                                        }
                                    }
                                }
                            }
                        } label: {
                            Label("Verified", systemImage: "checkmark.shield")
                        }
                        .menuStyle(.borderlessButton).scholiaPointingCursor()
                        .help("Models that passed Test provider for this endpoint")

                        Button("Browse & test…") {
                            modelPickerPresented = true
                        }
                        .popover(isPresented: $modelPickerPresented) {
                            ScholiaModelPickerPopover(
                                isPresented: $modelPickerPresented,
                                usesExplainModel: true,
                                providerID: provider.id,
                                onTestModel: { modelID, _ in
                                    saveKey(testAfterSaving: true, modelID: modelID)
                                }
                            )
                            .environmentObject(model)
                        }
                        .help("Search and test any catalog or custom model")
                    }
                }

                if let detail = model.modelVerificationDetail(model.activeModel, for: provider) {
                    Label("Verified · \(detail)", systemImage: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("Not verified for this endpoint. Run Test provider before using it from a model picker.", systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                TextField("Endpoint", text: endpointBinding)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        model.persistSettings()
                        model.refreshActiveBridgeStatus()
                    }

                if let modelDefinition = model.modelDefinition(for: provider, id: model.activeModel),
                   !modelDefinition.reasoningEfforts.isEmpty {
                    Picker("Reasoning", selection: reasoningBinding(for: modelDefinition)) {
                        ForEach(modelDefinition.reasoningEfforts, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    Picker("Reasoning", selection: .constant("")) {
                        Text("Unavailable for this model").tag("")
                    }
                    .disabled(true)
                }

                if provider.id == "claudecode" {
                    Toggle("Use Claude Code fast mode", isOn: $model.settings.fastClaudeMode)
                        .onChange(of: model.settings.fastClaudeMode) { _, _ in model.persistSettings() }
                }
            }

            Section("Quick Ask") {
                Picker("Provider", selection: quickAskProviderBinding) {
                    Text("Match Explain (\(provider.shortName))").tag("")
                    ForEach(ProviderCatalog.providers) { candidate in
                        Text(candidate.name).tag(candidate.id)
                    }
                }

                LabeledContent("Default model") {
                    HStack(spacing: 8) {
                        TextField("", text: quickAskModelBinding, prompt: Text("Model ID"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 220)
                            .onSubmit { model.setQuickAskModel(model.quickAskBaseModel) }
                        Menu {
                            ForEach(model.verifiedModels(for: quickAskProvider)) { item in
                                Button(modelPickerLabel(item)) { model.setQuickAskModel(item.id, for: quickAskProvider.id) }
                            }
                        } label: {
                            Label("Verified", systemImage: "checkmark.shield")
                        }
                        .menuStyle(.borderlessButton).scholiaPointingCursor()
                        .disabled(model.verifiedModels(for: quickAskProvider).isEmpty)
                        Button("Match Explain") { model.matchQuickAskModelToExplain() }
                            .controlSize(.small)
                            .disabled(model.settings.quickAskModels?[quickAskProvider.id] == nil
                                && model.quickAskProviderIsOverridden == false)
                    }
                }

                Picker("Active thinking", selection: quickAskThinkingProfileBinding) {
                    ForEach(QuickAskThinkingProfile.allCases) { profile in
                        Text(profile.label).tag(profile)
                            .disabled(!model.quickAskThinkingProfileIsAvailable(
                                profile,
                                provider: quickAskProvider
                            ))
                    }
                }
                .disabled(model.availableQuickAskThinkingProfiles(for: quickAskProvider).isEmpty)

                LabeledContent("Thinking profiles") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(QuickAskThinkingProfile.allCases) { profile in
                            let efforts = quickAskReasoningEfforts(for: profile)
                            let defaultEffort = quickAskDefaultReasoningEffort(for: profile)
                            HStack(spacing: 8) {
                                Text(profile.label)
                                    .font(.callout.weight(.medium))
                                    .frame(width: 68, alignment: .leading)
                                Picker("Model for \(profile.label)", selection: quickAskThinkingModelBinding(for: profile)) {
                                    Text("Current model").tag("")
                                    ForEach(model.verifiedModels(for: quickAskProvider)) { definition in
                                        Text(modelPickerLabel(definition)).tag(definition.id)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu).scholiaPointingCursor()
                                .frame(width: 190)
                                Picker("Effort for \(profile.label)", selection: quickAskThinkingReasoningBinding(for: profile)) {
                                    if efforts.isEmpty {
                                        Text("Unavailable").tag("")
                                    } else if let defaultEffort {
                                        Text("Default · \(defaultEffort)").tag("")
                                    } else {
                                        Text("Choose mode…").tag("")
                                    }
                                    ForEach(efforts, id: \.self) { effort in
                                        Text(effort).tag(effort)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu).scholiaPointingCursor()
                                .frame(width: 132)
                                .disabled(efforts.isEmpty)
                                .help(efforts.isEmpty
                                    ? "The selected model does not expose thinking modes."
                                    : "Thinking modes supported by the selected model")
                            }
                        }
                    }
                }

                Text("Press ⌘Tab in Quick Chat to cycle the thinking profiles supported by their selected models; use ⇧⌘Tab to go back. Each profile can use the current model with only a reasoning-effort change, or override both model and effort.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Quick Chat profile changes are temporary. Set the saved default here. Use Browse & test to verify models for their current endpoint before selecting them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(provider.keyRequired ? "Provider credential" : "Provider connection") {

                LabeledContent(provider.keyRequired ? "API key" : "Credential (optional)") {
                    SecureField("", text: $apiKey, prompt: Text(provider.keyHint))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 300)
                }
                Text("Credentials are stored in your macOS Keychain, never in preferences or source files.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button("Save credential") { saveKey() }
                    Button(model.isTestingProvider ? "Testing…" : "Test provider") {
                        saveKey(testAfterSaving: true)
                    }
                    .disabled(model.isTestingProvider)
                    if model.isTestingProvider {
                        Button("Cancel test") { model.cancelModelTest() }
                    }
                    if provider.bridge != nil {
                        if model.activeBridgeIsReady {
                            Label("Local provider ready", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Button(model.isStartingBridge ? "Starting local provider…" : "Start local provider") {
                                model.startActiveBridge()
                            }
                            .disabled(model.isStartingBridge)
                        }
                    }
                    Spacer()
                }
                if let status = keyStatus ?? model.providerTestStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            if provider.id == "opencode" {
                Section("opencode session health") {
                    HStack {
                        Button(model.isScanningOpencodeSessions ? "Scanning…" : "Scan session database") {
                            model.scanOpencodeSessions()
                        }
                        .disabled(model.isScanningOpencodeSessions)
                        if model.isScanningOpencodeSessions {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                        if !model.opencodeSessionFindings.isEmpty {
                            Button("Strip all unsafe attachments") {
                                model.repairAllOpencodeFindings()
                            }
                            .disabled(model.isScanningOpencodeSessions)
                        }
                    }

                    Text("The scan is read-only. Repairs first create a complete database backup, then remove only provider-breaking attachment payloads. Delete session is the full-reset option.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let status = model.opencodeRepairStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    ForEach(Array(model.opencodeSessionFindings.prefix(16))) { finding in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(finding.sessionTitle)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text(finding.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Strip attachment") {
                                    model.repairOpencodeAttachment(finding)
                                }
                                Button("Delete session", role: .destructive) {
                                    pendingSessionDeletion = finding
                                }
                            }
                            .controlSize(.small)
                            .disabled(model.isScanningOpencodeSessions)
                        }
                        .padding(.vertical, 3)
                    }
                    if model.opencodeSessionFindings.count > 16 {
                        Text("Showing 16 of \(model.opencodeSessionFindings.count) findings. “Strip all” repairs the complete set.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var behaviorSettings: some View {
        Form {
            Section("Interaction") {
                Picker("Answer language", selection: $model.settings.language) {
                    ForEach(AnswerLanguage.allCases) { language in Text(language.label).tag(language) }
                }
                .onChange(of: model.settings.language) { _, _ in model.persistSettings() }

                Toggle("Enable Selection Explain by default", isOn: Binding(
                    get: { model.settings.showSelectionPill },
                    set: { enabled in model.setSelectionPillEnabled(enabled) }
                ))

                Toggle("Enable native screen-region clip by default", isOn: Binding(
                    get: { model.settings.resolvedCaptureRegionEnabled },
                    set: { enabled in model.setCaptureRegionEnabled(enabled) }
                ))
                Text("These are independent defaults for applications without an override. Turning Selection Explain off hides the automatic popup and releases \(model.settings.resolvedExplainShortcut.displayName). Turning screen-region clip off releases \(model.settings.resolvedCaptureShortcut.displayName). A browser extension or the foreground app can then receive that key combination. Quick Ask and \(model.settings.resolvedToggleSelectionPopupShortcut.displayName) remain available. Drag the selected-text area to move the popup; Scholia remembers its offset.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Keep explanation windows on top", isOn: Binding(
                    get: { model.settings.resolvedKeepExplanationWindowOnTop },
                    set: { model.setKeepExplanationWindowOnTop($0) }
                ))

                Toggle("Include explanation windows in normal window switching", isOn: Binding(
                    get: { model.settings.resolvedShowExplanationWindowInWindowSwitcher },
                    set: { model.setShowExplanationWindowInWindowSwitcher($0) }
                ))
                Text("Quick Chat stays visible above other windows and across Spaces while open, including other apps’ full-screen Spaces on supported macOS versions. It shares one Scholia Dock icon with the study workspace and explanations. Scholia stays in the Dock until you quit. These toggles control saved explanation window cycling and placement separately.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Open Scholia at login", isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { enabled in model.setLaunchAtLogin(enabled) }
                ))
                .disabled(!model.launchAtLoginAvailable)
                if !model.launchAtLoginAvailable {
                    Text("Launch-at-login becomes available when you run the packaged Scholia.app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if let preferences = model.settings.selectionPopupApplications,
               !preferences.isEmpty {
                Section("Application overrides") {
                    ForEach(preferences) { preference in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preference.applicationName)
                                Text(preference.bundleIdentifier)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) {
                                Toggle("Selection", isOn: Binding(
                                    get: {
                                        model.settings.selectionPillIsEnabled(
                                            for: preference.bundleIdentifier
                                        )
                                    },
                                    set: {
                                        model.setSelectionPillEnabled(
                                            $0,
                                            for: preference.bundleIdentifier,
                                            applicationName: preference.applicationName
                                        )
                                    }
                                ))
                                Toggle("Region", isOn: Binding(
                                    get: {
                                        model.settings.captureRegionIsEnabled(
                                            for: preference.bundleIdentifier
                                        )
                                    },
                                    set: {
                                        model.setCaptureRegionEnabled(
                                            $0,
                                            for: preference.bundleIdentifier,
                                            applicationName: preference.applicationName
                                        )
                                    }
                                ))
                            }
                            .toggleStyle(.switch).scholiaPointingCursor()
                            .controlSize(.small)
                            Button {
                                model.removeSelectionPopupPreference(
                                    for: preference.bundleIdentifier,
                                    applicationName: preference.applicationName
                                )
                            } label: {
                                Image(systemName: "arrow.uturn.backward.circle")
                            }
                            .scholiaButtonStyle(.borderless)
                            .help("Use the default setting")
                        }
                    }
                    Text("Selection and Region can be handed off separately. Remove an override to make that application follow both defaults above; configure the matching browser commands in the Scholia extension settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Shortcuts") {
                LabeledContent("Explain selected text") {
                    ShortcutRecorder(
                        shortcut: model.settings.resolvedExplainShortcut,
                        onChange: { model.setShortcut($0, for: .explainSelection) }
                    )
                    .frame(width: 138, height: 28)
                }
                LabeledContent("Explain a screen region") {
                    ShortcutRecorder(
                        shortcut: model.settings.resolvedCaptureShortcut,
                        onChange: { model.setShortcut($0, for: .captureRegion) }
                    )
                    .frame(width: 138, height: 28)
                }
                LabeledContent("Open Quick Ask") {
                    ShortcutRecorder(
                        shortcut: model.settings.resolvedQuickAskShortcut,
                        onChange: { model.setShortcut($0, for: .quickAsk) }
                    )
                    .frame(width: 138, height: 28)
                }
                LabeledContent("Toggle desktop tools for active app") {
                    ShortcutRecorder(
                        shortcut: model.settings.resolvedToggleSelectionPopupShortcut,
                        onChange: { model.setShortcut($0, for: .toggleSelectionPopup) }
                    )
                    .frame(width: 138, height: 28)
                }
                HStack {
                    Text("Click a shortcut, then press a new combination.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults", action: model.resetShortcuts)
                        .controlSize(.small)
                }
                if !model.hotKeysAvailable {
                    Text("One or more shortcuts are already registered by another app. Choose another combination or use the menu-bar actions.")
                        .font(.caption).foregroundStyle(.orange)
                }
                DisclosureGroup("Workspace shortcuts") {
                    StudyWorkspaceShortcutList().padding(.vertical, 8)
                }
            }

            Section("Permissions") {
                permissionRow(
                    name: "Accessibility", granted: model.accessibilityGranted,
                    detail: "Reads selections and bounded visible window text for an explicit region capture.",
                    request: model.requestAccessibility, open: model.openAccessibilitySettings
                )
                permissionRow(
                    name: "Screen Recording", granted: model.screenCaptureGranted,
                    detail: "Captures only the region you drag across.",
                    needsRelaunch: model.screenCaptureNeedsRelaunch,
                    request: model.requestScreenCapture, open: model.openScreenCaptureSettings
                )
                if let permissionStatus = model.permissionStatus {
                    Label(permissionStatus, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button("Refresh permissions", action: model.refreshPermissions)
                    if model.screenCaptureNeedsRelaunch {
                        Button("Relaunch Scholia", action: model.relaunch)
                            .scholiaButtonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button("Show this copy in Finder", action: model.revealCurrentApp)
                }
                if !model.runningFromApplications {
                    Label(
                        "Install the stable-signed build in Applications before granting access. Future builds signed by the same identity keep these permissions.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var privacySettings: some View {
        Form {
            Section("Local files") {
                Toggle("Allow file access", isOn: Binding(
                    get: { model.settings.resolvedLocalFileAccessEnabled },
                    set: { enabled in
                        model.settings.localFileAccessEnabled = enabled
                        if !enabled { model.settings.localFileWriteAccessEnabled = false }
                        model.persistSettings()
                    }
                ))
                Text("Give Scholia a path or an approximate filename and folder in chat. It can search your Mac and read matching documents, text, code, and images. Files it reads are sent to your selected model to answer your request.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow write access", isOn: Binding(
                    get: { model.settings.resolvedLocalFileWriteAccessEnabled },
                    set: { enabled in
                        model.settings.localFileWriteAccessEnabled = enabled
                        model.persistSettings()
                    }
                ))
                .disabled(!model.settings.resolvedLocalFileAccessEnabled)
                Text("Off by default. When enabled, Scholia can create folders and create or edit text and code files you ask it to change. Turning it off blocks further writes, including during an answer.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("macOS may ask for access to Documents, Desktop, or Downloads. For other protected locations, grant Scholia Full Disk Access in System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Full Disk Access settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Section("Visible workspace context") {
                Toggle(
                    "Use compact visible-window context by default",
                    isOn: Binding(
                        get: { model.settings.resolvedUseVisibleWorkspaceContext },
                        set: { enabled in
                            model.settings.useVisibleWorkspaceContext = enabled
                            model.persistSettings()
                        }
                    )
                )
                Text("At send time, Compact mode uses Accessibility to inspect a small, bounded set of on-screen windows, correlates visible text with exposed browser-tab titles, and compresses relevant text before sending it to your chosen provider. Turning Compact off uses the previous full 24,000-character source behavior; choose None in Quick Chat or a saved chat to send no automatic context. Scholia never continuously scans, takes screenshots for this feature, or reads password-manager windows.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Local first") {
                Label("No Scholia server, analytics, or telemetry", systemImage: "checkmark.shield.fill")
                Text("Text and images are captured only after a question, selection, shortcut, Services command, clipboard action, or region gesture. Images are resized locally before they leave your Mac.")
                Text("Selected content, the context mode you choose, source app/window labels, files read for your request, your question, and bounded conversation history are sent directly to the provider you choose.")
                Text("Quick Ask prompts and answers are temporary. Full chats are stored locally only after you open or move a conversation into chat, and can be cleared from the chat history menu.")
            }
            Section("Endpoint safety") {
                Text("Hosted providers must use HTTPS. Plain HTTP is accepted only for localhost and 127.0.0.0/8 endpoints on this Mac.")
                Text("Use a dedicated, revocable API key with an appropriate spending limit.")
            }
            Section("Scholia") {
                LabeledContent("Version", value: Bundle.main.scholiaDisplayVersion)
                Text("Select anything. Understand it in place.")
                    .font(.system(.headline, design: .serif))
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(
        name: String,
        granted: Bool,
        detail: String,
        needsRelaunch: Bool = false,
        request: @escaping () -> Void,
        open: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(name, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Spacer()
                Text(granted ? "Allowed" : (needsRelaunch ? "Relaunch needed" : "Action needed"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(granted ? .green : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((granted ? Color.green : Color.orange).opacity(0.12), in: Capsule())
            }
            HStack(alignment: .firstTextBaseline) {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !granted {
                    if !needsRelaunch { Button("Request Access", action: request) }
                    Button("Open Settings", action: open)
                }
            }
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { model.settings.models[provider.id] ?? provider.defaultModel },
            set: { model.settings.models[provider.id] = $0 }
        )
    }

    private func modelPickerLabel(_ definition: ModelDefinition) -> String {
        switch definition.supportsImages {
        case true: "\(definition.label) · Vision"
        case false: "\(definition.label) · Text only"
        case nil: definition.label
        }
    }

    private var endpointBinding: Binding<String> {
        Binding(
            get: { model.settings.endpoints[provider.id] ?? provider.endpoint },
            set: { model.settings.endpoints[provider.id] = $0 }
        )
    }

    private var quickAskProviderBinding: Binding<String> {
        Binding(
            get: { model.settings.quickAskProviderID ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    model.settings.quickAskProviderID = nil
                } else {
                    model.setQuickAskProvider(trimmed)
                }
                model.persistSettings()
            }
        )
    }

    private var quickAskModelBinding: Binding<String> {
        Binding(
            get: { model.quickAskBaseModel },
            set: { value in
                var values = model.settings.quickAskModels ?? [:]
                values[quickAskProvider.id] = value
                model.settings.quickAskModels = values
            }
        )
    }

    private func reasoningBinding(for definition: ModelDefinition) -> Binding<String> {
        Binding(
            get: {
                let configured = model.settings.reasoningEfforts[provider.id]
                return (configured.flatMap {
                    definition.reasoningEfforts.contains($0) ? $0 : nil
                })
                    ?? definition.defaultReasoningEffort
                    ?? definition.reasoningEfforts.first
                    ?? ""
            },
            set: { model.settings.reasoningEfforts[provider.id] = $0; model.persistSettings() }
        )
    }

    private var quickAskThinkingProfileBinding: Binding<QuickAskThinkingProfile> {
        Binding(
            get: {
                model.effectiveQuickAskThinkingProfile(
                    model.settings.resolvedQuickAskThinkingProfile(for: quickAskProvider),
                    provider: quickAskProvider
                )
            },
            set: { model.setDefaultQuickAskThinkingProfile($0) }
        )
    }

    private func quickAskThinkingModelBinding(
        for profile: QuickAskThinkingProfile
    ) -> Binding<String> {
        Binding(
            get: {
                model.settings.quickAskThinkingConfiguration(
                    for: profile,
                    provider: quickAskProvider
                )?.modelID ?? ""
            },
            set: {
                model.setQuickAskThinkingModel(
                    $0,
                    for: profile,
                    providerID: quickAskProvider.id
                )
            }
        )
    }

    private func quickAskThinkingReasoningBinding(
        for profile: QuickAskThinkingProfile
    ) -> Binding<String> {
        Binding(
            get: {
                let configured = model.settings.quickAskThinkingConfiguration(
                    for: profile,
                    provider: quickAskProvider
                )?.reasoningEffort ?? ""
                return quickAskReasoningEfforts(for: profile).contains(configured)
                    ? configured
                    : ""
            },
            set: {
                model.setQuickAskThinkingReasoningEffort(
                    $0,
                    for: profile,
                    providerID: quickAskProvider.id
                )
            }
        )
    }

    private func quickAskReasoningEfforts(for profile: QuickAskThinkingProfile) -> [String] {
        model.quickAskReasoningEfforts(for: profile, provider: quickAskProvider)
    }

    private func quickAskDefaultReasoningEffort(
        for profile: QuickAskThinkingProfile
    ) -> String? {
        model.defaultQuickAskReasoningEffort(
            for: profile,
            provider: quickAskProvider
        )
    }

    private func loadAPIKey() {
        apiKey = model.apiKey(for: provider.id)
    }

    private func saveKey(testAfterSaving: Bool = false, modelID: String? = nil) {
        do {
            try model.saveAPIKey(apiKey, for: provider.id)
            keyStatus = apiKey.isEmpty ? "Credential removed." : "Saved securely in Keychain."
            if testAfterSaving {
                keyStatus = nil
                model.testModel(modelID ?? model.activeModel, providerID: provider.id, apiKeyOverride: apiKey)
            }
        } catch {
            keyStatus = error.localizedDescription
        }
    }
}

private extension Bundle {
    var scholiaDisplayVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development"
        guard let build = infoDictionary?["CFBundleVersion"] as? String,
              !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let shortcut: KeyboardShortcut
    let onChange: (KeyboardShortcut) -> Bool

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(frame: .zero)
        button.shortcut = shortcut
        button.onChange = onChange
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
        button.onChange = onChange
    }
}

@MainActor
private final class ShortcutRecorderButton: NSButton {
    var shortcut = KeyboardShortcut.explainDefault {
        didSet { if !isRecording { updateTitle() } }
    }
    var onChange: ((KeyboardShortcut) -> Bool)?
    private var isRecording = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        target = self
        action = #selector(beginRecording)
        toolTip = "Click, then press a keyboard shortcut"
        setAccessibilityLabel("Keyboard shortcut")
        updateTitle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        isRecording = true
        title = "Type shortcut…"
        setAccessibilityValue("Waiting for a shortcut")
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        capture(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        capture(event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { finishRecording() }
        return resigned
    }

    private func capture(_ event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            finishRecording()
            return
        }
        let candidate = KeyboardShortcut(event: event)
        guard candidate.isValid else {
            NSSound.beep()
            title = "Add ⌘, ⌥, or ⌃"
            return
        }
        guard onChange?(candidate) != false else {
            NSSound.beep()
            finishRecording()
            return
        }
        shortcut = candidate
        finishRecording()
    }

    private func finishRecording() {
        isRecording = false
        updateTitle()
    }

    private func updateTitle() {
        title = shortcut.displayName
        setAccessibilityValue(shortcut.displayName)
    }
}

struct ScholiaMark: View {
    var size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(Color(red: 49 / 255, green: 89 / 255, blue: 78 / 255))
            Text("S")
                .font(.system(size: size * 0.63, weight: .bold, design: .serif))
                .foregroundStyle(Color(red: 250 / 255, green: 248 / 255, blue: 242 / 255))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
