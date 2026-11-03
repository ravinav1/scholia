import Foundation
import WebKit

/// Cookies never leave WebKit or reach disk. Each local library has its own
/// connection, reused only for this app run. Disconnect replaces the store
/// before clearing the old one, so cleanup cannot erase a new login.
@MainActor
final class StudentwebResultsConnection {
    private(set) var dataStore = WKWebsiteDataStore.nonPersistent()
    private var cleanup: Task<Void, Never>?

    func prepare() async { await cleanup?.value }

    func clearPageData(in store: WKWebsiteDataStore) {
        let previous = cleanup
        cleanup = Task {
            await previous?.value
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes().subtracting([WKWebsiteDataTypeCookies]),
                modifiedSince: .distantPast)
        }
    }

    func disconnect() {
        let old = dataStore, previous = cleanup
        dataStore = .nonPersistent()
        cleanup = Task {
            await previous?.value
            await old.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }
}

/// Bounded routing: no credential entry, SAML replay, private API or redirect
/// guessing. A failed/changed login flow remains available for manual sign-in.
struct StudentwebResultsNavigation {
    enum Step: Equatable { case wait, institution, feide, results, read }
    static let loginURL = URL(string: "https://fsweb.no/studentweb/login.jsf?inst=FSNTNU")!
    private var choseInstitution = false
    private var startedFeide = false
    private var openedResults = false
    private let automaticFeide: Bool

    init(automaticFeide: Bool = true) { self.automaticFeide = automaticFeide }

    static func showsSignIn(_ url: URL) -> Bool {
        guard StudentwebExtraction.trusted(url) else { return true }
        return ["/studentweb/login.jsf", "/studentweb/velginstitusjon.jsf"].contains(url.path.lowercased())
    }

    mutating func next(for url: URL) -> Step {
        guard StudentwebExtraction.trusted(url) else { return .wait }
        if StudentwebResults.resultsPage(url) { return .read }
        switch url.path.lowercased() {
        case "/studentweb/velginstitusjon.jsf", "/studentweb/login.jsf":
            let institution = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "inst" }?.value
            if institution == "FSNTNU" { choseInstitution = true }
            if !choseInstitution { choseInstitution = true; return .institution }
            if automaticFeide, url.path.lowercased() == "/studentweb/login.jsf", !startedFeide {
                startedFeide = true; return .feide
            }
        default:
            if StudentwebExtraction.examPage(url), !openedResults {
                openedResults = true; return .results
            }
        }
        return .wait
    }

    // The public NTNU login page exposes a JSF Feide form. Trigger its existing
    // handler so JSF view state and authentication tokens stay inside WebKit.
    // Never read input values, synthesize an authentication POST or eval onclick.
    static let signInScript = #"""
    if (location.protocol !== 'https:' || location.hostname !== 'fsweb.no' || location.username || location.password ||
        (location.port && location.port !== '443') || location.pathname !== '/studentweb/login.jsf') return false;
    const forms = document.querySelectorAll('.login-name-feide form');
    if (forms.length !== 1) return false;
    const form = forms[0];
    const action = new URL(form.getAttribute('action') || '', location.href);
    if (action.origin !== location.origin || action.pathname !== '/studentweb/login.jsf' || action.search ||
        (form.getAttribute('method') || '').toLowerCase() !== 'post' || form.hasAttribute('target') ||
        form.querySelector('input:not([type="hidden"]),textarea,select')) return false;
    const links = form.querySelectorAll('a.link[href="#"]');
    if (links.length !== 1) return false;
    links[0].click();
    return true;
    """#
}
