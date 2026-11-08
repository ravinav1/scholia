@preconcurrency import AppKit
import JavaScriptCore
import PDFKit
import SwiftUI

struct StudyOutlineEntry: Identifiable {
    var id: Int
    var title: String
    var page: Int
    var depth: Int
}
struct StudySearchMatch {
    var page: Int
    var selection: PDFSelection?
}

/// The extension and native reader run the same local semantic ranking code.
@MainActor
final class StudyDocumentSearch {
    private let context = JSContext()
    init(scriptURL: URL? = nil) {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("NativeResources/pdf-search.js")
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        let url =
            scriptURL ?? (bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            ?? root.appendingPathComponent("dist/native-resources/pdf-search.js")
        if let source = try? String(contentsOf: url, encoding: .utf8) { context?.evaluateScript(source) }
    }
    func matches(pages: [StudyPage], query: String, semantic: Bool) -> [Int] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let method = semantic ? "findPdfSemanticMatches" : "findPdfMatches"
        let result = context?.objectForKeyedSubscript("ScholiaDocumentSearch")?.invokeMethod(
            method, withArguments: [pages.map(\.text), query])
        return (result?.forProperty("matches")?.toArray() as? [[String: Any]] ?? []).compactMap {
            ($0["pageIndex"] as? Int).flatMap { pages.indices.contains($0) ? pages[$0].number : nil }
        }
    }
}

@MainActor
final class StudyPDFControls: ObservableObject {
    @Published var layout = "continuous"
    @Published var zoomMode = "width"
    @Published var scale: CGFloat = 1
    @Published var dark = false
    @Published var outline: [StudyOutlineEntry] = []
    @Published var matches: [StudySearchMatch] = []
    @Published var matchIndex = -1
    weak var host: StudyPDFHost?
    private var engine: StudyDocumentSearch?

    func attach(_ host: StudyPDFHost) {
        self.host = host
        guard let document = host.pdf.document else { outline = []; return }
        var entries: [StudyOutlineEntry] = []
        func visit(_ node: PDFOutline, depth: Int) {
            for n in 0..<node.numberOfChildren {
                guard let child = node.child(at: n) else { continue }
                if let page = (child.destination ?? (child.action as? PDFActionGoTo)?.destination)?.page {
                    entries.append(
                        StudyOutlineEntry(
                            id: entries.count, title: child.label ?? "Untitled section",
                            page: document.index(for: page) + 1, depth: depth))
                }
                visit(child, depth: min(8, depth + 1))
            }
        }
        if let root = document.outlineRoot { visit(root, depth: 0) }
        outline = entries
        apply()
    }
    func apply() {
        guard let host else { return }
        let pdf = host.pdf
        let page = pdf.currentPage
        let previousZoom = host.zoomMode
        let previousScale = pdf.scaleFactor
        let mode: PDFDisplayMode =
            layout == "page" ? .singlePage : layout == "spread" ? .twoUpContinuous : .singlePageContinuous
        if pdf.displayMode != mode {
            pdf.displayMode = mode
            pdf.displaysAsBook = false
            if let page { pdf.go(to: page) }
        }
        host.zoomMode = zoomMode
        host.fitZoom()
        if zoomMode == "custom" {
            pdf.autoScales = false
            if abs(pdf.scaleFactor - scale) > 0.005 { pdf.scaleFactor = scale }
        }
        if zoomMode == "page", previousZoom != zoomMode || abs(previousScale - pdf.scaleFactor) > 0.005,
            let page, host.pendingPage == nil
        {
            pdf.layoutDocumentView()
            pdf.go(to: page)
        }
        pdf.backgroundColor = dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : .clear
    }
    func zoom(_ delta: Int) {
        if delta == 0 {
            zoomMode = "width"
        } else {
            scale = min(4, max(0.25, (host?.pdf.scaleFactor ?? 1) * (delta > 0 ? 1.2 : 1 / 1.2)))
            zoomMode = "custom"
        }
        apply()
    }
    func search(_ query: String, pages: [StudyPage], semantic: Bool) {
        matchIndex = -1
        host?.pdf.highlightedSelections = nil
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            matches = []
            return
        }
        if !semantic, let document = host?.pdf.document {
            let selections = document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive])
            matches = selections.compactMap { selection in
                selection.pages.first.map { StudySearchMatch(page: document.index(for: $0) + 1, selection: selection) }
            }
            for selection in selections { selection.color = NSColor.systemYellow.withAlphaComponent(0.4) }
            host?.pdf.highlightedSelections = selections
        } else {
            matches = []
        }
        // A native hit on one page must not hide OCR-only hits elsewhere.
        if engine == nil { engine = StudyDocumentSearch() }
        let nativePages = Set(matches.map(\.page))
        matches += (engine?.matches(pages: pages, query: query, semantic: semantic) ?? [])
            .filter { !nativePages.contains($0) }.map { StudySearchMatch(page: $0) }
        matches.sort { $0.page < $1.page }
    }
    func nextMatch(_ direction: Int) -> Int? {
        guard !matches.isEmpty else { return nil }
        matchIndex =
            matchIndex < 0
            ? (direction < 0 ? matches.count - 1 : 0) : (matchIndex + direction + matches.count) % matches.count
        let match = matches[matchIndex]
        if let selection = match.selection {
            host?.pdf.go(to: selection)
            host?.pdf.setCurrentSelection(selection, animate: true)
        }
        return match.page
    }
    func printDocument() {
        host?.pdf.document?.printOperation(for: NSPrintInfo.shared, scalingMode: .pageScaleToFit, autoRotate: true)?
            .run()
    }
    func pageTarget(_ page: Int, count: Int, direction: Int) -> Int {
        if layout == "spread" {
            return min(max(1, ((count - 1) / 2) * 2 + 1), max(1, ((page - 1) / 2) * 2 + 1 + direction * 2))
        }
        return min(count, max(1, page + direction))
    }
}
