import { extname } from 'node:path';

// Persist only a small explanation, never a second copy of the document text.
export const materialAnalysisVersion = 1;
export const materialCategories = [
  ['information', 'Course information'],
  ['lectures', 'Lectures & slides'],
  ['notes', 'Notes'],
  ['readings', 'Readings'],
  ['exercises', 'Exercises & assignments'],
  ['solutions', 'Solutions'],
  ['exams', 'Exams & revision'],
  ['code', 'Code & notebooks'],
  ['data', 'Data'],
  ['documents', 'Documents'],
  ['assets', 'Course assets'],
];
const labels = new Map(materialCategories);
const cues = {
  information: [
    /\bsyllabus\b/iu,
    /\bcourse (?:information|overview|schedule|plan|policies)\b/iu,
    /\b(?:emnebeskrivelse|semesterplan|pensumliste)\b/iu,
  ],
  lectures: [/\blectures?\b/iu, /\bslides?\b/iu, /\b(?:forelesning|forelesninger)\b/iu],
  notes: [
    /\b(?:study|class|lecture|handwritten|reading|revision) notes?\b/iu,
    /\bnotater\b/iu,
    /\bnotes\b/iu,
  ],
  readings: [
    /\b(?:textbook|reading|readings)\b/iu,
    /\b(?:journal|doi|bibliography)\b/iu,
    /\b(?:abstract|references)\b/iu,
  ],
  exercises: [
    /\b(?:assignment|homework|problem set|exercise sheet|worksheet|lab assignment)\b/iu,
    /\b(?:exercises|øving|oving|oppgaver)\b/iu,
    /\b(?:submit|submission|due date)\b/iu,
  ],
  solutions: [
    /\b(?:answer key|marking scheme|(?:worked|model|official) solutions?|(?:assignment|exam|exercise|problem set) solutions?|solutions? (?:to|for) (?:the )?(?:assignment|exam|exercise|problem set))\b/iu,
    /\b(?:worked examples?|worked answers?)\b/iu,
    /\b(?:løsningsforslag|losningsforslag|fasit)\b/iu,
  ],
  exams: [
    /\b(?:exam|examination|midterm|final exam|practice test)\b/iu,
    /\b(?:eksamen|kontinuasjonseksamen)\b/iu,
    /\b(?:time allowed|permitted aids|exam duration)\b/iu,
  ],
};
const normalize = (value) =>
  String(value || '')
    .normalize('NFKC')
    .replace(/[_-]+/gu, ' ')
    .replace(/\s+/gu, ' ')
    .trim();

function cleanTopic(value) {
  const text = normalize(value)
    .replace(/^#+\s*/u, '')
    .replace(
      /^(?:(?:lecture|chapter|section|week|forelesning|kapittel|(?:study|lecture|handwritten) notes?|notes?|assignment|exercise|problem set|final exam|exam)\b\s*\d*(?:[.:]\d+)*\s*[:.\-–—]?\s*)/iu,
      ''
    )
    .replace(/^\d+(?:\.\d+)*[.)]?\s+/u, '')
    .trim();
  if (text.length < 5 || text.length > 90 || !/\p{L}{3}/u.test(text)) return null;
  const substantive = text
    .replace(/\b[A-ZÆØÅ]{2,}\s?\d{3,}[A-Z]?\b/gu, '')
    .replace(
      /\b(?:lecture|lectures|slides|notes|study|class|course|document|assignment|exam)\b/giu,
      ''
    )
    .replace(/[\d\s/#:._-]/gu, '');
  if (substantive.length < 3) return null;
  if (/https?:|@|[{}=<>]|\?$/u.test(text) || text.split(/\s+/u).length > 12) return null;
  if (
    /^(?:page|side|copyright|contents|table of contents|references|abstract|introduction|conclusion|overview|solutions?|answer key|exercises?|assignments?|homework|notes?|lecture notes?|syllabus|course information|learning objectives|problem\s*\d*|question\s*\d*)\b[\s\d.:]*$/iu.test(
      text
    )
  )
    return null;
  if (
    /^(?:calculate|compute|show|prove|find|consider|submit|deadline|due|author|university|department)\b/iu.test(
      text
    )
  )
    return null;
  return text;
}

function headingCandidates(pages) {
  const candidates = [];
  for (const [pageIndex, page] of pages.entries()) {
    if (page.extractionMethod === 'ocr' && Number(page.ocrConfidence) < 0.55) continue;
    const lines = String(page.text || '')
      .slice(0, 6000)
      .split('\n')
      .map((line) => line.trim())
      .filter(Boolean);
    for (const [lineIndex, line] of lines.slice(0, 32).entries()) {
      // Markdown headings, numbered headings and short opening lines carry stronger
      // evidence than incidental terminology in a paragraph or a reference list.
      const explicit =
        /^#{1,6}\s+|^(?:lecture|chapter|section|week|forelesning|kapittel)\s*\d+\b/iu.test(line);
      if (!explicit && (lineIndex > 1 || /[.!?;]$/u.test(line))) continue;
      const topic = cleanTopic(line);
      if (topic)
        candidates.push({
          text: line.slice(0, 160),
          topic,
          score: (explicit ? 4 : 1) + (pageIndex === 0 ? 2 : 0),
        });
    }
  }
  return candidates;
}

export function analyzeMaterial({ name = '', title = '', kind = '', pages = [] } = {}) {
  const ext = extname(name).slice(1).toLowerCase();
  // Distributed samples avoid letting a cover or a single appended answer sheet
  // determine a whole file. Bound analysis independently of document length.
  const positions = [
    ...new Set([0, 1, 2, 3, Math.floor(pages.length / 2), pages.length - 1]),
  ].filter((i) => pages[i]);
  for (const [i, page] of pages.entries()) {
    if (positions.length >= 12) break;
    if (['ocr', 'mixed'].includes(page.extractionMethod) && !positions.includes(i))
      positions.push(i);
  }
  const sampled = positions.map((i) => pages[i]);
  const reliable = sampled.filter(
    (page) => page.extractionMethod !== 'ocr' || Number(page.ocrConfidence ?? 1) >= 0.55
  );
  const body = reliable.map((page) => String(page.text || '').slice(0, 6000)).join('\n');
  const headings = headingCandidates(reliable);
  const headerText = reliable
    .slice(0, 2)
    .map((page) =>
      String(page.text || '')
        .slice(0, 1000)
        .split('\n')
        .slice(0, 3)
        .filter((line) => line.length <= 160)
        .join('\n')
    )
    .join('\n');
  const fileLabel = normalize(`${title} ${name.replace(/\.[^.]+$/u, '')}`);
  const ocrPages = sampled.filter(
    (p) => p.extractionMethod === 'ocr' || p.extractionMethod === 'mixed'
  );
  const textPages = sampled.filter((p) => p.text?.trim() && p.extractionMethod !== 'ocr');
  const extractionMethod = ocrPages.length
    ? textPages.length
      ? 'mixed'
      : 'ocr'
    : body.trim()
      ? 'text'
      : 'none';
  const scores = new Map();
  for (const [category, patterns] of Object.entries(cues)) {
    let content = 0,
      metadata = 0;
    for (const pattern of patterns) {
      if (pattern.test(headerText)) content += 5;
      else if (headings.some((heading) => pattern.test(heading.text))) content += 3;
      else if (pattern.test(body)) content += 1;
      if (pattern.test(fileLabel)) metadata += 2;
    }
    scores.set(category, { content, metadata, score: content + metadata });
  }
  if (
    scores.get('solutions').content > 0 &&
    /\b(?:(?:exam|assignment|exercise|problem set) solutions?|solutions? (?:to|for))\b/iu.test(
      headerText
    )
  ) {
    const solutions = scores.get('solutions');
    solutions.content += 4;
    solutions.score += 4;
  }
  const codeExtensions = new Set([
    'ipynb',
    'py',
    'r',
    'jl',
    'js',
    'ts',
    'java',
    'c',
    'cpp',
    'h',
    'm',
    'sh',
    'sql',
  ]);
  const structuredData = new Set(['csv', 'tsv', 'json', 'yaml', 'yml', 'xml', 'xlsx']);
  if (codeExtensions.has(ext) || kind === 'notebook')
    scores.set('code', { content: 100, metadata: 0, score: 100 });
  if (structuredData.has(ext)) scores.set('data', { content: 100, metadata: 0, score: 100 });
  // A logo-like filename alone must not hide a photograph of study notes.
  if (
    ['png', 'jpg', 'jpeg', 'gif', 'svg', 'webp'].includes(ext) &&
    !body.trim() &&
    /\b(?:icon|logo|banner|footer|header)\b/iu.test(fileLabel)
  )
    scores.set('assets', { content: 0, metadata: 4, score: 4 });
  const ranked = [...scores].sort((a, b) => b[1].score - a[1].score);
  const [first, evidence] = ranked[0],
    second = ranked[1]?.[1].score || 0;
  // Multiple weak signals are insufficient when the strongest categories tie.
  const decisive = evidence.score >= 2 && (evidence.score - second >= 2 || second === 0);
  const categoryID = decisive ? first : 'documents';
  const confidence =
    !decisive || evidence.content === 0
      ? 'low'
      : evidence.score >= 7 && evidence.score - second >= 3
        ? 'high'
        : 'medium';
  const topic = headings
    .sort((a, b) => b.score - a.score)
    .find(
      (heading) =>
        (!['code', 'data'].includes(categoryID) || /^#/u.test(heading.text)) &&
        !Object.values(cues).some((patterns) =>
          patterns.some(
            (pattern) => pattern.test(heading.topic) && heading.topic.split(/\s+/u).length <= 3
          )
        )
    )?.topic;
  return {
    version: materialAnalysisVersion,
    categoryID,
    categoryTitle: labels.get(categoryID),
    classificationConfidence: confidence,
    classificationBasis: !decisive
      ? body.trim()
        ? 'Mixed or insufficient content evidence'
        : 'Content not yet readable'
      : evidence.content
        ? codeExtensions.has(ext) || structuredData.has(ext)
          ? 'File format'
          : extractionMethod === 'ocr'
            ? 'Locally recognized text and headings'
            : 'Document text and headings'
        : 'Filename only; content unverified',
    ...(topic ? { topic } : {}),
    extractionMethod,
  };
}

export function materialClassification(document, reference) {
  const analysis =
    document?.materialAnalysis?.version === materialAnalysisVersion
      ? document.materialAnalysis
      : analyzeMaterial({
          name: document?.fileName || reference?.fileName || '',
          title: document?.title || reference?.title || '',
          kind: document?.kind,
        });
  if (reference?.kind === 'assignments')
    return {
      ...analysis,
      categoryID: 'exercises',
      categoryTitle: labels.get('exercises'),
      classificationConfidence: 'high',
      classificationBasis: 'Canvas assignment',
    };
  return analysis;
}
