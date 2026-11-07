@preconcurrency import AppKit
import PDFKit

/// A page-space render, independent of NSView backing-store offsets and Retina
/// caching. PDFView supplies the transform, including crop boxes, zoom, scroll,
/// page rotation and spread placement. Only output quality uses backing scale.
@MainActor
enum StudyPDFRegionCapture {
    struct Region {
        var page: PDFPage
        var pageToView: CGAffineTransform
        var visibleBounds: CGRect
        var number: Int
    }
    struct Capture {
        var data: Data
        var primaryPage: Int
    }

    static func capture(pdf: PDFView, rect: CGRect) -> Capture? {
        guard let document = pdf.document else { return nil }
        let rect = rect.standardized.intersection(pdf.bounds)
        let regions = pdf.visiblePages.compactMap { page -> Region? in
            let bounds = pdf.convert(page.bounds(for: pdf.displayBox), from: page)
            guard bounds.intersects(rect) else { return nil }
            let origin: NSPoint = pdf.convert(NSPoint.zero, from: page)
            let x = pdf.convert(NSPoint(x: 1, y: 0), from: page)
            let y = pdf.convert(NSPoint(x: 0, y: 1), from: page)
            return Region(
                page: page,
                pageToView: CGAffineTransform(
                    a: x.x - origin.x, b: x.y - origin.y, c: y.x - origin.x, d: y.y - origin.y, tx: origin.x,
                    ty: origin.y), visibleBounds: bounds, number: document.index(for: page) + 1)
        }
        guard
            let primary = regions.max(by: {
                $0.visibleBounds.intersection(rect).area < $1.visibleBounds.intersection(rect).area
            }),
            let image = render(
                regions: regions, rect: rect, box: pdf.displayBox, flipped: pdf.isFlipped,
                scale: max(pdf.window?.backingScaleFactor ?? 2, 2 / max(0.1, pdf.scaleFactor))),
            let data = ImageEncoding.jpegData(from: image)
        else { return nil }
        return Capture(data: data, primaryPage: primary.number)
    }

    static func render(
        regions: [Region], rect: CGRect, box: PDFDisplayBox = .cropBox, flipped: Bool = false,
        scale requested: CGFloat = 2
    ) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1, rect.width.isFinite, rect.height.isFinite, !regions.isEmpty else {
            return nil
        }
        let scale = min(max(0.1, requested), 1_800 / max(rect.width, rect.height))
        let width = max(1, Int(ceil(rect.width * scale)))
        let height = max(1, Int(ceil(rect.height * scale)))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let viewToImage = CGAffineTransform(
            a: scale, b: 0, c: 0, d: flipped ? -scale : scale,
            tx: -rect.minX * scale, ty: (flipped ? rect.maxY : -rect.minY) * scale)
        for region in regions {
            guard let page = region.page.pageRef, region.visibleBounds.intersects(rect) else { continue }
            context.saveGState()
            context.concatenate(region.pageToView.concatenating(viewToImage))
            context.clip(to: region.page.bounds(for: box))
            // CGPDFPage drawing uses original page coordinates; applying the
            // PDFView transform exactly once avoids double rotation/scaling.
            context.drawPDFPage(page)
            context.restoreGState()
        }
        return context.makeImage()
    }
}

extension CGRect { fileprivate var area: CGFloat { isNull ? 0 : width * height } }
