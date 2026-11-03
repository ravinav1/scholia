@preconcurrency import AppKit
@preconcurrency import Carbon
import SwiftUI

enum ComposerReturnAction: Equatable, Sendable {
    case submit
    case insertNewline
    case systemDefault
}

func composerReturnAction(
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags
) -> ComposerReturnAction {
    guard keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter) else {
        return .systemDefault
    }
    let relevantFlags = modifierFlags.intersection([.command, .shift, .option, .control])
    if relevantFlags.isEmpty { return .submit }
    if relevantFlags == [.shift] { return .insertNewline }
    return .systemDefault
}

struct ComposerTextView: View {
    @Binding var text: String
    @Binding var isFocused: Bool
    var placeholder: String
    var font: NSFont
    var height: CGFloat
    var isEnabled = true
    var maximumUTF16Units = TextInputPolicy.maximumMessageUTF16Units
    var onSubmit: () -> Void
    var onPasteAttachment: (() -> Bool)? = nil
    var onPasteImage: ((NSImage) -> Void)? = nil
    var onDropAttachment: ((NSPasteboard) -> Bool)? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: font.pointSize))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .allowsHitTesting(false)
            }
            ComposerEditorRepresentable(
                text: $text,
                isFocused: $isFocused,
                font: font,
                isEnabled: isEnabled,
                maximumUTF16Units: maximumUTF16Units,
                onSubmit: onSubmit,
                onPasteAttachment: onPasteAttachment,
                onPasteImage: onPasteImage,
                onDropAttachment: onDropAttachment
            )
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: height)
        .contentShape(Rectangle())
        .help(onPasteAttachment == nil && onPasteImage == nil
            ? "Return sends · Shift-Return inserts a new line"
            : "Drop or paste files with Command-V · Return sends · Shift-Return inserts a new line")
    }
}

private struct ComposerEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var font: NSFont
    var isEnabled: Bool
    var maximumUTF16Units: Int
    var onSubmit: () -> Void
    var onPasteAttachment: (() -> Bool)?
    var onPasteImage: ((NSImage) -> Void)?
    var onDropAttachment: ((NSPasteboard) -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> ComposerScrollView {
        let scrollView = ComposerScrollView(frame: .zero)
        let editor = scrollView.editor
        editor.delegate = context.coordinator
        configure(editor)
        return scrollView
    }

    func updateNSView(_ scrollView: ComposerScrollView, context: Context) {
        context.coordinator.parent = self
        let editor = scrollView.editor
        configure(editor)
        editor.maximumUTF16Units = maximumUTF16Units
        editor.onSubmit = onSubmit
        editor.onPasteAttachment = onPasteAttachment
        editor.onPasteImage = onPasteImage
        editor.onDropAttachment = onDropAttachment
        editor.registerForDraggedTypes(AttachmentDropReader.draggedTypes)

        let bounded = TextInputPolicy.bounded(text, maximumUTF16Units: maximumUTF16Units)
        if bounded != text {
            DispatchQueue.main.async {
                if self.text != bounded { self.text = bounded }
            }
        }
        if editor.string != bounded {
            context.coordinator.isSynchronizing = true
            let selection = editor.selectedRange()
            editor.string = bounded
            let length = (bounded as NSString).length
            editor.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            context.coordinator.isSynchronizing = false
        }
        if scrollView.wantsEditorFocus != (isFocused && isEnabled) {
            scrollView.wantsEditorFocus = isFocused && isEnabled
        }
    }

    private func configure(_ editor: BoundedComposerTextView) {
        if editor.font != font { editor.font = font }
        if editor.textColor != .labelColor { editor.textColor = .labelColor }
        if editor.insertionPointColor != .labelColor { editor.insertionPointColor = .labelColor }
        if editor.isEditable != isEnabled { editor.isEditable = isEnabled }
        if editor.isSelectable != isEnabled { editor.isSelectable = isEnabled }
        editor.setAccessibilityLabel("Message")
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerEditorRepresentable
        var isSynchronizing = false

        init(parent: ComposerEditorRepresentable) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            if !parent.isFocused { parent.isFocused = true }
        }

        func textDidEndEditing(_ notification: Notification) {
            if parent.isFocused { parent.isFocused = false }
        }

        func textDidChange(_ notification: Notification) {
            guard !isSynchronizing,
                  let editor = notification.object as? NSTextView else { return }
            let bounded = TextInputPolicy.bounded(
                editor.string,
                maximumUTF16Units: parent.maximumUTF16Units
            )
            if parent.text != bounded { parent.text = bounded }
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard !isSynchronizing else { return true }
            guard let replacementString else { return true }
            let currentLength = (textView.string as NSString).length
            let available = max(
                0,
                parent.maximumUTF16Units - (currentLength - affectedCharRange.length)
            )
            guard !TextInputPolicy.boundedResult(
                replacementString,
                maximumUTF16Units: available
            ).wasTruncated else {
                NSSound.beep()
                return false
            }
            return true
        }
    }
}

@MainActor
private final class ComposerScrollView: NSScrollView {
    let editor = BoundedComposerTextView(frame: .zero)
    var wantsEditorFocus = false {
        didSet { focusEditorIfNeeded() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true

        editor.drawsBackground = false
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.minSize = .zero
        editor.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 0, height: 3)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        documentView = editor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusEditorIfNeeded()
    }

    private func focusEditorIfNeeded() {
        guard wantsEditorFocus, let window, window.firstResponder !== editor else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.wantsEditorFocus else { return }
            window.makeFirstResponder(self.editor)
        }
    }
}

@MainActor
final class BoundedComposerTextView: NSTextView {
    var maximumUTF16Units = TextInputPolicy.maximumMessageUTF16Units
    var onSubmit: (() -> Void)?
    var onPasteAttachment: (() -> Bool)?
    var onPasteImage: ((NSImage) -> Void)?
    var onDropAttachment: ((NSPasteboard) -> Bool)?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if onDropAttachment != nil, AttachmentDropReader.canRead(sender.draggingPasteboard, allowPathStrings: true) {
            return isEditable ? .copy : []
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if onDropAttachment != nil, AttachmentDropReader.canRead(sender.draggingPasteboard, allowPathStrings: true) {
            return isEditable ? .copy : []
        }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if onDropAttachment != nil, AttachmentDropReader.canRead(sender.draggingPasteboard, allowPathStrings: true) { return isEditable }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if isEditable, let onDropAttachment, AttachmentDropReader.canRead(sender.draggingPasteboard, allowPathStrings: true) {
            return onDropAttachment(sender.draggingPasteboard)
        }
        return super.performDragOperation(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleEditingShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handleEditingShortcut(_ event: NSEvent) -> Bool {
        // A nonactivating Quick Ask panel may be key while another app owns
        // the menu bar. Route editing commands to this focused editor instead
        // of relying on that app's Edit menu or a SwiftUI scene's commands.
        guard window?.firstResponder === self, isSelectable else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers == [.command] {
            switch key {
            case "a": selectAll(nil)
            case "c": copy(nil)
            case "x" where isEditable: cut(nil)
            case "v" where isEditable: paste(nil)
            case "z" where isEditable: undoManager?.undo()
            default: return false
            }
            return true
        }
        if modifiers == [.command, .shift], key == "z", isEditable {
            undoManager?.redo()
            return true
        }
        return false
    }

    override func keyDown(with event: NSEvent) {
        if handleEditingShortcut(event) { return }
        guard !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        switch composerReturnAction(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
        case .submit:
            onSubmit?()
        case .insertNewline:
            // Insert the line break directly. Routing this through AppKit's
            // insertNewline command can be treated as a submit action by the
            // surrounding SwiftUI responder chain in packaged builds.
            insertText("\n", replacementRange: selectedRange())
        case .systemDefault:
            super.keyDown(with: event)
        }
    }

    override func paste(_ sender: Any?) {
        if onPasteAttachment?() == true { return }
        if pasteImageIfAvailable(from: .general) { return }
        guard let pasted = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        let selection = selectedRange()
        let currentLength = (string as NSString).length
        let available = max(0, maximumUTF16Units - (currentLength - selection.length))
        let result = TextInputPolicy.boundedResult(
            pasted,
            maximumUTF16Units: available
        )
        guard !result.value.isEmpty else {
            if result.wasTruncated { NSSound.beep() }
            return
        }
        insertText(result.value, replacementRange: selection)
        if result.wasTruncated { NSSound.beep() }
    }

    @discardableResult
    func pasteImageIfAvailable(from pasteboard: NSPasteboard) -> Bool {
        guard let onPasteImage, let image = NSImage(pasteboard: pasteboard) else { return false }
        onPasteImage(image)
        return true
    }
}
