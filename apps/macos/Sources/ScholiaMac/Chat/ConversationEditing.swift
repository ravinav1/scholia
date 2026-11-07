import Foundation

struct ConversationEditPreparation: Equatable, Sendable {
    var precedingMessages: [ConversationMessage]
    var question: String
    var imageData: Data?
    var imageMimeType: String?
    var attachments: [MessageAttachment]?
}

enum ConversationEditor {
    static let maximumMessageCharacters = TextInputPolicy.maximumMessageUTF16Units

    static func prepareResend(
        messages: [ConversationMessage],
        messageID: UUID,
        rawQuestion: String
    ) -> ConversationEditPreparation? {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              messages[index].role == .user else { return nil }
        guard let question = TextInputPolicy.preparedMessage(
            rawQuestion,
            maximumUTF16Units: maximumMessageCharacters
        ) else { return nil }
        return ConversationEditPreparation(
            precedingMessages: Array(messages[..<index]),
            question: question,
            imageData: messages[index].imageData,
            imageMimeType: messages[index].imageMimeType,
            attachments: messages[index].attachments
        )
    }
}
