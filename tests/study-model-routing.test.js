import test from 'node:test';
import assert from 'node:assert/strict';
import { PROVIDERS } from '../packages/core/src/providers.js';
import { classifyStudyQuestion, routeStudyModel } from '../packages/core/src/study-model-routing.js';

const models = PROVIDERS.find((provider) => provider.id === 'openai').models;
const route = (options = {}) => routeStudyModel({
  mode: 'auto', providerID: 'openai', selectedModel: 'gpt-5-mini', availableModels: models, ...options,
});

test('study routing balances quick recall, worked problems, and demanding reasoning', () => {
  for (const question of ['What is entropy?', 'Summarize this lecture', 'Make ten flashcards', 'When is the assignment due?', 'What is a mathematical proof?']) {
    assert.equal(route({ question }).modelID, 'gpt-6-luna', question);
    assert.equal(route({ question }).reasoningEffort, 'low');
  }
  for (const question of ['Solve this system of equations', 'Check my solution', 'Compare mitosis and meiosis', 'Optimize this function']) {
    assert.equal(route({ question }).modelID, 'gpt-6.1-sol', question);
  }
  for (const question of ['Prove that sqrt(2) is irrational', 'Derive the wave equation', 'Compare the conflicting theories across these papers']) {
    assert.equal(route({ question }).modelID, 'gpt-6-astra', question);
    assert.equal(route({ question }).reasoningEffort, 'high');
  }
});

test('a followup keeps problem context while a new simple question returns to fast', () => {
  const previousQuestions = ['Prove that sqrt(2) is irrational'];
  assert.equal(route({ question: 'Why does that follow?', previousQuestions }).tier, 'deep');
  assert.equal(route({ question: 'Explain the next step', previousQuestions }).tier, 'deep');
  assert.equal(route({ question: 'Continue', previousQuestions: [...previousQuestions, 'Why does that follow?'] }).tier, 'deep');
  assert.equal(route({ question: 'Define a rational number', previousQuestions }).tier, 'fast');
  assert.equal(classifyStudyQuestion({ question: 'Review this', contextCharacters: 90_000 }).tier, 'balanced');
});

test('manual and explicit mode choices take precedence over classification', () => {
  assert.equal(route({ mode: 'manual', question: 'Prove this', reasoningEffort: 'high' }).modelID, 'gpt-5-mini');
  assert.equal(route({ mode: 'manual', reasoningEffort: 'high' }).reasoningEffort, 'high');
  assert.equal(route({ mode: 'fast', question: 'Prove this' }).modelID, 'gpt-6-luna');
  assert.equal(route({ mode: 'deep', question: 'Define a vector' }).modelID, 'gpt-6-astra');
  assert.equal(route({ mode: 'invalid' }).modelID, 'gpt-5-mini');
});

test('routing stays within the provider catalog, supports fallback, and respects image capability', () => {
  const unavailable = route({ availableModels: [] });
  assert.equal(unavailable.modelID, 'gpt-5-mini');
  assert.match(unavailable.reason, /No suitable/);
  const unknown = route({ providerID: 'custom', selectedModel: 'private-model' });
  assert.equal(unknown.modelID, 'private-model');
  assert.match(unknown.reason, /unavailable for this provider/);
  assert.equal(route({ question: 'Calculate this', availableModels: ['gpt-6-sol'] }).modelID, 'gpt-6-sol');
  const image = route({ hasImages: true, availableModels: [{ id: 'gpt-6-luna', supportsImages: false }, 'gpt-5-mini'] });
  assert.equal(image.modelID, 'gpt-5-mini');
  assert.equal(image.reasoningEffort, null);
  assert.equal(route({ providerID: 'anthropic', availableModels: PROVIDERS.find((p) => p.id === 'anthropic').models }).modelID, 'claude-haiku-4-5-20251001');
});
