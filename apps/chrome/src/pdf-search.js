export const MAX_PDF_SEARCH_RESULTS = 10_000;
export const MAX_PDF_SEMANTIC_RESULTS = 100;

const SEMANTIC_STOP_WORDS = new Set([
  'about', 'after', 'also', 'and', 'are', 'because', 'been', 'before', 'being', 'between',
  'both', 'but', 'can', 'could', 'does', 'each', 'explain', 'for', 'from', 'had', 'has',
  'have', 'into', 'its', 'more', 'most', 'not', 'only', 'other', 'over', 'same', 'should',
  'some', 'such', 'than', 'that', 'the', 'their', 'then', 'there', 'these', 'they', 'this',
  'through', 'under', 'very', 'was', 'were', 'what', 'when', 'where', 'which', 'while',
  'who', 'will', 'with', 'would', 'your',
  'alle', 'blir', 'den', 'denne', 'der', 'det', 'dette', 'eller', 'enn', 'etter', 'fordi',
  'fra', 'har', 'hva', 'hvem', 'hvor', 'ikke', 'kan', 'med', 'men', 'mer', 'mot', 'noe',
  'og', 'om', 'over', 'skal', 'som', 'til', 'under', 'ved', 'være'
]);

const SEMANTIC_CONCEPT_GROUPS = [
  ['cause', 'reason', 'why', 'because', 'mechanism', 'driver', 'origin', 'arsak', 'grunn', 'hvorfor', 'skyldes'],
  ['effect', 'result', 'consequence', 'impact', 'outcome', 'therefore', 'virkning', 'resultat', 'konsekvens', 'utfall'],
  ['define', 'definition', 'meaning', 'means', 'concept', 'term', 'definisjon', 'betydning', 'begrep'],
  ['compare', 'comparison', 'difference', 'different', 'versus', 'similar', 'contrast', 'sammenligne', 'forskjell', 'likhet'],
  ['process', 'step', 'method', 'procedure', 'algorithm', 'workflow', 'approach', 'prosess', 'trinn', 'metode', 'fremgangsmate'],
  ['example', 'instance', 'illustration', 'case', 'eksempel', 'tilfelle', 'illustrasjon'],
  ['benefit', 'advantage', 'strength', 'gain', 'fordel', 'styrke', 'gevinst'],
  ['risk', 'limitation', 'disadvantage', 'weakness', 'problem', 'drawback', 'ulempe', 'begrensning', 'svakhet', 'problem'],
  ['summary', 'conclusion', 'overview', 'recap', 'takeaway', 'oppsummering', 'konklusjon', 'oversikt'],
  ['increase', 'grow', 'rise', 'higher', 'more', 'oker', 'vekst', 'stiger', 'hoyere'],
  ['decrease', 'reduce', 'fall', 'lower', 'less', 'reduserer', 'faller', 'lavere', 'mindre'],
  ['create', 'produce', 'generate', 'form', 'make', 'convert', 'lage', 'produsere', 'danne', 'omdanne'],
  ['use', 'apply', 'application', 'purpose', 'function', 'bruke', 'anvende', 'formal', 'funksjon'],
  ['part', 'component', 'element', 'structure', 'section', 'del', 'komponent', 'element', 'struktur'],
  ['store', 'storage', 'retain', 'hold', 'accumulate', 'lagre', 'lager', 'beholde', 'samle'],
  ['energy', 'power', 'fuel', 'energi', 'kraft', 'drivstoff'],
  ['sunlight', 'solar', 'light', 'sun', 'sollys', 'solenergi', 'lys'],
  ['plant', 'vegetation', 'photosynthesis', 'plante', 'vegetasjon', 'fotosyntese']
];

function foldedWord(value) {
  return String(value || '')
    .normalize('NFKD')
    .replace(/\p{M}+/gu, '')
    .replace(/æ/gi, 'ae')
    .replace(/ø/gi, 'o')
    .toLowerCase();
}

function semanticStem(value) {
  let term = foldedWord(value).replace(/^[^a-z0-9]+|[^a-z0-9]+$/g, '');
  if (term.length <= 4) return term;
  const suffixes = [
    ['izations', 'ize'], ['ization', 'ize'], ['ations', 'ate'], ['ation', 'ate'],
    ['ments', ''], ['ment', ''], ['ingly', ''], ['ende', ''], ['inger', ''],
    ['ing', ''], ['ied', 'y'], ['ies', 'y'], ['ers', ''], ['ene', ''],
    ['ed', ''], ['er', ''], ['es', ''], ['en', ''], ['et', ''], ['s', '']
  ];
  for (const [suffix, replacement] of suffixes) {
    if (term.endsWith(suffix) && term.length - suffix.length + replacement.length >= 4) {
      term = `${term.slice(0, -suffix.length)}${replacement}`;
      break;
    }
  }
  return term;
}

const SEMANTIC_EQUIVALENTS = (() => {
  const equivalents = new Map();
  for (const group of SEMANTIC_CONCEPT_GROUPS) {
    const terms = [...new Set(group.map(semanticStem).filter(Boolean))];
    for (const term of terms) equivalents.set(term, terms);
  }
  return equivalents;
})();

function semanticTokens(value, { keepStopWords = false } = {}) {
  const source = String(value || '');
  const tokens = [];
  for (const match of source.matchAll(/[\p{L}\p{N}][\p{L}\p{M}\p{N}'’-]*/gu)) {
    const folded = foldedWord(match[0]);
    const term = semanticStem(folded);
    if (!term || (!keepStopWords && SEMANTIC_STOP_WORDS.has(folded))) continue;
    tokens.push({ term, start: match.index, length: match[0].length });
  }
  return tokens;
}

function termBucket(term) {
  return `${term[0] || ''}:${Math.floor(term.length / 3)}`;
}

export function createPdfSemanticIndex() {
  return {
    pages: [],
    documentFrequency: new Map(),
    vocabulary: new Set(),
    vocabularyBuckets: new Map(),
    totalTokens: 0,
    averagePageLength: 0,
    finalized: false
  };
}

export function addPdfSemanticPage(index, value, pageIndex = index?.pages?.length || 0) {
  if (!index?.pages || index.finalized) throw new Error('The PDF semantic index cannot accept more pages.');
  const tokens = semanticTokens(value);
  const termCounts = new Map();
  for (const { term } of tokens) termCounts.set(term, (termCounts.get(term) || 0) + 1);
  index.pages[pageIndex] = { termCounts, tokenCount: tokens.length };
  index.totalTokens += tokens.length;
  for (const term of termCounts.keys()) {
    index.documentFrequency.set(term, (index.documentFrequency.get(term) || 0) + 1);
    index.vocabulary.add(term);
    const bucket = termBucket(term);
    const terms = index.vocabularyBuckets.get(bucket) || new Set();
    terms.add(term);
    index.vocabularyBuckets.set(bucket, terms);
  }
  return index;
}

export function finalizePdfSemanticIndex(index) {
  if (!index?.pages) return createPdfSemanticIndex();
  for (let pageIndex = 0; pageIndex < index.pages.length; pageIndex += 1) {
    index.pages[pageIndex] ||= { termCounts: new Map(), tokenCount: 0 };
  }
  index.averagePageLength = index.pages.length ? index.totalTokens / index.pages.length : 0;
  index.finalized = true;
  return index;
}

export function buildPdfSemanticIndex(pageTexts = []) {
  const index = createPdfSemanticIndex();
  for (const [pageIndex, text] of (Array.isArray(pageTexts) ? pageTexts : []).entries()) {
    addPdfSemanticPage(index, text, pageIndex);
  }
  return finalizePdfSemanticIndex(index);
}

function wordTrigrams(value) {
  const padded = `^${value}$`;
  const values = new Set();
  for (let index = 0; index <= padded.length - 3; index += 1) values.add(padded.slice(index, index + 3));
  return values;
}

function trigramSimilarity(left, right) {
  const leftTerms = wordTrigrams(left);
  const rightTerms = wordTrigrams(right);
  let overlap = 0;
  for (const term of leftTerms) if (rightTerms.has(term)) overlap += 1;
  return 2 * overlap / Math.max(1, leftTerms.size + rightTerms.size);
}

function nearbyVocabularyTerms(index, term) {
  if (term.length < 5 || index.vocabulary.has(term)) return [];
  const buckets = [
    termBucket(term),
    `${term[0] || ''}:${Math.max(0, Math.floor(term.length / 3) - 1)}`,
    `${term[0] || ''}:${Math.floor(term.length / 3) + 1}`
  ];
  const candidates = new Set(buckets.flatMap((bucket) => [...(index.vocabularyBuckets.get(bucket) || [])]));
  return [...candidates]
    .map((candidate) => ({ term: candidate, score: trigramSimilarity(term, candidate) }))
    .filter(({ score }) => score >= 0.68)
    .sort((left, right) => right.score - left.score || left.term.localeCompare(right.term))
    .slice(0, 2);
}

function semanticQueryFeatures(index, rawQuery) {
  const baseTerms = [...new Set(semanticTokens(rawQuery).map(({ term }) => term))];
  const features = new Map();
  for (const term of baseTerms) {
    features.set(term, Math.max(features.get(term) || 0, 1.5));
    for (const equivalent of SEMANTIC_EQUIVALENTS.get(term) || []) {
      if (equivalent !== term) features.set(equivalent, Math.max(features.get(equivalent) || 0, 0.58));
    }
    for (const candidate of nearbyVocabularyTerms(index, term)) {
      features.set(candidate.term, Math.max(features.get(candidate.term) || 0, 0.42 * candidate.score));
    }
  }
  return { baseTerms, features };
}

function inverseDocumentFrequency(index, term) {
  const documents = Math.max(1, index.pages.length);
  const frequency = index.documentFrequency.get(term) || 0;
  return Math.log(1 + (documents - frequency + 0.5) / (frequency + 0.5));
}

function semanticPageScore(index, page, features) {
  const averageLength = Math.max(1, index.averagePageLength);
  const lengthRatio = page.tokenCount / averageLength;
  let score = 0;
  let matchedFeatures = 0;
  for (const [term, weight] of features) {
    const frequency = page.termCounts.get(term) || 0;
    if (!frequency) continue;
    const normalizedFrequency = frequency * 2.3 / (frequency + 1.3 * (0.28 + 0.72 * lengthRatio));
    score += weight * inverseDocumentFrequency(index, term) * normalizedFrequency;
    matchedFeatures += 1;
  }
  return score * (1 + Math.min(0.35, Math.max(0, matchedFeatures - 1) * 0.07));
}

function bestSemanticRange(text, index, features) {
  const matches = semanticTokens(text, { keepStopWords: true })
    .filter(({ term }) => features.has(term))
    .map((token) => ({
      ...token,
      score: features.get(token.term) * inverseDocumentFrequency(index, token.term)
    }));
  if (!matches.length) return { start: 0, length: 0, excerpt: '' };

  let bestWindow = { score: -1, start: 0, end: 0 };
  let right = 0;
  let windowScore = 0;
  for (let left = 0; left < matches.length; left += 1) {
    while (right < matches.length && matches[right].start - matches[left].start <= 520) {
      windowScore += matches[right].score;
      right += 1;
    }
    if (windowScore > bestWindow.score) {
      bestWindow = { score: windowScore, start: left, end: right };
    }
    windowScore -= matches[left].score;
    if (right < left + 1) right = left + 1;
  }
  const windowMatches = matches.slice(bestWindow.start, bestWindow.end);
  const anchor = [...windowMatches].sort((left, rightValue) => rightValue.score - left.score || left.start - rightValue.start)[0];
  const excerptStart = Math.max(0, anchor.start - 90);
  const excerpt = String(text).slice(excerptStart, anchor.start + anchor.length + 150).replace(/\s+/g, ' ').trim();
  return { start: anchor.start, length: anchor.length, excerpt };
}

export function findPdfSemanticMatches(pageTexts, rawQuery, semanticIndex, limit = MAX_PDF_SEMANTIC_RESULTS) {
  const texts = Array.isArray(pageTexts) ? pageTexts : [];
  if (!String(rawQuery || '').trim() || limit <= 0 || !texts.length) return { matches: [], truncated: false };
  const index = semanticIndex?.finalized && semanticIndex.pages.length === texts.length
    ? semanticIndex
    : buildPdfSemanticIndex(texts);
  const { baseTerms, features } = semanticQueryFeatures(index, rawQuery);
  if (!baseTerms.length || !features.size) return { matches: [], truncated: false };

  const ranked = index.pages
    .map((page, pageIndex) => ({ pageIndex, score: semanticPageScore(index, page, features) }))
    .filter(({ score }) => score > 0)
    .sort((left, right) => right.score - left.score || left.pageIndex - right.pageIndex);
  const truncated = ranked.length > limit;
  const matches = ranked.slice(0, limit).map(({ pageIndex, score }) => ({
    pageIndex,
    ...bestSemanticRange(texts[pageIndex], index, features),
    score
  }));
  return { matches, truncated };
}

function escapedLiteral(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function queryPattern(rawQuery) {
  const query = String(rawQuery || '');
  const phrase = query.trim()
    .split(/\s+/u)
    .filter(Boolean)
    .map(escapedLiteral)
    .join('\\s+');
  if (!phrase) return '';
  // Edge spaces constrain the match instead of being discarded. Assertions
  // let adjacent matches share a separator (" ry ry "), without highlighting
  // or consuming the surrounding whitespace. PDF line breaks/NBSP count too.
  return `${/^\s/u.test(query) ? '(?<=\\s)' : ''}${phrase}${/\s$/u.test(query) ? '(?=\\s)' : ''}`;
}

export function findPdfMatches(pageTexts, rawQuery, limit = MAX_PDF_SEARCH_RESULTS) {
  const pattern = queryPattern(rawQuery);
  if (!pattern || !Array.isArray(pageTexts) || limit <= 0) {
    return { matches: [], truncated: false };
  }

  const matches = [];
  const expression = new RegExp(pattern, 'giu');
  for (const [pageIndex, value] of pageTexts.entries()) {
    const text = String(value || '');
    expression.lastIndex = 0;
    let match;
    while ((match = expression.exec(text)) !== null) {
      matches.push({ pageIndex, start: match.index, length: match[0].length });
      if (matches.length >= limit) return { matches, truncated: true };
    }
  }
  return { matches, truncated: false };
}

/** Cooperatively scan large documents; a superseded query stops at the next slice. */
export async function findPdfMatchesAsync(pageTexts, rawQuery, {
  limit = MAX_PDF_SEARCH_RESULTS, signal,
  yieldTask = () => new Promise((resolve) => setTimeout(resolve, 0))
} = {}) {
  const pattern = queryPattern(rawQuery);
  if (!pattern || !Array.isArray(pageTexts) || limit <= 0) return { matches: [], truncated: false };
  const expression = new RegExp(pattern, 'giu');
  const matches = [];
  let started = performance.now();
  for (const [pageIndex, value] of pageTexts.entries()) {
    signal?.throwIfAborted();
    expression.lastIndex = 0;
    let match;
    while ((match = expression.exec(String(value || ''))) !== null) {
      matches.push({ pageIndex, start: match.index, length: match[0].length });
      if (matches.length >= limit) return { matches, truncated: true };
      if (matches.length % 256 === 0 && performance.now() - started >= 8) {
        await yieldTask();
        signal?.throwIfAborted();
        started = performance.now();
      }
    }
    if (performance.now() - started >= 8) {
      await yieldTask();
      signal?.throwIfAborted();
      started = performance.now();
    }
  }
  return { matches, truncated: false };
}

/** Preserve PDF line separators while keeping offsets into the selectable spans. */
export function pdfSearchTextContent(items = []) {
  const parts = [], itemStarts = [];
  let offset = 0;
  for (const item of items) {
    if (typeof item?.str !== 'string') continue;
    itemStarts.push(offset);
    const text = item.str + (item.hasEOL ? '\n' : '');
    parts.push(text);
    offset += text.length;
  }
  return { text: parts.join(''), itemStarts };
}

export function pdfMatchItemSegments(items, start, length, itemStarts) {
  const matchStart = Math.max(0, Number(start) || 0);
  const matchEnd = matchStart + Math.max(0, Number(length) || 0);
  if (!Array.isArray(items) || matchEnd <= matchStart) return [];

  const segments = [];
  // A cached offset table avoids rescanning every earlier span for every hit.
  let first = 0;
  if (itemStarts?.length) {
    let high = itemStarts.length;
    while (first < high) {
      const middle = (first + high) >>> 1;
      if (itemStarts[middle] + String(items[middle] || '').length <= matchStart) first = middle + 1;
      else high = middle;
    }
  }
  let itemStart = itemStarts?.[first] || 0;
  for (let itemIndex = first; itemIndex < items.length; itemIndex += 1) {
    if (itemStarts) itemStart = itemStarts[itemIndex];
    const text = String(items[itemIndex] || '');
    const itemEnd = itemStart + text.length;
    if (matchEnd <= itemStart) break;
    if (matchStart < itemEnd && matchEnd > itemStart) {
      segments.push({
        itemIndex,
        start: Math.max(0, matchStart - itemStart),
        end: Math.min(text.length, matchEnd - itemStart)
      });
    }
    itemStart = itemEnd;
  }
  return segments;
}
