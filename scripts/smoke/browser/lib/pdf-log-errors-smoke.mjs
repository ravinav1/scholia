import assert from 'node:assert/strict';

export async function pdfLogErrorsSmoke({ client, evaluate, waitFor, staticPort, selectionExpression }) {
  const base = `http://127.0.0.1:${staticPort}`;
  await client.send('Log.enable');
  await client.send('Browser.grantPermissions', { origin: base, permissions: ['clipboardReadWrite', 'clipboardSanitizedWrite'] });
  await client.send('Page.addScriptToEvaluateOnNewDocument', { source: `
    globalThis.__smokeErrors = [];
    addEventListener('error', (event) => __smokeErrors.push(event.message));
  ` });
  const navigate = async (path, ready) => {
    await client.send('Page.navigate', { url: `${base}${path}` });
    await client.send('Page.bringToFront');
    await waitFor(client, ready, path);
  };
  const frames = (count = 4) => evaluate(client, `(async () => {
    for (let i = 0; i < ${count}; i++) await new Promise(requestAnimationFrame);
  })()`);
  const inFrame = (expression) => `document.querySelector('#restricted-frame').contentWindow.eval(${JSON.stringify(expression)})`;
  const clickInFrame = async (expression) => {
    const point = await evaluate(client, `(() => {
      const frame = document.querySelector('#restricted-frame');
      const element = frame.contentWindow.eval(${JSON.stringify(expression)});
      element.scrollIntoView({block:'center'});
      const r = element.getBoundingClientRect(), f = frame.getBoundingClientRect();
      return {x:f.x+r.x+r.width/2,y:f.y+r.y+r.height/2};
    })()`);
    await client.send('Input.dispatchMouseEvent', { type:'mousePressed', button:'left', clickCount:1, ...point });
    await client.send('Input.dispatchMouseEvent', { type:'mouseReleased', button:'left', clickCount:1, ...point });
  };

  await navigate('/dist/chrome/pdf-viewer.html?source=smoke_pdf_source_123', "document.querySelector('.pdf-page canvas') && !document.querySelector('#outline-toggle').disabled");
  for (const [width, height] of [[1280,900], [900,450], [640,380], [380,700], [760,400], [1280,900]]) {
    await client.send('Emulation.setDeviceMetricsOverride', {width, height, deviceScaleFactor:1, mobile:false});
    await evaluate(client, "document.querySelector('#search-toggle').click(); document.querySelector('#outline-toggle').click(); document.querySelector('#open-chat').click()");
    await frames(12);
    const toolbar = await evaluate(client, `({actual: Math.ceil(document.querySelector('.toolbar').getBoundingClientRect().height), stored: parseFloat(document.documentElement.style.getPropertyValue('--toolbar-height')), errors: __smokeErrors})`);
    assert.equal(toolbar.stored, toolbar.actual, 'PDF toolbar offset must follow its current size');
    assert.deepEqual(toolbar.errors, [], `PDF resize errors at ${width}×${height}`);
  }
  await client.send('Emulation.clearDeviceMetricsOverride');
  // Exercise layout feedback explicitly: a size derived from the measured
  // toolbar height must settle across frames without an observer-loop error.
  await evaluate(client, "document.querySelector('.toolbar').style.minHeight = 'calc(100px + var(--toolbar-height) / 2)'");
  await frames(24);
  assert.equal(await evaluate(client, "document.querySelector('.toolbar').getBoundingClientRect().height"), 200);
  assert.deepEqual(await evaluate(client, '__smokeErrors'), [], 'Toolbar layout feedback must settle without errors');
  await evaluate(client, "document.querySelector('.toolbar').style.removeProperty('min-height')");
  await frames();

  await navigate('/__scholia-clipboard-policy-fixture.html', inFrame("Boolean(globalThis.__scholiaShadow?.querySelector('[data-model] optgroup'))"));
  assert.equal(await evaluate(client, inFrame("document.featurePolicy.allowsFeature('clipboard-write')")), false);
  await evaluate(client, inFrame(selectionExpression('#canvas-pdf-text', 'source point')));
  await waitFor(client, inFrame("!__scholiaShadow.querySelector('[data-pill]').hidden"), 'highlight selection');
  await evaluate(client, inFrame("__scholiaShadow.querySelector('[data-pill-send]').click()"));
  await waitFor(client, inFrame("__scholiaShadow.querySelector('[data-copy-code]') && !__scholiaShadow.querySelector('.scholia-caret')"), 'highlighted explanation');
  await clickInFrame("__scholiaShadow.querySelector('[data-copy-code]')");
  await waitFor(client, inFrame("__scholiaShadow.querySelector('[data-copy-code]').textContent === 'Copied'"), 'copy from restricted highlight popup');
  assert.equal(await evaluate(client, 'navigator.clipboard.readText()'), 'const result = 42;');

  await evaluate(client, "document.querySelector('#restricted-frame').src = '/dist/chrome/pdf-viewer.html?source=smoke_pdf_source_123'");
  await waitFor(client, inFrame("Boolean(document.querySelector('.pdf-page canvas'))"), 'restricted PDF viewer');
  await evaluate(client, inFrame("document.querySelector('#open-chat').click()"));
  await waitFor(client, inFrame("Boolean(document.querySelector('#pdf-chat-content').shadowRoot?.querySelector('#home-view'))"), 'PDF chat');
  await evaluate(client, inFrame(`(() => {
    globalThis.chatRoot = document.querySelector('#pdf-chat-content').shadowRoot;
    chatRoot.querySelector('#context-question').value = 'Explain this PDF';
    chatRoot.querySelector('#context-form').requestSubmit();
  })()`));
  await waitFor(client, inFrame("chatRoot.querySelector('[data-copy-code]') && !chatRoot.querySelector('.caret')"), 'PDF chat response');
  await evaluate(client, "navigator.clipboard.writeText('replace this value')");
  await clickInFrame("chatRoot.querySelector('[data-copy-code]')");
  await waitFor(client, inFrame("chatRoot.querySelector('[data-copy-code]').textContent === 'Copied'"), 'copy from restricted PDF chat');
  assert.equal(await evaluate(client, 'navigator.clipboard.readText()'), 'const result = 42;');
  assert.deepEqual(await evaluate(client, inFrame('__smokeErrors')), []);

  const policyErrors = client.events.filter(event => event.method === 'Log.entryAdded')
    .map(event => event.params.entry.text).filter(text => /permissions policy violation.*clipboard|ResizeObserver loop/i.test(text));
  assert.deepEqual(policyErrors, [], 'No clipboard policy violations or resize-loop messages');
  assert.deepEqual(client.events.filter(event => event.method === 'Runtime.exceptionThrown'), [], 'No uncaught browser errors');
  console.log('Chromium PDF log regression passed: responsive toolbar and actual clipboard copying in policy-restricted highlight popups and PDF chat, with no resize-loop or clipboard-policy errors.');
}
