import { build } from 'esbuild';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { gzipSync } from 'node:zlib';

const stage = process.argv.includes('--baseline') ? 'before' : process.argv.includes('--after-removal') ? 'after-removal' : 'after';
const { metafile } = await build({ entryPoints:['apps/chrome/src/content.js'], bundle:true, minify:true, write:false, metafile:true, format:'iife', loader:{'.css':'text'}, logLevel:'silent' });
const initial = await readFile('dist/chrome/content.js');
const deferred = await readFile('dist/chrome/content-ui.js').catch(() => null);
const context = await readFile('dist/chrome/content-context.js').catch(() => null);
const report = { node:process.version, initialBytes:initial.length, initialGzipBytes:gzipSync(initial).length, initialModuleCount:Object.keys(metafile.inputs).length,
  ...(deferred ? {deferredBytes:deferred.length,deferredGzipBytes:gzipSync(deferred).length}:{}), ...(context ? {contextOnlyBytes:context.length}:{}), inputs:Object.keys(metafile.inputs) };
await mkdir('results/performance', {recursive:true});
await writeFile(`results/performance/extension-bundle-${stage}.json`,JSON.stringify(report,null,2)+'\n');
console.log(JSON.stringify(report,null,2));
