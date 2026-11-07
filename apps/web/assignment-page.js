import { escapeHtml as esc, renderMarkdown } from '../chrome/src/render.js';
import { selectedAssignment, assignmentDate, assignmentAvailability, submissionBadgeMarkup } from './workspace/assignments.js';

export function assignmentPageMarkup(state, { closed = new Set() } = {}) {
  const material = selectedAssignment(state);
  if (!material) return '';
  const details = material.assignment,
    due = assignmentDate(details?.dueAt);
  const course = state.library.courses.find((c) => c.id === state.library.selectedCourseID);
  const selected = course?.documents.find((d) => d.id === state.library.selectedDocumentID);
  const files = state.assignmentFiles || state.assignmentPDFs || [];
  const documentsBySource = new Map(
    course?.documents.map((document) => [document.sourceKey, document])
  );
  const filesKey = `assignment-files:${course.id}:${material.id}`;
  const dueText = due
    ? `Due ${new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(due)}`
    : details
      ? 'No due date'
      : 'Deadline not synced';
  return `<article class="assignment-page ${selected ? '' : 'assignment-only'}" aria-label="Assignment details">
    <div class="assignment-page-heading"><div><span class="eyebrow">ASSIGNMENT</span><h1>${esc(material.title)}</h1></div>${submissionBadgeMarkup(details?.status, details)}</div>
    <p class="assignment-page-due">${esc(dueText)} · ${esc(Intl.DateTimeFormat().resolvedOptions().timeZone)}${assignmentAvailability(details) ? ` · ${esc(assignmentAvailability(details))}` : ''}</p>
    ${
      files.length
        ? `<details class="assignment-files" aria-label="Included files" data-collapse-key="${esc(filesKey)}" ${closed.has(filesKey) ? '' : 'open'}><summary>Included files <span>${files.length}</span></summary><div class="assignment-file-list">${files
            .map((file) => {
              const saved = documentsBySource.get(file.id);
              const tooLarge = file.byteCount > 100_000_000;
              const readable =
                saved && saved.kind !== 'preview' && saved.pageCount > (saved.unreadablePages || 0);
              const status = tooLarge
                ? 'Larger than 100 MB'
                : state.assignmentFileNotices?.[file.id] ||
                  (readable
                    ? 'Ready for companion'
                    : saved
                      ? 'No readable text · original available'
                      : state.assignmentPreparingFileID === file.id
                        ? 'Preparing…'
                        : 'Open to add to companion');
              return `<button data-action="assignmentFile" data-id="${esc(file.id)}" data-assignment-id="${esc(material.id)}" data-course-id="${esc(course.id)}" aria-pressed="${selected?.sourceKey === file.id}" title="${esc(file.title)} · ${esc(status)}" ${tooLarge ? 'disabled' : ''}><span>${selected?.sourceKey === file.id ? '✓ ' : ''}${esc(file.title)}</span><small>${esc(status)}</small></button>`;
            })
            .join(
              ''
            )}</div><p class="assignment-file-note">Instructions and readable included files are available to the study companion.</p></details>`
        : !state.assignmentPreparing && details?.linkedFileIDs && !state.assignmentNotice
          ? '<p class="assignment-file-note">No files are linked to this assignment.</p>'
          : ''
    }
    <details class="assignment-instructions" open><summary>Instructions</summary><div class="assignment-description">${state.assignmentText ? renderMarkdown(state.assignmentText) : `<p>${details?.locked ? 'Locked in Canvas.' : state.assignmentPreparing ? 'Loading instructions…' : 'No saved instructions. Retry to load this assignment.'}</p>`}</div></details>
    ${state.assignmentNotice ? `<div class="assignment-page-notice" role="status"><span>${esc(state.assignmentNotice)}</span>${details?.locked ? '' : `<button data-action="assignment" data-id="${esc(material.id)}" data-course-id="${esc(state.library.selectedCourseID)}" ${state.assignmentPreparing ? 'disabled' : ''}>Retry</button>`}</div>` : state.assignmentPreparing ? '<p class="assignment-file-note" role="status">Opening assignment files…</p>' : ''}
  </article>`;
}

