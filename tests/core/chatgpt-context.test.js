import test from 'node:test';
import assert from 'node:assert/strict';
import {
  CHATGPT_QUICK_CHAT_REFRESH_INTERVALS,
  chatGptMemoryLooksLikePersonalizationPage,
  chatGptQuickChatRefreshIsDue,
  chatGptWebContextAvailable,
  formatChatGptWebContext,
  formatChatGptWebContextForPage,
  isChatGptWebUrl,
  MAX_CHATGPT_MEMORY_CONTEXT,
  normalizeChatGptWebContext,
  publicChatGptWebContext,
  safeChatGptWebUrl
} from '../../packages/core/src/chatgpt-context.js';

const PERSONALIZATION_PAGE_CAPTURE = `Personalization
Base style and tone
Set the style and tone of how ChatGPT responds to you. This doesn't impact ChatGPT's capabilities.
Candid
Characteristics
Choose additional customizations on top of your base style and tone.
Warm
Default
Suggested prompts
Custom instructions
Pet
Select pet
About you
Nickname
Occupation
Engineering student at University of Waterloo
More about you
Enable memory
Let ChatGPT personalize your experience based on your chats, files, and connected apps.
Manage
Record mode
Reference record history
Advanced`;

test('ChatGPT web context is bounded and strips URL query data', () => {
  const context = normalizeChatGptWebContext({
    enabled: true,
    memory: `  Likes concise answers.\n${'x'.repeat(MAX_CHATGPT_MEMORY_CONTEXT + 20)}`,
    projectName: '  Thesis project  ',
    projectUrl: 'https://chatgpt.com/g/g-p-private/project?token=secret#section',
    projectContext: 'Use the notation from chapter 3.',
    quickChatRefreshInterval: '12h',
    updatedAt: 1234.8,
    fetchedAt: 1200.9
  });
  assert.equal(context.enabled, true);
  assert.equal(context.autoUseOnChatGpt, true);
  assert.equal(context.quickChatRefreshInterval, '12h');
  assert.equal(context.memory.length, MAX_CHATGPT_MEMORY_CONTEXT);
  assert.equal(context.projectName, 'Thesis project');
  assert.equal(context.projectUrl, 'https://chatgpt.com/g/g-p-private/project');
  assert.equal(context.updatedAt, 1234);
  assert.equal(context.fetchedAt, 1200);
  assert.equal(chatGptWebContextAvailable(context), true);
});

test('legacy Personalization-page captures are deterministically removed from cached memory', () => {
  assert.equal(chatGptMemoryLooksLikePersonalizationPage(PERSONALIZATION_PAGE_CAPTURE), true);
  const context = normalizeChatGptWebContext({
    enabled: true,
    memory: PERSONALIZATION_PAGE_CAPTURE,
    fetchedAt: 1234,
    projectContext: 'Keep this valid project context.'
  });
  assert.equal(context.memory, '');
  assert.equal(context.fetchedAt, 0);
  assert.equal(context.projectContext, 'Keep this valid project context.');
  assert.equal(chatGptWebContextAvailable(context), true);
  assert.equal(chatGptQuickChatRefreshIsDue({
    ...context,
    quickChatRefreshInterval: '3h'
  }, 1234), true);
  assert.doesNotMatch(formatChatGptWebContext(context), /Base style and tone/);
});

test('an isolated Memory settings card is rejected like the full Personalization page', () => {
  const card = `Enable memory
Let ChatGPT personalize your experience based on your chats, files, and connected apps.
View an overview of what ChatGPT has learned about you.
Manage`;
  assert.equal(chatGptMemoryLooksLikePersonalizationPage(card), true);
  assert.equal(normalizeChatGptWebContext({ memory: card, fetchedAt: 1234 }).memory, '');
  assert.equal(normalizeChatGptWebContext({ memory: card, fetchedAt: 1234 }).fetchedAt, 0);
});

test('ordinary memories containing isolated settings words are retained', () => {
  const memory = 'The user likes advanced calculus and keeps a pet dog.';
  assert.equal(chatGptMemoryLooksLikePersonalizationPage(memory), false);
  assert.equal(normalizeChatGptWebContext({ memory }).memory, memory);
});

test('only official ChatGPT web origins are accepted', () => {
  assert.equal(isChatGptWebUrl('https://chatgpt.com/'), true);
  assert.equal(isChatGptWebUrl('https://chat.openai.com/c/abc'), true);
  assert.equal(isChatGptWebUrl('https://chatgpt.com.evil.test/'), false);
  assert.equal(isChatGptWebUrl('http://chatgpt.com/'), false);
  assert.equal(safeChatGptWebUrl('https://example.test/'), '');
});

test('public ChatGPT settings expose availability but not imported text', () => {
  const context = normalizeChatGptWebContext({
    enabled: true,
    quickChatRefreshInterval: '3h',
    memory: 'Private preference',
    projectName: 'Research',
    projectContext: 'Private project material'
  });
  const visible = publicChatGptWebContext(context);
  assert.deepEqual(visible, {
    enabled: true,
    autoUseOnChatGpt: true,
    quickChatRefreshInterval: '3h',
    available: true,
    hasMemory: true,
    hasProject: true,
    projectName: 'Research',
    updatedAt: 0,
    fetchedAt: 0
  });
  assert.equal('memory' in visible, false);
  assert.equal('projectContext' in visible, false);
  assert.match(formatChatGptWebContext(context), /ChatGPT memory snapshot:\nPrivate preference/);
  assert.match(formatChatGptWebContext(context), /ChatGPT project snapshot — Research:/);
});

test('Quick Chat refresh intervals use the last successful website fetch', () => {
  const threeHours = 3 * 60 * 60_000;
  const fetchedAt = 1_000_000;
  assert.deepEqual(
    CHATGPT_QUICK_CHAT_REFRESH_INTERVALS.map(({ id }) => id),
    ['off', 'always', '3h', '12h', '1d', '3d', '7d']
  );
  assert.equal(chatGptQuickChatRefreshIsDue({ quickChatRefreshInterval: 'off' }, fetchedAt + threeHours), false);
  const fetchedMemory = { memory: 'Current memory snapshot.', fetchedAt };
  assert.equal(chatGptQuickChatRefreshIsDue({ ...fetchedMemory, quickChatRefreshInterval: 'always' }, fetchedAt), true);
  assert.equal(chatGptQuickChatRefreshIsDue({ ...fetchedMemory, quickChatRefreshInterval: '3h' }, fetchedAt + threeHours - 1), false);
  assert.equal(chatGptQuickChatRefreshIsDue({ ...fetchedMemory, quickChatRefreshInterval: '3h' }, fetchedAt + threeHours), true);
  assert.equal(chatGptQuickChatRefreshIsDue({ quickChatRefreshInterval: '1d', fetchedAt: 0 }, fetchedAt), true);
});

test('automatic ChatGPT-site context includes only the matching project', () => {
  const context = normalizeChatGptWebContext({
    autoUseOnChatGpt: true,
    memory: 'Global memory.',
    projectName: 'Study project',
    projectUrl: 'https://chatgpt.com/g/g-p-study/project',
    projectContext: 'Use the project glossary.'
  });
  const matching = formatChatGptWebContextForPage(
    context,
    'https://chatgpt.com/g/g-p-study/c/conversation-id'
  );
  assert.match(matching, /Global memory/);
  assert.match(matching, /Use the project glossary/);

  const unrelated = formatChatGptWebContextForPage(
    context,
    'https://chatgpt.com/g/g-p-unrelated/c/other-id'
  );
  assert.match(unrelated, /Global memory/);
  assert.doesNotMatch(unrelated, /Use the project glossary/);
  assert.equal(formatChatGptWebContextForPage(context, 'https://example.test/'), '');
  assert.equal(formatChatGptWebContextForPage({ ...context, autoUseOnChatGpt: false }, 'https://chatgpt.com/'), '');
});
