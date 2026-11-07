import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { chromiumSession } from './smoke/browser/lib/chromium.mjs';

const source = await readFile(new URL('../apps/macos/Sources/ScholiaMac/StudentwebResults.swift', import.meta.url), 'utf8');
const script = source.match(/static let script = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const fixture = await readFile(new URL('../tests/fixtures/studentweb-results.html', import.meta.url), 'utf8');
const responsiveFixture = await readFile(new URL('../tests/fixtures/studentweb-results-responsive.html', import.meta.url), 'utf8');
const connectionSource = await readFile(new URL('../apps/macos/Sources/ScholiaMac/StudentwebResultsConnection.swift', import.meta.url), 'utf8');
const signInScript = connectionSource.match(/static let signInScript = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const browser = await chromiumSession();
try {
  const { evaluate, send } = browser;
  const { frameTree } = await send('Page.getFrameTree');
  await send('Page.setDocumentContent', { frameId: frameTree.frame.id, html: fixture });
  // Supply the trusted URL to the isolated function without visiting Studentweb,
  // signing into an account or exposing any real student data to automation.
  const read = (url = 'https://fsweb.no/studentweb/resultater.jsf') => evaluate(
    `new Function('document', 'location', ${JSON.stringify(script)})(document, new URL(${JSON.stringify(url)}))`
  );
  const before = await evaluate('document.documentElement.outerHTML');
  const snapshot = await read();
  assert.deepEqual(JSON.parse(snapshot), [
    { courseCode: 'TDT4100', passed: true }, { courseCode: 'TFE4100', passed: false },
    { courseCode: 'TMA4100', passed: true }, { courseCode: 'TTK4100', passed: false },
  ]);
  assert.doesNotMatch(snapshot, /PRIVATE|12345|98765|@|2025|2026|Karakter|grade|credits|PART1000|CSS1000|CLOSED1000|HIDDEN/);
  assert.equal(await evaluate('document.documentElement.outerHTML'), before, 'Extraction must not change the page');
  for (const url of ['https://fsweb.no/studentweb/start.jsf', 'https://fsweb.no/studentweb/login.jsf', 'http://fsweb.no/studentweb/resultater.jsf', 'https://fsweb.no.evil.test/studentweb/resultater.jsf']) {
    assert.equal(await read(url), '');
  }
  await evaluate(`document.querySelectorAll('tbody')[0].replaceChildren()`);
  assert.equal(await read(), '[]', 'Removed results must not survive a new read');
  assert.equal(await evaluate('document.querySelector("details").open'), false);
  await send('Page.setDocumentContent', { frameId: frameTree.frame.id, html: responsiveFixture });
  for (const width of [1200, 480]) {
    await send('Emulation.setDeviceMetricsOverride', { width, height: 800, deviceScaleFactor: 1, mobile: false });
    const before = await evaluate('document.documentElement.outerHTML');
    const snapshot = await read();
    assert.deepEqual(JSON.parse(snapshot), [
      { courseCode: 'TEST1000', passed: false }, { courseCode: 'TEST1001', passed: true },
      { courseCode: 'TEST1002', passed: true }, { courseCode: 'ØKO1000', passed: true },
    ].sort((a, b) => a.courseCode.localeCompare(b.courseCode)));
    assert.doesNotMatch(snapshot, /PRIVATE|PART|HIDDEN|Legeattest|Godkjent|møtt|grade|date|credits/);
    assert.equal(await evaluate('document.documentElement.outerHTML'), before);
  }
  // Only synthetic sign-in controls. Verify the real browser dispatches the
  // official form handler without reading or returning any hidden auth state.
  await send('Page.setDocumentContent', { frameId: frameTree.frame.id, html: '<html><body><section class="login-name-feide">'
    + '<form method="post" action="/studentweb/login.jsf"><input type="hidden" name="javax.faces.ViewState" value="SYNTHETIC_STATE">'
    + '<a class="link" href="#" onclick="event.preventDefault(); window.syntheticSignInCount = (window.syntheticSignInCount || 0) + 1">Feide</a></form></section></body></html>' });
  assert.equal(await evaluate(`new Function('document', 'location', ${JSON.stringify(signInScript)})(document, new URL('https://fsweb.no/studentweb/login.jsf?inst=FSNTNU'))`), true);
  assert.equal(await evaluate('window.syntheticSignInCount'), 1);
  assert.deepEqual(browser.errors, []);
  console.log('PASS: Chromium sign-in dispatch and results extraction: code + boolean only, desktop/mobile CSS, complete vs partial results, missing/zero credits, Unicode, retakes, exact origin, no page mutation or stale rows');
} finally {
  await browser.close();
}
