#!/usr/bin/env node
// Read-only verification of captured benchmark artifacts; never calls a model.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const output = path.join(root, 'output/chat-benchmark');
const read = file => JSON.parse(fs.readFileSync(path.join(output, file)));
const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
const identical = (a, b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));
const hash = value => createHash('sha256').update(value).digest('hex');
const plan = read('run-plan.json'), summary = read('summary.json');
const failures = [], checks = [];
function check(name, passed, detail) { checks.push({ name, passed, detail }); if (!passed) failures.push(name); }
const baseline = read('batched/round-01-native-request.json'); delete baseline.reasoning_effort;
const batchForward = read('batched/round-01-forwarded-request.json'); delete batchForward.reasoning_effort;
for (const arm of plan.order) {
  const native = read(`${arm}/round-01-native-request.json`), expectedEffort = arm.startsWith('batched-') ? arm.slice(8) : 'max';
  check(`${arm}: exact selected model and effort`, native.model === 'gpt-6-astra' && native.reasoning_effort === expectedEffort);
  delete native.reasoning_effort;
  check(`${arm}: identical initial native request except effort`, identical(native, baseline));
  const forwarded = read(`${arm}/round-01-forwarded-request.json`); delete forwarded.reasoning_effort;
  const expected = structuredClone(batchForward);
  if (arm === 'sequential') for (const message of expected.messages.filter(message => message.role === 'system')) {
    message.content = message.content.split('\n').filter(line => !line.trim().startsWith('{"operation":"read_batch"') && !line.trim().startsWith('{"operation":"attachment_batch"')).join('\n')
      .replace('ONE operation (or one read_batch containing independent operations)', 'ONE operation')
      .replace('ONE operation (or one attachment_batch of independent operations)', 'ONE operation');
  }
  check(`${arm}: exact expected forwarded request`, identical(forwarded, expected));
  const row = summary.rows.find(row => row.arm === arm);
  check(`${arm}: native token aggregation equals captured per-round totals`, row.nativeUsage?.inputTokens === row.inputTokens
    && row.nativeUsage?.cachedInputTokens === row.cachedInputTokens && row.nativeUsage?.outputTokens === row.outputTokens
    && row.nativeUsage?.requestCount === row.modelRequests);
  check(`${arm}: final answer artifact exists`, row.complete && fs.existsSync(path.join(output, arm, 'answer.md')));
}
const expectedCLI = { max: 18, high: 6, medium: 5, low: 6 };
const actualCLI = {};
for (const invocation of summary.cliInvocations) {
  check(`CLI ${invocation.at}: model and ephemeral process`, invocation.model === 'gpt-6-astra' && invocation.ephemeral === true && invocation.imageCount === 4);
  const effort = invocation.configs.find(value => value.startsWith('model_reasoning_effort='));
  const value = effort ? JSON.parse(effort.slice(effort.indexOf('=') + 1)) : null;
  actualCLI[value] = (actualCLI[value] || 0) + 1;
}
check('Actual CLI effort counts include exactly one interrupted Max request', identical(actualCLI, expectedCLI), actualCLI);
check('No fixture scope violations', summary.violations.length === 0);
check('Exactly one documented transport interruption', summary.harnessErrors.length === 1);
check('Every emitted source operation has an explicit result', summary.rows.every(row => row.sourceOperationsUnconfirmed === 0));
const replay = fs.readFileSync(path.join(output, 'sequential/replay-audit.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
check('Recovery replay used ten exact inputs without inference', replay.length === 10 && replay.every((entry, index) => entry.round === index + 1 && entry.identicalInput && entry.inference === false));
const sourcePaths = ['scripts/benchmark-chat-live.mjs', 'scripts/benchmark-chat-native.swift', 'scripts/benchmark-chat-native.sh',
  'scripts/codex-bridge.mjs', 'scripts/lib/codex-cli-arguments.mjs', 'scripts/lib/codex-usage.mjs',
  ...['ProviderClient', 'PromptBuilder', 'AttachmentContextRetrieval', 'AttachmentCorpusTools', 'StudyContext', 'StudyReadingRetrieval', 'LocalFileTools', 'ReadOnlyToolBatch', 'CompletionUsage'].map(name => `apps/macos/Sources/ScholiaMac/${name}.swift`)];
const audit = { auditedAt: new Date().toISOString(), passed: failures.length === 0, failures, checks, expectedCLI, actualCLI,
  nativeExecutableSHA256: hash(fs.readFileSync(path.join(output, 'chat-benchmark-native'))),
  preparedSnapshotSHA256: hash(fs.readFileSync(path.join(output, 'prepared-messages.json'))),
  sourceSHA256: Object.fromEntries(sourcePaths.map(name => [name, hash(fs.readFileSync(path.join(root, name)))])),
  measurementLimits: ['One sample per selected mode; no statistical speed/quality guarantee.',
    'Sequential Max timing is reconstructed after a benchmark transport interruption; abandoned-call token usage is unknown.',
    'Quota snapshots reflect a shared account and integer percentage granularity; they are not exact per-query costs.',
    'Time to final answer is measured; proxy buffering makes first displayed token latency unrepresentative.'] };
fs.writeFileSync(path.join(output, 'measurement-audit.json'), JSON.stringify(audit, null, 2) + '\n');
console.log(JSON.stringify({ passed: audit.passed, checks: checks.length, failures, actualCLI }, null, 2));
if (failures.length) process.exitCode = 1;
