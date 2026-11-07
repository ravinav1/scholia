import AppKit
import QuartzCore
import SwiftUI

@MainActor
func setStudyPaneCollapsed(_ collapsed: Bool, item: NSSplitViewItem, animated: Bool) {
    guard item.isCollapsed != collapsed else { return }
    guard animated, ScholiaVisualStyle.appKitAnimationsEnabled else {
        item.isCollapsed = collapsed
        return
    }
    NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.20
        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        item.animator().isCollapsed = collapsed
    }
}

/// Keep the library width independent of the document/tutor divider.
struct StudySidebarSplitView<Sidebar: View, Content: View>: NSViewControllerRepresentable {
    var sidebar: Sidebar
    var content: Content
    var sidebarVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSViewController(context: Context) -> Controller {
        Controller(sidebar: sidebar, content: content)
    }
    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.sidebarHost.rootView = sidebar
        controller.contentHost.rootView = content
        if controller.sidebarVisible != sidebarVisible {
            setStudyPaneCollapsed(!sidebarVisible, item: controller.splitViewItems[0],
                animated: !reduceMotion && controller.sidebarVisible != nil && controller.view.window != nil)
            controller.sidebarVisible = sidebarVisible
        }
    }
    final class Controller: NSSplitViewController {
        let sidebarHost: NSHostingController<Sidebar>
        let contentHost: NSHostingController<Content>
        private var positioned = false
        var sidebarVisible: Bool?
        init(sidebar: Sidebar, content: Content) {
            sidebarHost = NSHostingController(rootView: sidebar)
            contentHost = NSHostingController(rootView: content)
            super.init(nibName: nil, bundle: nil)
            sidebarHost.sizingOptions = []
            contentHost.sizingOptions = []
            splitView.isVertical = true
            splitView.dividerStyle = .thin
            splitView.autosaveName = "ScholiaLibrarySplit"
            splitView.setAccessibilityLabel("Course library and workspace")
            let library = NSSplitViewItem(viewController: sidebarHost)
            library.minimumThickness = 190
            library.maximumThickness = 460
            library.canCollapse = true
            library.holdingPriority = .init(251)
            let main = NSSplitViewItem(viewController: contentHost)
            main.minimumThickness = 560
            main.holdingPriority = .init(249)
            addSplitViewItem(library)
            addSplitViewItem(main)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidLayout() {
            super.viewDidLayout()
            guard !positioned, splitView.bounds.width > 750 else { return }
            positioned = true
            if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames ScholiaLibrarySplit") == nil {
                splitView.setPosition(224, ofDividerAt: 0)
            }
        }
    }
}

/// AppKit owns the divider and its constraints; resizing never recreates the reader.
struct StudyWorkspaceSplitView<Reader: View, Tutor: View>: NSViewControllerRepresentable {
    var reader: Reader
    var tutor: Tutor
    var tutorVisible: Bool
    var readerReset: Int
    var minimumReaderWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSViewController(context: Context) -> Controller {
        Controller(reader: reader, tutor: tutor, minimumReaderWidth: minimumReaderWidth)
    }
    func updateNSViewController(_ controller: Controller, context: Context) {
        if controller.lastReset != readerReset {
            controller.lastReset = readerReset
            controller.splitView.setPosition(
                max(minimumReaderWidth, controller.splitView.bounds.width - 390), ofDividerAt: 0)
        }
        controller.readerHost.rootView = reader
        controller.tutorHost.rootView = tutor
        if controller.splitViewItems[0].minimumThickness != minimumReaderWidth {
            controller.splitViewItems[0].minimumThickness = minimumReaderWidth
        }
        if controller.tutorVisible != tutorVisible {
            setStudyPaneCollapsed(!tutorVisible, item: controller.splitViewItems[1],
                animated: !reduceMotion && controller.tutorVisible != nil && controller.view.window != nil)
            controller.tutorVisible = tutorVisible
        }
    }
    final class Controller: NSSplitViewController {
        let readerHost: NSHostingController<Reader>
        let tutorHost: NSHostingController<Tutor>
        private var positioned = false
        var lastReset = 0
        var tutorVisible: Bool?
        init(reader: Reader, tutor: Tutor, minimumReaderWidth: CGFloat) {
            readerHost = NSHostingController(rootView: reader)
            tutorHost = NSHostingController(rootView: tutor)
            super.init(nibName: nil, bundle: nil)
            readerHost.sizingOptions = []
            tutorHost.sizingOptions = []
            splitView.isVertical = true
            splitView.dividerStyle = .thin
            splitView.autosaveName = "ScholiaDocumentTutorSplit"
            let reading = NSSplitViewItem(viewController: readerHost)
            reading.minimumThickness = minimumReaderWidth
            reading.holdingPriority = .init(249)
            let chat = NSSplitViewItem(viewController: tutorHost)
            chat.minimumThickness = 220
            chat.canCollapse = true
            chat.holdingPriority = .init(250)
            addSplitViewItem(reading)
            addSplitViewItem(chat)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidLayout() {
            super.viewDidLayout()
            guard !positioned, splitView.bounds.width > 400 else { return }
            positioned = true
            if UserDefaults.standard.object(forKey: "NSSplitView Subview Frames ScholiaDocumentTutorSplit") == nil {
                splitView.setPosition(
                    max(splitViewItems[0].minimumThickness, splitView.bounds.width - 390), ofDividerAt: 0)
            }
        }
    }
}
