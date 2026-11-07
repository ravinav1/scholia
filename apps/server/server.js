import http from 'node:http';
import { readFile, open } from 'node:fs/promises';
import { pipeline } from 'node:stream/promises';
import { resolve, extname, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AccountStore, hash } from './store.js';
import { Documents, documentMime } from './documents/documents.js';
import { Workspaces } from './workspaces.js';
const source = dirname(fileURLToPath(import.meta.url));
const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript',
  '.mjs': 'text/javascript',
  '.css': 'text/css',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.gif': 'image/gif',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.bcmap': 'application/octet-stream',
};
const parseCookie = (request) =>
  String(request.headers.cookie || '')
    .split(';')
    .map((v) => v.trim())
    .find((v) => v.startsWith('scholia_session='))
    ?.slice(16);
const httpError = (status, message) => Object.assign(new Error(message), { status });
// GET validators use weak comparison, including a client's comma-separated list.
const matchesETag = (header, etag) => String(header || '').split(',').some((value) =>
  value.trim() === '*' || value.trim().replace(/^W\//, '') === etag.replace(/^W\//, ''));
async function body(request, limit = 135_000_000) {
  if (!String(request.headers['content-type'] || '').startsWith('application/json'))
    throw httpError(415, 'Use a JSON request.');
  if (Number(request.headers['content-length']) > limit)
    throw httpError(413, 'Request is too large.');
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > limit) throw httpError(413, 'Request is too large.');
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks));
  } catch {
    throw httpError(400, 'Invalid JSON.');
  }
}
export function createHostedServer({
  root,
  origin,
  assets = resolve(source, '../../dist/web'),
  secret,
  canvasHosts = ['canvas.ntnu.no'],
  ...options
}) {
  const publicURL = new URL(origin);
  if (
    !['http:', 'https:'].includes(publicURL.protocol) ||
    publicURL.username ||
    publicURL.password ||
    publicURL.pathname !== '/' ||
    publicURL.search ||
    publicURL.hash
  ) {
    throw new Error(
      'SCHOLIA_ORIGIN must be an HTTP or HTTPS origin without a path or credentials.'
    );
  }
  if (
    publicURL.protocol !== 'https:' &&
    !['127.0.0.1', 'localhost', '[::1]'].includes(publicURL.hostname)
  )
    throw new Error('The hosted service requires an HTTPS public origin.');
  const store = new AccountStore(root, { secret }),
    documents = new Documents(root),
    workspaces = new Workspaces(store, documents, { canvasHosts, ...options });
  const secure = publicURL.protocol === 'https:',
    attempts = new Map();
  let authActive = 0,
    uploads = 0,
    closing = false;
  const cookie = (value, expire = false) =>
    `scholia_session=${value}; Path=/; HttpOnly; SameSite=Strict; ${secure ? 'Secure; ' : ''}Max-Age=${expire ? 0 : 604800}`;
  const server = http.createServer(async (request, response) => {
    const writeHeaders = (status, type, headers = {}) => {
      response.writeHead(status, {
        'Content-Type': type,
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
        'Referrer-Policy': 'same-origin',
        'X-Frame-Options': 'DENY',
        'Content-Security-Policy':
          "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; font-src 'self' data:; connect-src 'self'; worker-src 'self' blob:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
        ...(secure ? { 'Strict-Transport-Security': 'max-age=31536000' } : {}),
        ...headers,
      });
    };
    const send = (status, data, type = 'application/json; charset=utf-8', headers = {}) => {
      writeHeaders(status, type, headers);
      response.end(Buffer.isBuffer(data) || typeof data === 'string' ? data : JSON.stringify(data));
    };
    const sendFile = async (file, type, headers = {}, revalidate = false) => {
      const handle = await open(file, 'r');
      try {
        const info = await handle.stat();
        if (!info.isFile()) throw httpError(404, 'Not found.');
        if (revalidate) {
          // Validate the same open file that will be streamed, including a
          // rebuilt asset atomically replacing its previous pathname.
          const etag = `W/"${info.size}-${info.mtimeMs}-${info.ctimeMs}"`;
          headers = { ...headers, ETag: etag };
          if (matchesETag(request.headers['if-none-match'], etag)) {
            send(304, '', type, headers);
            return;
          }
        }
        writeHeaders(200, type, { ...headers, 'Content-Length': info.size });
        if (request.method === 'HEAD') response.end();
        // Backpressure bounds each transfer's buffers even for a 100 MB PDF
        // or a disconnected client; do not materialize the whole file in RAM.
        else await pipeline(handle.createReadStream({ autoClose: false }), response);
      } finally { await handle.close(); }
    };
    const sendAsset = (file, type = types[extname(file)] || 'application/octet-stream') =>
      sendFile(file, type, { 'Cache-Control': 'private, no-cache' }, true);
    try {
      if (closing) throw httpError(503, 'The server is restarting. Try again shortly.');
      if (request.headers.host !== publicURL.host) throw httpError(403, 'Invalid host.');
      const path = new URL(request.url, origin).pathname;
      if (
        (request.headers.origin && request.headers.origin !== publicURL.origin) ||
        request.headers['sec-fetch-site'] === 'cross-site'
      )
        throw httpError(403, 'Cross-site request refused.');
      if (!['GET', 'HEAD', 'POST'].includes(request.method))
        throw httpError(405, 'Method not allowed.');
      if (path === '/healthz') {
        send(200, { ok: true });
        return;
      }
      if (path === '/auth/login' && request.method === 'POST') {
        const value = await body(request, 4096),
          address = request.socket.remoteAddress;
        const keys = [
          address,
          String(value.email || '')
            .trim()
            .toLowerCase(),
        ];
        for (const [key, value] of attempts) if (value.until < Date.now()) attempts.delete(key);
        if (
          authActive >= 4 ||
          attempts.size > 10000 ||
          keys.some((key) => (attempts.get(key)?.count || 0) >= 10)
        )
          throw httpError(429, 'Too many sign-in attempts. Try again in 15 minutes.');
        for (const key of keys)
          attempts.set(key, {
            count: (attempts.get(key)?.count || 0) + 1,
            until: Date.now() + 900000,
          });
        authActive++;
        let login;
        try {
          login = await store.login(value.email, value.password);
        } finally {
          authActive--;
        }
        if (!login) throw httpError(401, 'Email or password is incorrect.');
        for (const key of keys) attempts.delete(key);
        send(200, { ok: true }, undefined, { 'Set-Cookie': cookie(login.value) });
        return;
      }
      const session = store.session(parseCookie(request));
      if (path === '/login' || path === '/auth.js') {
        if (path === '/login' && session) {
          send(303, '', 'text/plain', { Location: '/' });
          return;
        }
        const file = path === '/login' ? 'login.html' : 'auth.js';
        if (path === '/auth.js') await sendAsset(resolve(source, file));
        else send(200, await readFile(resolve(source, file)), types[extname(file)]);
        return;
      }
      if (!session) {
        if (path.startsWith('/api/') || path.startsWith('/auth/'))
          throw httpError(401, 'Sign in to continue.');
        if (['/app.css', '/icon.svg'].includes(path)) {
          await sendAsset(resolve(assets, path.slice(1)));
          return;
        }
        send(303, '', 'text/plain', { Location: '/login' });
        return;
      }
      if (path.startsWith('/api/') || path === '/auth/logout') {
        if (request.headers['x-scholia-token'] !== session.csrf)
          throw httpError(403, 'Reopen Scholia to renew this session.');
        if (path === '/auth/logout' && request.method === 'POST') {
          store.logout(parseCookie(request));
          send(200, { ok: true }, undefined, { 'Set-Cookie': cookie('', true) });
          return;
        }
        if (path === '/api/state' && request.method === 'GET') {
          const data = JSON.stringify(await workspaces.state(session));
          const etag = `"${hash(data)}"`;
          const unchanged = matchesETag(request.headers['if-none-match'], etag);
          // Keep account state out of the browser's HTTP cache. The workspace
          // explicitly retains its last accepted validator in memory instead.
          send(unchanged ? 304 : 200, unchanged ? '' : data, undefined, { ETag: etag });
          return;
        }
        if (path === '/api/learning' && request.method === 'GET') {
          send(200, workspaces.learning.view(workspaces.account(session.user_id), session.navigation));
          return;
        }
        if (path === '/api/learning' && request.method === 'POST') {
          send(200, await workspaces.learningAction(session, await body(request, 100_000)));
          return;
        }
        if (path === '/api/search' && request.method === 'GET') {
          const params = new URL(request.url, origin).searchParams;
          const controller = new AbortController();
          const disconnected = () => { if (!response.writableEnded) controller.abort(); };
          response.once('close', disconnected);
          try {
            const result = await workspaces.search.search(workspaces.account(session.user_id), params.get('q') || '', {
              courseID: params.get('courseID') || '', mode: params.get('mode') || 'all', signal: controller.signal,
            });
            if (!response.destroyed) send(200, result);
          } catch (error) {
            if (!controller.signal.aborted) throw error;
          } finally { response.removeListener('close', disconnected); }
          return;
        }
        const match = path.match(
          /^\/api\/(document|index|edit|image)\/([\da-f-]{36})(?:\/([^/]+))?$/i
        );
        if (match && request.method === 'GET') {
          const account = workspaces.account(session.user_id),
            doc = workspaces.doc(account, match[2]);
          if (match[1] === 'document')
            await sendFile(documents.originalPath(account.id, doc), documentMime(doc), {
              'Content-Disposition': `inline; filename*=UTF-8''${encodeURIComponent(doc.fileName)}`,
            });
          else if (match[1] === 'index') send(200, await documents.index(account.id, doc));
          else if (match[1] === 'edit') send(200, await workspaces.edit(account, doc.id));
          else
            send(
              200,
              await documents.image(account.id, doc, decodeURIComponent(match[3] || '')),
              'image/png'
            );
          return;
        }
        if (path === '/api/exam-recommendation' && request.method === 'POST') {
          if (uploads >= 8) throw httpError(503, 'The server is busy. Try again shortly.');
          uploads++;
          const controller = new AbortController();
          const disconnected = () => { if (!response.writableEnded) controller.abort(); };
          response.once('close', disconnected);
          try {
            const result = await workspaces.recommendExams(session, await body(request, 500_000), controller.signal);
            if (!response.destroyed) send(200, result);
          } finally {
            response.removeListener('close', disconnected);
            uploads--;
          }
          return;
        }
        if (path === '/api/action' && request.method === 'POST') {
          if (uploads >= 8) throw httpError(503, 'The server is busy. Try again shortly.');
          uploads++;
          try {
            send(200, await workspaces.action(session, await body(request)));
          } finally {
            uploads--;
          }
          return;
        }
        throw httpError(404, 'Not found.');
      }
      if (request.method !== 'GET') throw httpError(405, 'Method not allowed.');
      const decoded = decodeURIComponent(path);
      if (decoded.includes('..') || decoded.includes('\\') || decoded.includes('\0'))
        throw httpError(404, 'Not found.');
      const file = resolve(assets, decoded === '/' ? 'index.html' : decoded.slice(1));
      if (!file.startsWith(resolve(assets) + '/')) throw httpError(404, 'Not found.');
      if (file.endsWith('/index.html')) {
        const data = Buffer.from(
          (await readFile(file))
            .toString()
            .replaceAll('__SCHOLIA_TOKEN__', session.csrf)
            .replace(
              '</head>',
              `<meta name="scholia-account" content="${session.user_id}"><meta name="scholia-hosted" content="true"></head>`
            )
        );
        send(200, data, types[extname(file)]);
      } else await sendAsset(file);
    } catch (error) {
      if (!response.headersSent)
        send(error.status || (error.code === 'ENOENT' ? 404 : 400), {
          error: error.code === 'ENOENT' ? 'Not found.' : error.message,
        });
      else response.end();
    }
  });
  server.requestTimeout = 120000;
  server.headersTimeout = 15000;
  server.maxHeadersCount = 50;
  return {
    server,
    store,
    documents,
    workspaces,
    async close() {
      closing = true;
      const closed = new Promise((resolve) => server.close(resolve));
      await workspaces.stop();
      await closed;
      store.close();
    },
  };
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const port = Number(process.env.PORT || 3000),
    origin = process.env.SCHOLIA_ORIGIN || `http://127.0.0.1:${port}`;
  const app = createHostedServer({
    root: resolve(process.env.SCHOLIA_DATA_DIR || '.data'),
    origin,
    secret: process.env.SCHOLIA_SECRET_KEY,
    canvasHosts: (process.env.SCHOLIA_CANVAS_HOSTS || 'canvas.ntnu.no')
      .split(',')
      .map((s) => s.trim()),
  });
  app.server.listen(port, process.env.HOST || '127.0.0.1', () =>
    console.log(`Scholia web listening at ${origin}`)
  );
  for (const signal of ['SIGTERM', 'SIGINT'])
    process.once(signal, async () => {
      await app.close();
      process.exit(0);
    });
}
