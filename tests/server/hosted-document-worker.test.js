import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { Documents } from '../../apps/server/documents/documents.js';
import { spawnSync, execFileSync } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';

test('unknown scientific text extensions are indexed without treating binaries as text', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'scholia-worker-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const documents = new Documents(root),
    user = randomUUID();
  for (const name of ['in.nanowire', 'Ni.eam', 'parameters.dat', 'input']) {
    const text = Buffer.from('units metal\n# nickel potential\t58.6934\r\nÅngström\fend');
    const doc = await documents.import(user, name, text);
    assert.equal(doc.kind, 'code', name);
    assert.equal(doc.unreadablePages, 0);
    assert.deepEqual(await documents.data(user, doc), text);
    assert.match((await documents.index(user, doc)).pages[0].text, /nickel potential/);
  }
  for (const [name, data] of [
    ['archive.zip', Buffer.from('ASCII but known archive extension')],
    ['opaque.bin', Buffer.from('ASCII but known binary extension')],
    [
      'unknown.part',
      Buffer.concat([Buffer.from('Printable prefix '.repeat(1000)), Buffer.from([0])]),
    ],
    ['unknown.utf8', Buffer.from([0xc3, 0x28])],
    ['unknown.control', Buffer.from('Text with an escape\x1bcode')],
  ]) {
    const doc = await documents.import(user, name, data);
    assert.equal(doc.kind, 'preview', name);
    assert.equal(doc.unreadablePages, 1);
    assert.match(doc.contentNotice, /no readable text/);
    assert.equal((await documents.index(user, doc)).pages[0].text, '');
    assert.deepEqual(await documents.data(user, doc), data);
  }
  const image = await documents.import(user, 'diagram.png', Buffer.from('image fixture'));
  assert.equal(image.unreadablePages, 1);
});

test('document index cache deduplicates reads, isolates accounts, evicts and invalidates on replacement', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'scholia-index-cache-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const documents = new Documents(root, { maxIndexBytes: 1000, maxIndexEntries: 1 });
  const user = randomUUID(),
    other = randomUUID();
  const doc = await documents.import(user, 'notes.txt', Buffer.from('First revision'));
  const [first, concurrent] = await Promise.all([
    documents.index(user, doc),
    documents.index(user, doc),
  ]);
  assert.equal(first, concurrent, 'simultaneous readers share parsing');
  assert.equal(await documents.index(user, doc), first, 'unchanged pages are reused');
  const privateDoc = await documents.import(other, 'private.txt', Buffer.from('Other account'), {
    id: doc.id,
  });
  assert.equal((await documents.index(other, privateDoc)).pages[0].text, 'Other account');
  assert.equal(documents.indexCache.size, 1);
  assert.notEqual(
    await documents.index(user, doc),
    first,
    'LRU evicts when entry limit is reached'
  );
  const replacement = await documents.import(user, 'notes.txt', Buffer.from('Second revision'), {
    id: doc.id,
  });
  assert.equal((await documents.index(user, replacement)).pages[0].text, 'Second revision');
  const large = await documents.import(user, 'large.txt', Buffer.from('a'.repeat(1500)));
  await documents.index(user, large);
  assert.ok(documents.indexBytes <= 1000);
  assert.ok(
    !documents.indexCache.has(documents.directory(user, large.id)),
    'oversized index is not retained'
  );
});

function scannedPdf(jpeg, width, height) {
  const drawing = 'q 612 0 0 344 0 448 cm /Scan Do Q';
  const objects = [
    Buffer.from('<< /Type /Catalog /Pages 2 0 R >>'),
    Buffer.from('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    Buffer.from(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Scan 4 0 R >> >> /Contents 5 0 R >>'
    ),
    Buffer.concat([
      Buffer.from(
        `<< /Type /XObject /Subtype /Image /Width ${width} /Height ${height} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>\nstream\n`
      ),
      jpeg,
      Buffer.from('\nendstream'),
    ]),
    Buffer.from(`<< /Length ${drawing.length} >>\nstream\n${drawing}\nendstream`),
  ];
  const chunks = [Buffer.from('%PDF-1.4\n')],
    offsets = [];
  let length = chunks[0].length;
  for (const [i, object] of objects.entries()) {
    offsets.push(length);
    const chunk = Buffer.concat([
      Buffer.from(`${i + 1} 0 obj\n`),
      object,
      Buffer.from('\nendobj\n'),
    ]);
    chunks.push(chunk);
    length += chunk.length;
  }
  chunks.push(
    Buffer.from(
      `xref\n0 6\n0000000000 65535 f \n${offsets.map((offset) => `${String(offset).padStart(10, '0')} 00000 n \n`).join('')}trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n${length}\n%%EOF\n`
    )
  );
  return Buffer.concat(chunks);
}

test('local OCR indexes a raster image and a scanned PDF for content classification', async (t) => {
  if (
    process.env.SCHOLIA_OCR === 'off' ||
    spawnSync(process.env.SCHOLIA_TESSERACT || 'tesseract', ['--version']).status !== 0
  ) {
    t.skip('Optional local Tesseract is not installed or enabled');
    return;
  }
  // Keep fixture bitmap allocations outside the process running import workers.
  const fixture = JSON.parse(
    execFileSync(
      process.execPath,
      [
        '--input-type=module',
        '-e',
        `
    import { createCanvas } from '@napi-rs/canvas';
    const canvas = createCanvas(1600, 900), context = canvas.getContext('2d');
    context.fillStyle = 'white'; context.fillRect(0, 0, 1600, 900);
    context.fillStyle = 'black'; context.font = '52px sans-serif';
    ['Study notes', 'Eigenvectors and bases', 'Linear transformations preserve vector spaces', 'Diagonalization gives a useful matrix representation'].forEach((line, index) => context.fillText(line, 70, 100 + index * 130));
    process.stdout.write(JSON.stringify({ png: canvas.toBuffer('image/png').toString('base64'), jpeg: canvas.toBuffer('image/jpeg').toString('base64') }));
  `,
      ],
      { maxBuffer: 1_000_000, encoding: 'utf8' }
    )
  );
  const root = await mkdtemp(join(tmpdir(), 'scholia-local-ocr-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const documents = new Documents(root),
    user = randomUUID();
  for (const [name, data] of [
    ['scan.png', Buffer.from(fixture.png, 'base64')],
    ['scan.pdf', scannedPdf(Buffer.from(fixture.jpeg, 'base64'), 1600, 900)],
  ]) {
    const doc = await documents.import(user, name, data);
    assert.equal(doc.unreadablePages, 0, name);
    assert.equal(doc.materialAnalysis.categoryID, 'notes', name);
    assert.equal(doc.materialAnalysis.topic, 'Eigenvectors and bases', name);
    assert.equal(doc.materialAnalysis.extractionMethod, 'ocr', name);
    assert.match((await documents.index(user, doc)).pages[0].text, /Eigenvectors and bases/, name);
    assert.match(doc.contentNotice, /OCR/, name);
    assert.deepEqual(await documents.data(user, doc), data, 'OCR preserves originals');
  }
});

test('canceling OCR kills its local process and does not publish a document index', async (t) => {
  if (process.platform === 'win32') {
    t.skip('Executable fixture uses a POSIX shebang');
    return;
  }
  const root = await mkdtemp(join(tmpdir(), 'scholia-cancel-ocr-'));
  const executable = join(root, 'ocr-fixture'),
    pidFile = join(root, 'pid');
  await writeFile(
    executable,
    `#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(pidFile)}, String(process.pid)); setInterval(() => {}, 1000);\n`,
    { mode: 0o700 }
  );
  const previous = process.env.SCHOLIA_TESSERACT,
    previousEnabled = process.env.SCHOLIA_OCR;
  process.env.SCHOLIA_TESSERACT = executable;
  delete process.env.SCHOLIA_OCR;
  let pid;
  t.after(async () => {
    if (previous === undefined) delete process.env.SCHOLIA_TESSERACT;
    else process.env.SCHOLIA_TESSERACT = previous;
    if (previousEnabled === undefined) delete process.env.SCHOLIA_OCR;
    else process.env.SCHOLIA_OCR = previousEnabled;
    if (pid) {
      try {
        process.kill(pid, 'SIGKILL');
      } catch {}
    }
    await rm(root, { recursive: true, force: true });
  });
  const documents = new Documents(root),
    user = randomUUID(),
    id = randomUUID(),
    controller = new AbortController();
  const importing = documents.import(user, 'scan.png', Buffer.from('OCR fixture input'), {
    id,
    signal: controller.signal,
  });
  const rejected = assert.rejects(importing, { name: 'AbortError' });
  for (let i = 0; i < 120 && !pid; i++) {
    pid = Number(await readFile(pidFile, 'utf8').catch(() => 0));
    if (!pid) await delay(25);
  }
  assert.ok(pid, 'local OCR process started');
  controller.abort();
  await rejected;
  for (let i = 0; i < 80; i++) {
    try {
      process.kill(pid, 0);
    } catch {
      break;
    }
    await delay(25);
  }
  assert.throws(() => process.kill(pid, 0), { code: 'ESRCH' });
  assert.deepEqual(await readdir(documents.directory(user, id)).catch(() => []), []);
  assert.equal(documents.active, 0);
});
