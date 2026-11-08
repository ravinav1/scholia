#!/usr/bin/env node
// Run after swift package resolve. Read pristine, pinned dependency objects from
// git into a disposable fixture; never alter the real SwiftPM checkout here.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { patchSwiftMathResources } from './patch-swiftmath-resources.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const packageRoot = path.join(root, 'apps/macos');
const checkout = path.join(packageRoot, '.build/checkouts/SwiftMath');
const revision = 'fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7';
const testRoot = await mkdtemp(path.join(os.tmpdir(), 'scholia-swiftmath-patch-test-'));
try {
  const pin = await readFile(path.join(packageRoot, 'Package.resolved'), 'utf8');
  await writeFile(path.join(testRoot, 'Package.resolved'), pin);
  const original = new Map();
  for (const relative of ['MathRender/MTFont.swift', 'MathBundle/MathFont.swift']) {
    const source = `Sources/SwiftMath/${relative}`;
    const contents = execFileSync('git', ['-C', checkout, 'show', `${revision}:${source}`], { encoding: 'utf8' });
    const destination = path.join(testRoot, '.build/checkouts/SwiftMath', source);
    await mkdir(path.dirname(destination), { recursive: true });
    await writeFile(destination, contents);
    original.set(destination, contents);
  }
  assert.equal((await patchSwiftMathResources(testRoot)).changed, 2);
  assert.equal((await patchSwiftMathResources(testRoot)).changed, 0);
  console.log('PASS exact original patch and repeated idempotence');

  const [first, second] = [...original.keys()];
  await writeFile(first, original.get(first));
  await writeFile(second, original.get(second) + '// unreviewed upstream edit\n');
  await assert.rejects(patchSwiftMathResources(testRoot), /unexpected source contents/);
  assert.equal(await readFile(first, 'utf8'), original.get(first));
  console.log('PASS source drift rejected before modifying either source');

  const unsupported = JSON.parse(pin);
  unsupported.pins.find(item => item.identity === 'swiftmath').state.version = '1.7.4';
  await writeFile(path.join(testRoot, 'Package.resolved'), JSON.stringify(unsupported));
  await assert.rejects(patchSwiftMathResources(testRoot), /requires pinned/);
  console.log('PASS dependency version drift rejected');
} finally {
  await rm(testRoot, { recursive: true, force: true });
}
