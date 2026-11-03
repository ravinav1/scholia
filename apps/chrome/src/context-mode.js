import { COMPACT_PACKED_CONTEXT_CHARS } from '../../../packages/core/src/context.js';

// Keep typical research articles intact, including dense 10–15 page PDFs.
export const FULL_CONTEXT_CHARS = 120_000;

export const CONTEXT_MODE_COMPACT = 'compact';
export const CONTEXT_MODE_FULL = 'full';
export const CONTEXT_MODE_NONE = 'none';

const CONTEXT_MODES = new Set([
  CONTEXT_MODE_COMPACT,
  CONTEXT_MODE_FULL,
  CONTEXT_MODE_NONE
]);

export function defaultContextMode(settings) {
  return settings?.includePageContext === false
    ? CONTEXT_MODE_FULL
    : CONTEXT_MODE_COMPACT;
}

export function normalizeContextMode(value, {
  legacyContextEnabled,
  fallback = CONTEXT_MODE_COMPACT
} = {}) {
  const candidate = String(value || '').trim().toLowerCase();
  if (CONTEXT_MODES.has(candidate)) return candidate;
  if (legacyContextEnabled === false) return CONTEXT_MODE_NONE;
  return CONTEXT_MODES.has(fallback) ? fallback : CONTEXT_MODE_COMPACT;
}

export function contextIsEnabled(mode) {
  return normalizeContextMode(mode) !== CONTEXT_MODE_NONE;
}

export function contextIsCompact(mode) {
  return normalizeContextMode(mode) === CONTEXT_MODE_COMPACT;
}

export function contextCharacterLimit(mode) {
  return contextIsCompact(mode)
    ? COMPACT_PACKED_CONTEXT_CHARS
    : FULL_CONTEXT_CHARS;
}
