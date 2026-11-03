import test from 'node:test';
import assert from 'node:assert/strict';
import { entirePdfContext, readEntirePdf, MAX_ENTIRE_PDF_CHARS } from '../packages/core/src/entire-pdf.js';
import { normalizeChatRecord } from '../apps/chrome/src/chat-history.js';
import { buildProviderRequest } from '../apps/chrome/src/provider-runtime.js';
import { mergeSettings } from '../packages/core/src/providers.js';

test('entire PDF survives saved chat and a provider follow-up beyond normal excerpt limits', () => {
  const pages = Array.from({ length: 30 }, (_, index) => `Start ${index + 1}\n${'Document evidence. '.repeat(500)}\nConclusion ${index + 1}`);
  const full = entirePdfContext({ title: 'Long reading', pages });
  assert.ok(full.context.length > 140_000);
  const chat = normalizeChatRecord({ id: 'whole-pdf', capture: { context: full.context, entirePDF: true, sourceKind: 'pdf' },
    messages: [{ role: 'user', content: 'Explain the whole document.' }, { role: 'assistant', content: 'Overview.' }] });
  assert.equal(chat.capture.context, full.context);
  const request = buildProviderRequest({ provider: 'openai', context: chat.capture.context,
    entirePDF: chat.capture.entirePDF, messages: [...chat.messages, { role: 'user', content: 'Compare the introduction and conclusion.' }] },
  mergeSettings({ apiKeys: { openai: 'test' } }));
  const body = JSON.parse(request.fetchOptions.body);
  assert.match(body.messages[0].content, /Read every supplied PDF page before answering/);
  assert.ok(body.messages.at(-1).content.includes(full.context));
  for (let page = 1; page <= 30; page++) assert.ok(body.messages.at(-1).content.includes(`Conclusion ${page}`));
});

test('full PDF rejects missing, truncated and oversized content instead of silently clipping', () => {
  assert.throws(() => entirePdfContext({ pages: ['First'], pageCount: 2 }), /missing or shortened/);
  assert.throws(() => entirePdfContext({ pages: ['First'], truncated: true }), /missing or shortened/);
  assert.throws(() => entirePdfContext({ pages: ['First', undefined] }), /page 2 could not be read/);
  assert.throws(() => entirePdfContext({ pages: Array(2) }), /page 1 could not be read/);
  assert.throws(() => entirePdfContext({ pages: ['a'.repeat(MAX_ENTIRE_PDF_CHARS)] }), /too large/);
  assert.throws(() => entirePdfContext({ pages: ['', ' '] }), /no readable text/);
  assert.match(entirePdfContext({ pages: ['Introduction', '', 'Conclusion'] }).context, /No readable text on pages 2/);
});

test('explicit full PDF reading visits every page in order and supports cancellation', async () => {
  const reads = [];
  const result = await readEntirePdf({ pageCount: 4, readPage: async (number) => { reads.push(number); return `Page ${number}`; } });
  assert.deepEqual(reads, [1, 2, 3, 4]);
  assert.match(result.context, /Page 4/);
  const controller = new AbortController();
  await assert.rejects(readEntirePdf({ pageCount: 4, signal: controller.signal,
    readPage: async () => { controller.abort(); return 'Text'; } }), { name: 'AbortError' });
  await assert.rejects(readEntirePdf({ pageCount: 4, readPage: async (page) => { if (page === 2) throw new Error('Damaged page'); return 'Text'; } }), /Damaged page/);
});
