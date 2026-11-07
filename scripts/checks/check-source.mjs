import { execFileSync } from 'node:child_process';
import { readdirSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const ignoredDirectories = new Set([
  '.git',
  '.swiftpm',
  '.build',
  'dist',
  'node_modules',
  '.data',
  '.release',
  'output',
]);

function projectFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    if (entry.isDirectory() && ignoredDirectories.has(entry.name)) return [];
    const path = join(directory, entry.name);
    return entry.isDirectory() ? projectFiles(path) : [path];
  });
}

const files = projectFiles(projectRoot);
const javaScriptFiles = files.filter((file) => /\.(?:js|mjs)$/.test(file));
const jsonFiles = files.filter((file) => file.endsWith('.json'));

for (const file of javaScriptFiles) {
  execFileSync(process.execPath, ['--check', file], { stdio: 'inherit' });
}
for (const file of jsonFiles) {
  JSON.parse(await readFile(file, 'utf8'));
}

console.log(`Checked ${javaScriptFiles.length} JavaScript files and ${jsonFiles.length} JSON files.`);
