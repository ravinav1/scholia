import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough, Writable } from 'node:stream';
import { spawn } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import net from 'node:net';
import { once } from 'node:events';
import { codexCompletionUsage, createCodexUsageReader, queryCodexRateLimits } from '../scripts/lib/codex-usage.mjs';

test('completed Codex token counts retain cached input without counting it twice', () => {
  assert.deepEqual(codexCompletionUsage({ input_tokens: 1000, cached_input_tokens: 800, output_tokens: 200 }), {
    prompt_tokens: 1000, completion_tokens: 200, total_tokens: 1200,
    prompt_tokens_details: { cached_tokens: 800 }
  });
  assert.equal(codexCompletionUsage(null), undefined);
  assert.equal(codexCompletionUsage({ input_tokens: '100', output_tokens: -1 }), undefined);
  assert.deepEqual(codexCompletionUsage({ input_tokens: 0, cached_input_tokens: 1 }), { prompt_tokens: 0 });
  assert.deepEqual(codexCompletionUsage({ output_tokens: 0 }), { completion_tokens: 0 });
});

test('usage retrieval initializes app-server and reads account metadata without inference', async () => {
  const sent = [];
  let killed = false;
  const rateLimits = { primary: { usedPercent: 17, windowDurationMins: 300, resetsAt: 1800000000 } };
  const spawnProcess = (_command, args) => {
    assert.deepEqual(args, ['app-server', '--listen', 'stdio://']);
    const child = new EventEmitter();
    child.stdout = new PassThrough(); child.stderr = new PassThrough();
    child.kill = () => { killed = true; queueMicrotask(() => child.emit('close')); };
    child.stdin = new Writable({ write(chunk, _encoding, done) {
      const request = JSON.parse(String(chunk)); sent.push(request);
      const result = request.method === 'initialize' ? {} : request.method === 'account/rateLimits/read' ? { rateLimits } : null;
      if (result) queueMicrotask(() => child.stdout.write(JSON.stringify({ id: request.id, result }) + '\n'));
      done();
    }});
    return child;
  };
  assert.deepEqual(await queryCodexRateLimits('fixture', { spawnProcess }), { rateLimits });
  assert.deepEqual(sent.map((item) => item.method), ['initialize', 'initialized', 'account/rateLimits/read']);
  assert.equal(killed, true);
});

test('account reads expire, force refresh, deduplicate and do not return stale values on failure', async () => {
  let now = 0, calls = 0, fail = false;
  const reader = createCodexUsageReader({ codex: 'fixture', now: () => now,
    query: async () => { calls++; if (fail) throw Error('offline'); return { rateLimits: { primary: { usedPercent: calls } } }; } });
  const [first, duplicate] = await Promise.all([reader.read(), reader.read()]);
  assert.equal(calls, 1); assert.deepEqual(first, duplicate);
  assert.equal(first.fetchedAt, '1970-01-01T00:00:00.000Z');
  await reader.read(); assert.equal(calls, 1);
  now = 46_000;
  await reader.read(); assert.equal(calls, 2);
  await reader.read({ fresh: true }); assert.equal(calls, 3);
  reader.invalidate(); await reader.read(); assert.equal(calls, 4);
  fail = true; reader.invalidate();
  assert.deepEqual(await reader.read(), { ok: false, error: 'offline' });
});

test('a completion during an account read prevents reusing the pre-completion snapshot', async () => {
  const resolve = [];
  const reader = createCodexUsageReader({ codex: 'fixture', query: () => new Promise((done) => resolve.push(done)) });
  const before = reader.read(); await Promise.resolve();
  reader.invalidate();
  const after = reader.read(); await Promise.resolve();
  assert.equal(resolve.length, 2);
  resolve[1]({ rateLimits: { primary: { usedPercent: 20 } } });
  assert.equal((await after).rateLimits.primary.usedPercent, 20);
  resolve[0]({ rateLimits: { primary: { usedPercent: 10 } } }); await before;
  assert.equal((await reader.read()).rateLimits.primary.usedPercent, 20);
});

test('bridge transports measured usage in JSON and SSE and authenticates account metadata', { timeout: 15_000 }, async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'scholia-usage-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const fixture = join(directory, 'codex-fixture.mjs');
  await writeFile(fixture, `#!${process.execPath}
import { createInterface } from 'node:readline';
if (process.argv.includes('--version')) { console.log('fixture'); process.exit(); }
if (process.argv.includes('app-server')) {
  for await (const line of createInterface({ input: process.stdin })) {
    const request = JSON.parse(line);
    if (request.method === 'initialize') console.log(JSON.stringify({ id: request.id, result: {} }));
    if (request.method === 'account/rateLimits/read') console.log(JSON.stringify({ id: request.id,
      result: { rateLimits: { primary: { usedPercent: 23, windowDurationMins: 300 } } } }));
  }
} else {
  process.stdin.resume();
  process.stdin.on('end', () => {
    console.log(JSON.stringify({ type: 'item.completed', item: { type: 'agent_message', text: 'Fixture answer' } }));
    console.log(JSON.stringify({ type: 'turn.completed', usage: { input_tokens: 120, cached_input_tokens: 100, output_tokens: 30 } }));
  });
}
`, { mode: 0o700 });
  const reserve = net.createServer(); reserve.listen(0, '127.0.0.1'); await once(reserve, 'listening');
  const port = reserve.address().port; await new Promise((resolve) => reserve.close(resolve));
  const bridge = spawn(process.execPath, ['scripts/codex-bridge.mjs', '--port', String(port), '--codex', fixture, '--token', 'test-token'],
    { stdio: ['ignore', 'pipe', 'pipe'] });
  t.after(async () => { if (bridge.exitCode == null) { bridge.kill(); await once(bridge, 'exit'); } });
  let stderr = ''; bridge.stderr.on('data', (chunk) => { stderr += chunk; });
  await new Promise((resolve, reject) => {
    bridge.stdout.on('data', (chunk) => { if (String(chunk).includes('listening on')) resolve(); });
    bridge.once('error', reject); bridge.once('exit', () => reject(Error(stderr || 'Bridge exited')));
  });
  const base = `http://127.0.0.1:${port}`;
  assert.equal((await fetch(`${base}/v1/usage`)).status, 401);
  const headers = { Authorization: 'Bearer test-token', 'Content-Type': 'application/json' };
  const quotaResponse = await fetch(`${base}/v1/usage`, { headers });
  assert.equal(quotaResponse.headers.get('cache-control'), 'no-store');
  const quota = await quotaResponse.json();
  assert.equal(quota.rateLimits.primary.usedPercent, 23);
  assert.ok(Date.parse(quota.fetchedAt));
  const complete = (stream) => fetch(`${base}/v1/chat/completions`, { method: 'POST', headers,
    body: JSON.stringify({ model: 'gpt-6-astra', messages: [{ role: 'user', content: 'fixture' }], stream }) });
  const json = await (await complete(false)).json();
  assert.equal(json.choices[0].message.content, 'Fixture answer');
  assert.equal(json.usage.total_tokens, 150);
  assert.equal(json.usage.prompt_tokens_details.cached_tokens, 100);
  assert.ok(json.scholia_usage.elapsed_seconds >= 0);
  const sse = await (await complete(true)).text();
  const frames = sse.split('\n').filter((line) => line.startsWith('data: {')).map((line) => JSON.parse(line.slice(6)));
  const done = frames.find((frame) => frame.choices?.[0]?.finish_reason === 'stop');
  assert.deepEqual(done.usage, json.usage);
  assert.ok(done.scholia_usage.elapsed_seconds >= 0);
  assert.equal(frames.filter((frame) => frame.usage).length, 1);
});
