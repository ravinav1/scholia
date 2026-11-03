export const RECENT_MODELS_KEY = 'scholia.recentModels.v1';
export const MAX_RECENT_MODELS = 12;
export const MAX_VISIBLE_RECENT_MODELS = 8;

export function normalizeRecentModels(value, now = Date.now() / 1000) {
  const seen = new Set();
  return (Array.isArray(value) ? value : [])
    .filter((item) => item && typeof item.providerID === 'string' && item.providerID.trim()
      && item.providerID.length <= 100 && typeof item.modelID === 'string' && item.modelID.trim()
      && item.modelID.length <= 200 && Number.isFinite(item.lastUsedAt)
      && item.lastUsedAt > 0 && item.lastUsedAt <= now + 300)
    .map(({ providerID, modelID, lastUsedAt }) => ({ providerID: providerID.trim(), modelID: modelID.trim(), lastUsedAt }))
    .sort((a, b) => b.lastUsedAt - a.lastUsedAt)
    .filter((item) => {
      const key = JSON.stringify([item.providerID, item.modelID]);
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    }).slice(0, MAX_RECENT_MODELS);
}

export function recordRecentModel(records, providerID, modelID, lastUsedAt = Date.now() / 1000) {
  return normalizeRecentModels([{ providerID, modelID, lastUsedAt }, ...normalizeRecentModels(records)
    .filter((item) => item.providerID !== providerID || item.modelID !== modelID)]);
}

// Models already passed the surface's availability/verification filter.
export function recentModelChoices(models, limit = MAX_VISIBLE_RECENT_MODELS) {
  const records = normalizeRecentModels(models.map((model) => ({ ...model, modelID: model.id })));
  return records.slice(0, limit).map((record) => models.find((model) =>
    model.providerID === record.providerID && model.id === record.modelID));
}
