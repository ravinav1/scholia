import { escapeHtml as esc } from '../chrome/src/html-escape.js';
import {
  teachingModes,
  coursePrompts,
  conversationScope,
  studyRenderKey,
} from './study-session.js';

let renderer;
let rendererPromise;

function loadRenderer() {
  return rendererPromise ||= import('../chrome/src/render.js').then((module) => {
    renderer = module;
    return module;
  }).catch((error) => {
    rendererPromise = null;
    throw error;
  });
}

// Keep independent message sections alive when a token, activity event or
// elapsed-time tick changes another section. This also preserves selection,
// disclosure state and focused source/copy controls during generation.
function updatePart(entry, name, key, markup) {
  let part = entry.parts.get(name);
  if (!part) {
    const node = entry.node.ownerDocument.createElement('div');
    node.dataset.messagePart = name;
    entry.node.append(node);
    part = { node };
    entry.parts.set(name, part);
  }
  if (part.key?.length === key.length && key.every((value, index) => value === part.key[index])) return;
  const open = new Set([...part.node.querySelectorAll('details[open]')].map((node) => node.dataset.detail));
  const html = markup();
  part.node.hidden = !html;
  part.node.innerHTML = html;
  for (const details of part.node.querySelectorAll('details')) details.open = open.has(details.dataset.detail);
  part.key = key;
}

function updateMessage(entry, message, sources, streaming) {
  const { renderMarkdown, renderActivity } = renderer;
  const part = (name, key, markup) => updatePart(entry, name, key, markup);
  const action = (title, name) =>
    `<button data-action="${name}" data-id="${esc(message.id)}">${title}</button>`;
  const route = message.role === 'assistant' && message.modelRouting;
  const routeLabel = route && (route.mode === 'auto'
    ? `Auto study · ${{ fast: 'Fast', balanced: 'Balanced', deep: 'Deep', manual: 'Selected model' }[route.tier] || 'Selected model'}`
    : route.mode === 'deep' ? 'Deep' : 'Fast');
  part('label', [message.role, message.isStreaming], () => `<div class="message-label">${message.role === 'user' ? 'YOU' : '✧ SCHOLIA'} ${message.isStreaming ? '· THINKING WITH YOU' : ''}</div>`);
  part('route', [routeLabel, route?.reason, route?.modelID], () => route ? `<div class="study-model-route" title="${esc(route.reason || '')}">${esc(routeLabel)} · ${esc(route.modelID || '')}</div>` : '');
  part('image', [message.imageData], () => message.imageData ? `<img alt="Question attachment" src="data:image/jpeg;base64,${esc(message.imageData)}">` : '');
  const files = (message.files || message.attachments || []).map((file) => ({
    id: file.id, sourcePath: file.sourcePath, mimeType: file.mimeType,
    textCorpusUTF16Count: file.textCorpusUTF16Count,
    name: file.name || file.fileName, text: file.text ?? file.extractedText ?? '',
    notice: file.notice || file.readDetail || '',
    status: file.status || ({ complete: 'readable', partial: 'partial', unreadable: 'unavailable' }[file.readStatus]) || 'unavailable',
    enabled: file.enabled !== false && file.isEnabled !== false,
  }));
  part('files', [studyRenderKey(files)], () => files.map((file, index) => `<details class="scholia-file-preview" data-detail="file-${index}"><summary>${file.mimeType === 'inode/directory' ? 'Folder' : 'File'} · ${esc(file.name)} · ${!file.enabled ? 'Excluded' : file.status === 'unavailable' ? 'Not read' : file.status === 'partial' ? 'Partial' : 'Read'}</summary><p>${esc(file.sourcePath || 'Local path unavailable')}${file.id ? ` · Attachment ${esc(file.id)}` : ''}</p><p>Saved extraction: ${(file.textCorpusUTF16Count || file.text.length).toLocaleString()} characters. Preview shows up to 16,000 characters; each answer may use different excerpts.</p><p>${esc(file.notice)}</p>${file.text ? `<pre>${esc(file.text.slice(0, 16_000))}</pre>` : ''}</details>`).join(''));
  part('reasoning', [message.reasoning], () => message.reasoning ? `<details data-detail="reasoning"><summary>Reasoning</summary>${renderMarkdown(message.reasoning, { cache: !message.isStreaming })}</details>` : '');
  part('activity', [studyRenderKey(message.activity || [])], () => renderActivity(message.activity));
  part('content', [message.content], () => renderMarkdown(message.content || '', { cache: !message.isStreaming }));
  part('progress', [message.isStreaming, message.metadata], () => message.isStreaming ? `<div class="generation-progress" role="status"><span class="generation-progress-label">${esc(message.metadata || 'Preparing your answer…')}</span><span class="generation-elapsed" aria-hidden="true"></span></div>` : '');
  part('sources', [studyRenderKey(sources)], () => sources.length ? `<details data-detail="sources"><summary>${sources.length} pages provided</summary><div class="source-chips">${sources.map((source) => `<button data-source="${esc(source.documentID)}" data-page="${source.page}" title="${esc(source.title)}">${esc(source.title.slice(0, 24))} · p. ${source.page}</button>`).join('')}</div></details>` : '');
  part('actions', [message.role, message.role === 'user' && streaming], () => `<div class="message-actions">${action('Copy', 'copy')}${message.role === 'user' && !streaming ? action('Edit', 'edit') : ''}</div>`);
}

export class StudyConversation {
  constructor(host) {
    this.host = host;
    this.entries = new Map();
  }

  render(state) {
    this.latestState = state;
    const { host } = this;
    const changedThread = this.thread !== state.library.selectedThreadID;
    const atBottom = changedThread || host.scrollHeight - host.scrollTop - host.clientHeight < 90;
    this.thread = state.library.selectedThreadID;
    if (!state.messages.length) {
      const scope = conversationScope(state);
      const automaticContext = state.automaticContextEnabled !== false;
      if (this.entries.size || !host.querySelector('.tutor-empty') || this.emptyScope !== scope || this.emptyMode !== state.mode || this.emptyAutomaticContext !== automaticContext) {
        this.entries.clear();
        this.emptyScope = scope;
        this.emptyMode = state.mode;
        this.emptyAutomaticContext = automaticContext;
        host.innerHTML =
          !automaticContext
            ? '<div class="tutor-empty"><h3>Choose your context.</h3><p>Automatic reading and course context is off. Attach files or paste the information you want to discuss. Each file shows what could be read.</p></div>'
            : state.mode === 'General'
            ? '<div class="tutor-empty"><h3>What’s on your mind?</h3><p>Ask anything, brainstorm, or talk through an idea. Course materials are available when relevant.</p><button data-study-prompt="General">Talk through an idea<span aria-hidden="true">↗</span></button></div>'
            : scope === 'course'
            ? `<div class="tutor-empty"><h3>Your whole course,<br>in view.</h3><p>Explore topics, assignments, deadlines, and connections between readings. Start with a question about your course.</p>${coursePrompts.map(({ id, title }) => `<button data-course-prompt="${id}">${title}<span aria-hidden="true">↗</span></button>`).join('')}</div>`
            : `<div class="tutor-empty"><h3>What would you like<br>to understand?</h3><p>Explore an idea, work through an example, or test what you remember. Choose a starting point and make it your own.</p>${teachingModes.map(({ mode, title }) => `<button data-study-prompt="${esc(mode)}">${title}<span aria-hidden="true">↗</span></button>`).join('')}</div>`;
      }
      return;
    }
    if (!renderer) {
      if (!this.ready) {
        host.innerHTML = '<div class="tutor-empty" role="status">Opening conversation…</div>';
        this.ready = loadRenderer().then(() => this.render(this.latestState)).catch(() => {
          this.ready = null;
          if (this.latestState.messages.length) host.innerHTML = '<div class="tutor-empty" role="status">The conversation could not be loaded. Please try again.</div>';
        });
      }
      return;
    }
    host.querySelector('.tutor-empty')?.remove();
    const ids = new Set(state.messages.map((message) => message.id));
    for (const [id, entry] of this.entries) {
      if (!ids.has(id)) {
        entry.node.remove();
        this.entries.delete(id);
      }
    }
    let previous = null;
    for (const message of state.messages) {
      const sources = state.sources?.[message.id] || [];
      let entry = this.entries.get(message.id);
      if (!entry) {
        const node = host.ownerDocument.createElement('article');
        node.className = `message ${message.role === 'user' ? 'user' : 'assistant'}`;
        node.dataset.messageId = message.id;
        entry = { node, parts: new Map() };
        this.entries.set(message.id, entry);
      }
      updateMessage(entry, message, sources, state.streaming);
      const elapsed = entry.node.querySelector('.generation-elapsed');
      if (elapsed && state.answerStartedAt) {
        const text = `${Math.max(0, Math.floor(Date.now() / 1000 - state.answerStartedAt))}s`;
        if (elapsed.textContent !== text) elapsed.textContent = text;
      }
      const next = previous ? previous.nextElementSibling : host.firstElementChild;
      if (next !== entry.node) host.insertBefore(entry.node, next);
      previous = entry.node;
    }
    if (atBottom) host.scrollTop = host.scrollHeight;
  }
}
