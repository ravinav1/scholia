@preconcurrency import AppKit
import PDFKit
import Quartz
import SwiftUI

struct StudyOriginalPreview: NSViewRepresentable {
    let url: URL
    var captureRequest = 0
    var onCapture: ((NSImage) -> Void)? = nil
    final class Coordinator { var captured = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL }
        if captureRequest != context.coordinator.captured {
            context.coordinator.captured = captureRequest
            DispatchQueue.main.async {
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let image = NSImage(size: view.bounds.size)
                image.addRepresentation(bitmap)
                onCapture?(image)
            }
        }
    }
}

struct StudyPDFReader: NSViewRepresentable {
    let url: URL
    @Binding var page: Int
    @Binding var selection: String
    @Binding var selectingFigure: Bool
    var zoom: CGFloat
    var onFigure: (Data) -> Void
    var controls: StudyPDFControls? = nil
    var onSelectionAction: ((String, Bool, String) -> Bool)? = nil
    var selectionResponse: ((@escaping () -> Void) -> AnyView)? = nil
    var selectionBusy = false
    var revision = ""
    var onOpenLink: ((URL) -> Bool)? = nil

    func makeNSView(context: Context) -> StudyPDFHost {
        let host = StudyPDFHost()
        context.coordinator.host = host
        host.pdf.delegate = context.coordinator
        context.coordinator.observe()
        return host
    }
    func updateNSView(_ host: StudyPDFHost, context: Context) {
        context.coordinator.parent = self
        if host.url != url || host.revision != revision {
            host.closeSelectionResponse()
            host.pendingPage = page
            host.url = url
            host.revision = revision
            context.coordinator.loadDocument(url: url, revision: revision)
        }
        // Page controls can change while file parsing is still in progress.
        if context.coordinator.loadingDocument { host.pendingPage = page }
        host.controls = controls
        host.selectionBusy = selectionBusy
        host.selectionResponse = selectionResponse
        configureActions(for: host)
        host.crop.isHidden = !selectingFigure
        if host.pendingPage == nil, let target = host.pdf.document?.page(at: page - 1), host.pdf.currentPage !== target
        {
            host.pdf.go(to: target)
        }
        if controls == nil && host.zoom != zoom {
            host.zoom = zoom
            host.pdf.autoScales = zoom == 1
            if zoom != 1 { host.pdf.scaleFactor = host.pdf.scaleFactorForSizeToFit * zoom }
        }
    }
    func configureActions(for host: StudyPDFHost) {
        host.onSelectionAction = { [weak host] text, explain, question in
            if let selectedPage = host?.selectionPage { page = selectedPage }
            selection = text
            return onSelectionAction?(text, explain, question) ?? false
        }
        // The host owns the overlay; retaining it here would keep every closed
        // reader, PDF document, and rendered page alive after navigation.
        host.crop.onCapture = { [weak host] data in
            selectingFigure = false
            if let capturedPage = host?.crop.capturedPage { page = capturedPage }
            if let data { onFigure(data) }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    static func dismantleNSView(_ host: StudyPDFHost, coordinator: Coordinator) {
        coordinator.cancelDocumentLoad()
        NotificationCenter.default.removeObserver(coordinator)
        host.pdf.delegate = nil
        coordinator.host = nil
        host.stopObservingEvents()
        host.crop.onCapture = nil
        host.onSelectionAction = nil
        host.selectionResponse = nil
        host.pdf.document = nil
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency PDFViewDelegate {
        var parent: StudyPDFReader
        weak var host: StudyPDFHost?
        private var loadTask: Task<Void, Never>?
        private var loadID: UUID?
        private var selectionUpdateScheduled = false
        var loadingDocument: Bool { loadTask != nil }
        init(_ parent: StudyPDFReader) { self.parent = parent }
        func cancelDocumentLoad() {
            loadTask?.cancel()
            loadTask = nil
            loadID = nil
        }
        func loadDocument(url: URL, revision: String) {
            cancelDocumentLoad()
            let ticket = UUID()
            loadID = ticket
            // Clear the previous reading immediately; a slow load must never
            // expose the old PDF beneath the new document title.
            host?.pdf.document = nil
            loadTask = Task { [weak self] in
                do {
                    let loaded = try await StudyPDFDocumentLoader.shared.load(url)
                    guard let self, !Task.isCancelled, self.loadID == ticket,
                          let host = self.host, host.url == url, host.revision == revision else { return }
                    self.loadTask = nil
                    host.pdf.document = loaded.document
                    host.pdf.autoScales = true
                    self.parent.controls?.attach(host)
                    host.needsLayout = true
                } catch {
                    if self?.loadID == ticket { self?.loadTask = nil }
                }
            }
        }
        func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            guard StudyHTML.safeURL(url.absoluteString) != nil else { return }
            if parent.onOpenLink?(url) != true { NSWorkspace.shared.open(url) }
        }
        func observe() {
            NotificationCenter.default.addObserver(
                self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: host?.pdf)
            NotificationCenter.default.addObserver(
                self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: host?.pdf)
        }
        @objc func pageChanged() {
            guard let host, host.pendingPage == nil, let current = host.pdf.currentPage, let doc = host.pdf.document
            else { return }
            let number = doc.index(for: current) + 1
            DispatchQueue.main.async { [weak self] in
                guard let self, self.host?.pendingPage == nil, self.host?.pdf.currentPage === current,
                    self.parent.page != number
                else { return }
                self.parent.page = number
                self.parent.selection = ""
            }
        }
        @objc func selectionChanged() {
            host?.scheduleSelectionPopup()
            // PDFKit may emit several changes during one selection drag. Read
            // the latest text once after that burst instead of retaining and
            // publishing every intermediate multi-page selection.
            guard !selectionUpdateScheduled else { return }
            selectionUpdateScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.selectionUpdateScheduled = false
                guard let host = self.host else { return }
                let text = String((host.pdf.currentSelection?.string ?? "").prefix(16_000))
                if self.parent.selection != text { self.parent.selection = text }
            }
        }
    }
}

@MainActor
final class StudyPDFHost: NSView, NSTextFieldDelegate {
    let pdf = StudyInteractivePDFView()
    let crop = StudyFigureOverlay()
    var url: URL?
    var revision = ""
    var pendingPage: Int?
    var zoom: CGFloat = 1
    var zoomMode = "width"
    weak var controls: StudyPDFControls?
    var onSelectionAction: ((String, Bool, String) -> Bool)?
    var selectionResponse: ((@escaping () -> Void) -> AnyView)?
    private(set) var responsePopover: NSPopover?
    var selectionBusy = false { didSet { explainButton.isEnabled = !selectionBusy } }
    private(set) var selectionPage: Int?
    private var popupText = ""
    private let questionField = NSTextField()
    private let selectionPreview = NSTextField(wrappingLabelWithString: "")
    private let explainButton = ScholiaPointingButton()
    private let selectionPopup = NSVisualEffectView()
    private var popupWork: DispatchWorkItem?
    private var mouseMonitor: Any?
    override init(frame: NSRect) {
        super.init(frame: frame)
        pdf.displayMode = .singlePageContinuous
        pdf.displayDirection = .vertical
        pdf.displaysPageBreaks = true
        pdf.pageBreakMargins = NSEdgeInsets(top: 22, left: 28, bottom: 22, right: 28)
        pdf.backgroundColor = .clear
        pdf.autoScales = true
        pdf.autoresizingMask = [.width, .height]
        crop.autoresizingMask = [.width, .height]
        crop.pdf = pdf
        crop.isHidden = true
        addSubview(pdf)
        addSubview(crop)
        pdf.host = self
        selectionPopup.material = .popover
        selectionPopup.state = .active
        selectionPopup.wantsLayer = true
        selectionPopup.layer?.cornerRadius = 12
        selectionPopup.isHidden = true
        selectionPreview.font = .systemFont(ofSize: 11)
        selectionPreview.textColor = .secondaryLabelColor
        selectionPreview.maximumNumberOfLines = 1
        selectionPreview.lineBreakMode = .byTruncatingTail
        questionField.placeholderString = "Add a question (optional)"
        questionField.font = .systemFont(ofSize: 12)
        questionField.bezelStyle = .roundedBezel
        questionField.delegate = self
        questionField.target = self
        questionField.action = #selector(explainSelection)
        questionField.setAccessibilityLabel("Ask about selected passage")
        explainButton.title = "Explain"
        explainButton.target = self
        explainButton.action = #selector(explainSelection)
        explainButton.bezelStyle = .rounded
        explainButton.font = .systemFont(ofSize: 11, weight: .medium)
        let ask = ScholiaPointingButton(title: "Open in chat ↗", target: self, action: #selector(askSelection))
        ask.bezelStyle = .inline
        ask.font = .systemFont(ofSize: 10)
        let close = ScholiaPointingButton(title: "×", target: self, action: #selector(closeSelection))
        close.isBordered = false
        close.setAccessibilityLabel("Close selection popup")
        let hint = NSTextField(labelWithString: "Selection + document context")
        hint.stringValue = "Passage + context"
        hint.font = .systemFont(ofSize: 9)
        hint.textColor = .secondaryLabelColor
        selectionPreview.frame = NSRect(x: 10, y: 65, width: 274, height: 17)
        questionField.frame = NSRect(x: 10, y: 32, width: 220, height: 27)
        explainButton.frame = NSRect(x: 236, y: 31, width: 76, height: 28)
        hint.frame = NSRect(x: 10, y: 9, width: 170, height: 14)
        ask.frame = NSRect(x: 205, y: 5, width: 105, height: 23)
        close.frame = NSRect(x: 289, y: 63, width: 22, height: 23)
        for view in [selectionPreview, questionField, explainButton, hint, ask, close] {
            selectionPopup.addSubview(view)
        }
        addSubview(selectionPopup)
        // PDFKit's internal document view can consume mouse-up instead of
        // forwarding it through PDFView. Observe the local event as well so a
        // long selection drag always gets its popup after the button is released.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(point), self.selectionPopup.isHidden || !self.selectionPopup.frame.contains(point) {
                self.scheduleSelectionPopup()
            }
            return event
        }
        setAccessibilityLabel("Course document reader")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        pdf.frame = bounds
        crop.frame = bounds
        // Legacy scrollers reserve a strip on the right, which leaves a fitted
        // page visibly off-centre. Overlay scrollers keep the page centred.
        if let scrollView = pdf.documentView?.enclosingScrollView, scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
        }
        fitZoom()
        if abs(bounds.width - centeredWidth) > 0.5 {
            centeredWidth = bounds.width
            centerHorizontally()
        }
        // PDFKit cannot restore a page accurately while SwiftUI's reader still
        // has a zero-sized frame. Navigate after its first real zoom/layout.
        if bounds.width > 20, bounds.height > 20, let number = pendingPage,
            let page = pdf.document?.page(at: number - 1)
        {
            pdf.go(to: page)
            pendingPage = nil
        }
        // Setting the popup frame itself schedules layout; hiding it here made
        // the popup disappear immediately after a successful text selection.
        if !selectionPopup.isHidden { showSelectionPopup() }
    }
    func stopObservingEvents() {
        closeSelectionResponse()
        popupWork?.cancel()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }
    func fitZoom() {
        guard bounds.width > 20, bounds.height > 20, ["page", "auto", "width"].contains(zoomMode),
            let page = pendingPage.flatMap({ pdf.document?.page(at: $0 - 1) }) ?? pdf.currentPage
        else { return }
        func size(_ page: PDFPage) -> CGSize {
            let rect = page.bounds(for: pdf.displayBox)
            return page.rotation % 180 == 0 ? rect.size : CGSize(width: rect.height, height: rect.width)
        }
        var dimensions = size(page)
        if pdf.displayMode == .twoUpContinuous, let document = pdf.document {
            let first = document.index(for: page) / 2 * 2
            let sizes = [document.page(at: first), document.page(at: first + 1)].compactMap { $0 }.map(size)
            dimensions = CGSize(
                width: sizes.reduce(0) { $0 + $1.width }, height: sizes.map(\.height).max() ?? dimensions.height)
        }
        let width = max(1, bounds.width - 60) / max(1, dimensions.width)
        let height = max(1, bounds.height - 48) / max(1, dimensions.height)
        let fit = min(width, height)
        let target = max(
            0.01,
            zoomMode == "page"
                ? fit : zoomMode == "auto" ? min(1.25, dimensions.width > dimensions.height ? fit : width) : width)
        // autoScales uses PDFKit's display-mode heuristic, which can fit only
        // the width of a continuous page. Both axes must constrain Fit page.
        pdf.autoScales = false
        pdf.minScaleFactor = min(0.01, target)
        pdf.maxScaleFactor = max(8, target)
        let previous = pdf.scaleFactor
        if abs(previous - target) > 0.005 {
            pdf.scaleFactor = target
            // A sidebar or focus change rescales the page in one step; keep the
            // reader on the same page top instead of an arbitrary scroll offset.
            if pendingPage == nil, abs(target / max(0.01, previous) - 1) > 0.1 { pdf.go(to: page) }
            centerHorizontally()
        }
    }
    private var centeredWidth: CGFloat = 0
    /// PDFKit keeps the horizontal scroll offset across rescaling, which leaves
    /// a fitted page sitting off-centre after the reader changes width.
    func centerHorizontally() {
        guard let scrollView = pdf.documentView?.enclosingScrollView else { return }
        let clip = scrollView.contentView
        let documentWidth = scrollView.documentView?.frame.width ?? 0
        guard documentWidth > clip.bounds.width + 1 else { return }
        let x = (documentWidth - clip.bounds.width) / 2
        guard abs(clip.bounds.origin.x - x) > 1 else { return }
        clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }
    func scheduleSelectionPopup() {
        popupWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showSelectionPopup() }
        popupWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
    func showSelectionPopup() {
        guard responsePopover?.isShown != true else { return }
        // Keep the captured passage while the popup's field editor owns focus.
        if !selectionPopup.isHidden, questionField.currentEditor() != nil { return }
        // Layout also runs while an NSButton is tracking a click. Hiding its
        // parent at that point cancels the click before its action can fire.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        guard crop.isHidden,
            let selection = pdf.currentSelection, let text = selection.string,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let page = selection.pages.last
        else {
            selectionPopup.isHidden = true
            return
        }
        let rect = convert(pdf.convert(selection.bounds(for: page), from: page), from: pdf)
        guard rect.intersects(bounds) else {
            selectionPopup.isHidden = true
            return
        }
        let captured = String(text.prefix(16_000))
        let selectedPage = pdf.document.map { $0.index(for: page) + 1 }
        if captured != popupText || selectedPage != selectionPage {
            questionField.stringValue = ""
            questionField.placeholderString = "Add a question (optional)"
            explainButton.title = "Explain"
        }
        popupText = captured
        selectionPage = selectedPage
        selectionPreview.stringValue = String(text.prefix(240))
        selectionPreview.toolTip = String(text.prefix(1000))
        let y = rect.minY > 100 ? rect.minY - 98 : min(bounds.height - 98, rect.maxY + 5)
        selectionPopup.frame = NSRect(
            x: max(6, min(bounds.width - 326, rect.midX - 160)), y: max(6, y), width: 320, height: 92)
        selectionPopup.isHidden = false
    }
    @objc private func explainSelection() { useSelection(explain: true) }
    @objc private func askSelection() { useSelection(explain: false) }
    private func useSelection(explain: Bool) {
        guard !popupText.isEmpty, !explain || !selectionBusy else { return }
        popupWork?.cancel()
        let question = questionField.stringValue
        // Release the field editor before chat takes focus, not after it.
        if !explain { closeSelection() }
        let sent = onSelectionAction?(popupText, explain, question) ?? false
        if !explain {
            selectionPopup.isHidden = sent
        } else if sent {
            if let selectionResponse {
                closeSelectionResponse()
                let popover = NSPopover()
                popover.behavior = .transient
                popover.animates = ScholiaVisualStyle.appKitAnimationsEnabled
                popover.contentSize = NSSize(width: 460, height: 440)
                popover.contentViewController = NSHostingController(rootView: selectionResponse { [weak self] in
                    self?.closeSelectionResponse()
                })
                responsePopover = popover
                let anchor = selectionPopup.frame
                closeSelection()
                popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
            } else {
                questionField.stringValue = ""
                questionField.placeholderString = "Ask a follow-up…"
                explainButton.title = "Send"
            }
        }
    }
    func closeSelectionResponse() {
        responsePopover?.close()
        responsePopover = nil
    }
    @objc private func closeSelection() {
        popupWork?.cancel()
        selectionPopup.isHidden = true
        if questionField.currentEditor() != nil { window?.makeFirstResponder(pdf) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            closeSelection()
            return true
        }
        return false
    }
}

@MainActor
final class StudyInteractivePDFView: PDFView {
    weak var host: StudyPDFHost?
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        host?.scheduleSelectionPopup()
    }
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        host?.scheduleSelectionPopup()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers,
            ["+", "=", "-", "0"].contains(key)
        {
            host?.controls?.zoom(key == "0" ? 0 : key == "-" ? -1 : 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: goToPreviousPage(nil)
        case 124: goToNextPage(nil)
        case 115: goToFirstPage(nil)
        case 119: goToLastPage(nil)
        default: super.keyDown(with: event)
        }
    }
}

@MainActor
final class StudyFigureOverlay: NSView {
    weak var pdf: PDFView?
    var onCapture: ((Data?) -> Void)?
    var capturedPage: Int?
    private var start: NSPoint?
    private var selected = NSRect.zero
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        start = convert(event.locationInWindow, from: nil)
        selected = .zero
        capturedPage = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        selected = NSRect(
            x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x),
            height: abs(point.y - start.y)
        ).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer {
            start = nil
            selected = .zero
            needsDisplay = true
        }
        guard selected.width >= 8, selected.height >= 8, let pdf else {
            onCapture?(nil)
            return
        }
        let rect = pdf.convert(selected, from: self)
        guard let capture = StudyPDFRegionCapture.capture(pdf: pdf, rect: rect) else {
            onCapture?(nil)
            return
        }
        capturedPage = capture.primaryPage
        onCapture?(capture.data)
    }
    override func cancelOperation(_ sender: Any?) { onCapture?(nil) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.10).setFill()
        bounds.fill()
        if !selected.isEmpty {
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            selected.fill()
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: selected)
            path.lineWidth = 2
            path.stroke()
        }
    }
}
