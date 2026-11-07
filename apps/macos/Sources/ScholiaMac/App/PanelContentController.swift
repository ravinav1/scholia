@preconcurrency import AppKit
import SwiftUI

/// Hosts SwiftUI inside an AppKit-owned frame without letting content resize the window.
@MainActor
final class PanelContentController<Content: View>: NSViewController {
    init(rootView: Content, size: NSSize) {
        super.init(nibName: nil, bundle: nil)

        // A hosting controller installed directly as a window's content controller can
        // still enter SwiftUI's animated window-sizing path on macOS 27, even with
        // sizingOptions = []. Keep a plain NSView at the window boundary instead.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let hostingView = NSHostingView(rootView: rootView.scholiaButtonStyle(.automatic))
        hostingView.sizingOptions = []
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        view = container
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
