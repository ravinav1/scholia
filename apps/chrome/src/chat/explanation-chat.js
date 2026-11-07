import { saveChat } from './chat-history.js';
import { dedicatedChatUrl } from './chat-page.js';

// Persist before navigating so the destination can restore the whole explanation.
export async function openExplanationChat(explanation, browser = globalThis.chrome, { destination = 'tab' } = {}) {
  const chat = await saveChat({
    ...explanation,
    id: explanation?.id || crypto.randomUUID()
  }, browser.storage.local);
  const url = dedicatedChatUrl((path) => browser.runtime.getURL(path), chat?.id);
  if (!url) throw new Error('Send a message before moving this explanation to chat.');
  // The originating PDF opens its own embedded panel after this save completes.
  // Avoid global panel navigation, which can redirect chats in other PDF tabs.
  if (destination === 'pdf-sidebar') return { chatId: chat.id, surface: 'pdf-sidebar' };
  await browser.tabs.create({ url });
  return { chatId: chat.id };
}
