import { extractPdfContext } from './pdf-context.js';
import { normalizeImageFile } from './image-input.js';
import { extractOfficeText } from './office-text.js';
import { decodeFileText, extractArchiveText } from './archive-text.js';

export const MAX_FILE_BYTES = 25 * 1024 * 1024;
export const MAX_EXTRACTED_FILE_CHARACTERS = 50_000_000;

function attachmentID() {
  if (globalThis.crypto.randomUUID) return globalThis.crypto.randomUUID();
  // Content-script dialogs can run on HTTP pages, where randomUUID is absent.
  const bytes = globalThis.crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = bytes[6] & 0x0f | 0x40;
  bytes[8] = bytes[8] & 0x3f | 0x80;
  const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export async function readChatFile(file, { signal, pdfReader = extractPdfContext } = {}) {
  const base = { id: attachmentID(), name: file?.name || 'Attached file', size: file?.size || 0, mimeType: file?.type || 'application/octet-stream', enabled: true };
  const unavailable = (notice) => ({ ...base, text: '', status: 'unavailable', notice });
  if (!file?.size) return unavailable('This file is empty. No contents are available.');
  if (file.size > MAX_FILE_BYTES) return unavailable('Attached, but not read: this file exceeds the 25 MB browser extraction limit. Attach a smaller export or relevant sections.');
  try {
  signal?.throwIfAborted();
  if (/\.(docx|pptx|xlsx|docm|pptm|xlsm)$/i.test(file.name)) return { ...base, ...await extractOfficeText(file, MAX_EXTRACTED_FILE_CHARACTERS), status: 'partial', notice: 'Document text and saved cell values only. Images, charts, formatting, macros, and external links are not read or executed.' };
  if (/\.(slx|mlx|zip|odt|ods|odp|epub|jar|fmu)$/i.test(file.name)) {
    const archive = await extractArchiveText(file, MAX_EXTRACTED_FILE_CHARACTERS);
    return { ...base, ...archive, status: archive.text ? 'partial' : 'unavailable' };
  }
  if (String(file.type).startsWith('image/')) {
    return { ...base, imageDataUrl: await normalizeImageFile(file), status: 'readable', notice: 'Image supplied to the model for visual inspection.' };
  }
  if (file.type === 'application/pdf' || /\.pdf$/i.test(file.name)) {
    const pdf = await pdfReader(file, { signal, maxCharacters: MAX_EXTRACTED_FILE_CHARACTERS });
    if (!pdf.extractedCharacters) throw new Error(`“${file.name}” has no readable text after local OCR. Try a clearer scan or attach page images.`);
    return { ...base, mimeType: 'application/pdf', text: pdf.context, status: 'partial', notice: `Extracted PDF text and available OCR only. Diagrams and page images are not included; attach relevant images when needed.${pdf.truncated ? ' Extraction reached its processing limit; later text was not read.' : ''}`, truncated: pdf.truncated };
  }
  const bytes = new Uint8Array(await file.arrayBuffer());
  const text = decodeFileText(bytes);
  if (!text.trim()) throw new Error(`“${file.name}” has no readable text.`);
  const model = /\.(mdl|m|ssc)$/i.test(file.name);
  return { ...base, text, truncated: false, status: model ? 'partial' : 'readable', notice: model ? 'Complete source text retained. Not executed; referenced models, scripts, workspace values, and data files must be attached separately.' : 'Complete text extracted and retained; relevant excerpts are chosen for each question.' };
  } catch (error) {
    if (signal?.aborted || error.name === 'AbortError') throw error;
    return unavailable(`Attached, but its contents could not be read: ${error.message}. Provide a readable export, screenshots, transcript, or the relevant details. Do not infer contents from the filename.`);
  }
}
