import { isQuickChatShortcut } from './ui-primitives.js';
import { sendRuntimeMessage } from './runtime-message.js';

const uiMessages = new Set([
  'SCHOLIA_EXPLAIN_CURRENT', 'SCHOLIA_EXPLAIN_TEXT', 'SCHOLIA_START_CAPTURE', 'SCHOLIA_SELECT_REGION',
]);
const handledMessages = new Set([
  'SCHOLIA_EXPLAIN_CURRENT', 'SCHOLIA_EXPLAIN_TEXT', 'SCHOLIA_START_CAPTURE',
  'SCHOLIA_SELECT_REGION', 'SCHOLIA_GET_PAGE_CONTEXT', 'SCHOLIA_GET_RESEARCH_PAGE',
  'SCHOLIA_GET_TAB_CONTEXT_PREVIEW', 'SCHOLIA_PREPARE_DEEP_PAGE',
  'SCHOLIA_SCROLL_DEEP_PAGE', 'SCHOLIA_FINISH_DEEP_PAGE', 'SCHOLIA_GET_SITE_CONTEXT',
]);

// Clone the range before an asynchronous module load. Reading window.getSelection
// afterwards would capture a click in another control instead of the user's text.
export function snapshotSelection(selection) {
  if (!selection || selection.isCollapsed || !selection.rangeCount) return null;
  const range = selection.getRangeAt(0).cloneRange();
  const text = selection.toString();
  return {
    isCollapsed: false, rangeCount: 1,
    anchorNode: selection.anchorNode, focusNode: selection.focusNode,
    anchorOffset: selection.anchorOffset, focusOffset: selection.focusOffset,
    getRangeAt: () => range, toString: () => text,
  };
}

export function lazyContent(load, initialize = (module) => module.mountContent()) {
  let pending;
  let attempt = 0;
  return () => {
    if (!pending) {
      // A failed import is cached by some browsers. Use a fresh, extension-owned
      // URL on retry; the successful promise stays shared by all concurrent callers.
      pending = Promise.resolve().then(() => load(attempt++)).then(initialize);
      pending = pending.catch((error) => { pending = null; throw error; });
    }
    return pending;
  };
}

export function installContentBootstrap({
  doc = document, win = window, runtime = chrome.runtime,
  load = (attempt) => import(runtime.getURL(`content-ui.js${attempt ? `?retry=${attempt}` : ''}`)),
  loadContext = (attempt) => import(runtime.getURL(`content-context.js${attempt ? `?retry=${attempt}` : ''}`)),
} = {}) {
  const loadContent = lazyContent(load);
  const contextReader = lazyContent(loadContext, (module) => module.createContextReader());
  let ready = false;
  let selectionGeneration = 0;
  let documentGeneration = 0;
  let selectionTimer;
  let warning;
  let warningTimer;
  const report = (error) => {
    if (!warning) {
      warning = doc.createElement('div');
      warning.setAttribute('role', 'status');
      warning.style.cssText = 'position:fixed;bottom:20px;right:20px;z-index:2147483647;padding:12px;background:#fff;color:#222;border:1px solid #aaa;border-radius:8px;font:14px system-ui;max-width:360px';
      doc.documentElement.append(warning);
    }
    warning.textContent = 'Scholia could not open. Select again or retry the command. ' + (error?.message || '');
    clearTimeout(warningTimer);
    warningTimer = setTimeout(() => { warning?.remove(); warning = null; }, 6000);
  };
  const ensure = () => loadContent().then((app) => { ready = true; warning?.remove(); warning = null; return app; });
  const inspect = () => {
    if (ready) return;
    const generation = ++selectionGeneration;
    const selection = snapshotSelection(win.getSelection());
    if (!selection) return;
    ensure().then((app) => {
      if (generation === selectionGeneration) app.inspectSelection(selection);
    }).catch(report);
  };
  const schedule = (event) => {
    if (ready || event?.target?.closest?.('#pdf-chat-content, #scholia-extension-root')) return;
    ++selectionGeneration;
    clearTimeout(selectionTimer);
    selectionTimer = setTimeout(inspect, event?.type === 'pointerup' ? 35 : 280);
  };
  doc.addEventListener('scholia:document-instance-changed', () => {
    documentGeneration++; selectionGeneration++; clearTimeout(selectionTimer);
  });
  doc.addEventListener('selectionchange', schedule, true);
  doc.addEventListener('pointerup', schedule, true);
  doc.addEventListener('keyup', (event) => {
    if (event.key === 'Shift' || event.key?.startsWith('Arrow') || ['Home', 'End'].includes(event.key)) inspect();
  }, true);
  doc.addEventListener('click', (event) => {
    if (ready || !event.target?.closest?.('mjx-container, .katex, math')) return;
    ensure().then((app) => app.handleMathClick(event)).catch(report);
  }, true);
  // Start loading as a math touch begins so the existing long-press controller
  // owns the gesture. Replay only a touch that is still down after initialization.
  let touch;
  doc.addEventListener('touchstart', (event) => {
    if (ready || event.touches?.length !== 1 || !event.target?.closest?.('mjx-container, .katex, math')) return;
    touch = event;
    ensure().then((app) => { if (touch === event) app.beginMathTouch?.(event); }).catch(report);
  }, { passive: true, capture: true });
  doc.addEventListener('touchmove', (event) => {
    const first = touch?.touches?.[0], current = event.touches?.[0];
    if (first && (!current || Math.abs(first.clientX - current.clientX) > 10 || Math.abs(first.clientY - current.clientY) > 10)) touch = null;
  }, { passive: true, capture: true });
  doc.addEventListener('touchend', () => { touch = null; }, { passive: true, capture: true });
  doc.addEventListener('touchcancel', () => { touch = null; }, { passive: true, capture: true });
  doc.addEventListener('keydown', (event) => {
    if (ready || win.top !== win || event.target?.closest?.('#pdf-chat-content') || !isQuickChatShortcut(event)) return;
    event.preventDefault(); event.stopImmediatePropagation();
    sendRuntimeMessage({ type: 'SCHOLIA_TOGGLE_QUICK_CHAT' }).catch(report);
  }, true);
  runtime.onMessage.addListener((message, sender, respond) => {
    if (!handledMessages.has(message?.type)) return undefined;
    const selection = snapshotSelection(win.getSelection());
    const generation = documentGeneration;
    (uiMessages.has(message.type) ? ensure() : contextReader()).then((app) => {
      if (generation !== documentGeneration) respond?.({ ok: false, error: 'The document changed. Retry in the current reading.' });
      else return app.handleRuntimeMessage(message, sender, respond, selection);
    })
      .catch((error) => { respond?.({ ok: false, error: error?.message || 'Scholia could not load.' }); report(error); });
    return true;
  });
  return { ensure };
}
