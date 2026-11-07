const CHAT_ID_PATTERN = /^[a-zA-Z0-9_-]{8,120}$/;

export function normalizedChatId(value) {
  const chatId = String(value || '').trim();
  return CHAT_ID_PATTERN.test(chatId) ? chatId : '';
}

export function dedicatedChatId(value) {
  try {
    return normalizedChatId(new URL(String(value || '')).searchParams.get('chat'));
  } catch {
    return '';
  }
}

export function dedicatedChatUrl(runtimeGetUrl, chatId) {
  const normalized = normalizedChatId(chatId);
  if (!normalized || typeof runtimeGetUrl !== 'function') return '';
  const url = new URL(runtimeGetUrl('chat.html'));
  url.searchParams.set('chat', normalized);
  return url.href;
}
