import { mountChatPanel } from '../panel.js';

// Render in the reader's document. Nested chrome-extension:// frame navigation
// is blocked by affected Brave builds; no iframe or browser side panel is needed.
export async function mountPdfChat(host, { close } = {}) {
  const [markupResponse, styleResponse] = await Promise.all([
    fetch(chrome.runtime.getURL('panel.html')),
    fetch(chrome.runtime.getURL('panel.css'))
  ]);
  if (!markupResponse.ok || !styleResponse.ok) throw new Error('The PDF chat interface could not be loaded.');
  const [markup, css] = await Promise.all([markupResponse.text(), styleResponse.text()]);
  const template = new DOMParser().parseFromString(markup, 'text/html');
  const root = host.shadowRoot || host.attachShadow({ mode: 'open' });
  const style = document.createElement('style');
  style.textContent = css
    .replaceAll(':root', ':host')
    .replace(/\bhtml,body\b/g, ':host,.panel-document')
    .replace(/\bbody\s*\{/g, '.panel-document {')
    .replace(/@media\s*\((min|max)-width:/g, '@container ($1-width:')
    .replace(/\b(\d*\.?\d+)vw\b/g, '$1cqw')
    + '\n:host { display:block; container-type:inline-size; }'
    + '\n.panel-document { position:relative; contain:layout paint; width:100%; height:100%; }';
  const mathStyle = document.createElement('link');
  mathStyle.rel = 'stylesheet';
  mathStyle.href = chrome.runtime.getURL('vendor/katex/katex.min.css');
  const body = document.createElement('div');
  body.className = 'panel-document';
  body.append(...[...template.body.children]
    .filter((node) => node.tagName !== 'SCRIPT')
    .map((node) => document.importNode(node, true)));
  const fileStyle = document.createElement('link');
  fileStyle.rel = 'stylesheet';
  fileStyle.href = chrome.runtime.getURL('file-attachments.css');
  root.replaceChildren(style, mathStyle, fileStyle, body);
  // Keep chat typing, selection, search, and Escape out of the PDF shortcuts.
  root.addEventListener('keydown', (event) => event.stopPropagation());
  root.addEventListener('pointerup', (event) => event.stopPropagation());
  return mountChatPanel({ root, embeddedPdf: true, close });
}
