import { DOMParser } from 'linkedom';
import { canvasDocumentLinks } from '../../packages/core/src/canvas-links.js';
export { canvasContentLink } from '../../packages/core/src/canvas-links.js';

export function canvasContentLinks(html, origin, courseID, sourceURL) {
  const doc = new DOMParser().parseFromString(`<html><body>${html || ''}</body></html>`, 'text/html');
  return canvasDocumentLinks(doc, origin, courseID, sourceURL);
}

export const canvasModuleFields = ['moduleID', 'moduleTitle', 'modulePosition', 'moduleItemPosition', 'moduleSection'];
export const canvasLinkFields = ['linkedFromID', 'linkedFromTitle', 'linkedPosition', 'linkedOrder', 'linkedSection'];

export function inheritCanvasGrouping(target, parent, position, section) {
  if (target.moduleID != null || target.linkedFromID || target.id === parent.id) return;
  for (const field of canvasModuleFields) if (parent[field] != null) target[field] = parent[field];
  Object.assign(target, {
    linkedFromID: parent.id,
    linkedFromTitle: parent.title,
    linkedPosition: position,
    linkedOrder: [...(parent.linkedOrder || []), position],
    linkedSection: section,
  });
}

export function canvasFolderTitle(folderID, folders) {
  const names = [], seen = new Set();
  let folder = folders.get(String(folderID));
  while (folder && !seen.has(String(folder.id))) {
    seen.add(String(folder.id));
    // Canvas's default root is not a teacher-defined grouping.
    if (folder.parent_folder_id == null) break;
    if (folder.name?.trim()) names.unshift(folder.name.trim());
    folder = folders.get(String(folder.parent_folder_id));
  }
  return names.join(' / ') || undefined;
}
