import test from 'node:test';
import assert from 'node:assert/strict';
import {
  matchingMessageIndexes,
  movedSearchIndex,
  searchRanges
} from '../../apps/chrome/src/chat/chat-search.js';

test('chat search finds user, assistant, attachment, and LaTeX source text', () => {
  const messages = [
    { role: 'user', content: 'Explain this', attachment: { text: 'Selected theorem' } },
    { role: 'assistant', content: 'The result is $a^2 + b^2 = c^2$.', reasoning: 'Compared both triangles.' },
    { role: 'user', content: 'What follows?' }
  ];

  assert.deepEqual(matchingMessageIndexes(messages, 'THEOREM'), [0]);
  assert.deepEqual(matchingMessageIndexes(messages, 'a^2 + b^2'), [1]);
  assert.deepEqual(matchingMessageIndexes(messages, 'triangles'), [1]);
  assert.deepEqual(matchingMessageIndexes(messages, 'what'), [2]);
  assert.deepEqual(matchingMessageIndexes(messages, '   '), []);
});

test('visible search ranges are case-insensitive and non-overlapping', () => {
  assert.deepEqual(searchRanges('Alpha alpha alphabet', 'ALPHA'), [
    { start: 0, end: 5 },
    { start: 6, end: 11 },
    { start: 12, end: 17 }
  ]);
  assert.deepEqual(searchRanges('aaaa', 'aa'), [
    { start: 0, end: 2 },
    { start: 2, end: 4 }
  ]);
});

test('search navigation wraps in both directions', () => {
  assert.equal(movedSearchIndex(-1, 3, 1), 0);
  assert.equal(movedSearchIndex(2, 3, 1), 0);
  assert.equal(movedSearchIndex(0, 3, -1), 2);
  assert.equal(movedSearchIndex(-1, 3, -1), 2);
  assert.equal(movedSearchIndex(0, 0, 1), -1);
});
