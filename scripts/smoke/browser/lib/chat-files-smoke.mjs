import { writeFile } from 'node:fs/promises';
import assert from 'node:assert/strict';

export async function chatFilesSmoke({ client, evaluate, waitFor, staticPort, selectionExpression }) {
  const base = `http://127.0.0.1:${staticPort}`;
  await client.send('Browser.grantPermissions', { origin: base, permissions: ['clipboardReadWrite', 'clipboardSanitizedWrite'] });
  const navigate = async (path, ready) => {
    await client.send('Page.navigate', { url: `${base}${path}` });
    await client.send('Page.bringToFront');
    await waitFor(client, ready, path);
  };
  const click = async (expression) => {
    const point = await evaluate(client, `(() => { const element = ${expression}; element.scrollIntoView({block:'center'}); const r = element.getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2}; })()`);
    await client.send('Page.bringToFront');
    await client.send('Input.dispatchMouseEvent', { type: 'mousePressed', button: 'left', clickCount: 1, ...point });
    await client.send('Input.dispatchMouseEvent', { type: 'mouseReleased', button: 'left', clickCount: 1, ...point });
  };
  const drop = async (root, target, fileName = 'notes.txt') => evaluate(client, `(async () => {
    const root = ${root};
    const transfer = new DataTransfer();
    const pdf = ${JSON.stringify(fileName.endsWith('.pdf'))};
    const body = pdf ? await (await fetch('/__scholia-pdf-search-fixture.pdf')).blob() : 'ATTACHED_FILE_EVIDENCE: entropy measures microscopic states.';
    transfer.items.add(new File([body], ${JSON.stringify(fileName)}, {type: pdf ? 'application/pdf' : 'text/plain'}));
    const event = new DragEvent('drop', {dataTransfer: transfer, bubbles: true, cancelable: true});
    root.querySelector(${JSON.stringify(target)}).dispatchEvent(event);
    return event.defaultPrevented;
  })()`);

  await client.send('Emulation.setDeviceMetricsOverride', { width: 380, height: 800, deviceScaleFactor: 1, mobile: false });
  await navigate('/dist/chrome/panel.html', "document.querySelector('#current-title')?.textContent === 'Recursive smoke notes'");
  assert.equal(await drop('document', '#home-view', 'lecture.pdf'), true);
  await waitFor(client, "document.querySelector('#composer-files .scholia-file-chip')?.textContent.includes('lecture.pdf') && !document.querySelector('#chat-view').hidden", 'PDF drop from home');
  const shot = await client.send('Page.captureScreenshot', {format:'png'});
  await writeFile('/private/tmp/scholia-chat-files.png', Buffer.from(shot.data, 'base64'));
  await evaluate(client, "document.querySelector('#composer').value = 'Summarize the lecture'; document.querySelector('#composer-form').requestSubmit()");
  await waitFor(client, "globalThis.__scholiaLastChatPayload?.messages[0]?.files?.[0]?.text.includes('Photosynthesis') && !document.querySelector('#messages .caret')", 'PDF text sent to provider');
  const savedId = await evaluate(client, "new URL(location.href).searchParams.get('chat') || Object.values(JSON.parse(localStorage.getItem('__scholia_chrome_local_stub__'))).find(Array.isArray)?.[0]?.id");
  assert.ok(savedId);
  await evaluate(client, "document.querySelector('#expand-chat').click()");
  const url = await evaluate(client, 'globalThis.__scholiaCreatedTabUrl');
  await client.send('Emulation.clearDeviceMetricsOverride');
  await client.send('Page.navigate', { url });
  await waitFor(client, "document.querySelector('#messages .scholia-file-chip')?.textContent.includes('lecture.pdf')", 'attachment restored in dedicated chat');
  await evaluate(client, "document.querySelector('[data-edit-query]').click()");
  await evaluate(client, "document.querySelector('[data-query-editor]').value = 'Revised lecture question'; document.querySelector('[data-save-query-edit]').click()");
  await waitFor(client, "globalThis.__scholiaLastChatPayload?.messages[0]?.files?.[0]?.text.includes('Photosynthesis') && !document.querySelector('#messages .caret')", 'edited turn retains PDF');
  assert.equal(await evaluate(client, "Boolean(document.querySelector('#model-select option[value=\"openai::gpt-6-astra\"]'))"), true);

  // Reset to a response containing a highlighted excerpt and a code block.
  await navigate('/dist/chrome/panel.html', "document.querySelector('#current-title')?.textContent === 'Recursive smoke notes'");
  await evaluate(client, "document.querySelector('#context-question').value='Explain'; document.querySelector('#context-form').requestSubmit()");
  await waitFor(client, "document.querySelector('#messages [data-copy-code]') && !document.querySelector('#messages .caret')", 'response with code');
  assert.equal(await evaluate(client, 'globalThis.__scholiaLastContextRequest.correlateTabs'), false);
  await click("document.querySelector('#messages [data-copy-code]')");
  await waitFor(client, "document.querySelector('#messages [data-copy-code]').textContent === 'Copied'", 'sidebar copy');
  assert.equal(await evaluate(client, 'navigator.clipboard.readText()'), 'const result = 42;');
  await evaluate(client, selectionExpression('#messages .message--assistant .bubble', 'root recursion target'));
  await waitFor(client, "!document.querySelector('#response-explain').hidden", 'response selection');
  await evaluate(client, "document.querySelector('#response-explain-send').click()");
  await waitFor(client, "!document.querySelector('#response-window-backdrop').hidden && !document.querySelector('#response-window-messages .caret')", 'nested response window');
  assert.equal(await drop('document', '#response-window-composer'), true);
  await waitFor(client, "document.querySelector('#response-window-files .scholia-file-chip')", 'nested attachment');
  await evaluate(client, "document.querySelector('#response-window-form').requestSubmit()");
  await waitFor(client, "globalThis.__scholiaLastChatPayload?.messages.at(-1)?.files?.[0]?.text.includes('ATTACHED_FILE_EVIDENCE')", 'nested attachment payload');

  await navigate('/__scholia-canvas-pdf-frame-fixture.html', 'globalThis.__scholiaShadow?.querySelector("[data-model] optgroup")');
  await evaluate(client, selectionExpression('#canvas-pdf-text', 'source point'));
  await waitFor(client, "!globalThis.__scholiaShadow.querySelector('[data-pill]').hidden", 'highlight popup');
  await evaluate(client, "globalThis.__scholiaShadow.querySelector('[data-pill-send]').click()");
  await waitFor(client, "globalThis.__scholiaShadow.querySelector('[data-copy-code]') && !globalThis.__scholiaShadow.querySelector('.scholia-caret')", 'highlight explanation code');
  await evaluate(client, `(() => {
    Object.defineProperty(navigator.clipboard, 'writeText', { configurable: true, value: async () => { throw new DOMException('Blocked by frame policy', 'NotAllowedError'); } });
  })()`);
  await click("globalThis.__scholiaShadow.querySelector('[data-copy-code]')");
  await waitFor(client, "globalThis.__scholiaShadow.querySelector('[data-copy-code]').textContent === 'Copied'", 'popup clipboard fallback');
  assert.equal(await evaluate(client, 'navigator.clipboard.readText()'), 'const result = 42;');
  assert.equal(await drop('globalThis.__scholiaShadow', '[data-composer]', 'popup.pdf'), true);
  await waitFor(client, "globalThis.__scholiaShadow.querySelector('[data-files] .scholia-file-chip')?.textContent.includes('popup.pdf')", 'PDF in closed shadow popup');
  await evaluate(client, "globalThis.__scholiaShadow.querySelector('[data-composer]').value='Read popup PDF'; globalThis.__scholiaShadow.querySelector('[data-send]').click()");
  await waitFor(client, "globalThis.__scholiaLastChatPayload?.messages.at(-1)?.files?.[0]?.text.includes('Photosynthesis')", 'popup file payload');

  await navigate('/dist/chrome/popup.html', "document.querySelector('#site')?.textContent === 'example.test'");
  assert.equal(await drop('document', '#quick-input'), true);
  await waitFor(client, "document.querySelector('#quick-files .scholia-file-chip')", 'toolbar attachment');
  await evaluate(client, "document.querySelector('#quick-form').requestSubmit()");
  await waitFor(client, "globalThis.__scholiaLastChatPayload?.messages[0]?.files?.[0]?.text.includes('ATTACHED_FILE_EVIDENCE')", 'toolbar attachment payload');

  await navigate('/dist/chrome/pdf-viewer.html?source=smoke_pdf_source_123', "document.querySelector('.pdf-page canvas')");
  await evaluate(client, "document.querySelector('#open-chat').click()");
  await waitFor(client, "document.querySelector('#pdf-chat-content').shadowRoot?.querySelector('#home-view')", 'embedded PDF chat');
  assert.equal(await drop("document.querySelector('#pdf-chat-content').shadowRoot", '#home-view'), true);
  await waitFor(client, "document.querySelector('#pdf-chat-content').shadowRoot.querySelector('#composer-files .scholia-file-chip')", 'embedded attachment');
  const overflow = await evaluate(client, `(() => {
    const root = document.querySelector('#pdf-chat-content').shadowRoot;
    const composer = root.querySelector('#composer-form');
    return composer.scrollWidth - composer.clientWidth;
  })()`);
  assert.ok(overflow <= 1, `Embedded composer overflow: ${overflow}`);

  const office = await evaluate(client, `(async () => {
    const { readChatFile } = await import('/apps/chrome/src/file-input.js');
    const fixtures = {"docx": "UEsDBBQAAAAIAOdqN13HLt+zfgAAAKUAAAARAAAAd29yZC9kb2N1bWVudC54bWxFzjEOwjAMBdCrRD0ArhgYopAFdlbWkJimUh1HTqqU29OUgeV9WV9fsmk6sF8JU1UbLanodh1irVkDFB+RXDlxxrR3bxZydT9lgsYSsrDHUuY00QLncbwAuTkN1jT94vDpmTvSqfb+uD2V51UKqhqRBclAL7pymA9/Y/g/Zr9QSwECFAMUAAAACADnajddxy7fs34AAAClAAAAEQAAAAAAAAAAAAAAgAEAAAAAd29yZC9kb2N1bWVudC54bWxQSwUGAAAAAAEAAQA/AAAArQAAAAAA", "pptx": "UEsDBBQAAAAIAOdqN12GXUSigAAAAMkAAAAVAAAAcHB0L3NsaWRlcy9zbGlkZTEueG1sjY89CgIxEIWvsuwBnMXCIsScYQsL22ETs4FkMkxG9Pgmi42dzQeP9wPPsmnZT++SqRm+zrsqG4C27aFgO1UO1L1HlYLapURgCS2QoqZKJcN5WS5QMNH8HcF/RrzgK1H86TuLhgdkQN263u5TDps+JUw+YRQsFoYzKAd7Ho4H7gNQSwECFAMUAAAACADnajddhl1EooAAAADJAAAAFQAAAAAAAAAAAAAAgAEAAAAAcHB0L3NsaWRlcy9zbGlkZTEueG1sUEsFBgAAAAABAAEAQwAAALMAAAAAAA==", "xlsx": "UEsDBBQAAAAIAOdqN10dc04FZQAAAG4AAAAUAAAAeGwvc2hhcmVkU3RyaW5ncy54bWwVzTEOwjAMRuGrRD0ArhgYkPEJ2Fi6RsGQSnUS+TcSxyeMT9/wGIj0taPhttSIcSVCqWoZpz60TXl1txwz/U0YrvmJqhp20HldL2R5b4swduGQ7f7YUukfhyaU7soUwvRHmiP5AVBLAwQUAAAACADnajddX1eHbHQAAACgAAAAGAAAAHhsL3dvcmtzaGVldHMvc2hlZXQxLnhtbE2OSw7CMAxEr1LlADiqEAvkesVFrGAIovkotlqOT8iiYvnezEiDe2lvjSI2fdKadXHRrF4BNERJrKdSJffkUVpi69ieoLUJ38corTB7f4HEr+wIh7uxMWErO2GYbHHag408wkYIocsfnueDYVThbwvHKfoCUEsBAhQDFAAAAAgA52o3XR1zTgVlAAAAbgAAABQAAAAAAAAAAAAAAIABAAAAAHhsL3NoYXJlZFN0cmluZ3MueG1sUEsBAhQDFAAAAAgA52o3XV9Xh2x0AAAAoAAAABgAAAAAAAAAAAAAAIABlwAAAHhsL3dvcmtzaGVldHMvc2hlZXQxLnhtbFBLBQYAAAAAAgACAIgAAABBAQAAAAA="};
    const results = [];
    for (const [ext, base64] of Object.entries(fixtures)) {
      const bytes = Uint8Array.from(atob(base64), (character) => character.charCodeAt(0));
      const result = await readChatFile(new File([bytes], 'notes.' + ext));
      results.push(result.text);
    }
    return results;
  })()`);
  assert.deepEqual(office, ['DOCX course theorem', 'PPTX lecture diagram', 'XLSX course score\t42']);

  // Exercise authenticated-style API pagination, PDF extraction, IndexedDB reuse,
  // source replacement, cache deletion and query retrieval without a real account.
  await navigate('/dist/chrome/panel.html', "document.querySelector('#current-title')?.textContent === 'Recursive smoke notes'");
  const courseResult = await evaluate(client, `(async () => {
    const { loadCanvasCourseIndex, getCanvasCourseContext } = await import('/apps/chrome/src/canvas-index.js');
    const originalFetch = globalThis.fetch;
    let version = 1, downloads = 0;
    globalThis.fetch = async (input, options) => {
      const url = new URL(input, location.href);
      const root = '/api/v1/courses/42';
      let value;
      if (url.pathname === '/api/v1/users/self') value = {id: 7};
      else if (url.pathname === root) value = {id: 42, name: 'Biology', syllabus_body: '<p>Plant biology syllabus</p>'};
      else if (url.pathname === root + '/pages') value = [{url:'intro', title:'Introduction', updated_at:String(version)}];
      else if (url.pathname === root + '/pages/intro') value = {body:'<p>COURSE_REVISION_' + version + '</p>'};
      else if (url.pathname === root + '/files') value = [{id:9, display_name:'Lecture.pdf', updated_at:'v1', 'content-type':'application/pdf', size:2000, url:location.origin + '/__scholia-pdf-search-fixture.pdf'}];
      else if (url.pathname === root + '/modules' || url.pathname === root + '/assignments') value = [];
      else { if (url.pathname.endsWith('.pdf')) downloads++; return originalFetch(input, options); }
      if (options.credentials !== 'include') throw new Error('Missing login credentials');
      return new Response(JSON.stringify(value), {headers:{'Content-Type':'application/json'}});
    };
    try {
      const url = location.origin + '/courses/42';
      await loadCanvasCourseIndex(url, {clear:true});
      const first = await loadCanvasCourseIndex(url);
      const second = await loadCanvasCourseIndex(url);
      const context = await getCanvasCourseContext(url, {question:'How do plants store solar energy?'});
      version = 2;
      const updated = await loadCanvasCourseIndex(url, {force:true});
      await loadCanvasCourseIndex(url, {clear:true});
      return {first:first.documents.length, cached:second.cached, context:context.context, downloads, updated:updated.documents.map(d=>d.text).join(' ')};
    } finally {
      globalThis.__scholiaCanvasOriginalFetch = originalFetch;
      globalThis.__scholiaSourceOverride = {tabId:1, windowId:1, pageTitle:'Biology course', sourceKind:'page', url:location.origin+'/courses/42', canvasCourse:{origin:location.origin,courseId:'42'}};
    }
  })()`);
  assert.equal(courseResult.first, 3);
  assert.equal(courseResult.cached, true);
  assert.equal(courseResult.downloads, 1);
  assert.match(courseResult.context, /Photosynthesis/);
  assert.match(courseResult.updated, /COURSE_REVISION_2/);
  assert.doesNotMatch(courseResult.updated, /COURSE_REVISION_1/);
  await evaluate(client, "chrome.tabs.onActivated.listeners.forEach((listener) => listener({tabId:1,windowId:1}))");
  await waitFor(client, "!document.querySelector('#course-index').hidden", 'Canvas course controls');
  await evaluate(client, "document.querySelector('#context-question').value='Explain photosynthesis from my course'; document.querySelector('#context-form').requestSubmit()");
  await waitFor(client, "globalThis.__scholiaLastChatPayload?.context.includes('Photosynthesis') && !document.querySelector('#chat-course-refresh').hidden && !document.querySelector('#messages .caret')", 'automatic Canvas course context');
  await evaluate(client, "document.querySelector('#composer').value='What changed in the introduction?'; document.querySelector('#composer-form').requestSubmit()");
  await waitFor(client, "globalThis.__scholiaLastChatPayload?.messages.at(-1)?.content.includes('What changed') && globalThis.__scholiaLastChatPayload.context.includes('COURSE_REVISION_2')", 'course retrieval on follow-up');
  await evaluate(client, "globalThis.fetch = globalThis.__scholiaCanvasOriginalFetch");
  console.log('Chromium chat files smoke passed: PDF drop, history/edit, all five chat surfaces, real clipboard fallback, tab-only context, GPT-6, and Canvas cache refresh.');
}
