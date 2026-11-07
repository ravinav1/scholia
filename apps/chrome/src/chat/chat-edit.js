const MAX_MESSAGE_CHARACTERS = 30_000;

export function prepareEditedResend(messages, messageIndex, rawQuestion) {
  const question = String(rawQuestion || '').trim().slice(0, MAX_MESSAGE_CHARACTERS);
  const entry = Array.isArray(messages) && Number.isInteger(messageIndex)
    ? messages[messageIndex]
    : null;
  if (!entry || entry.role !== 'user' || !question) return null;
  return {
    question,
    precedingMessages: messages.slice(0, messageIndex),
    attachment: entry.attachment || null,
    ...(entry.files?.length ? { files: entry.files } : {}),
    imageDataUrl: String(entry.imageDataUrl || '')
  };
}

export function replaceConversationPrefix(messages, prepared) {
  if (!Array.isArray(messages) || !prepared) return false;
  messages.splice(0, messages.length, ...prepared.precedingMessages);
  return true;
}
