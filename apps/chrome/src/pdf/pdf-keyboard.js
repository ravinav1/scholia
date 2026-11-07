export const PDF_KEYBOARD_LINE_STEP = 56;

function normalizedKey(value) {
  if (value === 'Spacebar') return ' ';
  return String(value || '');
}

export function pdfKeyboardAction(event = {}, {
  viewportHeight = 0,
  toolbarHeight = 0
} = {}) {
  if (event.defaultPrevented || event.isComposing) return null;
  const key = normalizedKey(event.key);
  const primaryModifier = Boolean(event.metaKey || event.ctrlKey);

  if (primaryModifier && !event.altKey && !event.shiftKey) {
    if (key === '+' || key === '=') return { type: 'zoom', direction: 1 };
    if (key === '-' || key === '_') return { type: 'zoom', direction: -1 };
    if (key === '0') return { type: 'zoom', direction: 0 };
    return null;
  }
  if (primaryModifier || event.altKey) return null;
  if (event.shiftKey && key !== ' ') return null;

  const pageStep = Math.max(160, Number(viewportHeight) - Number(toolbarHeight) - 32);
  switch (key) {
  case 'ArrowUp':
    return { type: 'scroll', top: -PDF_KEYBOARD_LINE_STEP, left: 0 };
  case 'ArrowDown':
    return { type: 'scroll', top: PDF_KEYBOARD_LINE_STEP, left: 0 };
  case 'ArrowLeft':
    return { type: 'page', direction: -1 };
  case 'ArrowRight':
    return { type: 'page', direction: 1 };
  case 'PageUp':
    return { type: 'scroll', top: -pageStep, left: 0 };
  case 'PageDown':
    return { type: 'scroll', top: pageStep, left: 0 };
  case ' ':
    return { type: 'scroll', top: event.shiftKey ? -pageStep : pageStep, left: 0 };
  case 'Home':
    return { type: 'edge', edge: 'start' };
  case 'End':
    return { type: 'edge', edge: 'end' };
  default:
    return null;
  }
}

export function isPdfKeyboardControl(target, key = '') {
  const element = target?.nodeType === 3 ? target.parentElement : target;
  if (!element?.closest) return false;
  if (element.closest(
    'input, textarea, select, [contenteditable="true"], [contenteditable=""], '
      + '[role="textbox"], [role="slider"]'
  )) return true;
  return normalizedKey(key) === ' ' && Boolean(element.closest('button, a[href], [role="button"]'));
}
