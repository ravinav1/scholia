import assert from 'node:assert/strict';
import { access, readFile, mkdtemp, cp, rm } from 'node:fs/promises';
import { constants } from 'node:fs';
import { tmpdir } from 'node:os';
import { createRequire } from 'node:module';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Worker } from 'node:worker_threads';

// Check the self-contained bundle, not imports resolved from the source tree.
// A canceled worker job exercises startup without downloading model weights or
// opening a user's index. No provider or model-inference request is made.
const app = resolve(process.argv[2] || 'dist/macos/Scholia.app');
const resources = join(app, 'Contents/Resources');
for (const name of ['pdf-search.js', 'code-highlight.js', 'ntnu-study-plans.json']) {
  await access(join(resources, 'NativeResources', name));
}
// Relocate outside the checkout so Node cannot silently fall back to the
// development node_modules when a transitive runtime dependency is missing.
const isolated = await mkdtemp(join(tmpdir(), 'scholia-package-check-'));
try {
  const runtime = join(isolated, 'SemanticSearch');
  await cp(join(resources, 'SemanticSearch'), runtime, {
    recursive: true,
    mode: constants.COPYFILE_FICLONE,
  });
  await access(join(runtime, 'scripts/semantic-search-bridge.mjs'));
  const require = createRequire(join(runtime, 'package.json'));
  await import(pathToFileURL(require.resolve('@huggingface/transformers')).href);
  const cancellation = new SharedArrayBuffer(4);
  Atomics.store(new Int32Array(cancellation), 0, 1);
  const worker = new Worker(
    pathToFileURL(join(runtime, 'packages/search/semantic-search-worker.js'))
  );
  try {
    const reply = await new Promise((resolve, reject) => {
      const timeout = setTimeout(
        () => reject(new Error('Packaged semantic worker timed out')),
        15_000
      );
      const done = (callback) => (value) => {
        clearTimeout(timeout);
        callback(value);
      };
      worker.once('message', done(resolve));
      worker.once('error', done(reject));
      worker.postMessage({ id: 'package-probe', cancellation });
    });
    assert.equal(reply.id, 'package-probe');
    assert.equal(reply.errorName, 'AbortError');
    assert.match(reply.error, /cancelled/i);
  } finally {
    await worker.terminate();
  }
  const metadata = JSON.parse(await readFile(join(runtime, 'package.json'), 'utf8'));
  assert.equal(metadata.type, 'module');
  console.log(
    'PASS native bundled helpers, semantic dependency closure, and canceled worker startup'
  );
} finally {
  await rm(isolated, { recursive: true, force: true });
}
