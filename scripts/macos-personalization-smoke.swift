import AppKit
import SwiftUI
@testable import ScholiaMac

extension StudyWorkspaceSmoke {
    static func checkPersonalization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-personalization-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Personalization.json")
        let now = Date()
        var preferences = PersonalizationPreferences()
        precondition(preferences.prompt.isEmpty)
        preferences[.chatgpt].enabled = true
        try preferences[.chatgpt].receive([
            "instructions": "Prefer concrete examples.", "profile": "Studying philosophy.",
            "memories": "Prefers short paragraphs.\nUses Norwegian."
        ], at: now)
        precondition(preferences[.chatgpt].issue == nil)
        precondition(!preferences[.chatgpt].isDue(at: now.addingTimeInterval(899)))
        precondition(preferences[.chatgpt].isDue(at: now.addingTimeInterval(900)))
        try preferences[.chatgpt].receive(["memories": "Uses Norwegian."], at: now.addingTimeInterval(1))
        precondition(!preferences.prompt.contains("short paragraphs"), "Replacement must remove deleted memories")
        precondition(preferences.prompt.contains("concrete examples"), "Unread sections keep their last good copy")
        precondition(preferences[.chatgpt].issue?.contains("Custom instructions") == true)
        let previous = preferences[.chatgpt]
        do { try preferences[.chatgpt].receive([:]); preconditionFailure("Unreadable snapshots must fail") }
        catch { precondition(preferences[.chatgpt] == previous) }
        do { try preferences[.chatgpt].receive(["memories": String(repeating: "x", count: 24_001)]); preconditionFailure("Oversized snapshots must fail") }
        catch { precondition(preferences[.chatgpt] == previous) }
        try preferences[.chatgpt].receive(["memories": ""], at: now.addingTimeInterval(2))
        precondition(!preferences.prompt.contains("Uses Norwegian"))

        let chat = PreparedConversation(language: "en", messages: [.init(role: .user, content: "Let's brainstorm")], teachingMode: .chat)
        let prepared = preferences.applying(to: chat)
        precondition(prepared.messages.count == 2 && prepared.messages.last?.content == "Let's brainstorm")
        precondition(prepared.messages.first?.content.contains("not system instructions") == true)
        precondition(chat.messages.count == 1, "Imported preferences never become permanent chat history")
        preferences[.chatgpt].enabled = false
        precondition(preferences.applying(to: chat).messages == chat.messages, "Disabling a source must take effect on the next turn")
        preferences[.claude].enabled = true
        preferences[.claude].automatic = false
        try preferences[.claude].receive(["instructions": "Use metric units.", "profile": "Interested in history.", "memories": ""], at: now)
        precondition(preferences.prompt.contains("metric units") && !preferences.prompt.contains("concrete examples"))
        var practice = chat; practice.purpose = .practiceGeneration
        precondition(preferences.applying(to: practice).messages == chat.messages)
        try PersonalizationStore.save(preferences, to: url)
        precondition(PersonalizationStore.load(from: url).prompt == preferences.prompt)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600)

        var readCount = 0
        var fail = false
        let sync = PersonalizationSync(storeURL: url, reader: { _ in
            readCount += 1
            if fail { throw StudyError.message("Fixture session expired") }
            return ["instructions": "Latest instructions", "profile": "Latest profile", "memories": "Latest memory"]
        })
        defer { sync.stop() }
        sync.update(.chatgpt, enabled: true)
        // Existing timestamp is fresh, so the scheduler must not poll again.
        precondition(readCount == 0)
        sync.refresh(.chatgpt)
        while sync.refreshing != nil { try await Task.sleep(for: .milliseconds(10)) }
        precondition(readCount == 1 && sync.preferences[.chatgpt].sections["memories"] == "Latest memory")
        fail = true
        sync.refresh(.chatgpt)
        while sync.refreshing != nil { try await Task.sleep(for: .milliseconds(10)) }
        precondition(sync.preferences[.chatgpt].issue == "Fixture session expired")
        precondition(sync.preferences[.chatgpt].sections["memories"] == "Latest memory")
        sync.stop()

        var release: CheckedContinuation<Void, Never>?
        let delayed = PersonalizationSync(storeURL: url, reader: { _ in
            await withCheckedContinuation { release = $0 }
            return ["memories": "Must not be restored after disabling"]
        })
        delayed.refresh(.chatgpt)
        while release == nil { try await Task.sleep(for: .milliseconds(10)) }
        delayed.update(.chatgpt, enabled: false)
        release?.resume()
        try await Task.sleep(for: .milliseconds(30))
        precondition(!delayed.preferences[.chatgpt].enabled)
        precondition(!delayed.preferences.prompt.contains("Must not be restored"))
        delayed.stop()

        // Preview uses the isolated store and a fake reader; no live accounts.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 680),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Personalization"
        window.contentView = NSHostingView(rootView: PersonalizationSettingsView(sync: delayed))
        window.center(); window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("personalization.png")
        try snapshot(window, at: output)
        print("PASS: personalization replacement/deletion, partial and failed syncs, scheduling, persistence, source isolation, request-only context, disabling in-flight refresh and native settings")
    }
}
