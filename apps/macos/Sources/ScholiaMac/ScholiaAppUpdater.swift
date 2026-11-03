@preconcurrency import AppKit

@MainActor
enum ScholiaAppUpdater {
    static func open() {
        guard let sourceRoot = Bundle.main.object(forInfoDictionaryKey: "ScholiaSourceRoot") as? String,
              !sourceRoot.isEmpty else {
            showError("Open your Scholia source folder and double-click Update Scholia.command to install the latest changes.")
            return
        }
        open(sourceRoot: sourceRoot)
    }

    static func open(sourceRoot: String) {
        let command = URL(fileURLWithPath: sourceRoot, isDirectory: true)
            .appendingPathComponent("Update Scholia.command")
        guard FileManager.default.isExecutableFile(atPath: command.path) else {
            showError("The Scholia source folder has moved or is unavailable. Open it in Finder and double-click Update Scholia.command to reconnect updates.")
            return
        }

        // Terminal owns the installer so it can finish after Scholia quits.
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true)
        NSWorkspace.shared.open(
            [command], withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            guard let error else { return }
            let message = error.localizedDescription
            Task { @MainActor in showError(message) }
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t open the Scholia updater"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}
