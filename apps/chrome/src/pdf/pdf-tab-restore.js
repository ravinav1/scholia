import { pdfSourceRecordIsRestorable } from './pdf-source-store.js';
import { pdfViewerTabSourceId } from '../tab-context.js';

export async function restoredPdfTabTarget(tab, loadSource) {
  const sourceId = pdfViewerTabSourceId(tab);
  if (!tab?.id || !sourceId || typeof loadSource !== 'function') return null;
  const source = await loadSource(sourceId);
  if (!pdfSourceRecordIsRestorable(source)) return null;
  return { sourceId, url: source.pdfUrl };
}
