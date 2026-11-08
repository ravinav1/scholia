import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { lazyContent, snapshotSelection, installContentBootstrap } from '../../apps/chrome/src/content-bootstrap.js';

const deferred = () => { let resolve, reject; const promise = new Promise((yes, no) => { resolve = yes; reject = no; }); return { promise, resolve, reject }; };

test('concurrent triggers wait for one mounted interface and initialized provider', async () => {
  const loaded = deferred(), settings = deferred();
  let imports = 0, mounts = 0;
  const load = lazyContent(() => { imports++; return loaded.promise; });
  const first = load(), second = load();
  loaded.resolve({ async mountContent() { mounts++; return { settings: await settings.promise }; } });
  let ready = false; first.then(() => { ready = true; });
  await new Promise(setImmediate);
  assert.equal(ready, false, 'input cannot reach an interface without provider settings');
  settings.resolve({ model: 'current-model' });
  const [a, b] = await Promise.all([first, second]);
  assert.equal(a, b);
  assert.equal((await load()).settings.model, 'current-model');
  assert.equal(imports, 1);
  assert.equal(mounts, 1);
});

test('a failed module download can be retried without caching rejection', async () => {
  const attempts = [];
  const load = lazyContent(async (attempt) => {
    attempts.push(attempt);
    if (attempt === 0) throw new Error('Download interrupted');
    return { mountContent: async () => ({ ready: true }) };
  });
  await assert.rejects(load(), /Download interrupted/);
  const [first, second] = await Promise.all([load(), load()]);
  assert.equal(first.ready, true);
  assert.equal(first, second);
  assert.deepEqual(attempts, [0, 1]);
});

test('selection capture keeps text and a cloned range when the live selection moves', () => {
  const original = { cloneRange: () => ({ selected: 'original range' }) };
  const live = { isCollapsed: false, rangeCount: 1, anchorNode: {}, focusNode: {}, text: 'first selection', getRangeAt: () => original, toString() { return this.text; } };
  const saved = snapshotSelection(live);
  live.text = 'second selection'; live.isCollapsed = true;
  assert.equal(saved.toString(), 'first selection');
  assert.notEqual(saved.getRangeAt(0), original);
  assert.equal(snapshotSelection(live), null);
});

test('routing ignores unrelated messages and retains command selection during lazy loading', async () => {
  const listeners = new Map(), messages = [];
  const doc = { addEventListener: (type, fn) => listeners.set(type, fn) };
  let text = 'the requested passage';
  const selection = { isCollapsed:false,rangeCount:1,anchorNode:{},focusNode:{},getRangeAt:()=>({cloneRange:()=>({})}),toString:()=>text };
  const win = { getSelection: () => selection };
  const loading = deferred(); let listener, loads = 0;
  const runtime = { onMessage: { addListener: (fn) => { listener = fn; } } };
  installContentBootstrap({ doc, win, runtime, load: () => { loads++; return loading.promise; } });
  assert.equal(listener({ type: 'UNRELATED' }, {}, () => {}), undefined);
  assert.equal(loads, 0);
  const response = deferred();
  assert.equal(listener({ type: 'SCHOLIA_EXPLAIN_CURRENT' }, {}, response.resolve), true);
  text = 'different passage';
  loading.resolve({ mountContent: async () => ({ handleRuntimeMessage(message, sender, respond, saved) { messages.push(saved.toString()); respond({ ok:true }); } }) });
  assert.equal((await response.promise).ok, true);
  assert.deepEqual(messages, ['the requested passage']);
  assert.equal(loads, 1);
});

test('only the packaged lazy module is exposed, with no broad JavaScript wildcard', async () => {
  const manifest = JSON.parse(await readFile(new URL('../../apps/chrome/manifest.json', import.meta.url)));
  const resources = manifest.web_accessible_resources.flatMap((group) => group.resources);
  assert.ok(resources.includes('content-ui.js'));
  assert.equal(resources.some((path) => path === '*.js' || path === '*'), false);
});

test('background page context loads no rich interface, including concurrent requests', async () => {
  const doc = { addEventListener() {} }, win = { getSelection: () => null };
  let listener, uiLoads = 0, contextLoads = 0;
  const runtime = { onMessage: { addListener(fn) { listener = fn; } } };
  installContentBootstrap({ doc, win, runtime,
    load() { uiLoads++; throw new Error('Unexpected UI initialization'); },
    async loadContext() { contextLoads++; return { createContextReader: () => ({ handleRuntimeMessage(message, sender, respond) { respond({ ok: true, value: 'private page context' }); } }) }; },
  });
  const first = deferred(), second = deferred();
  listener({type:'SCHOLIA_GET_PAGE_CONTEXT'}, {}, first.resolve);
  listener({type:'SCHOLIA_GET_TAB_CONTEXT_PREVIEW'}, {}, second.resolve);
  assert.deepEqual(await Promise.all([first.promise, second.promise]), [
    {ok:true,value:'private page context'}, {ok:true,value:'private page context'},
  ]);
  assert.equal(uiLoads, 0);
  assert.equal(contextLoads, 1);
});

test('a replaced PDF cancels a queued source command before the lazy interface uses it', async () => {
  const events = new Map(), doc = {addEventListener(type, callback) {events.set(type, callback);}}, win = {getSelection:()=>null};
  let listener, handled = 0;
  const loading = deferred(), reply = deferred();
  installContentBootstrap({doc,win,runtime:{onMessage:{addListener(fn){listener=fn;}}},load:()=>loading.promise});
  listener({type:'SCHOLIA_EXPLAIN_CURRENT'}, {}, reply.resolve);
  events.get('scholia:document-instance-changed')();
  loading.resolve({mountContent:()=>({handleRuntimeMessage(){handled++;}})});
  assert.deepEqual(await reply.promise,{ok:false,error:'The document changed. Retry in the current reading.'});
  assert.equal(handled,0);
});
