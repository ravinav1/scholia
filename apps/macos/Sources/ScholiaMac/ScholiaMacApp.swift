@preconcurrency import AppKit
import SwiftUI

@main
struct ScholiaMacApp: App {
    @NSApplicationDelegateAdaptor(ScholiaAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(model).scholiaButtonStyle(.automatic)
        } label: {
            ZStack {
                Image(systemName: model.isAnswering ? "ellipsis.bubble" : "text.magnifyingglass")
                if !model.isAnswering && !model.selectionPillIsEnabledForActiveApplication {
                    Image(systemName: "slash")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .accessibilityLabel(model.menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model).scholiaButtonStyle(.automatic)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Report & fix…") { ScholiaRepairCenter.shared.present(workspace: model.studyWorkspace, app: model) }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Update Scholia…", action: ScholiaAppUpdater.open)
                    .help("Build and install the latest changes from your Scholia folder, then reopen the app.")
            }
            CommandGroup(after: .newItem) {
                Button("Open Study Workspace", action: model.openStudyWorkspace)
                    .keyboardShortcut("1", modifiers: .command)
                Button("Study on Paper…") { PaperStudyWindowController.shared.show(app: model) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Import Study Documents…", action: model.chooseStudyDocuments)
                    .keyboardShortcut("o", modifiers: .command)
                Button("Open Scholia in Browser", action: model.openStudyWebsite)
                    .keyboardShortcut("2", modifiers: .command)
                Button("Quick Chat", action: model.showQuickAsk)
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Document Focus") { model.studyWorkspace.toggleDocumentFocus() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class ScholiaAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        AppModel.shared.start()
        if CommandLine.arguments.contains("--serve-study") { AppModel.shared.startStudyWebsite() }
        if !CommandLine.arguments.contains("--background") {
            AppModel.shared.openStudyWorkspace()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScholiaRepairCenter.shared.stop()
        AppModel.shared.stop()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        AppModel.shared.openStudyDocuments(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppModel.shared.applicationDidBecomeActive()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.reopenFromDock()
        return true
    }

    @objc func explainWithScholia(
        _ pasteboard: NSPasteboard,
        userData: String,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
            errorPointer.pointee = "Scholia did not receive selected text."
            return
        }
        AppModel.shared.explainServiceText(text)
    }
}
