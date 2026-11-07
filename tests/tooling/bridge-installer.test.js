import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';

const installer = new URL('../../scripts/bridges/install-bridge-handler.mjs', import.meta.url);
const run = (...args) =>
  spawnSync(process.execPath, [installer.pathname, ...args], {
    encoding: 'utf8',
  });

test('each bridge exposes its own help without installing a handler', () => {
  for (const provider of ['codex', 'claude', 'opencode']) {
    const result = run(provider, '--help');
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, new RegExp(`install-bridge-handler.mjs ${provider} `));
    assert.match(result.stdout, /--port N.*--uninstall/);
  }
});

test('invalid installer arguments fail before changing the system', () => {
  for (const args of [
    [],
    ['unknown'],
    ['constructor'],
    ['codex', '--port', '0'],
    ['claude', '--port', '65536'],
    ['opencode', '--port'],
    ['codex', '--unknown'],
  ]) {
    const result = run(...args);
    assert.equal(result.status, 1, JSON.stringify(args));
    assert.match(result.stderr, /Choose a bridge|--port must be|Unknown option/);
  }
  assert.equal(run('--help').status, 0);
});
