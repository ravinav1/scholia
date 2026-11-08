import { cp, mkdir, readFile, writeFile, access } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Copy the CPU runtime dependency closure and only this Mac's native binaries.
// No model weights are bundled: they are downloaded once into the user's cache.
const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const destination = resolve(process.argv[2]);
const copied = new Set();
await mkdir(join(destination, 'scripts'), { recursive: true });
await mkdir(join(destination, 'packages', 'search'), { recursive: true });
await writeFile(join(destination, 'package.json'), '{"type":"module","private":true}\n');
for (const name of ['semantic-embedding.js', 'semantic-index.js', 'semantic-search-worker.js'])
  await cp(join(root, 'packages', 'search', name), join(destination, 'packages', 'search', name));
await cp(join(root, 'scripts', 'semantic-search-bridge.mjs'), join(destination, 'scripts', 'semantic-search-bridge.mjs'));

async function packageDirectory(name, from) {
  const require = createRequire(join(from, 'package.json'));
  for (const base of require.resolve.paths(name) || []) {
    const candidate = join(base, name);
    try { await access(join(candidate, 'package.json')); return candidate; } catch {}
  }
  throw new Error(`Missing semantic search dependency: ${name}`);
}
async function copyPackage(name, from, optional = false) {
  let directory;
  try { directory = await packageDirectory(name, from); } catch (error) { if (optional) return; throw error; }
  if (copied.has(directory)) return;
  copied.add(directory);
  const metadata = JSON.parse(await readFile(join(directory, 'package.json'), 'utf8'));
  // Preserve npm's nested dependency layout when versions differ.
  const target = join(destination, directory.slice(root.length + 1));
  await mkdir(dirname(target), { recursive: true });
  await cp(directory, target, { recursive: true, dereference: true,
    filter: path => {
      if (/(?:\/\.git|\/test(?:s)?)(?:\/|$)/.test(path) || /\.(?:map|wasm)$/.test(path)) return false;
      const onnx = path.match(/\/bin\/napi-v\d+\/(darwin|linux|win32)(?:\/([^/]+))?/);
      if (onnx && (onnx[1] !== process.platform || (onnx[2] && onnx[2] !== process.arch))) return false;
      const prebuilt = path.match(/\/prebuilds\/([^/]+)/)?.[1];
      return !prebuilt || (prebuilt.startsWith(`${process.platform}-`) && prebuilt.includes(process.arch));
    } });
  for (const dependency of Object.keys(metadata.dependencies || {})) await copyPackage(dependency, directory);
  for (const dependency of Object.keys(metadata.optionalDependencies || {})) await copyPackage(dependency, directory, true);
}
await copyPackage('@huggingface/transformers', root);
await copyPackage('usearch', root);
console.log(`Bundled ${copied.size} local semantic search runtime packages.`);
