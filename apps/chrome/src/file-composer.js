import { FILE_PREVIEW_CHARACTERS, MAX_FILE_ATTACHMENTS, normalizeFileAttachments } from '../../../packages/core/src/file-attachments.js';
import { readChatFile } from './file-input.js';

export const PAPERCLIP = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m21 11-8.5 8.5a6 6 0 0 1-8.5-8.5l9-9a4 4 0 0 1 5.7 5.7l-9 9a2 2 0 0 1-2.8-2.8L15 6"/></svg>';

export function appendFileChips(container, files = [], remove = null, toggle = null) {
  const doc = container.ownerDocument;
  for (const [index, file] of files.entries()) {
    const chip = doc.createElementNS('http://www.w3.org/1999/xhtml', 'span');
    chip.className = 'scholia-file-chip';
    chip.dataset.status = file.status || (file.truncated ? 'partial' : 'readable');
    chip.classList.toggle('scholia-file-excluded', file.enabled === false);
    if (toggle) {
      const enabled = doc.createElement('input');
      enabled.type = 'checkbox';
      enabled.checked = file.enabled !== false;
      enabled.title = 'Include in the next message';
      enabled.setAttribute('aria-label', `Include ${file.name} in context`);
      enabled.addEventListener('change', () => toggle(index, enabled.checked));
      chip.append(enabled);
    }
    if (file.imageDataUrl) {
      const image = doc.createElementNS('http://www.w3.org/1999/xhtml', 'img');
      image.src = file.imageDataUrl;
      image.alt = '';
      chip.append(image);
    }
    const name = doc.createElementNS('http://www.w3.org/1999/xhtml', 'span');
    name.textContent = `${file.mimeType === 'inode/directory' ? 'Folder' : 'File'} · ${file.name}`;
    name.title = `${file.name}${file.sourcePath ? ` · ${file.sourcePath}` : ''}${file.notice ? ` · ${file.notice}` : ''}`;
    chip.append(name);
    if (file.status || file.truncated) {
      const note = doc.createElementNS('http://www.w3.org/1999/xhtml', 'small');
      note.textContent = file.enabled === false ? 'Excluded' : file.status === 'unavailable' ? 'Not read' : file.truncated || file.status === 'partial' ? 'Partial' : file.imageDataUrl ? 'Image' : 'Read';
      chip.append(note);
    }
    if (remove) {
      const button = doc.createElementNS('http://www.w3.org/1999/xhtml', 'button');
      button.type = 'button';
      button.textContent = '×';
      button.setAttribute('aria-label', `Remove ${file.name}`);
      button.addEventListener('click', () => remove(index));
      chip.append(button);
    }
    container.append(chip);
    if (toggle) {
      const details = doc.createElement('details');
      details.className = 'scholia-file-preview';
      const summary = doc.createElement('summary');
      summary.textContent = `Saved file text: ${file.name}`;
      const notice = doc.createElement('p');
      const count = file.textCorpusUTF16Count || file.text?.length || 0;
      notice.textContent = `Saved extraction: ${count.toLocaleString()} characters. The answer uses excerpts selected for your question; saved text remains available for follow-ups. ${count > FILE_PREVIEW_CHARACTERS ? `Preview shows the first ${Math.min(FILE_PREVIEW_CHARACTERS, file.text?.length || 0).toLocaleString()} characters. ` : ''}${file.notice || ''}${file.truncated ? ' Extraction is incomplete.' : ''}${file.enabled === false ? ' Excluded from the next message.' : ''}`;
      details.append(summary, notice);
      const provenance = doc.createElement('p');
      provenance.textContent = `${file.mimeType === 'inode/directory' ? 'Folder' : 'File'}: ${file.name}${file.sourcePath ? ` · ${file.sourcePath}` : ' · Local path is not available from this browser.'}${file.id ? ` · Attachment ${file.id}` : ''}`;
      details.append(provenance);
      if (file.text) {
        const pre = doc.createElement('pre');
        pre.textContent = file.text.slice(0, FILE_PREVIEW_CHARACTERS);
        details.append(pre);
      }
      container.append(details);
    }
  }
}

export function mountFileComposer({ button, container, dropTarget, pasteTarget, readFile = readChatFile, normalizeFiles = normalizeFileAttachments, disabled = () => false, onChange = () => {} }) {
  const doc = container.ownerDocument;
  const input = doc.createElementNS('http://www.w3.org/1999/xhtml', 'input');
  input.type = 'file';
  input.multiple = true;
  input.hidden = true;
  button.innerHTML = PAPERCLIP;
  button.title = 'Attach files';
  button.setAttribute('aria-label', 'Attach files');
  const list = doc.createElementNS('http://www.w3.org/1999/xhtml', 'div');
  list.className = 'scholia-file-list';
  const status = doc.createElementNS('http://www.w3.org/1999/xhtml', 'div');
  status.className = 'scholia-file-status';
  status.setAttribute('role', 'status');
  container.append(list, status, input);
  let files = [];
  let busy = false;
  let version = 0;
  let controller;
  let dragDepth = 0;
  let pending = [];
  function render() {
    list.replaceChildren();
    const included = normalizeFiles(files.filter((file) => file.enabled !== false && !file.imageDataUrl));
    let includedIndex = 0;
    const display = files.map((file) => file.enabled === false || file.imageDataUrl ? file : included[includedIndex++]);
    appendFileChips(list, display, (index) => {
      if (disabled() || busy) return;
      files.splice(index, 1);
      status.textContent = '';
      render();
    }, (index, enabled) => { if (!disabled() && !busy) { files[index].enabled = enabled; render(); } });
    container.hidden = !files.length && !status.textContent;
    onChange();
  }
  async function add(candidates) {
    if (disabled()) return;
    pending.push(...Array.from(candidates));
    if (busy) return;
    const token = ++version;
    controller = new AbortController();
    busy = true;
    status.textContent = 'Reading files…';
    render();
    const errors = [];
    while (pending.length) {
      const candidate = pending.shift();
      if (token !== version) return;
      if (files.length >= MAX_FILE_ATTACHMENTS) { errors.push(`Attach up to ${MAX_FILE_ATTACHMENTS} files per message. ${pending.length + 1} additional files were not added.`); pending = []; break; }
      try {
        const file = await readFile(candidate, { signal: controller.signal });
        if (token !== version) return;
        if (file.imageDataUrl && files.some((entry) => entry.imageDataUrl)) {
          delete file.imageDataUrl;
          file.status = 'unavailable'; file.notice = 'Attached, but this message already has an image. Send this image in another message for visual inspection.';
        }
        files.push(file);
      } catch (error) {
        if (token !== version) return;
        errors.push(error.message || 'Could not read this file.');
      }
    }
    busy = false;
    status.textContent = errors.join(' ');
    render();
  }
  button.addEventListener('click', () => { if (!disabled() && !busy) input.click(); });
  input.addEventListener('change', () => { const chosen = [...input.files]; input.value = ''; void add(chosen); });
  const isFiles = (event) => Array.from(event.dataTransfer?.types || []).includes('Files');
  dropTarget.addEventListener('dragenter', (event) => {
    if (!isFiles(event)) return;
    event.preventDefault(); event.stopPropagation();
    dragDepth += 1;
    if (!disabled()) dropTarget.classList.add('scholia-file-drag');
  });
  dropTarget.addEventListener('dragover', (event) => {
    if (!isFiles(event)) return;
    event.preventDefault(); event.stopPropagation();
    event.dataTransfer.dropEffect = disabled() ? 'none' : 'copy';
  });
  dropTarget.addEventListener('dragleave', (event) => {
    if (!isFiles(event)) return;
    event.stopPropagation();
    if (--dragDepth <= 0) dropTarget.classList.remove('scholia-file-drag');
  });
  dropTarget.addEventListener('drop', (event) => {
    if (!isFiles(event)) return;
    event.preventDefault(); event.stopPropagation();
    dragDepth = 0;
    dropTarget.classList.remove('scholia-file-drag');
    const dropped = [...event.dataTransfer.files];
    if (!dropped.length) for (const item of event.dataTransfer.items || []) { const file = item.kind === 'file' ? item.getAsFile() : null; if (file) dropped.push(file); }
    if (dropped.length) void add(dropped);
    else { status.textContent = 'This application supplied a file reference without readable file contents. Use Attach files to choose the original file.'; render(); }
  });
  pasteTarget?.addEventListener('paste', (event) => {
    const pasted = [...(event.clipboardData?.files || [])];
    if (!pasted.length) return;
    event.preventDefault(); event.stopImmediatePropagation();
    void add(pasted);
  });
  render();
  return {
    get busy() { return busy; },
    get files() { return files.slice(); },
    get options() { const included = files.filter((file) => file.enabled !== false); return { files: normalizeFiles(included.filter((file) => !file.imageDataUrl)), imageDataUrl: included.find((file) => file.imageDataUrl)?.imageDataUrl || '' }; },
    set(next = []) {
      version += 1;
      controller?.abort();
      pending = []; files = next.slice(); busy = false; status.textContent = ''; render();
    },
    add
  };
}
