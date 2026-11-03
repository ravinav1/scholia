// Inspect ZIP members in memory. No extraction to disk, execution, or relationship fetching.
export async function archiveEntries(file) {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let end = -1;
  for (let at = bytes.length - 22; at >= Math.max(0, bytes.length - 65_557); at--) {
    if (view.getUint32(at, true) === 0x06054b50 && at + 22 + view.getUint16(at + 20, true) === bytes.length) { end = at; break; }
  }
  if (end < 0) throw new Error('The archive directory could not be read.');
  const count = view.getUint16(end + 10, true);
  if (count > 10_000 || view.getUint16(end + 4, true) || view.getUint16(end + 6, true)) throw new Error('Split, ZIP64, or very large archives need an exported copy.');
  let at = view.getUint32(end + 16, true);
  const entries = [];
  for (let index = 0; index < count; index++) {
    if (at + 46 > end || view.getUint32(at, true) !== 0x02014b50) throw new Error('The archive directory is incomplete.');
    const nameLength = view.getUint16(at + 28, true);
    const next = at + 46 + nameLength + view.getUint16(at + 30, true) + view.getUint16(at + 32, true);
    if (next > end) throw new Error('The archive entry is incomplete.');
    entries.push({ name: new TextDecoder().decode(bytes.subarray(at + 46, at + 46 + nameLength)), flags: view.getUint16(at + 8, true), method: view.getUint16(at + 10, true), size: view.getUint32(at + 20, true), expanded: view.getUint32(at + 24, true), local: view.getUint32(at + 42, true) });
    at = next;
  }
  let totalExpanded = 0;
  return { entries, async read(entry) {
    if (entry.flags & 1) throw new Error('Encrypted member');
    totalExpanded += entry.expanded;
    if (entry.expanded > 8_000_000 || totalExpanded > 24_000_000) throw new Error('Archive expansion limit reached');
    const local = entry.local;
    if (local + 30 > end || view.getUint32(local, true) !== 0x04034b50) throw new Error('Invalid member header');
    const start = local + 30 + view.getUint16(local + 26, true) + view.getUint16(local + 28, true);
    if (start + entry.size > end) throw new Error('Incomplete member');
    let data = bytes.subarray(start, start + entry.size);
    if (entry.method === 8) {
      const reader = new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate-raw')).getReader();
      const chunks = [];
      let length = 0;
      while (true) {
        const chunk = await reader.read();
        if (chunk.done) break;
        length += chunk.value.length;
        if (length > entry.expanded || length > 8_000_000) { await reader.cancel(); throw new Error('Member exceeds declared size'); }
        chunks.push(chunk.value);
      }
      data = new Uint8Array(await new Blob(chunks).arrayBuffer());
    } else if (entry.method !== 0) throw new Error('Unsupported compression');
    if (data.length !== entry.expanded) throw new Error('Invalid member size');
    return data;
  } };
}

export function decodeFileText(bytes, { stream = false } = {}) {
  const encoding = bytes[0] === 0xff && bytes[1] === 0xfe ? 'utf-16le'
    : bytes[0] === 0xfe && bytes[1] === 0xff ? 'utf-16be' : 'utf-8';
  const text = new TextDecoder(encoding, { fatal: true }).decode(bytes, { stream });
  if (/[\u0000-\u0008\u000e-\u001f]/.test(text)) throw new Error('Binary contents');
  return text;
}

export async function extractArchiveText(file, maxCharacters) {
  const archive = await archiveEntries(file);
  const simulink = /\.slx$/i.test(file.name);
  const entries = archive.entries.filter((entry) => !entry.name.endsWith('/'));
  // Model definitions and subsystem connections must precede cosmetic metadata.
  entries.sort((a, b) => (simulink ? Number(!/^simulink\/(blockdiagram|systems\/)/.test(a.name)) - Number(!/^simulink\/(blockdiagram|systems\/)/.test(b.name)) : 0) || a.name.localeCompare(b.name, 'en', { numeric: true }));
  let text = '';
  const omitted = [];
  for (const entry of entries) {
    if (text.length >= maxCharacters) { omitted.push(`${entry.name}: outside text budget`); continue; }
    try {
      const content = decodeFileText(await archive.read(entry));
      if (!content.trim()) continue;
      const part = `\n\n--- Archive member: ${entry.name} ---\n${content}`;
      const room = maxCharacters - text.length;
      text += part.slice(0, room);
      if (part.length > room) omitted.push(`${entry.name}: truncated`);
    } catch (error) { omitted.push(`${entry.name}: ${error.message}`); }
  }
  const detail = simulink
    ? 'Simulink model XML: blocks, parameters, connections, and available subsystem definitions. The model was not executed; external model references, MATLAB workspace values, data dictionaries, and simulation results require their own files.'
    : 'Readable archive members only. Embedded binary files, nested archives, macros, and external references are not interpreted.';
  return {
    text: text.trim(), status: 'partial', truncated: omitted.length > 0,
    notice: `${detail}${omitted.length ? ` Unread members (${omitted.length}): ${omitted.slice(0, 12).join('; ')}${omitted.length > 12 ? '; …' : ''}.` : ''}`,
  };
}
