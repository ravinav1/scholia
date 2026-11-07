import test from 'node:test';
import assert from 'node:assert/strict';
import { getDocument } from 'pdfjs-dist/legacy/build/pdf.mjs';
import {
  pdfDocumentBaseUrl,
  pdfExternalLinkUrl,
  pdfSourceFragment,
  recoverPdfAnnotationLinks,
  samePdfDocumentUrl
} from '../../apps/chrome/src/pdf/pdf-links.js';

function linkedPdf() {
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R 5 0 R] >>',
    '<< /Type /Annot /Subtype /Link /Rect [72 700 300 730] /A << /S /URI /URI (/science/article/pii/S0123456789012345) >> >>',
    '<< /Type /Annot /Subtype /Link /Rect [72 650 300 680] /A << /S /URI /URI (javascript:alert\\(1\\)) >> >>'
  ];
  let source = '%PDF-1.4\n';
  const offsets = [];
  for (const [index, object] of objects.entries()) {
    offsets.push(source.length);
    source += `${index + 1} 0 obj\n${object}\nendobj\n`;
  }
  const xref = source.length;
  source += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  for (const offset of offsets) source += `${String(offset).padStart(10, '0')} 00000 n \n`;
  source += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return new TextEncoder().encode(source);
}

test('PDF links resolve publisher-relative, DOI, host-only, and communication URLs', () => {
  const base = 'https://linkinghub.elsevier.com/retrieve/pii/S0123456789012345.pdf?token=private#page=2';
  assert.equal(
    pdfExternalLinkUrl('/science/article/pii/S0123456789012345', base),
    'https://linkinghub.elsevier.com/science/article/pii/S0123456789012345'
  );
  assert.equal(
    pdfExternalLinkUrl('related-article.pdf', base),
    'https://linkinghub.elsevier.com/retrieve/pii/related-article.pdf'
  );
  assert.equal(pdfExternalLinkUrl('//doi.org/10.1016/j.test.2026.1'), 'https://doi.org/10.1016/j.test.2026.1');
  assert.equal(pdfExternalLinkUrl('doi:10.1016/j.test.2026.1'), 'https://doi.org/10.1016/j.test.2026.1');
  assert.equal(pdfExternalLinkUrl('10.1016/j.test.2026.1'), 'https://doi.org/10.1016/j.test.2026.1');
  assert.equal(pdfExternalLinkUrl('www.sciencedirect.com/topics/computer-science'), 'https://www.sciencedirect.com/topics/computer-science');
  assert.equal(pdfExternalLinkUrl('mailto:author@example.com'), 'mailto:author@example.com');
  assert.equal(pdfExternalLinkUrl('tel:+4712345678'), 'tel:+4712345678');
});

test('PDF links reject executable and privileged browser URLs', () => {
  for (const unsafe of [
    'javascript:alert(1)',
    'data:text/html,unsafe',
    'file:///etc/passwd',
    'chrome://settings',
    'chrome-extension://abcdefgh/index.html'
  ]) {
    assert.equal(pdfExternalLinkUrl(unsafe, 'https://example.com/paper.pdf'), '');
  }
});

test('PDF source helpers preserve signed bases and recognize same-document fragments', () => {
  const source = 'https://papers.example/article.pdf?signature=secret#page=8';
  assert.equal(pdfDocumentBaseUrl(source), 'https://papers.example/article.pdf?signature=secret');
  assert.equal(pdfSourceFragment(source), 'page=8');
  assert.equal(samePdfDocumentUrl(source, 'https://papers.example/article.pdf?signature=secret#nameddest=results'), true);
  assert.equal(samePdfDocumentUrl(source, 'https://papers.example/article.pdf?signature=other#page=8'), false);
});

test('annotation recovery fills safe URLs without enabling unsafe actions', () => {
  const recovered = recoverPdfAnnotationLinks([
    { id: 'relative', unsafeUrl: '../article/related' },
    { id: 'script', unsafeUrl: 'javascript:alert(1)' },
    { id: 'internal', dest: 'Methods' }
  ], 'https://www.elsevier.com/journals/current/paper.pdf');
  assert.equal(recovered[0].url, 'https://www.elsevier.com/journals/article/related');
  assert.equal('url' in recovered[1], false);
  assert.equal(recovered[2].dest, 'Methods');
});

test('PDF.js receives the document base URL for Elsevier-style relative annotations', async () => {
  const loadingTask = getDocument({
    data: linkedPdf(),
    docBaseUrl: 'https://linkinghub.elsevier.com/retrieve/pii/S0123456789012345.pdf?token=private'
  });
  try {
    const documentProxy = await loadingTask.promise;
    const annotations = await (await documentProxy.getPage(1)).getAnnotations({ intent: 'display' });
    assert.equal(annotations[0].url, 'https://linkinghub.elsevier.com/science/article/pii/S0123456789012345');
    assert.equal(annotations[1].url, undefined);
    assert.match(annotations[1].unsafeUrl, /^javascript:/);
  } finally {
    await loadingTask.destroy();
  }
});
