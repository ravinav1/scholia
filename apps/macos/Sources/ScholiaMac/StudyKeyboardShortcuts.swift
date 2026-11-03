import SwiftUI

private enum StudyWorkspaceShortcuts {
    static let workspace = StudyShortcutGroup(title: "Workspace", shortcuts: [
        ("Search files and contents", "⌘ K"),
        ("Switch workspace or take an action", "⌘ ⇧ K"),
        ("Back / forward", "⌘ [ / ]"),
        ("Open study workspace", "⌘ 1"),
        ("Open Scholia in browser", "⌘ 2"),
        ("Import documents", "⌘ O")
    ])
    static let chat = StudyShortcutGroup(title: "Chat", shortcuts: [
        ("Send message", "Return"), ("New line", "⇧ Return")
    ])
    static let readerAndEditor = StudyShortcutGroup(title: "Reader and editor", shortcuts: [
        ("Find in document", "⌘ F"), ("Print PDF", "⌘ P"), ("Save edits", "⌘ S")
    ])
    static let dialogs = StudyShortcutGroup(title: "Dialogs", shortcuts: [
        ("Move through search results", "↑ / ↓"),
        ("Open selected result", "Return"), ("Close dialog", "Esc")
    ])
}

private struct StudyShortcutGroup: View {
    let title: String
    let shortcuts: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(shortcuts, id: \.0) { label, keys in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(label).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(keys).monospaced().foregroundStyle(.secondary).fixedSize()
                }.font(.system(size: 12)).frame(maxWidth: .infinity)
            }
        }
    }
}

struct StudyWorkspaceShortcutList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StudyWorkspaceShortcuts.workspace
            StudyWorkspaceShortcuts.chat
            StudyWorkspaceShortcuts.readerAndEditor
            StudyWorkspaceShortcuts.dialogs
        }
    }
}

struct StudyKeyboardShortcutsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Keyboard shortcuts").font(.title2)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("keyboard-shortcuts-done")
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    StudyWorkspaceShortcuts.workspace
                    StudyShortcutGroup(title: "Desktop tools", shortcuts: [
                        ("Explain selected text", app.settings.resolvedExplainShortcut.displayName),
                        ("Explain a screen region", app.settings.resolvedCaptureShortcut.displayName),
                        ("Open Quick Ask", app.settings.resolvedQuickAskShortcut.displayName),
                        ("Toggle desktop tools for active app", app.settings.resolvedToggleSelectionPopupShortcut.displayName)
                    ])
                }.frame(maxWidth: .infinity, alignment: .topLeading)
                Divider()
                VStack(alignment: .leading, spacing: 20) {
                    StudyWorkspaceShortcuts.chat
                    StudyWorkspaceShortcuts.readerAndEditor
                    StudyWorkspaceShortcuts.dialogs
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }.fixedSize(horizontal: false, vertical: true)
            Text("Reader and editor shortcuts work while that view is active. Change desktop shortcuts in Settings → Shortcuts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(width: 780).fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
