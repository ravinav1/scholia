import { Worker } from 'node:worker_threads';
import { createInterface } from 'node:readline';

// Private inherited pipes, not an HTTP listener. EOF stops the worker when the
// Mac app exits, including a force quit during an update.
const worker = new Worker(new URL('../apps/server/semantic-search-worker.js', import.meta.url));
const pending = new Map();
const send = value => process.stdout.write(`${JSON.stringify(value)}\n`);
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
worker.on('message', value => {
  if (value.type === 'idle') {
    // A new request may already be on its way to the worker. Its parent owns
    // the pending set and makes the final retirement decision.
    if (!pending.size) { input.close(); process.stdin.destroy(); }
    return;
  }
  pending.delete(value.id); send(value);
});
const stopped = error => {
  for (const id of pending.keys()) send({ id, error: error.message });
  pending.clear(); process.exitCode = 1; input.close(); process.stdin.destroy();
};
worker.on('error', stopped);
worker.on('exit', code => { if (!input.closed) stopped(new Error(`The local search worker stopped (${code}).`)); });
input.on('line', line => {
  let message;
  try {
    message = JSON.parse(line);
    if (message.cancel) {
      const flag = pending.get(message.cancel);
      if (flag) Atomics.store(new Int32Array(flag), 0, 1);
      return;
    }
    if (pending.size >= 16) throw new Error('Semantic search is busy. Try again shortly.');
    const cancellation = new SharedArrayBuffer(4);
    pending.set(message.id, cancellation);
    worker.postMessage({ ...message, cancellation });
  } catch (error) { if (message?.id) send({ id: message.id, error: error.message }); }
});
input.on('close', () => { void worker.terminate(); });
