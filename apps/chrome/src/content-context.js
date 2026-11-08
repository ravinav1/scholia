import { isCanvasCoursePage, canvasCourseFromUrl } from './canvas-course.js';
import { siteIsEnabled } from '../../../packages/core/src/providers.js';
import { packPageContext, packSiteContext } from '../../../packages/core/src/context.js';
import { sendRuntimeMessage } from './runtime-message.js';
import { currentSiteKey, resolvedPageMetadata } from './page-capture.js';
import { crawlSite, siteLinksFromDocument } from './site-context.js';
import { researchUrl, researchLinksFromDocument } from './research-links.js';
import { finishDeepPageCapture, prepareDeepPageCapture, scrollDeepPageCapture } from './deep-page.js';

// Background context retrieval never mounts the explanation UI or its renderers.
export function createContextReader() { return new ContentContext(); }
class ContentContext {
  constructor() { this.siteContextCache = new Map(); }
  async handleRuntimeMessage(message, _sender, respond) {
    try {
      if (!['SCHOLIA_SCROLL_DEEP_PAGE', 'SCHOLIA_FINISH_DEEP_PAGE'].includes(message.type)) {
        const settings = await sendRuntimeMessage({ type: 'SCHOLIA_GET_PUBLIC_SETTINGS' });
        if (!siteIsEnabled(settings, currentSiteKey())) throw new Error(settings?.siteAccessMode === 'allowlist'
          ? 'This site is not whitelisted. Add it from the extension panel.'
          : 'Scholia is disabled on this site. Re-enable it from the extension panel.');
      }
      respond?.({ ok: true, value: await this.read(message) });
    } catch (error) {
      respond?.({ ok: false, error: error?.message || 'Scholia could not read this page.' });
    }
  }
  async read(message) {
    if (message.type === 'SCHOLIA_PREPARE_DEEP_PAGE') return prepareDeepPageCapture();
    if (message.type === 'SCHOLIA_SCROLL_DEEP_PAGE') return scrollDeepPageCapture(message.position, { sessionId: String(message.sessionId || '') });
    if (message.type === 'SCHOLIA_FINISH_DEEP_PAGE') {
      try { return { metadata: await resolvedPageMetadata(), ...finishDeepPageCapture({ sessionId: String(message.sessionId || '') }) }; }
      catch (error) { finishDeepPageCapture({ sessionId: String(message.sessionId || '') }); throw error; }
    }
    if (message.type === 'SCHOLIA_GET_SITE_CONTEXT') return this.getSiteContext({
      question: String(message.question || ''), selection: String(message.selection || ''),
      includeContext: message.includeContext, maxChars: message.maxChars,
    });
    const metadata = await resolvedPageMetadata();
    if (message.type === 'SCHOLIA_GET_RESEARCH_PAGE') return {
      url: researchUrl(location.href), title: metadata.pageTitle, text: metadata.context.slice(0, 120_000),
      links: researchLinksFromDocument(document, location.href),
      ...(isCanvasCoursePage(location.href, document) ? { canvasCourse: canvasCourseFromUrl(location.href) } : {}),
    };
    if (message.type === 'SCHOLIA_GET_TAB_CONTEXT_PREVIEW') return {
      pageTitle: metadata.pageTitle, url: metadata.url, visibleText: metadata.visibleContext,
      context: packPageContext(metadata.context, {
        outline: metadata.outline, selection: String(message.correlationText || metadata.visibleContext || ''),
        question: String(message.question || ''),
        maxChars: Number.isFinite(Number(message.maxChars)) ? Number(message.maxChars) : 3_500,
        scopeDescription: 'a related open browser tab',
      }),
    };
    if (message.type !== 'SCHOLIA_GET_PAGE_CONTEXT') throw new Error('Unknown page context request.');
    const context = message.includeContext !== false ? packPageContext(metadata.context, {
      outline: metadata.outline, selection: String(message.selection || ''), question: String(message.question || ''),
      ...(message.maxChars != null && Number.isFinite(Number(message.maxChars)) ? { maxChars: Number(message.maxChars) } : {}),
      scopeDescription: metadata.htmlContextCharacters
        ? 'the live page text, accessible embedded content, image descriptions, and its sanitized DOM HTML snapshot'
        : 'the complete live page text',
    }) : '';
    return { ...metadata,
      ...(isCanvasCoursePage(location.href, document) ? { canvasCourse: canvasCourseFromUrl(location.href) } : {}),
      context, outline: '', rawContextCharacters: metadata.context.length, packedContextCharacters: context.length,
    };
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
      if (this.siteContextCache.size > 4) this.siteContextCache.delete(this.siteContextCache.keys().next().value);
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

}
