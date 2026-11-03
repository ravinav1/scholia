import hljs from 'highlight.js';
import katex from 'katex';
import MarkdownIt from 'markdown-it';
import { escapeHtml } from './html-escape.js';
export { escapeHtml } from './html-escape.js';

// Streaming changes the message suffix, while most math and code blocks stay
// identical. Reuse their expensive output without retaining an unbounded chat.
function renderCache(maxCharacters, maxEntries) {
  const entries = new Map();
  let characters = 0;
  return (key, render) => {
    const existing = entries.get(key);
    if (existing !== undefined) {
      entries.delete(key);
      entries.set(key, existing);
      return existing;
    }
    const result = render();
    const size = key.length + result.length;
    if (size <= maxCharacters) {
      while (entries.size && (characters + size > maxCharacters || entries.size >= maxEntries)) {
        const oldest = entries.keys().next().value;
        characters -= oldest.length + entries.get(oldest).length;
        entries.delete(oldest);
      }
      entries.set(key, result);
      characters += size;
    }
    return result;
  };
}

const cachedMath = renderCache(1_000_000, 256);
const cachedCode = renderCache(500_000, 64);
const cachedMarkdown = renderCache(2_000_000, 64);

function stripOuterMathDelimiters(value) {
  let source = String(value || '').trim();
  const pairs = [['$$', '$$'], ['$', '$'], ['\\[', '\\]'], ['\\(', '\\)']];
  let changed = true;
  while (changed) {
    changed = false;
    for (const [opening, closing] of pairs) {
      if (source.startsWith(opening) && source.endsWith(closing)
          && source.length > opening.length + closing.length) {
        source = source.slice(opening.length, -closing.length).trim();
        changed = true;
        break;
      }
    }
  }
  return source.replace(/[\u200B-\u200D\u2060\uFEFF]/g, '');
}

function collapseRedundantTextGroups(value) {
  let source = value;
  let previous = '';
  while (source !== previous) {
    previous = source;
    source = source.replace(
      /\\(text|textrm|textsf|texttt|mathrm|mathbf|mathit|operatorname)\{\{([^{}]*)\}\}/g,
      '\\$1{$2}'
    );
  }
  return source;
}

function balanceMathBraces(value) {
  let output = '';
  let depth = 0;
  for (let index = 0; index < value.length; index += 1) {
    const character = value[index];
    if ((character === '{' || character === '}') && isEscaped(value, index)) {
      output += character;
    } else if (character === '{') {
      depth += 1;
      output += character;
    } else if (character === '}') {
      if (depth > 0) {
        depth -= 1;
        output += character;
      }
    } else {
      output += character;
    }
  }
  return output + '}'.repeat(depth);
}

export function normalizedMathCandidates(tex) {
  const stripped = stripOuterMathDelimiters(tex);
  const collapsed = collapseRedundantTextGroups(stripped);
  return [...new Set([
    stripped,
    collapsed,
    balanceMathBraces(stripped),
    balanceMathBraces(collapsed)
  ].map((candidate) => candidate.trim()).filter(Boolean))];
}

function readableMathFallback(tex) {
  return stripOuterMathDelimiters(tex)
    .replace(/\\(?:text|textrm|textsf|texttt|mathrm|mathbf|mathit|operatorname)\{([^{}]*)\}/g, '$1')
    .replace(/\\(?:times|cdot)\b/g, '·')
    .replace(/\\leq?\b/g, '≤')
    .replace(/\\geq?\b/g, '≥')
    .replace(/\\neq?\b/g, '≠')
    .replace(/\\infty\b/g, '∞')
    .replace(/\\(?:quad|qquad)\b/g, ' ')
    .replace(/\\[,;!]/g, ' ')
    .replace(/[{}]/g, '');
}

function renderMath(tex, displayMode) {
  return cachedMath(`${displayMode ? 'display' : 'inline'}:${tex}`, () => renderMathUncached(tex, displayMode));
}

function renderMathUncached(tex, displayMode) {
  for (const candidate of normalizedMathCandidates(tex)) {
    try {
      return katex.renderToString(candidate, {
        displayMode,
        throwOnError: true,
        strict: 'ignore',
        trust: false,
        output: 'htmlAndMathml'
      });
    } catch {}
  }
  return `<span class="scholia-math-fallback" role="img" aria-label="Math expression">${escapeHtml(readableMathFallback(tex))}</span>`;
}

function isEscaped(source, index) {
  let slashes = 0;
  for (let cursor = index - 1; cursor >= 0 && source[cursor] === '\\'; cursor -= 1) slashes += 1;
  return slashes % 2 === 1;
}

function mathInlineRule(state, silent) {
  const start = state.pos;
  const parenthesized = state.src.startsWith('\\(', start) && !isEscaped(state.src, start);
  if (parenthesized) {
    for (let cursor = start + 2; cursor < state.posMax - 1; cursor += 1) {
      if (!state.src.startsWith('\\)', cursor) || isEscaped(state.src, cursor)) continue;
      if (!silent) {
        const token = state.push('scholia_math_inline', 'math', 0);
        token.content = state.src.slice(start + 2, cursor);
        token.markup = '\\(\\)';
      }
      state.pos = cursor + 2;
      return true;
    }
    return false;
  }

  if (state.src[start] !== '$' || state.src[start + 1] === '$'
      || isEscaped(state.src, start) || start + 2 >= state.posMax
      || /\s/.test(state.src[start + 1])) return false;

  for (let cursor = start + 1; cursor < state.posMax; cursor += 1) {
    if (state.src[cursor] !== '$' || isEscaped(state.src, cursor)) continue;
    if (state.src[cursor + 1] === '$' || /\s/.test(state.src[cursor - 1])) continue;
    if (!silent) {
      const token = state.push('scholia_math_inline', 'math', 0);
      token.content = state.src.slice(start + 1, cursor);
      token.markup = '$';
    }
    state.pos = cursor + 1;
    return true;
  }
  return false;
}

function closingBracketMathIndex(line) {
  const trimmed = line.trimEnd();
  return trimmed.endsWith('\\]') && !isEscaped(trimmed, trimmed.length - 2)
    ? trimmed.length - 2
    : -1;
}

function bracketMathBlockRule(state, startLine, endLine, silent) {
  const start = state.bMarks[startLine] + state.tShift[startLine];
  const maximum = state.eMarks[startLine];
  const openingLine = state.src.slice(start, maximum);
  if (!openingLine.startsWith('\\[') || isEscaped(openingLine, 0)) return false;
  if (silent) return true;

  const lines = [];
  const openingRemainder = openingLine.slice(2);
  const sameLineClose = closingBracketMathIndex(openingRemainder);
  let nextLine = startLine + 1;
  if (sameLineClose >= 0) {
    lines.push(openingRemainder.slice(0, sameLineClose));
  } else {
    let foundClosingFence = false;
    if (openingRemainder) lines.push(openingRemainder);
    for (let line = startLine + 1; line < endLine; line += 1) {
      const content = state.getLines(line, line + 1, state.tShift[line], false).replace(/\n$/, '');
      const closingIndex = closingBracketMathIndex(content);
      if (closingIndex >= 0) {
        lines.push(content.slice(0, closingIndex));
        nextLine = line + 1;
        foundClosingFence = true;
        break;
      }
      lines.push(content);
      nextLine = line + 1;
    }
    if (!foundClosingFence) return false;
  }

  const token = state.push('scholia_math_block', 'math', 0);
  token.block = true;
  token.content = lines.join('\n').trim();
  token.map = [startLine, nextLine];
  token.markup = '\\[\\]';
  state.line = nextLine;
  return true;
}

function closingDisplayMathIndex(line) {
  const trimmed = line.trimEnd();
  return trimmed.endsWith('$$') && !isEscaped(trimmed, trimmed.length - 2)
    ? trimmed.length - 2
    : -1;
}

function mathBlockRule(state, startLine, endLine, silent) {
  const start = state.bMarks[startLine] + state.tShift[startLine];
  const maximum = state.eMarks[startLine];
  const openingLine = state.src.slice(start, maximum);
  if (!openingLine.startsWith('$$') || openingLine.startsWith('$$$')) return false;
  if (silent) return true;

  const lines = [];
  const openingRemainder = openingLine.slice(2);
  const sameLineClose = closingDisplayMathIndex(openingRemainder);
  let nextLine = startLine + 1;
  if (sameLineClose >= 0) {
    lines.push(openingRemainder.slice(0, sameLineClose));
  } else {
    if (openingRemainder) lines.push(openingRemainder);
    let foundClosingFence = false;
    for (let line = startLine + 1; line < endLine; line += 1) {
      const content = state.getLines(line, line + 1, state.tShift[line], false).replace(/\n$/, '');
      const closingIndex = closingDisplayMathIndex(content);
      if (closingIndex >= 0) {
        lines.push(content.slice(0, closingIndex));
        nextLine = line + 1;
        foundClosingFence = true;
        break;
      }
      lines.push(content);
      nextLine = line + 1;
    }
    if (!foundClosingFence) nextLine = endLine;
  }

  const token = state.push('scholia_math_block', 'math', 0);
  token.block = true;
  token.content = lines.join('\n').trim();
  token.map = [startLine, nextLine];
  token.markup = '$$';
  state.line = nextLine;
  return true;
}

function safeLink(value) {
  const link = String(value || '').trim();
  if (link.startsWith('#')) return true;
  try {
    return ['http:', 'https:', 'mailto:'].includes(new URL(link).protocol.toLowerCase());
  } catch {
    return false;
  }
}

function codeLanguage(info) {
  return String(info || '')
    .trim()
    .split(/\s+/, 1)[0]
    .replace(/[^a-z0-9_+#.-]/gi, '')
    .slice(0, 40)
    .toLowerCase();
}

function highlightedCode(source, language) {
  if (!language || !hljs.getLanguage(language)) return escapeHtml(source);
  try {
    return cachedCode(`${language}:${source}`, () => hljs.highlight(source, { language, ignoreIllegals: true }).value);
  } catch {
    return escapeHtml(source);
  }
}

function escapeProtectedTablePipes(line) {
  let output = '';
  let codeFenceLength = 0;
  let mathFenceLength = 0;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (character === '\\' && index + 1 < line.length) {
      output += character + line[index + 1];
      index += 1;
      continue;
    }
    if (character === '`') {
      let runLength = 1;
      while (line[index + runLength] === '`') runLength += 1;
      if (!codeFenceLength) codeFenceLength = runLength;
      else if (codeFenceLength === runLength) codeFenceLength = 0;
      output += '`'.repeat(runLength);
      index += runLength - 1;
      continue;
    }
    if (character === '$' && !codeFenceLength) {
      let runLength = 1;
      while (line[index + runLength] === '$') runLength += 1;
      if (!mathFenceLength) mathFenceLength = runLength;
      else if (mathFenceLength === runLength) mathFenceLength = 0;
      output += '$'.repeat(runLength);
      index += runLength - 1;
      continue;
    }
    if (character === '|' && (codeFenceLength || mathFenceLength)) output += '\\|';
    else output += character;
  }
  return output;
}

function isTableDelimiter(line) {
  let source = String(line || '').trim();
  if (source.startsWith('|')) source = source.slice(1);
  if (source.endsWith('|') && !isEscaped(source, source.length - 1)) source = source.slice(0, -1);
  const cells = source.split('|').map((cell) => cell.trim());
  return cells.length > 0 && cells.every((cell) => /^:?-{3,}:?$/.test(cell));
}

function normalizeTablePipes(source) {
  const lines = source.split('\n');
  const literalLines = new Set();
  let fence = null;

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (fence) {
      literalLines.add(index);
      const closing = new RegExp(`^ {0,3}${fence.character}{${fence.length},}\\s*$`);
      if (closing.test(line)) fence = null;
      continue;
    }

    const opening = /^ {0,3}(`{3,}|~{3,})/.exec(line);
    if (opening) {
      fence = { character: opening[1][0], length: opening[1].length };
      literalLines.add(index);
      continue;
    }
    if (/^(?: {4}|\t)/.test(line)) literalLines.add(index);
  }

  for (let index = 1; index < lines.length; index += 1) {
    if (literalLines.has(index)
        || literalLines.has(index - 1)
        || !isTableDelimiter(lines[index])
        || !lines[index - 1].includes('|')) continue;
    lines[index - 1] = escapeProtectedTablePipes(lines[index - 1]);
    for (let row = index + 1;
      row < lines.length
        && !literalLines.has(row)
        && lines[row].trim()
        && lines[row].includes('|');
      row += 1) {
      lines[row] = escapeProtectedTablePipes(lines[row]);
    }
  }
  return lines.join('\n');
}

function installTaskListRule(markdown) {
  markdown.core.ruler.after('inline', 'scholia_task_lists', (state) => {
    for (let index = 0; index < state.tokens.length; index += 1) {
      const inline = state.tokens[index];
      if (inline.type !== 'inline' || !inline.children?.length) continue;
      const textIndex = inline.children.findIndex((child) => child.type === 'text' && child.content.length);
      if (textIndex < 0) continue;
      const match = /^\[([ xX])\]\s+/.exec(inline.children[textIndex].content);
      if (!match) continue;

      let listItem;
      for (let cursor = index - 1; cursor >= 0; cursor -= 1) {
        if (state.tokens[cursor].type === 'list_item_close') break;
        if (state.tokens[cursor].type === 'list_item_open') {
          listItem = state.tokens[cursor];
          break;
        }
      }
      if (!listItem) continue;

      const completed = match[1].toLowerCase() === 'x';
      inline.children[textIndex].content = inline.children[textIndex].content.slice(match[0].length);
      const marker = new state.Token('html_inline', '', 0);
      marker.content = `<span class="scholia-task-marker" role="img" aria-label="${completed ? 'Completed' : 'Incomplete'} task">${completed ? '☑' : '☐'}</span>`;
      inline.children.splice(textIndex, 0, marker);
      listItem.attrJoin('class', 'scholia-task-item');
    }
  });
}

function createRenderer() {
  const markdown = new MarkdownIt({
    html: false,
    breaks: false,
    linkify: true,
    typographer: true
  });
  markdown.validateLink = safeLink;
  markdown.inline.ruler.before('escape', 'scholia_math_inline', mathInlineRule);
  markdown.block.ruler.after('blockquote', 'scholia_math_block', mathBlockRule, {
    alt: ['paragraph', 'reference', 'blockquote', 'list']
  });
  markdown.block.ruler.after('scholia_math_block', 'scholia_math_bracket_block', bracketMathBlockRule, {
    alt: ['paragraph', 'reference', 'blockquote', 'list']
  });
  installTaskListRule(markdown);

  markdown.renderer.rules.scholia_math_inline = (tokens, index) => renderMath(tokens[index].content, false);
  markdown.renderer.rules.scholia_math_block = (tokens, index) => (
    `<div class="scholia-display-math">${renderMath(tokens[index].content, true)}</div>\n`
  );
  markdown.renderer.rules.fence = (tokens, index) => {
    const token = tokens[index];
    const language = codeLanguage(token.info);
    const label = escapeHtml(language || 'plain text');
    const className = language ? `hljs language-${escapeHtml(language)}` : 'hljs';
    return `<div class="scholia-code"><div class="scholia-code__bar"><span>${label}</span><button type="button" data-copy-code aria-label="Copy code block">Copy</button></div><pre><code class="${className}">${highlightedCode(token.content.replace(/\n$/, ''), language)}</code></pre></div>\n`;
  };
  markdown.renderer.rules.code_block = (tokens, index) => {
    const content = tokens[index].content.replace(/\n$/, '');
    return `<div class="scholia-code"><div class="scholia-code__bar"><span>plain text</span><button type="button" data-copy-code aria-label="Copy code block">Copy</button></div><pre><code class="hljs">${escapeHtml(content)}</code></pre></div>\n`;
  };
  markdown.renderer.rules.image = (tokens, index) => {
    const label = tokens[index].content.trim();
    const suffix = label ? `: ${escapeHtml(label)}` : '';
    return `<span class="scholia-image-reference" role="img" aria-label="External image omitted">Image${suffix}</span>`;
  };

  const defaultLinkOpen = markdown.renderer.rules.link_open
    || ((tokens, index, options, environment, renderer) => renderer.renderToken(tokens, index, options));
  markdown.renderer.rules.link_open = (tokens, index, options, environment, renderer) => {
    const href = tokens[index].attrGet('href') || '';
    if (/^https?:/i.test(href)) {
      tokens[index].attrSet('target', '_blank');
      tokens[index].attrSet('rel', 'noopener noreferrer');
    }
    return defaultLinkOpen(tokens, index, options, environment, renderer);
  };

  markdown.renderer.rules.table_open = () => '<div class="scholia-table-wrap" role="region" aria-label="Scrollable table" tabindex="0"><table>\n';
  markdown.renderer.rules.table_close = () => '</table></div>\n';
  const tableCellOpen = (tokens, index, options, environment, renderer) => {
    const alignment = /text-align:\s*(left|center|right)/i.exec(tokens[index].attrGet('style') || '')?.[1]?.toLowerCase();
    if (alignment && alignment !== 'left') tokens[index].attrJoin('class', `scholia-table-cell--${alignment}`);
    return renderer.renderToken(tokens, index, options);
  };
  markdown.renderer.rules.th_open = tableCellOpen;
  markdown.renderer.rules.td_open = tableCellOpen;

  return markdown;
}

const renderer = createRenderer();

export function renderMarkdown(value, { cache = true } = {}) {
  const normalized = String(value ?? '')
    .replace(/\r\n?/g, '\n')
    .replace(/^(?:[ \t]*\n)+/, '')
    .replace(/(?:\n[ \t]*)+$/, '');
  if (!normalized.trim()) return '';
  const render = () => renderer.render(normalizeTablePipes(normalized));
  return cache ? cachedMarkdown(normalized, render) : render();
}

const REASONING_ACTIVITY_MAX_LENGTH = 72;

function boundedActivityLabel(value) {
  const label = String(value || '').replace(/\s+/g, ' ').trim();
  if (label.length <= REASONING_ACTIVITY_MAX_LENGTH) return label;
  return `${label.slice(0, REASONING_ACTIVITY_MAX_LENGTH - 1).trimEnd()}…`;
}

function reasoningActivityCandidate(value) {
  const plain = String(value || '')
    .replace(/```[\s\S]*?```/g, ' reviewing code ')
    .replace(/`([^`]+)`/g, '$1')
    .replace(/!??\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/<[^>]*>/g, ' ')
    .replace(/^\s{0,3}(?:#{1,6}|[-*+]|\d+[.)])\s+/gm, '')
    .replace(/[>*_~]/g, ' ')
    .replace(/[\t\f\v ]+/g, ' ')
    .trim();
  if (!plain) return '';
  const segments = plain
    .split(/\n+|(?<=[.!?;:])\s+/u)
    .map((segment) => segment.replace(/\s+/g, ' ').trim())
    .filter(Boolean);
  return (segments.at(-1) || plain).replace(/[.!?;:]+$/g, '').trim();
}

export function reasoningActivityLabel(value) {
  let activity = reasoningActivityCandidate(value);
  if (!activity) return 'Working through the problem';

  if (/^(?:the\s+)?user(?:'s)?\s+(?:answer|approach|solution)?\s*(?:is|looks|seems)\s+(?:fully\s+)?correct\b/i.test(activity)) {
    return 'Your approach is correct';
  }
  if (/^(?:the\s+)?(?:user(?:'s)?\s+)?(?:answer|approach|solution)\s+(?:is|looks|seems)\s+(?:incorrect|wrong)\b/i.test(activity)) {
    return 'Checking a possible mistake';
  }

  activity = activity
    .replace(/^(?:so|now|next|then|okay|ok|well)[,:-]?\s+/i, '')
    .replace(/^(?:we|i)\s+(?:(?:now\s+)?(?:need|want|have|should|will|can|must)(?:\s+to)?|(?:am|'m)\s+going\s+to)\s+/i, '')
    .replace(/^(?:need|want|have|should|must)\s+to\s+/i, '')
    .replace(/^let(?:'s| us)\s+/i, '')
    .trim();

  const actions = [
    [/^(?:check(?:ing)?|verif(?:y|ying)|validat(?:e|ing)|confirm(?:ing)?)\b\s*/i, 'Checking'],
    [/^(?:calculat(?:e|ing)|comput(?:e|ing)|evaluat(?:e|ing))\b\s*/i, 'Calculating'],
    [/^(?:compar(?:e|ing)|contrast(?:ing)?)\b\s*/i, 'Comparing'],
    [/^(?:analyz(?:e|ing)|examin(?:e|ing)|inspect(?:ing)?|review(?:ing)?)\b\s*/i, 'Analyzing'],
    [/^(?:deriv(?:e|ing)|deduc(?:e|ing))\b\s*/i, 'Deriving'],
    [/^(?:solv(?:e|ing)|simplif(?:y|ying)|integrat(?:e|ing)|differentiat(?:e|ing))\b\s*/i, 'Solving'],
    [/^(?:find(?:ing)?|determin(?:e|ing)|identif(?:y|ying))\b\s*/i, 'Finding'],
    [/^(?:read(?:ing)?|search(?:ing)?|look(?:ing)?\s+up)\b\s*/i, 'Reading'],
    [/^(?:explain(?:ing)?|describ(?:e|ing)|clarif(?:y|ying))\b\s*/i, 'Explaining'],
    [/^(?:summariz(?:e|ing)|condens(?:e|ing))\b\s*/i, 'Summarizing'],
    [/^(?:plan(?:ning)?|organiz(?:e|ing)|structur(?:e|ing)|compos(?:e|ing)|formulat(?:e|ing)|answer(?:ing)?)\b\s*/i, 'Preparing the answer']
  ];
  for (const [pattern, label] of actions) {
    if (!pattern.test(activity)) continue;
    const subject = activity.replace(pattern, '').replace(/^(?:to\s+)?/i, '').trim();
    return boundedActivityLabel(subject && label !== 'Preparing the answer' ? `${label} ${subject}` : label);
  }

  const readable = activity.replace(/^that\s+/i, '').trim();
  if (readable.length < 4) return 'Working through the problem';
  return boundedActivityLabel(`${readable[0].toUpperCase()}${readable.slice(1)}`);
}

export function renderReasoning(value, { streaming = false } = {}) {
  const reasoning = String(value || '').trim();
  if (!reasoning) return '';
  const activity = reasoningActivityLabel(reasoning);
  return `<details class="scholia-reasoning"><summary><span class="scholia-reasoning__activity">${escapeHtml(activity)}</span><span class="scholia-reasoning__hint">${streaming ? 'live · provided by model' : 'provided by model'}</span></summary><div class="scholia-reasoning__body">${renderMarkdown(reasoning)}</div></details>`;
}

export function addActivity(message, event) {
  if (!event?.title) return;
  const entry = { title: String(event.title).slice(0, 180), detail: String(event.detail || '').slice(0, 2000), timestamp: event.timestamp || Date.now() };
  if (message.activity?.at(-1)?.title === entry.title && message.activity?.at(-1)?.detail === entry.detail) return;
  message.activity = [...(message.activity || []), entry].slice(-80);
}

export function renderActivity(events = []) {
  if (!Array.isArray(events) || !events.length) return '';
  return `<details class="chat-activity" data-detail="activity"><summary>Activity · ${events.length} <span>${escapeHtml(events.at(-1)?.title || '')}</span></summary><ol>${events.slice(-80).map((event) => `<li><strong>${escapeHtml(event.title)}</strong>${event.detail ? `<pre>${escapeHtml(event.detail)}</pre>` : ''}</li>`).join('')}</ol></details>`;
}

export function bindActivityDisclosure(root, message) {
  const details = root.querySelector('.chat-activity');
  if (!details) return;
  details.open = message.activityExpanded === true;
  details.addEventListener('toggle', () => { message.activityExpanded = details.open; });
}
