import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';

export function codexModelChoices(entries) {
  const models = new Map();
  for (const entry of Array.isArray(entries) ? entries : []) {
    if (!entry || entry.hidden === true) continue;
    const id = String(entry.model || entry.id || '').trim();
    if (!id || id.length > 200 || /[\u0000-\u001f]/.test(id)) continue;
    const efforts = [...new Set((Array.isArray(entry.supportedReasoningEfforts) ? entry.supportedReasoningEfforts : [])
      .map((item) => item?.reasoningEffort).filter((item) => typeof item === 'string' && item.length > 0 && item.length <= 40))];
    const defaultEffort = efforts.includes(entry.defaultReasoningEffort) ? entry.defaultReasoningEffort : efforts[0];
    models.set(id, {
      id, object: 'model', owned_by: 'codex',
      label: String(entry.displayName || id).slice(0, 240),
      ...(efforts.length ? { reasoning: { efforts, default: defaultEffort } } : {}),
      supportsImages: !Array.isArray(entry.inputModalities) || entry.inputModalities.includes('image')
    });
  }
  return [...models.values()];
}

// This only asks for a catalog. It never starts a thread or an inference turn.
export function queryCodexModels(codex, { spawnProcess = spawn, timeoutMs = 12_000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawnProcess(codex, ['app-server', '--listen', 'stdio://'], {
      cwd: tmpdir(), stdio: ['pipe', 'pipe', 'pipe'], env: process.env
    });
    let buffer = '', requestID = 1, settled = false, pages = 0;
    const entries = [], cursors = new Set();
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      child.stdin.end();
      child.kill('SIGTERM');
      const kill = setTimeout(() => child.kill('SIGKILL'), 1_000);
      kill.unref();
      child.once('close', () => clearTimeout(kill));
      if (error) reject(error); else resolve(value);
    };
    const timeout = setTimeout(() => finish(new Error('Codex model discovery timed out.')), timeoutMs);
    const send = (message) => child.stdin.write(JSON.stringify(message) + '\n');
    const list = (cursor) => send({ id: ++requestID, method: 'model/list', params: { limit: 100, includeHidden: false, ...(cursor ? { cursor } : {}) } });
    child.stdin.on('error', () => finish(new Error('Codex catalog connection closed.')));
    child.stderr.on('data', () => {});
    child.on('error', () => finish(new Error('Codex could not be started for model discovery.')));
    child.on('close', () => finish(new Error('Codex model discovery ended early.')));
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      if (settled) return;
      buffer += chunk.toString('utf8');
      if (buffer.length > 4_000_000) return finish(new Error('Codex model catalog is too large.'));
      let newline;
      while (!settled && (newline = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
        let message;
        try { message = JSON.parse(line); } catch { continue; }
        if (message.id !== requestID) continue;
        if (message.error) return finish(new Error('Codex rejected model discovery.'));
        if (requestID === 1) { send({ method: 'initialized' }); list(); continue; }
        if (!Array.isArray(message.result?.data)) return finish(new Error('Codex returned an invalid model catalog.'));
        entries.push(...message.result.data);
        const cursor = message.result.nextCursor;
        if (cursor) {
          if (typeof cursor !== 'string' || cursors.has(cursor) || ++pages >= 20)
            return finish(new Error('Codex returned invalid model pagination.'));
          cursors.add(cursor); list(cursor);
        } else {
          const models = codexModelChoices(entries);
          finish(models.length ? null : new Error('Codex returned no visible models.'), models);
        }
      }
    });
    send({ id: 1, method: 'initialize', params: { clientInfo: { name: 'scholia-model-catalog', title: 'Scholia', version: '1.0.0' }, capabilities: {} } });
  });
}

export function createCodexModelCatalog({ codex, fallback = [], query = queryCodexModels, now = Date.now, ttlMs = 120_000 }) {
  let models = fallback.map((id) => ({ id, label: id, object: 'model', owned_by: 'codex' }));
  let checkedAt = -Infinity, pending;
  return {
    peek: () => models,
    read() {
      if (pending) return pending;
      if (now() - checkedAt < ttlMs) return Promise.resolve(models);
      pending = Promise.resolve().then(() => query(codex)).then((next) => {
        if (!next.length) throw new Error('Empty model catalog');
        models = next; checkedAt = now();
        return models;
      }).catch(() => {
        // Keep the last working catalog while offline; retry soon.
        checkedAt = now() - ttlMs + 15_000;
        return models;
      }).finally(() => { pending = null; });
      return pending;
    }
  };
}
