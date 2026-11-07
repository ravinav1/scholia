import assert from 'node:assert/strict';
import { join } from 'node:path';
import { chromiumSession } from './lib/chromium.mjs';

const browser = await chromiumSession();
const { send, evaluate, until, click } = browser;
try {
  await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 880, deviceScaleFactor: 1, mobile: false });
  await send('Page.navigate', { url: process.argv[2] });
  await until("document.querySelector('.page[data-page-number=\"2\"] .textLayer')?.textContent.includes('eigenvectors')");
  const select = async () => {
    await evaluate(`(() => {
      document.activeElement?.blur();
      const node = [...document.querySelectorAll('.page[data-page-number="2"] .textLayer span')].find(node => node.textContent.includes('eigenvectors')).firstChild;
      const start = node.textContent.indexOf('eigenvectors'), range = document.createRange();
      range.setStart(node, start); range.setEnd(node, start + 'eigenvectors'.length);
      const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
      node.parentElement.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));
    })()`);
    await until("document.querySelector('.pdf-selection-popup')");
  };
  await select();
  assert.equal(await evaluate("document.querySelector('.pdf-selection-popup input').value"), '');
  assert.ok(await evaluate("document.querySelector('.pdf-selection-popup').getBoundingClientRect().height < 115"));
  await browser.screenshot(join(process.argv[3], 'pdf-selection-compact-web.png'));
  const count = await evaluate("document.querySelectorAll('.message.user').length");
  await click('.pdf-selection-popup [type=submit]');
  await until(`document.querySelectorAll('.message.user').length === ${count + 1} && document.querySelector('#send').getAttribute('aria-label') !== 'Stop answer'`);
  assert.match(await evaluate("[...document.querySelectorAll('.message.user')].at(-1).textContent"), /eigenvectors/);
  await click('.pdf-selection-popup [data-close]');
  await evaluate("document.querySelector('.workspace').classList.add('chat-hidden')");
  await select();
  await click('.pdf-selection-popup [data-chat]');
  await until("!document.querySelector('.pdf-selection-popup') && document.activeElement === document.querySelector('#question')");
  assert.equal(await evaluate("document.querySelector('.workspace').classList.contains('chat-hidden')"), false);
  assert.equal(await evaluate("document.querySelector('#question').value"), '');
  assert.equal(await evaluate("document.querySelector('#send').disabled"), false);
  await click('#send');
  await until(`document.querySelectorAll('.message.user').length === ${count + 2} && document.querySelector('#send').getAttribute('aria-label') !== 'Stop answer'`);
  await until("document.querySelector('.message.assistant .chat-activity')");
  assert.ok(await evaluate("document.querySelector('.message.assistant pre code')"));
  assert.deepEqual(browser.errors, []);
  console.log('PASS: Chromium PDF selections send without comments, Open in chat focuses and enables Send, activity and code render during background sync');
} finally { await browser.close(); }
