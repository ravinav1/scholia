import { copyCodeBlock, copyText } from './clipboard.js';
import { isCanvasCoursePage, canvasCourseFromUrl } from './canvas-course.js';
import fileStyles from '../file-attachments.css';
import { mountFileComposer, appendFileChips } from './file-composer.js';
import contentStyles from './content.css';
import {
  modelReasoning,
  providerById,
  providerSupportsFastMode,
  providerSupportsWebSearch,
  siteIsEnabled
} from '../../../packages/core/src/providers.js';
import { populateModelSelect } from './model-select.js';
import {
  COMPACT_PACKED_CONTEXT_CHARS,
  packPageContext,
  packParentContext,
  packSiteContext
} from '../../../packages/core/src/context.js';
import { renderMarkdown, renderReasoning } from './render.js';
import { sendRuntimeMessage as extensionMessage } from './runtime-message.js';
import { bridgeLaunchDecision } from './bridge-launch.js';
import { formatUsageRemaining } from './usage.js';
import { createHtmlElement } from './html-elements.js';
import { clipboardImageFile, normalizeImageFile } from './image-input.js';
import { isolateUiInputEvents } from './ui-event-boundary.js';
import { prepareEditedResend, replaceConversationPrefix } from './chat-edit.js';
import { canExplainImageDirectly, DEFAULT_IMAGE_EXPLANATION, createUserTurn, requestConversation } from './chat-turn.js';
import { selectionContextForQuestion } from './selection-context.js';
import { contextCharacterLimit, defaultContextMode } from './context-mode.js';
import { detectDocumentLanguage, documentLanguageLabel } from './document-language.js';
import { isQuickChatShortcut } from './keyboard-shortcuts.js';
import { crawlSite, siteLinksFromDocument } from './site-context.js';
import { researchUrl, researchLinksFromDocument } from './research-links.js';
import {
  finishDeepPageCapture,
  prepareDeepPageCapture,
  scrollDeepPageCapture
} from './deep-page.js';
import {
  chainAtPoint,
  collapseWhitespace,
  cropScreenshot,
  currentSelectionCapture,
  currentSiteKey,
  decodeMathNode,
  directMathChildren,
  lastRangeRect,
  leafMathNodes,
  mathChain,
  mathContainer,
  resolvedPageMetadata,
  sourceUrl,
  wrappedMath
} from './page-capture.js';

const HOST_ID = 'scholia-extension-root';
const PDF_LEARNING_MODE_KEY = 'scholia.pdf-learning-mode.v1';

function boot() {
  const host = createHtmlElement('div');
  host.id = HOST_ID;
  host.style.cssText = 'all:initial;position:fixed;inset:0;z-index:2147483647;pointer-events:none;contain:layout style;';
  const shadow = host.attachShadow({ mode: 'closed' });
  const style = createHtmlElement('style');
  style.textContent = contentStyles + '\n' + fileStyles;
  shadow.append(style);
  document.documentElement.append(host);

  loadKatexStyles(shadow);
  const app = new ScholiaContent(shadow);
  app.mount();
}

async function loadKatexStyles(shadow) {
  try {
    const response = await fetch(chrome.runtime.getURL('vendor/katex/katex.min.css'));
    if (!response.ok) return;
    const style = createHtmlElement('style');
    style.textContent = await response.text();
    shadow.prepend(style);
  } catch {}
}

class ScholiaContent {
  constructor(shadow) {
    this.shadow = shadow;
    this.capture = null;
    this.pendingCapture = null;
    this.layers = [];
    this.mathState = null;
    this.settings = null;
    this.messages = [];
    this.editingMessageIndex = -1;
    this.streaming = false;
    this.requestId = '';
    this.port = null;
    this.toastTimer = null;
    this.selectionTimer = null;
    this.captureForConversation = false;
    this.captureReturnToModal = false;
    this.popoverInteracting = false;
    this.popoverInteractionTimer = null;
    this.multiSelection = [];
    this.multiAddMode = false;
    this.singleMathPick = null;
    this.highlightElements = [];
    this.bridgeStatus = null;
    this.bridgeStatusRequest = 0;
    this.bridgeWatchTimer = null;
    this.bridgeLaunchState = null;
    this.longPressTimer = null;
    this.justLongPressed = false;
    this.imageQuestionDraft = '';
    this.webSearchEnabled = false;
    this.learningModeEnabled = false;
    this.refreshingChatGptContext = false;
    this.siteContextCache = new Map();
    this.lastPublishedSelection = '';
  }

  mount() {
    const template = createHtmlElement('template');
    template.innerHTML = `
      <section class="scholia-pill" data-pill hidden role="dialog" aria-label="Ask Scholia about this selection">
        <div class="scholia-pill__preview">
          <span class="scholia-pill__kind" data-pill-kind>Text</span>
          <span class="scholia-pill__preview-text" data-pill-preview></span>
          <button type="button" class="scholia-pill__add" data-add-symbol hidden title="Select several symbols">+ symbol</button>
          <span class="scholia-pill__math-tools" data-math-tools hidden>
            <button type="button" data-narrow title="Select a smaller math part">Narrower</button>
            <button type="button" data-wider title="Select a wider math part">Wider</button>
          </span>
          <button type="button" class="scholia-pill__site" data-disable-site title="Disable Scholia on this site" aria-label="Disable Scholia on this site"><span aria-hidden="true">⊘</span></button>
        </div>
        <div class="scholia-pill__row">
          <input data-pill-question aria-label="Ask about selection" placeholder="Ask about this…">
          <button type="button" class="scholia-primary" data-pill-send>Explain</button>
        </div>
        <div class="scholia-pill__options">
          <label class="scholia-pill__context" data-web-search-option hidden title="Let the selected model search the public web for this question">
            <input data-web-search-toggle type="checkbox">
            <span>Search the web</span>
          </label>
          <label class="scholia-pill__context" data-chatgpt-context hidden>
            <input data-chatgpt-context-toggle type="checkbox">
            <span data-chatgpt-context-label>Include imported ChatGPT context</span>
          </label>
        </div>
      </section>
      <div class="scholia-backdrop" data-backdrop hidden>
        <div class="scholia-layer-stack" data-layer-stack aria-hidden="true"></div>
        <section class="scholia-modal" data-modal role="dialog" aria-modal="true" aria-label="Scholia explanation">
          <header class="scholia-header">
            <div class="scholia-brand"><span class="scholia-mark">S</span><span class="scholia-title">Scholia</span></div>
            <select class="scholia-model" data-model aria-label="AI model"></select>
            <select class="scholia-effort" data-effort hidden aria-label="Reasoning effort"></select>
            <button type="button" class="scholia-header-chip" data-fast hidden title="Fast mode" aria-pressed="false">⚡</button>
            <button type="button" class="scholia-header-chip" data-web-search-action hidden title="Use web search for the next question" aria-pressed="false"><span aria-hidden="true">⊕</span> Web</button>
            <button type="button" class="scholia-header-chip scholia-bridge-pill" data-bridge hidden><span class="scholia-status-dot is-checking"></span><span data-bridge-label>checking</span></button>
            <button type="button" class="scholia-header-chip" data-move-chat title="Move this explanation to a saved chat">Move to chat ↗</button>
            <button type="button" class="scholia-icon-button" data-settings title="Settings" aria-label="Settings">⚙</button>
            <button type="button" class="scholia-icon-button" data-disable-site title="Disable Scholia on this site" aria-label="Disable Scholia on this site">⊘</button>
            <button type="button" class="scholia-icon-button" data-close title="Close" aria-label="Close">×</button>
          </header>
          <div class="scholia-bridge-bar" data-bridge-bar hidden>
            <span class="scholia-status-dot is-down"></span>
            <span data-bridge-bar-text>Local bridge is not running.</span>
            <button type="button" data-bridge-start>Start bridge</button>
            <button type="button" data-bridge-copy>Copy command</button>
          </div>
          <div class="scholia-source" data-source hidden>
            <img data-source-image hidden alt="Captured screen region">
            <div class="scholia-source__body">
              <div class="scholia-source__heading">
                <span class="scholia-source__label" data-source-label>Selected text</span>
                <span class="scholia-source__context" data-source-context>Selection only</span>
              </div>
              <div class="scholia-source__text" data-source-text></div>
            </div>
          </div>
          <main class="scholia-messages" data-messages><div class="scholia-empty"><strong>Ask in context</strong>Select text or capture a region, then Scholia will explain it here.</div></main>
          <footer class="scholia-composer">
            <div data-files hidden></div>
            <div class="scholia-composer__box">
              <button type="button" class="scholia-icon-button" data-attach-files title="Attach files" aria-label="Choose an image">▧</button>
              <button type="button" class="scholia-icon-button" data-capture title="Capture another region" aria-label="Capture another region">▣</button>
              <textarea data-composer rows="1" placeholder="Ask a follow-up…" aria-label="Ask a follow-up"></textarea>
              <button type="button" class="scholia-primary scholia-explain-capture" data-explain-capture aria-label="Explain captured image" hidden>Explain</button>
              <button type="button" class="scholia-primary scholia-send" data-send aria-label="Send">↑</button>
            </div>
            <div class="scholia-composer__hint">Enter to send · Shift+Enter for a new line</div>
            <input data-image-file type="file" accept="image/*" hidden>
          </footer>
        </section>
      </div>
      <div class="scholia-toast" data-toast hidden role="status"></div>
      <div class="scholia-capture" data-capture-layer tabindex="-1" role="dialog" aria-label="Select a screen region" hidden>
        <div class="scholia-capture__help">Drag over the page to capture a region · Escape to cancel <button type="button" data-capture-cancel>Cancel</button></div>
        <div class="scholia-capture__rect" data-capture-rect hidden></div>
      </div>`;
    this.shadow.append(template.content);

    this.bindElements();
    this.bindEvents();
    this.refreshSettings();
  }

  bindElements() {
    const q = (selector) => this.shadow.querySelector(selector);
    this.els = {
      pill: q('[data-pill]'), pillKind: q('[data-pill-kind]'), pillPreview: q('[data-pill-preview]'),
      pillQuestion: q('[data-pill-question]'), pillSend: q('[data-pill-send]'), mathTools: q('[data-math-tools]'), addSymbol: q('[data-add-symbol]'),
      chatGptContext: q('[data-chatgpt-context]'), chatGptContextToggle: q('[data-chatgpt-context-toggle]'),
      chatGptContextLabel: q('[data-chatgpt-context-label]'),
      webSearchOption: q('[data-web-search-option]'), webSearchToggle: q('[data-web-search-toggle]'),
      backdrop: q('[data-backdrop]'), layerStack: q('[data-layer-stack]'), modal: q('[data-modal]'), close: q('[data-close]'),
      moveChat: q('[data-move-chat]'),
      model: q('[data-model]'), effort: q('[data-effort]'), fast: q('[data-fast]'), webSearchAction: q('[data-web-search-action]'),
      bridge: q('[data-bridge]'), bridgeLabel: q('[data-bridge-label]'), bridgeBar: q('[data-bridge-bar]'),
      bridgeBarText: q('[data-bridge-bar-text]'), source: q('[data-source]'),
      sourceLabel: q('[data-source-label]'), sourceContext: q('[data-source-context]'),
      sourceText: q('[data-source-text]'), sourceImage: q('[data-source-image]'),
      messages: q('[data-messages]'), composer: q('[data-composer]'), explainCapture: q('[data-explain-capture]'),
      send: q('[data-send]'), imageFile: q('[data-image-file]'),
      toast: q('[data-toast]'), captureLayer: q('[data-capture-layer]'), captureRect: q('[data-capture-rect]')
    };
    this.els.disableSiteButtons = [...this.shadow.querySelectorAll('[data-disable-site]')];
  }

  bindEvents() {
    const host = document.getElementById(HOST_ID);
    isolateUiInputEvents(this.shadow);
    document.addEventListener('pointerdown', (event) => {
      if (!this.els.pill.hidden && !event.composedPath().includes(host)) this.hidePill(false);
    }, true);
    this.shadow.addEventListener('pointerdown', (event) => {
      if (!this.els.pill.hidden && !event.target.closest?.('.scholia-pill')) this.hidePill(false);
    }, true);
    document.addEventListener('pointerup', (event) => {
      if (event.target?.closest?.('#pdf-chat-content')) return;
      if (event.altKey || this.justLongPressed || this.popoverInteracting) return;
      clearTimeout(this.selectionTimer);
      this.selectionTimer = setTimeout(() => this.inspectSelection(), event.pointerType === 'touch' ? 250 : 35);
    }, true);
    const scheduleSelectionInspection = () => {
      if (this.popoverInteracting || this.mathState || this.multiSelection.length) return;
      clearTimeout(this.selectionTimer);
      this.selectionTimer = setTimeout(() => this.inspectSelection(), 280);
    };
    document.addEventListener('selectionchange', scheduleSelectionInspection, true);
    this.shadow.addEventListener('selectionchange', scheduleSelectionInspection, true);
    document.addEventListener('scholia:document-instance-changed', () => {
      if (!this.els.backdrop.hidden) this.closeModal();
      else this.hidePill(false);
      this.clearLiveSelection();
      this.lastPublishedSelection = '';
    });
    document.addEventListener('keyup', (event) => {
      if (event.target?.closest?.('#pdf-chat-content')) return;
      if (event.key === 'Shift' || event.key.startsWith('Arrow') || event.key === 'Home' || event.key === 'End') this.inspectSelection();
    }, true);
    document.addEventListener('click', (event) => this.handleMathClick(event), true);
    this.shadow.addEventListener('click', (event) => this.handleMathClick(event), true);
    this.bindMathTouch();
    document.addEventListener('scroll', () => {
      if (!this.els.backdrop.hidden || !this.els.captureLayer.hidden) return;
      if (this.pendingCapture?.range && !this.els.pill.hidden) {
        this.paintRangeHighlight(this.pendingCapture.range);
        const rect = lastRangeRect(this.pendingCapture.range);
        if (rect) this.showPill(rect);
        return;
      }
      if (this.mathState || this.multiSelection.length) return;
      this.hidePill(false);
    }, { passive: true, capture: true });
    document.addEventListener('keydown', (event) => {
      if (event.target?.closest?.('#pdf-chat-content')) return;
      if (window.top === window && isQuickChatShortcut(event)) {
        event.preventDefault();
        event.stopImmediatePropagation();
        extensionMessage({ type: 'SCHOLIA_TOGGLE_QUICK_CHAT' })
          .catch((error) => this.toast(error?.message || 'Quick Chat could not be toggled.'));
        return;
      }
      if (event.key !== 'Escape') return;
      if (!this.els.captureLayer.hidden) this.cancelCapture();
      else if (!this.els.backdrop.hidden) this.closeTopLayer();
      else this.hidePill(false);
    }, true);

    this.els.pill.addEventListener('pointerdown', () => this.markPopoverInteraction());
    this.els.pill.addEventListener('click', (event) => { this.markPopoverInteraction(); event.stopPropagation(); });
    this.els.pillSend.addEventListener('click', () => this.explainPill());
    this.els.pillQuestion.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
        event.preventDefault();
        this.explainPill();
      }
    });
    this.shadow.querySelector('[data-narrow]').addEventListener('click', () => this.updateMathDepth(-1));
    this.shadow.querySelector('[data-wider]').addEventListener('click', () => this.updateMathDepth(1));
    this.els.addSymbol.addEventListener('click', () => {
      this.multiAddMode = !this.multiAddMode;
      this.updateAddSymbolButton();
    });
    this.els.close.addEventListener('click', () => this.closeTopLayer());
    this.els.moveChat.addEventListener('click', () => this.moveToChat());
    this.els.backdrop.addEventListener('pointerdown', (event) => {
      if (event.target === this.els.backdrop) this.closeTopLayer();
    });
    this.shadow.querySelector('[data-settings]').addEventListener('click', () => extensionMessage({ type: 'SCHOLIA_OPEN_OPTIONS' }).catch((error) => this.toast(error.message)));
    for (const button of this.els.disableSiteButtons) button.addEventListener('click', () => this.disableCurrentSite());
    this.fileComposer = mountFileComposer({
      button: this.shadow.querySelector('[data-attach-files]'),
      container: this.shadow.querySelector('[data-files]'),
      dropTarget: this.els.backdrop, pasteTarget: this.els.composer,
      disabled: () => this.streaming || this.layers.at(-1)?.moving
    });
    this.shadow.querySelector('[data-capture]').addEventListener('click', () => this.startCapture(true));
    this.els.explainCapture.addEventListener('click', () => this.sendComposer());
    this.els.send.addEventListener('click', () => this.sendComposer());
    this.els.composer.addEventListener('input', () => {
      this.resizeComposer();
      this.renderComposerSubmitAction();
    });
    this.els.composer.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
        event.preventDefault();
        this.sendComposer();
      }
    });

    this.els.pillQuestion.addEventListener('paste', (event) => this.handleImagePaste(event));
    this.els.imageFile.addEventListener('change', () => {
      const [file] = this.els.imageFile.files || [];
      const question = this.imageQuestionDraft;
      this.useImageFile(file, { question }).catch((error) => this.toast(error.message || 'Could not read that image.')).finally(() => {
        this.els.imageFile.value = '';
        this.imageQuestionDraft = '';
      });
    });
    this.els.model.addEventListener('change', () => {
      this.updateModelControls();
      this.saveSelectedModel();
    });
    this.els.effort.addEventListener('change', () => this.saveSelectedModel());
    this.els.fast.addEventListener('click', () => {
      this.settings.fastMode = !this.settings.fastMode;
      this.updateModelControls();
      this.saveSelectedModel();
    });
    this.els.webSearchAction.addEventListener('click', () => {
      this.webSearchEnabled = !this.webSearchEnabled;
      this.updateWebSearchControls();
    });
    this.els.bridge.addEventListener('click', () => {
      if (this.bridgeStatus?.up) this.refreshBridgeStatus(true);
      else this.startBridge();
    });
    this.shadow.querySelector('[data-bridge-start]').addEventListener('click', () => this.startBridge());
    this.shadow.querySelector('[data-bridge-copy]').addEventListener('click', () => this.copyBridgeCommand());
    this.els.messages.addEventListener('click', (event) => {
      const edit = event.target.closest?.('[data-edit-message]');
      if (edit) { this.beginMessageEdit(Number(edit.dataset.editMessage)); return; }
      const resend = event.target.closest?.('[data-resend-message]');
      if (resend) { this.resendEditedMessage(Number(resend.dataset.resendMessage)); return; }
      const cancel = event.target.closest?.('[data-cancel-message-edit]');
      if (cancel) { this.cancelMessageEdit(); return; }
      this.copyCode(event);
    });
    this.els.messages.addEventListener('keydown', (event) => {
      const editor = event.target.closest?.('[data-message-editor]');
      if (!editor) return;
      if (event.key === 'Escape') {
        event.preventDefault();
        this.cancelMessageEdit();
      } else if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
        event.preventDefault();
        this.resendEditedMessage(Number(editor.dataset.messageEditor));
      }
    });
    this.bindCaptureLayer();

    chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
      if (message?.type === 'SCHOLIA_EXPLAIN_CURRENT') {
        if (this.siteDisabled()) { this.toast(this.siteDisabledMessage()); sendResponse?.({ ok: true }); return; }
        const selected = currentSelectionCapture();
        if (!selected) this.toast('Select some text first.');
        else this.openAndAsk(selected, '').catch((error) => this.toast(error.message));
        sendResponse?.({ ok: true });
      } else if (message?.type === 'SCHOLIA_EXPLAIN_TEXT') {
        if (this.siteDisabled()) { sendResponse?.({ ok: true }); return; }
        const selected = currentSelectionCapture(message.text);
        if (selected) this.openAndAsk(selected, '').catch((error) => this.toast(error.message));
        sendResponse?.({ ok: true });
      } else if (message?.type === 'SCHOLIA_START_CAPTURE') {
        if (this.siteDisabled()) { this.toast(this.siteDisabledMessage()); sendResponse?.({ ok: true }); return; }
        this.startCapture(false);
        sendResponse?.({ ok: true });
      } else if (message?.type === 'SCHOLIA_SELECT_REGION') {
        if (this.siteDisabled()) { sendResponse({ ok: false, error: this.siteDisabledMessage() }); return; }
        this.startCapture(false, sendResponse);
        return true;
      } else if (message?.type === 'SCHOLIA_GET_PAGE_CONTEXT') {
        if (this.siteDisabled()) {
          sendResponse?.({ ok: false, error: this.siteDisabledMessage() });
          return;
        }
        resolvedPageMetadata().then((metadata) => {
          const shouldIncludeContext = typeof message.includeContext === 'boolean'
            ? message.includeContext
            : true;
          const context = shouldIncludeContext
            ? packPageContext(metadata.context, {
              outline: metadata.outline,
              selection: String(message.selection || ''),
              question: String(message.question || ''),
              ...(message.maxChars != null && Number.isFinite(Number(message.maxChars))
                ? { maxChars: Number(message.maxChars) }
                : {}),
              scopeDescription: metadata.htmlContextCharacters
                ? 'the live page text, accessible embedded content, image descriptions, and its sanitized DOM HTML snapshot'
                : 'the complete live page text'
            })
            : '';
          sendResponse?.({
            ok: true,
            value: {
              ...metadata,
              ...(isCanvasCoursePage(location.href, document) ? { canvasCourse: canvasCourseFromUrl(location.href) } : {}),
              context,
              outline: '',
              rawContextCharacters: metadata.context.length,
              packedContextCharacters: context.length
            }
          });
        }).catch((error) => {
          sendResponse?.({ ok: false, error: error?.message || 'Scholia could not read this page.' });
        });
        return true;
      } else if (message?.type === 'SCHOLIA_GET_RESEARCH_PAGE') {
        if (this.siteDisabled()) { sendResponse?.({ ok: false, error: this.siteDisabledMessage() }); return; }
        resolvedPageMetadata().then((metadata) => sendResponse?.({ ok: true, value: {
          url: researchUrl(location.href), title: metadata.pageTitle, text: metadata.context.slice(0, 120_000),
          links: researchLinksFromDocument(document, location.href),
          ...(isCanvasCoursePage(location.href, document) ? { canvasCourse: canvasCourseFromUrl(location.href) } : {})
        } })).catch((error) => sendResponse?.({ ok: false, error: error.message }));
        return true;
      } else if (message?.type === 'SCHOLIA_GET_TAB_CONTEXT_PREVIEW') {
        if (this.siteDisabled()) {
          sendResponse?.({ ok: false, error: this.siteDisabledMessage() });
          return;
        }
        resolvedPageMetadata().then((metadata) => {
          const maxChars = Number.isFinite(Number(message.maxChars))
            ? Number(message.maxChars)
            : 3_500;
          const context = packPageContext(metadata.context, {
            outline: metadata.outline,
            selection: String(message.correlationText || metadata.visibleContext || ''),
            question: String(message.question || ''),
            maxChars,
            scopeDescription: 'a related open browser tab'
          });
          sendResponse?.({
            ok: true,
            value: {
              pageTitle: metadata.pageTitle,
              url: metadata.url,
              visibleText: metadata.visibleContext,
              context
            }
          });
        }).catch((error) => {
          sendResponse?.({ ok: false, error: error?.message || 'Scholia could not read this tab.' });
        });
        return true;
      } else if (message?.type === 'SCHOLIA_PREPARE_DEEP_PAGE') {
        if (this.siteDisabled()) {
          sendResponse?.({ ok: false, error: this.siteDisabledMessage() });
          return;
        }
        prepareDeepPageCapture().then((value) => {
          sendResponse?.({ ok: true, value });
        }).catch((error) => {
          sendResponse?.({ ok: false, error: error?.message || 'Scholia could not load the complete page.' });
        });
        return true;
      } else if (message?.type === 'SCHOLIA_SCROLL_DEEP_PAGE') {
        scrollDeepPageCapture(message.position, { sessionId: String(message.sessionId || '') }).then((value) => {
          sendResponse?.({ ok: true, value });
        }).catch((error) => {
          sendResponse?.({ ok: false, error: error?.message || 'Scholia could not continue the complete-page capture.' });
        });
        return true;
      } else if (message?.type === 'SCHOLIA_FINISH_DEEP_PAGE') {
        resolvedPageMetadata().then((metadata) => {
          const restored = finishDeepPageCapture({ sessionId: String(message.sessionId || '') });
          sendResponse?.({ ok: true, value: { metadata, ...restored } });
        }).catch((error) => {
          finishDeepPageCapture({ sessionId: String(message.sessionId || '') });
          sendResponse?.({ ok: false, error: error?.message || 'Scholia could not finish reading the complete page.' });
        });
        return true;
      } else if (message?.type === 'SCHOLIA_GET_SITE_CONTEXT') {
        if (this.siteDisabled()) {
          sendResponse?.({ ok: false, error: this.siteDisabledMessage() });
          return;
        }
        this.getSiteContext({
          question: String(message.question || ''),
          selection: String(message.selection || ''),
          includeContext: message.includeContext,
          maxChars: message.maxChars
        }).then((value) => {
          sendResponse?.({ ok: true, value });
        }).catch((error) => {
          sendResponse?.({ ok: false, error: error?.message || 'Scholia could not read this site.' });
        });
        return true;
      }
      return undefined;
    });

    chrome.storage.onChanged.addListener((_changes, area) => {
      if (area === 'local') this.refreshSettings();
    });
  }

  async getSiteContext({ question = '', selection = '', includeContext = null, maxChars = null } = {}) {
    const currentUrl = new URL(location.href);
    if (!['http:', 'https:'].includes(currentUrl.protocol)) {
      throw new Error('Entire-site context is available only on ordinary HTTP and HTTPS sites.');
    }
    const metadata = await resolvedPageMetadata();
    if (isCanvasCoursePage(currentUrl.href, document)) {
      return { ...metadata, canvasCourse: canvasCourseFromUrl(currentUrl.href) };
    }
    const cacheKey = currentUrl.origin;
    let cached = this.siteContextCache.get(cacheKey);
    if (!cached || Date.now() - cached.createdAt > 10 * 60_000) {
      const crawl = await crawlSite({
        startUrl: currentUrl.href,
        initialPage: {
          url: currentUrl.href,
          title: metadata.pageTitle,
          text: metadata.context,
          links: siteLinksFromDocument(document, currentUrl.href)
        }
      });
      if (!crawl.pages.length) throw new Error('No readable pages were found on this site.');
      cached = { createdAt: Date.now(), crawl };
      this.siteContextCache.set(cacheKey, cached);
    }

    const { crawl } = cached;
    const shouldIncludeContext = typeof includeContext === 'boolean'
      ? includeContext
      : true;
    const context = shouldIncludeContext
      ? packSiteContext(crawl.pages, {
        question,
        selection,
        ...(maxChars != null && Number.isFinite(Number(maxChars)) ? { maxChars: Number(maxChars) } : {}),
        discoveredPages: crawl.discoveredPages,
        truncated: crawl.truncated
      })
      : '';
    return {
      ...metadata,
      sourceKind: 'site',
      context,
      outline: '',
      rawContextCharacters: crawl.totalCharacters,
      packedContextCharacters: context.length,
      sitePageCount: crawl.pages.length,
      siteDiscoveredPages: crawl.discoveredPages,
      siteFailedPages: crawl.failedPages,
      siteTruncated: crawl.truncated,
      contextNotice: `Site-wide context from ${currentUrl.hostname}`
    };
  }

  async refreshSettings() {
    try {
      const [publicSettings, stored] = await Promise.all([
        extensionMessage({ type: 'SCHOLIA_GET_PUBLIC_SETTINGS' }),
        chrome.storage.local.get(PDF_LEARNING_MODE_KEY)
      ]);
      this.settings = publicSettings;
      this.learningModeEnabled = document.documentElement.dataset.scholiaPdfViewer === 'true'
        && stored[PDF_LEARNING_MODE_KEY] === true;
      const allowlistMode = this.settings.siteAccessMode === 'allowlist';
      for (const button of this.els.disableSiteButtons) {
        const label = allowlistMode ? 'Remove this site from the whitelist' : 'Disable Scholia on this site';
        button.title = label;
        button.setAttribute('aria-label', label);
      }
      this.populateModels();
      if (this.siteDisabled()) {
        this.hidePill(false);
        if (!this.els.backdrop.hidden) this.closeModal();
      }
    } catch (error) {
      this.toast(error.message);
    }
  }

  siteDisabled() {
    if (!this.settings) return true;
    return !siteIsEnabled(this.settings, currentSiteKey());
  }

  siteDisabledMessage() {
    return this.settings?.siteAccessMode === 'allowlist'
      ? 'This site is not whitelisted. Add it from the extension panel.'
      : 'Scholia is disabled on this site. Re-enable it from the extension panel.';
  }

  liveSelection() {
    let shadowSelection = null;
    try { shadowSelection = this.shadow.getSelection?.() || null; } catch {}
    if (shadowSelection && !shadowSelection.isCollapsed && shadowSelection.rangeCount) return shadowSelection;
    return window.getSelection();
  }

  clearLiveSelection() {
    const selections = new Set();
    try { selections.add(window.getSelection()); } catch {}
    try { selections.add(this.shadow.getSelection?.()); } catch {}
    for (const selection of selections) {
      try { selection?.removeAllRanges(); } catch {}
    }
  }

  populateModels() {
    populateModelSelect(this.els.model, this.settings);
    this.updateModelControls();
  }

  async saveSelectedModel() {
    const [provider, ...modelParts] = this.els.model.value.split('::');
    const model = modelParts.join('::');
    try {
      const reasoning = this.els.effort.hidden ? undefined : this.els.effort.value;
      this.settings = await extensionMessage({
        type: 'SCHOLIA_SAVE_MODEL', provider, model,
        reasoningEffort: reasoning,
        fastMode: this.settings?.fastMode
      });
      this.populateModels();
    } catch (error) { this.toast(error.message); }
  }

  updateModelControls() {
    const { provider: providerId, model } = this.selectedProviderModel();
    const provider = providerById(providerId);
    const reasoning = modelReasoning(provider, model, this.settings);
    this.els.effort.hidden = !reasoning;
    if (reasoning) {
      const current = this.settings?.reasoningEfforts?.[provider.id];
      const selected = reasoning.efforts.includes(current) ? current : reasoning.default;
      this.els.effort.textContent = '';
      for (const effort of reasoning.efforts) {
        const option = createHtmlElement('option');
        option.value = effort;
        option.textContent = effort;
        option.selected = effort === selected;
        this.els.effort.append(option);
      }
      this.els.effort.title = `Reasoning effort: ${selected}`;
    }
    this.els.fast.hidden = !providerSupportsFastMode(provider);
    this.els.fast.title = `Fast mode for ${provider.name} (uses more credits)`;
    this.els.fast.classList.toggle('is-active', Boolean(this.settings?.fastMode));
    this.els.fast.setAttribute('aria-pressed', String(Boolean(this.settings?.fastMode)));
    this.updateWebSearchControls();
    this.els.bridge.hidden = !provider.localBridge;
    this.els.bridgeBar.hidden = true;
    if (provider.localBridge) this.refreshBridgeStatus(!this.els.backdrop.hidden);
    else {
      this.bridgeStatus = null;
      clearTimeout(this.bridgeWatchTimer);
      this.bridgeStatusRequest += 1;
    }
  }

  updateWebSearchControls() {
    const provider = providerById(this.selectedProviderModel().provider);
    const available = providerSupportsWebSearch(provider);
    if (!available) {
      this.webSearchEnabled = false;
      this.els.webSearchToggle.checked = false;
    }
    this.els.webSearchOption.hidden = !available;
    this.els.webSearchAction.hidden = !available;
    this.els.webSearchAction.classList.toggle('is-active', available && this.webSearchEnabled);
    this.els.webSearchAction.setAttribute('aria-pressed', String(available && this.webSearchEnabled));
    this.els.webSearchAction.title = available
      ? `${this.webSearchEnabled ? 'Disable' : 'Enable'} web search for the next question with ${provider.name}`
      : `Web search is unavailable through ${provider.name}`;
  }

  async refreshBridgeStatus(includeUsage = false) {
    clearTimeout(this.bridgeWatchTimer);
    const request = ++this.bridgeStatusRequest;
    const { provider } = this.selectedProviderModel();
    const definition = providerById(provider);
    if (!definition.localBridge) return;
    if (this.bridgeStatus?.provider !== provider) {
      this.bridgeStatus = { provider, up: null, label: definition.localBridge.label };
    }
    this.paintBridgeStatus(this.bridgeStatus);
    try {
      const status = await extensionMessage({ type: 'SCHOLIA_BRIDGE_STATUS', provider, includeUsage });
      if (request !== this.bridgeStatusRequest || this.selectedProviderModel().provider !== provider) return;
      this.bridgeStatus = status;
      this.paintBridgeStatus(status);
    } catch (error) {
      if (request !== this.bridgeStatusRequest) return;
      this.bridgeStatus = { ...this.bridgeStatus, up: false, label: definition.localBridge.label, error: error.message };
      this.paintBridgeStatus(this.bridgeStatus);
    }
    if (!this.els.backdrop.hidden) {
      this.bridgeWatchTimer = setTimeout(() => this.refreshBridgeStatus(), this.bridgeStatus.up ? 10_000 : 1_500);
    }
  }

  paintBridgeStatus(status) {
    const dot = this.els.bridge.querySelector('.scholia-status-dot');
    dot.className = `scholia-status-dot ${status.up == null ? 'is-checking' : status.up ? 'is-up' : 'is-down'}`;
    let label = status.up == null ? 'checking' : status.up ? 'running' : 'start';
    const remaining = formatUsageRemaining(status.usage);
    if (status.up && remaining) label = remaining;
    this.els.bridgeLabel.textContent = label;
    this.els.bridge.title = status.up ? `${status.label} is running` : `Start ${status.label || 'local bridge'}`;
    const showBar = !this.els.backdrop.hidden && status.up === false;
    this.els.bridgeBar.hidden = !showBar;
    this.els.bridgeBarText.textContent = `${status.label || 'Local bridge'} is not running.`;
  }

  startBridge() {
    const status = this.bridgeStatus;
    if (!status?.startUrl) { this.refreshBridgeStatus(true); return; }
    const decision = bridgeLaunchDecision(this.bridgeLaunchState, status.startUrl);
    this.bridgeLaunchState = decision.state;
    if (!decision.allowed) {
      const seconds = Math.max(1, Math.ceil(decision.retryAfterMs / 1_000));
      this.toast(`Bridge launch already requested. Wait ${seconds}s or copy the start command.`);
      this.refreshBridgeStatus(true);
      return;
    }
    const frame = createHtmlElement('iframe');
    frame.hidden = true;
    frame.src = status.startUrl;
    document.documentElement.append(frame);
    setTimeout(() => frame.remove(), 1_500);
    this.refreshBridgeStatus(true);
  }

  async copyBridgeCommand() {
    const command = this.bridgeStatus?.command;
    if (!command) return;
    try {
      await copyText(command, { root: this.shadow });
      this.toast(`Copied: ${command}`);
    } catch { this.toast(command, 6_000); }
  }

  async disableCurrentSite() {
    try {
      await extensionMessage({ type: 'SCHOLIA_SET_SITE_ENABLED', enabled: false });
      this.hidePill(false);
      this.closeModal();
      const message = this.settings?.siteAccessMode === 'allowlist'
        ? `${currentSiteKey()} was removed from the whitelist.`
        : `Scholia disabled on ${currentSiteKey()}. Re-enable it from the extension panel.`;
      this.toast(message, 5_000);
    } catch (error) { this.toast(error.message); }
  }

  decorateRecursiveCapture(capture, origin) {
    const bubble = origin?.closest?.('.scholia-message--assistant .scholia-bubble');
    if (!bubble || this.els.backdrop.hidden || !this.layers.length) return capture;
    const messageIndex = Number(bubble.closest('.scholia-message')?.dataset.messageIndex);
    const response = Number.isInteger(messageIndex) ? this.messages[messageIndex]?.content : bubble.innerText;
    const pageCapture = this.layers.at(-1)?.capture || this.capture;
    return {
      ...capture,
      context: pageCapture?.context || capture.context,
      outline: pageCapture?.outline || capture.outline,
      pageTitle: pageCapture?.pageTitle || capture.pageTitle,
      pageLanguage: pageCapture?.pageLanguage || capture.pageLanguage,
      url: pageCapture?.url || capture.url,
      packedContext: pageCapture?.packedContext,
      pdfLocalContext: pageCapture?.pdfLocalContext,
      sourceKind: pageCapture?.sourceKind || capture.sourceKind,
      parentContext: packParentContext({
        ancestorContext: pageCapture?.parentContext,
        messages: Number.isInteger(messageIndex)
          ? this.messages.filter((_message, index) => index !== messageIndex)
          : this.messages,
        response: response || '',
        selection: capture.selection
      }),
      useChatGptWebContext: pageCapture?.useChatGptWebContext
        ?? Boolean(this.settings?.chatgptWebContext?.enabled),
      recursive: true
    };
  }

  inspectSelection() {
    const pdfChatRoot = document.getElementById('pdf-chat-content')?.shadowRoot;
    const chatSelection = pdfChatRoot?.getSelection?.();
    if (pdfChatRoot?.contains(chatSelection?.anchorNode)) return;
    if (!this.settings || this.siteDisabled() || this.popoverInteracting || this.editingMessageIndex >= 0) return;
    const live = this.liveSelection();
    const selectedNode = live?.anchorNode?.nodeType === Node.ELEMENT_NODE ? live.anchorNode : live?.anchorNode?.parentElement;
    const selectedInsideResponse = Boolean(selectedNode
      && this.shadow.contains(selectedNode)
      && selectedNode.closest?.('.scholia-message--assistant .scholia-bubble'));
    if (selectedNode && this.shadow.contains(selectedNode) && !selectedInsideResponse) return;
    const selected = currentSelectionCapture('', live);
    if (!selected) {
      if (!selectedNode || !this.shadow.contains(selectedNode)) this.lastPublishedSelection = '';
      if (!this.els.backdrop.hidden) { this.hidePill(true); return; }
      if (!this.mathState && !this.multiSelection.length && !this.els.pill.contains(this.shadow.activeElement)) this.hidePill(false);
      return;
    }
    if (!selectedInsideResponse) this.publishPageSelection(selected);
    if (!this.settings.explainOnSelection) return;
    this.mathState = null;
    this.multiSelection = [];
    this.multiAddMode = false;
    this.singleMathPick = null;
    this.pendingCapture = this.decorateRecursiveCapture(selected, selectedNode);
    this.paintRangeHighlight(this.pendingCapture.range);
    this.showPill(this.pendingCapture.rect);
  }

  publishPageSelection(capture) {
    const selection = String(capture?.selection || '').trim();
    const signature = `${capture?.kind || 'text'}:${capture?.mailSubject || ''}:${capture?.mailMessageCount || 0}:${selection}`;
    if (!selection || signature === this.lastPublishedSelection) return;
    this.lastPublishedSelection = signature;
    extensionMessage({
      type: 'SCHOLIA_PAGE_SELECTION_CHANGED',
      selection,
      kind: capture?.kind || 'text',
      mailContext: capture?.kind === 'mail' ? String(capture.mailContext || '') : '',
      mailSubject: capture?.kind === 'mail' ? String(capture.mailSubject || '') : '',
      mailMessageCount: capture?.kind === 'mail' ? Number(capture.mailMessageCount) || 0 : 0,
      defaultQuestion: capture?.kind === 'mail' ? String(capture.defaultQuestion || '') : ''
    }).catch(() => {});
  }

  showPill(rect) {
    const pill = this.els.pill;
    const capture = this.pendingCapture;
    if (!capture) return;
    this.els.pillKind.textContent = capture.kind === 'mail'
      ? 'Email'
      : capture.kind === 'latex' ? 'Math' : capture.kind === 'image' ? 'Image' : 'Text';
    this.els.pillPreview.textContent = collapseWhitespace(capture.preview || capture.selection).slice(0, 220);
    this.els.pillQuestion.placeholder = capture.kind === 'mail'
      ? 'Optional: tone, length, or key point…'
      : 'Ask about this…';
    this.els.pillSend.textContent = capture.kind === 'mail' ? 'Draft reply' : 'Explain';
    const webSearchAvailable = providerSupportsWebSearch(this.selectedProviderModel().provider);
    this.els.webSearchOption.hidden = !webSearchAvailable;
    this.els.webSearchToggle.checked = webSearchAvailable && Boolean(
      capture.webSearch ?? this.webSearchEnabled
    );
    const imported = this.settings?.chatgptWebContext;
    this.els.chatGptContext.hidden = !capture.recursive || !imported?.available;
    this.els.chatGptContextToggle.checked = Boolean(
      capture.useChatGptWebContext ?? imported?.enabled
    );
    this.els.chatGptContextLabel.textContent = imported?.projectName
      ? `Include ChatGPT memory · ${imported.projectName}`
      : 'Include imported ChatGPT memory/project context';
    this.els.mathTools.hidden = !this.mathState?.chain?.length || this.multiSelection.length > 1;
    this.updateAddSymbolButton();

    const wasVisible = pill.classList.contains('is-visible');
    pill.hidden = false;
    const viewportPadding = 8;
    const gap = 8;
    const width = pill.offsetWidth;
    const height = pill.offsetHeight;
    const anchor = rect || { left: window.innerWidth / 2, right: window.innerWidth / 2, top: window.innerHeight / 2, bottom: window.innerHeight / 2, width: 0 };
    const anchorCenter = Math.max(viewportPadding, Math.min(window.innerWidth - viewportPadding, anchor.left + (anchor.width || 0) / 2));
    let left = anchorCenter - width / 2;
    left = Math.max(viewportPadding, Math.min(window.innerWidth - width - viewportPadding, left));

    const spaceAbove = anchor.top - viewportPadding;
    const spaceBelow = window.innerHeight - anchor.bottom - viewportPadding;
    const placeAbove = spaceBelow < height + gap && spaceAbove > spaceBelow;
    let top = placeAbove ? anchor.top - height - gap : anchor.bottom + gap;
    top = Math.max(viewportPadding, Math.min(window.innerHeight - height - viewportPadding, top));

    pill.dataset.placement = placeAbove ? 'above' : 'below';
    pill.style.setProperty('--scholia-pill-pointer-x', `${Math.max(16, Math.min(width - 16, anchorCenter - left))}px`);
    pill.style.left = `${left}px`;
    pill.style.top = `${top}px`;
    if (!wasVisible) requestAnimationFrame(() => pill.classList.add('is-visible'));
  }

  hidePill(keepHighlight = false) {
    this.els.pill.classList.remove('is-visible');
    setTimeout(() => { if (!this.els.pill.classList.contains('is-visible')) this.els.pill.hidden = true; }, 150);
    if (!keepHighlight) {
      this.clearHighlights();
      this.mathState = null;
      this.multiSelection = [];
      this.multiAddMode = false;
      this.singleMathPick = null;
      this.updateAddSymbolButton();
      this.pendingCapture = null;
    }
  }

  markPopoverInteraction() {
    this.popoverInteracting = true;
    clearTimeout(this.popoverInteractionTimer);
    this.popoverInteractionTimer = setTimeout(() => { this.popoverInteracting = false; }, 220);
  }

  clearHighlights() {
    for (const element of this.highlightElements) element.remove();
    this.highlightElements = [];
  }

  paintRects(rects, variant = 'math') {
    this.clearHighlights();
    for (const rect of rects) {
      if (!rect || (!rect.width && !rect.height)) continue;
      const element = createHtmlElement('div');
      element.className = `scholia-highlight scholia-highlight--${variant}`;
      Object.assign(element.style, {
        left: `${rect.left}px`, top: `${rect.top}px`, width: `${rect.width}px`, height: `${rect.height}px`
      });
      this.shadow.append(element);
      this.highlightElements.push(element);
    }
  }

  paintRangeHighlight(range) {
    // Chromium already paints the live selection in blue. A second fixed
    // yellow rectangle layer was visually noisy and could drift a pixel from
    // the native selection while scrolling, so text selections use only the
    // browser highlight. Math-node picks still use the explicit overlay.
    this.clearHighlights();
  }

  paintMathNodes(nodes) {
    this.paintRects(nodes.map((node) => node?.getBoundingClientRect?.()).filter(Boolean));
  }

  updateAddSymbolButton() {
    const visible = Boolean(this.singleMathPick || this.multiSelection.length);
    this.els.addSymbol.hidden = !visible;
    if (!visible) return;
    this.els.addSymbol.classList.toggle('is-active', this.multiAddMode);
    this.els.addSymbol.textContent = this.multiAddMode ? 'Done' : `+ symbol${this.multiSelection.length > 1 ? ` (${this.multiSelection.length})` : ''}`;
  }

  updateMathDepth(change) {
    if (!this.mathState) return;
    const { chain, fullTex, container } = this.mathState;
    const maxDepth = chain.length;
    this.mathState.depth = Math.max(0, Math.min(maxDepth, this.mathState.depth + change));
    const whole = this.mathState.depth === maxDepth;
    const node = whole ? container : chain[this.mathState.depth];
    const fragment = whole ? '' : decodeMathNode(node);
    const description = whole || !fragment ? fullTex : this.describeMathSelection(container, node, fragment, fullTex);
    this.pendingCapture = { ...this.mathState.capture, selection: description, preview: fragment || fullTex, rect: node.getBoundingClientRect() };
    const rect = this.pendingCapture.rect;
    this.singleMathPick = whole ? null : { container, node, decoded: fragment };
    this.multiSelection = [];
    this.paintMathNodes([node]);
    this.shadow.querySelector('[data-narrow]').disabled = this.mathState.depth <= 0;
    this.shadow.querySelector('[data-wider]').disabled = this.mathState.depth >= maxDepth;
    this.showPill(rect);
  }

  describeMathSelection(container, node, decoded, fullTex) {
    const structural = {
      msup: ['the base of the power', 'the exponent'],
      msub: ['the base', 'the subscript'],
      msubsup: ['the base', 'the subscript', 'the exponent'],
      mfrac: ['the numerator', 'the denominator'],
      mroot: ['the radicand', 'the root index'],
      munder: ['', 'the lower limit'],
      mover: ['', 'the upper mark'],
      munderover: ['', 'the lower limit', 'the upper limit']
    };
    let role = '';
    let current = node;
    while (current && current !== container) {
      const parent = current.parentElement?.closest?.('g[data-mml-node]');
      if (!parent || !container.contains(parent)) break;
      const type = parent.getAttribute('data-mml-node');
      if (structural[type]) {
        const index = directMathChildren(parent).indexOf(current);
        role = structural[type][index] || '';
        break;
      }
      current = parent;
    }
    const matches = leafMathNodes(container).filter((candidate) => decodeMathNode(candidate) === decoded);
    const ordinal = matches.length > 1 ? matches.indexOf(node) + 1 : 0;
    const suffix = ordinal > 0 ? (ordinal % 10 === 1 && ordinal % 100 !== 11 ? 'st' : ordinal % 10 === 2 && ordinal % 100 !== 12 ? 'nd' : ordinal % 10 === 3 && ordinal % 100 !== 13 ? 'rd' : 'th') : '';
    const identity = ordinal > 0 ? `the ${ordinal}${suffix} "${decoded}"` : `the part "${decoded}"`;
    return `${identity}${role ? ` (${role})` : ''} within the full expression ${fullTex}`;
  }

  baseMathCapture(selection, preview, rect, origin) {
    const capture = { kind: 'latex', selection, preview, rect };
    return this.decorateRecursiveCapture(capture, origin);
  }

  selectWholeMath(container) {
    const fullTex = wrappedMath(container);
    if (!fullTex) return false;
    const rect = container.getBoundingClientRect();
    this.mathState = { container, chain: [], depth: 0, fullTex, capture: this.baseMathCapture(fullTex, fullTex, rect, container) };
    this.multiSelection = [];
    this.multiAddMode = false;
    this.singleMathPick = null;
    this.pendingCapture = this.mathState.capture;
    this.paintMathNodes([container]);
    this.showPill(rect);
    return true;
  }

  selectExactMath(container, node, chain = mathChain(container, node)) {
    const fullTex = wrappedMath(container);
    if (!fullTex || !node || !chain.length) return false;
    this.mathState = {
      container, chain, depth: 0, fullTex,
      capture: this.baseMathCapture(fullTex, fullTex, node.getBoundingClientRect(), container)
    };
    this.updateMathDepth(0);
    return true;
  }

  handleMathClick(event) {
    if (event.target?.closest?.('#pdf-chat-content')) return;
    if (this.siteDisabled()) return;
    if (this.justLongPressed) {
      this.justLongPressed = false;
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    const container = mathContainer(event.target);
    if (!container || event.target?.closest?.('.scholia-math-source')) return;
    if ((event.altKey && event.shiftKey) || this.multiAddMode) {
      const chain = chainAtPoint(container, event.target, event.clientX, event.clientY);
      if (!chain.length) return;
      event.preventDefault();
      event.stopPropagation();
      this.clearLiveSelection();
      this.toggleMultiSymbol(container, chain[0]);
      return;
    }
    const selection = this.liveSelection();
    if (selection && !selection.isCollapsed) return;
    if (event.altKey) {
      const chain = chainAtPoint(container, event.target, event.clientX, event.clientY);
      if (chain.length) {
        event.preventDefault();
        event.stopPropagation();
        this.selectExactMath(container, chain[0], chain);
        return;
      }
    }
    this.selectWholeMath(container);
  }

  toggleMultiSymbol(container, node) {
    if (!this.multiSelection.length && this.singleMathPick?.node?.isConnected) {
      this.multiSelection.push(this.singleMathPick);
    }
    const index = this.multiSelection.findIndex((entry) => entry.node === node);
    if (index >= 0) this.multiSelection.splice(index, 1);
    else this.multiSelection.push({ container, node, decoded: decodeMathNode(node) || '(symbol)' });
    this.multiSelection = this.multiSelection.filter((entry) => entry.node?.isConnected);
    if (!this.multiSelection.length) { this.hidePill(false); return; }
    if (this.multiSelection.length === 1) {
      const only = this.multiSelection[0];
      this.selectExactMath(only.container, only.node, mathChain(only.container, only.node));
      this.multiAddMode = true;
      this.updateAddSymbolButton();
      return;
    }
    this.applyMultiSelection();
  }

  applyMultiSelection() {
    const groups = [];
    for (const entry of this.multiSelection) {
      let group = groups.find((candidate) => candidate.container === entry.container);
      if (!group) { group = { container: entry.container, entries: [] }; groups.push(group); }
      group.entries.push(entry);
    }
    const descriptions = groups.map((group) => {
      const symbols = group.entries.map((entry) => `"${entry.decoded}"`).join(', ');
      const full = wrappedMath(group.container);
      return full ? `${symbols} (in ${full})` : symbols;
    });
    const selection = `the symbols ${descriptions.join(' and ')}`;
    const preview = this.multiSelection.map((entry) => entry.decoded).join(', ');
    const last = this.multiSelection.at(-1).node;
    const rect = last.getBoundingClientRect();
    this.mathState = null;
    this.singleMathPick = null;
    this.pendingCapture = this.baseMathCapture(selection, preview, rect, last);
    this.paintMathNodes(this.multiSelection.map((entry) => entry.node));
    this.showPill(rect);
  }

  bindMathTouch() {
    let start = null;
    const cancel = () => {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = null;
      start = null;
    };
    document.addEventListener('touchstart', (event) => {
      cancel();
      this.justLongPressed = false;
      if (this.siteDisabled() || event.touches?.length !== 1) return;
      const touch = event.touches[0];
      const container = mathContainer(touch.target);
      if (!container) return;
      start = { x: touch.clientX, y: touch.clientY, target: touch.target, container };
      this.longPressTimer = setTimeout(() => {
        this.longPressTimer = null;
        if (!start) return;
        const hit = document.elementFromPoint(start.x, start.y) || start.target;
        const activeContainer = mathContainer(hit) || start.container;
        const chain = chainAtPoint(activeContainer, hit, start.x, start.y);
        this.justLongPressed = true;
        setTimeout(() => { this.justLongPressed = false; }, 800);
        if (this.multiAddMode && chain.length) this.toggleMultiSymbol(activeContainer, chain[0]);
        else if (chain.length) this.selectExactMath(activeContainer, chain[0], chain);
        else this.selectWholeMath(activeContainer);
      }, 480);
    }, { passive: true, capture: true });
    document.addEventListener('touchmove', (event) => {
      if (!start || !this.longPressTimer) return;
      const touch = event.touches?.[0];
      if (!touch || Math.abs(touch.clientX - start.x) > 10 || Math.abs(touch.clientY - start.y) > 10) cancel();
    }, { passive: true, capture: true });
    document.addEventListener('touchend', cancel, { passive: true, capture: true });
    document.addEventListener('touchcancel', cancel, { passive: true, capture: true });
  }

  async explainPill() {
    if (!this.pendingCapture) return;
    const capture = {
      ...this.pendingCapture,
      webSearch: !this.els.webSearchOption.hidden && this.els.webSearchToggle.checked,
      useChatGptWebContext: !this.els.chatGptContext.hidden
        && this.els.chatGptContextToggle.checked
    };
    const question = this.els.pillQuestion.value.trim();
    this.els.pillQuestion.value = '';
    const previousLabel = this.els.pillSend.textContent;
    this.els.pillSend.disabled = true;
    this.els.pillSend.textContent = capture.kind === 'mail'
      ? 'Reading thread…'
      : document.documentElement.dataset.scholiaPdfViewer === 'true' ? 'Reading PDF…' : 'Opening…';
    try {
      await this.openAndAsk(capture, question);
    } catch (error) {
      this.toast(error?.message || 'Scholia could not read this document.');
    } finally {
      this.els.pillSend.disabled = false;
      this.els.pillSend.textContent = previousLabel;
    }
  }

  async openAndAsk(capture, question) {
    const recursive = capture.recursive === true && !this.els.backdrop.hidden && this.layers.length > 0;
    if (!recursive && capture.context === undefined) {
      capture = capture.kind === 'mail' && capture.mailContext
        ? {
          pageTitle: capture.mailSubject || document.title,
          pageLanguage: await detectDocumentLanguage({
            context: capture.mailContext,
            selection: capture.selection,
            fallback: document.documentElement.lang || navigator.language
          }),
          url: sourceUrl(),
          imageDataUrl: '',
          ...capture
        }
        : { ...await resolvedPageMetadata({
          ...capture, forSelection: true, fullContext: this.settings?.includePageContext === false
        }), ...capture };
    }
    if (!recursive && capture.kind === 'mail' && capture.mailContext) {
      capture = {
        ...capture,
        context: capture.mailContext,
        outline: '',
        htmlContextCharacters: 0,
        renderedContextCharacters: String(capture.mailContext).length
      };
    }
    if (recursive && this.streaming) this.cancelRequest();
    if (this.layers.length) {
      const currentLayer = this.layers.at(-1);
      currentLayer.scrollTop = this.els.messages.scrollTop;
      if (recursive) {
        currentLayer.files = this.fileComposer.files;
        currentLayer.panel = this.snapshotActivePanel();
        currentLayer.webSearchEnabled = this.webSearchEnabled;
      }
    }
    this.hidePill(!recursive);
    this.pendingCapture = null;
    if (!recursive) this.layers = [];
    this.webSearchEnabled = Boolean(capture.webSearch && providerSupportsWebSearch(this.selectedProviderModel().provider));
    const layer = { capture, messages: [], scrollTop: 0, webSearchEnabled: this.webSearchEnabled };
    this.fileComposer.set();
    this.layers.push(layer);
    this.capture = capture;
    this.messages = layer.messages;
    this.editingMessageIndex = -1;
    this.renderSource();
    this.renderMessages();
    this.renderLayerStack();
    this.els.composer.placeholder = capture.kind === 'mail'
      ? 'Refine the reply or ask for another tone…'
      : capture.kind === 'image' ? 'Ask about the captured region…' : 'Ask a follow-up…';
    this.els.backdrop.hidden = false;
    this.updateModelControls();
    this.clearLiveSelection();
    await this.prepareQuickChatContext(capture);
    if (this.capture !== capture || this.els.backdrop.hidden) return;
    this.ask(question || capture.defaultQuestion || (capture.kind === 'image' ? DEFAULT_IMAGE_EXPLANATION : 'Explain this.'));
  }

  async prepareQuickChatContext(capture) {
    if (document.documentElement.dataset.scholiaPdfViewer === 'true') {
      capture.useChatGptWebContext = false;
      return;
    }
    const imported = this.settings?.chatgptWebContext;
    if (!imported || imported.quickChatRefreshInterval === 'off') return;
    const cachedAvailable = Boolean(imported.available);
    capture.useChatGptWebContext = cachedAvailable;
    this.refreshingChatGptContext = true;
    this.renderSource();
    extensionMessage({
      type: 'SCHOLIA_REFRESH_CHATGPT_CONTEXT_FOR_QUICK_CHAT'
    }).then((result) => {
      if (result?.context) {
        this.settings.chatgptWebContext = result.context;
      }
      if (result?.refreshed) {
        this.toast(`ChatGPT context refreshed · ${Number(result.memoryCharacters || 0).toLocaleString()} characters`);
      }
    }).catch((error) => {
      this.toast(cachedAvailable
        ? `ChatGPT refresh failed; using the saved snapshot. ${error.message}`
        : `ChatGPT context was unavailable. ${error.message}`, 6_000);
    }).finally(() => {
      this.refreshingChatGptContext = false;
      this.renderSource();
    });
  }

  renderSource() {
    const capture = this.capture;
    if (!capture) { this.els.source.hidden = true; return; }
    this.els.source.hidden = false;
    this.els.sourceLabel.textContent = capture.imageOrigin === 'pasted'
      ? 'Pasted image'
      : capture.imageOrigin === 'selected'
        ? 'Selected image'
        : capture.recursive
          ? capture.kind === 'latex' ? 'Mathematics selected from an explanation' : 'Selected from an explanation'
          : capture.kind === 'mail'
            ? 'Selected email + thread'
            : capture.kind === 'image' ? 'Captured region' : capture.kind === 'latex' ? 'Selected mathematics' : 'Selected text';
    this.els.sourceText.textContent = capture.kind === 'image' ? (capture.pageTitle || 'Visible page region') : capture.selection;
    const pageContextAttached = Boolean(String(capture.context || capture.packedContext || '').trim());
    const chatGptContextAttached = Boolean(capture.useChatGptWebContext);
    const contextLabel = this.refreshingChatGptContext
      ? 'Refreshing ChatGPT context…'
      : capture.kind === 'mail' && chatGptContextAttached
        ? `Mail thread (${Number(capture.mailMessageCount) || 1}) + ChatGPT context`
        : capture.kind === 'mail'
          ? `Mail thread attached · ${Number(capture.mailMessageCount) || 1} message${Number(capture.mailMessageCount) === 1 ? '' : 's'}`
      : pageContextAttached && chatGptContextAttached
        ? 'Page + ChatGPT context'
        : pageContextAttached
          ? capture.pdfLocalContext ? 'Nearby PDF pages attached' : 'Page context attached'
          : chatGptContextAttached ? 'ChatGPT context attached' : 'Selection only';
    const showLanguage = capture.imageOrigin !== 'pasted' && capture.imageOrigin !== 'selected';
    const language = showLanguage ? documentLanguageLabel(capture.pageLanguage) : '';
    this.els.sourceContext.textContent = [language ? `Language: ${language}` : '', contextLabel, capture.ocrNotice]
      .filter(Boolean).join(' · ');
    this.els.sourceContext.classList.toggle('is-attached', pageContextAttached || chatGptContextAttached);
    this.els.sourceImage.hidden = !capture.imageDataUrl;
    if (capture.imageDataUrl) this.els.sourceImage.src = capture.imageDataUrl;
    else this.els.sourceImage.removeAttribute('src');
  }

  renderLayerStack() {
    this.els.layerStack.textContent = '';
    const behind = this.layers.slice(0, -1).slice(-4);
    behind.forEach((layer, index) => {
      const depth = behind.length - index;
      const panel = layer.panel;
      if (!panel) return;
      panel.style.setProperty('--scholia-layer-offset', `${depth * -12}px`);
      panel.style.setProperty('--scholia-layer-scale', String(1 - depth * 0.012));
      panel.style.setProperty('--scholia-layer-opacity', String(1 - depth * 0.08));
      panel.style.zIndex = String(index + 1);
      this.els.layerStack.append(panel);
      const messages = panel.querySelector('.scholia-messages');
      if (messages) messages.scrollTop = layer.scrollTop;
    });
    const layered = this.layers.length > 1;
    this.els.close.textContent = layered ? '←' : '×';
    this.els.close.title = layered ? 'Back to previous explanation' : 'Close';
    this.els.close.setAttribute('aria-label', this.els.close.title);
  }

  snapshotActivePanel() {
    const panel = this.els.modal.cloneNode(true);
    panel.classList.add('scholia-modal--layer');
    panel.removeAttribute('data-modal');
    panel.removeAttribute('role');
    panel.removeAttribute('aria-modal');
    panel.setAttribute('aria-hidden', 'true');
    panel.setAttribute('inert', '');
    return panel;
  }

  async moveToChat() {
    const layer = this.layers.at(-1);
    if (!layer || this.els.moveChat.disabled) return;
    layer.moving = true;
    layer.chatId ||= crypto.randomUUID();
    this.renderMessages();
    try {
      const moved = await extensionMessage({
        type: 'SCHOLIA_MOVE_EXPLANATION_TO_CHAT',
        explanation: {
          id: layer.chatId,
          ...this.selectedProviderModel(),
          capture: {
            ...this.capture,
            context: this.capture.packedContext || this.capture.context || '',
            contextEnabled: true,
            compactContextEnabled: this.settings?.includePageContext !== false,
            webSearch: this.webSearchEnabled
          },
          messages: this.messages,
          draft: this.els.composer.value
        }
      });
      if (moved?.surface === 'pdf-sidebar') {
        document.dispatchEvent(new CustomEvent('scholia:open-pdf-chat', {
          detail: { chatId: moved.chatId }
        }));
      }
      if (this.layers.at(-1) === layer) this.closeTopLayer();
    } catch (error) {
      this.toast(error.message || 'The explanation could not be moved to chat.');
    } finally {
      layer.moving = false;
      if (this.layers.at(-1) === layer) this.renderMessages();
    }
  }

  closeTopLayer() {
    if (this.layers.length <= 1) {
      this.closeModal();
      return;
    }
    if (this.streaming) this.cancelRequest();
    this.hidePill(false);
    this.fileComposer.set();
    this.layers.pop();
    const layer = this.layers.at(-1);
    this.fileComposer.set(layer.files || []);
    this.capture = layer.capture;
    this.messages = layer.messages;
    this.webSearchEnabled = Boolean(layer.webSearchEnabled);
    this.editingMessageIndex = -1;
    this.els.composer.value = '';
    this.renderSource();
    this.renderMessages();
    this.els.messages.scrollTop = layer.scrollTop;
    this.renderLayerStack();
    this.updateModelControls();
    this.clearLiveSelection();
    this.els.close.focus();
  }

  closeModal() {
    if (this.streaming) this.cancelRequest();
    this.hidePill(false);
    this.layers = [];
    this.fileComposer?.set();
    this.capture = null;
    this.messages = [];
    this.webSearchEnabled = false;
    this.editingMessageIndex = -1;
    this.els.backdrop.hidden = true;
    this.renderLayerStack();
    this.els.bridgeBar.hidden = true;
    clearTimeout(this.bridgeWatchTimer);
    this.bridgeStatusRequest += 1;
  }

  openImagePicker(question = '') {
    this.imageQuestionDraft = String(question || '');
    this.els.imageFile.click();
  }

  handleImagePaste(event) {
    const file = clipboardImageFile(event.clipboardData);
    if (!file) return;
    event.preventDefault();
    this.useImageFile(file, { question: event.currentTarget?.value || '', pasted: true })
      .catch((error) => this.toast(error.message || 'Could not read that image.'));
  }

  async useImageFile(file, { question = '', pasted = false } = {}) {
    if (!file) return;
    const imageDataUrl = await normalizeImageFile(file);
    const metadata = await resolvedPageMetadata();
    const label = pasted ? 'Pasted image' : String(file.name || 'Selected image');
    const nextCapture = {
      kind: 'image',
      imageOrigin: pasted ? 'pasted' : 'selected',
      selection: '',
      preview: label,
      pageTitle: label,
      pageLanguage: metadata.pageLanguage || navigator.language,
      url: '',
      context: '',
      outline: [],
      imageDataUrl
    };
    this.showImageDraft(nextCapture, question);
  }

  showImageDraft(nextCapture, question = '') {
    if (this.streaming) this.cancelRequest();
    this.editingMessageIndex = -1;
    const replaceCurrent = !this.els.backdrop.hidden && this.layers.length > 0;
    this.hidePill(false);
    if (replaceCurrent) {
      this.messages.splice(0);
      const layer = this.layers.at(-1);
      layer.capture = nextCapture;
      layer.messages = this.messages;
    } else {
      this.layers = [];
      this.messages = [];
      this.layers.push({ capture: nextCapture, messages: this.messages, scrollTop: 0 });
    }
    this.capture = nextCapture;
    this.renderSource();
    this.renderMessages();
    this.renderLayerStack();
    this.els.composer.value = String(question || '');
    this.els.composer.placeholder = 'Ask about this image…';
    this.resizeComposer();
    this.els.backdrop.hidden = false;
    this.updateModelControls();
    this.clearLiveSelection();
    this.els.composer.focus();
    this.renderComposerSubmitAction();
    this.toast('Image ready. Add a question, or explain it as-is.');
  }

  sendComposer() {
    const question = this.els.composer.value.trim()
      || (this.fileComposer.files.length ? 'Explain the attached files.' : this.canExplainCaptureDirectly() ? DEFAULT_IMAGE_EXPLANATION : '');
    if (!question || this.fileComposer.busy || this.streaming || this.layers.at(-1)?.moving) return;
    this.els.composer.value = '';
    this.resizeComposer();
    this.ask(question);
  }

  canExplainCaptureDirectly() {
    return canExplainImageDirectly({
      kind: this.capture?.kind,
      imageDataUrl: this.capture?.imageDataUrl,
      question: this.els.composer.value,
      messageCount: this.messages.length,
      hasAttachments: Boolean(this.fileComposer?.files.length)
    });
  }

  renderComposerSubmitAction() {
    const explainDirectly = !this.streaming && this.canExplainCaptureDirectly();
    this.els.explainCapture.hidden = !explainDirectly;
    this.els.send.hidden = explainDirectly;
  }

  beginMessageEdit(index) {
    if (this.streaming || this.layers.at(-1)?.moving || this.messages[index]?.role !== 'user') return;
    this.hidePill(false);
    this.editingMessageIndex = index;
    this.renderMessages();
  }

  cancelMessageEdit() {
    this.editingMessageIndex = -1;
    this.renderMessages();
  }

  resendEditedMessage(index) {
    const editor = this.els.messages.querySelector(`[data-message-editor="${index}"]`);
    const prepared = prepareEditedResend(this.messages, index, editor?.value);
    if (!prepared || this.streaming) {
      editor?.focus();
      return;
    }
    replaceConversationPrefix(this.messages, prepared);
    this.editingMessageIndex = -1;
    this.ask(prepared.question, { files: prepared.files || [], imageDataUrl: prepared.imageDataUrl });
  }

  resizeComposer() {
    const textarea = this.els.composer;
    textarea.style.height = 'auto';
    textarea.style.height = `${Math.min(textarea.scrollHeight, 130)}px`;
  }

  selectedProviderModel() {
    const [provider, ...parts] = this.els.model.value.split('::');
    const providerId = provider || this.settings?.provider;
    return {
      provider: providerId,
      model: parts.join('::') || this.settings?.models?.[providerId],
      reasoningEffort: this.els.effort.hidden ? undefined : this.els.effort.value,
      fastMode: Boolean(this.settings?.fastMode)
    };
  }

  ask(question, options = this.fileComposer.options) {
    if (this.streaming || !this.capture) return;
    if (this.messages.at(-1)?.error) {
      this.messages.pop();
      if (this.messages.at(-1)?.role === 'user') this.messages.pop();
    }
    const user = createUserTurn(question, null, options);
    if (!user) return;
    this.messages.push(user);
    this.fileComposer.set();
    const assistant = { role: 'assistant', content: '', streaming: true, meta: '' };
    this.messages.push(assistant);
    this.streaming = true;
    this.editingMessageIndex = -1;
    this.renderMessages();

    const conversation = requestConversation(this.messages);
    conversation.pop();
    const compactContext = this.settings?.includePageContext !== false;
    const packedContext = selectionContextForQuestion(this.capture, question, {
      includePageContext: true,
      maxChars: contextCharacterLimit(defaultContextMode(this.settings))
    });
    this.capture.packedContext = packedContext;
    const chosen = this.selectedProviderModel();
    const webSearch = this.webSearchEnabled && providerSupportsWebSearch(chosen.provider);
    this.requestId = crypto.randomUUID();
    const requestId = this.requestId;
    const port = chrome.runtime.connect({ name: 'scholia-chat' });
    this.port = port;

    port.onMessage.addListener((message) => {
      if (message.requestId !== requestId) return;
      if (message.type === 'token') {
        assistant.content += message.token || '';
        this.scheduleRender();
      } else if (message.type === 'reasoning') {
        assistant.reasoning = `${assistant.reasoning || ''}${message.token || ''}`;
        this.scheduleRender();
      } else if (message.type === 'done') {
        assistant.streaming = false;
        assistant.reasoning = message.reasoning || '';
        assistant.meta = `${providerById(message.provider).name} · ${message.model}${message.webSearchUsed ? ' · web search' : webSearch ? ' · web enabled' : ''}`;
        this.streaming = false;
        this.renderMessages();
        port.disconnect();
        this.port = null;
      } else if (message.type === 'error') {
        assistant.streaming = false;
        assistant.error = true;
        assistant.content = message.error || 'The provider request failed.';
        this.streaming = false;
        this.renderMessages();
        if (providerById(chosen.provider).localBridge) this.refreshBridgeStatus(true);
        port.disconnect();
        this.port = null;
      } else if (message.type === 'cancelled') {
        assistant.streaming = false;
        const index = this.messages.indexOf(assistant);
        if (!assistant.content && index >= 0) this.messages.splice(index, 1);
        this.streaming = false;
        this.renderMessages();
      }
    });
    port.onDisconnect.addListener(() => {
      if (!this.streaming || this.requestId !== requestId) return;
      assistant.streaming = false;
      assistant.error = true;
      const detail = chrome.runtime.lastError?.message;
      assistant.content ||= detail ? `The Scholia service worker disconnected: ${detail}` : 'The connection to the Scholia service worker closed before the provider replied. Try again.';
      this.streaming = false;
      this.port = null;
      this.renderMessages();
    });

    port.postMessage({
      type: 'start', requestId,
      payload: {
        ...chosen,
        webSearch,
        messages: conversation,
        kind: this.capture.kind,
        selection: this.capture.selection,
        context: packedContext,
        includeContext: true,
        compactContext,
        parentContext: this.capture.parentContext || '',
        pageTitle: this.capture.pageTitle,
        pageLanguage: this.capture.pageLanguage,
        url: this.capture.url,
        imageDataUrl: this.capture.imageDataUrl,
        useChatGptWebContext: document.documentElement.dataset.scholiaPdfViewer !== 'true'
          && Boolean(this.capture.useChatGptWebContext),
        learningMode: this.learningModeEnabled
      }
    });
  }

  cancelRequest() {
    try { this.port?.postMessage({ type: 'cancel', requestId: this.requestId }); } catch {}
    const assistant = this.messages.at(-1);
    if (assistant?.role === 'assistant' && assistant.streaming) assistant.streaming = false;
    this.streaming = false;
    this.port?.disconnect();
    this.port = null;
    this.renderMessages();
  }

  scheduleRender() {
    if (this.renderFrame) return;
    this.renderFrame = requestAnimationFrame(() => {
      this.renderFrame = null;
      this.renderMessages();
    });
  }

  renderMessages() {
    this.els.send.disabled = Boolean(this.layers.at(-1)?.moving);
    this.els.composer.readOnly = Boolean(this.layers.at(-1)?.moving);
    this.els.moveChat.disabled = this.streaming || this.layers.at(-1)?.moving
      || this.editingMessageIndex >= 0 || !this.messages.some((entry) => entry.role === 'user');
    this.els.moveChat.title = this.streaming
      ? 'Wait for the response to finish, or stop it before moving to chat'
      : 'Move this explanation to a full-page chat';
    const list = this.els.messages;
    if (!this.messages.length) {
      list.innerHTML = '<div class="scholia-empty"><strong>Ask in context</strong>Select text or capture a region, then Scholia will explain it here.</div>';
      this.renderComposerSubmitAction();
      return;
    }
    list.textContent = '';
    for (const [index, message] of this.messages.entries()) {
      const row = createHtmlElement('article');
      row.className = `scholia-message scholia-message--${message.role}${message.error ? ' scholia-message--error' : ''}`;
      row.dataset.messageIndex = String(index);
      const bubble = createHtmlElement('div');
      bubble.className = 'scholia-bubble';
      if (message.role === 'user') {
        appendFileChips(bubble, message.files);
        if (message.imageDataUrl) {
          const image = createHtmlElement('img');
          image.src = message.imageDataUrl; image.alt = 'Attached image';
          image.style.cssText = 'display:block;max-width:100%;max-height:180px;border-radius:8px;margin-bottom:8px';
          bubble.append(image);
        }
      }
      if (message.role === 'assistant' && !message.error) {
        bubble.innerHTML = renderReasoning(message.reasoning, { streaming: message.streaming })
          + renderMarkdown(message.content)
          + (message.streaming ? '<span class="scholia-caret" aria-label="Writing"></span>' : '');
      } else if (message.role === 'user' && this.editingMessageIndex === index) {
        row.classList.add('is-editing');
        const editor = createHtmlElement('div');
        editor.className = 'scholia-query-editor';
        const textarea = createHtmlElement('textarea');
        textarea.value = message.content;
        textarea.dataset.messageEditor = String(index);
        textarea.setAttribute('aria-label', 'Edit message');
        const actions = createHtmlElement('div');
        actions.className = 'scholia-query-editor__actions';
        const cancel = createHtmlElement('button');
        cancel.type = 'button';
        cancel.className = 'scholia-query-editor__cancel';
        cancel.dataset.cancelMessageEdit = String(index);
        cancel.textContent = 'Cancel';
        const resend = createHtmlElement('button');
        resend.type = 'button';
        resend.className = 'scholia-query-editor__resend';
        resend.dataset.resendMessage = String(index);
        resend.textContent = 'Resend';
        actions.append(cancel, resend);
        editor.append(textarea, actions);
        bubble.append(editor);
      } else if (message.role === 'user') {
        const copy = createHtmlElement('div');
        copy.className = 'scholia-query-copy';
        copy.textContent = message.content;
        const edit = createHtmlElement('button');
        edit.type = 'button';
        edit.className = 'scholia-query-edit';
        edit.dataset.editMessage = String(index);
        edit.disabled = this.streaming || Boolean(this.layers.at(-1)?.moving);
        edit.title = 'Edit this message and regenerate from here';
        edit.setAttribute('aria-label', 'Edit message');
        edit.textContent = 'Edit';
        bubble.append(copy, edit);
      } else {
        bubble.textContent = message.content;
      }
      if (message.meta) {
        const meta = createHtmlElement('div');
        meta.className = 'scholia-meta';
        meta.textContent = message.meta;
        bubble.append(meta);
      }
      row.append(bubble);
      list.append(row);
    }
    if (this.editingMessageIndex >= 0) {
      requestAnimationFrame(() => {
        const editor = list.querySelector(`[data-message-editor="${this.editingMessageIndex}"]`);
        editor?.focus();
        editor?.setSelectionRange(editor.value.length, editor.value.length);
        editor?.scrollIntoView({ block: 'nearest' });
      });
    } else {
      list.scrollTop = list.scrollHeight;
    }
    this.renderComposerSubmitAction();
  }

  async copyCode(event) {
    return copyCodeBlock(event, (error) => this.toast(error.message));
  }

  bindCaptureLayer() {
    let start = null;
    let current = null;
    const layer = this.els.captureLayer;
    const box = this.els.captureRect;
    this.resetCaptureDrag = () => { start = null; current = null; };
    const point = (event) => ({
      x: Math.max(0, Math.min(window.innerWidth, event.clientX)),
      y: Math.max(0, Math.min(window.innerHeight, event.clientY))
    });
    this.shadow.querySelector('[data-capture-cancel]').addEventListener('click', () => this.cancelCapture());

    const update = () => {
      if (!start || !current) return;
      const left = Math.min(start.x, current.x);
      const top = Math.min(start.y, current.y);
      const width = Math.abs(current.x - start.x);
      const height = Math.abs(current.y - start.y);
      Object.assign(box.style, { left: `${left}px`, top: `${top}px`, width: `${width}px`, height: `${height}px` });
      box.hidden = false;
    };

    layer.addEventListener('pointerdown', (event) => {
      if (event.button !== 0 || event.target.closest('.scholia-capture__help')) return;
      event.preventDefault();
      start = point(event);
      current = start;
      layer.setPointerCapture(event.pointerId);
      update();
    });
    layer.addEventListener('pointermove', (event) => {
      if (!start) return;
      current = point(event);
      update();
    });
    layer.addEventListener('pointerup', async (event) => {
      if (!start) return;
      current = point(event);
      const rect = {
        left: Math.min(start.x, current.x), top: Math.min(start.y, current.y),
        width: Math.abs(current.x - start.x), height: Math.abs(current.y - start.y)
      };
      start = null;
      current = null;
      box.hidden = true;
      if (rect.width < 16 || rect.height < 16) { this.cancelCapture(); return; }
      await this.finishCapture(rect);
    });
    layer.addEventListener('pointercancel', () => this.cancelCapture());
  }

  startCapture(forConversation, sendResponse = null) {
    if (this.siteDisabled()) { this.toast(this.siteDisabledMessage()); return; }
    if (this.regionCaptureSession) this.cancelCapture();
    if (this.streaming) this.cancelRequest();
    const controller = new AbortController();
    const readerChat = document.documentElement.dataset.scholiaPdfViewer === 'true'
      ? document.getElementById('pdf-chat') : null;
    const previousVisibility = readerChat?.style.getPropertyValue('visibility') || '';
    const previousPriority = readerChat?.style.getPropertyPriority('visibility') || '';
    // Keep the page's layout and scroll position while revealing the PDF below its chat.
    readerChat?.style.setProperty('visibility', 'hidden', 'important');
    this.regionCaptureSession = {
      sendResponse,
      cleanup: () => {
        controller.abort();
        if (readerChat) {
          if (previousVisibility) readerChat.style.setProperty('visibility', previousVisibility, previousPriority);
          else readerChat.style.removeProperty('visibility');
        }
      }
    };
    const options = { capture: true, signal: controller.signal };
    window.addEventListener('keydown', (event) => {
      event.preventDefault();
      event.stopImmediatePropagation();
      if (event.key === 'Escape') this.cancelCapture();
    }, options);
    window.addEventListener('wheel', (event) => event.preventDefault(), { ...options, passive: false });
    window.addEventListener('resize', () => this.cancelCapture(), options);
    document.addEventListener('visibilitychange', () => { if (document.hidden) this.cancelCapture(); }, options);
    window.addEventListener('pagehide', () => this.cancelCapture(), options);
    this.captureReturnToModal = !this.els.backdrop.hidden;
    this.captureForConversation = Boolean(forConversation && this.messages.length);
    this.els.backdrop.hidden = true;
    this.hidePill();
    this.els.captureLayer.hidden = false;
    this.els.captureRect.hidden = true;
    clearTimeout(this.toastTimer);
    this.els.toast.hidden = true;
    window.focus();
    this.els.captureLayer.focus({ preventScroll: true });
  }

  cancelCapture() {
    const session = this.regionCaptureSession;
    this.regionCaptureSession = null;
    this.resetCaptureDrag();
    this.els.captureLayer.hidden = true;
    this.els.captureRect.hidden = true;
    if (this.captureReturnToModal) this.els.backdrop.hidden = false;
    this.captureForConversation = false;
    this.captureReturnToModal = false;
    session?.cleanup();
    session?.sendResponse?.({ ok: true, value: null });
  }

  async finishCapture(rect) {
    const session = this.regionCaptureSession;
    if (!session) return;
    this.els.captureLayer.hidden = true;
    clearTimeout(this.toastTimer);
    this.els.toast.hidden = true;
    try {
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      if (this.regionCaptureSession !== session) return;
      const screenshot = await extensionMessage({ type: 'SCHOLIA_CAPTURE_VISIBLE' });
      if (this.regionCaptureSession !== session) return;
      const imageDataUrl = await cropScreenshot(screenshot, rect);
      if (this.regionCaptureSession !== session) return;
      session.cleanup();
      if (session.sendResponse) {
        if (this.captureReturnToModal) this.els.backdrop.hidden = false;
        session.sendResponse({ ok: true, value: { imageDataUrl } });
        return;
      }
      this.toast('Preparing the selected region…', 5000);
      const nextCapture = {
        kind: 'image', selection: '', preview: 'Captured screen region',
        ...await resolvedPageMetadata({
          forSelection: true, rect, fullContext: this.settings?.includePageContext === false
        }), imageDataUrl, rect
      };
      if (this.captureForConversation) {
        this.capture = nextCapture;
        this.messages.splice(0);
        this.editingMessageIndex = -1;
        const layer = this.layers.at(-1);
        if (layer) {
          layer.capture = nextCapture;
          layer.messages = this.messages;
        }
        this.renderSource();
        this.renderMessages();
        this.renderLayerStack();
        this.els.backdrop.hidden = false;
        this.els.composer.placeholder = 'Ask about the captured region…';
        this.renderComposerSubmitAction();
        this.els.composer.focus();
      } else {
        this.showImageDraft(nextCapture);
      }
    } catch (error) {
      if (this.regionCaptureSession !== session) return;
      if (session.sendResponse) session.sendResponse({ ok: false, error: error.message || 'Could not capture this region.' });
      else this.toast(error.message || 'Could not capture this region.');
      if (this.captureReturnToModal) this.els.backdrop.hidden = false;
    } finally {
      if (this.regionCaptureSession === session) {
        session.cleanup();
        this.regionCaptureSession = null;
        this.captureForConversation = false;
        this.captureReturnToModal = false;
      }
    }
  }

  toast(message, duration = 3200) {
    clearTimeout(this.toastTimer);
    this.els.toast.textContent = message;
    this.els.toast.hidden = false;
    this.toastTimer = setTimeout(() => { this.els.toast.hidden = true; }, duration);
  }
}

if (!document.getElementById(HOST_ID)) boot();
