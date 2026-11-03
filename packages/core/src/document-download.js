const cleanName = (value) =>
  String(value || '')
    .replace(/[\x00-\x1f\x7f/\\:*?"<>|]+/g, '-')
    .replace(/^[.\s]+|[.\s]+$/g, '');
const basename = (value) =>
  cleanName(
    String(value || '')
      .replaceAll('\\', '/')
      .split('/')
      .at(-1)
  );
const storageName = (name) => /^original(?:\.[^.]+)?$/i.test(name);
const extension = (name) => /\.([^.]+)$/.exec(name)?.[1] || '';

// fileName may be Scholia's storage name. Keep it separate from the exported name.
export function documentDownloadFilename(document, course) {
  const reference = document.sourceKey
    ? course?.canvasMaterials?.find((item) => item.id === document.sourceKey)
    : null;
  const sourceName = [document.originalFileName, reference?.fileName, document.fileName]
    .map(basename)
    .find((name) => name && !storageName(name));
  const storedExtension = extension(basename(document.fileName));
  let name = sourceName;
  if (!name) {
    const title = cleanName(document.title);
    const label = cleanName(course?.code) || cleanName(course?.name);
    name = [label, title && !storageName(title) ? title : 'Document'].filter(Boolean).join(' - ');
  }
  // Native image imports are converted to JPEG; retain the actual saved format.
  const suffix = document.kind === 'pdf' ? 'pdf' : storedExtension;
  if (suffix && (!sourceName || document.kind === 'pdf' || document.kind === 'image')) {
    if (!name.toLowerCase().endsWith(`.${suffix.toLowerCase()}`)) {
      if (document.kind === 'image' && sourceName) name = name.replace(/\.[^.]+$/, '');
      name += `.${suffix}`;
    }
  }
  return name;
}
