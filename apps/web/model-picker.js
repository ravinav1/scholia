import { sortModelChoices } from '../../packages/core/src/providers.js';
import { recentModelChoices } from '../../packages/core/src/recent-models.js';
import { escapeHtml as esc } from '../chrome/src/html-escape.js';

export function studyModelPickerMarkup(models, providerID, modelID) {
  const recent = recentModelChoices(models);
  const recentSet = new Set(recent);
  const groups = new Map();
  for (const model of models) {
    if (recentSet.has(model)) continue;
    if (!groups.has(model.provider)) groups.set(model.provider, []);
    groups.get(model.provider).push(model);
  }
  const option = (model, includeProvider = false) => `<option value="${esc(JSON.stringify([model.providerID, model.id]))}"${model.id === modelID && model.providerID === providerID ? ' selected' : ''}>${esc(includeProvider ? `${model.label} · ${model.provider}` : model.label)}</option>`;
  return (recent.length ? `<optgroup label="Recently used">${recent.map((model) => option(model, true)).join('')}</optgroup>` : '')
    + [...groups].map(([provider, choices]) => `<optgroup label="${esc(provider)}">${sortModelChoices(choices).map((model) => option(model)).join('')}</optgroup>`).join('');
}
