import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { chromiumSession } from './lib/chromium.mjs';

const source = await readFile(new URL('../apps/macos/Sources/ScholiaMac/PersonalizationPage.swift', import.meta.url), 'utf8');
const script = source.match(/static let script = #"""\n([\s\S]*?)\n\s*"""#/)[1];
const browser = await chromiumSession();
try {
  const { evaluate, send } = browser;
  const { frameTree } = await send('Page.getFrameTree');
  const html = value => send('Page.setDocumentContent', { frameId: frameTree.frame.id, html: `<!doctype html><html><body>${value}</body></html>` });
  const read = (action, url = 'https://chatgpt.com/#settings/Personalization') => evaluate(`
    (async () => JSON.parse(await new (Object.getPrototypeOf(async function(){}).constructor)('document', 'location', 'action', ${JSON.stringify(script)})(document,new URL(${JSON.stringify(url)}),${JSON.stringify(action)})))()`);
  await html(`<main><h1>Personalization</h1>
    <label for="instructions">Custom instructions</label><textarea id="instructions">Use concrete examples.</textarea>
    <label for="name">Nickname</label><input id="name" value="Alex">
    <label for="occupation">Occupation</label><input id="occupation" value="Student">
    <input type="hidden" value="secret-token"><input type="email" value="private@example.com">
    <label for="hidden">About you</label><input id="hidden" style="display:none" value="hidden preference">
    <textarea id="prompt-textarea" aria-label="Chat message">Do not capture a chat draft</textarea>
    <h2>Memory summary</h2><p>View an overview of what ChatGPT has learned about you.</p><button>Manage</button></main>`);
  const profile = await read('profile');
  assert.equal(profile.instructions, 'Use concrete examples.');
  assert.match(profile.profile, /Nickname: Alex/);
  assert.doesNotMatch(JSON.stringify(profile), /secret|private@|hidden preference|chat draft/);
  assert.deepEqual(await read('memory'), {}, 'Personalization settings are never a memory list');
  await evaluate(`document.querySelector('#instructions').value=''`);
  assert.equal((await read('profile')).instructions, '', 'An explicitly cleared field removes old preferences');
  assert.deepEqual(await read('profile', 'https://chatgpt.com.evil.example/#settings/Personalization'), {});
  assert.deepEqual(await read('profile', 'https://chatgpt.com/c/example'), {}, 'Chats are never imported as preferences');

  await html(`<div role="dialog"><h2>Saved memories</h2><input type="search" placeholder="Search memories">
    <ul><li data-testid="memory-entry">Alex studies philosophy.</li><li data-testid="memory-entry">Prefers concise answers.</li></ul>
    <p style="display:none">Hidden memory</p><button>Delete all</button></div>`);
  assert.deepEqual(await read('memory'), { memories: 'Alex studies philosophy.\nPrefers concise answers.' });
  await evaluate(`document.querySelector('li').remove()`);
  assert.deepEqual(await read('memory'), { memories: 'Prefers concise answers.' }, 'Deleted memories do not accumulate');
  await evaluate(`document.querySelector('input').value='Alex'`);
  assert.deepEqual(await read('memory'), {}, 'A filtered subset must not replace the saved snapshot');
  await html('<div role="dialog"><h2>Saved memories</h2><p>No saved memories yet</p></div>');
  assert.deepEqual(await read('memory'), { memories: '' }, 'An explicit empty list clears old memories');
  await html('<div role="dialog"><h2>Saved memories</h2><p>Loading…</p></div>');
  assert.deepEqual(await read('memory'), {}, 'Loading does not erase memories');
  await html('<div role="dialog"><h2>Memory</h2><p>Prefers custom instructions about formatting.</p><p>Loading…</p></div>');
  assert.deepEqual(await read('memory'), {}, 'A partly loaded list does not replace a complete snapshot');
  await evaluate(`document.querySelector('p:last-child').remove()`);
  assert.deepEqual(await read('memory'), { memories: 'Prefers custom instructions about formatting.' });

  await html(`<main><h1>Profile</h1><label for="prefs">Instructions for Claude</label>
    <textarea id="prefs">Prefer short paragraphs.</textarea><label for="fullname">Full name</label><input id="fullname" value="Alex"></main>`);
  assert.deepEqual(await read('profile', 'https://claude.ai/settings/profile'), {
    instructions: 'Prefer short paragraphs.', profile: 'Full name: Alex',
  });
  await html('<main><section><h2>Your memory</h2><p>Alex enjoys hiking.</p><p>Prefers metric units.</p></section></main>');
  assert.deepEqual(await read('memory', 'https://claude.ai/settings/memory'), { memories: 'Alex enjoys hiking.\nPrefers metric units.' });
  await html('<div role="dialog"><h2>View and edit your memory</h2><textarea aria-label="Memory">Alex writes in Norwegian.</textarea></div>');
  assert.deepEqual(await read('memory', 'https://claude.ai/settings/capabilities'), { memories: 'Alex writes in Norwegian.' });
  await html('<main><h1>Sign in</h1><input type="password" value="secret"><label for="prefs">Custom instructions</label><textarea id="prefs">Not valid</textarea></main>');
  assert.deepEqual(await read('profile'), {});

  await html(`<div role="dialog" style="height:100px;overflow:auto"><h2>Saved memories</h2><ul>${Array.from({length: 20}, (_,i)=>`<li style="height:25px" data-testid="memory-entry">Memory ${i+1}</li>`).join('')}</ul></div>`);
  const all = await read('memory');
  assert.equal(all.memories.split('\n').length, 20);
  assert.equal(await evaluate('document.querySelector("[role=dialog]").scrollTop'), 0);
  assert.deepEqual(browser.errors, []);
  console.log('PASS: Chromium ChatGPT/Claude instructions, profile, memory extraction; origin and login guards; hidden data, deletion, empty/pending/filtered lists and bounded scrolling.');
} finally { await browser.close(); }
