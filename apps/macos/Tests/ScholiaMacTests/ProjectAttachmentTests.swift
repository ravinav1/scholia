import Foundation
import XCTest
import zlib
@testable import ScholiaMac

final class ProjectAttachmentTests: XCTestCase {
    func testSLXPreservesBlocksConnectionsAndMissingBinaryEvidence() throws {
        let model = #"<Model><System><Block BlockType="Gain" Name="Controller" SID="3"><P Name="Gain">Kp</P></Block><Block BlockType="Reference" Name="Plant"><P Name="SourceBlock">external_library/Plant</P></Block><Line><P Name="Src">3#out:1</P><P Name="Dst">4#in:1</P></Line></System></Model>"#
        let data = zip([
            ("simulink/systems/system_root.xml", Data(model.utf8)),
            ("simulink/configSet0.xml", Data("<P Name=\"InitFcn\">load('calibration.mat')</P>".utf8)),
            ("calibration.mat", Data([0, 1, 2, 0, 255]))
        ])
        let attachment = try MessageAttachmentIngestion.read(data: data, fileName: "project.slx", mimeType: nil)
        XCTAssertEqual(attachment.effectiveReadStatus, .partial)
        XCTAssertTrue(attachment.extractedText.contains(model))
        XCTAssertTrue(attachment.extractedText.contains("calibration.mat — UNREADABLE"))
        XCTAssertTrue(attachment.readDetail?.contains("workspace") == true)
        XCTAssertTrue(attachment.readDetail?.contains("not a simulation") == true)
        XCTAssertTrue(attachment.readingLimitSummary?.contains("2 files fully read") == true)
        XCTAssertTrue(attachment.readingLimitSummary?.contains("1 unavailable") == true)
        XCTAssertTrue(attachment.readingLimitSummary?.contains("Static model; not simulated") == true)
        let prepared = try PromptBuilder.prepare(messages: [ConversationMessage(role: .user, content: "Derive the controller", attachments: [attachment])], capture: nil, languagePreference: .english)
        XCTAssertTrue(prepared.messages[0].content.contains("Kp"))
        XCTAssertTrue(prepared.messages[0].content.contains("UNREADABLE"))
        XCTAssertTrue(prepared.messages[0].content.contains("partial"))
    }

    func testUnknownTextUTF16AndBinaryFilesAreAllRetainedHonestly() throws {
        let unusual = try MessageAttachmentIngestion.read(data: Data("gain = 4.2".utf8), fileName: "settings.customformat", mimeType: nil)
        XCTAssertEqual(unusual.effectiveReadStatus, .complete)
        XCTAssertEqual(unusual.extractedText, "gain = 4.2")
        let unicode = try MessageAttachmentIngestion.read(data: Data([0xff, 0xfe]) + "Modell: æøå".data(using: .utf16LittleEndian)!, fileName: "model.mdl", mimeType: nil)
        XCTAssertEqual(unicode.extractedText, "Modell: æøå")
        let binary = try MessageAttachmentIngestion.read(data: Data([0, 0xff, 3, 0]), fileName: "experiment.proprietary", mimeType: nil)
        XCTAssertEqual(binary.effectiveReadStatus, .unreadable)
        XCTAssertTrue(binary.extractedText.isEmpty)
        XCTAssertTrue(binary.readDetail?.contains("cannot decode") == true)
        let prepared = try PromptBuilder.prepare(messages: [ConversationMessage(role: .user, content: "What does this prove?", attachments: [binary])], capture: nil, languagePreference: .english)
        XCTAssertTrue(prepared.messages[0].content.contains("experiment.proprietary"))
        XCTAssertTrue(prepared.messages[0].content.contains("unreadable"))
    }

    func testOfficeAndMATLABSourcesExtractWithoutExecuting() throws {
        let document = #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Course project evidence</w:t></w:r></w:p></w:body></w:document>"#
        let doc = try MessageAttachmentIngestion.read(data: zip([("word/document.xml", Data(document.utf8))]), fileName: "project.docx", mimeType: nil)
        XCTAssertEqual(doc.effectiveReadStatus, .partial)
        XCTAssertTrue(doc.extractedText.contains("Course project evidence"))
        let source = "Kp = 2;\nload('missing-workspace.mat');\n"
        let script = try MessageAttachmentIngestion.read(data: Data(source.utf8), fileName: "initialize.m", mimeType: nil)
        XCTAssertEqual(script.extractedText, source)
        XCTAssertTrue(script.readDetail?.contains("without execution") == true)
    }

    func testFolderIncludesReadableFilesAndReportsOmissionsWithoutFollowingLinks() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("Kp = 12;".utf8).write(to: project.appendingPathComponent("initialize.m"))
        try Data([0, 255, 0]).write(to: project.appendingPathComponent("workspace.mat"))
        let external = root.appendingPathComponent("outside.txt")
        try Data("DO NOT READ EXTERNAL SENTINEL".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("outside-link"), withDestinationURL: external)
        let attachment = try MessageAttachmentIngestion.read(fileAt: project)
        XCTAssertEqual(attachment.sourcePath, project.path)
        XCTAssertEqual(attachment.effectiveReadStatus, .partial)
        XCTAssertTrue(attachment.extractedText.contains("Kp = 12;"))
        XCTAssertTrue(attachment.extractedText.contains("workspace.mat — UNREADABLE"))
        XCTAssertTrue(attachment.extractedText.contains("symbolic link not followed"))
        XCTAssertFalse(attachment.extractedText.contains("DO NOT READ EXTERNAL SENTINEL"))
        XCTAssertTrue(attachment.readDetail?.contains("1 file fully read") == true)
        XCTAssertTrue(attachment.readingLimitSummary?.contains("1 unavailable") == true)
        XCTAssertTrue(attachment.readingDetailsText.contains("symbolic link not followed"))
    }

    func testSavedFolderSummaryUsesOnlyOuterManifestWithoutReadingOrMutatingSource() {
        let saved = MessageAttachment(fileName: "TTK4100", mimeType: "inode/directory", byteCount: 1,
            extractedText: """
            Project folder: TTK4100

            FILE MANIFEST
            parameters.m — complete
            gruppeprosjekt.slx — partial
            guide.js — partial (text budget)
            generated.html — NOT READ: Attachment text budget reached

            LIMITATIONS
            guide.js: text after the included excerpt was not read.

            EXTRACTED CONTENT
            --- File: gruppeprosjekt.slx [partial] — Static model evidence; not a simulation. ---
            Contents of gruppeprosjekt.slx

            FILE MANIFEST
            simulink/system.xml — complete
            thumbnail.png — UNREADABLE: image not included

            EXTRACTED CONTENT
            MODEL_BODY_SENTINEL
            """, readStatus: .partial, readDetail: "Visible project files were read recursively.",
            sourcePath: "/nonexistent/saved-project")
        let original = saved
        XCTAssertEqual(saved.readingLimitSummary, "Text limit reached · 1 file fully read · 2 partly read · 1 not read")
        XCTAssertTrue(saved.readingDetailsText.contains("generated.html — NOT READ"))
        XCTAssertTrue(saved.readingDetailsText.contains("not a simulation"))
        XCTAssertFalse(saved.readingDetailsText.contains("MODEL_BODY_SENTINEL"))
        XCTAssertEqual(saved, original)
    }

    func testNewProjectContinuesReadingAfterPreviewAndKeepsFullCorpus() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try AttachmentTextCorpusStore.$directoryOverride.withValue(root) {
            let result = try MessageAttachmentIngestion.read(data: zip([
                ("large.txt", Data(String(repeating: "source text ", count: 18_000).utf8)),
                ("later.txt", Data("LATER_FILE_SENTINEL".utf8))
            ]), fileName: "large.zip", mimeType: nil)
            XCTAssertEqual(result.effectiveReadStatus, .complete)
            XCTAssertNotNil(result.textCorpusID)
            XCTAssertFalse(result.extractedText.contains("LATER_FILE_SENTINEL"))
            let full = try AttachmentTextCorpusStore.text(for: result)
            XCTAssertTrue(full.contains("LATER_FILE_SENTINEL"))
            XCTAssertTrue(full.contains("later.txt — complete"))
            XCTAssertFalse(full.contains("Attachment text budget reached"))
            XCTAssertTrue(result.readDetail?.contains("2 files fully read") == true)
            XCTAssertFalse(result.readingDetailsText.contains("source text source text"))
        }
        let ordinary = MessageAttachment(fileName: "notes.txt", mimeType: "text/plain", byteCount: 20,
            extractedText: "FILE MANIFEST\nsecret.txt — UNREADABLE: no", readStatus: .partial, readDetail: "Only the opening passage is included.")
        XCTAssertEqual(ordinary.readingLimitSummary, ordinary.readDetail)
        XCTAssertFalse(ordinary.readingDetailsText.contains("secret.txt"))
    }

    func testCorruptUnsafeAndNestedArchivesHaveExplicitLimits() throws {
        let unsafe = try MessageAttachmentIngestion.read(data: zip([("../escape.txt", Data("not evidence".utf8))]), fileName: "unsafe.zip", mimeType: nil)
        XCTAssertEqual(unsafe.effectiveReadStatus, .unreadable)
        XCTAssertTrue(unsafe.extractedText.isEmpty)
        var corrupt = zip([("evidence.txt", Data("known evidence".utf8))])
        corrupt[30 + "evidence.txt".utf8.count] ^= 0xff
        let corrupted = try MessageAttachmentIngestion.read(data: corrupt, fileName: "corrupt.zip", mimeType: nil)
        XCTAssertTrue(corrupted.extractedText.contains("integrity check"))
        XCTAssertFalse(corrupted.extractedText.contains("known evidence"))
        var nested = Data("deep evidence".utf8)
        for index in 0..<5 { nested = zip([("nested-\(index).zip", nested)]) }
        let result = try MessageAttachmentIngestion.read(data: nested, fileName: "nested.zip", mimeType: nil)
        XCTAssertEqual(result.effectiveReadStatus, .partial)
        XCTAssertTrue(result.extractedText.contains("three-level"))
        XCTAssertFalse(result.extractedText.contains("deep evidence"))
    }

    func testLocalArchiveMemberCanReadBeyondAttachmentBudgetWithoutEnablingBinaryWrites() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("large.slx")
        try await AttachmentTextCorpusStore.$directoryOverride.withValue(root.appendingPathComponent("corpora")) {
        let xml = "<System>" + String(repeating: "x", count: 230_000) + "FINAL_MODEL_PARAMETER</System>"
        try zip([("simulink/systems/system_root.xml", Data(xml.utf8))]).write(to: url)
        let attachment = try MessageAttachmentIngestion.read(fileAt: url)
        XCTAssertEqual(attachment.effectiveReadStatus, .partial)
        XCTAssertFalse(attachment.extractedText.contains("FINAL_MODEL_PARAMETER"))
        XCTAssertTrue(try AttachmentTextCorpusStore.text(for: attachment).contains("FINAL_MODEL_PARAMETER"))
        let service = LocalFileTools(policy: LocalFileAccessPolicy(read: true), home: root)
        let result = try await service.execute(LocalFileToolCall(operation: "read", path: url.path, offset: 225_000, archiveMember: "simulink/systems/system_root.xml"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        XCTAssertTrue((json["text"] as? String)?.contains("FINAL_MODEL_PARAMETER") == true)
        XCTAssertEqual(json["editableText"] as? Bool, false)
        XCTAssertEqual(json["truncated"] as? Bool, false)
        }
    }

    func testMissingAndInvalidCorpusReferencesNeverFallBackToPreview() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try AttachmentTextCorpusStore.$directoryOverride.withValue(root) {
            var missing = MessageAttachment(fileName: "large.txt", mimeType: "text/plain", byteCount: 1,
                extractedText: "INCOMPLETE PREVIEW", textCorpusID: String(repeating: "a", count: 64), textCorpusUTF16Count: 300_000)
            XCTAssertThrowsError(try AttachmentTextCorpusStore.text(for: missing))
            missing.textCorpusID = "../../private-file"
            XCTAssertThrowsError(try AttachmentTextCorpusStore.text(for: missing))
        }
    }

    func testSameBasenameDifferentPathsKeepDistinctProvenanceAndCorpora() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try AttachmentTextCorpusStore.$directoryOverride.withValue(root.appendingPathComponent("corpora")) {
            var results: [MessageAttachment] = []
            for name in ["first", "second"] {
                let directory = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("ttk4100.slx")
                let xml = "<System>" + String(repeating: "x", count: 210_000) + "MODEL_SOURCE_\(name)</System>"
                try zip([("simulink/system.xml", Data(xml.utf8))]).write(to: url)
                let attachment = try MessageAttachmentIngestion.read(fileAt: url)
                XCTAssertEqual(attachment.fileName, "ttk4100.slx")
                XCTAssertEqual(attachment.sourcePath, url.path)
                XCTAssertTrue(try AttachmentTextCorpusStore.text(for: attachment).contains("MODEL_SOURCE_\(name)"))
                results.append(attachment)
            }
            XCTAssertNotEqual(results[0].textCorpusID, results[1].textCorpusID)
            XCTAssertNotEqual(results[0].sourcePath, results[1].sourcePath)
        }
    }

    func testUserProvidedSimulinkModelWhenExplicitlyConfigured() throws {
        guard let path = ProcessInfo.processInfo.environment["SCHOLIA_ATTACHMENT_MODEL_PATH"] else {
            throw XCTSkip("Set SCHOLIA_ATTACHMENT_MODEL_PATH for read-only validation against a real project model.")
        }
        let attachment = try MessageAttachmentIngestion.read(fileAt: URL(fileURLWithPath: path))
        XCTAssertEqual(attachment.effectiveReadStatus, .partial)
        XCTAssertTrue(attachment.extractedText.contains("<Block"))
        XCTAssertTrue(attachment.extractedText.contains("<Line"))
        XCTAssertTrue(attachment.extractedText.contains("simulink/"))
        XCTAssertEqual(attachment.sourcePath, path)
        print("Real Simulink attachment verified: \(attachment.byteCount) bytes, \(attachment.extractedText.utf16.count) extracted characters; \(attachment.readDetail ?? "")")
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-project-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func zip(_ files: [(String, Data)]) -> Data {
        var result = Data(), directory = Data()
        func number(_ value: UInt32, bytes: Int, to target: inout Data) {
            for offset in 0..<bytes { target.append(UInt8(truncatingIfNeeded: value >> (8 * offset))) }
        }
        for (name, data) in files {
            let nameData = Data(name.utf8), offset = UInt32(result.count)
            let crc = data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(data.count))) }
            for value in [UInt32(0x04034b50)] { number(value, bytes: 4, to: &result) }
            for value in [20, 0, 0, 0, 0] { number(UInt32(value), bytes: 2, to: &result) }
            for value in [crc, UInt32(data.count), UInt32(data.count)] { number(value, bytes: 4, to: &result) }
            number(UInt32(nameData.count), bytes: 2, to: &result); number(0, bytes: 2, to: &result)
            result += nameData; result += data
            number(0x02014b50, bytes: 4, to: &directory)
            for value in [20, 20, 0, 0, 0, 0] { number(UInt32(value), bytes: 2, to: &directory) }
            for value in [crc, UInt32(data.count), UInt32(data.count)] { number(value, bytes: 4, to: &directory) }
            for value in [UInt32(nameData.count), 0, 0, 0, 0] { number(value, bytes: 2, to: &directory) }
            number(0, bytes: 4, to: &directory); number(offset, bytes: 4, to: &directory)
            directory += nameData
        }
        let directoryOffset = UInt32(result.count)
        result += directory
        number(0x06054b50, bytes: 4, to: &result)
        number(0, bytes: 2, to: &result); number(0, bytes: 2, to: &result)
        number(UInt32(files.count), bytes: 2, to: &result); number(UInt32(files.count), bytes: 2, to: &result)
        number(UInt32(directory.count), bytes: 4, to: &result); number(directoryOffset, bytes: 4, to: &result)
        number(0, bytes: 2, to: &result)
        return result
    }
}
