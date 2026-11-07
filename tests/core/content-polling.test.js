import test from 'node:test';
import assert from 'node:assert/strict';
import { contentPollAttempt, contentPollDecision, contentPollRate, contentPollSnapshot, newContentPollingModel, observeContentPoll } from '../../packages/core/src/content-polling.js';
import { pollingFixtures as fixtures, trainedPollingModel } from '../helpers/content-polling.js';

const seconds = value => Date.parse(value) / 1000;
const observe = (model, time, signature, complete = true) => observeContentPoll(model, { time, signature, complete, interval: 300 });
const decision = (model, time, lastRegular = model.attemptedAt, options = {}) =>
  contentPollDecision(model, { time, interval: 300, lastRegular, ...options });

test('cold start and first import keep only regular checks; no requests train the model', () => {
  const model = newContentPollingModel(), time = seconds(fixtures.daily.predict);
  assert.equal(decision(model, time), 'regular');
  contentPollAttempt(model, time, 'regular');
  observe(model, time, 'all imported files');
  assert.deepEqual(model.bins, {});
  assert.equal(decision(model, time + 150), null);
  assert.equal(decision(model, time + 300), 'regular');
  observe(model, time + 86400, 'offline backlog');
  assert.deepEqual(model.bins, {}, 'Offline catch-up cannot timestamp a publication');
});

test('replayed daily and weekly publishing patterns trigger bounded intermediate checks', () => {
  for (const fixture of Object.values(fixtures)) {
    const { model, time } = trainedPollingModel(fixture);
    assert.ok(contentPollRate(model, time) >= 0.5);
    assert.equal(decision(model, time + 149), null);
    assert.equal(decision(model, time + 150), 'predicted');
    contentPollAttempt(model, time + 150, 'predicted');
    assert.equal(decision(model, time + 151, time), null);
    assert.equal(decision(model, time + 300, time), 'regular', 'Prediction must not postpone the regular cadence');
    const persisted = JSON.parse(JSON.stringify(model));
    assert.equal(decision(persisted, time + 450, time + 300), null, 'Restart must retain the hourly cooldown');
    assert.equal(model.extraChecks.length, 1);
  }
  const weekly = trainedPollingModel(fixtures.weekly);
  const tuesday = weekly.time + 86400;
  observe(weekly.model, tuesday, weekly.model.signature);
  assert.equal(contentPollRate(weekly.model, tuesday), 0, 'Monday evidence must not invent a Tuesday pattern');
});

test('learning is independent of polling frequency, respects Oslo DST and needs repeated days', () => {
  const slow = trainedPollingModel(), fast = trainedPollingModel(fixtures.daily, 60);
  assert.ok(Math.abs(contentPollRate(slow.model, slow.time) - contentPollRate(fast.model, fast.time)) < 0.001);
  const short = trainedPollingModel({ ...fixtures.daily, days: 2 });
  assert.equal(contentPollRate(short.model, short.time), 0);
  const dst = trainedPollingModel({ ...fixtures.daily, start: '2026-10-21T00:00:00Z', weekdays: [3, 4, 5], predict: '2026-10-26T13:00:00Z' }, 300, 'Europe/Oslo');
  assert.ok(contentPollRate(dst.model, dst.time) >= 0.5, 'Local publishing hour survives the DST transition');
  observe(dst.model, dst.time + 84 * 86400, dst.model.signature);
  assert.equal(contentPollRate(dst.model, dst.time + 84 * 86400), 0, 'Old semesters must not keep generating predictions');
});

test('budgets are rolling, persisted, shared across sources and never suppress regular checks', () => {
  const { model, time } = trainedPollingModel();
  const workspaceExtras = Array.from({ length: 8 }, (_, i) => time - 3600 - i);
  assert.equal(decision(model, time + 150, time, { workspaceExtras }), null);
  assert.equal(decision(model, time + 300, time, { workspaceExtras }), 'regular');
  model.extraChecks = [time - 7200, time - 3600];
  assert.equal(decision(model, time + 150, time), null);
  model.extraChecks = [time - 86401, time - 3600];
  assert.equal(decision(model, time + 150, time), 'predicted');
  model.extraChecks = [time + 86400, time + 86401];
  assert.equal(decision(model, time + 150, time), null, 'Clock rollback must not refill a budget');
});

test('partial results do not train; repeated failures back off and a successful baseline recovers', () => {
  const { model, time } = trainedPollingModel(), bins = structuredClone(model.bins);
  observe(model, time + 300, 'partial or error', false);
  assert.deepEqual(model.bins, bins);
  assert.equal(decision(model, time + 450), null);
  assert.equal(decision(model, time + 600), 'regular');
  observe(model, time + 600, '', false);
  assert.equal(decision(model, time + 900), null);
  assert.equal(decision(model, time + 1200), 'regular');
  observe(model, time + 1200, 'new baseline');
  assert.equal(model.failures, 0);
  assert.equal(model.retryAfter, undefined);
  assert.ok(Object.values(model.bins).reduce((sum, b) => sum + b.events, 0) < 3.01);
});

test('content fingerprints separate sources and ignore grades and synthetic validators', () => {
  const refs = [
    { id: 'assignments:1', title: 'Problem set', version: 'v1', assignment: { score: 0 } },
    { id: 'math-wiki:notes', title: 'Notes', version: 'unvalidated:1', byteCount: 123 },
    { id: 'course-web:notes', title: 'Notes', version: 'v1' },
  ];
  const before = ['canvas', 'mathWiki'].map(source => contentPollSnapshot(refs, source));
  refs[0].assignment.score = 100; refs[1].version = 'unvalidated:2'; refs[2].version = 'v2';
  assert.deepEqual(['canvas', 'mathWiki'].map(source => contentPollSnapshot(refs, source)), before);
  refs[1].byteCount++;
  assert.equal(contentPollSnapshot(refs, 'canvas'), before[0]);
  assert.notEqual(contentPollSnapshot(refs, 'mathWiki'), before[1]);
  refs[0].version = 'v2';
  assert.notEqual(contentPollSnapshot(refs, 'canvas'), before[0]);
});
