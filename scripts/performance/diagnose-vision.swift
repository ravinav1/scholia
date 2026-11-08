// Diagnostic only: no Scholia import, PDFKit, window, application services or
// user files. Framework failures are recorded, not converted into a test pass.
// swiftc -O scripts/performance/diagnose-vision.swift -o /tmp/scholia-vision-probe
// /tmp/scholia-vision-probe /path/to/vision-capabilities.json
import CoreGraphics
import CoreText
import Darwin
import Foundation
import Vision

private struct ProbeFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func jsonValue(_ value: Any, depth: Int = 0) -> Any {
    guard depth < 8 else { return String(describing: value) }
    if let error = value as? NSError { return errorRecord(error, depth: depth + 1) }
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value }
    if value is NSNull { return NSNull() }
    if let values = value as? [Any] { return values.map { jsonValue($0, depth: depth + 1) } }
    if let values = value as? [String: Any] { return values.mapValues { jsonValue($0, depth: depth + 1) } }
    return String(describing: value)
}

private func errorRecord(_ error: NSError, depth: Int = 0) -> [String: Any] {
    var result: [String: Any] = [
        "domain": error.domain, "code": error.code,
        "description": error.description, "debugDescription": error.debugDescription,
        "localizedDescription": error.localizedDescription,
        "userInfo": error.userInfo.mapValues { jsonValue($0, depth: depth + 1) }
    ]
    if let reason = error.localizedFailureReason { result["localizedFailureReason"] = reason }
    if let suggestion = error.localizedRecoverySuggestion { result["localizedRecoverySuggestion"] = suggestion }
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, depth < 8 {
        result["underlyingError"] = errorRecord(underlying, depth: depth + 1)
    }
    return result
}

private func makeImage() throws -> CGImage {
    let width = 1_600, height = 600
    guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw ProbeFailure(message: "Could not construct the fixed-pixel OCR image")
    }
    bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
    bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let text = NSAttributedString(string: "Scanned attachment contains all the evidence", attributes: [
        NSAttributedString.Key(rawValue: kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 48, nil),
        NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
    ])
    let line = CTLineCreateWithAttributedString(text)
    guard CTLineGetTypographicBounds(line, nil, nil, nil) < Double(width - 100) else {
        throw ProbeFailure(message: "OCR fixture text would be clipped")
    }
    bitmap.textPosition = CGPoint(x: 50, y: 280)
    CTLineDraw(line, bitmap)
    guard let image = bitmap.makeImage() else { throw ProbeFailure(message: "Could not create the OCR CGImage") }
    return image
}

private func runProbe() throws {
    guard CommandLine.arguments.count == 2 else {
        throw ProbeFailure(message: "Usage: scholia-vision-probe /path/to/vision-capabilities.json")
    }
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let image = try makeImage()
    #if arch(arm64)
    let architecture = "arm64"
    #elseif arch(x86_64)
    let architecture = "x86_64"
    #else
    let architecture = "other"
    #endif
    var report: [String: Any] = [
        "kind": "direct-vision-capability-diagnostic",
        "recordedAt": ISO8601DateFormatter().string(from: Date()),
        "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "architecture": architecture,
        "processorCount": ProcessInfo.processInfo.processorCount,
        "physicalMemory": ProcessInfo.processInfo.physicalMemory,
        "image": ["width": image.width, "height": image.height,
            "construction": "CoreGraphics bitmap + CoreText Helvetica 48; direct CGImage; no PDF or AppKit"],
        "expectedPhrase": "all the evidence",
        "supportedRevisions": Array(VNRecognizeTextRequest.supportedRevisions),
        "currentRevision": VNRecognizeTextRequest.currentRevision,
        "defaultRevision": VNRecognizeTextRequest.defaultRevision,
        "diagnosticOnly": true,
        "complete": false
    ]
    var results: [[String: Any]] = []
    func publish() throws {
        report["variants"] = results
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output, options: .atomic)
    }
    try publish()
    let variants: [(String, VNRequestTextRecognitionLevel, Bool, Bool)] = [
        ("accurate_auto_default", .accurate, true, false),
        ("accurate_auto_cpu", .accurate, true, true),
        ("accurate_english_default", .accurate, false, false),
        ("accurate_english_cpu", .accurate, false, true),
        ("fast_english_cpu", .fast, false, true)
    ]
    for (name, level, autoDetect, cpuOnly) in variants {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.automaticallyDetectsLanguage = autoDetect
        if !autoDetect { request.recognitionLanguages = ["en-US"] }
        // Deliberately probe the deprecated switch to distinguish unavailable
        // accelerators from text-recognition/model failures on virtual runners.
        request.usesCPUOnly = cpuOnly
        var result: [String: Any] = [
            "name": name, "revision": request.revision,
            "recognitionLevel": level == .accurate ? "accurate" : "fast",
            "automaticallyDetectsLanguage": autoDetect, "usesCPUOnly": cpuOnly,
            "recognitionLanguages": request.recognitionLanguages,
            "usesLanguageCorrection": request.usesLanguageCorrection
        ]
        do { result["supportedLanguages"] = try request.supportedRecognitionLanguages() }
        catch { result["supportedLanguagesError"] = errorRecord(error as NSError) }
        let started = Date()
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
            let candidates = (request.results ?? []).compactMap { $0.topCandidates(1).first }
            let recognized = candidates.map(\.string).joined(separator: "\n")
            result["performSucceeded"] = true
            result["recognizedText"] = recognized
            result["confidences"] = candidates.map { Double($0.confidence) }
            result["expectedPhraseMatched"] = recognized.contains("all the evidence")
        } catch {
            result["performSucceeded"] = false
            result["expectedPhraseMatched"] = false
            result["error"] = errorRecord(error as NSError)
        }
        result["elapsedMilliseconds"] = Date().timeIntervalSince(started) * 1_000
        results.append(result)
        try publish()
        print("\(name): perform=\(result["performSucceeded"]!) phrase=\(result["expectedPhraseMatched"]!)")
        fflush(stdout)
    }
    report["complete"] = true
    try publish()
    print("Recorded direct Vision diagnostics at \(output.path). Framework failures remain failures in the native OCR gate.")
}

do { try runProbe() }
catch {
    FileHandle.standardError.write(Data("Vision probe could not complete: \(error)\n".utf8))
    exit(1)
}
