#!/usr/bin/env node
// Reproducible, non-commercial verification fixtures from human digital ink.
// These are rasterizations of real pen strokes, not photographs of paper.
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { createCanvas, loadImage } from '@napi-rs/canvas';

const output = resolve(import.meta.dirname, '../output/paper-study');
const archive = resolve(output, 'mathwriting-2024-excerpt.tgz');
const source = 'https://storage.googleapis.com/mathwriting_data/mathwriting-2024-excerpt.tgz';
await mkdir(output, { recursive: true });
let bytes;
try { bytes = await readFile(archive); }
catch {
  const response = await fetch(source);
  if (!response.ok) throw new Error(`Dataset download failed: HTTP ${response.status}`);
  bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length > 5_000_000) throw new Error('Unexpectedly large dataset excerpt.');
  await writeFile(archive, bytes);
}
const selected = {
  'inverse-mistake': 'test/0333d9584ff7c0d0.inkml',
  'inverse-correct': 'test/0276c02c9b9222e9.inkml',
  'polynomial-valid': 'test/024279a4b8037bae.inkml',
};
const extracted = spawnSync('python3', ['-c', `
import sys,tarfile,xml.etree.ElementTree as ET,json
selected=json.loads(sys.argv[2]);result={}
with tarfile.open(sys.argv[1]) as archive:
 for name,path in selected.items():
  root=ET.fromstring(archive.extractfile('mathwriting-2024-excerpt/'+path).read())
  meta={e.attrib.get('type'):e.text for e in root if e.tag.endswith('annotation')}
  assert meta.get('inkCreationMethod')=='human', 'Only genuine human ink is allowed'
  strokes=[[[float(v) for v in p.strip().split()[:2]] for p in e.text.split(',')]
   for e in root if e.tag.endswith('trace')]
  result[name]={'strokes':strokes,'label':meta.get('normalizedLabel'),'id':meta['sampleId'],'path':path}
print(json.dumps(result))
`, archive, JSON.stringify(selected)], { encoding: 'utf8', maxBuffer: 2_000_000 });
if (extracted.status !== 0) throw new Error(extracted.stderr || 'Could not read InkML.');
const inks = JSON.parse(extracted.stdout);
const manifest = {
  source, sha256: createHash('sha256').update(bytes).digest('hex'),
  authors: 'Google LLC; MathWriting by Philippe Gervais, Anastasiia Fadeeva, Andrii Maksai',
  documentation: 'https://github.com/google-research/google-research/tree/master/mathwriting',
  license: 'CC BY-NC-SA 4.0', licenseURL: 'https://creativecommons.org/licenses/by-nc-sa/4.0/',
  scope: 'Non-commercial local verification only. Original human digital-pen strokes rasterized; not camera photographs. Partial, obscured, and unclear variants are simulated. Different writers are staged as revisions, not a real continuous session.',
  samples: [],
};
async function render(name, ink, variant = 'original') {
  const width = 1200, height = 500;
  const canvas = createCanvas(width, height), context = canvas.getContext('2d');
  context.fillStyle = '#fff'; context.fillRect(0, 0, width, height);
  const points = ink.strokes.flat(), xs = points.map(p => p[0]), ys = points.map(p => p[1]);
  const minX = Math.min(...xs), maxX = Math.max(...xs), minY = Math.min(...ys), maxY = Math.max(...ys);
  const scale = Math.min((width - 140) / (maxX - minX), (height - 140) / (maxY - minY), 5);
  const offsetX = (width - (maxX - minX) * scale) / 2, offsetY = (height - (maxY - minY) * scale) / 2;
  context.strokeStyle = '#161616'; context.fillStyle = '#161616';
  context.lineWidth = Math.max(2, scale * 2.1); context.lineCap = 'round'; context.lineJoin = 'round';
  const strokes = variant === 'partial' ? ink.strokes.slice(0, Math.max(2, Math.floor(ink.strokes.length * 0.45))) : ink.strokes;
  for (const stroke of strokes) {
    context.beginPath();
    stroke.forEach(([x, y], i) => context[i ? 'lineTo' : 'moveTo']((x - minX) * scale + offsetX, (y - minY) * scale + offsetY));
    context.stroke();
  }
  if (variant === 'obscured') {
    context.fillStyle = '#b1aaa2'; context.fillRect(width * .23, height * .15, width * .7, height * .75);
  }
  if (variant === 'unclear') {
    const tiny = createCanvas(45, 19), small = tiny.getContext('2d');
    small.drawImage(canvas, 0, 0, tiny.width, tiny.height);
    context.fillStyle = '#fff'; context.fillRect(0, 0, width, height);
    context.globalAlpha = .38; context.drawImage(tiny, 0, 0, width, height); context.globalAlpha = 1;
  }
  await writeFile(resolve(output, `${name}.jpg`), canvas.toBuffer('image/jpeg', 90));
  manifest.samples.push({ name, sampleID: ink.id, originalPath: ink.path, normalizedLabel: ink.label, variant });
}
for (const [name, ink] of Object.entries(inks)) await render(name, ink);
await render('inverse-incomplete', inks['inverse-mistake'], 'partial');
await render('inverse-obscured', inks['inverse-mistake'], 'obscured');
await render('inverse-unclear', inks['inverse-mistake'], 'unclear');
// Original human expressions are staged on one sheet; only the crossing-out
// strokes and their placement are synthetic, as recorded in the provenance.
const revised = createCanvas(1200, 900), revisionContext = revised.getContext('2d');
revisionContext.fillStyle = '#fff'; revisionContext.fillRect(0, 0, 1200, 900);
revisionContext.drawImage(await loadImage(resolve(output, 'inverse-mistake.jpg')), 20, 0, 1160, 480);
revisionContext.drawImage(await loadImage(resolve(output, 'inverse-correct.jpg')), 20, 410, 1160, 480);
revisionContext.strokeStyle = '#161616'; revisionContext.lineWidth = 5;
revisionContext.beginPath(); revisionContext.moveTo(75, 200); revisionContext.lineTo(1130, 245);
revisionContext.moveTo(75, 242); revisionContext.lineTo(1130, 205); revisionContext.stroke();
await writeFile(resolve(output, 'inverse-crossed-out.jpg'), revised.toBuffer('image/jpeg', 90));
manifest.samples.push({ name: 'inverse-crossed-out', sourceSampleIDs: [inks['inverse-mistake'].id, inks['inverse-correct'].id],
  variant: 'Two human ink expressions composited as a revision; synthetic crossing-out strokes over the earlier incorrect expression.' });
const problemPage = createCanvas(1200, 650), problemContext = problemPage.getContext('2d');
problemContext.fillStyle = '#fff'; problemContext.fillRect(0, 0, 1200, 650);
problemContext.fillStyle = '#161616'; problemContext.font = '30px Arial';
problemContext.fillText('Problem: Find the inverse FUNCTION of f(x) = x², for x ≥ 0.', 40, 65);
problemContext.drawImage(await loadImage(resolve(output, 'inverse-mistake.jpg')), 0, 110, 1200, 500);
await writeFile(resolve(output, 'inverse-problem-page.jpg'), problemPage.toBuffer('image/jpeg', 90));
manifest.samples.push({ name: 'inverse-problem-page', sourceSampleIDs: [inks['inverse-mistake'].id],
  variant: 'Original human ink beneath a synthetic PRINTED problem header. Tests an image-only problem reference across confirmed pages; the header is not human handwriting.' });
await writeFile(resolve(output, 'handwriting-provenance.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log(`Prepared ${manifest.samples.length} attributed human-ink fixtures in ${output}`);
