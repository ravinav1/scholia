import test from 'node:test';
import assert from 'node:assert/strict';
import { highlightCodeRuns } from '../../packages/core/src/code-highlight.js';
import { renderMarkdown, addActivity, renderActivity } from '../../apps/chrome/src/render.js';
import { providerActivity } from '../../apps/chrome/src/provider-runtime.js';

test('shared code grammars support LaTeX, programming, shell and unknown literal code safely', () => {
  for (const [language, code] of [
    ['latex', String.raw`\begin{align} E &= mc^2 \end{align}`],
    ['python', 'def hello():\n    return "🌱 <hello>"'],
    ['swift', 'let value: Int = 42'], ['sql', 'SELECT name FROM courses WHERE id = 1;'],
    ['rust', 'fn main() { println!("hello"); }'], ['fortran', 'program hello\nprint *, "Hello"\nend program'],
    ['bash', 'echo "$HOME"'], ['json', '{"value": 42}'], ['julia', 'function f(x)\n return x + 1\nend']
  ]) {
    const runs = highlightCodeRuns(code, language);
    assert.ok(runs.length, `${language} should have syntax highlighting`);
    assert.ok(runs.every((run) => run.location >= 0 && run.length > 0 && run.location + run.length <= code.length));
    const html = renderMarkdown(`\`\`\`${language}\n${code}\n\`\`\``);
    assert.match(html, /data-copy-code/);
    assert.match(html, /hljs-/);
  }
  assert.deepEqual(highlightCodeRuns('<script>alert(1)</script>', 'not-a-language'), []);
  assert.match(renderMarkdown('```not-a-language\n<script>alert(1)</script>\n```'), /&lt;script&gt;/);
});

test('activity timelines are bounded, deduplicated and escape file and tool output', () => {
  const message = {};
  addActivity(message, { title: 'Read file', detail: '<script>secret()</script>' });
  addActivity(message, { title: 'Read file', detail: '<script>secret()</script>' });
  assert.equal(message.activity.length, 1);
  assert.ok(!renderActivity(message.activity).includes('<script>'));
  assert.match(renderActivity(message.activity), /&lt;script&gt;/);
  for (let i = 0; i < 100; i++) addActivity(message, { title: `Step ${i}` });
  assert.equal(message.activity.length, 80);
  assert.equal(message.activity.at(-1).title, 'Step 99');
  assert.deepEqual(providerActivity({ type: 'response.web_search_call.completed' }), { title: 'Web search complete' });
  assert.equal(providerActivity({ choices: [{ delta: { content: 'I read a file' } }] }), null, 'Answer prose must never be treated as an actual tool action');
});
