import { cp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { isChromeExtensionVersion, localChromeExtensionVersion } from './lib/chrome-extension-version.mjs';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const chromeRoot = join(projectRoot, 'apps', 'chrome');
const sourceRoot = join(chromeRoot, 'src');
const outputRoot = join(projectRoot, 'dist', 'chrome');
const outputManifestPath = join(outputRoot, 'manifest.json');
const buildStartedAt = new Date();
let previousBuildVersion = '';
try {
  previousBuildVersion = JSON.parse(await readFile(outputManifestPath, 'utf8')).version || '';
} catch {}

await rm(outputRoot, { recursive: true, force: true });
await mkdir(outputRoot, { recursive: true });

const shared = {
  bundle: true,
  minify: true,
  sourcemap: false,
  target: ['chrome116'],
  legalComments: 'none',
  logLevel: 'info'
};

const katexStringRenderer = {
  name: 'katex-string-renderer',
  setup(buildContext) {
    buildContext.onLoad({ filter: /[/\\]katex[/\\]dist[/\\]katex\.mjs$/ }, async ({ path }) => {
      const source = await readFile(path, 'utf8');
      const guardStart = source.indexOf('// KaTeX\'s styles don\'t work properly in quirks mode.');
      const guardEnd = source.indexOf('/**\n * Parse and build an expression, and return the markup for that.', guardStart);
      if (guardStart < 0 || guardEnd < 0) throw new Error('Could not isolate the KaTeX DOM-rendering guard.');
      return { contents: `${source.slice(0, guardStart)}${source.slice(guardEnd)}`, loader: 'js' };
    });
  }
};

await build({
  ...shared,
  entryPoints: [join(sourceRoot, 'content.js')],
  outfile: join(outputRoot, 'content.js'),
  format: 'iife',
  loader: { '.css': 'text' },
  plugins: [katexStringRenderer]
});

await build({
  ...shared,
  entryPoints: [join(sourceRoot, 'chatgpt-probe.js')],
  outfile: join(outputRoot, 'chatgpt-probe.js'),
  format: 'iife'
});

await build({
  ...shared,
  entryPoints: [join(sourceRoot, 'service-worker.js')],
  outfile: join(outputRoot, 'service-worker.js'),
  format: 'esm'
});

await Promise.all([
  build({
    ...shared,
    entryPoints: [join(sourceRoot, 'options.js')],
    outfile: join(outputRoot, 'options.js'),
    format: 'esm'
  }),
  build({
    ...shared,
    entryPoints: [join(sourceRoot, 'panel.js')],
    outfile: join(outputRoot, 'panel.js'),
    format: 'esm'
  }),
  build({
    ...shared,
    entryPoints: [join(sourceRoot, 'popup.js')],
    outfile: join(outputRoot, 'popup.js'),
    format: 'esm'
  }),
  build({
    ...shared,
    entryPoints: [join(sourceRoot, 'pdf-viewer.js')],
    outfile: join(outputRoot, 'pdf-viewer.js'),
    format: 'esm'
  }),
  build({
    ...shared,
    entryPoints: [join(sourceRoot, 'ocr-offscreen.js')],
    outfile: join(outputRoot, 'ocr-offscreen.js'),
    format: 'esm'
  })
]);

for (const file of [
  'manifest.json',
  'options.html', 'options.css',
  'panel.html', 'panel.css', 'file-attachments.css',
  'chat.html', 'chat.css', 'chat-bootstrap.js',
  'popup.html', 'popup.css',
  'pdf-viewer.html', 'pdf-viewer.css', 'ocr-offscreen.html'
]) {
  await cp(join(chromeRoot, file), join(outputRoot, file));
}
await cp(join(chromeRoot, 'assets'), join(outputRoot, 'assets'), { recursive: true });
await cp(join(projectRoot, 'LICENSE'), join(outputRoot, 'LICENSE'));

const katexRoot = join(projectRoot, 'node_modules', 'katex', 'dist');
const katexOutput = join(outputRoot, 'vendor', 'katex');
await mkdir(katexOutput, { recursive: true });
await cp(join(katexRoot, 'katex.min.css'), join(katexOutput, 'katex.min.css'));
await cp(join(katexRoot, 'fonts'), join(katexOutput, 'fonts'), { recursive: true });
await cp(join(projectRoot, 'node_modules', 'katex', 'LICENSE'), join(katexOutput, 'LICENSE'));

const licenseOutput = join(outputRoot, 'vendor', 'licenses');
await mkdir(licenseOutput, { recursive: true });
await cp(join(projectRoot, 'node_modules', 'markdown-it', 'LICENSE'), join(licenseOutput, 'markdown-it.txt'));
await cp(join(projectRoot, 'node_modules', 'highlight.js', 'LICENSE'), join(licenseOutput, 'highlight.js.txt'));

const pdfjsRoot = join(projectRoot, 'node_modules', 'pdfjs-dist');
const pdfjsOutput = join(outputRoot, 'vendor', 'pdfjs');
await mkdir(pdfjsOutput, { recursive: true });
await cp(join(pdfjsRoot, 'legacy', 'build', 'pdf.min.mjs'), join(pdfjsOutput, 'pdf.min.mjs'));
await cp(join(pdfjsRoot, 'legacy', 'build', 'pdf.worker.min.mjs'), join(pdfjsOutput, 'pdf.worker.min.mjs'));
await cp(join(pdfjsRoot, 'cmaps'), join(pdfjsOutput, 'cmaps'), { recursive: true });
await cp(join(pdfjsRoot, 'standard_fonts'), join(pdfjsOutput, 'standard_fonts'), { recursive: true });
await cp(join(pdfjsRoot, 'web', 'images'), join(pdfjsOutput, 'images'), { recursive: true });
await cp(join(pdfjsRoot, 'LICENSE'), join(pdfjsOutput, 'LICENSE'));

// OCR runs fully inside the extension; neither code nor language data uses a CDN.
const ocrRoot = join(outputRoot, 'vendor', 'ocr');
await mkdir(join(ocrRoot, 'lang'), { recursive: true });
await cp(join(projectRoot, 'node_modules/tesseract.js/dist/worker.min.js'), join(ocrRoot, 'worker.min.js'));
await cp(join(projectRoot, 'node_modules/tesseract.js/LICENSE.md'), join(licenseOutput, 'tesseract.js.txt'));
await cp(join(projectRoot, 'node_modules/tesseract.js-core/LICENSE'), join(licenseOutput, 'tesseract.js-core.txt'));
for (const variant of ['lstm', 'simd-lstm', 'relaxedsimd-lstm']) {
  const name = `tesseract-core-${variant}.wasm.js`;
  await cp(join(projectRoot, 'node_modules/tesseract.js-core', name), join(ocrRoot, name));
}
for (const language of ['eng', 'nor']) {
  await cp(join(projectRoot, `node_modules/@tesseract.js-data/${language}/4.0.0_best_int/${language}.traineddata.gz`),
    join(ocrRoot, 'lang', `${language}.traineddata.gz`));
}

const manifest = JSON.parse(await readFile(outputManifestPath, 'utf8'));
const requestedVersion = String(process.env.SCHOLIA_EXTENSION_VERSION || '').trim();
manifest.version = requestedVersion || localChromeExtensionVersion(buildStartedAt, previousBuildVersion);
if (!isChromeExtensionVersion(manifest.version)) {
  throw new Error(`Invalid Chrome extension version: ${manifest.version}`);
}
if (!requestedVersion) delete manifest.version_name;
await writeFile(outputManifestPath, `${JSON.stringify(manifest, null, 2)}\n`);

console.log(`Chrome extension ${manifest.version_name || manifest.version} built at ${outputRoot}`);
