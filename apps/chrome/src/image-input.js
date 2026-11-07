import { createHtmlElement } from './ui-primitives.js';

const MAX_IMAGE_FILE_BYTES = 25 * 1024 * 1024;
const MAX_IMAGE_EDGE = 1_800;

function imageFileLabel(file) {
  return String(file?.name || 'pasted image').trim() || 'pasted image';
}

export function clipboardImageFile(clipboardData) {
  const items = [...(clipboardData?.items || [])];
  const item = items.find((candidate) => candidate.kind === 'file' && String(candidate.type || '').startsWith('image/'));
  return item?.getAsFile?.()
    || [...(clipboardData?.files || [])].find((file) => String(file.type || '').startsWith('image/'))
    || null;
}

export async function normalizeImageFile(file) {
  if (!file || typeof file.size !== 'number' || !String(file.type || '').startsWith('image/')) {
    throw new Error('Choose or paste an image file.');
  }
  if (!file.size) throw new Error('The image is empty.');
  if (file.size > MAX_IMAGE_FILE_BYTES) {
    throw new Error(`The image “${imageFileLabel(file)}” is larger than 25 MB.`);
  }

  let bitmap;
  try {
    bitmap = await createImageBitmap(file);
  } catch {
    throw new Error(`Chrome could not read “${imageFileLabel(file)}”. Try PNG, JPEG, WebP, GIF, AVIF, or BMP.`);
  }

  try {
    if (!bitmap.width || !bitmap.height) throw new Error('The image has no visible pixels.');
    const scale = Math.min(1, MAX_IMAGE_EDGE / Math.max(bitmap.width, bitmap.height));
    const canvas = createHtmlElement('canvas');
    canvas.width = Math.max(1, Math.round(bitmap.width * scale));
    canvas.height = Math.max(1, Math.round(bitmap.height * scale));
    const context = canvas.getContext('2d');
    if (!context) throw new Error('Image preparation is unavailable.');
    context.fillStyle = '#fff';
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.imageSmoothingEnabled = true;
    context.imageSmoothingQuality = 'high';
    context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    return canvas.toDataURL('image/jpeg', 0.9);
  } finally {
    bitmap.close?.();
  }
}
