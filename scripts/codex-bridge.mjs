#!/usr/bin/env node
/**
 * OpenAI-compatible loopback bridge for a locally authenticated Codex CLI.
 * Every completion is ephemeral, read-only, and non-interactive. Web search is
 * enabled only for a request that explicitly opts in. Base64 image blocks are
 * materialized only for the lifetime of the matching Codex process and passed
 * through `codex exec --image`.
 */
import { execFile, spawn } from 'node:child_process';
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import http from 'node:http';
import os from 'node:os';
import { buildCodexExecArguments } from './lib/codex-cli-arguments.mjs';
import { materializeCodexImages } from './lib/codex-images.mjs';
import { createCodexModelCatalog } from './lib/codex-model-catalog.mjs';
import { codexCompletionUsage, createCodexUsageReader } from './lib/codex-usage.mjs';

const MODELS = [
  'gpt-5.5',
  'gpt-6-astra',
  'gpt-6-sol',
  'gpt-6-luna',
  'gpt-5.6-sol',
  'gpt-5.6-terra',
  'gpt-5.6-luna',
  'gpt-5.4',
  'gpt-5.4-mini'
];
const EFFORTS = ['minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'];
const MAX_BODY_BYTES = 10 * 1024 * 1024;
const BRIDGE_VERSION = '0.9.0';
const MAX_REASONING_CHARACTERS = 24_000;
const LOCAL_ORIGIN = /^https?:\/\/(?:localhost|127\.0\.0\.1)(?::\d+)?$/i;
const EXTENSION_ORIGIN = /^chrome-extension:\/\/[a-p]{32}$/i;

function parseArguments(argv) {
  const options = {
    port: 8789,
    codex: 'codex',
    timeout: 600,
    token: '',
    cors: [],
    verbose: false
  };
  const valueOptions = new Set(['--port', '--codex', '--timeout', '--token', '--cors']);
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--help' || argument === '-h') {
      console.log(
        'Usage: node scripts/codex-bridge.mjs [--port N] [--codex PATH] '
        + '[--timeout SECONDS] [--token SECRET] [--cors ORIGINS] [--verbose]'
      );
      process.exit(0);
    }
    if (argument === '--verbose') {
      options.verbose = true;
      continue;
    }
    if (!valueOptions.has(argument)) throw new Error(`Unknown option: ${argument}`);
    const value = argv[++index];
    if (value == null) throw new Error(`${argument} requires a value.`);
    if (argument === '--port') options.port = Number(value);
    else if (argument === '--timeout') options.timeout = Number(value);
    else if (argument === '--cors') options.cors.push(...value.split(',').map((origin) => origin.trim()).filter(Boolean));
    else options[argument.slice(2)] = value;
  }

  if (!Number.isInteger(options.port) || options.port < 1 || options.port > 65_535) {
    throw new Error('--port must be an integer between 1 and 65535.');
  }
  if (!Number.isFinite(options.timeout) || options.timeout <= 0) {
    throw new Error('--timeout must be a positive number.');
  }
  return options;
}

const options = parseArguments(process.argv.slice(2));
const modelCatalog = createCodexModelCatalog({ codex: options.codex, fallback: MODELS });
const usageReader = createCodexUsageReader({ codex: options.codex });
const allowedOrigins = new Set([
  'https://folk.ntnu.no',
  'https://heaps0rt.github.io',
  ...options.cors
]);

function corsHeaders(request) {
  const origin = request.headers.origin || '';
  if (LOCAL_ORIGIN.test(origin) || EXTENSION_ORIGIN.test(origin) || allowedOrigins.has(origin)) {
    return { 'Access-Control-Allow-Origin': origin, Vary: 'Origin' };
  }
  return { Vary: 'Origin' };
}

function authorizationMatches(header) {
  if (!options.token) return true;
  const match = /^Bearer\s+(.+)$/i.exec(header || '');
  if (!match) return false;
  const supplied = createHash('sha256').update(match[1]).digest();
  const expected = createHash('sha256').update(options.token).digest();
  return timingSafeEqual(supplied, expected);
}

function sendJson(response, status, value, headers = {}) {
  if (response.writableEnded || response.headersSent) return;
  const body = JSON.stringify(value);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    ...headers
  });
  response.end(body);
}

function sendError(response, status, message, headers) {
  sendJson(response, status, { error: { message, type: 'bridge_error' } }, headers);
}

function messageText(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return String(content || '');
  return content
    .filter((part) => part?.type === 'text' && typeof part.text === 'string')
    .map((part) => part.text)
    .join('\n');
}

function buildPrompt(messages, { webSearch = false } = {}) {
  const transcript = messages
    .filter((message) => message && ['user', 'assistant'].includes(message.role))
    .map((message) => {
      const role = message.role === 'assistant' ? 'Assistant' : message.role === 'system' ? 'System' : 'User';
      return `${role}: ${messageText(message.content)}`;
    })
    .join('\n\n');
  const boundary = webSearch
    ? 'Web search is enabled for this request. Use it when it helps answer the question and preserve source links. Do not inspect files, run commands, use other tools, or modify the workspace.'
    : 'Do not inspect files, run commands, use tools, or modify the workspace.';
  return `${transcript}\n\nFollow the system message's response format, including a Scholia file-operation block if requested. Scholia executes those blocks itself; they do not authorize native CLI tools. ${boundary}`;
}

function reasoningItemText(item) {
  if (!item || item.type !== 'reasoning') return '';
  if (typeof item.text === 'string') return item.text;
  if (typeof item.summary === 'string') return item.summary;
  for (const value of [item.summary, item.content]) {
    if (!Array.isArray(value)) continue;
    const text = value
      .map((part) => typeof part === 'string' ? part : part?.text || part?.summary || '')
      .filter(Boolean)
      .join('\n\n');
    if (text) return text;
  }
  return '';
}

function stopChild(child) {
  try {
    child.kill('SIGTERM');
  } catch {
    return null;
  }
  const timer = setTimeout(() => {
    try { child.kill('SIGKILL'); } catch {}
  }, 3_000);
  timer.unref();
  return timer;
}

function completion(request, response, body) {
  const startedAt = performance.now();
  const headers = corsHeaders(request);
  if (!Array.isArray(body.messages) || !body.messages.length) {
    sendError(response, 400, 'messages must be a non-empty array', headers);
    return;
  }

  const model = typeof body.model === 'string' && body.model ? body.model : MODELS[0];
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]*$/.test(model)) {
    sendError(response, 400, 'invalid model', headers);
    return;
  }
  const modelReasoning = modelCatalog.peek().find((entry) => entry.id === model)?.reasoning;
  const supportedEfforts = modelReasoning?.efforts || EFFORTS;
  const effort = supportedEfforts.includes(body.reasoning_effort) ? body.reasoning_effort : modelReasoning?.default || 'high';
  const webSearch = body.web_search === true;
  let imageFiles;
  try {
    imageFiles = materializeCodexImages(body.messages);
  } catch (error) {
    sendError(response, 400, error.message || 'Invalid image attachment.', headers);
    return;
  }
  const cliArguments = buildCodexExecArguments({
    model,
    effort,
    fastMode: body.fast_mode === true || body.fast === true,
    webSearch,
    systemInstructions: body.messages.filter((message) => message?.role === 'system')
      .map((message) => messageText(message.content)).join('\n\n'),
    imagePaths: imageFiles.paths
  });
  let child;
  try {
    child = spawn(options.codex, cliArguments, {
      cwd: os.tmpdir(),
      stdio: ['pipe', 'pipe', 'pipe'],
      env: process.env
    });
  } catch (error) {
    imageFiles.cleanup();
    sendError(response, 502, `Codex CLI failed: ${error.message}`, headers);
    return;
  }

  let answer = '';
  let completionUsage;
  const reasoningParts = [];
  let buffer = '';
  let stderr = '';
  let spawnError = null;
  let timedOut = false;
  let disconnected = false;
  let webSearchUsed = false;
  let forceKillTimer = null;
  let turnFailure = '';
  let finalized = false;
  let cleaned = false;
  const startStream = () => {
    if (body.stream !== true || response.headersSent) return;
    response.writeHead(200, { 'Content-Type': 'text/event-stream; charset=utf-8', 'Cache-Control': 'no-cache', ...headers });
  };
  const reportActivity = (title, detail = '') => {
    if (body.stream !== true || finalized || disconnected) return;
    startStream();
    response.write(`data: ${JSON.stringify({ scholia_activity: { title, detail: String(detail).slice(0, 2000) } })}\n\n`);
  };
  const timeout = setTimeout(() => {
    timedOut = true;
    forceKillTimer = stopChild(child);
  }, options.timeout * 1_000);

  const cleanupImages = () => {
    if (cleaned) return;
    cleaned = true;
    imageFiles.cleanup();
  };

  const finish = ({ code = null, turnCompleted = false } = {}) => {
    if (finalized || disconnected) return;
    if (!turnCompleted && code == null) return;
    finalized = true;
    usageReader.invalidate();
    clearTimeout(timeout);
    cleanupImages();

    if (timedOut || turnFailure || (code != null && code !== 0) || spawnError || !answer) {
      const errorLines = stderr.trim().split('\n').map((line) => line.trim()).filter(Boolean);
      const usefulError = errorLines.find((line) => /^error:/i.test(line))
        || errorLines.find((line) => !/^warning:/i.test(line));
      const detail = timedOut
        ? `Codex timed out after ${options.timeout} seconds.`
        : turnFailure || spawnError?.message || usefulError || `Codex exited with status ${code}.`;
      if (response.headersSent) {
        response.write(`data: ${JSON.stringify({ error: { message: `Codex CLI failed: ${detail}` } })}\n\n`);
        response.end('data: [DONE]\n\n');
      } else sendError(response, timedOut ? 504 : 502, `Codex CLI failed: ${detail}`, headers);
    } else {
      const id = `chatcmpl-${randomUUID()}`;
      const created = Math.floor(Date.now() / 1_000);
      const reasoning = reasoningParts.join('\n\n').slice(0, MAX_REASONING_CHARACTERS);
      const usageFields = {
        ...(completionUsage ? { usage: completionUsage } : {}),
        scholia_usage: { elapsed_seconds: (performance.now() - startedAt) / 1_000 }
      };
      if (body.stream === true) {
        startStream();
        const chunk = {
          id,
          object: 'chat.completion.chunk',
          created,
          model,
          web_search_used: webSearchUsed,
          choices: [{
            index: 0,
            delta: {
              role: 'assistant',
              content: answer,
              ...(reasoning ? { reasoning_content: reasoning } : {})
            },
            finish_reason: null
          }]
        };
        const done = {
          ...chunk,
          ...usageFields,
          choices: [{ index: 0, delta: {}, finish_reason: 'stop' }]
        };
        response.write(`data: ${JSON.stringify(chunk)}\n\n`);
        response.write(`data: ${JSON.stringify(done)}\n\n`);
        response.end('data: [DONE]\n\n');
      } else {
        sendJson(response, 200, {
          id,
          object: 'chat.completion',
          ...usageFields,
          created,
          model,
          web_search_used: webSearchUsed,
          choices: [{
            index: 0,
            message: {
              role: 'assistant',
              content: answer,
              ...(reasoning ? { reasoning_content: reasoning } : {})
            },
            finish_reason: 'stop'
          }]
        }, headers);
      }
      if (options.verbose) console.log(`[codex-bridge] model=${model} effort=${effort} webSearch=${webSearch} ok`);
    }

    // `codex exec` has occasionally lingered after its completed-turn event.
    // The result is final at this point, so do not make the browser wait for
    // process shutdown before receiving it.
    if (turnCompleted && child.exitCode == null) forceKillTimer = stopChild(child);
  };

  const handleLine = (line) => {
    try {
      const event = JSON.parse(line);
      const item = event.item || event;
      if (/web_search/i.test(String(item.type || event.type || item.name || ''))) {
        webSearchUsed = true;
        const query = item.query || item.action?.query || (Array.isArray(item.action?.queries) ? item.action.queries.join('\n') : '');
        reportActivity(event.type === 'item.completed' ? 'Web search complete' : 'Searching the web', query);
      }
      if (item.type === 'agent_message' && typeof item.text === 'string') answer = item.text;
      if (event.type === 'item.completed' && item.type === 'reasoning') {
        const reasoning = reasoningItemText(item).trim();
        if (reasoning) reasoningParts.push(reasoning);
      }
      if (event.type === 'turn.failed') {
        turnFailure = String(event.error?.message || event.message || 'The Codex turn failed.');
        finish({ turnCompleted: true });
      } else if (event.type === 'turn.completed') {
        completionUsage = codexCompletionUsage(event.usage);
        finish({ turnCompleted: true });
      }
    } catch {}
  };

  child.stdin.on('error', () => {});
  child.stdin.end(buildPrompt(body.messages, { webSearch }));
  child.stdout.on('data', (chunk) => {
    buffer += chunk.toString('utf8');
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      handleLine(buffer.slice(0, newline));
      buffer = buffer.slice(newline + 1);
    }
  });
  child.stderr.on('data', (chunk) => { stderr = (stderr + chunk).slice(-4_000); });
  child.on('error', (error) => { spawnError = error; });
  response.on('close', () => {
    if (!response.writableEnded) {
      disconnected = true;
      clearTimeout(timeout);
      cleanupImages();
      forceKillTimer = stopChild(child);
    }
  });

  child.on('close', (code) => {
    if (forceKillTimer) clearTimeout(forceKillTimer);
    if (finalized || disconnected) return;
    if (buffer.trim()) handleLine(buffer);
    finish({ code });
  });
}

function readCompletionBody(request, response, headers) {
  const chunks = [];
  let size = 0;
  let rejected = false;
  request.on('data', (chunk) => {
    if (rejected) return;
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      rejected = true;
      chunks.length = 0;
      sendError(response, 413, 'request body exceeds 10 MB', headers);
      return;
    }
    chunks.push(chunk);
  });
  request.on('end', () => {
    if (rejected || response.writableEnded) return;
    try {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (!body || typeof body !== 'object') throw new Error('request body must be a JSON object');
      completion(request, response, body);
    } catch (error) {
      sendError(response, 400, `invalid request: ${error.message}`, headers);
    }
  });
  request.on('error', () => {});
}

let codexVersion = null;
const server = http.createServer((request, response) => {
  const url = new URL(request.url || '/', 'http://127.0.0.1');
  const headers = corsHeaders(request);

  if (request.method === 'OPTIONS') {
    response.writeHead(204, {
      ...headers,
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'content-type, authorization',
      'Access-Control-Allow-Private-Network': 'true'
    });
    response.end();
    return;
  }
  if (request.method === 'GET' && url.pathname === '/health') {
    sendJson(response, 200, {
      ok: true,
      service: 'codex-bridge',
      bridgeVersion: BRIDGE_VERSION,
      version: codexVersion,
      models: modelCatalog.peek().map((model) => model.id),
      efforts: EFFORTS,
      images: true,
      fastMode: true,
      webSearch: true
    }, headers);
    return;
  }
  if (request.method === 'GET' && url.pathname === '/v1/usage') {
    if (!authorizationMatches(request.headers.authorization)) {
      sendError(response, 401, 'missing or invalid bearer token', headers);
      return;
    }
    usageReader.read({ fresh: url.searchParams.get('fresh') === '1' }).then((result) =>
      sendJson(response, result.ok ? 200 : 502, result, { ...headers, 'Cache-Control': 'no-store' }));
    return;
  }
  if (request.method === 'GET' && url.pathname === '/v1/models') {
    if (!authorizationMatches(request.headers.authorization)) {
      sendError(response, 401, 'missing or invalid bearer token', headers);
      return;
    }
    modelCatalog.read().then((data) => sendJson(response, 200, { object: 'list', data }, headers));
    return;
  }
  if (request.method === 'POST' && url.pathname === '/v1/chat/completions') {
    if (!authorizationMatches(request.headers.authorization)) {
      sendError(response, 401, 'missing or invalid bearer token', headers);
      return;
    }
    readCompletionBody(request, response, headers);
    return;
  }
  sendError(response, 404, 'not found', headers);
});

server.requestTimeout = 0;
server.headersTimeout = 60_000;
execFile(options.codex, ['--version'], { timeout: 15_000 }, (error, stdout) => {
  codexVersion = error ? null : stdout.trim();
});
server.listen(options.port, '127.0.0.1', () => {
  console.log(`[codex-bridge] listening on http://127.0.0.1:${options.port}`);
});
server.on('error', (error) => {
  console.error(`[codex-bridge] server error: ${error.message}`);
  process.exitCode = 1;
});
