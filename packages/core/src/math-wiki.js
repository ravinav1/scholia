const origin = 'https://wiki.math.ntnu.no';

export function publicTeachingURL(value, base = origin) {
  try {
    const url = new URL(value, base), host = url.hostname;
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.port) return null;
    if (!host.includes('.') || /(?:^|\.)(?:localhost|local|internal|lan|home|test|invalid|example)$/.test(host) || /^[\d.]+$/.test(host) || host.includes(':')) return null;
    url.protocol = 'https:';
    url.hash = '';
    return url;
  } catch { return null; }
}

export function mathWikiLink(value, base = origin) {
  let url = publicTeachingURL(value, base);
  if (!url) return null;
  if (url.hostname === 'github.com' && /^\/[^/]+\/[^/]+\/edit\//.test(url.pathname)) return null;
  if (url.hostname === 'colab.research.google.com' && /^\/github\/[^/]+\/[^/]+\/blob\//.test(url.pathname)) {
    url = new URL('https://raw.githubusercontent.com' + url.pathname.replace(/^\/github/, '').replace('/blob/', '/'));
  }
  if (url.hostname === 'github.com' && /^\/[^/]+\/[^/]+\/blob\//.test(url.pathname)) {
    url = new URL('https://raw.githubusercontent.com' + url.pathname.replace('/blob/', '/'));
  }
  // NTNU's document service puts a version UUID after the actual filename.
  const document = url.pathname.match(/^\/documents\/\d+\/\d+\/([^/]+\.(?:pdf|docx?|pptx?|xlsx?|zip))\/[^/]+\/?$/i);
  if (document) {
    url.searchParams.delete('t');
    return { kind: 'files', url: url.href, fileName: decodeURIComponent(document[1]) };
  }
  if (url.origin === origin) {
    if (url.searchParams.has('do') && !['', 'show'].includes(url.searchParams.get('do'))) return null;
    if (url.searchParams.has('rev')) return null;
    const media = url.searchParams.get('media');
    if (media && ['/lib/exe/fetch.php', '/lib/exe/detail.php'].includes(url.pathname)) {
      if (/^https?:\/\//i.test(media)) return mathWikiLink(media);
      url = new URL('/_media/' + media.replace(/^:/, '').replaceAll(':', '/'), origin);
    } else if (url.pathname.startsWith('/_detail/')) url.pathname = url.pathname.replace('/_detail/', '/_media/');
    else if (url.searchParams.has('id')) url = new URL('/' + url.searchParams.get('id').replaceAll(':', '/'), origin);
    if (url.pathname.startsWith('/_media/')) {
      url.search = '';
      return { kind: 'files', url: url.href, fileName: decodeURIComponent(url.pathname.split('/').at(-1)) };
    }
    if (!/\.[a-z0-9]+$/i.test(url.pathname)) {
      url.search = '';
      url.pathname = url.pathname.replace(/\/+$/, '').toLowerCase();
      return { kind: 'pages', url: url.href };
    }
  }
  if (/\.(?:pdf|ipynb|py|r|m|jl|txt|md|tex|csv|tsv|json|zip|docx?|pptx?|xlsx?|odt|ods|odp|png|jpe?g|webp|svg)$/i.test(url.pathname))
    return { kind: 'files', url: url.href, fileName: decodeURIComponent(url.pathname.split('/').at(-1)) };
  return null;
}
