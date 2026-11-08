#!/usr/bin/env node
// Local compatibility patch for SwiftMath 1.7.3. Keep its resource bundle in the
// standard signed macOS Contents/Resources directory; preserve SwiftPM fallback
// for command-line executables and XCTest. See patches/SWIFTMATH.md.
import { createHash } from 'node:crypto';
import { readFile, rename, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const projectRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const expectedVersion = '1.7.3';
const expectedRevision = 'fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7';
const originalLookup = 'Bundle.module.url(forResource: "mathFonts"';
const packagedLookup = 'ScholiaSwiftMathResources.bundle.url(forResource: "mathFonts"';
const helper = `
// Scholia packaging compatibility for pinned SwiftMath 1.7.3.
// Bundle.module's generated app-root lookup does not search Contents/Resources.
// Evaluate its SwiftPM fallback only when no packaged resource bundle exists.
internal enum ScholiaSwiftMathResources {
    static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "SwiftMath_SwiftMath", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
}
`;
const sources = [
  { relative: 'Sources/SwiftMath/MathRender/MTFont.swift', count: 1,
    sha256: '7f1d49676eb867ddd40ab7e3d45df8c152a5eca011c1979a1283e6fa988d5d25', helper },
  { relative: 'Sources/SwiftMath/MathBundle/MathFont.swift', count: 2,
    sha256: '28b90ef540397a4fe94291ac5de6473890d1aff2618bd6c85211009b8b96bc3f', helper: '' },
];
const digest = value => createHash('sha256').update(value).digest('hex');
const occurrences = (value, token) => value.split(token).length - 1;

export async function patchSwiftMathResources(packageRoot) {
  const resolved = JSON.parse(await readFile(path.join(packageRoot, 'Package.resolved'), 'utf8'));
  const pin = resolved.pins.find(item => item.identity.toLowerCase() === 'swiftmath');
  if (pin?.state?.version !== expectedVersion || pin?.state?.revision !== expectedRevision) {
    throw new Error('SwiftMath resource patch requires pinned 1.7.3/fa8244ed; review patches/SWIFTMATH.md before updating.');
  }
  const checkout = path.join(packageRoot, '.build/checkouts/SwiftMath');
  // Validate every input before writing either source. Unknown/local edits fail
  // closed, including a changed upstream release under an unchanged lockfile.
  const edits = await Promise.all(sources.map(async source => {
    const file = path.join(checkout, source.relative);
    const current = await readFile(file, 'utf8');
    let original = current;
    if (digest(original) !== source.sha256) {
      if (source.helper && !current.endsWith(source.helper)) {
        throw new Error(`SwiftMath resource patch: unexpected source contents: ${file}`);
      }
      original = source.helper ? current.slice(0, -source.helper.length) : current;
      original = original.replaceAll(packagedLookup, originalLookup);
    }
    if (digest(original) !== source.sha256 || occurrences(original, originalLookup) !== source.count) {
      throw new Error(`SwiftMath resource patch: unexpected source contents: ${file}`);
    }
    const patched = original.replaceAll(originalLookup, packagedLookup) + source.helper;
    if (current !== original && current !== patched) {
      throw new Error(`SwiftMath resource patch: incomplete or unexpected patch: ${file}`);
    }
    return { file, current, patched };
  }));
  let changed = 0;
  for (const edit of edits) {
    if (edit.current === edit.patched) continue;
    // SwiftPM checkout files are read-only; publish a replacement in the same
    // directory without altering upstream git metadata or generated objects.
    const temporary = `${edit.file}.scholia-${process.pid}`;
    await writeFile(temporary, edit.patched, { flag: 'wx', mode: 0o644 });
    await rename(temporary, edit.file);
    changed += 1;
  }
  return { changed, version: expectedVersion, revision: expectedRevision };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = await patchSwiftMathResources(path.resolve(process.argv[2] ?? path.join(projectRoot, 'apps/macos')));
    console.log(`SwiftMath ${result.version} packaged-resource patch: ${result.changed ? 'applied' : 'already applied'}.`);
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
