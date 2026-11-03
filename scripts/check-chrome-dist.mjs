import { access, readFile, readdir, stat } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { isChromeExtensionVersion } from './lib/chrome-extension-version.mjs';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dist = join(projectRoot, 'dist', 'chrome');
const manifest = JSON.parse(await readFile(join(dist, 'manifest.json'), 'utf8'));

if (manifest.manifest_version !== 3) throw new Error('Chrome build is not Manifest V3.');
if (!isChromeExtensionVersion(manifest.version)) throw new Error('Chrome build has an invalid extension version.');
if (!manifest.content_security_policy?.extension_pages?.includes("'wasm-unsafe-eval'")) {
  throw new Error('Chrome extension pages must allow the bundled PDF.js WebAssembly image decoders.');
}
if (!manifest.action?.default_popup) throw new Error('Chrome build does not declare the compact toolbar popup.');
if (manifest.action.default_popup === manifest.side_panel?.default_path) {
  throw new Error('The toolbar popup and side panel must remain separate surfaces.');
}
if (manifest.mime_types_handler?.['application/pdf']?.handler_url !== 'pdf-viewer.html'
    || manifest.mime_types_handler['application/pdf'].can_embed !== true) {
  throw new Error('Register the PDF MIME reader so supported Chromium versions retain the original address.');
}
for (const command of ['capture-region', 'quick-chat']) {
  if (!manifest.commands?.[command]) throw new Error(`Chrome build is missing the ${command} command.`);
}
const selectionScript = manifest.content_scripts?.find((entry) => entry.js?.includes('content.js'));
if (!selectionScript?.all_frames
    || !selectionScript.match_about_blank
    || !selectionScript.match_origin_as_fallback) {
  throw new Error('Selection tools must run in embedded document frames, including Canvas PDF previews.');
}

const required = [
  manifest.background?.service_worker,
  manifest.options_page,
  manifest.action?.default_popup,
  manifest.side_panel?.default_path,
  ...manifest.content_scripts.flatMap((entry) => entry.js || []),
  ...Object.values(manifest.icons || {}),
  'options.js', 'options.css', 'panel.js', 'panel.css', 'file-attachments.css',
  'chat.html', 'chat.css', 'chat-bootstrap.js',
  'popup.js', 'popup.css', 'pdf-viewer.html', 'pdf-viewer.js', 'pdf-viewer.css',
  'ocr-offscreen.html', 'ocr-offscreen.js', 'vendor/ocr/worker.min.js',
  ...['lstm', 'simd-lstm', 'relaxedsimd-lstm'].map((variant) => `vendor/ocr/tesseract-core-${variant}.wasm.js`),
  'vendor/ocr/lang/eng.traineddata.gz', 'vendor/ocr/lang/nor.traineddata.gz',
  'vendor/katex/katex.min.css', 'vendor/katex/LICENSE',
  'vendor/licenses/markdown-it.txt', 'vendor/licenses/highlight.js.txt',
  'vendor/pdfjs/pdf.min.mjs', 'vendor/pdfjs/pdf.worker.min.mjs',
  'vendor/pdfjs/images/annotation-note.svg', 'vendor/pdfjs/LICENSE'
].filter(Boolean);

for (const relative of required) await access(join(dist, relative));

for (const htmlFile of [manifest.options_page, manifest.action.default_popup, manifest.side_panel.default_path, 'chat.html', 'pdf-viewer.html', 'ocr-offscreen.html']) {
  const html = await readFile(join(dist, htmlFile), 'utf8');
  const remoteScript = /<script[^>]+src=["']https?:\/\//i.exec(html);
  if (remoteScript) throw new Error(`${htmlFile} loads remotely hosted code.`);
  if (/\son\w+\s*=/.test(html)) throw new Error(`${htmlFile} contains an inline event handler.`);
}

for (const jsFile of ['content.js', 'chatgpt-probe.js', 'service-worker.js', 'options.js', 'panel.js', 'chat-bootstrap.js', 'popup.js', 'pdf-viewer.js', 'ocr-offscreen.js']) {
  const source = await readFile(join(dist, jsFile), 'utf8');
  if (/\b(?:eval|Function)\s*\(/.test(source)) throw new Error(`${jsFile} contains dynamic code execution.`);
  if (/\bimport\s*\(\s*["']https?:\/\//.test(source)) throw new Error(`${jsFile} imports remote code.`);
}

for (const jsFile of ['content.js', 'service-worker.js', 'options.js', 'panel.js', 'popup.js']) {
  const source = await readFile(join(dist, jsFile), 'utf8');
  if (!source.includes('GPT NTNU')
      || !source.includes('https://llm.hpc.ntnu.no/v1/chat/completions')) {
    throw new Error(`${jsFile} is missing the GPT NTNU provider.`);
  }
}

const fonts = await readdir(join(dist, 'vendor', 'katex', 'fonts'));
if (!fonts.some((name) => name.endsWith('.woff2'))) throw new Error('KaTeX fonts were not packaged.');

const cmaps = await readdir(join(dist, 'vendor', 'pdfjs', 'cmaps'));
if (!cmaps.some((name) => name.endsWith('.bcmap'))) throw new Error('PDF.js character maps were not packaged.');
const standardFonts = await readdir(join(dist, 'vendor', 'pdfjs', 'standard_fonts'));
if (!standardFonts.some((name) => name.endsWith('.pfb'))) throw new Error('PDF.js standard fonts were not packaged.');

async function sizeOf(directory) {
  let total = 0;
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    total += entry.isDirectory() ? await sizeOf(path) : (await stat(path)).size;
  }
  return total;
}

const bytes = await sizeOf(dist);
console.log(`Chrome package smoke check passed (${(bytes / 1024 / 1024).toFixed(2)} MiB).`);
