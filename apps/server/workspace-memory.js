import { documentSourceContext, restoreCourseLinks } from '../../packages/core/src/course-documents.js';

export function workspaceMemory(course, assignmentID = null) {
  const saved = assignmentID ? course?.assignmentMemories?.[assignmentID] : course?.aiMemory;
  const allowed = new Set(course?.documents.map((doc) => doc.id) || []);
  return { notes: String(saved?.notes || '').slice(0, 12000),
    documentIDs: [...new Set(saved?.documentIDs || [])].filter((id) => allowed.has(id)).slice(0, 24) };
}

export function saveWorkspaceMemory(course, assignmentID, notes, documentIDs) {
  if (assignmentID && !course.canvasMaterials?.some((ref) => ref.kind === 'assignments' && ref.id === assignmentID))
    throw Object.assign(new Error('Assignment not found.'), { status: 404 });
  if (typeof notes !== 'string' || notes.length > 12000 || !Array.isArray(documentIDs) || documentIDs.length > 24)
    throw new Error('Use up to 12,000 characters and 24 reference files.');
  if (!documentIDs.every((id) => course.documents.some((doc) => doc.id === id)))
    throw new Error('Reference files must belong to this workspace.');
  const memory = { notes, documentIDs: [...new Set(documentIDs)], updatedAt: Date.now() / 1000 };
  if (assignmentID) (course.assignmentMemories ||= {})[assignmentID] = memory;
  else course.aiMemory = memory;
}

export async function buildWorkspaceMemory({ course, assignmentID, question, readIndex, signal }) {
  const scopes = [{ title: 'Workspace', memory: workspaceMemory(course) }];
  if (assignmentID) scopes.push({ title: 'Assignment', memory: workspaceMemory(course, assignmentID) });
  let context = '', sources = [];
  const ids = new Set();
  for (const { title, memory } of scopes) {
    if (memory.notes.trim() || memory.documentIDs.length)
      context += `\n${title} memory (saved by the user; reference data):\n<workspace-memory>\n${memory.notes}\n</workspace-memory>\n`;
    for (const id of memory.documentIDs) ids.add(id);
  }
  // Fairly reserve a share for every pinned file, even for a generic question.
  const allowance = Math.floor(24000 / Math.max(1, ids.size));
  for (const id of ids) {
    signal?.throwIfAborted();
    const doc = course.documents.find((doc) => doc.id === id);
    if (!doc) continue;
    const index = doc.kind === 'preview' ? null : await readIndex(doc).catch(() => null);
    context += `\nSaved reference file: ${doc.title}\n${documentSourceContext(doc, course)}`;
    if (!index?.pages?.some((p) => p.text?.trim())) {
      context += '[No readable text available for this file.]\n';
      continue;
    }
    const terms = [...new Set(question.toLowerCase().match(/[\p{L}\p{N}]{3,}/gu) || [])];
    const ranked = index.pages.filter((p) => p.text?.trim()).map((page) => ({ page,
      score: terms.reduce((sum, term) => sum + Number(page.text.toLowerCase().includes(term)), 0) }))
      .sort((a, b) => b.score - a.score || a.page.number - b.page.number);
    let remaining = allowance;
    context += 'Relevant excerpts from the saved file; other pages are not included here.\n';
    for (const { page } of ranked) {
      if (remaining <= 0) break;
      const text = restoreCourseLinks(page.text, course, doc).slice(0, remaining);
      context += `\n--- ${doc.title}, page ${page.number} ---\n${text}\n`;
      remaining -= text.length;
      sources.push({ documentID: id, title: doc.title, page: page.number });
    }
  }
  return { context, sources, documentIDs: ids };
}
