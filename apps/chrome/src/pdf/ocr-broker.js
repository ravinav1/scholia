let creating = null;
const pending = new Map();

async function ensureOcrDocument() {
  const url = chrome.runtime.getURL('ocr-offscreen.html');
  const contexts = await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'], documentUrls: [url] });
  if (contexts.length) return;
  if (!creating) {
    creating = chrome.offscreen.createDocument({
      url, reasons: ['WORKERS'], justification: 'Read scanned PDF pages locally with the bundled OCR worker.'
    }).finally(() => { creating = null; });
  }
  await creating;
}

export async function forwardOcrRequest(message, sender) {
  if (sender.id !== chrome.runtime.id) throw new Error('OCR is available only inside Scholia.');
  const id = String(message.requestId || '');
  if (!/^[\w-]{1,100}$/.test(id)) throw new Error('Invalid OCR request.');
  const requestId = `${sender.documentId || `${sender.tab?.id}:${sender.frameId}`}:${id}`;
  if (message.type === 'SCHOLIA_OCR_RECOGNIZE') {
    if (typeof message.image !== 'string' || message.image.length > 32_000_000
        || !/^data:image\/png;base64,[a-z0-9+/=]+$/i.test(message.image)) throw new Error('Invalid OCR page image.');
    const job = { cancelled: false };
    pending.set(requestId, job);
    try {
      await ensureOcrDocument();
      if (job.cancelled) throw new Error('OCR was cancelled.');
      const response = await chrome.runtime.sendMessage({ ...message, target: 'scholia-ocr', requestId });
      if (!response?.ok) throw new Error(response?.error || 'Local OCR could not read this page.');
      return response.value;
    } finally { pending.delete(requestId); }
  } else {
    const job = pending.get(requestId);
    if (job) job.cancelled = true;
    if (creating) await creating;
    const contexts = await chrome.runtime.getContexts({ contextTypes: ['OFFSCREEN_DOCUMENT'] });
    if (!contexts.length) return;
  }
  await chrome.runtime.sendMessage({ ...message, target: 'scholia-ocr', requestId });
}
