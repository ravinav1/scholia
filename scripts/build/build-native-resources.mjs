import { build } from 'esbuild';
import { mkdir, copyFile } from 'node:fs/promises';
import { resolve } from 'node:path';
const root = resolve(import.meta.dirname, '../..');
const output = resolve(root, 'dist/native-resources');
await mkdir(output, { recursive: true });
await Promise.all([
  build({ entryPoints: [resolve(root, 'apps/chrome/src/pdf/pdf-search.js')], outfile: resolve(output, 'pdf-search.js'), bundle: true, format: 'iife', globalName: 'ScholiaDocumentSearch', target: 'safari17', minify: true }),
  build({ entryPoints: [resolve(root, 'packages/core/src/code-highlight.js')], outfile: resolve(output, 'code-highlight.js'), bundle: true, format: 'iife', globalName: 'ScholiaCodeHighlight', target: 'safari17', minify: true, legalComments: 'eof' }),
  copyFile(resolve(root, 'packages/core/data/ntnu-study-plans.json'), resolve(output, 'ntnu-study-plans.json')),
]);
console.log('Built native JavaScriptCore helpers and study-plan data in dist/native-resources.');
