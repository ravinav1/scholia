const UNSUPPORTED = /\.(?:7z|avi|avif|bmp|css|eot|epub|gif|gz|ico|jpe?g|js|map|mkv|mov|mp3|mp4|ogg|png|rar|svg|tar|tiff?|wav|webm|webp|woff2?|zip)$/i;
const ACTION = /(?:^|[\W_])(?:delete|destroy|login|log-in|logout|log-out|signin|sign-in|signout|sign-out|oauth|authorize|unsubscribe|enroll|unenroll|submit|publish|reset|revoke|approve|reject|purchase|checkout)(?:$|[\W_])/i;
const SECRET = /^(?:access_token|auth|authorization|token|key|api_key|signature|sig|verifier|password|code|x-amz-.+|x-goog-.+)$/i;

export function researchUrl(value, base) {
  try {
    const url = new URL(String(value || ''), base);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.href.length > 2048) return '';
    if (ACTION.test(decodeURIComponent(url.pathname)) || UNSUPPORTED.test(url.pathname)) return '';
    for (const [key, value] of [...url.searchParams]) {
      if (SECRET.test(key) || ACTION.test(key) || (/^(?:action|do|method|event)$/i.test(key) && !/^(?:view|read|show|list)$/i.test(value))) return '';
      if (/^(?:utm_.+|fbclid|gclid|ref)$/i.test(key)) url.searchParams.delete(key);
    }
    url.hash = '';
    url.searchParams.sort();
    return url.href;
  } catch { return ''; }
}

export function researchLinksFromDocument(documentValue, base) {
  const links = new Map();
  for (const node of documentValue?.querySelectorAll?.('a[href],iframe[src]') || []) {
    if (node.closest('form,[hidden],[aria-hidden="true"],#scholia-root,#global_nav,.ic-app-header__main-navigation')
        || /\bnofollow\b/i.test(node.getAttribute('rel') || '')
        || (node.getAttribute('data-method') && node.getAttribute('data-method').toLowerCase() !== 'get')) continue;
    const url = researchUrl(node.getAttribute('href') || node.getAttribute('src'), base);
    if (!url || links.has(url)) continue;
    const title = String(node.textContent || node.getAttribute('title') || node.getAttribute('aria-label') || '')
      .replace(/\s+/g, ' ').trim().slice(0, 300);
    links.set(url, { url, title });
    if (links.size >= 1000) break;
  }
  return [...links.values()];
}

export function promptResearchLinks(question) {
  return (String(question || '').match(/https?:\/\/[^\s<>"`]+/gi) || []).slice(0, 20)
    .map((value) => researchUrl(value.replace(/[),.;!?\]}]+$/, '')))
    .filter(Boolean).map((url) => ({ url, title: 'Link in your question', explicit: true }));
}
