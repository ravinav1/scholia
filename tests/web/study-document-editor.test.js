import test from 'node:test';
import assert from 'node:assert/strict';
import { editorMarkup, canEditDocument } from '../../apps/web/reader/document-editor.js';

test('editable notebook sources stay literal even when they contain HTML and closing textarea tags', () => {
  const html = editorMarkup({ source: null, cells: [{ id: 0, kind: 'markdown', source: '</textarea><script>alert(1)</script>' }, { id: 1, kind: 'code', source: 'if x < 2:\n    print("hello")\n' }] });
  assert.equal((html.match(/<textarea /g) || []).length, 2);
  assert.equal((html.match(/<\/textarea>/g) || []).length, 2);
  assert.ok(!html.includes('<script>'));
  assert.ok(html.includes('if x &lt; 2:\n    print(&quot;hello&quot;)\n'));
});

test('plain text including empty source uses one editor and unsupported binary formats stay read-only', () => {
  assert.equal((editorMarkup({ source: '', cells: [] }).match(/<textarea /g) || []).length, 1);
  assert.ok(canEditDocument({ kind: 'notebook' }) && canEditDocument({ kind: 'code' }) && canEditDocument({ kind: 'text' }));
  assert.ok(!canEditDocument({ kind: 'pdf' }) && !canEditDocument({ kind: 'office' }));
});
