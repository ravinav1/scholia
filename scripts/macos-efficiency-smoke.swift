import AppKit
import Foundation
@testable import ScholiaMac

// Run the same regression bodies on Command Line Tools installations, which
// provide AppKit/PDFKit but omit XCTest. Failures remain fatal assertions.
func XCTAssertEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T, _ message: String = "") {
    do { let value = try actual(); precondition(value == expected, "\(message) Expected \(expected), got \(value)") }
    catch { preconditionFailure("\(message) Unexpected error: \(error)") }
}
func XCTAssertNil<T>(_ value: T?, _ message: String = "") { precondition(value == nil, message) }
func XCTAssertTrue(_ value: Bool, _ message: String = "") { precondition(value, message) }
func XCTAssertFalse(_ value: Bool, _ message: String = "") { precondition(!value, message) }
func XCTAssertLessThan<T: Comparable>(_ value: T, _ bound: T, _ message: String = "") { precondition(value < bound, message) }
func XCTAssertLessThanOrEqual<T: Comparable>(_ value: T, _ bound: T, _ message: String = "") { precondition(value <= bound, message) }
func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: String = "") {
    do { _ = try expression(); preconditionFailure(message) } catch { }
}
func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T, _ message: String = "") {
    do { _ = try expression() } catch { preconditionFailure("\(message) Unexpected error: \(error)") }
}
func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw StudyError.message("Expected a non-nil value") }
    return value
}

@main @MainActor
struct EfficiencySmoke {
    static func main() throws {
        _ = NSApplication.shared
        let rendering = ReaderRenderingEfficiencyTests()
        rendering.testPDFCaptureCallbacksReleaseClosedReadersAndTheirDocuments()
        rendering.testDismantlingImmediatelyReleasesPDFAndInteractionClosures()
        print("PASS: closed PDF readers and documents release; dismantling clears interaction closures")
        try rendering.testWidthChangesPreserveTextSelectionAndResizeExistingEquation()
        try rendering.testSeparateReaderWidthsShareNaturalSizeMathImages()
        print("PASS: markdown resize preserves text/selection, rescales equations and shares natural-size images")
        rendering.testMarkdownResizeBenchmark()
        let history = ConversationHistoryWriterTests()
        try history.testSlowWriteDoesNotBlockSubmissionAndClearSupersedesQueuedSaves()
        try history.testClearCannotBeUndoneByAnOlderSaveAndNewHistoryCanFollowIt()
        try history.testFlushReportsFailureUntilALaterWriteSucceeds()
        print("PASS: history writes stay off the caller, coalesce queued saves, preserve clear ordering and report failures")
    }
}
