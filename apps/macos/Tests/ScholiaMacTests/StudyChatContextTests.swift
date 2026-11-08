import XCTest
@testable import ScholiaMac

final class StudyChatContextTests: XCTestCase {
    func testUnreadableAndPartialFilesReachProviderWithoutPretendingToBeRead() throws {
        let files = [
            MessageAttachment(fileName: "project.slx", mimeType: "application/zip", byteCount: 40,
                extractedText: "<Block Name=\"Controller\"><P Name=\"Gain\">Kp</P></Block>",
                readStatus: .partial, readDetail: "External workspace variable Kp is unavailable."),
            MessageAttachment(fileName: "measurements.mat", mimeType: "application/octet-stream", byteCount: 100,
                extractedText: "", readStatus: .unreadable, readDetail: "Export the variables to CSV or text."),
            MessageAttachment(fileName: "disabled.txt", mimeType: "text/plain", byteCount: 10,
                extractedText: "EXCLUDED_FILE_MARKER", isEnabled: false)
        ]
        let message = ConversationMessage(role: .user, content: "What is the controller gain?", attachments: files)
        let roundTrip = try JSONDecoder().decode(ConversationMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(roundTrip.attachments, files)
        let request = try PromptBuilder.prepare(messages: [roundTrip], capture: nil, languagePreference: .english)
        let text = request.messages[0].content
        XCTAssertTrue(text.contains("status=\"partial\""))
        XCTAssertTrue(text.contains("workspace variable Kp is unavailable"))
        XCTAssertTrue(text.contains("measurements.mat"))
        XCTAssertTrue(text.contains("contents could not be read"))
        XCTAssertFalse(text.contains("EXCLUDED_FILE_MARKER"))
        XCTAssertTrue(request.systemPrompt.contains("ask the user a focused question"))
        XCTAssertTrue(request.systemPrompt.contains("simulation results"))
    }

    func testBrowserAttachmentMetadataSurvivesRoundTripAndLimitsAreValidated() throws {
        let original = MessageAttachment(fileName: "plant.slx", mimeType: "application/zip", byteCount: 80,
            extractedText: "model source", readStatus: .partial, readDetail: "Dependency missing", isEnabled: false)
        let wire = try JSONDecoder().decode(StudyAttachmentTransfer.self, from: JSONEncoder().encode(StudyAttachmentTransfer(original)))
        let restored = try wire.attachment()
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.readStatus, .partial)
        XCTAssertEqual(restored.extractedText, "model source")
        XCTAssertFalse(restored.includedInContext)
        var oversized = wire
        oversized.text = String(repeating: "x", count: MessageAttachmentIngestion.maximumExtractedUTF16Units + 1)
        XCTAssertThrowsError(try oversized.attachment())
    }

    @MainActor
    func testAutomaticContextOffOmitsCourseAndMemoryButPreservesExplicitFilesAndSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let model = StudyWorkspaceModel(store: store)
        model.createCourse(name: "Kybintro", code: "TTK4100")
        let source = try StudyDocumentImporter.read(data: Data("COURSE_SECRET_493".utf8), name: "Compendium.txt", store: store)
        model.library.courses[0].documents = [source]
        model.library.courses[0].aiMemory = StudyAIMemory(notes: "MEMORY_SECRET_827", documentIDs: [source.id])
        model.automaticContextEnabled = false
        model.selectedText = "Explicit selected passage"
        model.draft = "Which project data do you need?"
        let file = MessageAttachment(fileName: "init.m", mimeType: "text/plain", byteCount: 8,
            extractedText: "Kp = 3;", readStatus: .complete)
        model.draftAttachments = [file]
        let owner = model.draftOwner
        model.draftAttachments[0].isEnabled = false
        XCTAssertNotEqual(model.draftOwner, owner)
        model.draftAttachments[0].isEnabled = nil
        let config = ProviderConfiguration(provider: ProviderCatalog.provider(id: "ollama"), model: "test",
            endpoint: "http://127.0.0.1:11434", apiKey: "", language: .english, fastClaudeMode: false)
        var observed = false
        model.submit(configuration: config) { messages, _, _ in
            observed = true
            let prepared = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english)
            let text = prepared.messages.map(\.content).joined(separator: "\n")
            XCTAssertTrue(text.contains("Kp = 3;"))
            XCTAssertTrue(text.contains("Explicit selected passage"))
            XCTAssertTrue(text.contains("Automatic course, assignment, document, and workspace-memory context is off"))
            XCTAssertFalse(text.contains("COURSE_SECRET_493"))
            XCTAssertFalse(text.contains("MEMORY_SECRET_827"))
            return CompletionResult(text: "Please attach the project model.", providerID: "test", providerName: "Test", model: "test")
        }
        for _ in 0..<200 where model.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(observed)
        XCTAssertFalse(model.isStreaming)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.messages.first?.attachments, [file])
        XCTAssertTrue(model.draftAttachments.isEmpty)
        XCTAssertTrue(model.contextSummary.contains("1 attached file"))
        XCTAssertTrue(model.thread?.sources.values.allSatisfy(\.isEmpty) == true)
        model.setAttachmentIncluded(file.id, included: false)
        model.flush()
        let restored = StudyWorkspaceModel(store: store)
        XCTAssertFalse(restored.automaticContextEnabled)
        XCTAssertFalse(try XCTUnwrap(restored.messages.first?.attachments?.first).includedInContext)
        restored.edit(try XCTUnwrap(restored.messages.first))
        XCTAssertEqual(restored.draftAttachments.first?.id, file.id)
        restored.cancelEdit()
        XCTAssertTrue(restored.draftAttachments.isEmpty)
    }
}
