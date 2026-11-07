import { escapeHtml as esc } from '../../chrome/src/html-escape.js';
import { submissionBadgeMarkup } from './assignments.js';

function materialRowMarkup(
  item,
  {
    compact = false,
    courseID = '',
    selectedID = '',
    selectedAssignmentID = '',
    busy = false,
    savedLabel = 'Saved offline',
    showClassification = false,
  } = {}
) {
  const isAssignment = item.materialID?.startsWith('assignments:');
  const id = isAssignment ? item.materialID : item.documentID || item.materialID;
  const selected = isAssignment
    ? item.materialID === selectedAssignmentID
    : item.documentID && item.documentID === selectedID;
  const disabled =
    !isAssignment && !item.documentID && (busy || item.detail === 'Larger than 100 MB');
  let link = '';
  try {
    const url = new URL(item.sourceURL);
    if (url.protocol === 'https:') link = url.href;
  } catch {}
  const classification = showClassification
    ? [item.categoryTitle, item.topic].filter(Boolean).join(' · ')
    : '';
  const extraction = ['ocr', 'mixed'].includes(item.extractionMethod) ? 'Includes OCR text' : '';
  return `<div class="material-row ${selected ? 'active' : ''}"><button class="${compact ? 'material-nav-item' : ''}" data-action="${isAssignment ? 'assignment' : item.documentID ? 'document' : 'material'}" data-id="${esc(id)}" data-course-id="${esc(courseID)}" title="${esc(item.title)}" ${selected ? 'aria-current="true"' : ''} ${disabled ? 'disabled' : ''}><span class="material-title"><strong>${esc(item.title)}</strong>${compact ? '' : `<small>${esc(item.detail)}</small>`}${!compact && (classification || extraction) ? `<small class="material-classification" title="${esc(item.classificationBasis || '')}">${esc([classification, extraction].filter(Boolean).join(' · '))}</small>` : ''}${isAssignment && item.requiresSubmission !== false ? submissionBadgeMarkup(item.submissionStatus, item.assignment) : ''}${item.badge ? `<small class="material-badge">${esc(item.badge)}</small>` : ''}</span><span class="cloud" title="${item.documentID ? esc(savedLabel) : 'Download on demand'}" aria-label="${item.documentID ? esc(savedLabel) : 'Download on demand'}">${item.documentID ? '▣' : '↓'}</span></button>${!compact && item.updateAvailable ? `<button class="material-update" data-action="material" data-id="${esc(item.materialID)}" ${busy ? 'disabled' : ''}>Update</button>` : ''}${link ? `<a href="${esc(link)}" target="_blank" rel="noreferrer" aria-label="Open ${esc(item.title)} in Canvas">↗</a>` : ''}</div>`;
}

const materialSearchText = (item) =>
  [item.title, item.fileName, item.categoryTitle, item.topic, item.canvasHeading, item.canvasSubheading, item.canvasGroupTitle]
    .filter(Boolean)
    .join(' ')
    .toLocaleLowerCase();

// Canvas headings take precedence over inferred categories/topics. For courses
// without Canvas structure, retain the existing content-based organization.
function groupedRowsMarkup(group, options) {
  const canvas = /^(module:|canvas-page:|folder:)/.test(group.id);
  if (canvas) {
    let previous, previousSection;
    return group.items.map((item) => {
      const heading = item.canvasHeading;
      const section = item.canvasSubheading;
      const changed = heading !== previous;
      const title = heading && changed && heading !== group.title
        ? `<h3 class="material-subheader">${esc(heading)}</h3>` : '';
      const subtitle = section && (changed || section !== previousSection)
        ? `<h4 class="material-subheader">${esc(section)}</h4>` : '';
      previous = heading;
      previousSection = section;
      return title + subtitle + materialRowMarkup(item, options);
    }).join('');
  }
  const heading = (item) => item.topic;
  if (!group.items.some(heading))
    return group.items.map((item) => materialRowMarkup(item, options)).join('');
  let previous;
  return group.items
    .map((item, index) => {
      const title = heading(item) || group.title;
      const repeatsRow = title.toLocaleLowerCase() === item.title.toLocaleLowerCase();
      const nextTitle = group.items[index + 1] && heading(group.items[index + 1]);
      const subheader =
        title !== previous && (!repeatsRow || nextTitle === title)
          ? `<h3 class="material-subheader">${esc(title)}</h3>`
          : '';
      previous = title;
      return subheader + materialRowMarkup(item, options);
    })
    .join('');
}

export function materialGroupsMarkup(groups, options = {}) {
  const { compact = false, courseID = '', query = '', closed = new Set() } = options;
  const needle = query.trim().toLocaleLowerCase();
  const visible = groups
    .map((group) => ({
      ...group,
      items: group.items.filter((item) =>
        `${group.title.toLocaleLowerCase()} ${materialSearchText(item)}`.includes(needle)
      ),
    }))
    .filter((group) => group.items.length);
  if (!visible.length)
    return `<p class="material-empty">${needle ? 'No matching materials.' : 'Your course materials will appear here.'}</p>`;
  return visible
    .map((group) => {
      const key = `${courseID}:${group.id}`;
      return `<details class="material-group ${compact ? 'compact' : ''}" data-collapse-key="${esc(key)}" ${needle || (!closed.has(key) && (group.id !== 'assets' || closed.has(`open:${key}`))) ? 'open' : ''}><summary><span>${esc(group.title)}</span><small>${group.items.length}</small></summary>${compact ? '' : `<p class="group-basis">${esc(group.basis)}</p>`}${groupedRowsMarkup(group, options)}</details>`;
    })
    .join('');
}

export function materialFilesMarkup(files, options = {}) {
  const needle = (options.query || '').trim().toLocaleLowerCase();
  const visible = files.filter((item) => materialSearchText(item).includes(needle));
  return `<div class="material-files" aria-label="All files"><p class="file-count">${visible.length} files</p>${visible.length ? visible.map((item) => materialRowMarkup(item, { ...options, compact: false, showClassification: true })).join('') : `<p class="material-empty">${needle ? 'No matching files.' : 'No files in this workspace yet.'}</p>`}</div>`;
}

export function materialViewPicker(view) {
  const flat = view === 'files';
  return `<div class="tabs material-views" role="group" aria-label="Materials view"><button data-action="materialView" data-id="organized" class="${flat ? '' : 'active'}" aria-pressed="${!flat}">Organized</button><button data-action="materialView" data-id="files" class="${flat ? 'active' : ''}" aria-pressed="${flat}">All files</button></div>`;
}

export function materialsViewMarkup(groups, files, options = {}) {
  return `${options.picker === false ? '' : materialViewPicker(options.view)}${options.view === 'files' ? materialFilesMarkup(files, options) : materialGroupsMarkup(groups, options)}`;
}
