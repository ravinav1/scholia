import test from 'node:test';
import assert from 'node:assert/strict';
import {
  chatGptContextAfterMemoryRefresh,
  chatGptQuickChatRefreshDecision
} from '../../apps/chrome/src/chatgpt-refresh.js';

test('Quick Chat refresh decision distinguishes disabled, fresh, stale, and forced snapshots', () => {
  const now = 20 * 60 * 60_000;
  assert.deepEqual(
    chatGptQuickChatRefreshDecision({ quickChatRefreshInterval: 'off' }, { now }),
    {
      context: {
        enabled: false,
        autoUseOnChatGpt: true,
        quickChatRefreshInterval: 'off',
        memory: '',
        projectName: '',
        projectUrl: '',
        projectContext: '',
        updatedAt: 0,
        fetchedAt: 0
      },
      enabled: false,
      due: false
    }
  );
  assert.equal(chatGptQuickChatRefreshDecision({
    quickChatRefreshInterval: '12h', fetchedAt: now - 60_000, memory: 'Cached'
  }, { now }).due, false);
  assert.equal(chatGptQuickChatRefreshDecision({
    quickChatRefreshInterval: '12h', fetchedAt: now - 13 * 60 * 60_000, memory: 'Cached'
  }, { now }).due, true);
  assert.equal(chatGptQuickChatRefreshDecision({
    quickChatRefreshInterval: 'off'
  }, { now, force: true }).due, true);
});

test('a successful background memory refresh preserves policy and project context', () => {
  const next = chatGptContextAfterMemoryRefresh({
    enabled: true,
    autoUseOnChatGpt: false,
    quickChatRefreshInterval: '3d',
    memory: 'Old memory',
    projectName: 'Research',
    projectUrl: 'https://chatgpt.com/g/g-p-research/project',
    projectContext: 'Keep the project glossary.'
  }, {
    memoryText: 'Fresh rendered memory',
    projectName: '',
    projectUrl: ''
  }, 42_000);

  assert.equal(next.memory, 'Fresh rendered memory');
  assert.equal(next.quickChatRefreshInterval, '3d');
  assert.equal(next.autoUseOnChatGpt, false);
  assert.equal(next.projectName, 'Research');
  assert.equal(next.projectContext, 'Keep the project glossary.');
  assert.equal(next.updatedAt, 42_000);
  assert.equal(next.fetchedAt, 42_000);
});

test('an empty rendered memory refresh is rejected without replacing the cache', () => {
  assert.throws(
    () => chatGptContextAfterMemoryRefresh({ memory: 'Keep me' }, { memoryText: '   ' }),
    /did not expose a valid rendered memory summary/
  );
});

test('a Personalization-page capture is rejected without replacing the cache', () => {
  assert.throws(
    () => chatGptContextAfterMemoryRefresh({ memory: 'Keep me' }, {
      memoryText: 'Personalization\nBase style and tone\nCharacteristics\nCustom instructions\nAbout you\nEnable memory\nManage'
    }),
    /did not expose a valid rendered memory summary/
  );
});
