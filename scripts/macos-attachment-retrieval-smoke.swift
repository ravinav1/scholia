import Foundation
@testable import ScholiaMac

private func check(_ value: Bool, _ message: String) throws {
    if !value { throw NSError(domain: "AttachmentRetrievalSmoke", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main
struct AttachmentRetrievalSmoke {
    static func main() throws {
        let filler = (0..<130).map { "<Block Name=\"Display_\($0)\"><P Name=\"Description\">"
            + String(repeating: "display and logging configuration ", count: 30) + "</P></Block>" }
        let model = filler.prefix(90).joined(separator: "\n")
            + "\n<Block Name=\"ProportionalController\"><P Name=\"Gain\">Kp</P><P Name=\"IntegratorGain\">Ki</P></Block>\n"
            + filler.suffix(40).joined(separator: "\n")
        let file = MessageAttachment(fileName: "controller.slx", mimeType: "application/zip", byteCount: model.utf8.count,
            extractedText: model, readStatus: .partial, readDetail: "External motor model is unavailable.",
            sourcePath: "/tmp/controller.slx")
        let messages = [ConversationMessage(role: .user, content: "Read the model", attachments: [file]),
            ConversationMessage(role: .assistant, content: "Which block?"),
            ConversationMessage(role: .user, content: "What is Kp in ProportionalController?")]
        let cold = AttachmentContextRetrieval.prepare(messages: messages, question: messages.last!.content)
        let focused = cold.messages[0].attachments![0]
        try check(cold.retrievedFiles == 1, "Specific identifier must retrieve the large model")
        try check(cold.includedCharacters < cold.originalCharacters / 3, "Specific query should send less than one third of the model")
        try check(focused.extractedText.contains("ProportionalController"), "Target block was lost")
        try check(focused.extractedText.contains("extracted characters") && focused.extractedText.contains("passages are omitted"),
            "Retrieval must disclose its exact source ranges and omitted coverage")
        try check(focused.readDetail?.contains("External motor model is unavailable") == true,
            "Missing external-model warning was lost")
        try check(focused.sourcePath == file.sourcePath && focused.effectiveReadStatus == .partial,
            "Scoped source recovery and partial status must survive")
        try check(messages[0].attachments![0].extractedText == model, "Stored original was mutated")
        let followupMessages = messages + [ConversationMessage(role: .assistant, content: "Kp is the gain expression."),
            ConversationMessage(role: .user, content: "Why?")]
        let followup = AttachmentContextRetrieval.prepare(messages: followupMessages, question: "Why?")
        try check(followup.retrievedFiles == 1 && followup.includedCharacters < followup.originalCharacters / 3,
            "Vague follow-up must reuse the previous specific question, not send the whole model")
        try check(followup.messages[0].attachments![0].extractedText.contains("ProportionalController"),
            "Vague follow-up lost its previous controller evidence")
        let explicitPage = AttachmentContextRetrieval.prepare(messages: messages, question: "What is on page 90?")
        try check(explicitPage.messages[0].attachments?.first?.extractedText == file.extractedText, "Explicit page request must not match arbitrary numeric values")
        for question in ["Explain the complete project", "How do the blocks connect?", "Explain this model",
                         "Forstå hele prosjektet", "Why are oscillations occurring?"] {
            let full = AttachmentContextRetrieval.prepare(messages: messages, question: question)
            try check(full.retrievedFiles == 0 && full.messages[0].attachments?.first?.extractedText == file.extractedText,
                "Whole-project questions and vocabulary misses must retain full evidence: \(question)")
        }
        let manifest = "Project folder: Course project\n\nFILE MANIFEST\nplant.slx — partial\ninit.m — complete\nmeasurements.mat — UNREADABLE: export variables\n\nLIMITATIONS\nexternal_model.slx was not attached\n\nEXTRACTED CONTENT\n"
        var project = file
        project.fileName = "Project"
        project.extractedText = manifest + "--- File: plant.slx [partial] ---\n" + model
            + "\n\n--- File: init.m [complete] ---\nKp = 3; Ki = 0.5; motor_mass = 2;\n"
        let projectResult = AttachmentContextRetrieval.prepare(messages: [ConversationMessage(role: .user,
            content: "", attachments: [project])], question: "What is ProportionalController gain?")
        let projectText = projectResult.messages[0].attachments![0].extractedText
        try check(projectResult.retrievedFiles == 1 && projectText.contains(manifest), "Project manifest and limits must remain")
        try check(projectText.contains("Kp = 3; Ki = 0.5; motor_mass = 2;"), "Small parameter script must remain for cross-file dependencies")
        try check(projectText.contains("plant.slx · extracted characters"), "Project source member labels must remain")
        for question in ["What parts of the compendium is relevant for understanding the simulink diagram?",
                         "Hvilke deler av kompendiet er relevante for å forstå Simulink-diagrammet?"] {
            let mapping = AttachmentContextRetrieval.prepare(messages: [ConversationMessage(role: .user,
                content: question, attachments: [project])], question: question)
            try check(mapping.retrievedFiles == 0 && mapping.messages[0].attachments?.first?.extractedText == project.extractedText,
                "cross-source chapter mapping must preserve the complete supplied project structure and dependency script")
        }
        print("PASS compendium-to-project mapping preserves complete attached model structure")
        var changed = file
        changed.extractedText = model.replacingOccurrences(of: "Kp", with: "replacement_gain")
        let refreshed = AttachmentContextRetrieval.prepare(messages: [ConversationMessage(role: .user,
            content: "", attachments: [changed])], question: "What is replacement_gain?")
        try check(refreshed.messages[0].attachments![0].extractedText.contains("replacement_gain"), "Cache returned stale source text")
        var timings: [Double] = []
        for _ in 0..<20 {
            timings.append(AttachmentContextRetrieval.prepare(messages: messages, question: messages.last!.content).elapsedMilliseconds)
        }
        let median = timings.sorted()[timings.count / 2]
        try check(median < 250, "Warm retrieval is unexpectedly slow")
        print("ATTACHMENT_RETRIEVAL_BENCHMARK cold_ms=\(cold.elapsedMilliseconds) warm_median_ms=\(median) input_chars=\(cold.originalCharacters) sent_chars=\(cold.includedCharacters) strategy=cached_identifier_BM25 additional_original_source_reads=0")
        if let path = ProcessInfo.processInfo.environment["SCHOLIA_ATTACHMENT_MODEL_PATH"] {
            let real = try MessageAttachmentIngestion.read(fileAt: URL(fileURLWithPath: path))
            let realMessages = [ConversationMessage(role: .user, content: "", attachments: [real])]
            let measured = AttachmentContextRetrieval.prepare(messages: realMessages,
                question: "Which Gain parameters are saved in the controller blocks?")
            let full = AttachmentContextRetrieval.prepare(messages: realMessages, question: "Explain the complete project")
            try check(full.messages[0].attachments?.first?.extractedText == real.extractedText, "Actual project lost coverage for complete-project request")
            print("REAL_PROJECT_RETRIEVAL input_chars=\(measured.originalCharacters) sent_chars=\(measured.includedCharacters) retrieval_ms=\(measured.elapsedMilliseconds) focused_files=\(measured.retrievedFiles)")
        }
        print("PASS: specific-query retrieval, complete-project coverage, vocabulary fallback, source labels, dependency scripts, source revision cache, and bounded warm latency")
    }
}
