import test from 'node:test';
import assert from 'node:assert/strict';
import {
  dedicatedChatId,
  dedicatedChatUrl,
  normalizedChatId
} from '../../apps/chrome/src/chat/chat-page.js';

test('dedicated chat URLs retain only a validated local chat id', () => {
  const chatId = '12345678-abcd_EFGH';
  const url = dedicatedChatUrl(
    (path) => `chrome-extension://abcdefghijklmnop/${path}`,
    chatId
  );
  assert.equal(url, `chrome-extension://abcdefghijklmnop/chat.html?chat=${chatId}`);
  assert.equal(dedicatedChatId(url), chatId);
});

test('dedicated chat routing rejects missing and unsafe ids', () => {
  assert.equal(normalizedChatId('short'), '');
  assert.equal(normalizedChatId('../options.html'), '');
  assert.equal(dedicatedChatUrl((path) => `chrome-extension://id/${path}`, '../bad'), '');
  assert.equal(dedicatedChatId('chrome-extension://id/chat.html?chat=%2E%2E%2Fbad'), '');
});
