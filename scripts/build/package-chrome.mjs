import { execFile } from 'node:child_process';
import { mkdir, readFile, readdir, rm } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { isChromeExtensionVersion } from './chrome-extension-version.mjs';

const run = promisify(execFile);
const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const packageJson = JSON.parse(await readFile(join(projectRoot, 'package.json'), 'utf8'));
const version = String(packageJson.version || '').trim();

if (!isChromeExtensionVersion(version)) {
  throw new Error(`package.json version ${JSON.stringify(version)} is not valid for Chrome.`);
}

const distRoot = join(projectRoot, 'dist');
const extensionRoot = join(distRoot, 'chrome');
const archive = join(distRoot, `scholia-chrome-${version}.zip`);

await mkdir(distRoot, { recursive: true });
await run(process.execPath, ['scripts/build/build-chrome.mjs'], {
  cwd: projectRoot,
  env: { ...process.env, SCHOLIA_EXTENSION_VERSION: version }
});
await run(process.execPath, ['scripts/checks/check-chrome-dist.mjs'], { cwd: projectRoot });
await rm(archive, { force: true });
await run('zip', ['-q', '-r', archive, '.'], { cwd: extensionRoot });

const { stdout: listing } = await run('unzip', ['-Z1', archive], { cwd: projectRoot });
const entries = listing.trim().split('\n');
if (!entries.includes('manifest.json')) {
  throw new Error('Packaged archive does not contain manifest.json at its root.');
}

for (const entry of await readdir(distRoot, { withFileTypes: true })) {
  if (entry.isFile() && /^scholia-chrome-\d+(?:\.\d+){0,3}\.zip$/.test(entry.name)
      && join(distRoot, entry.name) !== archive) {
    await rm(join(distRoot, entry.name));
  }
}

console.log(`Packaged Chrome Web Store upload: ${archive}`);
