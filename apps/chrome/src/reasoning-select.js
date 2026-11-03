import { modelReasoning } from '../../../packages/core/src/providers.js';
import { selectedModel } from './model-select.js';

const effortLabels = { none: 'None', minimal: 'Minimal', low: 'Low', medium: 'Medium', high: 'High', xhigh: 'Extra high', max: 'Max', ultra: 'Ultra' };

export function populateReasoningSelect(select, settings, { disabled = false } = {}) {
  const { provider, model } = selectedModel(settings);
  const reasoning = modelReasoning(provider, model, settings);
  select.closest('[data-reasoning-control]').hidden = !reasoning;
  select.disabled = disabled || !reasoning;
  select.replaceChildren();
  if (!reasoning) return;

  const saved = settings?.reasoningEfforts?.[provider];
  const current = reasoning.efforts.includes(saved) ? saved : reasoning.default;
  for (const effort of reasoning.efforts) {
    const option = select.ownerDocument.createElement('option');
    option.value = effort;
    option.textContent = effortLabels[effort] || effort;
    option.selected = effort === current;
    select.append(option);
  }
  select.title = `Reasoning for the next message: ${effortLabels[current] || current}`;
}
