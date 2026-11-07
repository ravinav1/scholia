import test from 'node:test';
import assert from 'node:assert/strict';
import { buildResponseLayerContext } from '../../apps/chrome/src/chat/response-layers.js';

test('response explanation layers retain bounded recursive parent context', () => {
  const capture = { kind: 'text', pageTitle: 'Notes', context: 'Original page context' };
  const first = buildResponseLayerContext({
    attachment: { origin: 'response', text: 'first excerpt', messageIndex: 1 },
    capture,
    messages: [
      { role: 'user', content: 'Explain streams.' },
      { role: 'assistant', content: 'A stream is a pipeline over a source; this is the first excerpt.' }
    ]
  });
  assert.ok(first);
  assert.match(first.parentContext, /A stream is a pipeline over a source/);
  assert.match(first.parentContext, /first excerpt/);

  const second = buildResponseLayerContext({
    attachment: { origin: 'response', text: 'second excerpt', messageIndex: 1 },
    capture: first.capture,
    ancestorContext: first.parentContext,
    messages: [
      { role: 'user', content: 'Explain this.' },
      { role: 'assistant', content: 'The source supplies elements to the pipeline; this is the second excerpt.' }
    ]
  });
  assert.ok(second);
  assert.match(second.parentContext, /The source supplies elements to the pipeline/);
  assert.match(second.parentContext, /Earlier explanation layers/);
  assert.match(second.parentContext, /first excerpt/);
  assert.ok(second.parentContext.length <= 36_000);
});
