import test from 'node:test';
import assert from 'node:assert/strict';
import {
  BRIDGE_LAUNCH_COOLDOWN_MS,
  bridgeLaunchDecision
} from '../../apps/chrome/src/bridge-launch.js';

test('local bridge launch guard allows one attempt and suppresses repeated scheme launches', () => {
  const first = bridgeLaunchDecision(null, 'opencode://start', 1_000);
  assert.equal(first.allowed, true);
  const repeated = bridgeLaunchDecision(first.state, 'opencode://start', 1_100);
  assert.equal(repeated.allowed, false);
  assert.equal(repeated.retryAfterMs, BRIDGE_LAUNCH_COOLDOWN_MS - 100);
  const later = bridgeLaunchDecision(first.state, 'opencode://start', 1_000 + BRIDGE_LAUNCH_COOLDOWN_MS);
  assert.equal(later.allowed, true);
});

test('local bridge launch guard treats a different provider URL as a separate attempt', () => {
  const opencode = bridgeLaunchDecision(null, 'opencode://start', 1_000);
  const codex = bridgeLaunchDecision(opencode.state, 'scholia-codex://start', 1_100);
  assert.equal(codex.allowed, true);
  assert.equal(bridgeLaunchDecision(codex.state, '', 1_200).allowed, false);
});
