import AppKit
import Foundation
import Security
import WebKit
@testable import ScholiaMac

extension CanvasDownloadSmoke {
    static func checkSavedSessions() async throws {
        let origin = URL(string: "https://canvas.session.test")!
        let now = Date()
        func cookie(_ value: String) -> HTTPCookie {
            HTTPCookie(properties: [.name: "session", .value: value, .domain: origin.host!, .path: "/", .secure: "TRUE"])!
        }
        let archive = CanvasCookieArchive(savedAt: now.addingTimeInterval(-30 * 86_400), entries: [.init(cookie("initial"))])
        precondition(archive.cookies(origin: origin, now: now).count == 1,
            "Canvas, rather than a local seven-day timer, controls session expiry")
        var durable = String(decoding: try JSONEncoder().encode(archive), as: UTF8.self)
        let dataStore = WKWebsiteDataStore.nonPersistent()
        var writes = 0
        let session = CanvasCookieSession(origin: origin, store: dataStore.httpCookieStore,
            readCredential: { _, _ in durable }, writeCredential: { value, _, _ in durable = value; writes += 1 })
        try await session.restore()
        let restored = try await session.header(origin, generation: session.generation)
        precondition(restored.contains("initial"))
        try await session.persist()
        let firstSave = writes
        try await session.persist()
        precondition(writes == firstSave, "Unchanged sessions should not keep writing Keychain")
        for cookie in await dataStore.httpCookieStore.allCookies() { await dataStore.httpCookieStore.deleteCookie(cookie) }
        try await session.persist()
        precondition(!durable.isEmpty, "An empty WebKit snapshot must not erase the saved login")
        try await session.clear()
        precondition(durable.isEmpty, "Explicit Disconnect must remove the archive")

        // A locked archive must not defeat a usable live browser session. Saving
        // rotated cookies can fail independently of an otherwise successful API call.
        let liveStore = WKWebsiteDataStore.nonPersistent()
        durable = String(decoding: try JSONEncoder().encode(archive), as: UTF8.self)
        let savedArchive = durable
        await liveStore.httpCookieStore.setCookie(cookie("live"))
        let live = CanvasCookieSession(origin: origin, store: liveStore.httpCookieStore,
            readCredential: { _, interaction in
                if interaction { return durable }
                throw KeychainStoreError.unexpectedStatus(errSecInteractionNotAllowed)
            },
            writeCredential: { value, _, interaction in
                guard interaction else { throw KeychainStoreError.unexpectedStatus(errSecInteractionNotAllowed) }
                durable = value
            })
        try await live.restore()
        try await live.receive(url: origin, headers: ["Set-Cookie": "session=renewed; Path=/; Secure; HttpOnly"], generation: live.generation)
        let renewed = try await live.header(origin, generation: live.generation)
        precondition(renewed.contains("renewed") && live.persistenceWarning != nil)
        precondition(durable == savedArchive, "A denied archive read must never permit overwriting the saved login")
        try await live.persist(allowKeychainInteraction: true)
        precondition(live.persistenceWarning == nil && !durable.isEmpty)
        let nextStore = WKWebsiteDataStore.nonPersistent()
        let reopened = CanvasCookieSession(origin: origin, store: nextStore.httpCookieStore,
            readCredential: { _, interaction in precondition(!interaction); return durable },
            writeCredential: { value, _, _ in durable = value })
        try await reopened.restore()
        let afterRestart = try await reopened.header(origin, generation: reopened.generation)
        precondition(afterRestart.contains("renewed"), "The renewed login must restore without another prompt")
        try await reopened.clear()
        try await live.clear()

        let orderedStore = WKWebsiteDataStore.nonPersistent()
        let order = SessionWriteOrder()
        let ordered = CanvasCookieSession(origin: origin, store: orderedStore.httpCookieStore,
            readCredential: { _, _ in "" }, writeCredential: { value, _, _ in
                if !order.started {
                    order.started = true
                    while !order.released { try await Task.sleep(for: .milliseconds(5)) }
                }
                durable = value
            })
        await orderedStore.httpCookieStore.setCookie(cookie("older"))
        let olderSave = Task { try await ordered.persist() }
        while !order.started { try await Task.sleep(for: .milliseconds(5)) }
        await orderedStore.httpCookieStore.setCookie(cookie("newest"))
        let newerSave = Task { try await ordered.persist() }
        order.released = true
        try await olderSave.value
        try await newerSave.value
        let finalArchive = try JSONDecoder().decode(CanvasCookieArchive.self, from: Data(durable.utf8))
        precondition(finalArchive.cookies(origin: origin).first?.value == "newest",
            "Overlapping saves must never replace the newest cookie with an older snapshot")
        try await ordered.clear()
        print("PASS: durable Canvas sessions, empty-store recovery, valid live login with locked Keychain, nonfatal cookie saves, interactive repair, restart and serialized rotation")
    }
}

@MainActor
private final class SessionWriteOrder {
    var started = false
    var released = false
}
