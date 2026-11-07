import test from 'node:test';
import assert from 'node:assert/strict';
import {
  chatGptMemoryManageControlMatches,
  chatGptMemoryTextIsPending,
  chatGptMemoryTextIsPersonalizationPage,
  chatGptMemoryTextIsUsable,
  chatGptPersonalizationUrl,
  chatGptProjectIdentity,
  requestChatGptWebStateWithInjection,
  summarizeChatGptWebPage
} from '../../apps/chrome/src/chatgpt-web.js';

test('ChatGPT web state recognizes a signed-in composer and explicit selection', () => {
  const state = summarizeChatGptWebPage({
    url: 'https://chatgpt.com/',
    title: 'ChatGPT',
    selectedText: '  I prefer concise explanations.  ',
    hasComposer: true
  });
  assert.equal(state.supported, true);
  assert.equal(state.loggedIn, true);
  assert.equal(state.captureKind, 'selection');
  assert.equal(state.captureText, 'I prefer concise explanations.');
});

test('ChatGPT project identity keeps a safe project URL and title', () => {
  const project = chatGptProjectIdentity({
    url: 'https://chatgpt.com/g/g-p-abc123/research/project?temporary=secret',
    title: 'Research — ChatGPT',
    heading: 'Thesis research'
  });
  assert.deepEqual(project, {
    projectName: 'Thesis research',
    projectUrl: 'https://chatgpt.com/g/g-p-abc123/project'
  });
});

test('Personalization always opens from ChatGPT root instead of a fragile conversation route', () => {
  const conversation = 'https://chatgpt.com/g/g-p-6a6c8ced3eac819184955dd3d86cef87/c/6a7df83e-0134-83eb-89ac-a4778c2be20b#settings/Personalization';
  assert.deepEqual(chatGptProjectIdentity({ url: conversation, heading: 'Technical structure' }), {
    projectName: 'Technical structure',
    projectUrl: 'https://chatgpt.com/g/g-p-6a6c8ced3eac819184955dd3d86cef87/project'
  });
  assert.equal(
    chatGptPersonalizationUrl(conversation),
    'https://chatgpt.com/#settings/Personalization'
  );
});

test('a rendered memory manager takes precedence over a stale page selection', () => {
  const state = summarizeChatGptWebPage({
    url: 'https://chatgpt.com/#settings/Personalization',
    selectedText: 'Old selected chat text',
    memoryText: 'Prefers complete worked examples.',
    hasAccountMenu: true
  });
  assert.equal(state.captureKind, 'memory');
  assert.equal(state.captureText, 'Prefers complete worked examples.');
  assert.equal(state.memoryText, 'Prefers complete worked examples.');
});

test('memory generation placeholders are never treated as imported memory', () => {
  assert.equal(chatGptMemoryTextIsPending('Generating'), true);
  assert.equal(chatGptMemoryTextIsPending('Generating memory summary…'), true);
  assert.equal(chatGptMemoryTextIsPending('Genererer minnesammendrag…'), true);
  assert.equal(chatGptMemoryTextIsPending('Your memory summary is being generated. Please wait.'), true);
  assert.equal(chatGptMemoryTextIsPending('Prefers detailed mathematical notation.'), false);
});

test('the Personalization settings surface is never accepted as memory', () => {
  const personalization = `Personalization
Base style and tone
Set the style and tone of how ChatGPT responds to you. This doesn't impact ChatGPT's capabilities.
Candid
Characteristics
Suggested prompts
Custom instructions
Pet
Select pet
About you
Nickname
Occupation
Engineering student at University of Waterloo
Enable memory
View an overview of what ChatGPT has learned about you.
Manage
Record mode
Reference record history
Advanced`;

  assert.equal(chatGptMemoryTextIsPersonalizationPage(personalization), true);
  assert.equal(chatGptMemoryTextIsUsable(personalization), false);
  assert.equal(chatGptMemoryTextIsUsable('Prefers direct answers with complete derivations.'), true);
  const state = summarizeChatGptWebPage({
    url: 'https://chatgpt.com/#settings/Personalization',
    memoryText: personalization,
    hasAccountMenu: true
  });
  assert.equal(state.memoryText, '');
  assert.equal(state.captureKind, '');
});

test('the isolated Memory settings card is never accepted as memory', () => {
  const memoryCard = `Enable memory
Let ChatGPT personalize your experience based on your chats, files, and connected apps.
View an overview of what ChatGPT has learned about you.`;
  assert.equal(chatGptMemoryTextIsPersonalizationPage(memoryCard), true);
  assert.equal(chatGptMemoryTextIsUsable(memoryCard), false);
});

test('a bare Manage button is only accepted inside the Memory setting', () => {
  assert.equal(chatGptMemoryManageControlMatches({
    label: 'Manage',
    contextText: 'Enable memory\nView an overview of what ChatGPT has learned about you.\nManage'
  }), true);
  assert.equal(chatGptMemoryManageControlMatches({
    label: 'Manage',
    contextText: 'Subscription\nManage\nCancel plan'
  }), false);
  assert.equal(chatGptMemoryManageControlMatches({ label: 'Manage memories' }), true);
  assert.equal(chatGptMemoryManageControlMatches({
    label: '', testID: 'memory-toggle'
  }), false);
  assert.equal(chatGptMemoryManageControlMatches({
    label: '', testID: 'memory-manage-button'
  }), true);
});

test('ChatGPT web state does not claim a signed-out or unrelated page is connected', () => {
  assert.deepEqual(
    summarizeChatGptWebPage({ url: 'https://example.test/', hasComposer: true }),
    { supported: false, loggedIn: false }
  );
  assert.equal(summarizeChatGptWebPage({
    url: 'https://chatgpt.com/', hasComposer: true, hasLoginControl: true
  }).loggedIn, false);
});

test('an already-open ChatGPT tab receives the lightweight probe without a reload', async () => {
  let requests = 0;
  let injections = 0;
  const result = await requestChatGptWebStateWithInjection({
    request: async () => {
      requests += 1;
      if (requests === 1) return undefined;
      return { ok: true, value: { supported: true, loggedIn: true } };
    },
    inject: async () => { injections += 1; }
  });
  assert.equal(requests, 2);
  assert.equal(injections, 1);
  assert.equal(result.value.loggedIn, true);
});

test('a responding ChatGPT tab is not injected a second time', async () => {
  let injections = 0;
  const result = await requestChatGptWebStateWithInjection({
    request: async () => ({ ok: true, value: { supported: true, loggedIn: false } }),
    inject: async () => { injections += 1; }
  });
  assert.equal(injections, 0);
  assert.equal(result.value.supported, true);
});
