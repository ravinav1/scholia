export const HTML_NAMESPACE = 'http://www.w3.org/1999/xhtml';

export function createHtmlElement(tagName, ownerDocument = document) {
  return ownerDocument.createElementNS(HTML_NAMESPACE, tagName);
}

export const ISOLATED_UI_EVENT_TYPES = Object.freeze([
  'keydown',
  'keypress',
  'keyup',
  'beforeinput',
  'input',
  'change',
  'compositionstart',
  'compositionupdate',
  'compositionend',
  'focusin',
  'focusout',
  'paste',
  'copy',
  'cut',
]);

export function isolateUiInputEvents(root) {
  const contain = (event) => event.stopPropagation();
  for (const type of ISOLATED_UI_EVENT_TYPES) root.addEventListener(type, contain);
}

export function isQuickChatShortcut(event, platform = globalThis.navigator?.platform || '') {
  if (
    !event ||
    event.repeat ||
    event.altKey ||
    !event.shiftKey ||
    String(event.key || '').toLowerCase() !== 'k'
  )
    return false;
  const mac = /mac|iphone|ipad|ipod/i.test(String(platform));
  return mac ? Boolean(event.metaKey && !event.ctrlKey) : Boolean(event.ctrlKey && !event.metaKey);
}

export function responseSelectionInteractionProtected({
  pointerInteraction = false,
  focusInside = false,
} = {}) {
  return Boolean(pointerInteraction || focusInside);
}
