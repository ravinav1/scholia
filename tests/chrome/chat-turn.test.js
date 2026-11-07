import test from 'node:test';
import assert from 'node:assert/strict';
import {
  canExplainImageDirectly,
  createUserTurn,
  DEFAULT_IMAGE_EXPLANATION,
  normalizeSelectionAttachment,
  normalizeTurnImageDataUrl,
  requestConversation,
  turnRequestContent
} from '../../apps/chrome/src/chat/chat-turn.js';

test('a fresh image capture can be explained without an added question', () => {
  const capture = { kind: 'image', imageDataUrl: 'data:image/png;base64,aGVsbG8=' };
  assert.equal(DEFAULT_IMAGE_EXPLANATION, 'Explain this image.');
  assert.equal(canExplainImageDirectly({ ...capture }), true);
  assert.equal(canExplainImageDirectly({ ...capture, question: '  Why?  ' }), false);
  assert.equal(canExplainImageDirectly({ ...capture, messageCount: 1 }), false);
  assert.equal(canExplainImageDirectly({ ...capture, hasAttachments: true }), false);
  assert.equal(canExplainImageDirectly({ kind: 'text', imageDataUrl: capture.imageDataUrl }), false);
  assert.equal(canExplainImageDirectly({ kind: 'image' }), false);
});

test('page and response selections become bounded, explicitly delimited turn context', () => {
  const attachment = normalizeSelectionAttachment({
    origin: 'response',
    text: '  A response\r\n\n\n excerpt  '
  });
  assert.deepEqual(attachment, {
    origin: 'response',
    text: 'A response\n\nexcerpt',
    label: 'Selected from a response',
    embedded: false,
    messageIndex: null
  });
  const content = turnRequestContent('Why?', attachment);
  assert.match(content, /Excerpt selected from an earlier assistant response/);
  assert.match(content, /<scholia-selection>\nA response\n\nexcerpt\n<\/scholia-selection>/);
  assert.match(content, /Question: Why\?/);
});

test('an attachment already embedded in the source stays visible without duplicating request context', () => {
  const turn = createUserTurn('Explain this.', {
    origin: 'page',
    text: 'selected page text',
    embedded: true
  });
  assert.equal(turn.content, 'Explain this.');
  assert.equal(turn.requestContent, 'Explain this.');
  assert.equal(turn.attachment.text, 'selected page text');
});

test('request conversations use model-facing turn content and omit errors', () => {
  const imageDataUrl = 'data:image/png;base64,aGVsbG8=';
  const turn = createUserTurn('Go deeper.', { origin: 'page', text: 'a selected claim' }, { imageDataUrl });
  assert.deepEqual(requestConversation([
    { role: 'user', content: 'First question' },
    { role: 'assistant', content: 'First answer' },
    turn,
    { role: 'assistant', content: 'Network failed', error: true }
  ]), [
    { role: 'user', content: 'First question' },
    { role: 'assistant', content: 'First answer' },
    { role: 'user', content: turn.requestContent, imageDataUrl }
  ]);
});

test('turn images are validated and stay attached to their own user message', () => {
  const imageDataUrl = 'data:image/jpeg;base64,aGVsbG8=';
  assert.equal(normalizeTurnImageDataUrl(imageDataUrl), imageDataUrl);
  assert.equal(normalizeTurnImageDataUrl('javascript:alert(1)'), '');
  assert.equal(normalizeTurnImageDataUrl('data:text/html;base64,aGVsbG8='), '');

  const turn = createUserTurn('Inspect this region.', null, { imageDataUrl });
  assert.equal(turn.imageDataUrl, imageDataUrl);
  assert.deepEqual(requestConversation([turn]), [{
    role: 'user',
    content: 'Inspect this region.',
    imageDataUrl
  }]);
});
