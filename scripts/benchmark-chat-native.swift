import Foundation
import Darwin
@testable import ScholiaMac

@main enum ChatBenchmark {
    struct Event: Codable { var seconds: Double; var message: String }
    struct Result: Codable {
        var arm: String; var startedAt: String; var elapsedSeconds: Double
        var model: String; var reasoningEffort: String; var usage: CompletionUsage?
        var firstAnswerTokenSeconds: Double?; var progress: [Event]; var error: String?
    }
    @MainActor static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
    @MainActor static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let output = URL(fileURLWithPath: env["CHAT_BENCHMARK_OUTPUT"]!)
        let corpus = output.appendingPathComponent("fixture/AttachmentText")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if CommandLine.arguments.contains("prepare") {
            let store = StudyLibraryStore(root: output.appendingPathComponent("fixture/Study"))
            let library = try store.load()
            let course = library.courses[0], document = course.documents[0], original = course.threads[0].messages[0]
            let started = Date()
            try AttachmentTextCorpusStore.$directoryOverride.withValue(corpus) {
                let retrieval = AttachmentContextRetrieval.prepare(messages: [original], question: original.content)
                let reading = try store.readingIndex(for: document)
                let pack = StudyContextBuilder.build(document: document, index: reading, currentPage: 1,
                    question: original.content, selection: "", course: course, store: store, includeCourse: false,
                    budget: StudyContextBuilder.requestBudget(original.content))
                let images = StudyContextBuilder.pageImages(document: document, pages: pack.imagePages, store: store)
                let messages = StudyContextBuilder.requestMessages(retrieval.messages, pack: pack, mode: .explain, images: images)
                try encoder.encode(messages).write(to: output.appendingPathComponent("prepared-messages.json"))
                try pack.text.write(to: output.appendingPathComponent("prepared-context.txt"), atomically: true, encoding: .utf8)
                let metadata: [String: Any] = ["preparationSeconds": Date().timeIntervalSince(started),
                    "contextSummary": pack.summary, "sourcePages": pack.sources.map(\.page), "imagePages": pack.imagePages,
                    "imageCount": images.count, "imageBytes": images.compactMap(\.imageData).reduce(0) { $0 + $1.count },
                    "originalAttachmentCharacters": retrieval.originalCharacters, "includedAttachmentCharacters": retrieval.includedCharacters,
                    "retrievalSummary": retrieval.summary as Any? ?? NSNull(), "initialUserMessages": 1, "assistantMessages": 0]
                try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("prepared-metadata.json"))
            }
            print("Prepared one immutable request snapshot."); return
        }
        let arm = env["CHAT_BENCHMARK_ARM"]!
        let messages = try JSONDecoder().decode([ConversationMessage].self, from: Data(contentsOf: output.appendingPathComponent("prepared-messages.json")))
        let effort = env["CHAT_BENCHMARK_EFFORT"] ?? "max"
        let config = ProviderConfiguration(provider: ProviderCatalog.provider(id: "codex"), model: "gpt-6-astra",
            endpoint: env["CHAT_BENCHMARK_ENDPOINT"]!, apiKey: env["CHAT_BENCHMARK_TOKEN"]!, language: .english,
            reasoningEffort: effort, fastClaudeMode: false, localFileAccess: LocalFileAccessPolicy(read: true, write: false))
        let start = Date(); var progress: [Event] = []; var first: Double?
        let folder = output.appendingPathComponent(arm)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let completion = try await AttachmentTextCorpusStore.$directoryOverride.withValue(corpus) {
                try await ProviderClient().complete(capture: nil, messages: messages, configuration: config,
                    onProgress: { value in
                        progress.append(Event(seconds: Date().timeIntervalSince(start), message: value))
                        print("\(arm) +\(Int(Date().timeIntervalSince(start)))s \(value)")
                        fflush(stdout)
                    }, onToken: { _ in if first == nil { first = Date().timeIntervalSince(start) } })
            }
            try completion.text.write(to: folder.appendingPathComponent("answer.md"), atomically: true, encoding: .utf8)
            if let reasoning = completion.reasoning {
                try reasoning.write(to: folder.appendingPathComponent("reasoning.txt"), atomically: true, encoding: .utf8)
            }
            try encoder.encode(Result(arm: arm, startedAt: start.ISO8601Format(), elapsedSeconds: Date().timeIntervalSince(start),
                model: completion.model, reasoningEffort: effort, usage: completion.usage, firstAnswerTokenSeconds: first,
                progress: progress)).write(to: folder.appendingPathComponent("native-result.json"))
            print("Completed \(arm) in \(Date().timeIntervalSince(start)) seconds.")
        } catch {
            try encoder.encode(Result(arm: arm, startedAt: start.ISO8601Format(), elapsedSeconds: Date().timeIntervalSince(start),
                model: config.model, reasoningEffort: effort, firstAnswerTokenSeconds: first,
                progress: progress, error: error.localizedDescription)).write(to: folder.appendingPathComponent("native-result.json"))
            throw error
        }
    }
}
