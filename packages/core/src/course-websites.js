import { mathWikiLink, publicTeachingURL } from './math-wiki.js';

// Verified teaching sites whose hostname does not contain the course code.
// Keep in sync with CourseWebsiteAddress.knownSeeds in the native client.
const knownNTNUWebsites = {
  TDT4120: 'https://algdat.idi.ntnu.no/',
};

export function knownCourseWebsiteSeeds(course) {
  if (course.canvasOrigin && course.canvasOrigin !== 'https://canvas.ntnu.no') return [];
  const codes = (value) => String(value || '').toUpperCase().match(/\b[A-ZÆØÅ]{2,8}\d{3,5}\b/g) || [];
  const explicit = codes(course.code);
  return [...new Set(explicit.length ? explicit : codes(course.name))]
    .flatMap(code => knownNTNUWebsites[code] ? [{ url: knownNTNUWebsites[code], evidenceURL: knownNTNUWebsites[code] }] : []);
}

export const isCourseWebsiteMaterial = (ref) => !!ref.id?.startsWith('course-web:');
export function courseWebsiteLink(value, base) {
  const url = publicTeachingURL(value, base);
  if (!url || /(?:^|\/)(?:login|logout|signin|signout|wp-admin|admin|ovsys|labregistrering|forum|ripes|git-pull|hub|inginious|queue)(?:\/|$)/i.test(url.pathname)) return null;
  const math = mathWikiLink(url.href);
  if (math) return math;
  if (url.hostname === 'wiki.math.ntnu.no') return null;
  if (/\.(?:html?|php|aspx?)$/i.test(url.pathname) || !/\.[a-z0-9]+$/i.test(url.pathname))
    return { kind: 'pages', url: url.href };
  return null;
}

// Seeds come from the enrolled course's actual Canvas content. A course code
// in the URL or an explicit course-site announcement distinguishes a teaching
// site from incidental references, staff profiles and university catalogs.
export function isCourseWebsiteHint(link, context, course) {
  if (link?.kind !== 'pages') return false;
  const url = new URL(link.url);
  if (url.origin === course.canvasOrigin || url.hostname === 'wiki.math.ntnu.no') return false;
  if (/\/(?:studier\/emner|studies\/courses|employees|ansatte|people|profile|studiekvalitetsportalen)(?:\/|$)/i.test(url.pathname)) return false;
  if (/^(?:git\.|gitlab\.|github\.com$|tp\.educloud\.no$)/i.test(url.hostname)) return false;
  if (/\b(?:youtube|youtu\.be|vimeo|zoom|teams\.microsoft|mazemap|panopto|piazza|edstem|ovsys|mattelab\d*[hv]?)\b/i.test(url.hostname)) return false;
  const codes = `${course.code || ''} ${course.name || ''}`.match(/\b[A-ZÆØÅ]{2,8}\d{3,5}\b/gi) || [];
  return codes.some((code) => url.href.toLowerCase().includes(code.toLowerCase())) ||
    /(?:course|class|subject|teaching)\s*(?:web\s*(?:site|page)|home\s*page|site)|(?:web\s*(?:site|page)|home\s*page)\s*(?:for|of)\s*(?:the\s*)?course|(?:emne|kurs|fag)(?:ets|et|s)?[-\s]*(?:nettside|hjemmeside|webside)|(?:nettside|hjemmeside)\s*(?:for|til)\s*(?:emnet|kurset|faget)/i.test(context);
}

export function websiteRoot(value) {
  const url = new URL(value);
  url.hash = ''; url.search = '';
  if (/\/[a-zæøå]{2,8}\d{3,5}\.html?$/i.test(url.pathname)) url.pathname = url.pathname.replace(/\.html?$/i, '/');
  else if (/\.[a-z0-9]+$/i.test(url.pathname) || /\/(?:start|index|home)$/i.test(url.pathname)) url.pathname = url.pathname.slice(0, url.pathname.lastIndexOf('/') + 1);
  else if (!url.pathname.endsWith('/')) url.pathname += '/';
  return url.href;
}

export function withinWebsite(value, seed) {
  const url = new URL(value), entry = new URL(seed), root = new URL(websiteRoot(seed));
  return courseWebsiteLink(value)?.kind === 'pages' && url.origin === root.origin && (url.pathname === entry.pathname || url.pathname.startsWith(root.pathname)) &&
    !/[?&](?:do|action)=(?:edit|login|logout|delete|history)/i.test(url.href) &&
    !/\/(?:tags?|authors?|search|feed|wp-json|wp-admin)(?:\/|$)/i.test(url.pathname);
}
