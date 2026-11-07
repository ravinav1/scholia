import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { cp, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { onePagePdf } from '../tests/helpers/pdf.js';
import { chromiumSession, sleep } from './smoke/browser/lib/chromium.mjs';

const pdf = onePagePdf('PDF navigation still works.');
const requests = [];
const server = createServer((request, response) => {
  const url = new URL(request.url, 'http://localhost');
  requests.push(url.pathname);
  if (url.pathname === '/notes.pdf') {
    response.writeHead(200, { 'Content-Type': 'application/pdf' });
    response.end(pdf);
    return;
  }
  response.writeHead(200, { 'Content-Type': 'text/html' });
  response.end(`<!doctype html>
    <title>Chat</title>
    <h1>Chat fixture</h1>
    <div id="prompt" role="textbox" contenteditable="true"></div>
    <p id="sent"></p>
    <script>
      const editor = document.querySelector('#prompt');
      const mode = new URL(location.href).searchParams.get('mode') || 'path';
      if (location.pathname.startsWith('/chat/')) {
        document.title = decodeURIComponent(location.pathname.slice('/chat/'.length));
        document.querySelector('#sent').textContent = 'Message sent';
      }
      editor.addEventListener('keydown', event => {
        if (event.key !== 'Enter' || event.shiftKey) return;
        event.preventDefault();
        const prompt = editor.textContent;
        document.title = prompt;
        if (mode === 'path') location.assign('/chat/' + encodeURIComponent(prompt));
        else {
          const next = mode === 'query' ? '/chat?q=' + encodeURIComponent(prompt)
            : mode === 'hash' ? '/chat#' + encodeURIComponent(prompt) : location.href;
          history.pushState({}, '', next);
          document.querySelector('#sent').textContent = 'Message sent';
        }
      });
    </script>`);
});

const root = await mkdtemp(join(tmpdir(), 'scholia-pdf-auto-open-'));
let browser;
try {
  // Exercise the compatibility handoff even on Chromium versions with a MIME
  // API. Only the disposable copy omits native MIME registration.
  const extensionPath = join(root, 'extension');
  await cp(resolve('dist/chrome'), extensionPath, { recursive: true });
  const manifestPath = join(extensionPath, 'manifest.json');
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
  delete manifest.mime_types_handler;
  await writeFile(manifestPath, JSON.stringify(manifest));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  browser = await chromiumSession({ extensionPath });
  const { send, evaluate, until } = browser;
  const { targetInfos } = await send('Target.getTargets');
  const worker = targetInfos.find(target => target.type === 'service_worker' && target.url.endsWith('/service-worker.js'));
  assert.ok(worker, 'Scholia service worker loaded');
  for (const linked of [false, true]) {
    for (const mode of ['path', 'query', 'hash', 'title']) {
      await send('Page.navigate', { url: `${origin}/chat?mode=${mode}` });
      await until('document.readyState === "complete" && document.querySelector("#prompt")');
      await evaluate(`(() => {
        const editor = document.querySelector('#prompt');
        editor.textContent = 'Explain this PDF: ';
        const url = location.origin + '/notes.pdf';
        if (${linked}) {
          const link = document.createElement('a'); link.href = url; link.textContent = url; editor.append(link);
        } else editor.append(url);
        editor.focus();
        const range = document.createRange(); range.selectNodeContents(editor); range.collapse(false);
        const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
      })()`);
      await send('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
      await send('Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
      await until('document.readyState === "complete" && document.querySelector("#sent")?.textContent === "Message sent"');
      // Give the delayed handoff time to run after real navigation/title events.
      await sleep(900);
      assert.equal(await evaluate('document.contentType'), 'text/html', `${mode}, linked=${linked}`);
      assert.equal(await evaluate('document.querySelector("#sent")?.textContent'), 'Message sent', `${mode}, linked=${linked}`);
      assert.ok((await evaluate('location.href')).startsWith(`${origin}/chat`));
    }
  }
  assert.equal(requests.filter(path => path === '/notes.pdf').length, 0, 'Sending a PDF link does not fetch the PDF');
  assert.equal((await send('Target.getTargets')).targetInfos.some(target => target.url.includes('/pdf-viewer.html')), false,
    'Sending a PDF link does not open a reader tab or frame');

  await send('Page.navigate', { url: `${origin}/notes.pdf` });
  await until('location.href.includes("/pdf-viewer.html?source=") && document.querySelector(".textLayer span")');
  assert.match(await evaluate('document.querySelector(".textLayer").textContent'), /PDF navigation still works/);
  assert.deepEqual(browser.errors, []);
  console.log('Passed: Enter sends 8 trailing-link prompts without opening a PDF; direct PDF navigation still opens the reader.');
} finally {
  await browser?.close();
  await new Promise(resolve => server.close(resolve));
  await rm(root, { recursive: true, force: true });
}
