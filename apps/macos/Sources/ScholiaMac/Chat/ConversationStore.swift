import Foundation

struct StoredCapture: Codable, Equatable, Sendable {
    static let maximumImageBytes = 900_000

    var kind: CaptureKind
    var text: String?
    var imageData: Data?
    var imageMimeType: String?
    var applicationName: String?
    var windowTitle: String?
    var sourceURL: String?
    var context: String?
    var parentContext: String?
    var capturedAt: Date
    var imageWasOmitted: Bool

    init(capture: CapturedContent) {
        kind = capture.kind
        text = capture.text.map { TextInputPolicy.bounded($0) }
        if let data = capture.imageData, data.count <= Self.maximumImageBytes {
            imageData = data
            imageMimeType = capture.imageMimeType
            imageWasOmitted = false
        } else {
            imageData = nil
            imageMimeType = nil
            imageWasOmitted = capture.imageData != nil
        }
        applicationName = capture.applicationName.map { String($0.prefix(300)) }
        windowTitle = capture.windowTitle.map { String($0.prefix(500)) }
        sourceURL = capture.sourceURL.map { String($0.prefix(2_048)) }
        context = capture.context.map { String($0.prefix(PromptBuilder.maxSourceContextCharacters)) }
        parentContext = capture.parentContext.map { String($0.prefix(PromptBuilder.maxParentContextCharacters)) }
        capturedAt = capture.capturedAt
    }

    var restored: CapturedContent {
        CapturedContent(
            kind: kind,
            text: text ?? (imageWasOmitted ? "The original image was too large to retain in chat history." : nil),
            imageData: imageData,
            imageMimeType: imageMimeType,
            applicationName: applicationName,
            windowTitle: windowTitle,
            sourceURL: sourceURL,
            context: context,
            parentContext: parentContext,
            capturedAt: capturedAt
        )
    }
}

struct StoredConversation: Codable, Identifiable, Equatable, Sendable {
    static let maximumMessages = 40
    static let maximumMessageCharacters = 24_000
    static let maximumMessageImageBytes = ImageEncoding.maximumInputBytes

    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var capture: StoredCapture?
    var messages: [ConversationMessage]
    var contextEnabled: Bool?
    var compactContextEnabled: Bool?

    init(
        id: UUID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        capture: CapturedContent?,
        messages: [ConversationMessage],
        contextEnabled: Bool? = nil,
        compactContextEnabled: Bool? = nil
    ) {
        self.id = id
        self.title = TextInputPolicy.bounded(title, maximumUTF16Units: 90)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.updatedAt = max(createdAt, updatedAt)
        self.capture = capture.map(StoredCapture.init)
        self.messages = Self.sanitizedMessages(messages)
        self.contextEnabled = contextEnabled
        self.compactContextEnabled = compactContextEnabled
    }

    var restoredCapture: CapturedContent? { capture?.restored }

    static func sanitizedMessages(_ values: [ConversationMessage]) -> [ConversationMessage] {
        let candidates = PromptBuilder.retainingAttachments(
            from: values, in: Array(values.suffix(maximumMessages))
        )
        var retainedImages: [UUID: (data: Data, mimeType: String)] = [:]
        for message in candidates.reversed() {
            guard message.role == .user,
                  let data = message.imageData,
                  !data.isEmpty,
                  data.count <= maximumMessageImageBytes,
                  let mimeType = message.imageMimeType?.trimmingCharacters(in: .whitespacesAndNewlines),
                  mimeType.lowercased().hasPrefix("image/") else { continue }
            retainedImages[message.id] = (data, mimeType)
        }
        var retainedAttachments: [UUID: [MessageAttachment]] = [:]
        for message in candidates.reversed() {
            let sanitized = PromptBuilder.sanitizedAttachments(message.attachments, role: message.role)
            guard let sanitized, !sanitized.isEmpty else { continue }
            retainedAttachments[message.id] = sanitized
        }

        return candidates.compactMap { message in
            let content = TextInputPolicy.bounded(
                message.content,
                maximumUTF16Units: maximumMessageCharacters
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty || message.activity?.isEmpty == false else { return nil }
            let reasoning = message.role == .assistant
                ? message.reasoning.map {
                    TextInputPolicy.bounded(
                        $0,
                        maximumUTF16Units: maximumMessageCharacters
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                }.flatMap { $0.isEmpty ? nil : $0 }
                : nil
            return ConversationMessage(
                id: message.id,
                role: message.role,
                content: content,
                imageData: retainedImages[message.id]?.data,
                imageMimeType: retainedImages[message.id]?.mimeType,
                attachments: retainedAttachments[message.id],
                reasoning: reasoning,
                isStreaming: false,
                metadata: message.metadata.map { String($0.prefix(300)) },
                activity: message.activity.map { Array($0.suffix(80)).map {
                    ConversationActivity(id: $0.id, timestamp: $0.timestamp,
                        title: String($0.title.prefix(180)), detail: $0.detail.map { String($0.prefix(2_000)) })
                } },
                modelRouting: message.modelRouting,
                usage: message.role == .assistant ? message.usage : nil,
                responseDurationSeconds: message.role == .assistant ? message.responseDurationSeconds : nil
            )
        }
    }
}

/// Encoding image-heavy history and atomically replacing its file must not
/// block window navigation. Keep only the latest queued snapshot; serialize
/// clears with saves and finish outstanding writes before application exit.
final class ConversationHistoryWriter: @unchecked Sendable {
    private struct Snapshot {
        let conversations: [StoredConversation]
        let onError: @Sendable (String) -> Void
    }
    private let queue = DispatchQueue(label: "app.scholia.conversation-writer", qos: .utility)
    private let lock = NSLock()
    private let persist: @Sendable ([StoredConversation]) throws -> Void
    private var pending: Snapshot?
    private var running = false
    // Accessed only on queue.
    private var latestWriteError: Error?

    init(persist: @escaping @Sendable ([StoredConversation]) throws -> Void = { values in
        if values.isEmpty { try ConversationStore.clear() }
        else { try ConversationStore.save(values) }
    }) {
        self.persist = persist
    }

    func save(_ conversations: [StoredConversation], onError: @escaping @Sendable (String) -> Void = { _ in }) {
        lock.withLock {
            pending = Snapshot(conversations: conversations, onError: onError)
            guard !running else { return }
            running = true
            queue.async { [self] in
                while let snapshot = lock.withLock({ () -> Snapshot? in
                    guard let value = pending else { running = false; return nil }
                    pending = nil
                    return value
                }) {
                    do {
                        try autoreleasepool { try persist(snapshot.conversations) }
                        latestWriteError = nil
                    } catch {
                        latestWriteError = error
                        snapshot.onError(error.localizedDescription)
                    }
                }
            }
        }
    }

    func flush() throws {
        // save enqueues before returning, so this barrier cannot overtake an
        // earlier submission. Only lifecycle boundaries wait for I/O.
        try queue.sync {
            if let error = latestWriteError { throw error }
        }
    }
}

enum ConversationStore {
    static let maximumConversations = 24
    static let maximumEncodedBytes = 100_000_000

    static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root.appendingPathComponent("Scholia", isDirectory: true)
            .appendingPathComponent("chats.json", isDirectory: false)
    }

    static func load(from url: URL? = nil, fileManager: FileManager = .default) -> [StoredConversation] {
        guard let target = try? (url ?? defaultURL(fileManager: fileManager)),
              let data = try? Data(contentsOf: target),
              let decoded = try? JSONDecoder().decode([StoredConversation].self, from: data) else {
            return []
        }
        return normalized(decoded)
    }

    static func save(
        _ conversations: [StoredConversation],
        to url: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let target = try url ?? defaultURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var values = normalized(conversations)
        var data = try JSONEncoder().encode(values)
        while values.count > 1 && data.count > maximumEncodedBytes {
            values.removeLast()
            data = try JSONEncoder().encode(values)
        }
        try data.write(to: target, options: .atomic)
    }

    static func clear(at url: URL? = nil, fileManager: FileManager = .default) throws {
        let target = try url ?? defaultURL(fileManager: fileManager)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
    }

    static func normalized(_ conversations: [StoredConversation]) -> [StoredConversation] {
        var unique: [UUID: StoredConversation] = [:]
        for conversation in conversations where conversation.messages.contains(where: { $0.role == .user }) {
            let normalized = StoredConversation(
                id: conversation.id,
                title: conversation.title,
                createdAt: conversation.createdAt,
                updatedAt: conversation.updatedAt,
                capture: conversation.restoredCapture,
                messages: conversation.messages,
                contextEnabled: conversation.contextEnabled,
                compactContextEnabled: conversation.compactContextEnabled
            )
            if unique[conversation.id]?.updatedAt ?? .distantPast < normalized.updatedAt {
                unique[conversation.id] = normalized
            }
        }
        return unique.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(maximumConversations).map { $0 }
    }
}
