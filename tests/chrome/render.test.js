import test from 'node:test';
import assert from 'node:assert/strict';
import { reasoningActivityLabel, renderMarkdown, renderReasoning } from '../../apps/chrome/src/render.js';

test('renderer escapes raw model HTML', () => {
  const html = renderMarkdown('<img src=x onerror=alert(1)> **safe**');
  assert.doesNotMatch(html, /<img/);
  assert.match(html, /&lt;img/);
  assert.match(html, /<strong>safe<\/strong>/);
});

test('provider reasoning is shown only when supplied and remains safely rendered', () => {
  assert.equal(renderReasoning(''), '');
  const html = renderReasoning('Checked **two** cases. <script>alert(1)</script>');
  assert.match(html, /<details class="scholia-reasoning">/);
  assert.match(html, /<strong>two<\/strong>/);
  assert.doesNotMatch(html, /<script>/);
  const live = renderReasoning('Checking the source.', { streaming: true });
  assert.match(live, /<details class="scholia-reasoning">/);
  assert.doesNotMatch(live, /<details class="scholia-reasoning" open>/);
  assert.match(live, /live · provided by model/);
});

test('reasoning headers track the model current activity', () => {
  assert.equal(
    reasoningActivityLabel('We need to calculate the determinant of the matrix.'),
    'Calculating the determinant of the matrix'
  );
  assert.equal(
    reasoningActivityLabel('First I will inspect the premise. Now I should verify whether x is positive.'),
    'Checking whether x is positive'
  );
  assert.equal(reasoningActivityLabel('The user is correct.'), 'Your approach is correct');
  assert.equal(
    reasoningActivityLabel('Inspecting the definitions\nCalculating the eigenvalues'),
    'Calculating the eigenvalues'
  );
  assert.notEqual(
    reasoningActivityLabel('Now I should compare the two definitions.'),
    reasoningActivityLabel('Now I should calculate the eigenvalues.')
  );

  const html = renderReasoning('We need to analyze <img src=x onerror=alert(1)> the proof.', { streaming: true });
  assert.match(html, /class="scholia-reasoning__activity">Analyzing the proof</);
  assert.doesNotMatch(html, /<img/);
});

test('renderer produces local KaTeX markup and code blocks', () => {
  const html = renderMarkdown('Energy is $E = mc^2$.\n\n```js\nconst x = 1;\n```');
  assert.match(html, /class="katex"/);
  assert.match(html, /data-copy-code/);
  assert.match(html, /class="hljs language-js"/);
  assert.match(html, /hljs-keyword">const/);
  assert.match(html, /hljs-number">1/);
});

test('renderer produces semantic, aligned tables inside a scroll container', () => {
  const html = renderMarkdown(`
| Concept | Meaning | Score |
| :--- | :---: | ---: |
| **Recall** | Retrieve without notes | 8 |
| Transfer | Use \`x | y\` safely | 13 |
| Cardinality | $|R|$ rows | 21 |
  `);

  assert.match(html, /class="scholia-table-wrap"/);
  assert.match(html, /<table>\s*<thead>\s*<tr>/);
  assert.match(html, /<th[^>]*>Concept<\/th>/);
  assert.match(html, /<th[^>]*class="scholia-table-cell--center"[^>]*>Meaning<\/th>/);
  assert.match(html, /<td[^>]*class="scholia-table-cell--right"[^>]*>13<\/td>/);
  assert.match(html, /<strong>Recall<\/strong>/);
  assert.match(html, /<code>x \| y<\/code>/);
  assert.match(html, /<td[^>]*><span class="katex"/);
  assert.match(html, /21<\/td>/);
});

test('renderer keeps escaped pipes in table cells and escapes raw table HTML', () => {
  const html = renderMarkdown('| Input | Output |\n| --- | --- |\n| a \\| b | <img src=x> |');

  assert.match(html, /<td>a \| b<\/td>/);
  assert.match(html, /<td>&lt;img src=x&gt;<\/td>/);
  assert.doesNotMatch(html, /<img/);
});

test('renderer does not treat ordinary pipe-separated prose as a table', () => {
  const html = renderMarkdown('alpha | beta\nthis is still prose');
  assert.doesNotMatch(html, /<table>/);
  assert.match(html, /<p>alpha \| beta\s+this is still prose<\/p>/);
});

test('renderer keeps a math-heavy join table separate from following prose and SQL', () => {
  const html = renderMarkdown(`Her er join-typene med vanlige symboler.

| Join-type | Symbol | Eksempel | Betydning |
|---|---:|---|---|
| Natural join | $\\bowtie$ | $R \\bowtie S$ | Matcher attributter med samme navn |
| Theta join | $\\bowtie_\\theta$ | $R \\bowtie_{R.a>S.b} S$ | Join med en vilkårlig betingelse |

For eksempel:

\`\`\`sql
SELECT * FROM Employee JOIN Department;
\`\`\``);

  assert.match(html, /^<p>Her er join-typene/);
  assert.equal((html.match(/<table>/g) || []).length, 1);
  assert.match(html, /class="katex"/);
  assert.match(html, /<\/table><\/div>\s*<p>For eksempel:<\/p>\s*<div class="scholia-code">/);
  assert.match(html, /<span>sql<\/span>/);
});

test('renderer supports nested GFM structure and task lists', () => {
  const html = renderMarkdown(`# Heading

1. First
   - Nested **bold** and *emphasis*
   - [x] Finished
2. Second

> A quote with ~~obsolete~~ text.

---
`);

  assert.match(html, /<h1>Heading<\/h1>/);
  assert.match(html, /<ol>\s*<li>First\s*<ul>/);
  assert.match(html, /<strong>bold<\/strong>/);
  assert.match(html, /<em>emphasis<\/em>/);
  assert.match(html, /class="scholia-task-marker"[^>]*>☑<\/span>/);
  assert.match(html, /<blockquote>\s*<p>A quote with <s>obsolete<\/s> text\.<\/p>/);
  assert.match(html, /<hr>/);
});

test('renderer allows safe links while blocking active content and remote images', () => {
  const html = renderMarkdown('[Docs](https://example.com) [unsafe](javascript:alert(1)) ![tracker](https://example.com/pixel.png) <img src=x onerror=alert(1)>');

  assert.match(html, /href="https:\/\/example\.com" target="_blank" rel="noopener noreferrer"/);
  assert.doesNotMatch(html, /href="javascript:/);
  assert.match(html, /class="scholia-image-reference"/);
  assert.doesNotMatch(html, /src="https:\/\/example\.com\/pixel\.png"/);
  assert.match(html, /&lt;img src=x onerror=alert\(1\)&gt;/);
});

test('renderer handles display math, hard breaks, and escaped code safely', () => {
  const html = renderMarkdown('Before  \nAfter\n\n$$\n\\int_0^1 x^2 \\, dx\n$$\n\n```html\n<script>alert(1)</script>\n```');

  assert.match(html, /Before<br>\s*After/);
  assert.match(html, /class="scholia-display-math"/);
  assert.match(html, /class="katex-display"/);
  assert.match(html, /class="hljs language-html"/);
  assert.doesNotMatch(html, /<script>alert/);
  assert.match(html, /class="hljs-tag">&lt;/);
});

test('renderer repairs common model brace mistakes without exposing red KaTeX errors', () => {
  const html = renderMarkdown(String.raw`Thus, its total magnification is approximately

$$M_{\text{final}} = M_{\text{objective}}M_{\text{{ocular}}}.$$`);

  assert.match(html, /class="katex-display"/);
  assert.doesNotMatch(html, /katex-error/);
  assert.doesNotMatch(html, /scholia-math-fallback/);
});

test('renderer supports bracket math delimiters and uses a readable fallback for invalid TeX', () => {
  const bracketed = renderMarkdown(String.raw`Inline \(E=mc^2\).

\[
\int_0^1 x^2 \, dx
\]`);
  const invalid = renderMarkdown(String.raw`$\definitelyNotACommand{x}$`);

  assert.match(bracketed, /class="katex"/);
  assert.match(bracketed, /class="katex-display"/);
  assert.doesNotMatch(bracketed, /katex-error/);
  assert.match(invalid, /class="scholia-math-fallback"/);
  assert.doesNotMatch(invalid, /katex-error/);
});

test('table normalization leaves fenced and indented code unchanged', () => {
  const fenced = renderMarkdown('```markdown\n| Code | Sample |\n| --- | --- |\n| `$x | y$` | `a | b` |\n```');
  const indented = renderMarkdown('    | Code | Sample |\n    | --- | --- |\n    | `$x | y$` | `a | b` |');

  assert.match(fenced, /\$x \| y\$/);
  assert.match(fenced, /a \| b/);
  assert.match(indented, /\$x \| y\$/);
  assert.match(indented, /a \| b/);
  assert.doesNotMatch(fenced, /\\\|/);
  assert.doesNotMatch(indented, /\\\|/);
  assert.doesNotMatch(fenced, /<table>/);
  assert.doesNotMatch(indented, /<table>/);
  assert.match(fenced, /class="scholia-code"/);
  assert.match(indented, /class="scholia-code"/);
});
