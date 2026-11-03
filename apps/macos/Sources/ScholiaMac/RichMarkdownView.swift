@preconcurrency import AppKit
import cmark_gfm
import cmark_gfm_extensions
import SwiftUI
import SwiftMath

struct RichMarkdownView: View {
    let source: String
    var compact = false
    var registerSelectionView: ((SelfSizingTextView) -> Void)?
    var onOpenLink: ((URL) -> Bool)?
    var references: ChatReferenceContext?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SelectableMarkdownDocument(
            source: source,
            compact: compact,
            colorScheme: colorScheme,
            registerSelectionView: registerSelectionView, onOpenLink: onOpenLink, references: references
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ProviderReasoningView: View {
    let source: String
    var compact = false
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            RichMarkdownView(source: source, compact: true)
                .foregroundStyle(.secondary)
                .padding(.top, compact ? 7 : 9)
        } label: {
            HStack(spacing: 7) {
                Text("Reasoning")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                Spacer(minLength: 10)
                Text("Provided by model")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, compact ? 9 : 11)
        .padding(.vertical, compact ? 7 : 9)
        .background(Color.accentColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.accentColor.opacity(0.24), lineWidth: 1)
        )
        .accessibilityHint("Shows reasoning content returned by the model")
    }
}

struct ConversationActivityView: View {
    let events: [ConversationActivity]
    @State private var expanded = false
    var body: some View {
        if !events.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(events) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "circle.fill").font(.system(size: 5)).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.title).font(.caption.weight(.medium))
                                    if let detail = event.detail, !detail.isEmpty {
                                        Text(detail).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                    }
                                }
                                Spacer(minLength: 3)
                                Text(event.timestamp, format: .dateTime.hour().minute().second())
                                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                        }
                    }.padding(.top, 7)
                }.frame(maxHeight: 190)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Activity · \(events.count)").font(.caption.weight(.semibold))
                    Text(events.last?.title ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }.padding(9).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

enum RichMarkdownPolicy {
    static func canOpen(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https", "mailto"].contains(scheme)
    }
}

enum RichMarkdownMathSizing {
    static let displayScale: CGFloat = 1.08

    static func fontSize(base: CGFloat, display: Bool) -> CGFloat {
        display ? base * displayScale : base
    }
}

enum RichMarkdownMath {
    enum Style: String, Equatable {
        case inline = "scholia-math-inline"
        case display = "scholia-math-display"
    }

    struct Expression: Equatable {
        var latex: String
        var style: Style
    }

    static func prepare(_ source: String) -> String {
        var output = ""
        var index = source.startIndex
        var atLineStart = true
        var codeFence: (character: Character, length: Int)?
        var inlineCodeFenceLength: Int?

        while index < source.endIndex {
            if atLineStart {
                let end = source[index...].firstIndex(of: "\n") ?? source.endIndex
                let line = source[index..<end]
                if let activeCodeFence = codeFence {
                    output += source[index..<end]
                    if end < source.endIndex { output.append("\n") }
                    if isClosingFence(line, matching: activeCodeFence) {
                        codeFence = nil
                    }
                    index = end < source.endIndex ? source.index(after: end) : end
                    atLineStart = true
                    continue
                }
                if let opening = openingFence(in: line) {
                    codeFence = opening
                    output += source[index..<end]
                    if end < source.endIndex { output.append("\n") }
                    index = end < source.endIndex ? source.index(after: end) : end
                    atLineStart = true
                    continue
                }
            }

            let character = source[index]
            if character == "`" {
                let length = runLength(of: "`", in: source, at: index)
                output += source[index..<source.index(index, offsetBy: length)]
                if inlineCodeFenceLength == length { inlineCodeFenceLength = nil }
                else if inlineCodeFenceLength == nil { inlineCodeFenceLength = length }
                index = source.index(index, offsetBy: length)
                atLineStart = false
                continue
            }

            if inlineCodeFenceLength == nil,
               let replacement = mathReplacement(in: source, at: index) {
                output += replacement.markdown
                index = replacement.endIndex
                atLineStart = false
                continue
            }

            output.append(character)
            index = source.index(after: index)
            atLineStart = character == "\n"
        }

        return output
    }

    static func expression(from url: URL?) -> Expression? {
        guard let url,
              let style = Style(rawValue: url.scheme?.lowercased() ?? "") else { return nil }
        let absolute = url.absoluteString
        guard let separator = absolute.firstIndex(of: ":") else { return nil }
        let token = String(absolute[absolute.index(after: separator)...])
        guard let data = base64URLData(token),
              let latex = String(data: data, encoding: .utf8),
              !latex.isEmpty else { return nil }
        return Expression(latex: latex, style: style)
    }

    private struct Replacement {
        var markdown: String
        var endIndex: String.Index
    }

    private static func mathReplacement(in source: String, at index: String.Index) -> Replacement? {
        guard !isEscaped(source, at: index) else { return nil }

        if source[index...].hasPrefix("$$"), !source[index...].hasPrefix("$$$") {
            let contentStart = source.index(index, offsetBy: 2)
            guard let close = closingDelimiter("$$", in: source, after: contentStart) else { return nil }
            let latex = source[contentStart..<close].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latex.isEmpty else { return nil }
            let end = source.index(close, offsetBy: 2)
            return Replacement(
                markdown: "\n\n![LaTeX equation](\(url(for: latex, style: .display)))\n\n",
                endIndex: end
            )
        }

        if source[index...].hasPrefix("\\[") {
            let contentStart = source.index(index, offsetBy: 2)
            guard let close = closingDelimiter("\\]", in: source, after: contentStart) else { return nil }
            let latex = source[contentStart..<close].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latex.isEmpty else { return nil }
            return Replacement(
                markdown: "\n\n![LaTeX equation](\(url(for: latex, style: .display)))\n\n",
                endIndex: source.index(close, offsetBy: 2)
            )
        }

        if source[index...].hasPrefix("\\(") {
            let contentStart = source.index(index, offsetBy: 2)
            guard let close = closingDelimiter("\\)", in: source, after: contentStart) else { return nil }
            let latex = source[contentStart..<close].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !latex.isEmpty else { return nil }
            return Replacement(
                markdown: "![LaTeX equation](\(url(for: latex, style: .inline)))",
                endIndex: source.index(close, offsetBy: 2)
            )
        }

        guard source[index] == "$" else { return nil }
        let contentStart = source.index(after: index)
        guard contentStart < source.endIndex,
              source[contentStart] != "$",
              !source[contentStart].isWhitespace,
              let close = closingInlineDollar(in: source, after: contentStart) else { return nil }
        let latex = source[contentStart..<close].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latex.isEmpty else { return nil }
        return Replacement(
            markdown: "![LaTeX equation](\(url(for: latex, style: .inline)))",
            endIndex: source.index(after: close)
        )
    }

    private static func closingInlineDollar(
        in source: String,
        after start: String.Index
    ) -> String.Index? {
        var cursor = start
        while cursor < source.endIndex {
            let character = source[cursor]
            if character == "\n" { return nil }
            if character == "$", !isEscaped(source, at: cursor) {
                let next = source.index(after: cursor)
                let previous = source.index(before: cursor)
                if (next == source.endIndex || source[next] != "$"),
                   !source[previous].isWhitespace {
                    return cursor
                }
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func closingDelimiter(
        _ delimiter: String,
        in source: String,
        after start: String.Index
    ) -> String.Index? {
        var cursor = start
        while cursor < source.endIndex {
            if source[cursor...].hasPrefix(delimiter), !isEscaped(source, at: cursor) {
                return cursor
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private static func isEscaped(_ source: String, at index: String.Index) -> Bool {
        var cursor = index
        var slashes = 0
        while cursor > source.startIndex {
            cursor = source.index(before: cursor)
            guard source[cursor] == "\\" else { break }
            slashes += 1
        }
        return !slashes.isMultiple(of: 2)
    }

    private static func openingFence(
        in line: Substring
    ) -> (character: Character, length: Int)? {
        var cursor = line.startIndex
        var spaces = 0
        while cursor < line.endIndex, line[cursor] == " ", spaces < 4 {
            spaces += 1
            cursor = line.index(after: cursor)
        }
        guard spaces <= 3, cursor < line.endIndex,
              line[cursor] == "`" || line[cursor] == "~" else { return nil }
        let character = line[cursor]
        let length = runLength(of: character, in: line, at: cursor)
        return length >= 3 ? (character, length) : nil
    }

    private static func isClosingFence(
        _ line: Substring,
        matching fence: (character: Character, length: Int)
    ) -> Bool {
        guard let candidate = openingFence(in: line),
              candidate.character == fence.character,
              candidate.length >= fence.length else { return false }
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor] == " " { cursor = line.index(after: cursor) }
        cursor = line.index(cursor, offsetBy: candidate.length)
        return line[cursor...].allSatisfy(\.isWhitespace)
    }

    private static func runLength<S: StringProtocol>(
        of character: Character,
        in source: S,
        at index: S.Index
    ) -> Int {
        var cursor = index
        var count = 0
        while cursor < source.endIndex, source[cursor] == character {
            count += 1
            cursor = source.index(after: cursor)
        }
        return count
    }

    private static func url(for latex: String, style: Style) -> String {
        let token = Data(latex.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(style.rawValue):\(token)"
    }

    private static func base64URLData(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }

}

private struct SelectableMarkdownDocument: NSViewRepresentable {
    var source: String
    var compact: Bool
    var colorScheme: ColorScheme
    var registerSelectionView: ((SelfSizingTextView) -> Void)?
    var onOpenLink: ((URL) -> Bool)?
    var references: ChatReferenceContext?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SelfSizingTextView {
        let textView = SelfSizingTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        // Keep the native link cursor for Copy code and source links while
        // letting the renderer supply their text styling.
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.usesFindPanel = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        registerSelectionView?(textView)
        return textView
    }

    func updateNSView(_ textView: SelfSizingTextView, context: Context) {
        context.coordinator.onOpenLink = onOpenLink
        textView.onOpenSourceLink = onOpenLink
        registerSelectionView?(textView)
        textView.updateMarkdown(source, compact: compact, colorScheme: colorScheme,
            width: max(280, textView.bounds.width), references: references)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: SelfSizingTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.requiredHeight(for: width))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onOpenLink: ((URL) -> Bool)?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = link as? URL ?? (link as? String).flatMap(URL.init(string:))
            if url?.scheme == "scholia-copy-code", let storage = textView.textStorage, charIndex < storage.length,
                let source = storage.attribute(.scholiaCodeSource, at: charIndex, effectiveRange: nil) as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source, forType: .string)
                return true
            }
            guard let url else { return true }
            if onOpenLink?(url) == true { return true }
            guard RichMarkdownPolicy.canOpen(url) else { return true }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}

private extension NSAttributedString.Key {
    static let scholiaMathSource = NSAttributedString.Key("ScholiaMathSource")
    static let scholiaCodeSource = NSAttributedString.Key("ScholiaCodeSource")
    static let scholiaCodeBlock = NSAttributedString.Key("ScholiaCodeBlock")
    static let scholiaInlineCode = NSAttributedString.Key("ScholiaInlineCode")
}

final class SelfSizingTextView: NSTextView {
    var onOpenSourceLink: ((URL) -> Bool)?
    private var renderedSource = ""
    private var renderedCompact: Bool?
    private var renderedDarkMode: Bool?
    private var mathLayoutWidth: CGFloat?
    private var renderedReferences: ChatReferenceContext?

    /// Window and split-pane resizing should only reflow existing text. Parsing,
    /// highlighting, and equation typesetting are needed when content changes.
    func updateMarkdown(_ source: String, compact: Bool, colorScheme: ColorScheme, width: CGFloat, references: ChatReferenceContext? = nil) {
        let isDark = colorScheme == .dark
        guard renderedSource != source || renderedCompact != compact || renderedDarkMode != isDark || renderedReferences != references else {
            resizeDisplayMath(for: width)
            return
        }
        renderedSource = source
        renderedCompact = compact
        renderedDarkMode = isDark
        renderedReferences = references
        let selection = selectedRange()
        let document = RichMarkdownDocumentRenderer(compact: compact, colorScheme: colorScheme,
            availableWidth: width, references: references).render(source)
        textStorage?.setAttributedString(document)
        mathLayoutWidth = width
        if NSMaxRange(selection) <= document.length { setSelectedRange(selection) }
        invalidateIntrinsicContentSize()
    }

    private func resizeDisplayMath(for width: CGFloat) {
        guard mathLayoutWidth.map({ abs($0 - width) > 0.5 }) ?? true, let storage = textStorage else { return }
        mathLayoutWidth = width
        // Only attachments change their attributes. Keeping the same text
        // storage also preserves selection and native code/link interactions.
        storage.beginEditing()
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? NativeMathTextAttachment,
                attachment.resize(for: width) else { return }
            storage.edited(.editedAttributes, range: range, changeInLength: 0)
        }
        storage.endEditing()
    }

    /// AppKit's link delegate is not consistently invoked for custom-scheme
    /// links in text-table cells. Handle the actual code-control glyphs as a
    /// button before NSTextView starts selecting text.
    func codeSource(at point: NSPoint) -> String? {
        guard let textContainer, let layoutManager, let storage = textStorage, storage.length > 0 else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        let location = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let index = layoutManager.characterIndex(for: location, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < storage.length else { return nil }
        var range = NSRange()
        guard let source = storage.attribute(.scholiaCodeSource, at: index, effectiveRange: &range) as? String else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        // characterIndex returns the nearest character, even in whitespace.
        guard bounds.contains(location) else { return nil }
        return source
    }

    func sourceLink(at point: NSPoint) -> URL? {
        guard let textContainer, let layoutManager, let storage = textStorage, storage.length > 0 else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let location = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let index = layoutManager.characterIndex(for: location, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < storage.length, let url = storage.attribute(.link, at: index, effectiveRange: nil) as? URL,
              url.scheme == "scholia-source" else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        guard layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer).contains(location) else { return nil }
        return url
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if let event, codeSource(at: convert(event.locationInWindow, from: nil)) != nil { return true }
        return super.acceptsFirstMouse(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if let source = codeSource(at: convert(event.locationInWindow, from: nil)) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(source, forType: .string)
            return
        }
        if let url = sourceLink(at: convert(event.locationInWindow, from: nil)), onOpenSourceLink?(url) == true { return }
        super.mouseDown(with: event)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: requiredHeight(for: max(1, bounds.width))
        )
    }

    func requiredHeight(for width: CGFloat) -> CGFloat {
        guard let textContainer, let layoutManager else { return 1 }
        let contentWidth = max(1, width - textContainerInset.width * 2)
        resizeDisplayMath(for: contentWidth)
        if abs(textContainer.containerSize.width - contentWidth) > 0.5 {
            textContainer.containerSize = NSSize(
                width: contentWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        layoutManager.ensureLayout(for: textContainer)
        return ceil(layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard let selection = attributedSelection(in: range) else {
            super.copy(sender)
            return
        }
        let fullRange = NSRange(location: 0, length: selection.length)
        let plainText = Self.plainText(from: selection)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plainText, forType: .string)
        if let richText = try? selection.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            pasteboard.setData(richText, forType: .rtf)
        }
    }

    func selectedPlainText() -> String? {
        guard let selection = attributedSelection(in: selectedRange()) else { return nil }
        let text = Self.plainText(from: selection)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(SelectionReader.maximumSelectionLength))
    }

    private func attributedSelection(in range: NSRange) -> NSAttributedString? {
        guard range.length > 0,
              let storage = textStorage,
              NSMaxRange(range) <= storage.length else { return nil }
        return storage.attributedSubstring(from: range)
    }

    private static func plainText(from selection: NSAttributedString) -> String {
        let fullRange = NSRange(location: 0, length: selection.length)
        var plainText = ""
        selection.enumerateAttribute(.scholiaMathSource, in: fullRange) { value, range, _ in
            if let source = value as? String { plainText += source }
            else { plainText += selection.attributedSubstring(from: range).string }
        }
        return plainText
    }
}

private typealias MarkdownNode = UnsafeMutablePointer<cmark_node>

private enum MarkdownParser {
    static func parse<Result>(
        _ markdown: String,
        body: (MarkdownNode) -> Result
    ) -> Result? {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return nil }
        defer { cmark_parser_free(parser) }
        for name in ["autolink", "strikethrough", "tagfilter", "tasklist", "table"] {
            if let syntaxExtension = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, syntaxExtension)
            }
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return nil }
        defer { cmark_node_free(document) }
        return body(document)
    }

    static func children(of node: MarkdownNode) -> [MarkdownNode] {
        var values: [MarkdownNode] = []
        var child = cmark_node_first_child(node)
        while let current = child {
            values.append(current)
            child = cmark_node_next(current)
        }
        return values
    }

    static func type(of node: MarkdownNode) -> String {
        String(cString: cmark_node_get_type_string(node))
    }

    static func literal(of node: MarkdownNode) -> String {
        cmark_node_get_literal(node).map(String.init(cString:)) ?? ""
    }

    static func url(of node: MarkdownNode) -> URL? {
        cmark_node_get_url(node).map(String.init(cString:)).flatMap(URL.init(string:))
    }
}

@MainActor
final class RichMarkdownDocumentRenderer {
    private struct InlineStyle {
        var size: CGFloat
        var bold = false
        var italic = false
        var monospaced = false
        var strikethrough = false
        var link: URL?
        var color: NSColor = .labelColor
        var backgroundColor: NSColor?
    }

    private let compact: Bool
    private let colorScheme: ColorScheme
    private let availableWidth: CGFloat
    private let references: ChatReferenceContext?
    private let output = NSMutableAttributedString()

    init(compact: Bool, colorScheme: ColorScheme, availableWidth: CGFloat, references: ChatReferenceContext? = nil) {
        self.compact = compact
        self.colorScheme = colorScheme
        self.availableWidth = availableWidth
        self.references = references
    }

    func render(_ source: String) -> NSAttributedString {
        let prepared = RichMarkdownMath.prepare(source)
        _ = MarkdownParser.parse(prepared) { document in
            for child in MarkdownParser.children(of: document) { renderBlock(child) }
        }
        while output.string.hasSuffix("\n\n") {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        linkSavedReferences()
        return output.copy() as? NSAttributedString ?? output
    }

    private func linkSavedReferences() {
        guard let references else { return }
        for link in references.links(in: output.string) {
            var excluded = false
            output.enumerateAttributes(in: link.range) { attributes, _, stop in
                if attributes[.link] != nil || attributes[.scholiaCodeBlock] != nil
                    || attributes[.scholiaMathSource] != nil || (link.isPage && attributes[.scholiaInlineCode] != nil) {
                    excluded = true
                    stop.pointee = true
                }
            }
            guard !excluded else { continue }
            output.addAttributes([.link: link.url, .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue, .toolTip: link.help], range: link.range)
        }
    }

    private var bodySize: CGFloat { compact ? 13 : 14 }

    private var baseStyle: InlineStyle { InlineStyle(size: bodySize) }

    // NSTextView can resolve translucent semantic background colors against the
    // panel's vibrancy appearance instead of SwiftUI's requested color scheme.
    // Keep code colors opaque and tied to the scheme that rendered the document
    // so light-mode text can never land on a dark-mode code background.
    private var codeBlockBackgroundColor: NSColor {
        if colorScheme == .dark {
            return NSColor(srgbRed: 0.075, green: 0.105, blue: 0.095, alpha: 1)
        }
        // Quick Chat sits on a light material surface, so its compact code blocks
        // need a little more separation than code in the regular chat window.
        return compact
            ? NSColor(srgbRed: 0.855, green: 0.89, blue: 0.875, alpha: 1)
            : NSColor(srgbRed: 0.925, green: 0.94, blue: 0.935, alpha: 1)
    }

    private var codeBlockTextColor: NSColor {
        colorScheme == .dark
            ? NSColor(srgbRed: 0.91, green: 0.945, blue: 0.935, alpha: 1)
            : NSColor(srgbRed: 0.095, green: 0.135, blue: 0.12, alpha: 1)
    }

    private var codeBlockLabelColor: NSColor {
        if colorScheme == .dark {
            return NSColor(srgbRed: 0.62, green: 0.70, blue: 0.675, alpha: 1)
        }
        return compact
            ? NSColor(srgbRed: 0.285, green: 0.36, blue: 0.335, alpha: 1)
            : NSColor(srgbRed: 0.36, green: 0.425, blue: 0.405, alpha: 1)
    }

    private var codeBlockBorderColor: NSColor {
        colorScheme == .dark
            ? NSColor(srgbRed: 0.23, green: 0.30, blue: 0.27, alpha: 1)
            : NSColor(srgbRed: 0.80, green: 0.84, blue: 0.82, alpha: 1)
    }

    private func renderBlock(_ node: MarkdownNode, listDepth: Int = 0) {
        switch MarkdownParser.type(of: node) {
        case "paragraph":
            if let expression = soleDisplayExpression(in: node) {
                renderDisplayMath(expression)
            } else {
                let start = output.length
                renderInlineChildren(of: node, style: baseStyle, into: output)
                finishParagraph(from: start, spacing: compact ? 8 : 10)
            }
        case "heading":
            renderHeading(node)
        case "block_quote":
            renderBlockquote(node)
        case "list":
            renderList(node, depth: listDepth)
        case "code_block":
            renderCodeBlock(node)
        case "table":
            renderTable(node)
        case "thematic_break":
            let start = output.length
            append("────────────────────────", style: InlineStyle(
                size: bodySize,
                color: .separatorColor
            ), to: output)
            finishParagraph(from: start, spacing: compact ? 8 : 10)
        case "html_block":
            let value = MarkdownParser.literal(of: node).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            let start = output.length
            appendMathAwareLiteral(value, style: baseStyle, to: output)
            finishParagraph(from: start, spacing: compact ? 8 : 10)
        default:
            for child in MarkdownParser.children(of: node) {
                renderBlock(child, listDepth: listDepth)
            }
        }
    }

    private func renderHeading(_ node: MarkdownNode) {
        let level = max(1, Int(cmark_node_get_heading_level(node)))
        let scale: CGFloat
        switch level {
        case 1: scale = compact ? 1.34 : 1.42
        case 2: scale = compact ? 1.2 : 1.27
        case 3: scale = compact ? 1.1 : 1.14
        default: scale = 1.04
        }
        let start = output.length
        var style = baseStyle
        style.size *= scale
        style.bold = true
        renderInlineChildren(of: node, style: style, into: output)
        finishParagraph(
            from: start,
            spacingBefore: level <= 2 ? (compact ? 10 : 13) : 8,
            spacing: compact ? 6 : 7
        )
    }

    private func renderBlockquote(_ node: MarkdownNode) {
        let start = output.length
        append("▎ ", style: InlineStyle(
            size: bodySize,
            bold: true,
            color: .controlAccentColor
        ), to: output)
        let children = MarkdownParser.children(of: node)
        for (index, child) in children.enumerated() {
            if MarkdownParser.type(of: child) == "paragraph" {
                var style = baseStyle
                style.color = .secondaryLabelColor
                renderInlineChildren(of: child, style: style, into: output)
                if index < children.count - 1 { append("\n", style: style, to: output) }
            } else {
                renderBlock(child)
            }
        }
        finishParagraph(from: start, spacing: compact ? 8 : 10, headIndent: 14)
    }

    private func renderList(_ node: MarkdownNode, depth: Int) {
        let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
        let startNumber = max(1, Int(cmark_node_get_list_start(node)))
        for (offset, item) in MarkdownParser.children(of: node).enumerated() {
            let itemType = MarkdownParser.type(of: item)
            let marker: String
            if itemType == "tasklist" {
                marker = cmark_gfm_extensions_get_tasklist_item_checked(item) ? "☑" : "☐"
            } else {
                marker = ordered ? "\(startNumber + offset)." : "•"
            }
            var emittedFirstParagraph = false
            for child in MarkdownParser.children(of: item) {
                if MarkdownParser.type(of: child) == "paragraph" {
                    let start = output.length
                    if !emittedFirstParagraph {
                        append(marker + "\t", style: baseStyle, to: output)
                        emittedFirstParagraph = true
                    }
                    renderInlineChildren(of: child, style: baseStyle, into: output)
                    finishListParagraph(from: start, depth: depth)
                } else if MarkdownParser.type(of: child) == "list" {
                    renderList(child, depth: depth + 1)
                } else {
                    renderBlock(child, listDepth: depth + 1)
                }
            }
        }
    }

    private func renderCodeBlock(_ node: MarkdownNode) {
        let start = output.length
        let info = cmark_node_get_fence_info(node).map(String.init(cString:))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let literal = MarkdownParser.literal(of: node)
        let code = literal.hasSuffix("\n") ? String(literal.dropLast()) : literal
        var fenceLength: Int32 = 0
        var fenceOffset: Int32 = 0
        var fenceCharacter: CChar = 0
        let isFenced = cmark_node_get_fenced(node, &fenceLength, &fenceOffset, &fenceCharacter) != 0
        // Models sometimes indent prose. cmark then treats the paragraph as literal code,
        // including the equation placeholders inserted before parsing. Render those as
        // prose with math; explicit fenced examples keep their literal code formatting.
        if !isFenced, !Self.mathPlaceholders(in: code).isEmpty {
            appendMathAwareLiteral(code, style: baseStyle, to: output)
            finishParagraph(from: start, spacing: compact ? 8 : 10)
            return
        }
        let language = info.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased() ?? ""
        let table = NSTextTable()
        table.numberOfColumns = 2
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.setContentWidth(100, type: .percentageValueType)
        func block(row: Int, column: Int = 0) -> NSTextTableBlock {
            let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: row == 0 ? 1 : 2)
            cell.setContentWidth(row == 0 ? 50 : 100, type: .percentageValueType)
            cell.setWidth(0.5, type: .absoluteValueType, for: .border)
            cell.setWidth(compact ? 8 : 11, type: .absoluteValueType, for: .padding)
            cell.setBorderColor(codeBlockBorderColor)
            if row == 0 {
                cell.setWidth(0, type: .absoluteValueType, for: .border, edge: column == 0 ? .maxX : .minX)
                cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minY)
                cell.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
            }
            cell.backgroundColor = row == 0
                ? (colorScheme == .dark ? NSColor(srgbRed: 0.13, green: 0.18, blue: 0.16, alpha: 1)
                    : NSColor(srgbRed: 0.89, green: 0.92, blue: 0.90, alpha: 1))
                : codeBlockBackgroundColor
            return cell
        }
        let labelStyle = InlineStyle(size: compact ? 9 : 10, bold: true, color: codeBlockLabelColor)
        append((language.isEmpty ? "Plain text" : language) + "\n", style: labelStyle, to: output)
        let header = NSMutableParagraphStyle()
        header.textBlocks = [block(row: 0)]
        output.addAttribute(.paragraphStyle, value: header, range: NSRange(location: start, length: output.length - start))
        let copyStart = output.length
        append("Copy code", style: labelStyle, to: output)
        output.addAttributes([.link: URL(string: "scholia-copy-code:copy")!, .scholiaCodeSource: code],
            range: NSRange(location: copyStart, length: output.length - copyStart))
        append("\n", style: labelStyle, to: output)
        let copyHeader = NSMutableParagraphStyle()
        copyHeader.textBlocks = [block(row: 0, column: 1)]
        copyHeader.alignment = .right
        output.addAttribute(.paragraphStyle, value: copyHeader, range: NSRange(location: copyStart, length: output.length - copyStart))
        let codeStart = output.length
        append(code, style: InlineStyle(
            size: compact ? 11 : 12,
            monospaced: true,
            color: codeBlockTextColor
        ), to: output)
        for run in NativeCodeHighlight.runs(code, language: language) {
            guard let location = run["location"] as? Int, let length = run["length"] as? Int,
                let scope = run["scope"] as? String, location >= 0, length > 0,
                location + length <= code.utf16.count else { continue }
            output.addAttribute(.foregroundColor, value: NativeCodeHighlight.color(scope, dark: colorScheme == .dark),
                range: NSRange(location: codeStart + location, length: length))
        }
        append("\n", style: InlineStyle(size: compact ? 11 : 12, monospaced: true, color: codeBlockTextColor), to: output)
        let body = NSMutableParagraphStyle()
        body.textBlocks = [block(row: 1)]
        body.lineSpacing = 2
        body.paragraphSpacing = 0
        body.lineBreakMode = .byCharWrapping
        body.defaultTabInterval = (compact ? 11 : 12) * 2.4
        output.addAttribute(.paragraphStyle, value: body, range: NSRange(location: codeStart, length: output.length - codeStart))
        output.addAttribute(.scholiaCodeBlock, value: true, range: NSRange(location: start, length: output.length - start))
        // Space belongs after the whole panel, not after each source-code line.
        let spacer = output.length
        append("\n", style: InlineStyle(size: 4), to: output)
        let spacing = NSMutableParagraphStyle()
        spacing.paragraphSpacing = compact ? 5 : 7
        output.addAttribute(.paragraphStyle, value: spacing, range: NSRange(location: spacer, length: 1))
    }

    private func renderTable(_ node: MarkdownNode) {
        let rows = MarkdownParser.children(of: node)
        let columnCount = rows.map { MarkdownParser.children(of: $0).count }.max() ?? 0
        guard columnCount > 0 else { return }

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        let alignments = tableAlignments(for: node, count: columnCount)

        for (rowIndex, row) in rows.enumerated() {
            let isHeader = MarkdownParser.type(of: row) == "table_header" || rowIndex == 0
            let cells = MarkdownParser.children(of: row)
            for column in 0..<columnCount {
                let start = output.length
                if cells.indices.contains(column) {
                    var style = baseStyle
                    style.size *= 0.92
                    style.bold = isHeader
                    renderInlineChildren(of: cells[column], style: style, into: output)
                }
                if output.length == start { append(" ", style: baseStyle, to: output) }
                append("\n", style: baseStyle, to: output)

                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: column,
                    columnSpan: 1
                )
                block.verticalAlignment = .middleAlignment
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setWidth(compact ? 5 : 6, type: .absoluteValueType, for: .padding)
                block.setBorderColor(.separatorColor)
                block.backgroundColor = isHeader
                    ? NSColor.controlAccentColor.withAlphaComponent(0.1)
                    : (rowIndex.isMultiple(of: 2)
                        ? NSColor.clear
                        : NSColor.labelColor.withAlphaComponent(0.035))

                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.alignment = alignments[column]
                paragraph.lineSpacing = compact ? 1 : 2
                output.addAttribute(
                    .paragraphStyle,
                    value: paragraph,
                    range: NSRange(location: start, length: output.length - start)
                )
            }
        }
        let spacerStart = output.length
        append("\n", style: baseStyle, to: output)
        let spacer = NSMutableParagraphStyle()
        spacer.paragraphSpacing = compact ? 8 : 10
        output.addAttribute(
            .paragraphStyle,
            value: spacer,
            range: NSRange(location: spacerStart, length: 1)
        )
    }

    private func tableAlignments(for node: MarkdownNode, count: Int) -> [NSTextAlignment] {
        let pointer = cmark_gfm_extensions_get_table_alignments(node)
        return (0..<count).map { index in
            guard let pointer else { return .left }
            switch Character(UnicodeScalar(pointer[index])) {
            case "c": return .center
            case "r": return .right
            default: return .left
            }
        }
    }

    private func renderInlineChildren(
        of node: MarkdownNode,
        style: InlineStyle,
        into target: NSMutableAttributedString
    ) {
        for child in MarkdownParser.children(of: node) {
            renderInline(child, style: style, into: target)
        }
    }

    private func renderInline(
        _ node: MarkdownNode,
        style: InlineStyle,
        into target: NSMutableAttributedString
    ) {
        switch MarkdownParser.type(of: node) {
        case "text":
            append(MarkdownParser.literal(of: node), style: style, to: target)
        case "softbreak":
            append(" ", style: style, to: target)
        case "linebreak":
            append("\n", style: style, to: target)
        case "code":
            var codeStyle = style
            codeStyle.monospaced = true
            codeStyle.size *= 0.9
            codeStyle.backgroundColor = .separatorColor.withAlphaComponent(0.16)
            let start = target.length
            append(MarkdownParser.literal(of: node), style: codeStyle, to: target)
            target.addAttribute(.scholiaInlineCode, value: true, range: NSRange(location: start, length: target.length - start))
        case "emph":
            var next = style
            next.italic = true
            renderInlineChildren(of: node, style: next, into: target)
        case "strong":
            var next = style
            next.bold = true
            renderInlineChildren(of: node, style: next, into: target)
        case "strikethrough":
            var next = style
            next.strikethrough = true
            renderInlineChildren(of: node, style: next, into: target)
        case "link":
            var next = style
            if let url = MarkdownParser.url(of: node) {
                if let local = references?.localURL(for: url) { next.link = local }
                else if RichMarkdownPolicy.canOpen(url) { next.link = url }
                if next.link != nil { next.color = .linkColor }
            }
            renderInlineChildren(of: node, style: next, into: target)
        case "image":
            if let expression = RichMarkdownMath.expression(from: MarkdownParser.url(of: node)) {
                target.append(mathAttachment(for: expression, inlineFontSize: style.size))
            } else {
                append("[External image omitted]", style: InlineStyle(
                    size: style.size * 0.9,
                    italic: true,
                    color: .secondaryLabelColor
                ), to: target)
            }
        case "html_inline":
            let html = MarkdownParser.literal(of: node)
            append(html.lowercased().hasPrefix("<br") ? "\n" : html, style: style, to: target)
        default:
            renderInlineChildren(of: node, style: style, into: target)
        }
    }

    private func soleDisplayExpression(in paragraph: MarkdownNode) -> RichMarkdownMath.Expression? {
        let children = MarkdownParser.children(of: paragraph)
        guard children.count == 1,
              MarkdownParser.type(of: children[0]) == "image",
              let expression = RichMarkdownMath.expression(from: MarkdownParser.url(of: children[0])),
              expression.style == .display else { return nil }
        return expression
    }

    private func renderDisplayMath(_ expression: RichMarkdownMath.Expression) {
        let start = output.length
        output.append(mathAttachment(for: expression, inlineFontSize: bodySize))
        finishParagraph(
            from: start,
            spacingBefore: compact ? 4 : 6,
            spacing: compact ? 10 : 12,
            alignment: .center
        )
    }

    private func mathAttachment(
        for expression: RichMarkdownMath.Expression,
        inlineFontSize: CGFloat
    ) -> NSAttributedString {
        let display = expression.style == .display
        let size = RichMarkdownMathSizing.fontSize(
            base: inlineFontSize,
            display: display
        )
        guard let image = NativeMathImageRenderer.image(
            latex: expression.latex,
            display: display,
            fontSize: size,
            colorScheme: colorScheme
        ) else {
            let fences = display ? "$$" : "$"
            return NSAttributedString(
                string: fences + expression.latex + fences,
                attributes: attributes(for: InlineStyle(size: inlineFontSize, monospaced: true))
            )
        }
        let attachment = NativeMathTextAttachment(image: image, display: display, availableWidth: availableWidth)
        let value = NSMutableAttributedString(attachment: attachment)
        let fences = display ? "$$" : "$"
        value.addAttribute(
            .scholiaMathSource,
            value: fences + expression.latex + fences,
            range: NSRange(location: 0, length: value.length)
        )
        return value
    }

    private static let mathPlaceholderPattern = try! NSRegularExpression(
        pattern: #"!\[LaTeX equation\]\((scholia-math-(?:inline|display):[A-Za-z0-9_-]+)\)"#
    )

    private static func mathPlaceholders(in value: String) -> [NSTextCheckingResult] {
        mathPlaceholderPattern.matches(in: value, range: NSRange(value.startIndex..., in: value))
    }

    private func appendMathAwareLiteral(
        _ value: String,
        style: InlineStyle,
        to target: NSMutableAttributedString
    ) {
        let text = value as NSString
        var cursor = 0
        for match in Self.mathPlaceholders(in: value) {
            guard let expression = RichMarkdownMath.expression(
                from: URL(string: text.substring(with: match.range(at: 1)))
            ) else { continue }
            append(text.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                   style: style, to: target)
            target.append(mathAttachment(for: expression, inlineFontSize: style.size))
            cursor = NSMaxRange(match.range)
        }
        append(text.substring(from: cursor), style: style, to: target)
    }

    private func append(
        _ value: String,
        style: InlineStyle,
        to target: NSMutableAttributedString
    ) {
        target.append(NSAttributedString(string: value, attributes: attributes(for: style)))
    }

    private func attributes(for style: InlineStyle) -> [NSAttributedString.Key: Any] {
        var font = style.monospaced
            ? NSFont.monospacedSystemFont(ofSize: style.size, weight: style.bold ? .semibold : .regular)
            : NSFont.systemFont(ofSize: style.size, weight: style.bold ? .semibold : .regular)
        if style.italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        var values: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.color
        ]
        if style.strikethrough {
            values[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = style.link {
            values[.link] = link
            values[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if let backgroundColor = style.backgroundColor {
            values[.backgroundColor] = backgroundColor
        }
        return values
    }

    private func finishParagraph(
        from start: Int,
        spacingBefore: CGFloat = 0,
        spacing: CGFloat,
        headIndent: CGFloat = 0,
        firstLineHeadIndent: CGFloat? = nil,
        alignment: NSTextAlignment = .left,
        textBlocks: [NSTextBlock] = []
    ) {
        append("\n", style: baseStyle, to: output)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = compact ? 1.5 : 2
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.paragraphSpacing = spacing
        paragraph.headIndent = headIndent
        paragraph.firstLineHeadIndent = firstLineHeadIndent ?? headIndent
        paragraph.alignment = alignment
        paragraph.textBlocks = textBlocks
        output.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: start, length: output.length - start)
        )
    }

    private func finishListParagraph(from start: Int, depth: Int) {
        append("\n", style: baseStyle, to: output)
        let baseIndent = CGFloat(depth) * (compact ? 16 : 18)
        let markerWidth: CGFloat = compact ? 18 : 21
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = baseIndent
        paragraph.headIndent = baseIndent + markerWidth
        paragraph.tabStops = [NSTextTab(
            textAlignment: .left,
            location: baseIndent + markerWidth,
            options: [:]
        )]
        paragraph.lineSpacing = compact ? 1 : 2
        paragraph.paragraphSpacing = compact ? 3 : 4
        output.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: start, length: output.length - start)
        )
    }
}

@MainActor
private final class NativeMathTextAttachment: NSTextAttachment {
    private let display: Bool

    init(image: NSImage, display: Bool, availableWidth: CGFloat) {
        self.display = display
        super.init(data: nil, ofType: nil)
        self.image = image
        bounds = NSRect(x: 0, y: display ? -4 : -max(1, image.size.height * 0.18),
            width: image.size.width, height: image.size.height)
        resize(for: availableWidth)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    func resize(for availableWidth: CGFloat) -> Bool {
        guard display, let image else { return false }
        let scale = min(1, max(120, availableWidth - 20) / image.size.width)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard bounds.size != size else { return false }
        bounds.size = size
        return true
    }
}

@MainActor
private enum NativeMathImageRenderer {
    // Images retain SwiftMath's display lists and AppKit may rasterize them at
    // Retina resolution. Bound their estimated backing cost as well as count,
    // and let AppKit evict them under pressure instead of retaining a dictionary.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    static func image(
        latex: String,
        display: Bool,
        fontSize: CGFloat,
        colorScheme: ColorScheme
    ) -> NSImage? {
        let key = "\(display)|\(Int((fontSize * 10).rounded()))|\(colorScheme == .dark)|\(latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let renderer = MTMathImage(
            latex: latex,
            fontSize: fontSize,
            textColor: colorScheme == .dark ? NSColor.white : NSColor.black,
            labelMode: display ? .display : .text,
            textAlignment: display ? .center : .left
        )
        renderer.font = MTFontManager().latinModernFont(withSize: fontSize)
        renderer.contentInsets = NSEdgeInsets(
            top: display ? 5 : 1,
            left: display ? 7 : 1,
            bottom: display ? 5 : 1,
            right: display ? 7 : 1
        )
        let (_, renderedImage) = renderer.asImage()
        guard let image = renderedImage, image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        let estimatedCost = ceil(image.size.width) * ceil(image.size.height) * 16 + CGFloat(latex.utf8.count * 8)
        if estimatedCost.isFinite, estimatedCost <= CGFloat(cache.totalCostLimit) {
            cache.setObject(image, forKey: key, cost: Int(estimatedCost))
        }
        return image
    }
}
