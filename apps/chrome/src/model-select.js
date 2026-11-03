import { PROVIDERS, modelId, modelLabel, providerById, providerModelChoices } from '../../../packages/core/src/providers.js';
import { MAX_VISIBLE_RECENT_MODELS, normalizeRecentModels } from '../../../packages/core/src/recent-models.js';

const pickerStates = new WeakMap();
export const MAX_RENDERED_MODEL_OPTIONS = 80;
let pickerSequence = 0;
let openPicker = null;

export function modelChoice(provider, model) {
  return `${provider}::${model}`;
}

export function parseModelChoice(value) {
  const [provider, ...modelParts] = String(value || '').split('::');
  return { provider, model: modelParts.join('::') };
}

export function selectedModel(settings) {
  const provider = settings?.provider || 'openai';
  return {
    provider,
    model: settings?.models?.[provider] || providerById(provider).defaultModel
  };
}

function normalizedSearch(value) {
  return String(value || '')
    .normalize('NFKD')
    .replace(/\p{Diacritic}/gu, '')
    .toLocaleLowerCase();
}

export function modelMatchesSearch({ label, id, provider } = {}, query = '') {
  const terms = normalizedSearch(query).split(/\s+/).filter(Boolean);
  if (!terms.length) return true;
  const searchable = normalizedSearch(`${label || ''} ${id || ''} ${provider || ''}`);
  return terms.every((term) => searchable.includes(term));
}

export function limitedModelPickerResults(results, limit = MAX_RENDERED_MODEL_OPTIONS) {
  const all = Array.isArray(results) ? results : [];
  const count = Math.max(0, Math.floor(Number(limit) || 0));
  const visible = all.slice(0, count);
  const selected = all.find((result) => result?.selected);
  if (selected && count > 0 && !visible.includes(selected)) {
    visible[visible.length - 1] = selected;
  }
  return { results: visible, total: all.length };
}

function providerLabel(group) {
  return String(group?.label || '').replace(/^[●○]\s*/, '');
}

function selectedOption(select) {
  return [...select.querySelectorAll('option')].find((option) => option.selected)
    || select.querySelector('option');
}

function syncPicker(state) {
  const option = selectedOption(state.select);
  const provider = providerLabel(option?.parentElement);
  state.value.textContent = option?.textContent || 'Choose a model';
  state.provider.textContent = provider;
  state.button.disabled = state.select.disabled;
  state.search.disabled = state.select.disabled;
  state.button.title = option
    ? `${provider} · ${option.textContent}`
    : state.select.getAttribute('aria-label') || 'Choose a model';
}

function closePicker(state, { restoreFocus = false } = {}) {
  if (!state || state.popover.hidden) return;
  state.popover.hidden = true;
  state.button.setAttribute('aria-expanded', 'false');
  if (openPicker === state) openPicker = null;
  if (restoreFocus) state.button.focus();
}

function chooseOption(state, option) {
  state.select.value = option.value;
  syncPicker(state);
  closePicker(state);
  state.select.dispatchEvent(new Event('change', { bubbles: true }));
}

function focusPickerOption(state, current, movement) {
  const options = [...state.list.querySelectorAll('.model-picker-option')];
  if (!options.length) return;
  const currentIndex = options.indexOf(current);
  const nextIndex = movement === 'first'
    ? 0
    : movement === 'last'
      ? options.length - 1
      : Math.max(0, Math.min(options.length - 1, currentIndex + movement));
  options[nextIndex]?.focus();
}

function renderPickerOptions(state) {
  state.list.textContent = '';
  const query = state.search.value;
  const groups = [];
  const allMatches = [];

  for (const group of state.select.querySelectorAll('optgroup')) {
    const provider = providerLabel(group);
    const matches = [...group.querySelectorAll('option')].filter((option) => {
      const parsed = parseModelChoice(option.value);
      return modelMatchesSearch({
        label: option.textContent,
        id: parsed.model,
        provider
      }, query);
    }).map((option) => ({ group, provider, option, selected: option.selected }));
    if (!matches.length) continue;
    groups.push({ group, provider, matches });
    allMatches.push(...matches);
  }

  const recent = (state.recentChoices || []).map((value) => allMatches.find((match) => match.option.value === value)).filter(Boolean);
  if (recent.length) {
    const recentValues = new Set(recent.map((match) => match.option.value));
    for (const group of groups) group.matches = group.matches.filter((match) => !recentValues.has(match.option.value));
    groups.unshift({ group: { label: 'Recently used' }, matches: recent });
  }
  const windowed = limitedModelPickerResults(groups.flatMap((group) => group.matches));
  const visible = new Set(windowed.results);

  for (const { group, provider, matches } of groups) {
    const shown = matches.filter((match) => visible.has(match));
    if (!shown.length) continue;

    const section = state.select.ownerDocument.createElement('section');
    section.className = 'model-picker-group';
    const heading = state.select.ownerDocument.createElement('div');
    heading.className = 'model-picker-group-label';
    const headingName = state.select.ownerDocument.createElement('span');
    headingName.textContent = group.label;
    const headingCount = state.select.ownerDocument.createElement('span');
    headingCount.className = 'model-picker-group-count';
    headingCount.textContent = shown.length === matches.length
      ? `${matches.length} model${matches.length === 1 ? '' : 's'}`
      : `${shown.length} of ${matches.length} models`;
    heading.append(headingName, headingCount);
    section.append(heading);

    for (const { option, provider } of shown) {
      const parsed = parseModelChoice(option.value);
      const row = state.select.ownerDocument.createElement('button');
      row.type = 'button';
      row.className = 'model-picker-option';
      row.setAttribute('role', 'option');
      row.setAttribute('aria-selected', String(option.selected));
      const label = state.select.ownerDocument.createElement('span');
      label.className = 'model-picker-option-label';
      label.textContent = option.textContent;
      const detail = state.select.ownerDocument.createElement('span');
      detail.className = 'model-picker-option-detail';
      detail.textContent = `${provider} · ${parsed.model}`;
      const check = state.select.ownerDocument.createElement('span');
      check.className = 'model-picker-option-check';
      check.setAttribute('aria-hidden', 'true');
      check.textContent = option.selected ? '✓' : '';
      row.append(label, detail, check);
      row.addEventListener('click', () => chooseOption(state, option));
      section.append(row);
    }
    state.list.append(section);
  }

  if (!windowed.total) {
    const empty = state.select.ownerDocument.createElement('div');
    empty.className = 'model-picker-empty';
    empty.textContent = 'No matching models';
    state.list.append(empty);
  } else if (windowed.results.length < windowed.total) {
    const limit = state.select.ownerDocument.createElement('div');
    limit.className = 'model-picker-limit';
    limit.setAttribute('role', 'status');
    limit.textContent = `Showing ${windowed.results.length} of ${windowed.total} models. Search to narrow.`;
    state.list.append(limit);
  }
  if (!state.popover.hidden) positionModelPicker(state);
}

function positionModelPicker(state) {
  const { wrapper, popover, list } = state;
  const view = wrapper.ownerDocument.defaultView;
  const bounds = { left: 8, right: view.innerWidth - 8, top: 8, bottom: view.innerHeight - 8 };
  for (let parent = wrapper.parentElement; parent; parent = parent.parentElement) {
    const style = view.getComputedStyle(parent);
    const rect = parent.getBoundingClientRect();
    if (/(hidden|clip|auto|scroll)/.test(style.overflowX)) {
      bounds.left = Math.max(bounds.left, rect.left + 8);
      bounds.right = Math.min(bounds.right, rect.right - 8);
    }
    if (/(hidden|clip|auto|scroll)/.test(style.overflowY)) {
      bounds.top = Math.max(bounds.top, rect.top + 8);
      bounds.bottom = Math.min(bounds.bottom, rect.bottom - 8);
    }
  }
  // Rectangles include the popup's layer transform; CSS offsets do not.
  const anchor = wrapper.getBoundingClientRect();
  const scaleX = anchor.width / wrapper.offsetWidth || 1;
  const scaleY = anchor.height / wrapper.offsetHeight || 1;
  for (const name of ['left', 'right', 'top', 'width']) popover.style.removeProperty(name);
  list.style.removeProperty('max-height');
  let rect = popover.getBoundingClientRect();
  const width = Math.max(0, Math.min(rect.width, bounds.right - bounds.left));
  const left = Math.max(bounds.left, Math.min(rect.left, bounds.right - width));
  popover.style.width = `${width / scaleX}px`;
  popover.style.left = `${(left - anchor.left) / scaleX}px`;
  popover.style.right = 'auto';
  rect = popover.getBoundingClientRect();
  const below = Math.max(0, bounds.bottom - anchor.bottom - 7);
  const above = Math.max(0, anchor.top - bounds.top - 7);
  const openAbove = rect.height > below && above > below;
  const available = openAbove ? above : below;
  const chromeHeight = rect.height - list.getBoundingClientRect().height;
  list.style.maxHeight = `${Math.max(0, Math.min(list.getBoundingClientRect().height, available - chromeHeight)) / scaleY}px`;
  rect = popover.getBoundingClientRect();
  const top = openAbove ? anchor.top - rect.height - 7 : anchor.bottom + 7;
  popover.style.top = `${(top - anchor.top) / scaleY}px`;
}

function openModelPicker(state) {
  if (state.select.disabled) return;
  if (openPicker && openPicker !== state) closePicker(openPicker);
  openPicker = state;
  state.search.value = '';
  renderPickerOptions(state);
  state.popover.hidden = false;
  positionModelPicker(state);
  state.button.setAttribute('aria-expanded', 'true');
  state.select.dispatchEvent(new Event('scholia-model-picker-open'));
  requestAnimationFrame(() => {
    if (state.popover.hidden) return;
    positionModelPicker(state);
    state.search.focus({ preventScroll: true });
  });
}

function ensureModelPicker(select) {
  if (pickerStates.has(select)) return pickerStates.get(select);

  const doc = select.ownerDocument;
  const id = `model-picker-${++pickerSequence}`;
  const wrapper = doc.createElement('div');
  wrapper.className = `model-picker${select.classList.contains('scholia-model') ? ' scholia-model-picker' : ''}`;
  select.before(wrapper);
  wrapper.append(select);
  select.hidden = true;

  const button = doc.createElement('button');
  button.type = 'button';
  button.className = 'model-picker-button';
  button.setAttribute('aria-haspopup', 'listbox');
  button.setAttribute('aria-expanded', 'false');
  button.setAttribute('aria-controls', `${id}-list`);
  button.setAttribute('aria-label', select.getAttribute('aria-label') || 'Choose a model');
  const buttonCopy = doc.createElement('span');
  buttonCopy.className = 'model-picker-button-copy';
  const value = doc.createElement('span');
  value.className = 'model-picker-button-value';
  const provider = doc.createElement('span');
  provider.className = 'model-picker-button-provider';
  buttonCopy.append(value, provider);
  const chevron = doc.createElement('span');
  chevron.className = 'model-picker-chevron';
  chevron.setAttribute('aria-hidden', 'true');
  chevron.textContent = '⌄';
  button.append(buttonCopy, chevron);

  const popover = doc.createElement('div');
  popover.className = 'model-picker-popover';
  popover.hidden = true;
  const searchWrap = doc.createElement('label');
  searchWrap.className = 'model-picker-search';
  const searchIcon = doc.createElement('span');
  searchIcon.setAttribute('aria-hidden', 'true');
  searchIcon.textContent = '⌕';
  const search = doc.createElement('input');
  search.type = 'search';
  search.placeholder = 'Quick search models or providers…';
  search.autocomplete = 'off';
  search.spellcheck = false;
  search.setAttribute('aria-label', 'Search models');
  searchWrap.append(searchIcon, search);
  const list = doc.createElement('div');
  list.id = `${id}-list`;
  list.className = 'model-picker-list';
  list.setAttribute('role', 'listbox');
  popover.append(searchWrap, list);
  wrapper.append(button, popover);

  const state = { select, wrapper, button, value, provider, popover, search, list };
  doc.defaultView.addEventListener('resize', () => {
    if (!popover.hidden) positionModelPicker(state);
  });
  pickerStates.set(select, state);
  button.addEventListener('click', (event) => {
    event.preventDefault();
    event.stopPropagation();
    if (popover.hidden) openModelPicker(state);
    else closePicker(state, { restoreFocus: true });
  });
  button.addEventListener('keydown', (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey || event.key.length !== 1 || event.key === ' ') return;
    event.preventDefault();
    openModelPicker(state);
    if (event.key !== '/') {
      state.search.value = event.key;
      renderPickerOptions(state);
    }
  });
  wrapper.addEventListener('pointerdown', (event) => event.stopPropagation());
  search.addEventListener('input', () => renderPickerOptions(state));
  search.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      closePicker(state, { restoreFocus: true });
    } else if (event.key === 'ArrowDown') {
      event.preventDefault();
      state.list.querySelector('.model-picker-option')?.focus();
    }
  });
  list.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      closePicker(state, { restoreFocus: true });
    } else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      focusPickerOption(state, event.target, event.key === 'ArrowDown' ? 1 : -1);
    } else if (event.key === 'Home' || event.key === 'End') {
      event.preventDefault();
      focusPickerOption(state, event.target, event.key === 'Home' ? 'first' : 'last');
    }
  });
  select.addEventListener('change', () => syncPicker(state));
  doc.addEventListener('pointerdown', () => closePicker(state));
  new MutationObserver(() => syncPicker(state)).observe(select, {
    attributes: true,
    attributeFilter: ['disabled']
  });
  syncPicker(state);
  return state;
}

export function populateModelSelect(select, settings) {
  if (!select) return;
  const selected = selectedModel(settings);
  select.textContent = '';
  for (const provider of PROVIDERS) {
    const group = document.createElement('optgroup');
    const configured = settings?.configuredProviders?.includes(provider.id);
    group.label = `${configured ? '●' : '○'} ${provider.name}`;
    for (const entry of providerModelChoices(provider, settings)) {
      const model = modelId(entry);
      const label = modelLabel(entry);
      const option = document.createElement('option');
      option.value = modelChoice(provider.id, model);
      option.textContent = label;
      option.selected = provider.id === selected.provider && model === selected.model;
      group.append(option);
    }
    select.append(group);
  }
  const picker = ensureModelPicker(select);
  picker.recentChoices = normalizeRecentModels(settings?.recentModels).slice(0, MAX_VISIBLE_RECENT_MODELS)
    .map((item) => modelChoice(item.providerID, item.modelID));
  syncPicker(picker);
  if (!picker.popover.hidden) renderPickerOptions(picker);
}
