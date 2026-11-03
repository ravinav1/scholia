import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const manifest = JSON.parse(await readFile(
  new URL('../apps/chrome/manifest.json', import.meta.url),
  'utf8'
));
const pdfViewerSource = await readFile(
  new URL('../apps/chrome/src/pdf-viewer.js', import.meta.url),
  'utf8'
);

test('selection content script is injected into embedded PDF viewer frames', () => {
  const selectionScript = manifest.content_scripts.find((entry) => entry.js?.includes('content.js'));

  assert.equal(selectionScript?.all_frames, true);
  assert.equal(selectionScript?.match_about_blank, true);
  assert.equal(selectionScript?.match_origin_as_fallback, true);
});

test('PDFs register an original-URL handler for top-level and embedded documents', () => {
  assert.deepEqual(manifest.mime_types_handler, {
    'application/pdf': { handler_url: 'pdf-viewer.html', can_embed: true }
  });
});

test('PDF chat stays in the reader without a browser-specific sidebar redirect', () => {
  assert.doesNotMatch(pdfViewerSource, /SCHOLIA_OPEN_SIDE_PANEL|useBrowserChatSidebar|pdf-chat-frame/);
  assert.match(pdfViewerSource, /mountPdfChat/);
  assert.match(pdfViewerSource, /is-pdf-chat-open/);
});

test('scheduled ChatGPT context refresh declares the alarms permission', () => {
  assert.equal(manifest.permissions.includes('alarms'), true);
});

test('region capture and Quick Chat expose configurable Chrome commands', () => {
  assert.equal(Number(manifest.minimum_chrome_version) >= 116, true);
  assert.equal(manifest.commands?.['capture-region']?.description, 'Capture and explain a screen region');
  assert.equal(manifest.commands?.['quick-chat']?.description, 'Toggle Scholia Quick Chat in the sidebar');
  assert.equal(manifest.commands?.['quick-chat']?.suggested_key?.mac, 'Command+Shift+K');
});
