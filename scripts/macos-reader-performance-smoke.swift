import Combine
import PDFKit
import SwiftUI
@testable import ScholiaMac

private final class IndexReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func read(_ url: URL) throws -> Data {
        lock.withLock { value += 1 }
        return try Data(contentsOf: url)
    }
}

final class ReaderPerformanceChecks {
    var cleanup: [() -> Void] = []
    func addTeardownBlock(_ block: @escaping () -> Void) { cleanup.append(block) }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func write(_ text: String, at url: URL) throws {
        try JSONEncoder().encode(StudyDocumentIndex(pages: [StudyPage(number: 1, text: text)]))
            .write(to: url, options: .atomic)
    }

    func testWarmIndexesAvoidReadsAndAtomicReplacementWithSameSizeAndDateInvalidates() throws {
        let url = try root().appendingPathComponent("index.json")
        try write("before", at: url)
        let originalDate = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]!
        let reads = IndexReadCounter()
        let cache = StudyDocumentIndexCache(readData: { try reads.read($0) })
        for _ in 0..<100 { expectEqual(try cache.index(at: url).pages[0].text, "before") }
        expectEqual(reads.count, 1, "A warm index must avoid disk reads and JSON decoding")
        try write("after!", at: url)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: url.path)
        expectEqual(try cache.index(at: url).pages[0].text, "after!")
        expectEqual(reads.count, 2, "Atomic replacements must invalidate even when size and date match")
        try FileManager.default.removeItem(at: url)
        expectThrows(try cache.index(at: url), "A removed file must not survive through a stale cache")
    }

    func testCacheEvictsLeastRecentlyUsedIndexesAndDoesNotRetainOversizedFiles() throws {
        let root = try root()
        let urls = (0..<3).map { root.appendingPathComponent("\($0).json") }
        for (i, url) in urls.enumerated() { try write("Index \(i)", at: url) }
        let reads = IndexReadCounter()
        let cache = StudyDocumentIndexCache(maximumEntries: 2, readData: { try reads.read($0) })
        _ = try cache.index(at: urls[0])
        _ = try cache.index(at: urls[1])
        _ = try cache.index(at: urls[0]) // Keep the actively read document.
        _ = try cache.index(at: urls[2])
        _ = try cache.index(at: urls[0])
        expectEqual(reads.count, 3)
        _ = try cache.index(at: urls[1])
        expectEqual(reads.count, 4)
        let tiny = StudyDocumentIndexCache(maximumBytes: 1, readData: { try reads.read($0) })
        _ = try tiny.index(at: urls[0])
        _ = try tiny.index(at: urls[0])
        expectEqual(reads.count, 6)
    }

    func testMemoryPressurePurgesIndexesAndSkipsRetentionUntilRecovery() throws {
        let url = try root().appendingPathComponent("pressure.json")
        try write("Keep the active reading usable", at: url)
        let reads = IndexReadCounter()
        let cache = StudyDocumentIndexCache(readData: { try reads.read($0) })
        let active = try cache.index(at: url)
        _ = try cache.index(at: url)
        expectEqual(reads.count, 1)
        cache.setMemoryPressure(true)
        expectEqual(active.pages[0].text, "Keep the active reading usable")
        _ = try cache.index(at: url)
        _ = try cache.index(at: url)
        expectEqual(reads.count, 3, "Memory pressure must purge old entries and suppress new retention")
        cache.setMemoryPressure(false)
        _ = try cache.index(at: url)
        _ = try cache.index(at: url)
        expectEqual(reads.count, 4, "Warm caching resumes when pressure ends")
    }

    func testPressureDuringDecodeDoesNotRefillPurgedCache() async throws {
        let url = try root().appendingPathComponent("inflight.json")
        try write("A pending reading", at: url)
        let reads = IndexReadCounter()
        let started = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let cache = StudyDocumentIndexCache(readData: { url in
            let data = try reads.read(url)
            if reads.count == 1 {
                started.signal()
                precondition(resume.wait(timeout: .now() + 5) == .success)
            }
            return data
        })
        let pending = Task.detached { try cache.index(at: url) }
        defer { resume.signal() }
        precondition(started.wait(timeout: .now() + 5) == .success)
        cache.setMemoryPressure(true)
        cache.setMemoryPressure(false)
        resume.signal()
        let loaded = try await pending.value
        expectEqual(loaded.pages[0].text, "A pending reading")
        _ = try cache.index(at: url)
        _ = try cache.index(at: url)
        expectEqual(reads.count, 2, "A decode started before the purge must not repopulate the cache")
    }

    func testLargeIndexWarmReadBenchmark() throws {
        let url = try root().appendingPathComponent("large-index.json")
        let index = StudyDocumentIndex(pages: (1...120).map {
            StudyPage(number: $0, text: String(repeating: "Lecture concepts and explanations. ", count: 240))
        })
        let data = try JSONEncoder().encode(index)
        try data.write(to: url, options: .atomic)
        let cache = StudyDocumentIndexCache()
        _ = try cache.index(at: url)
        let baselineStart = ContinuousClock.now
        for _ in 0..<30 {
            expectEqual(try JSONDecoder().decode(StudyDocumentIndex.self, from: Data(contentsOf: url)).pages.count, 120)
        }
        let baseline = baselineStart.duration(to: .now)
        let warmStart = ContinuousClock.now
        for _ in 0..<30 { expectEqual(try cache.index(at: url).pages.count, 120) }
        let warm = warmStart.duration(to: .now)
        print("Index cache benchmark: \(data.count) bytes, 30 uncached reads \(baseline), 30 warm reads \(warm)")
    }

    func testNewOCRSidecarOverridesPreviouslyCachedBaseIndex() throws {
        let store = StudyLibraryStore(root: try root())
        let document = StudyDocument(title: "Scan", kind: .pdf, fileName: "original.pdf", pageCount: 1, contentHash: "fixture")
        try store.write(document: document, index: StudyDocumentIndex(pages: [StudyPage(number: 1, text: "")]), data: Data())
        expectEqual(try store.index(for: document).pages[0].text, "")
        let sidecar = try unwrap(store.enrichedIndexURL(for: document))
        try write("Recognized text", at: sidecar)
        expectEqual(try store.index(for: document).pages[0].text, "Recognized text")
        try Data("interrupted sidecar".utf8).write(to: sidecar, options: .atomic)
        expectEqual(try store.index(for: document).pages[0].text, "", "Corrupt optional OCR must fall back to the base index")
    }

    @MainActor
    func testConversationNavigationKeepsReadyIndexButContentRevisionReloads() async throws {
        let store = StudyLibraryStore(root: try root())
        let document = try StudyDocumentImporter.read(data: Data("Original reading".utf8), name: "reading.md", store: store)
        let first = StudyThread(documentID: document.id)
        let second = StudyThread(documentID: document.id)
        let course = StudyCourse(name: "Fixture", documents: [document], threads: [first, second])
        try store.save(StudyLibrary(courses: [course], selectedCourseID: course.id,
            selectedDocumentID: document.id, selectedThreadID: first.id, showingCourseLibrary: false))
        let model = StudyWorkspaceModel(store: store)
        defer { model.flush() }
        for _ in 0..<100 where model.documentIndex == nil { try await Task.sleep(for: .milliseconds(10)) }
        expectEqual(model.documentIndex?.pages[0].text, "Original reading")
        var emptyPublications = 0
        let observation = model.$documentIndex.dropFirst().sink { if $0 == nil { emptyPublications += 1 } }
        defer { observation.cancel() }
        model.selectThread(second.id)
        expectEqual(model.documentIndex?.pages[0].text, "Original reading")
        expectEqual(emptyPublications, 0, "Changing conversations must not blank the same document")

        try write("Updated reading", at: store.directory(for: document.id).appendingPathComponent("index.json"))
        model.library.courses[0].documents[0].contentHash = "new-revision"
        model.selectDocument(document.id)
        expectEqual(emptyPublications, 1, "Changed file content must trigger an index reload")
        for _ in 0..<100 where model.documentIndex == nil { try await Task.sleep(for: .milliseconds(10)) }
        expectEqual(model.documentIndex?.pages[0].text, "Updated reading")
    }

    @MainActor
    func testPDFNavigationCancelsStaleLoadsAndKeepsLatestPendingPage() async throws {
        let root = try root()
        func pdf(_ name: String, pages: Int) throws -> URL {
            let url = root.appendingPathComponent(name)
            var box = CGRect(x: 0, y: 0, width: 500, height: 700)
            let context = try unwrap(CGContext(url as CFURL, mediaBox: &box, nil))
            for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
            context.closePDF()
            return url
        }
        let first = try pdf("first.pdf", pages: 1)
        let latest = try pdf("latest.pdf", pages: 3)
        // Deliberately occupy the main actor while the real loader opens a PDF.
        // Completion proves file parsing cannot be waiting for the UI executor.
        let completed = DispatchSemaphore(value: 0)
        let started = ContinuousClock.now
        let backgroundLoad = Task.detached {
            let value = try await StudyPDFDocumentLoader.shared.load(latest)
            completed.signal()
            return value
        }
        precondition(completed.wait(timeout: .now() + 2) == .success,
            "PDF file parsing must complete while the main actor is occupied")
        let parsed = try await backgroundLoad.value
        precondition(parsed.document?.pageCount == 3)
        print("PDF worker completed while main actor blocked in \(started.duration(to: .now))")
        let parent = StudyPDFReader(url: latest, page: .constant(2), selection: .constant(""),
            selectingFigure: .constant(false), zoom: 1, onFigure: { _ in })
        let coordinator = StudyPDFReader.Coordinator(parent)
        let host = StudyPDFHost()
        defer { coordinator.cancelDocumentLoad(); host.stopObservingEvents() }
        coordinator.host = host
        host.url = first
        coordinator.loadDocument(url: first, revision: "")
        expectNil(host.pdf.document, "Starting a read must return before PDF parsing")
        host.url = latest
        host.pendingPage = 2
        coordinator.loadDocument(url: latest, revision: "")
        for _ in 0..<100 where coordinator.loadingDocument { try await Task.sleep(for: .milliseconds(10)) }
        expectEqual(host.pdf.document?.pageCount, 3, "Only the latest requested PDF may reach the reader")
        expectEqual(host.pendingPage, 2, "Restore the requested page after layout obtains a usable size")
        expectFalse(coordinator.loadingDocument)

        coordinator.loadDocument(url: first, revision: "")
        coordinator.cancelDocumentLoad()
        await Task.yield()
        expectNil(host.pdf.document, "A dismantled reader must not receive a late PDF")
    }
}

private func expectEqual<T: Equatable>(_ actual: @autoclosure () throws -> T, _ expected: T, _ message: String = "") {
    do { let value = try actual(); precondition(value == expected, "\(message) Expected \(expected), got \(value)") }
    catch { preconditionFailure("\(message) Unexpected error: \(error)") }
}
private func expectNil<T>(_ value: T?, _ message: String = "") { precondition(value == nil, message) }
private func expectFalse(_ value: Bool, _ message: String = "") { precondition(!value, message) }
private func expectThrows<T>(_ expression: @autoclosure () throws -> T, _ message: String = "") {
    do { _ = try expression(); preconditionFailure(message) } catch { }
}
private func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw StudyError.message("Expected a non-nil value") }
    return value
}

@main @MainActor
struct ReaderPerformanceSmoke {
    static func main() async throws {
        let checks = ReaderPerformanceChecks()
        defer { checks.cleanup.forEach { $0() } }
        try checks.testWarmIndexesAvoidReadsAndAtomicReplacementWithSameSizeAndDateInvalidates()
        print("PASS: 100 warm index reads perform one decode; same-size atomic replacement and deletion invalidate")
        try checks.testCacheEvictsLeastRecentlyUsedIndexesAndDoesNotRetainOversizedFiles()
        print("PASS: bounded LRU and oversized-index eviction")
        try checks.testMemoryPressurePurgesIndexesAndSkipsRetentionUntilRecovery()
        try await checks.testPressureDuringDecodeDoesNotRefillPurgedCache()
        print("PASS: memory pressure releases cached indexes, preserves active readings, prevents late refill and recovers")
        try checks.testLargeIndexWarmReadBenchmark()
        try checks.testNewOCRSidecarOverridesPreviouslyCachedBaseIndex()
        print("PASS: new OCR sidecar takes precedence; corrupt sidecar safely falls back")
        try await checks.testConversationNavigationKeepsReadyIndexButContentRevisionReloads()
        print("PASS: same-reading conversation navigation stays ready; content revisions reload")
        try await checks.testPDFNavigationCancelsStaleLoadsAndKeepsLatestPendingPage()
        print("PASS: asynchronous PDF loading, rapid navigation cancellation and pending page restoration")
    }
}
