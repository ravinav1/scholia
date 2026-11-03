import test from 'node:test';
import assert from 'node:assert/strict';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import {
  assertPdfSize,
  extractPdfContext,
  fetchPdfDocument,
  formatPdfContext,
  MAX_PDF_BYTES,
  PDF_RANGE_CHUNK_BYTES,
  pdfDownloadUrlFromHtml,
  pdfInputOptions,
  pdfWrapperDownloadUrl,
  readPdfResponse,
  textContentToString
} from '../apps/chrome/src/pdf-context.js';

import { onePagePdf } from './helpers/pdf.js';

function responseAt(url, body, options = {}) {
  const response = new Response(body, options);
  Object.defineProperty(response, 'url', { configurable: true, value: url });
  return response;
}

test('PDF text items preserve visual lines and sensible word spacing', () => {
  const text = textContentToString([
    { str: 'Scholia', width: 36, transform: [1, 0, 0, 10, 10, 100] },
    { str: 'reads', width: 25, transform: [1, 0, 0, 10, 50, 100] },
    { str: '.', width: 2, transform: [1, 0, 0, 10, 75, 100], hasEOL: true },
    { str: 'Next line', width: 44, transform: [1, 0, 0, 10, 10, 82] }
  ]);
  assert.equal(text, 'Scholia reads.\nNext line');
});

test('PDF context retains explicit page boundaries and a document map', () => {
  const result = formatPdfContext(['Introduction\nFirst paragraph.', '', 'Conclusion']);
  assert.match(result.context, /\[PDF page 1 of 3\]/);
  assert.match(result.context, /\[PDF page 2 of 3\]\n\(No extractable text on this page\.\)/);
  assert.match(result.outline, /PDF page 3: Conclusion/);
  assert.equal(result.pageCount, 3);
  assert.equal(result.extractedCharacters, 'Introduction\nFirst paragraph.'.length + 'Conclusion'.length);
});

test('a growing PDF index distinguishes pending pages from extraction limits', () => {
  const partial = formatPdfContext(['First page'], 3, { indexing: true });
  assert.equal(partial.extractedPageCount, 1);
  assert.match(partial.context, /indexing is still in progress/);
  assert.match(partial.outline, /pages 2–3: not indexed yet/);
  assert.doesNotMatch(partial.context, /safety limit/);
  assert.match(formatPdfContext(['First page'], 3).context, /local safety limit/);
});

test('PDF downloads are assembled from streamed response chunks', async () => {
  const response = new Response(new ReadableStream({
    start(controller) {
      controller.enqueue(new TextEncoder().encode('%PDF-1.7\n'));
      controller.enqueue(new TextEncoder().encode('body'));
      controller.close();
    }
  }), { headers: { 'content-length': '13' } });
  const progress = [];
  const bytes = await readPdfResponse(response, (value) => progress.push(value.loaded));
  assert.equal(new TextDecoder().decode(bytes), '%PDF-1.7\nbody');
  assert.deepEqual(progress, [9, 13]);
});

test('repository PDF preview URLs resolve to their raw-download forms', () => {
  const github = 'https://github.com/mortenfyhn/ntnu-course-summaries/blob/master/TTK26%20Biomedisinsk%20instrumentering%20og%20regulering/TTK26-Summary.pdf?utm_source=chatgpt.com';
  assert.equal(
    pdfWrapperDownloadUrl(github),
    'https://github.com/mortenfyhn/ntnu-course-summaries/blob/master/TTK26%20Biomedisinsk%20instrumentering%20og%20regulering/TTK26-Summary.pdf?raw=1'
  );
  assert.equal(
    pdfWrapperDownloadUrl('https://gitlab.com/team/project/-/blob/main/docs/report.pdf?ref_type=heads'),
    'https://gitlab.com/team/project/-/raw/main/docs/report.pdf'
  );
  assert.equal(
    pdfWrapperDownloadUrl('https://bitbucket.org/team/project/src/main/docs/report.pdf?source=chat'),
    'https://bitbucket.org/team/project/raw/main/docs/report.pdf'
  );
});

test('bounded PDF wrapper HTML finds embedded and explicit download URLs', () => {
  assert.equal(
    pdfDownloadUrlFromHtml(
      '<main><iframe src="/reader/files/paper.pdf?token=a&amp;download=1"></iframe></main>',
      'https://publisher.example/articles/paper.pdf'
    ),
    'https://publisher.example/reader/files/paper.pdf?token=a&download=1'
  );
  assert.equal(
    pdfDownloadUrlFromHtml(
      '<a href="/about">About</a><a data-testid="download-raw-button" href="https://raw.githubusercontent.com/team/project/main/report.pdf">Raw</a>',
      'https://github.com/team/project/blob/main/report.pdf'
    ),
    'https://raw.githubusercontent.com/team/project/main/report.pdf'
  );
  assert.equal(
    pdfDownloadUrlFromHtml('<a href="javascript:alert(1)" download>PDF</a>', 'https://example.test/report.pdf'),
    ''
  );
});

test('GitHub blob PDF addresses load the redirected raw bytes and retain page fragments', async () => {
  const previousFetch = globalThis.fetch;
  const source = 'https://github.com/team/project/blob/main/docs/report.pdf?utm_source=chatgpt.com#page=3';
  const raw = 'https://raw.githubusercontent.com/team/project/main/docs/report.pdf';
  const requests = [];
  globalThis.fetch = async (url, options) => {
    requests.push({ url, options });
    return responseAt(raw, onePagePdf('GitHub wrapper resolved'), {
      headers: { 'content-type': 'application/octet-stream' }
    });
  };
  try {
    const document = await fetchPdfDocument(source);
    assert.equal(requests.length, 1);
    assert.equal(requests[0].url, 'https://github.com/team/project/blob/main/docs/report.pdf?raw=1');
    assert.equal(requests[0].options.credentials, 'include');
    assert.equal(document.url, `${raw}#page=3`);
    assert.match(await document.blob.text(), /^%PDF-/);
  } finally {
    globalThis.fetch = previousFetch;
  }
});

test('PDF fetching follows response download hints and generic HTML embeds', async () => {
  const previousFetch = globalThis.fetch;
  const hintedSource = 'https://code.example/preview/hinted.pdf?utm_source=chat';
  const hintedRaw = 'https://code.example/raw/hinted.pdf';
  const embeddedSource = 'https://publisher.example/view/embedded.pdf';
  const embeddedRaw = 'https://publisher.example/files/embedded.pdf?download=1';
  const requests = [];
  globalThis.fetch = async (url) => {
    requests.push(url);
    if (url === hintedSource) {
      return responseAt(url, '<html>Preview</html>', {
        headers: { 'content-type': 'text/html', 'x-raw-download': '/raw/hinted.pdf' }
      });
    }
    if (url === embeddedSource) {
      return responseAt(url, '<embed src="/files/embedded.pdf?download=1">', {
        headers: { 'content-type': 'text/html; charset=utf-8' }
      });
    }
    if (url === hintedRaw || url === embeddedRaw) {
      return responseAt(url, onePagePdf('Wrapper resolved'), {
        headers: { 'content-type': 'application/octet-stream' }
      });
    }
    throw new Error(`Unexpected PDF request: ${url}`);
  };
  try {
    const hinted = await fetchPdfDocument(hintedSource);
    const embedded = await fetchPdfDocument(embeddedSource);
    assert.equal(hinted.url, hintedRaw);
    assert.equal(embedded.url, embeddedRaw);
    assert.deepEqual(requests, [hintedSource, hintedRaw, embeddedSource, embeddedRaw]);
  } finally {
    globalThis.fetch = previousFetch;
  }
});

test('PDF size validation accepts 1 GB and rejects anything larger', () => {
  assert.equal(MAX_PDF_BYTES, 1024 * 1024 * 1024);
  assert.equal(assertPdfSize(MAX_PDF_BYTES), MAX_PDF_BYTES);
  assert.throws(
    () => assertPdfSize(MAX_PDF_BYTES + 1),
    /larger than Scholia's 1 GB local-processing limit/
  );
});

test('large Blob inputs are exposed to PDF.js as bounded range reads', async () => {
  const sliceCalls = [];
  class TrackedPdfBlob extends Blob {
    slice(begin, end, type) {
      sliceCalls.push([begin, end]);
      return super.slice(begin, end, type);
    }

    async arrayBuffer() {
      throw new Error('The whole Blob should not be materialized.');
    }
  }
  class FakeRangeTransport {
    constructor(length, initialData, progressiveDone, fileName) {
      Object.assign(this, { length, initialData, progressiveDone, fileName });
    }

    onDataRange(begin, chunk) {
      this.lastRange = { begin, chunk };
    }

    onDataProgress(loaded, total) {
      this.lastProgress = { loaded, total };
    }
  }

  const padding = new Uint8Array(PDF_RANGE_CHUNK_BYTES + 32);
  const blob = new TrackedPdfBlob(['%PDF-1.7\n', padding], { type: 'application/pdf' });
  const options = await pdfInputOptions(
    { PDFDataRangeTransport: FakeRangeTransport },
    blob,
    { fileName: 'large.pdf' }
  );

  assert.equal(options.length, blob.size);
  assert.equal(options.rangeChunkSize, PDF_RANGE_CHUNK_BYTES);
  assert.equal(options.disableStream, true);
  assert.equal(options.disableAutoFetch, true);
  assert.deepEqual(sliceCalls[0], [0, PDF_RANGE_CHUNK_BYTES]);

  options.range.requestDataRange(PDF_RANGE_CHUNK_BYTES, blob.size);
  await new Promise((resolve) => setTimeout(resolve, 0));
  assert.equal(options.range.lastRange.begin, PDF_RANGE_CHUNK_BYTES);
  assert.equal(options.range.lastRange.chunk.byteLength, blob.size - PDF_RANGE_CHUNK_BYTES);
  assert.deepEqual(sliceCalls[1], [PDF_RANGE_CHUNK_BYTES, blob.size]);
});

test('packaged PDF.js extracts text from an actual PDF document', async () => {
  const previousChrome = globalThis.chrome;
  globalThis.chrome = { runtime: { getURL(path) {
    const relative = path.replace(/^vendor\/pdfjs\//, '');
    const location = relative.startsWith('cmaps/') || relative.startsWith('standard_fonts/')
      ? resolve('node_modules/pdfjs-dist', relative)
      : resolve('node_modules/pdfjs-dist/legacy/build', relative);
    return pathToFileURL(location).href;
  } } };
  try {
    const result = await extractPdfContext(onePagePdf('Scholia PDF context works'));
    assert.equal(result.pageCount, 1);
    assert.equal(result.extractedCharacters, 25);
    assert.match(result.context, /\[PDF page 1 of 1\]\nScholia PDF context works/);

    const rangedResult = await extractPdfContext(new Blob([
      onePagePdf('Scholia ranged Blob works')
    ], { type: 'application/pdf' }));
    assert.equal(rangedResult.pageCount, 1);
    assert.match(rangedResult.context, /Scholia ranged Blob works/);
  } finally {
    if (previousChrome === undefined) delete globalThis.chrome;
    else globalThis.chrome = previousChrome;
  }
});
