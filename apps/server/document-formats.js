import { extname } from 'node:path';

const binaryExtensions = new Set([
  'zip',
  'gz',
  'bz2',
  'xz',
  '7z',
  'rar',
  'tar',
  'doc',
  'ppt',
  'xls',
  'rtf',
  'pages',
  'numbers',
  'key',
  'mp3',
  'mp4',
  'mov',
  'wav',
  'ogg',
  'aiff',
  'flac',
  'heic',
  'tiff',
  'tif',
  'bmp',
  'ico',
  'svg',
  'exe',
  'dll',
  'so',
  'dylib',
  'dmg',
  'pkg',
  'wasm',
  'bin',
  'sqlite',
  'db',
  'parquet',
  'h5',
  'hdf5',
  'npy',
  'npz',
]);
export const textIndexVersion = 3;

export function safePlainText(bytes, extension) {
  if (binaryExtensions.has(extension) || bytes.length > 32_000_000) return null;
  try {
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    return text.length <= 8_000_000 &&
      !/[\u0000-\u0008\u000b\u000e-\u001f\u007f-\u009f]/u.test(text)
      ? text
      : null;
  } catch {
    return null;
  }
}

export function needsTextIndexUpgrade(document) {
  return (
    ['preview', 'image', 'pdf'].includes(document?.kind) &&
    document.indexVersion !== textIndexVersion &&
    !binaryExtensions.has(extname(document.fileName).slice(1).toLowerCase()) &&
    (document.byteCount || 0) <= 20_000_000
  );
}

export function unreadablePageCount(pages) {
  return pages.filter(
    (page) =>
      !page.text
        .replace(/^```\n/, '')
        .replace(/\n```$/, '')
        .trim()
  ).length;
}
