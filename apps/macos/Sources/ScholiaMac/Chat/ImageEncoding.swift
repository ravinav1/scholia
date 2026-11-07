@preconcurrency import AppKit
import CoreGraphics
import Foundation
import ImageIO

enum ImageEncoding {
    static let maximumInputBytes = 25_000_000

    /// Decodes a file directly to the provider-sized raster instead of first
    /// materializing its full-resolution NSImage on the main actor. Besides
    /// keeping drag/drop responsive, the byte and pixel bounds prevent a small
    /// compressed file from causing an unbounded decode allocation.
    static func jpegData(
        fileAt url: URL,
        maximumDimension: Int = 1_800,
        quality: CGFloat = 0.9
    ) -> Data? {
        guard url.isFileURL,
              maximumDimension > 0,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= maximumInputBytes,
              let source = CGImageSourceCreateWithURL(
                  url as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              let image = CGImageSourceCreateThumbnailAtIndex(
                  source,
                  0,
                  [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                      kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary
              ) else { return nil }
        return jpegData(from: image, maximumDimension: maximumDimension, quality: quality)
    }

    static func jpegData(
        from image: CGImage,
        maximumDimension: Int = 1_800,
        quality: CGFloat = 0.9
    ) -> Data? {
        let longest = max(image.width, image.height)
        let scale = longest > maximumDimension ? CGFloat(maximumDimension) / CGFloat(longest) : 1
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(
            destination,
            resized,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    @MainActor
    static func cgImage(from image: NSImage) -> CGImage? {
        var proposed = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }

    @MainActor
    static func jpegData(from image: NSImage, maximumDimension: Int = 1_800) -> Data? {
        guard let cgImage = cgImage(from: image) else { return nil }
        return jpegData(from: cgImage, maximumDimension: maximumDimension)
    }
}
