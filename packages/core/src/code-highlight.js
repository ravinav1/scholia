import hljs from 'highlight.js';

// Returns UTF-16 ranges so the same language grammars work in AppKit text storage.
export function highlightCodeRuns(source, language) {
  source = String(source || '');
  language = String(language || '').trim().split(/\s+/, 1)[0].toLowerCase();
  if (!language || !hljs.getLanguage(language) || source.length > 100_000) return [];
  const html = hljs.highlight(source, { language, ignoreIllegals: true }).value;
  const runs = [], scopes = [];
  let decoded = '';
  const decode = (value) => value.replace(/&(amp|lt|gt|quot|#x27|#39);/g, (_, entity) => ({ amp: '&', lt: '<', gt: '>', quot: '"', '#x27': "'", '#39': "'" })[entity]);
  for (const token of html.match(/<\/?span\b[^>]*>|[^<]+|</g) || []) {
    if (token.startsWith('<span')) scopes.push(token.match(/class="([^"]*)"/)?.[1] || '');
    else if (token === '</span>') scopes.pop();
    else {
      const text = decode(token);
      if (text.length && scopes.length) runs.push({ location: decoded.length, length: text.length, scope: scopes.join(' ') });
      decoded += text;
    }
  }
  return decoded === source ? runs : [];
}
