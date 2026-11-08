import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

test('Codex bridge retains GPT-6.1 Sol offline and dispatches Extra High unchanged', async (t) => {
  const directory = await mkdtemp(join(tmpdir(), 'scholia-codex-model-'));
  const executable = join(directory, 'fixture-codex');
  const argumentsFile = join(directory, 'arguments.json');
  // This executable is a fixture; the real Codex CLI is never launched.
  await writeFile(executable, `#!${process.execPath}
const {writeFileSync}=require('node:fs');
if (process.argv[2] === '--version') { console.log('fixture-codex'); process.exit(0); }
if (process.argv[2] === 'app-server') process.exit(1);
writeFileSync(process.env.SCHOLIA_FIXTURE_CODEX_ARGS, JSON.stringify(process.argv.slice(2)));
process.stdin.resume();
process.stdin.on('end',()=>{
  console.log(JSON.stringify({type:'item.completed',item:{type:'agent_message',text:'Fixture answer'}}));
  console.log(JSON.stringify({type:'turn.completed',usage:{input_tokens:1,output_tokens:1}}));
});
`, { mode: 0o755 });
  const reserve = createServer();
  await new Promise((done) => reserve.listen(0, '127.0.0.1', done));
  const port = reserve.address().port;
  await new Promise((done) => reserve.close(done));
  const bridge = spawn(process.execPath, [
    new URL('../../scripts/bridges/codex-bridge.mjs', import.meta.url).pathname,
    '--port', String(port), '--codex', executable
  ], { env: { ...process.env, SCHOLIA_FIXTURE_CODEX_ARGS: argumentsFile }, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  bridge.stdout.on('data', (chunk) => { output += chunk; });
  bridge.stderr.on('data', (chunk) => { output += chunk; });
  t.after(async () => {
    if (bridge.exitCode === null) {
      const stopped = once(bridge, 'exit');
      bridge.kill('SIGTERM');
      await stopped;
    }
    await rm(directory, { recursive: true, force: true });
  });
  const base = `http://127.0.0.1:${port}`;
  let ready = false;
  for (let n = 0; n < 100; n++) {
    try { ready = (await fetch(`${base}/health`)).ok; } catch {}
    if (ready || bridge.exitCode !== null) break;
    await delay(20);
  }
  assert.ok(ready, output);
  const catalog = await (await fetch(`${base}/v1/models`)).json();
  assert.ok(catalog.data.some((entry) => entry.id === 'gpt-6.1-sol'), 'offline fallback includes the selectable model');
  const response = await fetch(`${base}/v1/chat/completions`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ model: 'gpt-6.1-sol', reasoning_effort: 'xhigh', messages: [{ role: 'user', content: 'Fixture only.' }] })
  });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).choices[0].message.content, 'Fixture answer');
  const args = JSON.parse(await readFile(argumentsFile, 'utf8'));
  assert.equal(args[args.indexOf('--model') + 1], 'gpt-6.1-sol');
  assert.ok(args.includes('model_reasoning_effort="xhigh"'));
  assert.ok(args.includes('--ephemeral'));
  assert.equal(args[args.indexOf('--sandbox') + 1], 'read-only');
});
