@preconcurrency import AppKit
import SwiftUI

enum ScholiaVisualStyle {
    static let floatingCornerRadius: CGFloat = 18
    static let cardCornerRadius: CGFloat = 13
    static let fastAnimation = Animation.easeOut(duration: 0.16)
    static let panelAnimation = Animation.easeInOut(duration: 0.24)
    static let disclosureAnimation = Animation.snappy(duration: 0.22, extraBounce: 0)
    static let pressAnimation = Animation.easeOut(duration: 0.08)
    static let releaseAnimation = Animation.spring(duration: 0.20, bounce: 0.12)

    static var appKitAnimationsEnabled: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func accentColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 142 / 255, green: 192 / 255, blue: 174 / 255)
            : Color(red: 49 / 255, green: 89 / 255, blue: 78 / 255)
    }
}

extension View {
    /// Keep the system button's appearance and behavior, with a visible click affordance.
    func scholiaButtonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View {
        buttonStyle(ScholiaPointingButtonStyle(style: style))
    }

    func scholiaPointingCursor() -> some View {
        modifier(ScholiaPointingCursorModifier())
    }

    func scholiaFloatingSurface(
        cornerRadius: CGFloat = ScholiaVisualStyle.floatingCornerRadius
    ) -> some View {
        modifier(ScholiaFloatingSurfaceModifier(cornerRadius: cornerRadius))
    }

    func scholiaCardSurface(
        cornerRadius: CGFloat = ScholiaVisualStyle.cardCornerRadius
    ) -> some View {
        modifier(ScholiaCardSurfaceModifier(cornerRadius: cornerRadius))
    }
}

private struct ScholiaPointingButtonStyle<S: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    let style: S

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(style).scholiaPointingCursor()
    }
}

private struct ScholiaPointingCursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(isEnabled ? .link : .default)
        } else {
            content.background(ScholiaCursorRegion(enabled: isEnabled))
        }
    }
}

/// macOS 14 fallback. Cursor rectangles are cleaned up by AppKit when a control
/// disappears, so navigation cannot leave a pointing hand on the cursor stack.
private struct ScholiaCursorRegion: NSViewRepresentable {
    let enabled: Bool

    func makeNSView(context: Context) -> CursorView { CursorView() }
    func updateNSView(_ view: CursorView, context: Context) {
        guard view.enabled != enabled else { return }
        view.enabled = enabled
        view.window?.invalidateCursorRects(for: view)
    }

    final class CursorView: NSView {
        var enabled = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() {
            super.resetCursorRects()
            if enabled { addCursorRect(visibleRect, cursor: .pointingHand) }
        }
    }
}

final class ScholiaPointingButton: NSButton {
    override var isEnabled: Bool {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(visibleRect, cursor: .pointingHand) }
    }
}

private struct ScholiaFloatingSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.regularMaterial, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(
                    .primary.opacity(colorScheme == .dark ? 0.2 : 0.12),
                    lineWidth: 1
                )
            }
    }
}

private struct ScholiaCardSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                .primary.opacity(colorScheme == .dark ? 0.075 : 0.045),
                in: shape
            )
            .overlay {
                shape.strokeBorder(
                    .primary.opacity(colorScheme == .dark ? 0.13 : 0.08),
                    lineWidth: 1
                )
            }
    }
}

struct ScholiaIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        ScholiaIconButtonBody(configuration: configuration, size: size)
    }
}

private struct ScholiaIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .symbolRenderingMode(.hierarchical)
            .frame(width: size, height: size)
            .contentShape(Circle())
            .background(
                .primary.opacity(configuration.isPressed ? 0.14 : (isHovering ? 0.075 : 0.001)),
                in: Circle()
            )
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.94 : 1)
            .animation(reduceMotion ? nil : (configuration.isPressed
                ? ScholiaVisualStyle.pressAnimation : ScholiaVisualStyle.releaseAnimation), value: configuration.isPressed)
            .animation(reduceMotion ? nil : ScholiaVisualStyle.fastAnimation, value: isHovering)
            .onHover { isHovering = $0 }
            .scholiaPointingCursor()
    }
}
