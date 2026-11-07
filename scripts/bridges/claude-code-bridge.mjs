#!/usr/bin/env node
/**
 * OpenAI-compatible loopback bridge for a locally authenticated Claude Code
 * CLI. Requests run without tools or session persistence. Use --token on a
 * shared machine and --allow-images only when image forwarding is intended.
 */

import http from 'node:http';
import { spawn, execFile } from 'node:child_process';
import { randomUUID, createHash, timingSafeEqual } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const BRIDGE_VERSION = '0.1.0';
const SERVICE = 'claude-code-bridge';
const MODELS = ['fable', 'opus', 'sonnet', 'haiku'];
const EFFORTS = ['low', 'medium', 'high', 'xhigh', 'max'];
const MAX_BODY_BYTES = 10 * 1024 * 1024;
const MAX_REASONING_CHARACTERS = 24_000;
const DEFAULT_SYSTEM = 'You are a helpful assistant.';
const IMAGE_PLACEHOLDER = '[image attached but this provider is text-only]';

function parseArgs(argv) {
  const opts = {
    port: 8787,
    token: null,
    cors: [],
    claude: 'claude',
    cwd: path.join(os.homedir(), '.cache', 'scholia', 'claude-bridge'),
    timeout: 600,
    verbose: false,
    allowImages: false
  };
  const takesValue = new Set(['port', 'token', 'cors', 'claude', 'cwd', 'timeout']);
  for (let i = 0; i < argv.length; i++) {
    let arg = argv[i];
    if (arg === '-h') arg = '--help';
    if (!arg.startsWith('--')) {
      console.error(`[bridge] unexpected argument: ${arg}`);
      process.exit(1);
    }
    arg = arg.slice(2);
    let value = null;
    const eq = arg.indexOf('=');
    if (eq >= 0) { value = arg.slice(eq + 1); arg = arg.slice(0, eq); }
    if (arg === 'help') {
      console.log(
        'Usage: node scripts/bridges/claude-code-bridge.mjs [--port N] [--token SECRET] '
        + '[--cors ORIGINS] [--claude PATH] [--cwd DIR] [--timeout SECONDS] '
        + '[--allow-images] [--verbose]'
      );
      process.exit(0);
    }
    if (arg === 'verbose') { opts.verbose = true; continue; }
    if (arg === 'allow-images') { opts.allowImages = true; continue; }
    if (!takesValue.has(arg)) {
      console.error(`[bridge] unknown flag --${arg} (try --help)`);
      process.exit(1);
    }
    if (value === null) value = argv[++i];
    if (value === undefined) {
      console.error(`[bridge] flag --${arg} needs a value`);
      process.exit(1);
    }
    if (arg === 'port' || arg === 'timeout') {
      const n = Number(value);
      const invalidPort = arg === 'port' && (!Number.isInteger(n) || n > 65_535);
      if (!Number.isFinite(n) || n <= 0 || invalidPort) {
        console.error(`[bridge] flag --${arg} needs a positive number, got "${value}"`);
        process.exit(1);
      }
      opts[arg] = Math.floor(n);
    } else if (arg === 'cors') {
      opts.cors = value.split(',').map((s) => s.trim()).filter(Boolean);
    } else {
      opts[arg] = value;
    }
  }
  return opts;
}

const OPTS = parseArgs(process.argv.slice(2));
const TIMEOUT_MS = OPTS.timeout * 1000;

const EXTRA_ORIGINS = new Set([
  'https://folk.ntnu.no',
  'https://heaps0rt.github.io',
  ...OPTS.cors
]);
const LOCAL_ORIGIN_RE = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/i;
const EXTENSION_ORIGIN_RE = /^chrome-extension:\/\/[a-p]{32}$/i;

function originAllowed(origin) {
  if (!origin) return false;
  return LOCAL_ORIGIN_RE.test(origin) || EXTENSION_ORIGIN_RE.test(origin) || EXTRA_ORIGINS.has(origin);
}

function corsHeaders(req) {
  const origin = req.headers.origin;
  if (!originAllowed(origin)) return { Vary: 'Origin' };
  return {
    'Access-Control-Allow-Origin': origin,
    Vary: 'Origin'
  };
}

function sendJson(res, status, obj, extraHeaders = {}) {
  if (res.writableEnded || res.headersSent) return;
  const body = JSON.stringify(obj);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    ...extraHeaders
  });
  res.end(body);
}

function sendError(res, status, message, type, extraHeaders = {}) {
  sendJson(res, status, { error: { message, type } }, extraHeaders);
}

function tokenMatches(header) {
  if (!OPTS.token) return true;
  const m = /^Bearer\s+(.+)$/i.exec(header || '');
  if (!m) return false;
  const a = createHash('sha256').update(m[1]).digest();
  const b = createHash('sha256').update(OPTS.token).digest();
  return timingSafeEqual(a, b);
}

function contentToText(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return content == null ? '' : String(content);
  const pieces = [];
  for (const part of content) {
    if (typeof part === 'string') { pieces.push(part); continue; }
    if (!part || typeof part !== 'object') continue;
    if (part.type === 'text' && typeof part.text === 'string') {
      pieces.push(part.text);
    } else if (part.type === 'image_url' || part.type === 'image' || part.type === 'input_image') {
      if (!OPTS.allowImages) pieces.push(IMAGE_PLACEHOLDER);
    } else if (typeof part.text === 'string') {
      pieces.push(part.text);
    }
  }
  return pieces.join('\n');
}

function buildPrompts(messages) {
  const systemParts = [];
  const turns = [];
  for (const msg of messages) {
    if (!msg || typeof msg !== 'object') continue;
    const text = contentToText(msg.content);
    if (msg.role === 'system') {
      if (text.trim()) systemParts.push(text);
    } else {
      turns.push({ role: msg.role === 'assistant' ? 'Assistant' : 'User', text });
    }
  }
  if (!turns.some((t) => t.role === 'User' && t.text.trim())) {
    return { error: 'messages must include at least one non-empty user message' };
  }
  const system = systemParts.join('\n\n') || DEFAULT_SYSTEM;
  const prompt = turns.length === 1
    ? turns[0].text
    : turns.map((t) => `${t.role}: ${t.text}`).join('\n\n');
  return { system, prompt };
}

function extractImages(messages) {
  const out = [];
  for (const msg of messages) {
    if (!msg || msg.role !== 'user' || !Array.isArray(msg.content)) continue;
    for (const part of msg.content) {
      if (!part || typeof part !== 'object') continue;
      if (part.type === 'image' && part.source?.type === 'base64' && part.source.data) {
        out.push({ media_type: part.source.media_type || 'image/png', data: part.source.data });
        continue;
      }
      let url = null;
      if (part.type === 'image_url') url = typeof part.image_url === 'string' ? part.image_url : part.image_url?.url;
      else if (part.type === 'input_image') url = part.image_url || part.url;
      if (typeof url !== 'string') continue;
      const m = /^data:([^;,]+);base64,(.+)$/s.exec(url);
      if (m && m[2]) out.push({ media_type: m[1] || 'image/png', data: m[2] });
    }
  }
  return out;
}

function mapUsage(u) {
  if (!u || typeof u !== 'object') return null;
  const promptTokens =
    (Number(u.input_tokens) || 0) +
    (Number(u.cache_read_input_tokens) || 0) +
    (Number(u.cache_creation_input_tokens) || 0);
  const completionTokens = Number(u.output_tokens) || 0;
  if (!promptTokens && !completionTokens) return null;
  return {
    prompt_tokens: promptTokens,
    completion_tokens: completionTokens,
    total_tokens: promptTokens + completionTokens
  };
}

function log(...args) {
  if (OPTS.verbose) console.log('[bridge]', ...args);
}

function handleChatCompletion(req, res, body) {
  const cors = corsHeaders(req);

  const model = typeof body.model === 'string' && body.model ? body.model : 'sonnet';
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(model)) {
    return sendError(res, 400, `invalid model "${model}"`, 'invalid_request_error', cors);
  }
  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return sendError(res, 400, 'messages must be a non-empty array', 'invalid_request_error', cors);
  }
  const prompts = buildPrompts(body.messages);
  if (prompts.error) {
    return sendError(res, 400, prompts.error, 'invalid_request_error', cors);
  }
  const stream = body.stream === true;
  const effort = EFFORTS.includes(body.reasoning_effort) ? body.reasoning_effort : null;

  const args = [
    '-p',
    '--output-format', 'stream-json',
    '--include-partial-messages',
    '--verbose',
    '--model', model,
    '--tools', '',
    '--no-session-persistence',
    '--safe-mode',
    `--system-prompt=${prompts.system}`
  ];
  if (effort) args.push('--effort', effort);
  if (body.fast_mode === true || body.fast === true) {
    args.push('--settings', JSON.stringify({ fastMode: true }));
  }

  let stdinPayload = prompts.prompt;
  const images = OPTS.allowImages ? extractImages(body.messages) : [];
  if (images.length) {
    args.push('--input-format', 'stream-json');
    const content = [{ type: 'text', text: prompts.prompt }];
    for (const im of images) {
      content.push({ type: 'image', source: { type: 'base64', media_type: im.media_type, data: im.data } });
    }
    stdinPayload = JSON.stringify({ type: 'user', message: { role: 'user', content } }) + '\n';
  }

  const startedAt = Date.now();
  const id = `chatcmpl-${randomUUID()}`;
  const created = Math.floor(startedAt / 1000);

  let child;
  try {
    child = spawn(OPTS.claude, args, {
      cwd: OPTS.cwd,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: process.env
    });
  } catch (err) {
    return sendError(res, 500, `failed to spawn claude: ${err.message}`, 'bridge_error', cors);
  }

  let settled = false;
  let aborted = false;
  let timedOut = false;
  let spawnError = null;
  let streamStarted = false;
  let sawDelta = false;
  let resultObj = null;
  const textParts = [];
  const reasoningParts = [];
  let stderrTail = '';
  let stdoutRemainder = '';

  const killChild = () => {
    try { child.kill('SIGTERM'); } catch { /* already gone */ }
    setTimeout(() => { try { child.kill('SIGKILL'); } catch { /* already gone */ } }, 3000).unref();
  };

  const timer = setTimeout(() => { timedOut = true; killChild(); }, TIMEOUT_MS);

  res.on('close', () => {
    if (!res.writableEnded) {
      aborted = true;
      clearTimeout(timer);
      killChild();
    }
  });

  child.stdin.on('error', () => { /* EPIPE if child died early — handled on close */ });
  child.stdin.end(stdinPayload);

  child.on('error', (err) => { spawnError = err; });

  child.stderr.on('data', (chunk) => {
    stderrTail = (stderrTail + chunk.toString('utf8')).slice(-2000);
  });

  const chunkPayload = (delta, finishReason, usage) => {
    const payload = {
      id,
      object: 'chat.completion.chunk',
      created,
      model,
      choices: [{ index: 0, delta, finish_reason: finishReason }]
    };
    if (usage) payload.usage = usage;
    return payload;
  };

  const writeSse = (obj) => {
    if (res.writableEnded) return;
    res.write(`data: ${JSON.stringify(obj)}\n\n`);
  };

  const startStream = () => {
    if (streamStarted || res.writableEnded) return;
    streamStarted = true;
    res.writeHead(200, {
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
      ...cors
    });
    writeSse(chunkPayload({ role: 'assistant' }, null));
  };

  const onText = (text) => {
    if (!text) return;
    sawDelta = true;
    textParts.push(text);
    if (stream) {
      startStream();
      writeSse(chunkPayload({ content: text }, null));
    }
  };

  const onReasoning = (text) => {
    if (!text || reasoningParts.join('').length >= MAX_REASONING_CHARACTERS) return;
    const bounded = text.slice(0, MAX_REASONING_CHARACTERS - reasoningParts.join('').length);
    reasoningParts.push(bounded);
    if (stream) {
      startStream();
      writeSse(chunkPayload({ reasoning_content: bounded }, null));
    }
  };

  const handleLine = (line) => {
    line = line.trim();
    if (!line) return;
    let obj;
    try { obj = JSON.parse(line); } catch { return; }
    if (obj && obj.type === 'stream_event' && obj.event) {
      const ev = obj.event;
      if (ev.type === 'content_block_delta' && ev.delta && ev.delta.type === 'text_delta' &&
          typeof ev.delta.text === 'string') {
        onText(ev.delta.text);
      } else if (ev.type === 'content_block_delta' && ev.delta?.type === 'thinking_delta' &&
          typeof ev.delta.thinking === 'string') {
        onReasoning(ev.delta.thinking);
      }
    } else if (obj && obj.type === 'result') {
      resultObj = obj;
    }
  };

  child.stdout.on('data', (chunk) => {
    stdoutRemainder += chunk.toString('utf8');
    let nl;
    while ((nl = stdoutRemainder.indexOf('\n')) >= 0) {
      handleLine(stdoutRemainder.slice(0, nl));
      stdoutRemainder = stdoutRemainder.slice(nl + 1);
    }
  });

  child.on('close', (code) => {
    clearTimeout(timer);
    if (settled || aborted) return;
    settled = true;
    if (stdoutRemainder) handleLine(stdoutRemainder);

    const durationMs = Date.now() - startedAt;
    const cliFailed = code !== 0 || spawnError ||
      (resultObj && (resultObj.is_error === true || (resultObj.subtype && resultObj.subtype !== 'success')));
    const resultText = resultObj && typeof resultObj.result === 'string' ? resultObj.result : '';
    const ok = !timedOut && !cliFailed && (sawDelta || resultText);

    if (ok) {
      const content = sawDelta ? textParts.join('') : resultText;
      const reasoning = reasoningParts.join('').trim();
      const usage = mapUsage(resultObj && resultObj.usage);
      const cost = resultObj && typeof resultObj.total_cost_usd === 'number'
        ? `$${resultObj.total_cost_usd.toFixed(6)}` : 'n/a';
      log(`model=${model} effort=${effort || '-'} stream=${stream} ${durationMs}ms cost=${cost} ok`);
      if (stream) {
        startStream();
        if (!sawDelta && content) writeSse(chunkPayload({ content }, null));
        const final = chunkPayload({}, 'stop', usage || undefined);
        if (!usage) delete final.usage;
        writeSse(final);
        res.write('data: [DONE]\n\n');
        res.end();
      } else {
        const payload = {
          id,
          object: 'chat.completion',
          created,
          model,
          choices: [{
            index: 0,
            message: {
              role: 'assistant',
              content,
              ...(reasoning ? { reasoning_content: reasoning } : {})
            },
            finish_reason: 'stop'
          }]
        };
        if (usage) payload.usage = usage;
        sendJson(res, 200, payload, cors);
      }
      return;
    }

    let message;
    if (timedOut) {
      message = `claude CLI timed out after ${OPTS.timeout}s`;
    } else if (spawnError) {
      message = `failed to spawn claude: ${spawnError.message}`;
    } else if (cliFailed) {
      message = `claude CLI failed (exit ${code})` +
        (resultText ? `: ${resultText.slice(0, 500)}` : '') +
        (!resultText && stderrTail ? `: ${stderrTail.trim().slice(-500)}` : '');
    } else {
      message = 'claude CLI produced no output';
    }
    log(`model=${model} effort=${effort || '-'} stream=${stream} ${durationMs}ms ERROR ${message}`);
    if (streamStarted) {
      writeSse(chunkPayload({ content: `\n\n[bridge error: ${message}]` }, 'stop'));
      res.write('data: [DONE]\n\n');
      res.end();
    } else {
      sendError(res, timedOut ? 504 : 502, message, 'bridge_error', cors);
    }
  });
}

function parseUsage(text) {
  const out = { ok: true, raw: text };
  const grab = (re) => { const m = text.match(re); return m ? m : null; };
  let m = grab(/Current session:\s*(\d+)%\s*used(?:\s*·\s*resets\s*([^\n]+))?/i);
  if (m) out.session = { percent: Number(m[1]), resets: (m[2] || '').trim() };
  m = grab(/Current week \(all models\):\s*(\d+)%\s*used(?:\s*·\s*resets\s*([^\n]+))?/i);
  if (m) out.week = { percent: Number(m[1]), resets: (m[2] || '').trim() };
  m = grab(/Current week \(([^)]*only)\):\s*(\d+)%\s*used(?:\s*·\s*resets\s*([^\n]+))?/i);
  if (m) out.weekModel = { label: m[1].trim(), percent: Number(m[2]), resets: (m[3] || '').trim() };
  return out;
}

let usageCache = null;
let usageInflight = null;
const USAGE_TTL_MS = 45 * 1000;

function getUsage() {
  if (usageCache && (Date.now() - usageCache.at) < USAGE_TTL_MS) {
    return Promise.resolve(usageCache.data);
  }
  if (usageInflight) return usageInflight;
  usageInflight = new Promise((resolve) => {
    execFile(OPTS.claude, ['-p', '/usage'], { timeout: 30000, maxBuffer: 1 << 20 }, (err, stdout, stderr) => {
      usageInflight = null;
      if (err) {
        resolve({ ok: false, error: (err && err.message) || 'usage query failed', raw: String(stderr || '') });
        return;
      }
      const data = parseUsage(String(stdout || ''));
      usageCache = { at: Date.now(), data };
      resolve(data);
    });
  });
  return usageInflight;
}

let claudeVersion = null;

function handleRequest(req, res) {
  const cors = corsHeaders(req);
  const url = (req.url || '/').split('?')[0];

  if (req.method === 'OPTIONS') {
    const headers = {
      ...cors,
      'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
      'Access-Control-Allow-Headers': 'authorization, content-type',
      'Access-Control-Max-Age': '86400'
    };
    if (req.headers['access-control-request-private-network']) {
      headers['Access-Control-Allow-Private-Network'] = 'true';
    }
    res.writeHead(204, headers);
    res.end();
    return;
  }

  if (req.method === 'GET' && url === '/health') {
    return sendJson(res, 200, {
      ok: true,
      service: SERVICE,
      bridgeVersion: BRIDGE_VERSION,
      claudeVersion,
      models: MODELS,
      efforts: EFFORTS,
      images: OPTS.allowImages,
      usage: true,
      fastMode: true
    }, cors);
  }

  if (req.method === 'GET' && url === '/v1/usage') {
    getUsage().then((data) => sendJson(res, 200, data, cors))
      .catch((err) => sendJson(res, 200, { ok: false, error: (err && err.message) || 'usage failed' }, cors));
    return;
  }

  if (req.method === 'GET' && url === '/v1/models') {
    return sendJson(res, 200, {
      object: 'list',
      data: MODELS.map((m) => ({ id: m, object: 'model', owned_by: SERVICE }))
    }, cors);
  }

  if (req.method === 'POST' && url === '/v1/chat/completions') {
    if (!tokenMatches(req.headers.authorization)) {
      return sendError(res, 401, 'missing or invalid bearer token', 'authentication_error', cors);
    }
    const chunks = [];
    let size = 0;
    let rejected = false;
    req.on('data', (chunk) => {
      if (rejected) return;
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        rejected = true;
        chunks.length = 0;
        sendError(res, 413, 'request body exceeds 10 MB', 'invalid_request_error', cors);
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (rejected || res.writableEnded) return;
      let body;
      try {
        body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      } catch (err) {
        return sendError(res, 400, `invalid JSON body: ${err.message}`, 'invalid_request_error', cors);
      }
      if (!body || typeof body !== 'object') {
        return sendError(res, 400, 'request body must be a JSON object', 'invalid_request_error', cors);
      }
      handleChatCompletion(req, res, body);
    });
    req.on('error', () => {});
    return;
  }

  sendError(res, 404, `no route for ${req.method} ${url}`, 'invalid_request_error', cors);
}

mkdirSync(OPTS.cwd, { recursive: true });

execFile(OPTS.claude, ['--version'], { timeout: 15000 }, (err, stdout) => {
  if (err) {
    console.error(`[bridge] warning: "${OPTS.claude} --version" failed (${err.message}) — requests will likely fail`);
  } else {
    claudeVersion = stdout.toString().trim().split('\n')[0] || null;
    console.log(`[bridge] claude CLI: ${claudeVersion}`);
  }
});

const server = http.createServer(handleRequest);
server.requestTimeout = 0;
server.headersTimeout = 60000;
server.listen(OPTS.port, '127.0.0.1', () => {
  console.log(`[bridge] ${SERVICE} v${BRIDGE_VERSION} listening on http://127.0.0.1:${OPTS.port}`);
  console.log(`[bridge] models: ${MODELS.join(', ')} | efforts: ${EFFORTS.join(', ')} | timeout: ${OPTS.timeout}s`);
  console.log(`[bridge] CLI workdir: ${OPTS.cwd}`);
  if (OPTS.token) console.log('[bridge] bearer-token auth ENABLED for POST requests');
  if (EXTRA_ORIGINS.size) console.log(`[bridge] CORS extras: ${[...EXTRA_ORIGINS].join(', ')} (+ any localhost/127.0.0.1 origin)`);
});
server.on('error', (err) => {
  console.error(`[bridge] server error: ${err.message}`);
  process.exit(1);
});
