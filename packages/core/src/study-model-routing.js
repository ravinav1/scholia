// Classify locally so choosing a study model adds no network round trip.
// These are routing hints, not an assessment of the answer's correctness.
export const STUDY_MODEL_MODES = Object.freeze(['manual', 'auto', 'fast', 'deep']);

export function normalizeStudyModelMode(mode) {
  return STUDY_MODEL_MODES.includes(mode) ? mode : 'manual';
}

const tiers = {
  openai: {
    fast: ['gpt-6-luna', 'gpt-5-mini', 'gpt-4.1-mini'],
    balanced: ['gpt-6.1-sol', 'gpt-6-sol', 'gpt-5.5', 'gpt-5'],
    deep: ['gpt-6-astra', 'gpt-6.1-sol', 'gpt-6-sol', 'gpt-5.5', 'o3'],
  },
  codex: {
    fast: ['gpt-6-luna', 'gpt-5.6-luna', 'gpt-5.4-mini'],
    balanced: ['gpt-6.1-sol', 'gpt-6-sol', 'gpt-5.6-sol', 'gpt-5.5'],
    deep: ['gpt-6-astra', 'gpt-6.1-sol', 'gpt-6-sol', 'gpt-5.5'],
  },
  anthropic: {
    fast: ['claude-haiku-4-5-20251001', 'claude-sonnet-4-6'],
    balanced: ['claude-sonnet-4-6', 'claude-opus-4-8'],
    deep: ['claude-opus-4-8', 'claude-opus-4-7', 'claude-sonnet-4-6'],
  },
  claudecode: { fast: ['haiku', 'sonnet'], balanced: ['sonnet', 'opus'], deep: ['opus', 'sonnet'] },
};

const isContinuation = (text) => text.length < 180 && /^(?:why\b|how so\b|continue\b|go on\b|explain (?:that|this|it|the (?:last|next) step)\b|what (?:about|if)\b|and\b|try again\b|check (?:that|this|it)\b|that(?:'s| is) (?:wrong|incorrect)\b)/i.test(text);

export function classifyStudyQuestion({ question = '', previousQuestions = [], contextCharacters = 0 } = {}) {
  const current = String(question).trim();
  // A short continuation inherits the last problem; a new, simple question does not.
  const followup = isContinuation(current);
  const previous = previousQuestions.slice(-4).reverse().find((text) => !isContinuation(String(text).trim()))
    || previousQuestions.at(-1) || '';
  const text = (followup ? `${String(previous).slice(0, 12_000)}\n${current}` : current).slice(0, 16_000);
  if (/\b(?:prove|disprove|derive|derivation|counterexample|rigorous|rigorously)\b|\b(?:check|verify|critique|construct|write|give|find)\b[^.!?\n]{0,70}\bproof\b|\b(?:synthesi[sz]e|reconcile)\b|\b(?:compare|connect|integrate)\b[^.!?\n]{0,100}\b(?:readings|papers|sources|theories)\b/i.test(text)) {
    return { tier: 'deep', reason: 'Proof, derivation, or synthesis across sources' };
  }
  if (/\b(?:solve|calculate|compute|evaluate|debug|analy[sz]e|optimi[sz]e|integrate|differentiate)\b|\b(?:step.by.step|multi.step|worked example|check my (?:work|answer|solution)|compare|trade.?offs)\b/i.test(text)) {
    return { tier: 'balanced', reason: 'Worked problem or analysis' };
  }
  if (current.length > 3000 || contextCharacters > 80_000) {
    return { tier: 'balanced', reason: 'Long question or extensive source context' };
  }
  return { tier: 'fast', reason: 'Everyday explanation, recall, or summary' };
}

export function routeStudyModel({ mode = 'manual', providerID, selectedModel, reasoningEffort = null,
  availableModels = [], question = '', previousQuestions = [], contextCharacters = 0, hasImages = false } = {}) {
  mode = normalizeStudyModelMode(mode);
  const unchanged = (reason) => ({ mode, modelID: selectedModel, reasoningEffort, tier: 'manual', reason });
  if (mode === 'manual') return unchanged('Selected model');
  const choices = tiers[providerID];
  if (!choices) return unchanged('Automatic routing is unavailable for this provider; using your selected model');
  const classification = mode === 'auto'
    ? classifyStudyQuestion({ question, previousQuestions, contextCharacters })
    : { tier: mode, reason: mode === 'fast' ? 'Fast mode selected' : 'Deep mode selected' };
  const available = availableModels.map((model) => typeof model === 'string' ? { id: model } : model);
  const definition = choices[classification.tier].map((id) => available.find((model) => model.id === id))
    .find((model) => model && (!hasImages || model.supportsImages !== false));
  if (!definition) return unchanged('No suitable routing model is available; using your selected model');
  const efforts = definition.reasoning?.efforts || definition.reasoningEfforts || [];
  const preferred = { fast: 'low', balanced: 'medium', deep: 'high' }[classification.tier];
  const defaultEffort = definition.reasoning?.default || definition.defaultReasoningEffort;
  const effort = efforts.includes(preferred) ? preferred
    : efforts.includes(defaultEffort) ? defaultEffort : efforts[0] || null;
  return { mode, modelID: definition.id, reasoningEffort: effort, ...classification };
}

export function studyRouteDescription(route) {
  const label = { auto: 'Auto study', fast: 'Fast', deep: 'Deep', manual: 'Manual' }[route.mode];
  return `${label} · ${route.modelID}${route.reasoningEffort ? ` · ${route.reasoningEffort} reasoning` : ''} · ${route.reason}`;
}
