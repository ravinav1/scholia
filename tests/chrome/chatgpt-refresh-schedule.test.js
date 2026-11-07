import test from 'node:test';
import assert from 'node:assert/strict';
import {
  CHATGPT_CONTEXT_REFRESH_ALARM,
  chatGptContextRefreshAlarmSchedule
} from '../../apps/chrome/src/chatgpt-refresh-schedule.js';

test('ChatGPT context refresh uses a recurring three-hour alarm', () => {
  const now = 10 * 60 * 60_000;
  const fetchedAt = now - 60 * 60_000;
  assert.equal(CHATGPT_CONTEXT_REFRESH_ALARM, 'scholia-chatgpt-context-refresh');
  assert.deepEqual(chatGptContextRefreshAlarmSchedule({
    quickChatRefreshInterval: '3h',
    memory: 'Prefers direct, technically precise answers.',
    fetchedAt
  }, now), {
    when: fetchedAt + 3 * 60 * 60_000,
    periodInMinutes: 180
  });
});

test('a missing or overdue snapshot schedules an immediate refresh', () => {
  const now = 10 * 60 * 60_000;
  assert.deepEqual(chatGptContextRefreshAlarmSchedule({
    quickChatRefreshInterval: '3h'
  }, now), {
    when: now + 1_000,
    periodInMinutes: 180
  });
  assert.equal(chatGptContextRefreshAlarmSchedule({
    quickChatRefreshInterval: 'off'
  }, now), null);
  assert.equal(chatGptContextRefreshAlarmSchedule({
    quickChatRefreshInterval: 'always'
  }, now), null);
});
