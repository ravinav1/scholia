import Foundation
@testable import ScholiaMac
// Isolated release measurement. --legacy reproduces the former full-JSON save;
// otherwise measure the current transactional store with the same fixture.
@main struct NativeStorageMeasurements {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-storage-baseline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = CommandLine.arguments.contains("--legacy")
        let output = CommandLine.arguments.dropFirst().first { $0 != "--legacy" }!
        var results: [[String: Any]] = []
        for count in [6, 89, 500] {
            var library = StudyLibrary()
            for index in 0..<count {
                var course = StudyCourse(name: "Workspace \(index)", code: "TEST\(index)")
                course.documents = (0..<20).map { StudyDocument(title: "Reading \($0)", kind: .text, fileName: "reading-\($0).txt", pageCount: 120) }
                course.canvasMaterials = (0..<70).map { CanvasMaterialReference(id: "files:\($0)", kind: .files, remoteID: "\($0)", title: "Reading \($0)", sourceURL: "https://fixture.invalid/\(index)/\($0)", version: "1") }
                library.courses.append(course)
            }
            var thread = StudyThread()
            thread.messages = (0..<200).map { ConversationMessage(role: $0 % 2 == 0 ? .user : .assistant, content: String(repeating: "Conversation content. ", count: 100)) }
            if count == 89 { thread.messages[0].imageData = Data(repeating: 65, count: 20_000_000) }
            library.courses[0].threads = [thread]
            let store = StudyLibraryStore(root: root.appendingPathComponent("\(count)"))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            func save(_ value: StudyLibrary) throws {
                if legacy {
                    try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
                    try encoder.encode(value).write(to: store.root.appendingPathComponent("library.json"), options: .atomic)
                } else { try store.save(value) }
            }
            try save(library)
            var times: [Double] = []
            var encoded: [Int] = [], rows: [Int] = []
            for page in 2...6 {
                library.courses[0].documents[0].lastPage = page
                let start = ContinuousClock.now
                try save(library)
                let elapsed = start.duration(to: .now).components
                times.append(Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
                encoded.append(legacy ? try Data(contentsOf: store.root.appendingPathComponent("library.json")).count : store.persistenceMetrics.encodedBytes)
                rows.append(legacy ? 1 : store.persistenceMetrics.writtenRows)
            }
            results.append(["courses": count, "documents": count * 20, "materials": count * 70,
                "messages": 200, "imageBytes": count == 89 ? 20_000_000 : 0,
                "operation": "single reading position change", "samplesMs": times,
                "encodedPayloadBytesPerSample": encoded,
                legacy ? "wholeFileReplacementsPerSample" : "writtenPayloadRowsPerSample": rows])
        }
        let report: [String: Any] = ["configuration": "release", "kind": legacy ? "native-full-json-storage-reproduction" : "native-targeted-storage",
            "buildID": ProcessInfo.processInfo.environment["SCHOLIA_BUILD_ID"] ?? "unrecorded",
            "bytes": "Encoded JSON payload bytes, not filesystem or SQLite WAL/page bytes",
            "rows": legacy ? "Whole library JSON replacements" : "Changed payload rows; excludes the separate transaction revision update",
            "recordedAt": ISO8601DateFormatter().string(from: Date()), "results": results]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
        print(String(data: data, encoding: .utf8)!)
    }
}
