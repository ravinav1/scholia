@preconcurrency import AppKit
import SwiftUI

/// Paper sessions deliberately have no disk-backed restoration or conversation store.
@MainActor
final class PaperStudyWindowController: NSObject, NSWindowDelegate {
    static let shared = PaperStudyWindowController()

    private(set) var window: NSWindow?
    private(set) var session: PaperStudySession?
    private let autosave: Bool

    init(session: PaperStudySession? = nil, autosave: Bool = true) {
        self.session = session
        self.autosave = autosave
        super.init()
    }

    func show(app: AppModel) {
        if window == nil {
            let studySession = session ?? PaperStudySession(app: app)
            session = studySession
            let size = NSSize(width: 1_300, height: 880)
            let studyWindow = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            studyWindow.title = "Paper study — Scholia"
            studyWindow.minSize = NSSize(width: 1_060, height: 680)
            studyWindow.isReleasedWhenClosed = false
            studyWindow.collectionBehavior = [.fullScreenPrimary]
            studyWindow.contentViewController = PanelContentController(
                rootView: PaperStudyView(session: studySession), size: size)
            studyWindow.delegate = self
            studyWindow.center()
            if autosave { studyWindow.setFrameAutosaveName("ScholiaPaperStudy") }
            window = studyWindow
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        session?.shutdown()
        // Release the hosted view too: SwiftUI drafts and displayed image copies belong to this session.
        window?.contentViewController = nil
        window = nil
        session = nil
    }
}
