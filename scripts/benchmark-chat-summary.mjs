#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
const output = path.join(path.dirname(path.dirname(fileURLToPath(import.meta.url))), 'output/chat-benchmark');
const read = name => JSON.parse(fs.readFileSync(path.join(output, name)));
const plan = read('run-plan.json');
const canonical = value => Array.isArray(value) ? value.map(canonical)
  : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
const digest = value => createHash('sha256').update(JSON.stringify(canonical(value))).digest('hex');
const rows = [];
for (const arm of plan.order) {
  const folder = path.join(output, arm);
  if (!fs.existsSync(folder)) continue;
  const rounds = fs.readdirSync(folder).filter(n => n.endsWith('-metrics.json')).sort().map(n => read(`${arm}/${n}`));
  const result = fs.existsSync(path.join(folder, 'native-result.json')) ? read(`${arm}/native-result.json`) : {};
  const recovery = fs.existsSync(path.join(folder, 'recovery.json')) ? read(`${arm}/recovery.json`) : null;
  const before = fs.existsSync(path.join(folder, 'quota-before.json')) ? read(`${arm}/quota-before.json`) : {};
  const afterFile = recovery ? 'recovery-quota-after.json' : 'quota-after.json';
  const after = fs.existsSync(path.join(folder, afterFile)) ? read(`${arm}/${afterFile}`) : {};
  const initial = fs.existsSync(path.join(folder, 'round-01-native-request.json')) ? read(`${arm}/round-01-native-request.json`) : {};
  const initialNormalized = { ...initial }; delete initialNormalized.reasoning_effort;
  const sum = key => rounds.length && rounds.every(r => typeof r.usage?.[key] === 'number')
    ? rounds.reduce((n, r) => n + r.usage[key], 0) : null;
  const cached = rounds.length && rounds.every(r => typeof r.usage?.prompt_tokens_details?.cached_tokens === 'number')
    ? rounds.reduce((n, r) => n + r.usage.prompt_tokens_details.cached_tokens, 0) : null;
  const beforeUsed = before.data?.rateLimits?.primary?.usedPercent;
  const afterUsed = after.data?.rateLimits?.primary?.usedPercent;
  let sourceOperationsSucceeded = 0, sourceOperationsRejected = 0, sourceOperationsUnconfirmed = 0;
  const sourceErrors = [];
  for (const round of rounds.filter(round => round.tool)) {
    const nextFile = `${arm}/round-${String(round.index + 1).padStart(2, '0')}-native-request.json`;
    if (!fs.existsSync(path.join(output, nextFile))) { sourceOperationsUnconfirmed += round.expandedOperations; continue; }
    const content = read(nextFile).messages.at(-1)?.content;
    try {
      if (typeof content !== 'string' || !content.startsWith('Scholia file-operation result')) throw new Error('No source result yet');
      const result = JSON.parse(content.slice(content.indexOf('\n') + 1));
      if (result.error) {
        sourceOperationsRejected += round.expandedOperations;
        sourceErrors.push({ round: round.index, operation: round.tool.operation, error: result.error });
      } else if (Array.isArray(result.results)) {
        for (const item of result.results) {
          if (item.status === 'ok') sourceOperationsSucceeded++;
          else { sourceOperationsRejected++; sourceErrors.push({ round: round.index, operation: item.operation, status: item.status, error: item.error }); }
        }
      } else sourceOperationsSucceeded++;
    } catch { sourceOperationsUnconfirmed += round.expandedOperations; }
  }
  const hasAnswer = fs.existsSync(path.join(folder, 'answer.md'));
  rows.push({ arm, complete: !!result.elapsedSeconds && !result.error && hasAnswer, attempted: !!initial.model,
    failed: !!result.error && !recovery, recovered: !!recovery, recovery,
    model: result.model || initial.model,
    reasoningEffort: result.reasoningEffort || initial.reasoning_effort,
    elapsedSeconds: recovery ? null : result.elapsedSeconds,
    reconstructedElapsedSeconds: recovery?.reconstructedElapsedSeconds ?? null,
    providerSeconds: rounds.reduce((n, r) => n + (r.providerSeconds || 0), 0),
    modelRequests: rounds.length, sourceRounds: rounds.filter(r => r.tool).length,
    sourceOperations: rounds.reduce((n, r) => n + r.expandedOperations, 0),
    sourceOperationsSucceeded, sourceOperationsRejected, sourceOperationsUnconfirmed, sourceErrors,
    batchRounds: rounds.filter(r => r.tool?.requests).length,
    inputTokens: sum('prompt_tokens'), cachedInputTokens: cached,
    uncachedInputTokens: sum('prompt_tokens') !== null && cached !== null ? sum('prompt_tokens') - cached : null,
    outputTokens: sum('completion_tokens'), totalTokens: sum('total_tokens'),
    tokenCoverage: recovery ? 'Successful completed rounds only; abandoned interrupted call token usage is unavailable.' : 'All completed provider rounds.',
    answerCharacters: hasAnswer ? fs.readFileSync(path.join(folder, 'answer.md'), 'utf8').length : null,
    quotaUsedBefore: beforeUsed, quotaUsedAfter: afterUsed,
    observedSharedQuotaPercentagePoints: typeof afterUsed === 'number' && typeof beforeUsed === 'number' ? afterUsed - beforeUsed : null,
    initialNativeBodyWithoutEffortSHA256: digest(initialNormalized), nativeUsage: result.usage, error: result.error,
    operations: rounds.filter(r => r.tool).map(r => r.tool) });
}
const recordedErrors = fs.existsSync(path.join(output, 'violations.jsonl')) ? fs.readFileSync(path.join(output, 'violations.jsonl'), 'utf8').trim().split('\n').map(JSON.parse) : [];
const harnessErrors = recordedErrors.filter(error => error.error === 'fetch failed');
const violations = recordedErrors.filter(error => error.error !== 'fetch failed');
const summary = { generatedAt: new Date().toISOString(), plan, prepared: read('prepared-metadata.json'),
  initialNativeBodiesMatchExceptEffort: new Set(rows.filter(r => r.model).map(r => r.initialNativeBodyWithoutEffortSHA256)).size <= 1,
  cliInvocations: fs.existsSync(path.join(output, 'cli-invocations.jsonl')) ? fs.readFileSync(path.join(output, 'cli-invocations.jsonl'), 'utf8').trim().split('\n').map(JSON.parse) : [],
  violations, harnessErrors, rows };
fs.writeFileSync(path.join(output, 'summary.json'), JSON.stringify(summary, null, 2) + '\n');
console.log(JSON.stringify({ complete: rows.filter(r => r.complete).length, initialNativeBodiesMatchExceptEffort: summary.initialNativeBodiesMatchExceptEffort,
  violations: violations.length, rows: rows.map(({ operations, nativeUsage, ...row }) => row) }, null, 2));
