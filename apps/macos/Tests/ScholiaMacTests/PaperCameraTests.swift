import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import ScholiaMac

final class PaperCameraTests: XCTestCase {
    func testCameraKindsDistinguishMacIPhoneAndDeskView() {
        XCTAssertEqual(PaperCameraDeviceKind(deviceType: .builtInWideAngleCamera, isContinuityCamera: false), .builtIn)
        // Older Continuity discovery can report the built-in device type.
        XCTAssertEqual(PaperCameraDeviceKind(deviceType: .builtInWideAngleCamera, isContinuityCamera: true), .iPhone)
        XCTAssertEqual(PaperCameraDeviceKind(deviceType: .continuityCamera, isContinuityCamera: true), .iPhone)
        XCTAssertEqual(PaperCameraDeviceKind(deviceType: .deskViewCamera, isContinuityCamera: true), .deskView)
        XCTAssertEqual(PaperCameraDeviceKind(deviceType: .external, isContinuityCamera: false), .external)
        XCTAssertEqual(PaperCameraDevice(id: "webcam", name: "Webcam").kind, .external)
        XCTAssertFalse(PaperCameraDeviceKind.builtIn.recoveryInstructions.contains("iPhone"))
        XCTAssertTrue(PaperCameraDeviceKind.iPhone.recoveryInstructions.contains("Lock"))
    }

    func testFirstCameraFrameHasLongerGraceThanAStalledStream() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(PaperCameraTiming.isFrameDeliveryOverdue(
            startedAt: start, lastSampleAt: nil, now: start.addingTimeInterval(14.9)))
        XCTAssertTrue(PaperCameraTiming.isFrameDeliveryOverdue(
            startedAt: start, lastSampleAt: nil, now: start.addingTimeInterval(15.1)))
        let firstSample = start.addingTimeInterval(10)
        XCTAssertFalse(PaperCameraTiming.isFrameDeliveryOverdue(
            startedAt: start, lastSampleAt: firstSample, now: firstSample.addingTimeInterval(5.9)))
        XCTAssertTrue(PaperCameraTiming.isFrameDeliveryOverdue(
            startedAt: start, lastSampleAt: firstSample, now: firstSample.addingTimeInterval(6.1)))
        let recentSample = start.addingTimeInterval(120)
        XCTAssertFalse(PaperCameraTiming.isFrameDeliveryOverdue(
            startedAt: start, lastSampleAt: recentSample, now: recentSample.addingTimeInterval(1)))
    }

    func testSourceGeometryChangesRequireReviewAfterTheFirstFrame() {
        let landscape = PaperCameraSourceGeometry(width: 1_920, height: 1_080)
        let portrait = PaperCameraSourceGeometry(width: 1_080, height: 1_920)
        let smallerLandscape = PaperCameraSourceGeometry(width: 1_280, height: 720)
        var gate = PaperCameraGeometryGate()
        XCTAssertTrue(gate.observe(landscape))
        XCTAssertFalse(gate.requiresReview, "The initial source format must not block camera startup")
        XCTAssertFalse(gate.observe(landscape))
        XCTAssertFalse(gate.requiresReview)
        XCTAssertTrue(gate.observe(portrait))
        XCTAssertTrue(gate.requiresReview, "Swapped source dimensions change the crop's coordinate space")
        XCTAssertFalse(gate.observe(portrait))
        XCTAssertTrue(gate.requiresReview, "A steady stream must not automatically approve the new crop")
        XCTAssertFalse(gate.confirm(landscape), "Reviewing an older source format cannot approve the current one")
        XCTAssertTrue(gate.requiresReview)
        XCTAssertTrue(gate.confirm(portrait))
        XCTAssertFalse(gate.requiresReview)
        XCTAssertTrue(gate.observe(smallerLandscape))
        XCTAssertTrue(gate.requiresReview)
        XCTAssertTrue(gate.confirm(smallerLandscape))
        XCTAssertTrue(gate.observe(landscape))
        XCTAssertTrue(gate.requiresReview, "Resolution changes also require review, even at the same aspect ratio")
        XCTAssertFalse(gate.confirm(nil))
        XCTAssertTrue(gate.requiresReview)
    }

    func testComparisonAcceptsSmallExposureNoiseAndFractionalCameraDrift() {
        let base = comparisonInkFixture()
        for exposure in [-8, -3, 3, 8] {
            let adjusted = base.map { UInt8(max(0, min(255, Int($0) + exposure))) }
            XCTAssertFalse(PaperFrameComparison.changed(base, adjusted))
        }
        let noise = base.enumerated().map { index, value in
            UInt8(max(0, min(255, Int(value) + (index * 7919 % 7) - 3)))
        }
        XCTAssertFalse(PaperFrameComparison.changed(base, noise))
        for drift in [0.1, 0.13, 0.25, 0.37, 0.5, 0.62, 0.75, 1.0, 2.0] {
            let moved = comparisonShift(base, dx: drift, dy: drift)
            XCTAssertFalse(PaperFrameComparison.changed(base, moved), "Camera drift \(drift) must not become a mathematical revision")
            XCTAssertFalse(PaperFrameComparison.changed(moved, base), "Registration must work in either direction")
        }
    }

    func testComparisonStillFindsTinySignsAndErasedStrokes() {
        let base = comparisonInkFixture(), width = PaperFrameProcessor.fingerprintWidth
        for y in 155..<160 {
            for x in 180..<185 {
                var revised = base
                revised[y * width + x] = 40
                XCTAssertTrue(PaperFrameComparison.changed(base, revised), "An isolated new sign pixel must not disappear into motion tolerance")
                XCTAssertTrue(PaperFrameComparison.changed(revised, base), "Erasing a sign must also count")
            }
        }
        var minus = base
        for x in 180...183 { minus[60 * width + x] = 35 }
        XCTAssertTrue(PaperFrameComparison.changed(base, minus))
        var erased = base
        for y in 77...83 where y != 80 { erased[y * width + 153] = 240 }
        XCTAssertTrue(PaperFrameComparison.changed(base, erased), "Turning a plus into a minus must invalidate current feedback")
    }

    func testComparisonDetectsTouchingOperatorChanges() {
        let width = PaperFrameProcessor.fingerprintWidth
        var plus = comparisonInkFixture()
        for x in 185...187 { plus[165 * width + x] = 35 }
        for y in 164...166 { plus[y * width + 186] = 35 }
        var minus = plus
        minus[164 * width + 186] = 240; minus[166 * width + 186] = 240
        XCTAssertTrue(PaperFrameComparison.changed(plus, minus), "A compact 3-pixel plus must not be mistaken for camera drift")
        XCTAssertTrue(PaperFrameComparison.changed(minus, plus))
        var attached = comparisonInkFixture()
        attached[79 * width + 149] = 35
        XCTAssertTrue(PaperFrameComparison.changed(comparisonInkFixture(), attached), "A new pixel touching existing ink still matters")
        var notEqual = comparisonInkFixture()
        for offset in 0..<8 { notEqual[(35 + offset) * width + 73 + offset] = 35 }
        XCTAssertTrue(PaperFrameComparison.changed(comparisonInkFixture(), notEqual), "A diagonal touching both equality strokes changes the operator")
    }

    func testComparisonRejectsBroadMotionAndLargeExposureChange() {
        let base = comparisonInkFixture()
        XCTAssertTrue(PaperFrameComparison.changed(base, comparisonShift(base, dx: 8, dy: 7)))
        XCTAssertTrue(PaperFrameComparison.changed(base, base.map { UInt8(max(0, Int($0) - 35)) }))
        XCTAssertTrue(PaperFrameComparison.changed(base, [UInt8](repeating: 20, count: base.count)))
    }

    func testCropContainsOnlySelectedRegionAndUsesTopLeftCoordinates() throws {
        let source = try image(width: 800, height: 600) { _, y in y < 300 ? 25 : 230 }
        let top = try XCTUnwrap(PaperFrameProcessor.makeFrame(
            image: source, region: CGRect(x: 0, y: 0, width: 1, height: 0.5), detectHands: false))
        let bottom = try XCTUnwrap(PaperFrameProcessor.makeFrame(
            image: source, region: CGRect(x: 0, y: 0.5, width: 1, height: 0.5), detectHands: false))
        XCTAssertEqual(top.width, 800)
        XCTAssertEqual(top.height, 300)
        XCTAssertEqual(top.fingerprint.count, 49_152)
        XCTAssertLessThan(average(top.fingerprint), 40)
        XCTAssertGreaterThan(average(bottom.fingerprint), 210)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(top.jpeg as CFData, nil))
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        XCTAssertEqual(output.width, 800)
        XCTAssertEqual(output.height, 300, "JPEG must contain the crop, never the full camera image")
    }

    func testClockwiseRotationKeepsPreviewOrientationAndNativeCropPrivacy() throws {
        let source = try image(width: 800, height: 600) { x, y in
            y < 300 ? (x < 400 ? 20 : 80) : (x < 400 ? 160 : 230)
        }
        let width = PaperFrameProcessor.fingerprintWidth, height = PaperFrameProcessor.fingerprintHeight
        func corners(_ frame: PaperFrame) -> [UInt8] {
            [(width / 4, height / 4), (width * 3 / 4, height / 4),
             (width / 4, height * 3 / 4), (width * 3 / 4, height * 3 / 4)]
                .map { frame.fingerprint[$0.1 * width + $0.0] }
        }
        let fullExpected: [(Int, [UInt8])] = [
            (90, [160, 20, 230, 80]), (180, [230, 160, 80, 20]), (270, [80, 230, 20, 160])
        ]
        for (angle, expected) in fullExpected {
            let frame = try XCTUnwrap(PaperFrameProcessor.makeFrame(
                image: source, region: CGRect(x: 0, y: 0, width: 1, height: 1),
                detectHands: false, rotationDegrees: angle))
            XCTAssertEqual(corners(frame), expected, "Rotation must be clockwise, matching the preview connection")
            XCTAssertEqual(frame.width, angle == 180 ? 800 : 600)
            XCTAssertEqual(frame.height, angle == 180 ? 600 : 800)
        }
        let cropExpected: [(Int, [UInt8])] = [
            (90, [230, 80, 230, 80]), (180, [230, 230, 80, 80]), (270, [80, 230, 80, 230])
        ]
        for (angle, expected) in cropExpected {
            let frame = try XCTUnwrap(PaperFrameProcessor.makeFrame(
                image: source, region: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                detectHands: false, rotationDegrees: angle))
            XCTAssertEqual(corners(frame), expected, "Rotation must never add the unselected left half of the source")
            XCTAssertEqual(frame.width, angle == 180 ? 400 : 600)
            XCTAssertEqual(frame.height, angle == 180 ? 600 : 400)
            let decoded = try XCTUnwrap(CGImageSourceCreateWithData(frame.jpeg as CFData, nil))
            let jpeg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
            XCTAssertEqual(jpeg.width, frame.width)
            XCTAssertEqual(jpeg.height, frame.height)
        }
    }

    func testPreviewSelectionGeometryMatchesClockwiseImageRotation() {
        let video = CGRect(x: 100, y: 50, width: 400, height: 200)
        let native = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        // Native/image coordinates are top-left; CALayer coordinates are bottom-left.
        let expected: [(Int, CGRect)] = [
            (0, CGRect(x: 140, y: 130, width: 120, height: 80)),
            (90, CGRect(x: 260, y: 170, width: 160, height: 60)),
            (180, CGRect(x: 340, y: 90, width: 120, height: 80)),
            (270, CGRect(x: 180, y: 70, width: 160, height: 60))
        ]
        for (angle, expectedRect) in expected {
            let displayed = PaperPreviewGeometry.layerRect(forNativeRegion: native, in: video, rotationDegrees: angle)
            assertRectNear(displayed, expectedRect)
            let recovered = PaperPreviewGeometry.nativeRegion(forLayerRect: displayed, in: video, rotationDegrees: angle)
            assertRectNear(recovered, native)
        }
    }

    func testPreviewSelectionClipsLetterboxingWithoutExpandingTheCrop() {
        let video = CGRect(x: 100, y: 50, width: 400, height: 200)
        let dragged = CGRect(x: 80, y: 30, width: 100, height: 100)
        let visibleSelection = dragged.intersection(video)
        for angle in [0, 90, 180, 270] {
            let native = PaperPreviewGeometry.nativeRegion(forLayerRect: dragged, in: video, rotationDegrees: angle)
            XCTAssertTrue(native.minX >= -0.000_001 && native.minY >= -0.000_001)
            XCTAssertTrue(native.maxX <= 1.000_001 && native.maxY <= 1.000_001)
            assertRectNear(PaperPreviewGeometry.layerRect(forNativeRegion: native, in: video, rotationDegrees: angle), visibleSelection)
        }
        let clippedNative = CGRect(x: 0, y: 0.8, width: 0.3, height: 0.2)
        let overhanging = CGRect(x: -0.1, y: 0.8, width: 0.4, height: 0.5)
        let displayed = PaperPreviewGeometry.layerRect(forNativeRegion: overhanging, in: video, rotationDegrees: 90)
        assertRectNear(displayed, CGRect(x: 100, y: 190, width: 80, height: 60))
        assertRectNear(PaperPreviewGeometry.nativeRegion(forLayerRect: displayed, in: video, rotationDegrees: 90), clippedNative)
        XCTAssertTrue(PaperPreviewGeometry.nativeRegion(
            forLayerRect: CGRect(x: 0, y: 0, width: 20, height: 20), in: video, rotationDegrees: 90).isNull)
        XCTAssertTrue(PaperPreviewGeometry.layerRect(forNativeRegion: .zero, in: video, rotationDegrees: 90).isNull)
        XCTAssertTrue(PaperPreviewGeometry.layerRect(forNativeRegion: clippedNative, in: .zero, rotationDegrees: 90).isNull)
    }

    func testEncodedEvidenceIsBoundedAndKeepsAspectRatio() throws {
        let source = try image(width: 2_400, height: 1_600) { x, y in (x / 16 + y / 16).isMultiple(of: 2) ? 30 : 240 }
        let frame = try XCTUnwrap(PaperFrameProcessor.makeFrame(
            image: source, region: CGRect(x: 0, y: 0, width: 1, height: 1), detectHands: false))
        XCTAssertEqual(frame.width, 1_920)
        XCTAssertEqual(frame.height, 1_280)
        XCTAssertNil(frame.qualityIssue)
        let decoded = try XCTUnwrap(CGImageSourceCreateWithData(frame.jpeg as CFData, nil))
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        XCTAssertEqual(output.width, frame.width)
        XCTAssertEqual(output.height, frame.height)
    }

    func testQualityRejectsDarkBlankBlurredAndSmallFrames() {
        let width = 256, height = 256
        func issue(_ pixels: [UInt8], sourceWidth: Int = 800, sourceHeight: Int = 600) -> String? {
            PaperFrameProcessor.qualityIssue(pixels: pixels, width: width, height: height,
                                            sourceWidth: sourceWidth, sourceHeight: sourceHeight)
        }
        XCTAssertTrue(issue([UInt8](repeating: 20, count: width * height))?.contains("dark") == true)
        XCTAssertTrue(issue([UInt8](repeating: 250, count: width * height))?.contains("not yet visible") == true)
        // Smooth, high-contrast gradients have no fine structure: contrast alone
        // must not let a defocused frame pass the readability check.
        let blur = (0..<height).flatMap { _ in (0..<width).map { UInt8(60 + $0 / 2) } }
        XCTAssertTrue(issue(blur)?.contains("blurred") == true)
        XCTAssertTrue(issue(blur, sourceWidth: 100)?.contains("too few pixels") == true)
        let crisp = (0..<(width * height)).map { UInt8($0 % 17 < 3 ? 35 : 240) }
        XCTAssertNil(issue(crisp, sourceWidth: 640, sourceHeight: 305))
        XCTAssertNil(issue(crisp, sourceWidth: 305, sourceHeight: 640), "Rotating the same readable pixels must not fail the size gate")
        XCTAssertTrue(issue(crisp, sourceWidth: 640, sourceHeight: 159)?.contains("too few pixels") == true)
        XCTAssertTrue(issue(crisp, sourceWidth: 159, sourceHeight: 640)?.contains("too few pixels") == true)
    }

    func testReadableStrokesPassAndChangedWritingChangesFingerprint() throws {
        let first = try image(width: 800, height: 600) { x, y in
            (y > 150 && y < 160 && x > 100 && x < 650) || (x > 350 && x < 360 && y > 80 && y < 240) ? 20 : 245
        }
        let revised = try image(width: 800, height: 600) { x, y in
            (y > 150 && y < 160 && x > 100 && x < 650) || (x > 450 && x < 460 && y > 80 && y < 240) ? 20 : 245
        }
        let a = try XCTUnwrap(PaperFrameProcessor.makeFrame(image: first, region: CGRect(x: 0, y: 0, width: 1, height: 1), detectHands: false))
        let b = try XCTUnwrap(PaperFrameProcessor.makeFrame(image: revised, region: CGRect(x: 0, y: 0, width: 1, height: 1), detectHands: false))
        XCTAssertNil(a.qualityIssue)
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
    }

    func testInvalidOrEmptyRegionsNeverEmitUncroppedEvidence() throws {
        let source = try image(width: 800, height: 600) { _, _ in 240 }
        for region in [CGRect.zero, CGRect(x: 2, y: 2, width: 1, height: 1), CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1)] {
            XCTAssertNil(PaperFrameProcessor.makeFrame(image: source, region: region, detectHands: false))
        }
    }

    private func assertRectNear(_ actual: CGRect, _ expected: CGRect,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(actual.isNull, file: file, line: line)
        for (actualValue, expectedValue) in zip(
            [actual.minX, actual.minY, actual.width, actual.height],
            [expected.minX, expected.minY, expected.width, expected.height]) {
            XCTAssertLessThan(abs(actualValue - expectedValue), 0.000_001, file: file, line: line)
        }
    }

    private func comparisonInkFixture() -> [UInt8] {
        let width = PaperFrameProcessor.fingerprintWidth, height = PaperFrameProcessor.fingerprintHeight
        var pixels = [UInt8](repeating: 240, count: width * height)
        func stroke(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            for py in y..<(y + h) { for px in x..<(x + w) { pixels[py * width + px] = 35 } }
        }
        for y in [35, 75, 115] {
            for x in 25...48 { stroke(x, y + abs(x - 35) / 2, 2, 2) }
            stroke(70, y + 1, 12, 2); stroke(70, y + 5, 12, 2)
            for x in 100...119 { stroke(x, y + abs(x - 108) / 2, 2, 2) }
        }
        stroke(150, 80, 7, 1); stroke(153, 77, 1, 7)
        stroke(205, 140, 1, 1)
        return pixels
    }

    private func comparisonShift(_ pixels: [UInt8], dx: Double, dy: Double) -> [UInt8] {
        let width = PaperFrameProcessor.fingerprintWidth, height = PaperFrameProcessor.fingerprintHeight
        var result = pixels
        func value(_ x: Int, _ y: Int) -> Double {
            x >= 0 && y >= 0 && x < width && y < height ? Double(pixels[y * width + x]) : 240
        }
        for y in 0..<height { for x in 0..<width {
            let px = Double(x) + dx, py = Double(y) + dy
            let ix = Int(floor(px)), iy = Int(floor(py)), fx = px - Double(ix), fy = py - Double(iy)
            let sample = (1 - fx) * (1 - fy) * value(ix, iy) + fx * (1 - fy) * value(ix + 1, iy)
                + (1 - fx) * fy * value(ix, iy + 1) + fx * fy * value(ix + 1, iy + 1)
            result[y * width + x] = UInt8(sample.rounded())
        } }
        return result
    }

    private func image(width: Int, height: Int, pixel: (Int, Int) -> UInt8) throws -> CGImage {
        let values = (0..<height).flatMap { y in (0..<width).map { x in pixel(x, y) } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(values) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func average(_ pixels: [UInt8]) -> Double {
        pixels.reduce(0) { $0 + Double($1) } / Double(pixels.count)
    }
}
