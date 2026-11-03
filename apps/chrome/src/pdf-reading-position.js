const POSITION_KEY = 'scholia.pdf-reading-position.v1';

// Chromium currently treats same-document History API calls in a MIME handler
// as a second handler navigation and crashes the browser (stream_info.cc).
// Session storage belongs to this tab and survives reloading the original URL.
export function readPdfPosition({ mimeHandled = false, history = globalThis.history, storage } = {}) {
  try {
    return mimeHandled ? JSON.parse((storage || globalThis.sessionStorage).getItem(POSITION_KEY) || 'null') : history.state?.scholiaPdfPosition;
  } catch { return null; }
}

export function writePdfPosition(position, { mimeHandled = false, history = globalThis.history, storage } = {}) {
  try {
    if (mimeHandled) (storage || globalThis.sessionStorage).setItem(POSITION_KEY, JSON.stringify(position));
    else history.replaceState({ ...history.state, scholiaPdfPosition: position }, '');
  } catch { /* Reading remains available if persistence is disabled. */ }
}
