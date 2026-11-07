#!/usr/bin/env node
// Five real native-provider queries. Private evidence stays under output/chat-benchmark.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { spawn, execFileSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const output = path.join(root, 'output/chat-benchmark');
const resuming = process.argv.includes('--resume');
const fixture = path.join(output, 'fixture');
const studySource = path.join(os.homedir(), 'Library/Application Support/Scholia/Study');
const sourceSLX = path.join(os.homedir(), 'programming/ttk4100/ttk4100.slx');
const sourceText = path.join(os.homedir(), 'programming/ttk4100/kilder/tekst/35_KybintroKompendium.pdf.txt');
const hash = value => createHash('sha256').update(value).digest('hex');
const write = (file, value) => fs.writeFileSync(path.join(output, file), JSON.stringify(value, null, 2) + '\n');
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server.address().port)));
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
fs.mkdirSync(output, { recursive: true, mode: 0o700 });
if (fs.existsSync(path.join(output, 'run-plan.json')) && !resuming) throw new Error('Existing benchmark run detected; use --resume deliberately.');
if (!resuming) {
fs.mkdirSync(path.join(fixture, 'sources'), { recursive: true });
fs.mkdirSync(path.join(fixture, 'AttachmentText'), { recursive: true });
const library = JSON.parse(fs.readFileSync(path.join(studySource, 'library.json')));
const course = library.courses.find(c => c.id === '168D28A5-D5EB-4AC2-98FF-3B8289672311');
const thread = course.threads.find(t => t.id === 'B540EEB5-7556-4C20-A9FD-A6C9A5F09B55');
const document = course.documents.find(d => d.id === '5D69074A-24FE-4ABE-9F35-D25527BB86F3');
const user = structuredClone(thread.messages.find(m => m.id === 'FDD30DAA-6933-41BE-B739-5ABD808E9F45'));
const copiedSLX = path.join(fixture, 'sources/ttk4100.slx');
fs.copyFileSync(sourceSLX, copiedSLX);
if (hash(fs.readFileSync(copiedSLX)) !== '9da20cab80e6cc298d873ef0d865604715d8382a5843da3f5edfe3aa5adfa9c6') throw new Error('SLX changed since saved-source verification.');
user.attachments[0].sourcePath = copiedSLX;
if (user.attachments[0].textCorpusID) {
  const name = user.attachments[0].textCorpusID + '.txt';
  fs.copyFileSync(path.join(os.homedir(), 'Library/Application Support/Scholia/AttachmentText', name), path.join(fixture, 'AttachmentText', name));
}
const documentDir = path.join(fixture, 'Study/Documents', document.id);
fs.mkdirSync(documentDir, { recursive: true });
for (const name of fs.readdirSync(path.join(studySource, 'Documents', document.id))) {
  if (name === document.fileName || name.endsWith('.json')) fs.copyFileSync(path.join(studySource, 'Documents', document.id, name), path.join(documentDir, name));
}
fs.copyFileSync(path.join(documentDir, document.fileName), path.join(fixture, 'sources/KybintroKompendium.pdf'));
fs.copyFileSync(sourceText, path.join(fixture, 'sources/35_KybintroKompendium.pdf.txt'));
const fixtureLibrary = { ...library, courses: [{ ...course, documents: [document], threads: [{ ...thread, messages: [user], sources: {} }] }] };
fs.writeFileSync(path.join(fixture, 'Study/library.json'), JSON.stringify(fixtureLibrary));
write('fixture-manifest.json', {
  question: user.content, originatingUserMessageID: user.id, attachmentID: user.attachments[0].id,
  savedAttachmentCharacters: user.attachments[0].extractedText.length,
  savedAttachmentExtractionSHA256: hash(user.attachments[0].extractedText),
  slxSHA256: hash(fs.readFileSync(copiedSLX)), pdfSHA256: hash(fs.readFileSync(path.join(documentDir, document.fileName))),
  pageLabelledTextSHA256: hash(fs.readFileSync(sourceText)),
  originalThreadMode: thread.mode, currentPage: 1, includeCourseContext: false, userMessages: 1, assistantMessages: 0,
  fixtureRoot: fixture, sourceFiles: fs.readdirSync(path.join(fixture, 'sources')),
  condition: 'Read-only fixture copies; original saved attachment extraction, not re-extracted source file; no historical assistant context.'
});
execFileSync(path.join(output, 'chat-benchmark-native'), ['prepare'], { cwd: root, env: { ...process.env, CHAT_BENCHMARK_OUTPUT: output }, stdio: 'inherit' });
const seed = randomBytes(4).readUInt32BE();
const lowerModes = ['batched-low', 'batched-medium', 'batched-high'];
for (let i = lowerModes.length - 1; i > 0; i--) { const j = (seed >>> (i * 3)) % (i + 1); [lowerModes[i], lowerModes[j]] = [lowerModes[j], lowerModes[i]]; }
const order = [...(seed % 2 ? ['sequential', 'batched'] : ['batched', 'sequential']), ...lowerModes];
write('run-plan.json', { startedAt: new Date().toISOString(), seed, order, model: 'gpt-6-astra', reasoningEffort: 'max',
  arms: 'Same current native pipeline and immutable prepared input; sequential removes batch instruction lines and batch permission parentheticals only.',
  isolation: 'Identical fixture-root instruction added to both arms. All emitted file operations audited before native execution. No out-of-fixture source access allowed.',
  caveats: ['One sample per arm; stochastic generation and service/cache/load variance.', 'Historical request bodies were not saved; current native preparation summary can be compared with saved historical activity.', 'Account quota is shared with other activity; delta is observational.', 'Proxy buffers each bridge response to audit file operations; first visible answer timing reflects this buffering.'] });
}
const binary = path.join(output, 'chat-benchmark-native');
const plan = JSON.parse(fs.readFileSync(path.join(output, 'run-plan.json')));
const order = plan.order.filter(arm => !fs.existsSync(path.join(output, arm, 'answer.md')));
const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
const same = (a, b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));
function requestBridge(body) {
  return new Promise((resolve, reject) => {
    const request = http.request(bridgeBase + '/v1/chat/completions', { method: 'POST', headers: {
      'content-type': 'application/json', authorization: `Bearer ${token}` } }, response => {
      const chunks = []; const firstByteAt = performance.now();
      response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, contentType: response.headers['content-type'],
        firstByteAt, raw: Buffer.concat(chunks).toString('utf8') }));
      response.on('error', reject);
    });
    request.setTimeout(650_000, () => request.destroy(new Error('Benchmark bridge socket idle for 650 seconds')));
    request.on('error', reject); request.end(JSON.stringify(body));
  });
}
let replayLimit = 0;
const actualCodex = execFileSync('which', ['codex'], { encoding: 'utf8' }).trim();
const wrapper = path.join(output, 'codex-audit.mjs');
fs.writeFileSync(wrapper, `#!${process.execPath}\nimport fs from 'node:fs';import{spawn}from'node:child_process';const a=process.argv.slice(2);if(a.includes('exec')){const configs=a.flatMap((v,i)=>v==='--config'?[a[i+1]]:[]).filter(v=>!v.startsWith('developer_instructions'));fs.appendFileSync(${JSON.stringify(path.join(output, 'cli-invocations.jsonl'))},JSON.stringify({at:new Date().toISOString(),model:a[a.indexOf('--model')+1],configs,ephemeral:a.includes('--ephemeral'),imageCount:a.includes('--image')?a.slice(a.indexOf('--image')+1).length:0})+'\\n');}const c=spawn(${JSON.stringify(actualCodex)},a,{stdio:'inherit',env:process.env});c.on('exit',(code,signal)=>{if(signal)process.kill(process.pid,signal);else process.exit(code??1);});\n`, { mode: 0o700 });
const reservation = http.createServer();
const bridgePort = await listen(reservation); await new Promise(r => reservation.close(r));
const token = randomBytes(24).toString('hex');
const bridgeLog = fs.openSync(path.join(output, 'bridge.log'), resuming ? 'a' : 'w');
const bridge = spawn(process.execPath, [path.join(root, 'scripts/bridges/codex-bridge.mjs'), '--port', String(bridgePort), '--timeout', '600', '--token', token, '--codex', wrapper, '--verbose'], { cwd: root, stdio: ['ignore', bridgeLog, bridgeLog] });
const bridgeBase = `http://127.0.0.1:${bridgePort}`;
let arm = null, count = 0, effort = 'max';
const scopedInstruction = `\nBenchmark source boundary: All general file operations must stay inside ${fixture}. For a search, always set location to that absolute directory or a descendant. Treat that directory as the available source collection. Do not access the original source locations or other home folders. Saved attachment operations remain available. This restriction changes source locations only, not the user's question; answer the question normally.`;
function assertToolScope(call) {
  if (call.operation === 'attachment_batch' || call.operation === 'read_batch') { for (const child of call.requests || []) assertToolScope(child); return; }
  if (['attachment_search', 'attachment_read'].includes(call.operation)) return;
  if (!['read', 'search', 'list'].includes(call.operation)) throw new Error(`Forbidden benchmark operation ${call.operation}`);
  const target = call.operation === 'search' ? call.location : call.path;
  if (!target || !path.isAbsolute(target)) throw new Error(`Missing absolute fixture location: ${JSON.stringify(call)}`);
  const resolved = path.resolve(target);
  if (resolved !== fixture && !resolved.startsWith(fixture + path.sep)) throw new Error(`File operation escaped fixture: ${JSON.stringify(call)}`);
}
const proxy = http.createServer(async (req, res) => {
  try {
    const chunks = []; for await (const chunk of req) chunks.push(chunk);
    let body = Buffer.concat(chunks);
    if (req.method !== 'POST') {
      const response = await fetch(bridgeBase + req.url, { headers: { authorization: `Bearer ${token}` } });
      res.writeHead(response.status, { 'content-type': response.headers.get('content-type') || 'application/json' }); res.end(Buffer.from(await response.arrayBuffer())); return;
    }
    const index = ++count, prefix = `${arm}/round-${String(index).padStart(2, '0')}`;
    const native = JSON.parse(body);
    if (index <= replayLimit) {
      const prior = JSON.parse(fs.readFileSync(path.join(output, prefix + '-native-request.json')));
      if (!same(native, prior)) throw new Error(`Replay input differs at ${prefix}`);
      const raw = fs.readFileSync(path.join(output, prefix + '-response.sse'));
      fs.appendFileSync(path.join(output, arm, 'replay-audit.jsonl'), JSON.stringify({ round: index, at: new Date().toISOString(), identicalInput: true, inference: false }) + '\n');
      res.writeHead(200, { 'content-type': 'text/event-stream' }); res.end(raw); return;
    }
    write(prefix + '-native-request.json', native);
    const forwarded = structuredClone(native);
    for (const message of forwarded.messages.filter(m => m.role === 'system')) {
      if (typeof message.content !== 'string') throw new Error('Unexpected system content type');
      if (arm === 'sequential') message.content = message.content.split('\n').filter(line => !line.trim().startsWith('{"operation":"read_batch"') && !line.trim().startsWith('{"operation":"attachment_batch"')).join('\n')
        .replace('ONE operation (or one read_batch containing independent operations)', 'ONE operation')
        .replace('ONE operation (or one attachment_batch of independent operations)', 'ONE operation');
      message.content += scopedInstruction;
    }
    if (forwarded.model !== 'gpt-6-astra' || forwarded.reasoning_effort !== effort) throw new Error('Requested model/effort changed');
    write(prefix + '-forwarded-request.json', forwarded);
    const start = performance.now(), at = new Date().toISOString();
    const response = await requestBridge(forwarded);
    const firstByteSeconds = (response.firstByteAt - start) / 1000;
    const raw = response.raw; fs.writeFileSync(path.join(output, prefix + '-response.sse'), raw);
    let text = '', usage = null, providerSeconds = null;
    const events = raw.split('\n').filter(line => line.startsWith('data: ') && !line.includes('[DONE]')).flatMap(line => { try { return [JSON.parse(line.slice(6))]; } catch { return []; } });
    for (const event of events) {
      text += event.choices?.[0]?.delta?.content || '';
      if (event.usage) usage = event.usage;
      if (event.scholia_usage) providerSeconds = event.scholia_usage.elapsed_seconds;
    }
    let tool = null;
    if (text.trim().startsWith('<scholia_file_tool>')) {
      tool = JSON.parse(text.trim().slice('<scholia_file_tool>'.length, -'</scholia_file_tool>'.length));
      assertToolScope(tool);
      if (arm === 'sequential' && ['read_batch', 'attachment_batch'].includes(tool.operation)) throw new Error('Sequential arm emitted unadvertised batch operation');
    }
    const expanded = tool ? (tool.requests?.length || 1) : 0;
    write(prefix + '-metrics.json', { arm, index, startedAt: at, seconds: (performance.now() - start) / 1000, firstByteSeconds,
      status: response.status, usage, providerSeconds, tool, expandedOperations: expanded, responseCharacters: text.length,
      requestBytes: Buffer.byteLength(JSON.stringify(forwarded)), responseBytes: Buffer.byteLength(raw) });
    fs.writeFileSync(path.join(output, prefix + '-text.txt'), text);
    res.writeHead(response.status, { 'content-type': response.contentType || 'text/event-stream' }); res.end(raw);
  } catch (error) {
    fs.appendFileSync(path.join(output, 'violations.jsonl'), JSON.stringify({ at: new Date().toISOString(), arm, round: count, error: error.message }) + '\n');
    res.writeHead(500, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: { message: error.message } }));
  }
});
const proxyPort = await listen(proxy);
async function quota(name) {
  try { const r = await fetch(bridgeBase + '/v1/usage?fresh=1', { headers: { authorization: `Bearer ${token}` } }); write(name, { at: new Date().toISOString(), status: r.status, data: await r.json() }); }
  catch (e) { write(name, { at: new Date().toISOString(), error: e.message }); }
}
try {
  for (let i = 0; ; i++) { try { if ((await fetch(bridgeBase + '/health')).ok) break; } catch {} if (i > 100) throw new Error('Bridge readiness timed out'); await sleep(100); }
  write('bridge-health.json', await (await fetch(bridgeBase + '/health')).json());
  await quota(resuming ? 'quota-resume-before.json' : 'quota-before.json');
  for (const current of order) {
    arm = current; count = 0; effort = arm.startsWith('batched-') ? arm.slice('batched-'.length) : 'max'; fs.mkdirSync(path.join(output, arm), { recursive: true });
    replayLimit = 0;
    while (fs.existsSync(path.join(output, arm, `round-${String(replayLimit + 1).padStart(2, '0')}-metrics.json`))) replayLimit++;
    const recovered = replayLimit > 0;
    if (recovered) {
      const failedPath = path.join(output, arm, 'native-result.json');
      if (fs.existsSync(failedPath)) {
        const failed = JSON.parse(fs.readFileSync(failedPath));
        fs.copyFileSync(failedPath, path.join(output, arm, 'aborted-native-result.json'));
        write(`${arm}/recovery.json`, { reason: 'Benchmark fetch transport failed after its 300-second header wait; production native timeout was not reached.',
          startedAt: new Date().toISOString(), replayedSourceRounds: replayLimit, interruptedRound: replayLimit + 1,
          originalAttemptElapsedSeconds: failed.elapsedSeconds, completedPrefixElapsedSeconds: failed.progress.at(-1).seconds,
          caveat: 'Successful source responses are replayed free, with exact native request equality asserted. Interrupted call is rerun; abandoned consumption is unknown. Timing is reconstructed, not uninterrupted.' });
      }
    }
    await quota(`${arm}/${recovered ? 'recovery-' : ''}quota-before.json`);
    console.log(`LIVE START ${arm} ${new Date().toISOString()}`);
    const code = await new Promise(resolve => {
      const child = spawn(binary, [], { cwd: root, env: { ...process.env, CHAT_BENCHMARK_OUTPUT: output, CHAT_BENCHMARK_ARM: arm,
        CHAT_BENCHMARK_ENDPOINT: `http://127.0.0.1:${proxyPort}/v1/chat/completions`, CHAT_BENCHMARK_TOKEN: token, CHAT_BENCHMARK_EFFORT: effort }, stdio: ['ignore', 'pipe', 'pipe'] });
      const log = fs.createWriteStream(path.join(output, arm, recovered ? 'recovered-native.log' : 'native.log'));
      child.stdout.on('data', b => { process.stdout.write(b); log.write(b); });
      child.stderr.on('data', b => { process.stderr.write(b); log.write(b); });
      child.on('exit', code => { log.end(); resolve(code); });
    });
    await quota(`${arm}/${recovered ? 'recovery-' : ''}quota-after.json`);
    if (recovered && code === 0) {
      const result = JSON.parse(fs.readFileSync(path.join(output, arm, 'native-result.json')));
      const recovery = JSON.parse(fs.readFileSync(path.join(output, arm, 'recovery.json')));
      const waits = result.progress.filter(event => event.message.startsWith('Waiting for'));
      recovery.recoveredProcessElapsedSeconds = result.elapsedSeconds;
      recovery.replayedPrefixElapsedSeconds = waits[replayLimit].seconds;
      recovery.reconstructedElapsedSeconds = recovery.completedPrefixElapsedSeconds + result.elapsedSeconds - recovery.replayedPrefixElapsedSeconds;
      write(`${arm}/recovery.json`, recovery);
    }
    if (code !== 0) console.error(`${arm} native run failed (${code}); preserving failure and continuing other selected efforts.`);
  }
  await quota('quota-after.json');
  write('completed.json', { completedAt: new Date().toISOString(), order });
} finally {
  proxy.close(); bridge.kill('SIGTERM'); fs.closeSync(bridgeLog);
}
