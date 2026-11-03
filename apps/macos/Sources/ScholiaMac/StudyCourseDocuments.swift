import AppKit
import SwiftUI
import WebKit

extension StudyDocument {
    var isHTML: Bool { ["html", "htm"].contains(URL(fileURLWithPath: fileName).pathExtension.lowercased()) }
    var needsCanvasHTMLUpgrade: Bool {
        guard let sourceKey else { return false }
        return (sourceKey == "syllabus" || ["pages:", "assignments:", "syllabus:"].contains(where: sourceKey.hasPrefix)) && !isHTML
    }
}

extension StudyHTML {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func safeURL(_ value: String, base: URL? = nil) -> URL? {
        guard let url = URL(string: plainText(value), relativeTo: base)?.absoluteURL,
            ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil
        else { return nil }
        return url
    }
    static func original(title: String, body: String, source: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"><base href=\"\(escape(source))\"><title>\(escape(title))</title></head><body><h1>\(escape(title))</h1>\(body)</body></html>"
    }
    static func replacing(_ text: String, pattern: String, transform: (NSTextCheckingResult, NSString) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(match, source))
        }
        return result
    }
    static func markdown(_ html: String, base: URL? = nil) -> String {
        var base = base
        _ = replacing(html, pattern: #"(?is)<base\b[^>]*\shref\s*=\s*["']([^"']+)["'][^>]*>"#) { match, source in
            if base == nil { base = safeURL(source.substring(with: match.range(at: 1))) }
            return ""
        }
        var text = embeddedLinks(html, base: base).replacingOccurrences(of: #"(?is)<(head|script|style)\b[^>]*>.*?</\1\s*>"#,
            with: "", options: .regularExpression)
        // Placeholders prevent the plain-text pass from interpreting decoded
        // angle brackets in an anchor label or URL as HTML.
        var links: [String: String] = [:]
        text = replacing(text, pattern: #"(?is)<a\b[^>]*\shref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(.*?)</a\s*>"#) { match, source in
            let range = (1...3).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
            let label = plainText(source.substring(with: match.range(at: 4)))
            guard let url = safeURL(source.substring(with: range), base: base) else { return escape(label) }
            let key = "SCHOLIALINK\(UUID().uuidString)"
            links[key] = "[\(markdownLabel(label.isEmpty ? "Open source" : label))](\(url.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")))"
            return key
        }
        text = replacing(text, pattern: #"(?is)<h([1-6])\b[^>]*>(.*?)</h[1-6]\s*>"#) { match, source in
            "\n\n" + String(repeating: "#", count: Int(source.substring(with: match.range(at: 1))) ?? 1) + " " + source.substring(with: match.range(at: 2)) + "\n\n"
        }
        text = plainText(text)
        for (key, value) in links { text = text.replacingOccurrences(of: key, with: value) }
        return text
    }
    static func embeddedLinks(_ html: String, base: URL?) -> String {
        replacing(html, pattern: #"(?is)<(?:iframe|object|embed)\b[^>]*\s(?:src|data)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>(?:.*?</(?:iframe|object)\s*>)?"#) { match, source in
            let range = (1...3).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
            guard let url = safeURL(source.substring(with: range), base: base) else { return "" }
            return "<p><a href=\"\(escape(url.absoluteString))\">Open embedded document ↗</a></p>"
        }
    }
    static func markdownLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
    static func restoringLinks(_ text: String, document: StudyDocument, course: StudyCourse) -> String {
        guard let sourceKey = document.sourceKey else { return text }
        var labels: [String: Set<String>] = [:]
        for ref in course.materials where ref.linkedFromID == sourceKey {
            guard safeURL(ref.sourceURL) != nil else { continue }
            for label in Set([ref.title, ref.fileName].compactMap { $0 }) {
                labels[label, default: []].insert(ref.sourceURL)
            }
        }
        return text.components(separatedBy: "\n").map { line in
            let label = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let urls = labels[label], urls.count == 1, let url = urls.first else { return line }
            return "[\(markdownLabel(label))](\(url))"
        }.joined(separator: "\n")
    }
}

extension StudyWorkspaceModel {
    var linkedReadingText: String {
        guard let document, let course else { return currentPageText }
        return StudyHTML.restoringLinks(currentPageText, document: document, course: course)
    }
    func openCourseLink(_ url: URL) -> Bool {
        guard let course else { return false }
        let wikiID = MathWikiAddress.link(url.absoluteString).map { "math-wiki:" + $0.url.absoluteString }
        let canvasID = course.canvasOrigin.flatMap(URL.init(string:)).flatMap { origin in
            course.canvasID.flatMap { CanvasContentLinks.resolve(url.absoluteString, origin: origin, courseID: $0)?.id }
        }
        let websiteID = CourseWebsiteAddress.link(url.absoluteString).map { "course-web:" + $0.url.absoluteString }
        for id in [canvasID, wikiID, websiteID].compactMap({ $0 }) {
            if let ref = course.materials.first(where: { $0.id == id }) {
                openCanvasMaterial(ref, courseID: course.id)
                return true
            }
            if let doc = course.documents.first(where: { $0.sourceKey == id }) {
                selectDocument(doc.id)
                return true
            }
        }
        return false
    }
}

struct StudyOriginalHTML: NSViewRepresentable {
    let url: URL
    let sourceURL: String?
    var onLink: (URL) -> Bool
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loaded: URL?
        var onLink: (URL) -> Bool = { _ in false }
        private func open(_ url: URL?) {
            guard let url, StudyHTML.safeURL(url.absoluteString) != nil else { return }
            if !onLink(url) { NSWorkspace.shared.open(url) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated {
                open(action.request.url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
            }
        }
        // Canvas file links commonly use target="_blank". WebKit asks the UI
        // delegate to create that window instead of navigating this reader.
        // Route it through the same document opener; never create a popup.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { open(action.request.url) }
            return nil
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        makeWebView(coordinator: context.coordinator)
    }
    func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        loadOriginal(into: view, coordinator: context.coordinator)
    }
    func loadOriginal(into view: WKWebView, coordinator: Coordinator) {
        coordinator.onLink = onLink
        guard coordinator.loaded != url else { return }
        coordinator.loaded = url
        let original = (try? String(contentsOf: url, encoding: .utf8)) ?? "Original page unavailable."
        let body = StudyHTML.embeddedLinks(original, base: sourceURL.flatMap(URL.init(string:)))
        let policy = "default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; form-action 'none'; frame-src 'none'"
        let html = "<html><head><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><base href=\"\(StudyHTML.escape(sourceURL ?? ""))\"><style>body{font:17px/1.65 Georgia,serif;color:#282b28;background:#fffdf8;margin:32px;padding:0 24px}img{max-width:100%}table{border-collapse:collapse}td,th{padding:8px;border:1px solid #ddd}a{color:#246850}</style></head><body>\(body)</body></html>"
        view.loadHTMLString(html, baseURL: nil)
    }
}
