import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, rm, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AccountStore } from '../../apps/server/store.js';

const script = fileURLToPath(new URL('../../apps/server/user.mjs', import.meta.url));
function provision(root, password, reset = false) {
  return new Promise((resolve, reject) => {
    const child = spawn(
      process.execPath,
      [script, '--email', 'reader@example.com', ...(reset ? ['--reset'] : [])],
      {
        env: { ...process.env, SCHOLIA_DATA_DIR: root, SCHOLIA_SECRET_KEY: '' },
        stdio: ['pipe', 'pipe', 'pipe'],
      }
    );
    let output = '';
    child.stdout.on('data', (chunk) => {
      output += chunk;
    });
    child.stderr.on('data', (chunk) => {
      output += chunk;
    });
    child.on('error', reject);
    child.on('close', (code) => resolve({ code, output }));
    child.stdin.end(password === undefined ? undefined : `${password}\n`);
  });
}

test('account CLI reads piped passwords without echoing them and revokes sessions on reset', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'scholia-user-cli-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const oldPassword = 'private CLI password 21',
    newPassword = 'new private CLI password 34';
  const created = await provision(root, oldPassword);
  assert.equal(created.code, 0, created.output);
  assert.match(created.output, /Account created/);
  assert.ok(!created.output.includes(oldPassword));
  const originalStore = new AccountStore(root);
  const login = await originalStore.login('reader@example.com', oldPassword);
  assert.ok(login);
  originalStore.close();
  const updated = await provision(root, newPassword, true);
  assert.equal(updated.code, 0, updated.output);
  assert.match(updated.output, /sessions revoked/);
  assert.ok(!updated.output.includes(newPassword));
  const store = new AccountStore(root);
  try {
    assert.equal(store.session(login.value), null);
    assert.equal(await store.login('reader@example.com', oldPassword), null);
    assert.ok(await store.login('reader@example.com', newPassword));
  } finally {
    store.close();
  }
});

test('account CLI exits cleanly when no password is supplied', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'scholia-user-empty-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const result = await provision(root);
  assert.equal(result.code, 1);
  assert.match(result.output, /No password supplied/);
  await assert.rejects(access(join(root, 'accounts.sqlite')));
});
