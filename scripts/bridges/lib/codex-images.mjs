import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import { join } from 'node:path';

const MAX_IMAGES = 4;
const MAX_TOTAL_IMAGE_BYTES = 7 * 1024 * 1024;
const EXTENSIONS = new Map([
  ['image/png', 'png'],
  ['image/jpeg', 'jpg'],
  ['image/webp', 'webp'],
  ['image/gif', 'gif']
]);

function encodedImage(part) {
  if (part?.type === 'image' && part.source?.type === 'base64') {
    return { mediaType: part.source.media_type, base64: part.source.data };
  }
  if (part?.type !== 'image_url' && part?.type !== 'input_image') return null;
  const url = part.type === 'image_url'
    ? (typeof part.image_url === 'string' ? part.image_url : part.image_url?.url)
    : part.image_url || part.url;
  if (typeof url !== 'string') return null;
  const match = /^data:([^;,]+);base64,([a-z0-9+/=\r\n]+)$/i.exec(url);
  if (!match) throw new Error('Codex image attachments must use base64 data URLs.');
  return { mediaType: match[1], base64: match[2] };
}

function decodeImage(image) {
  const mediaType = String(image.mediaType || '').toLowerCase();
  const extension = EXTENSIONS.get(mediaType);
  if (!extension) throw new Error(`Codex does not accept ${mediaType || 'this image format'} through this bridge.`);
  const base64 = String(image.base64 || '').replace(/\s/g, '');
  if (!base64 || !/^[a-z0-9+/]*={0,2}$/i.test(base64) || base64.length % 4 === 1) {
    throw new Error('An image attachment has invalid base64 data.');
  }
  const bytes = Buffer.from(base64, 'base64');
  if (!bytes.length || bytes.toString('base64').replace(/=+$/, '') !== base64.replace(/=+$/, '')) {
    throw new Error('An image attachment has invalid base64 data.');
  }
  return { bytes, extension };
}

export function materializeCodexImages(messages, { temporaryRoot = os.tmpdir() } = {}) {
  const encoded = [];
  for (const message of messages || []) {
    if (message?.role !== 'user' || !Array.isArray(message.content)) continue;
    for (const part of message.content) {
      const image = encodedImage(part);
      if (image) encoded.push(image);
    }
  }
  if (!encoded.length) return { paths: [], cleanup() {} };
  if (encoded.length > MAX_IMAGES) throw new Error(`Codex accepts at most ${MAX_IMAGES} images per request.`);

  const decoded = encoded.map(decodeImage);
  const totalBytes = decoded.reduce((total, image) => total + image.bytes.length, 0);
  if (totalBytes > MAX_TOTAL_IMAGE_BYTES) throw new Error('Codex image attachments exceed the 7 MB bridge limit.');

  const directory = mkdtempSync(join(temporaryRoot, 'scholia-codex-images-'));
  let cleaned = false;
  try {
    const paths = decoded.map((image, index) => {
      const path = join(directory, `image-${index + 1}.${image.extension}`);
      writeFileSync(path, image.bytes, { mode: 0o600 });
      return path;
    });
    return {
      paths,
      cleanup() {
        if (cleaned) return;
        cleaned = true;
        rmSync(directory, { recursive: true, force: true });
      }
    };
  } catch (error) {
    rmSync(directory, { recursive: true, force: true });
    throw error;
  }
}
