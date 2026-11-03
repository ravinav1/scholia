import XCTest
@testable import ScholiaMac

final class AttachmentContextRetrievalTests: XCTestCase {
    private func attachment(_ text: String, name: String = "controller.slx") -> MessageAttachment {
        MessageAttachment(fileName: name, mimeType: "application/zip", byteCount: text.utf8.count,
            extractedText: text, readStatus: .partial, readDetail: "External motor model is unavailable.",
            sourcePath: "/tmp/controller.slx")
    }
    private var longModel: String {
        let filler = (0..<130).map { "<Block Name=\"Unrelated_\($0)\"><P Name=\"Description\">" + String(repeating: "display and logging configuration ", count: 30) + "</P></Block>" }
        return filler.prefix(90).joined(separator: "\n")
            + "\n<Block Name=\"ProportionalController\"><P Name=\"Gain\">Kp</P><P Name=\"IntegratorGain\">Ki</P></Block>\n"
            + filler.suffix(40).joined(separator: "\n")
    }

    func testSpecificIdentifierRetrievalReducesTextAndKeepsReadingLimits() throws {
        let original = attachment(longModel)
        let messages = [ConversationMessage(role: .user, content: "Read the model", attachments: [original]),
                        ConversationMessage(role: .assistant, content: "Which block?"),
                        ConversationMessage(role: .user, content: "What is Kp in ProportionalController?")]
        let result = AttachmentContextRetrieval.prepare(messages: messages, question: messages.last!.content)
        let file = try XCTUnwrap(result.messages[0].attachments?.first)
        XCTAssertEqual(result.retrievedFiles, 1)
        XCTAssertLessThan(result.includedCharacters, result.originalCharacters / 3)
        XCTAssertTrue(file.extractedText.contains("ProportionalController"))
        XCTAssertTrue(file.extractedText.contains("extracted characters"))
        XCTAssertTrue(file.extractedText.contains("passages are omitted"))
        XCTAssertTrue(file.readDetail?.contains("External motor model is unavailable") == true)
        XCTAssertEqual(file.sourcePath, original.sourcePath)
        XCTAssertEqual(file.effectiveReadStatus, .partial)
        XCTAssertEqual(messages[0].attachments?.first?.extractedText, longModel)
    }

    func testVagueFollowupUsesPriorSpecificQuestionWithoutLosingFullProjectIntent() throws {
        let files = [attachment(longModel)]
        let messages = [ConversationMessage(role: .user, content: "What is Kp in ProportionalController?", attachments: files),
                        ConversationMessage(role: .assistant, content: "Kp is the gain expression."),
                        ConversationMessage(role: .user, content: "Why?")]
        let followup = AttachmentContextRetrieval.prepare(messages: messages, question: "Why?")
        XCTAssertEqual(followup.retrievedFiles, 1)
        XCTAssertTrue(followup.messages[0].attachments![0].extractedText.contains("ProportionalController"))
        XCTAssertLessThan(followup.includedCharacters, followup.originalCharacters / 3)
        let full = AttachmentContextRetrieval.prepare(messages: messages, question: "Explain the complete project")
        XCTAssertEqual(full.messages[0].attachments?.map(\.extractedText), files.map(\.extractedText))
        let page = AttachmentContextRetrieval.prepare(messages: messages, question: "What is on page 90?")
        XCTAssertEqual(page.messages[0].attachments?.map(\.extractedText), files.map(\.extractedText))
    }

    func testFullProjectAndVocabularyMissPreserveCompleteSuppliedEvidence() {
        let original = attachment(longModel)
        let messages = [ConversationMessage(role: .user, content: "", attachments: [original])]
        for question in ["Explain the complete project", "How do the blocks connect?", "Explain this model",
                         "Forstå hele prosjektet", "Why are oscillations occurring?"] {
            let result = AttachmentContextRetrieval.prepare(messages: messages, question: question)
            XCTAssertEqual(result.retrievedFiles, 0, question)
            XCTAssertEqual(result.messages[0].attachments?.first?.extractedText, original.extractedText, question)
        }
    }

    func testProjectRetrievalPreservesManifestMissingFilesAndSmallParameterScripts() throws {
        let manifest = "Project folder: Course project\n\nFILE MANIFEST\nplant.slx — partial\ninit.m — complete\nmeasurements.mat — UNREADABLE: export variables\n\nLIMITATIONS\nexternal_model.slx was not attached\n\nEXTRACTED CONTENT\n"
        let source = manifest + "--- File: plant.slx [partial] ---\n" + longModel
            + "\n\n--- File: init.m [complete] ---\nKp = 3; Ki = 0.5; motor_mass = 2;\n"
        let result = AttachmentContextRetrieval.prepare(messages: [ConversationMessage(role: .user,
            content: "", attachments: [attachment(source, name: "Project")])], question: "What is ProportionalController gain?")
        let text = try XCTUnwrap(result.messages[0].attachments?.first?.extractedText)
        XCTAssertEqual(result.retrievedFiles, 1)
        XCTAssertTrue(text.contains(manifest))
        XCTAssertTrue(text.contains("Kp = 3; Ki = 0.5; motor_mass = 2;"))
        XCTAssertTrue(text.contains("plant.slx · extracted characters"))
    }

    func testShortUnavailableAndDisabledAttachmentsAreUnchanged() {
        let short = attachment("Kp = 3", name: "init.m")
        let unreadable = MessageAttachment(fileName: "data.mat", mimeType: "application/octet-stream", byteCount: 100,
            extractedText: "", readStatus: .unreadable, readDetail: "Export variables")
        var excluded = attachment(longModel)
        excluded.isEnabled = false
        let files = [short, unreadable, excluded]
        let result = AttachmentContextRetrieval.prepare(messages: [ConversationMessage(role: .user,
            content: "", attachments: files)], question: "What is Kp?")
        XCTAssertEqual(result.messages[0].attachments?.map(\.extractedText), files.map(\.extractedText))
        XCTAssertEqual(result.retrievedFiles, 0)
    }

    func testCacheTracksTextChangesAndReportsMeasuredWarmLatency() throws {
        let original = attachment(longModel)
        let messages = [ConversationMessage(role: .user, content: "", attachments: [original])]
        let cold = AttachmentContextRetrieval.prepare(messages: messages, question: "What is Kp?")
        var timings: [Double] = []
        for _ in 0..<12 {
            timings.append(AttachmentContextRetrieval.prepare(messages: messages, question: "What is Kp?").elapsedMilliseconds)
        }
        var changed = original
        changed.extractedText = longModel.replacingOccurrences(of: "Kp", with: "replacement_gain")
        let refreshed = AttachmentContextRetrieval.prepare(messages: [ConversationMessage(role: .user,
            content: "", attachments: [changed])], question: "What is replacement_gain?")
        XCTAssertTrue(refreshed.messages[0].attachments![0].extractedText.contains("replacement_gain"))
        let sorted = timings.sorted()
        print("ATTACHMENT_RETRIEVAL_BENCHMARK cold_ms=\(cold.elapsedMilliseconds) warm_median_ms=\(sorted[sorted.count/2]) input_chars=\(cold.originalCharacters) sent_chars=\(cold.includedCharacters)")
        // A generous ceiling catches accidentally starting a process/model or
        // rescanning the filesystem; exact timing is reported rather than asserted.
        XCTAssertLessThan(sorted[sorted.count/2], 250)
        XCTAssertLessThan(cold.includedCharacters, cold.originalCharacters / 3)
    }
}
