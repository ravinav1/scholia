import { escapeHtml as esc } from '../chrome/src/html-escape.js';
import './workspace-shortcuts.css';

const normalize = (value) =>
  String(value || '')
    .normalize('NFKD')
    .replace(/\p{M}/gu, '')
    .toLocaleLowerCase();

let quickCatalog;
export function workspaceQuickCatalog(state) {
  const key = JSON.stringify([Intl.DateTimeFormat().resolvedOptions().locale,
    state.library.courses.map((c) => [c.id, c.name, c.code, c.term, c.favorite, c.canvasFavorite]),
    state.library.selectedCourseID, state.showingLibrary, state.streaming, state.busy]);
  if (quickCatalog?.key === key) return quickCatalog.items;
  const items = buildWorkspaceQuickCatalog(state).map((item) => ({ ...item,
    search: normalize(`${item.title} ${item.detail} ${item.keywords || ''}`), titleSearch: normalize(item.title) }));
  quickCatalog = { key, items };
  return items;
}
export function workspaceQuickItems(state, query = '', catalog = workspaceQuickCatalog(state)) {
  const commandsOnly = query.trimStart().startsWith('>');
  const terms = normalize(commandsOnly ? query.trimStart().slice(1) : query).trim().split(/\s+/).filter(Boolean);
  const matches = (item) => terms.every((term) => item.search.includes(term));
  const rank = (item) => Number(!terms.every((term) => item.titleSearch.includes(term)));
  const courses = commandsOnly ? [] : catalog.filter((item) => item.action === 'course' && matches(item));
  const actions = catalog.filter((item) => item.action !== 'course' && matches(item)).sort((a,b) => rank(a)-rank(b));
  return [...(terms.length ? courses : courses.slice(0,6)), ...actions];
}
function buildWorkspaceQuickCatalog(state) {
  const current = state.library.courses.find(
    (course) => course.id === state.library.selectedCourseID
  );
  const inCourse = !!current && !state.showingLibrary;
  const courses = [...state.library.courses]
        .sort(
          (a, b) =>
            Number(inCourse && a.id === current.id) - Number(inCourse && b.id === current.id) ||
            Number(!!(b.favorite ?? b.canvasFavorite)) -
              Number(!!(a.favorite ?? a.canvasFavorite)) ||
            a.name.localeCompare(b.name)
        )
        .map((course) => ({
          id: `course:${course.id}`,
          action: 'course',
          courseID: course.id,
          group: 'Workspaces',
          title: course.name,
          detail: [
            course.code,
            course.term,
            inCourse && course.id === current.id ? 'Current workspace' : 'Open workspace',
          ]
            .filter(Boolean)
            .join(' · '),
          icon: (course.favorite ?? course.canvasFavorite) ? '★' : '▦',
        }));
  const actions = [
    {
      id: 'search',
      title: 'Search coursework',
      detail: inCourse
        ? `Files and contents in ${current.code || current.name}`
        : 'Files and contents in all workspaces',
      keywords: 'find readings materials notes assignments',
      icon: '⌕',
      shortcut: 'K',
    },
    {
      id: 'searchAll',
      title: 'Search all coursework',
      detail: 'Files and contents across your library',
      keywords: 'find readings materials notes assignments',
      icon: '⌕',
    },
    {
      id: 'library',
      title: 'Go to dashboard',
      detail: 'Your workspaces and upcoming work',
      keywords: 'home courses library',
      icon: '▦',
    },
    {
      id: 'assignments',
      title: 'Go to assignments',
      detail: 'Upcoming and completed coursework',
      keywords: 'homework deadlines tasks',
      icon: '☑',
    },
    {
      id: 'exams',
      title: 'Go to exam dates',
      detail: 'Exam schedule and study planning',
      keywords: 'calendar planner',
      icon: '▦',
    },
    {
      id: 'reviewDue',
      title: 'Review due',
      detail: 'Practice questions ready to revisit',
      keywords: 'flashcards revision study',
      icon: '↻',
    },
    ...(inCourse
      ? [
          {
            id: 'materials',
            title: 'Browse course materials',
            detail: current.code || current.name,
            keywords: 'readings files coursework',
            icon: '▤',
          },
          ...(!state.streaming
            ? [
                {
                  id: 'newThread',
                  title: 'New chat',
                  detail: 'Start a conversation in this workspace',
                  keywords: 'tutor ask question conversation',
                  icon: '+',
                },
              ]
            : []),
          ...(!state.busy
            ? [
                {
                  id: 'upload',
                  title: 'Add documents',
                  detail: 'Import readings into this workspace',
                  keywords: 'upload files pdf',
                  icon: '+',
                },
              ]
            : []),
        ]
      : []),
    {
      id: 'keyboardShortcuts',
      title: 'Keyboard shortcuts',
      detail: 'Keys for navigation, chat, and reading',
      keywords: 'help settings keyboard hotkeys',
      icon: '⌨',
    },
    {
      id: 'create',
      title: 'New workspace',
      detail: 'Create a space for a course',
      keywords: 'add course',
      icon: '+',
    },
  ]
    .map((item) => ({ ...item, action: item.id, group: 'Quick actions' }));
  return [...courses, ...actions];
}

export function installWorkspaceShortcuts({ getState, onRun, notify, beforeOpen = () => {} }) {
  const primary = /Mac|iPhone|iPad/.test(navigator.platform) ? '⌘' : 'Ctrl';
  const help = document.createElement('dialog');
  help.id = 'keyboard-shortcuts-dialog';
  help.className = 'workspace-shortcuts-dialog keyboard-shortcuts-dialog';
  help.setAttribute('aria-labelledby', 'keyboard-shortcuts-title');
  const groups = [
    ['Workspace', [['Search files and contents', `${primary} K`], ['Switch workspace or take an action', `${primary} Shift K`]]],
    ['Chat', [['Send message', 'Enter'], ['New line', 'Shift Enter']]],
    ['PDF reader', [['Find in document', `${primary} F`], ['Print document', `${primary} P`], ['Previous / next page', '← / →'], ['Zoom in / out', `${primary} = / −`], ['Reset zoom', `${primary} 0`]]],
    ['Document editor', [['Save changes', `${primary} S`]]],
    ['Dialogs', [['Move through search results', '↑ / ↓'], ['Open selected result', 'Enter'], ['Close dialog', 'Esc']]],
  ];
  help.innerHTML = `<div class="quick-heading"><h2 id="keyboard-shortcuts-title">Keyboard shortcuts</h2><button type="button" class="quick-close" aria-label="Close keyboard shortcuts">×</button></div>
    <p class="shortcut-help-note">Reader and editor shortcuts work while that view is active.</p>
    ${groups.map(([title, rows]) => `<section class="shortcut-help-group"><h3>${title}</h3><dl>${rows.map(([label, keys]) => `<div><dt>${label}</dt><dd><kbd>${keys}</kbd></dd></div>`).join('')}</dl></section>`).join('')}`;
  document.body.append(help);
  let helpOpener;
  function openHelp() {
    if (!getState() || document.querySelector('dialog[open]')) return;
    beforeOpen();
    helpOpener = document.activeElement;
    help.showModal();
  }
  help.querySelector('.quick-close').addEventListener('click', () => help.close());
  help.addEventListener('close', () => {
    if (!document.querySelector('dialog[open]') && helpOpener?.isConnected)
      helpOpener.focus({ preventScroll: true });
  });
  const dialog = document.createElement('dialog');
  dialog.id = 'workspace-shortcuts-dialog';
  dialog.className = 'workspace-shortcuts-dialog';
  dialog.setAttribute('aria-labelledby', 'workspace-shortcuts-title');
  dialog.innerHTML = `<div class="quick-heading"><div><small>QUICK JUMP</small><h2 id="workspace-shortcuts-title">Switch workspace or take an action</h2></div><button type="button" class="quick-close" aria-label="Close quick jump">×</button></div>
    <label class="sr-only" for="workspace-shortcuts-query">Find a workspace or action</label>
    <input id="workspace-shortcuts-query" role="combobox" aria-autocomplete="list" aria-expanded="true" aria-controls="workspace-shortcuts-results" autocomplete="off" spellcheck="false" placeholder="Type a workspace, course code, or action…">
    <div id="workspace-shortcuts-results" role="listbox" aria-label="Workspaces and quick actions"></div>
    <p class="quick-empty" role="status" hidden>No matches. Try a course code or an action like “assignments”.</p>
    <footer class="quick-help"><span><kbd>↑</kbd><kbd>↓</kbd> move <kbd>↵</kbd> open <kbd>Esc</kbd> close</span><span>Type <kbd>&gt;</kbd> for actions</span></footer>`;
  document.body.append(dialog);
  const input = dialog.querySelector('input');
  const list = dialog.querySelector('[role=listbox]');
  let items = [],
    selected = 0,
    opener,
    running = false,
    catalog;
  function select(index) {
    const previous = list.querySelector(`[data-index="${selected}"]`);
    previous?.setAttribute('aria-selected', 'false');
    selected = Math.max(0, Math.min(index, items.length - 1));
    const row = list.querySelector(`[data-index="${selected}"]`);
    if (row) {
      row.setAttribute('aria-selected', 'true');
      input.setAttribute('aria-activedescendant', row.id);
      row.scrollIntoView({ block: 'nearest' });
    } else input.removeAttribute('aria-activedescendant');
  }
  function render() {
    const state = getState();
    items = state ? workspaceQuickItems(state, input.value, catalog) : [];
    let group = '';
    list.innerHTML = items
      .map((item, index) => {
        const heading =
          group !== item.group
            ? `<div class="quick-group" role="presentation">${item.group}${item.group === 'Workspaces' && !input.value.trim() && state.library.courses.length > 6 ? ' · type to find any workspace' : ''}</div>`
            : '';
        group = item.group;
        return `${heading}<div id="workspace-quick-${index}" class="quick-result" role="option" aria-selected="false" data-index="${index}"><span class="quick-icon" aria-hidden="true">${item.icon}</span><span class="quick-copy"><strong>${esc(item.title)}</strong><small>${esc(item.detail)}</small></span>${item.shortcut ? `<kbd>${primary} ${item.shortcut}</kbd>` : '<span class="quick-enter" aria-hidden="true">↵</span>'}</div>`;
      })
      .join('');
    dialog.querySelector('.quick-empty').hidden = items.length > 0;
    select(0);
  }
  function open() {
    if (!getState() || running || (document.querySelector('dialog[open]') && !dialog.open)) return;
    if (dialog.open) {
      input.focus();
      input.select();
      return;
    }
    beforeOpen();
    opener = document.activeElement;
    input.value = '';
    catalog = workspaceQuickCatalog(getState());
    dialog.showModal();
    render();
    input.focus();
  }
  async function activate(index) {
    const item = items[index];
    if (!item || running) return;
    running = true;
    dialog.close();
    try {
      await onRun(item);
    } catch (error) {
      notify(error.message);
    } finally {
      running = false;
    }
  }
  input.addEventListener('input', render);
  input.addEventListener('keydown', (event) => {
    if (event.isComposing || event.altKey || event.ctrlKey || event.metaKey) return;
    if (['ArrowDown', 'ArrowUp', 'Enter'].includes(event.key)) {
      event.preventDefault();
      if (event.key === 'Enter') void activate(selected);
      else select(selected + (event.key === 'ArrowDown' ? 1 : -1));
    }
  });
  list.addEventListener('mousedown', (event) => event.preventDefault());
  list.addEventListener('click', (event) => {
    const row = event.target.closest('[data-index]');
    if (row) void activate(Number(row.dataset.index));
  });
  dialog.querySelector('.quick-close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => {
    // A command may have opened another dialog or moved focus to the tutor.
    if (
      !document.querySelector('dialog[open]') &&
      document.activeElement === document.body &&
      opener?.isConnected
    )
      opener.focus({ preventScroll: true });
  });
  document.addEventListener('keydown', (event) => {
    if (
      event.defaultPrevented ||
      event.isComposing ||
      event.repeat ||
      event.altKey ||
      !(event.metaKey || event.ctrlKey) ||
      !event.shiftKey ||
      event.key.toLowerCase() !== 'k'
    )
      return;
    if (!getState() || (document.querySelector('dialog[open]') && !dialog.open)) return;
    event.preventDefault();
    open();
  });
  return { open, openHelp };
}
