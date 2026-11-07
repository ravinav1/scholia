import { escapeHtml as esc } from '../../chrome/src/html-escape.js';

export const canEditDocument = (item) => ['notebook', 'text', 'code'].includes(item?.kind);

export function editorMarkup(draft) {
  const field = (source, label, cell = '') =>
    `<textarea data-edit-cell="${cell}" aria-label="${esc(label)}" spellcheck="false" autocapitalize="off" autocomplete="off" autocorrect="off" wrap="off">${esc(source)}</textarea>`;
  if (draft.source != null)
    return `<div class="document-editor text-editor">${field(draft.source, 'Edit document')}</div>`;
  return `<article class="document-editor notebook-editor">${draft.cells.map((cell) => `<section class="editable-cell"><label>Cell ${cell.id + 1} · ${esc(cell.kind)}</label>${field(cell.source, `Edit cell ${cell.id + 1}`, cell.id)}</section>`).join('')}</article>`;
}

export class StudyDocumentEditor {
  constructor({ host, record, onSave, onChange }) {
    this.id = record.draft.documentID;
    this.record = record;
    this.abort = new AbortController();
    host.innerHTML = editorMarkup(record.draft);
    this.fields = [...host.querySelectorAll('textarea')];
    const grow = (field) => {
      if (record.draft.source == null) {
        field.style.height = 'auto';
        field.style.height = `${Math.max(110, field.scrollHeight + 2)}px`;
      }
    };
    const change = (field) => {
      if (field.dataset.editCell === '') record.draft.source = field.value;
      else record.draft.cells[Number(field.dataset.editCell)].source = field.value;
      record.dirty = true;
      grow(field);
      onChange();
    };
    for (const field of this.fields) {
      grow(field);
      field.addEventListener('input', () => change(field), { signal: this.abort.signal });
      field.addEventListener(
        'keydown',
        (event) => {
          if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') {
            event.preventDefault();
            onSave();
          }
          if (event.key === 'Tab' && !event.shiftKey && !event.metaKey && !event.ctrlKey) {
            event.preventDefault();
            field.setRangeText('    ', field.selectionStart, field.selectionEnd, 'end');
            change(field);
          }
        },
        { signal: this.abort.signal }
      );
    }
  }
  setBusy(busy) {
    for (const field of this.fields) field.readOnly = busy;
  }
  destroy() {
    this.abort.abort();
  }
}
