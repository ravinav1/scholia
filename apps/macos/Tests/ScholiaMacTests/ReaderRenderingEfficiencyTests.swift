import AppKit
import PDFKit
import SwiftUI
import XCTest
@testable import ScholiaMac

final class ReaderRenderingEfficiencyTests: XCTestCase {
    @MainActor
    private func textView() -> SelfSizingTextView {
        let view = SelfSizingTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 1))
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        return view
    }

    @MainActor
    private func attachments(in view: SelfSizingTextView) -> [NSTextAttachment] {
        var result: [NSTextAttachment] = []
        view.textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: view.string.utf16.count)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { result.append(attachment) }
        }
        return result
    }

    @MainActor
    func testPDFCaptureCallbacksReleaseClosedReadersAndTheirDocuments() {
        weak var releasedHost: StudyPDFHost?
        weak var releasedDocument: PDFDocument?
        autoreleasepool {
            let reader = StudyPDFReader(url: URL(fileURLWithPath: "/tmp/reader-lifecycle.pdf"),
                page: .constant(1), selection: .constant(""), selectingFigure: .constant(false),
                zoom: 1, onFigure: { _ in })
            let host = StudyPDFHost()
            host.pdf.document = PDFDocument()
            reader.configureActions(for: host)
            releasedHost = host
            releasedDocument = host.pdf.document
            host.stopObservingEvents()
        }
        XCTAssertNil(releasedHost, "The figure callback must not retain its owning reader")
        XCTAssertNil(releasedDocument, "Closing a reader must release its PDF document")
    }

    @MainActor
    func testDismantlingImmediatelyReleasesPDFAndInteractionClosures() {
        let reader = StudyPDFReader(url: URL(fileURLWithPath: "/tmp/reader-lifecycle.pdf"),
            page: .constant(1), selection: .constant(""), selectingFigure: .constant(false),
            zoom: 1, onFigure: { _ in })
        let host = StudyPDFHost()
        let coordinator = StudyPDFReader.Coordinator(reader)
        coordinator.host = host
        host.pdf.document = PDFDocument()
        reader.configureActions(for: host)
        StudyPDFReader.dismantleNSView(host, coordinator: coordinator)
        XCTAssertNil(host.pdf.document, "SwiftUI can retain a dismantled view briefly; release the expensive document immediately")
        XCTAssertNil(host.crop.onCapture)
        XCTAssertNil(host.onSelectionAction)
    }

    @MainActor
    func testWidthChangesPreserveTextSelectionAndResizeExistingEquation() throws {
        let source = "A selectable explanation.\n\n$$" + String(repeating: "x + ", count: 45) + "y$$\n\nInline $a^2$ stays readable."
        let view = textView()
        view.updateMarkdown(source, compact: false, colorScheme: .light, width: 800)
        let initial = attachments(in: view)
        XCTAssertEqual(initial.count, 2)
        let display = try XCTUnwrap(initial.first)
        let inline = try XCTUnwrap(initial.last)
        let originalBounds = display.bounds
        let inlineBounds = inline.bounds
        let selection = (view.string as NSString).range(of: "selectable explanation")
        view.setSelectedRange(selection)

        view.updateMarkdown(source, compact: false, colorScheme: .light, width: 300)
        XCTAssertTrue(attachments(in: view).first === display, "Resize must keep the existing equation and parsed text")
        XCTAssertLessThan(display.bounds.width, originalBounds.width)
        XCTAssertLessThanOrEqual(display.bounds.width, 280)
        XCTAssertEqual(inline.bounds, inlineBounds)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(view.selectedPlainText(), "selectable explanation")

        _ = view.requiredHeight(for: 800)
        XCTAssertEqual(display.bounds, originalBounds, "Widening restores the original equation size without quality loss")
        view.setSelectedRange(NSRange(location: 0, length: view.string.utf16.count))
        XCTAssertTrue(view.selectedPlainText()?.contains("$$" + String(repeating: "x + ", count: 45)) == true)

        view.updateMarkdown(source + "\n\nUpdated.", compact: false, colorScheme: .light, width: 800)
        XCTAssertTrue(view.string.contains("Updated."), "Content changes must still rerender")
        XCTAssertFalse(attachments(in: view).first === display)
    }

    @MainActor
    func testSeparateReaderWidthsShareNaturalSizeMathImages() throws {
        let source = "$$" + String(repeating: "x + ", count: 45) + "y$$"
        let narrow = textView(), wide = textView()
        narrow.updateMarkdown(source, compact: false, colorScheme: .light, width: 300)
        wide.updateMarkdown(source, compact: false, colorScheme: .light, width: 800)
        let first = try XCTUnwrap(attachments(in: narrow).first)
        let second = try XCTUnwrap(attachments(in: wide).first)
        XCTAssertTrue(first.image === second.image, "Pane widths must not duplicate cached equation images")
        XCTAssertLessThan(first.bounds.width, second.bounds.width)
        let imageSize = try XCTUnwrap(first.image).size
        _ = narrow.requiredHeight(for: 450)
        XCTAssertEqual(second.image?.size, imageSize, "Resizing one reader must not mutate shared images")
    }

    @MainActor
    func testMarkdownResizeBenchmark() {
        let source = String(repeating: "## Lecture explanation\n\nA **key concept** with an inline equation $a^2 + b^2 = c^2$ and [a reference](https://example.com).\n\n- Understand the relationship\n- Compare the result\n\n$$\\sum_{i=1}^{n} x_i = x_1 + x_2 + \\cdots + x_n$$\n\n", count: 15)
        let view = textView()
        let widths = (0..<30).map { CGFloat(400 + $0 * 10) }
        let baselineStart = ContinuousClock.now
        for width in widths {
            view.textStorage?.setAttributedString(RichMarkdownDocumentRenderer(compact: false,
                colorScheme: .light, availableWidth: width).render(source))
            _ = view.requiredHeight(for: width)
        }
        let baseline = baselineStart.duration(to: .now)
        view.updateMarkdown(source, compact: false, colorScheme: .light, width: widths[0])
        let resizedStart = ContinuousClock.now
        for width in widths {
            view.updateMarkdown(source, compact: false, colorScheme: .light, width: width)
            _ = view.requiredHeight(for: width)
        }
        let resized = resizedStart.duration(to: .now)
        print("Markdown resize benchmark: 30 full rerenders \(baseline), 30 preserved-text reflows \(resized)")
    }
}
