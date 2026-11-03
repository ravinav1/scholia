import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';

const tokenCount = (value) => Number.isSafeInteger(value) && value >= 0 ? value : undefined;

// Codex exec reports actual tokens at turn.completed. Unknown values remain
// absent: tokens cannot be converted into subscription-budget percentages.
export function codexCompletionUsage(usage) {
  const input = tokenCount(usage?.input_tokens);
  const output = tokenCount(usage?.output_tokens);
  const cached = tokenCount(usage?.cached_input_tokens);
  if (input === undefined && output === undefined && cached === undefined) return undefined;
  return {
    ...(input !== undefined ? { prompt_tokens: input } : {}),
    ...(output !== undefined ? { completion_tokens: output } : {}),
    ...(input !== undefined && output !== undefined && Number.isSafeInteger(input + output)
      ? { total_tokens: input + output } : {}),
    ...(cached !== undefined && (input === undefined || cached <= input)
      ? { prompt_tokens_details: { cached_tokens: cached } } : {})
  };
}

// Reads account metadata only; no thread or inference turn is created.
export function queryCodexRateLimits(codex, { spawnProcess = spawn, timeoutMs = 12_000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawnProcess(codex, ['app-server', '--listen', 'stdio://'], {
      cwd: tmpdir(), stdio: ['pipe', 'pipe', 'pipe'], env: process.env
    });
    let buffer = '', settled = false;
    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      child.stdin.end();
      child.kill('SIGTERM');
      const kill = setTimeout(() => child.kill('SIGKILL'), 1_000);
      kill.unref();
      child.once('close', () => clearTimeout(kill));
      if (error) reject(error); else resolve(result);
    };
    const timeout = setTimeout(() => finish(new Error('Codex usage query timed out.')), timeoutMs);
    const send = (message) => child.stdin.write(JSON.stringify(message) + '\n');
    child.stdin.on('error', () => finish(new Error('Codex usage connection closed.')));
    child.stderr.on('data', () => {});
    child.on('error', () => finish(new Error('Codex could not be started for usage retrieval.')));
    child.on('close', () => finish(new Error('Codex usage query ended early.')));
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      if (settled) return;
      buffer += chunk;
      if (buffer.length > 1_000_000) return finish(new Error('Codex usage response is too large.'));
      let newline;
      while (!settled && (newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
        let message;
        try { message = JSON.parse(line); } catch { continue; }
        if (![1, 2].includes(message.id)) continue;
        if (message.error) return finish(new Error(message.error.message || 'Codex rejected usage retrieval.'));
        if (message.id === 1 && message.result) {
          send({ method: 'initialized' });
          send({ id: 2, method: 'account/rateLimits/read' });
        } else if (message.id === 2) {
          const result = message.result;
          if (!result || typeof result !== 'object' || (!result.rateLimits && !result.rateLimitsByLimitId))
            return finish(new Error('Codex returned no account usage limits.'));
          finish(null, result);
        }
      }
    });
    send({ id: 1, method: 'initialize', params: {
      clientInfo: { name: 'scholia-codex-usage', version: '1.0.0' }, capabilities: {}
    } });
  });
}

export function createCodexUsageReader({ codex, query = queryCodexRateLimits, now = Date.now, ttlMs = 45_000 }) {
  let cached = null, pending = null, generation = 0;
  return {
    invalidate() { cached = null; generation++; },
    read({ fresh = false } = {}) {
      // A read begun before a completion must not become its "after" snapshot.
      if (pending && pending.generation === generation) return pending.promise;
      if (!fresh && cached && now() - cached.timestamp < ttlMs) return Promise.resolve(cached.value);
      const startedGeneration = generation;
      const promise = Promise.resolve().then(() => query(codex)).then((result) => {
        const timestamp = now();
        const value = { ...result, ok: true, fetchedAt: new Date(timestamp).toISOString() };
        if (startedGeneration === generation) cached = { value, timestamp };
        return value;
      }).catch((error) => ({ ok: false, error: error.message || 'Codex usage unavailable.' }))
        .finally(() => { if (pending?.promise === promise) pending = null; });
      pending = { promise, generation: startedGeneration };
      return promise;
    }
  };
}
