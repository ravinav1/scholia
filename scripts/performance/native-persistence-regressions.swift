import Foundation
import Darwin
import SQLite3
@testable import ScholiaMac

@main struct NativePersistenceRegressions {
    static func fixture() -> StudyLibrary {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var first = StudyCourse(name: "First", code: "FIRST")
        first.canvasID = 1; first.canvasOrigin = "https://canvas.fixture.invalid"; first.canvasUserID = 7
        first.documents = (0..<3).map { StudyDocument(title: "Reading \($0)", kind: .text, fileName: "reading-\($0).txt", pageCount: 10, addedAt: date) }
        first.canvasMaterials = (0..<2).map { CanvasMaterialReference(id: "files:\($0)", kind: .files, remoteID: "\($0)", title: "File \($0)", sourceURL: "https://canvas.fixture.invalid/\($0)", version: "1") }
        first.threads = (0..<2).map { index in
            var thread = StudyThread(title: "Conversation \(index)")
            thread.updatedAt = date
            thread.messages = (0..<4).map { ConversationMessage(role: $0 % 2 == 0 ? .user : .assistant, content: "Message \($0)") }
            thread.messages[0].imageData = Data(repeating: UInt8(index), count: 40_000)
            return thread
        }
        var second = StudyCourse(name: "Second", code: "SECOND")
        second.canvasOrigin = "https://other-account.fixture.invalid"; second.canvasUserID = 8
        second.documents = [StudyDocument(title: "Other reading", kind: .text, fileName: "other.txt", pageCount: 4, addedAt: date)]
        second.canvasMaterials = []
        return StudyLibrary(courses: [first, second], selectedCourseID: first.id)
    }
    static func execute(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw StudyError.message("Could not open test database") }
        defer { sqlite3_close_v2(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StudyError.message(String(cString: sqlite3_errmsg(db))) }
    }
    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.first == "--concurrent-migration", arguments.count == 2 {
            let persistence = StudyLibraryPersistence(root: URL(fileURLWithPath: Array(arguments)[1]),
                migrationWillCommit: { Thread.sleep(forTimeInterval: 0.1) })
            _ = try persistence.load()
            return
        }
        if arguments.first == "--crash-transaction", arguments.count == 2 {
            let persistence = StudyLibraryPersistence(root: URL(fileURLWithPath: Array(arguments)[1]))
            var changed = try persistence.load()
            changed.courses[0].documents[0].lastPage = 9
            changed.courses[0].threads[0].draft = "Must not survive process exit"
            try persistence.save(changed, beforeCommit: { _exit(86) })
            throw StudyError.message("Crash injection did not execute")
        }
        if arguments.first == "--crash-migration", arguments.count == 2 {
            let persistence = StudyLibraryPersistence(root: URL(fileURLWithPath: Array(arguments)[1]),
                migrationWillCommit: { _exit(87) })
            _ = try persistence.load()
            throw StudyError.message("Migration crash injection did not execute")
        }
        if arguments.first == "--export", arguments.count == 3 {
            let args = Array(arguments)
            try StudyLibraryStore(root: URL(fileURLWithPath: args[1], isDirectory: true))
                .exportJSON(to: URL(fileURLWithPath: args[2]))
            print("Exported current library to \(args[2])")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-persistence-regressions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func require(_ result: @autoclosure () throws -> Bool, _ message: String) throws {
            if try !result() { throw StudyError.message("FAIL: \(message)") }
        }
        let original = fixture()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let legacyBytes = try encoder.encode(original) + Data([10])
        let source = root.appendingPathComponent("original-library.json")
        try legacyBytes.write(to: source)
        func crash(_ mode: String, at directory: URL, status: Int32) throws {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = [mode, directory.path]
            try child.run()
            child.waitUntilExit()
            try require(child.terminationReason == .exit && child.terminationStatus == status,
                "Child process must exit at the requested transaction checkpoint")
        }
        let crashMigrationRoot = root.appendingPathComponent("crash-migration")
        try FileManager.default.createDirectory(at: crashMigrationRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: crashMigrationRoot.appendingPathComponent("library.json"))
        try crash("--crash-migration", at: crashMigrationRoot, status: 87)
        try require(try StudyLibraryStore(root: crashMigrationRoot).load() == original,
            "Fresh process recovers from termination before migration commit")
        let crashRoot = root.appendingPathComponent("crash-transaction")
        try StudyLibraryStore(root: crashRoot).save(original)
        try crash("--crash-transaction", at: crashRoot, status: 86)
        let afterCrash = StudyLibraryStore(root: crashRoot)
        try require(try afterCrash.load() == original, "WAL recovery exposes only the last commit after _exit without rollback or deinit")
        var afterCrashState = original
        afterCrashState.courses[0].threads[0].draft = "Successful save after crash"
        try afterCrash.save(afterCrashState)
        try require(try StudyLibraryStore(root: crashRoot).load() == afterCrashState,
            "Saving after process-crash recovery remains usable")
        print("PASS actual child-process termination during migration and multi-row WAL transaction")
        let concurrentRoot = root.appendingPathComponent("concurrent-migration")
        try FileManager.default.createDirectory(at: concurrentRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: concurrentRoot.appendingPathComponent("library.json"))
        let initializers = (0..<2).map { _ -> Process in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["--concurrent-migration", concurrentRoot.path]
            return child
        }
        for child in initializers { try child.run() }
        for child in initializers {
            child.waitUntilExit()
            try require(child.terminationReason == .exit && child.terminationStatus == 0,
                "Concurrent first launches serialize backup publication and schema initialization")
        }
        try require(try StudyLibraryStore(root: concurrentRoot).load() == original,
            "Concurrent initialization preserves the entire legacy snapshot")
        print("PASS simultaneous first-launch migration")
        let migrationRoot = root.appendingPathComponent("migration")
        try FileManager.default.createDirectory(at: migrationRoot, withIntermediateDirectories: true)
        let legacy = migrationRoot.appendingPathComponent("library.json")
        try FileManager.default.copyItem(at: source, to: legacy)
        let interrupted = StudyLibraryPersistence(root: migrationRoot, migrationWillCommit: {
            throw StudyError.message("Injected migration interruption")
        })
        do { _ = try interrupted.load(); throw StudyError.message("FAIL: migration injection did not abort") }
        catch { try require(error.localizedDescription.contains("Injected migration interruption"), "Expected migration injection error") }
        try require(try Data(contentsOf: legacy) == legacyBytes, "Interrupted migration leaves original bytes unchanged")
        let store = StudyLibraryStore(root: migrationRoot)
        var state = try store.load()
        try require(state == original, "Retry after interrupted migration restores every field and child order")
        let backups = try FileManager.default.contentsOfDirectory(at: migrationRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("library-v1-backup-") }
        try require(backups.count == 1, "Repeated migration reuses one immutable backup")
        try require(try Data(contentsOf: backups[0]) == legacyBytes, "Backup is byte-identical to source")
        try require(try store.load() == original, "Repeated load does not migrate again")

        state.courses[0].documents[0].lastPage = 4
        try store.save(state)
        try require(store.persistenceMetrics.encodedRows == 1 && store.persistenceMetrics.writtenRows == 1,
            "Reading position encodes and writes exactly one document row")
        try require(store.persistenceMetrics.encodedBytes < 2_000, "Reading position does not re-encode chat images or catalogs")
        try store.save(state)
        try require(store.persistenceMetrics == StudyLibraryPersistence.Metrics(), "Unchanged save does no encoding, row writes or revision commit")
        state.courses[0].threads[0].messages[3].content = "Updated final message"
        try store.save(state)
        try require(store.persistenceMetrics.encodedRows == 1 && store.persistenceMetrics.writtenRows == 1,
            "Editing one message encodes and writes exactly its row")
        try require(store.persistenceMetrics.encodedBytes < 2_000, "Message update does not encode previous image messages")
        state.courses[0].threads[0].draft = "New composer draft"
        try store.save(state)
        try require(store.persistenceMetrics.encodedRows == 1 && store.persistenceMetrics.encodedBytes < 2_000,
            "Composer draft encodes only thread metadata")
        state.courses[0].name = "Renamed course"
        try store.save(state)
        try require(store.persistenceMetrics.encodedRows == 1 && store.persistenceMetrics.encodedBytes < 2_000,
            "Course rename excludes document, material and conversation payloads")
        state.showingCourseLibrary = true
        try store.save(state)
        try require(store.persistenceMetrics.encodedRows == 1, "Navigation updates only library metadata")
        state.courses[0].documents.swapAt(0, 2)
        try store.save(state)
        try require(store.persistenceMetrics.encodedRows == 0 && store.persistenceMetrics.reorderedRows == 2,
            "Document reorder only updates two positions")
        state.courses.swapAt(0, 1)
        try store.save(state)
        try require(store.persistenceMetrics.encodedRows == 0 && store.persistenceMetrics.reorderedRows == 2,
            "Course reorder preserves child payloads without encoding")
        try require(try StudyLibraryStore(root: migrationRoot).load() == state, "Restart restores exact changed content and ordering")
        try require(try Data(contentsOf: legacy) == legacyBytes, "Normal saves never rewrite legacy JSON")
        print("PASS interrupted/repeated migration, byte-identical backup, restart and targeted row work")

        let transaction = StudyLibraryPersistence(root: migrationRoot)
        var attempted = try transaction.load()
        attempted.courses[0].name = "Must roll back"
        attempted.courses[1].threads[0].messages[0].content = "Also roll back"
        do { try transaction.save(attempted, beforeCommit: { throw StudyError.message("Injected transaction interruption") })
            throw StudyError.message("FAIL: transaction injection did not abort") }
        catch { try require(error.localizedDescription.contains("Injected transaction interruption"), "Expected transaction injection error") }
        try require(try StudyLibraryStore(root: migrationRoot).load() == state, "Interrupted multi-row transaction exposes no partial save")
        try transaction.save(attempted)
        try require(try StudyLibraryStore(root: migrationRoot).load() == attempted, "Retry after rollback commits every changed row")
        state = attempted
        let stale = StudyLibraryPersistence(root: migrationRoot)
        var staleState = try stale.load()
        state.courses[0].name = "Winning process"
        try transaction.save(state)
        staleState.courses[0].name = "Stale process"
        do { try stale.save(staleState); throw StudyError.message("FAIL: stale writer overwrote current data") }
        catch { try require(error.localizedDescription.contains("another process"), "Stale session is rejected with a conflict") }
        let export = root.appendingPathComponent("export.json")
        try stale.exportJSON(to: export)
        try require(try JSONDecoder().decode(StudyLibrary.self, from: Data(contentsOf: export)) == state,
            "Portable export reflects the latest committed snapshot")
        do { try stale.save(staleState); throw StudyError.message("FAIL: export rebased a stale writer") }
        catch { try require(error.localizedDescription.contains("another process"), "Export cannot silently rebase a stale writer") }
        _ = try stale.load()
        var duplicate = state
        duplicate.courses[1].documents.append(duplicate.courses[1].documents[0])
        do { try stale.save(duplicate); throw StudyError.message("FAIL: duplicate row silently merged") }
        catch { try require(error.localizedDescription.contains("duplicate item identifiers"), "Duplicate IDs inside one owner are rejected") }
        try require(try StudyLibraryStore(root: migrationRoot).load() == state, "Invalid snapshot preserves the committed library")
        print("PASS transaction rollback/retry, conflict rejection, portable export and duplicate validation")

        var crossOwner = state
        crossOwner.courses[0].documents.append(crossOwner.courses[1].documents[0])
        crossOwner.courses[0].threads = [crossOwner.courses[1].threads[0]]
        try stale.save(crossOwner)
        try require(try StudyLibraryStore(root: migrationRoot).load() == crossOwner,
            "Legacy UUID reuse across different course owners is preserved without merging")
        crossOwner.courses.removeFirst()
        try stale.save(crossOwner)
        try require(try StudyLibraryStore(root: migrationRoot).load() == crossOwner, "Course deletion removes only its owned child rows")
        let isolated = StudyLibraryStore(root: root.appendingPathComponent("other-root"))
        try isolated.save(original)
        try require(try isolated.load() == original, "Another root retains independent accounts and matching UUIDs")
        try require(try StudyLibraryStore(root: migrationRoot).load() == crossOwner, "Saving another root cannot change the first root")
        let exportAlias = root.appendingPathComponent("active-database-alias.json")
        try FileManager.default.createSymbolicLink(at: exportAlias,
            withDestinationURL: migrationRoot.appendingPathComponent("library.sqlite"))
        do { try stale.exportJSON(to: exportAlias); throw StudyError.message("FAIL: export accepted an active database alias") }
        catch { try require(error.localizedDescription.contains("active SQLite"), "Export rejects symlink aliases to active database files") }
        try require(try StudyLibraryStore(root: migrationRoot).load() == crossOwner,
            "Rejected export preserves the current database")
        var streaming = original
        streaming.courses[0].threads[0].messages.append(ConversationMessage(role: .assistant, content: "Partial answer", isStreaming: true))
        streaming.courses[0].threads[0].messages.append(ConversationMessage(role: .assistant, content: "", isStreaming: true))
        let streamingStore = StudyLibraryStore(root: root.appendingPathComponent("streaming"))
        try streamingStore.save(streaming)
        let repaired = try StudyLibraryStore(root: streamingStore.root).load()
        try require(repaired.courses[0].threads[0].messages.count == streaming.courses[0].threads[0].messages.count - 1,
            "Public load still removes interrupted empty answers")
        try require(repaired.courses[0].threads[0].messages.last?.isStreaming == false
            && repaired.courses[0].threads[0].messages.last?.content == "Partial answer",
            "Public load preserves and marks interrupted partial answers")
        try execute(migrationRoot.appendingPathComponent("library.sqlite"), "PRAGMA user_version = 999")
        do { _ = try StudyLibraryStore(root: migrationRoot).load(); throw StudyError.message("FAIL: unsupported schema was accepted") }
        catch { try require(error.localizedDescription.contains("newer or unrecognized"), "Unsupported schema fails without stale JSON fallback") }
        do { try stale.save(crossOwner); throw StudyError.message("FAIL: open writer ignored changed schema") }
        catch { try require(error.localizedDescription.contains("newer or unrecognized"), "Already-open writer rejects a concurrent schema change") }
        print("PASS ownership preservation, cascade deletion, root isolation and schema guards")
        print("PASS native targeted persistence regressions")
    }
}
