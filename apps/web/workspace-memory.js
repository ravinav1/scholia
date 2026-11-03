import { escapeHtml as esc } from '../chrome/src/html-escape.js';

export function installWorkspaceMemory({ getState, action }) {
  const dialog = document.createElement('dialog');
  dialog.className = 'workspace-memory-dialog';
  dialog.id = 'workspace-memory-dialog';
  dialog.setAttribute('aria-labelledby', 'memory-title');
  dialog.innerHTML = `<form><h2 id="memory-title">Workspace memory</h2>
    <p>Notes and reference files carry into every new chat here. Assignment chats also use the parent workspace’s memory. Other assignments keep their own memory.</p>
    <label for="memory-notes">Remember about this work</label>
    <textarea id="memory-notes" maxlength="12000" rows="5" placeholder="Goals, notation, decisions, or anything useful to remember…"></textarea>
    <label for="memory-search">Reference files <span id="memory-count"></span></label>
    <input type="search" id="memory-search" placeholder="Find a saved file">
    <div id="memory-files"></div>
    <p>Import a file into this workspace to add it here. Saved files remain available after reopening; readable excerpts are sent with your questions.</p>
    <p id="memory-status" role="status"></p>
    <footer><button type="button" id="memory-cancel">Cancel</button><button type="submit" id="memory-save">Save memory</button></footer></form>`;
  document.body.append(dialog);
  const $ = (selector) => dialog.querySelector(selector);
  let target, documents = [], selected = new Set(), opener;
  function renderFiles() {
    const query = $('#memory-search').value.toLocaleLowerCase();
    const matches = documents.filter((doc) => doc.title.toLocaleLowerCase().includes(query));
    matches.sort((a, b) => Number(selected.has(b.id)) - Number(selected.has(a.id)) || a.title.localeCompare(b.title));
    $('#memory-count').textContent = `${selected.size}/24`;
    $('#memory-files').innerHTML = matches.length ? matches.slice(0, 100).map((doc) =>
      `<label><input type="checkbox" value="${esc(doc.id)}" ${selected.has(doc.id) ? 'checked' : selected.size >= 24 ? 'disabled' : ''}> <span>${esc(doc.title)}</span></label>`).join('')
      + (matches.length > 100 ? '<p>Type to narrow the file list.</p>' : '') : '<p>No saved files match.</p>';
  }
  $('#memory-search').addEventListener('input', renderFiles);
  $('#memory-files').addEventListener('change', (event) => {
    const input = event.target;
    if (input.type !== 'checkbox') return;
    input.checked ? selected.add(input.value) : selected.delete(input.value);
    renderFiles();
  });
  $('#memory-cancel').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => opener?.focus());
  $('form').addEventListener('submit', async (event) => {
    event.preventDefault();
    $('#memory-save').disabled = true;
    try {
      await action('workspaceMemory', { courseID: target.courseID, assignmentID: target.assignmentID || null,
        text: $('#memory-notes').value, documentIDs: [...selected] });
      dialog.close();
    } catch (error) { $('#memory-status').textContent = error.message; }
    finally { $('#memory-save').disabled = false; }
  });
  document.querySelector('#workspace-memory').addEventListener('click', () => {
    const state = getState();
    target = state?.workspaceMemory;
    if (!target?.courseID) return;
    opener = document.activeElement;
    documents = state.library.courses.find((course) => course.id === target.courseID)?.documents || [];
    selected = new Set(target.documentIDs);
    $('#memory-title').textContent = target.assignmentID ? 'Assignment memory' : 'Workspace memory';
    $('#memory-notes').value = target.notes;
    $('#memory-search').value = '';
    $('#memory-status').textContent = '';
    renderFiles();
    dialog.showModal();
    $('#memory-notes').focus();
  });
}
