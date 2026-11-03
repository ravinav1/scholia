import Foundation
import WebKit

/// Only Canvas-origin cookies are retained, in the device-only Keychain. SSO
/// cookies and passwords never enter this archive. Server expiry still applies.
struct CanvasCookieArchive: Codable {
    struct Entry: Codable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var secure: Bool
        var httpOnly: Bool
        var expires: Date?
        init(_ cookie: HTTPCookie) {
            name = cookie.name; value = cookie.value; domain = cookie.domain; path = cookie.path
            secure = cookie.isSecure; httpOnly = cookie.isHTTPOnly; expires = cookie.expiresDate
        }
        var cookie: HTTPCookie? {
            var fields: [HTTPCookiePropertyKey: Any] = [
                .name: name, .value: value, .domain: domain, .path: path,
                .secure: secure ? "TRUE" : "FALSE", HTTPCookiePropertyKey("HttpOnly"): httpOnly ? "TRUE" : "FALSE"
            ]
            if let expires { fields[.expires] = expires }
            return HTTPCookie(properties: fields)
        }
    }
    var savedAt: Date
    var entries: [Entry]
    static func matches(_ cookie: HTTPCookie, origin: URL, now: Date = Date()) -> Bool {
        let host = origin.host?.lowercased() ?? ""
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // Do not archive a broad institution/SSO cookie (e.g. .ntnu.no).
        return !host.isEmpty && domain == host && (cookie.expiresDate ?? .distantFuture) > now
    }
    func cookies(origin: URL, now: Date = Date()) -> [HTTPCookie] {
        // Canvas controls session expiry. A local seven-day cutoff discarded
        // otherwise valid logins even after Keychain access was allowed.
        return entries.compactMap(\.cookie).filter { Self.matches($0, origin: origin, now: now) }
    }
    static func header(_ cookies: [HTTPCookie], url: URL, origin: URL) -> String {
        guard CanvasAddress.sameOrigin(url, origin) else { return "" }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let applicable = cookies.filter {
            guard matches($0, origin: origin) else { return false }
            let path = $0.path
            return requestPath == path || (requestPath.hasPrefix(path) && (path.hasSuffix("/") || requestPath.dropFirst(path.count).first == "/"))
        }.sorted { $0.path.count > $1.path.count }
        return HTTPCookie.requestHeaderFields(with: applicable)["Cookie"] ?? ""
    }
}

@MainActor
enum CanvasSession {
    private static var stores: [String: CanvasCookieSession] = [:]
    private static func session(_ origin: URL) -> CanvasCookieSession {
        if let existing = stores[origin.absoluteString] { return existing }
        let value = CanvasCookieSession(origin: origin)
        stores[origin.absoluteString] = value
        return value
    }
    static func prepare(origin: URL, allowKeychainInteraction: Bool = false) async throws {
        let current = session(origin)
        try await current.restore(allowKeychainInteraction: allowKeychainInteraction)
        do { try await current.persist(allowKeychainInteraction: allowKeychainInteraction) }
        catch {
            // A usable browser session must survive a failed background save.
            // Explicit sign-in still reports the failure so access can be granted.
            if allowKeychainInteraction { throw error }
        }
    }
    static func persistenceWarning(origin: URL) -> String? { session(origin).persistenceWarning }
    static func keychainError(origin: URL) -> Error? { session(origin).keychainError }
    static func preferBrowser(origin: URL) {
        UserDefaults.standard.set("browser", forKey: "canvas.auth:\(origin.absoluteString)")
    }
    static func saveToken(_ token: String, origin: URL) async throws {
        try await ProviderKeychain.setAsync(token, for: "canvas:\(origin.absoluteString)", allowInteraction: true)
        UserDefaults.standard.set("token", forKey: "canvas.auth:\(origin.absoluteString)")
    }
    static func client(origin: URL, useBrowserSession: Bool = false, allowKeychainInteraction: Bool = false) async throws -> CanvasClient {
        let browser = useBrowserSession || UserDefaults.standard.string(forKey: "canvas.auth:\(origin.absoluteString)") == "browser"
        let token = browser ? "" : try await ProviderKeychain.valueAsync(for: "canvas:\(origin.absoluteString)", allowInteraction: allowKeychainInteraction)
        if !token.isEmpty { return CanvasClient(origin: origin, token: token) }
        try await prepare(origin: origin, allowKeychainInteraction: allowKeychainInteraction)
        let current = session(origin)
        let generation = current.generation
        return CanvasClient(origin: origin, cookies: { url in
            try await current.header(url, generation: generation)
        }, receiveCookies: { url, headers in
            try await current.receive(url: url, headers: headers, generation: generation)
        })
    }
    static func disconnect(origin: URL) async throws {
        try await ProviderKeychain.setAsync("", for: "canvas:\(origin.absoluteString)", allowInteraction: true)
        try await session(origin).clear()
        UserDefaults.standard.removeObject(forKey: "canvas.auth:\(origin.absoluteString)")
    }
}

@MainActor
final class CanvasCookieSession: NSObject, WKHTTPCookieStoreObserver {
    let origin: URL
    let store: WKHTTPCookieStore
    private let readCredential: @MainActor (String, Bool) async throws -> String
    private let writeCredential: @MainActor (String, String, Bool) async throws -> Void
    var restoration: Task<Void, Error>?
    private var persistence: Task<Void, Error>?
    private var persistenceID = UUID()
    private(set) var persistenceWarning: String?
    private var archiveReadError: Error?
    private var persistenceError: Error?
    var keychainError: Error? {
        [archiveReadError, persistenceError].compactMap { $0 }.first {
            ($0 as? KeychainStoreError)?.needsInteraction == true
        }
    }
    var lastSaved = ""
    var clearing = false
    var generation = UUID()
    var key: String { "canvas-cookies:\(origin.absoluteString)" }
    init(origin: URL, store: WKHTTPCookieStore = WKWebsiteDataStore.default().httpCookieStore,
        readCredential: @escaping @MainActor (String, Bool) async throws -> String = {
            try await ProviderKeychain.valueAsync(for: $0, allowInteraction: $1)
        },
        writeCredential: @escaping @MainActor (String, String, Bool) async throws -> Void = {
            try await ProviderKeychain.setAsync($0, for: $1, allowInteraction: $2)
        }) {
        self.origin = origin; self.store = store
        self.readCredential = readCredential; self.writeCredential = writeCredential
        super.init()
    }
    func restore(allowKeychainInteraction: Bool = false) async throws {
        if let restoration {
            try await restoration.value
            if !allowKeychainInteraction || archiveReadError == nil { return }
        }
        let task = Task { @MainActor in
            let live = await store.allCookies().filter { CanvasCookieArchive.matches($0, origin: origin) }
            let raw: String
            do {
                raw = try await readCredential(key, allowKeychainInteraction)
                archiveReadError = nil
            }
            catch {
                guard !live.isEmpty, !allowKeychainInteraction,
                    (error as? KeychainStoreError)?.needsInteraction == true else { throw error }
                persistenceWarning = "Canvas is connected, but saving its login needs Keychain access."
                archiveReadError = error
                store.add(self)
                return
            }
            try Task.checkCancellation()
            if let data = raw.data(using: .utf8), let archive = try? JSONDecoder().decode(CanvasCookieArchive.self, from: data) {
                for cookie in archive.cookies(origin: origin) where !live.contains(where: {
                    $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path
                }) {
                    try Task.checkCancellation()
                    await store.setCookie(cookie)
                }
            }
            try Task.checkCancellation()
            store.add(self)
        }
        restoration = task
        do { try await task.value }
        catch { restoration = nil; throw error }
    }
    func header(_ url: URL, generation: UUID) async throws -> String {
        guard generation == self.generation, !clearing else { throw StudyError.message("Canvas was disconnected. Reconnect to continue.") }
        try await restore()
        let live = await store.allCookies()
        guard generation == self.generation, !clearing else { throw StudyError.message("Canvas was disconnected. Reconnect to continue.") }
        return CanvasCookieArchive.header(live, url: url, origin: origin)
    }
    func receive(url: URL, headers: [String: String], generation: UUID) async throws {
        guard generation == self.generation, !clearing, CanvasAddress.sameOrigin(url, origin), headers.keys.contains(where: { $0.lowercased() == "set-cookie" }) else { return }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
            guard generation == self.generation, !clearing else { return }
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard domain == origin.host?.lowercased() else { continue }
            if let expires = cookie.expiresDate, expires <= Date() { await store.deleteCookie(cookie) }
            else { await store.setCookie(cookie) }
        }
        guard generation == self.generation, !clearing else { return }
        // Cookie rotation is part of a successful API response. A Keychain write
        // failure must not turn that response into an authentication failure.
        try? await persist()
    }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in try? await persist() }
    }
    func persist(allowKeychainInteraction: Bool = false) async throws {
        // Snapshot and write in order; a slow older save must never overwrite a
        // newer session cookie. Waiters take a fresh snapshot after the write.
        guard !clearing else { return }
        let previous = persistence
        let ticket = UUID()
        let task = Task { @MainActor in
            _ = await previous?.result
            if allowKeychainInteraction, archiveReadError != nil {
                try await restore(allowKeychainInteraction: true)
            }
            try await saveSnapshot(allowKeychainInteraction: allowKeychainInteraction)
        }
        persistence = task
        persistenceID = ticket
        defer { if persistenceID == ticket { persistence = nil } }
        do { try await task.value; persistenceWarning = nil; persistenceError = nil }
        catch {
            persistenceError = error
            persistenceWarning = "Canvas is connected, but its login could not be saved: \(error.localizedDescription)"
            throw error
        }
    }
    private func saveSnapshot(allowKeychainInteraction: Bool) async throws {
        // Never overwrite an archive we were not allowed to read with a partial
        // live cookie store. An explicit access grant retries the restoration.
        if let archiveReadError { throw archiveReadError }
        let generation = self.generation
        let cookies = await store.allCookies().filter { CanvasCookieArchive.matches($0, origin: origin) }
            .sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) }
        // WebKit may briefly report an empty store during startup/teardown.
        // Only Disconnect is allowed to remove the durable saved session.
        guard !cookies.isEmpty, !clearing, generation == self.generation else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let entries = cookies.map(CanvasCookieArchive.Entry.init)
        let signature = String(decoding: try encoder.encode(entries), as: UTF8.self)
        guard signature != lastSaved else { return }
        let archive = CanvasCookieArchive(savedAt: Date(), entries: entries)
        try await writeCredential(String(decoding: try encoder.encode(archive), as: UTF8.self), key, allowKeychainInteraction)
        guard !clearing, generation == self.generation else { return }
        lastSaved = signature
    }
    func clear() async throws {
        clearing = true
        generation = UUID()
        defer { clearing = false }
        store.remove(self)
        restoration?.cancel()
        _ = await restoration?.result
        restoration = nil
        _ = await persistence?.result
        try await writeCredential("", key, true)
        for cookie in await store.allCookies() {
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if domain == origin.host?.lowercased() { await store.deleteCookie(cookie) }
        }
        lastSaved = ""
        persistenceWarning = nil
        archiveReadError = nil
        persistenceError = nil
    }
}
