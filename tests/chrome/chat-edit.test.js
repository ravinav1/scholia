import test from 'node:test';
import assert from 'node:assert/strict';
import {
  prepareEditedResend,
  replaceConversationPrefix
} from '../../apps/chrome/src/chat/chat-edit.js';

test('editing a user turn prepares its prior context and drops stale later turns', () => {
  const attachment = { origin: 'page', text: 'selected source' };
  const messages = [
    { role: 'user', content: 'First question' },
    { role: 'assistant', content: 'First answer' },
    { role: 'user', content: 'Old follow-up', attachment, imageDataUrl: 'data:image/png;base64,aGVsbG8=' },
    { role: 'assistant', content: 'Stale answer' },
    { role: 'user', content: 'Stale later question' }
  ];

  const prepared = prepareEditedResend(messages, 2, '  Better follow-up  ');
  assert.equal(prepared.question, 'Better follow-up');
  assert.equal(prepared.attachment, attachment);
  assert.equal(prepared.imageDataUrl, 'data:image/png;base64,aGVsbG8=');
  assert.deepEqual(prepared.precedingMessages, messages.slice(0, 2));

  assert.equal(replaceConversationPrefix(messages, prepared), true);
  assert.deepEqual(messages.map(({ role, content }) => ({ role, content })), [
    { role: 'user', content: 'First question' },
    { role: 'assistant', content: 'First answer' }
  ]);
});

test('editing rejects empty text and assistant turns', () => {
  const messages = [
    { role: 'user', content: 'Question' },
    { role: 'assistant', content: 'Answer' }
  ];
  assert.equal(prepareEditedResend(messages, 0, '   '), null);
  assert.equal(prepareEditedResend(messages, 1, 'Changed'), null);
  assert.equal(prepareEditedResend(messages, 99, 'Changed'), null);
});
