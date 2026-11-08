import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
export const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
export async function chromiumSession({ extensionPath = '' } = {}) {
  const profile = await mkdtemp(join(tmpdir(), 'scholia-chromium-'));
  const reserve = createServer();
  await new Promise((resolve) => reserve.listen(0, '127.0.0.1', resolve));
  const port = reserve.address().port;
  await new Promise((resolve) => reserve.close(resolve));
  const binary =
    process.env.CHROMIUM_BIN ||
    (process.platform === 'darwin'
      ? '/Applications/Chromium.app/Contents/MacOS/Chromium'
      : 'chromium');
  if (!/chromium/i.test(binary) || /brave/i.test(binary))
    throw new Error('Use Chromium for repository browser verification.');
  const processHandle = spawn(
    binary,
    [
      '--headless=new',
      '--no-first-run',
      '--disable-default-apps',
      '--disable-gpu',
      ...(process.env.SCHOLIA_CHROMIUM_NO_SANDBOX === '1' ? ['--no-sandbox'] : []),
      `--remote-debugging-port=${port}`,
      `--user-data-dir=${profile}`,
      ...(extensionPath ? [`--disable-extensions-except=${extensionPath}`, `--load-extension=${extensionPath}`] : []),
      'about:blank',
    ],
    { stdio: ['ignore', 'ignore', 'pipe'] }
  );
  let launchError = '';
  processHandle.stderr.on('data', chunk => { launchError = (launchError + chunk).slice(-8000); });
  processHandle.on('error', error => { launchError = error.message; });
  let socket;
  const close = async () => {
    socket?.close();
    processHandle.kill('SIGTERM');
    await new Promise((resolve) => {
      if (processHandle.exitCode !== null || processHandle.signalCode !== null) resolve();
      else {
        processHandle.once('exit', resolve);
        setTimeout(resolve, 3000).unref();
      }
    });
    if (processHandle.exitCode === null && processHandle.signalCode === null) {
      processHandle.kill('SIGKILL');
      await new Promise(resolve => {
        processHandle.once('exit', resolve);
        setTimeout(resolve, 1000).unref();
      });
    }
    // Chromium child processes can finish a final preferences write just after
    // the browser process exits. Retry only bounded transient filesystem races.
    await rm(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 100 });
  };
  try {
    let ready = false;
    for (let i = 0; i < 100; i++) {
      try {
        if ((await fetch(`http://127.0.0.1:${port}/json/version`)).ok) {
          ready = true;
          break;
        }
      } catch {}
      await sleep(100);
    }
    if (!ready) throw new Error(`Chromium did not start: ${launchError || 'no launch diagnostics'}`);
    const target = await (
      await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })
    ).json();
    socket = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((resolve, reject) => {
      socket.addEventListener('open', resolve, { once: true });
      socket.addEventListener('error', reject, { once: true });
    });
    let next = 0;
    const pending = new Map(),
      errors = [];
    socket.addEventListener('message', (event) => {
      const value = JSON.parse(event.data);
      if (value.method === 'Runtime.exceptionThrown') errors.push(value.params);
      const callback = pending.get(value.id);
      if (!callback) return;
      pending.delete(value.id);
      clearTimeout(callback.timer);
      value.error
        ? callback.reject(new Error(value.error.message))
        : callback.resolve(value.result);
    });
    const send = (method, params = {}, sessionId) =>
      new Promise((resolve, reject) => {
        const id = ++next,
          timer = setTimeout(() => reject(new Error(`Chromium timed out: ${method}`)), 20000);
        pending.set(id, { resolve, reject, timer });
        socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
      });
    const evaluate = async (expression, sessionId) => {
      const result = await send('Runtime.evaluate', {
        expression,
        awaitPromise: true,
        returnByValue: true,
      }, sessionId);
      if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails));
      return result.result.value;
    };
    const until = async (expression, { timeoutMs = 15_000, sessionId } = {}) => {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        if (await evaluate(expression, sessionId)) return;
        await sleep(100);
      }
      throw new Error(`Timed out: ${expression}`);
    };
    await send('Runtime.enable');
    await send('Page.enable');
    return {
      send,
      evaluate,
      until,
      errors,
      close,
      click: (selector) => evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`),
      screenshot: async (path) => {
        const { data } = await send('Page.captureScreenshot', { format: 'png' });
        await writeFile(path, Buffer.from(data, 'base64'));
      },
    };
  } catch (error) {
    await close();
    throw error;
  }
}
