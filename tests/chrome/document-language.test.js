import test from 'node:test';
import assert from 'node:assert/strict';
import {
  canonicalDocumentLanguage,
  detectDocumentLanguage,
  detectedDocumentLanguage,
  documentLanguageLabel,
  documentLanguageSample
} from '../../apps/chrome/src/document-language.js';

test('document language codes are canonicalized without collapsing non-English languages', () => {
  assert.equal(canonicalDocumentLanguage('pt_br'), 'pt-BR');
  assert.equal(canonicalDocumentLanguage('iw'), 'he');
  assert.equal(canonicalDocumentLanguage('not a language'), '');
  assert.match(documentLanguageLabel('fr'), /French/i);
});

test('document language sampling is bounded and removes prompt wrappers', () => {
  const sample = documentLanguageSample({
    context: `[PDF page 1 of 2]\n<p>${'Bonjour tout le monde. '.repeat(2_000)}</p>`,
    visibleContext: 'Bonjour encore.',
    selection: 'Pourquoi?'
  });
  assert.ok(sample.length <= 16_000);
  assert.doesNotMatch(sample, /PDF page|<p>/);
  assert.match(sample, /Bonjour/);
});

test('reliable text detection overrides a wrong HTML language hint', async () => {
  let received = '';
  const language = await detectDocumentLanguage({
    context: 'Este documento explica el resultado y presenta varios ejemplos detallados.',
    fallback: 'en-US'
  }, async (sample) => {
    received = sample;
    return { isReliable: true, languages: [{ language: 'es', percentage: 98 }] };
  });
  assert.match(received, /documento explica/);
  assert.equal(language, 'es');
});

test('weak detection retains a valid declared language', () => {
  assert.equal(detectedDocumentLanguage({
    isReliable: false,
    languages: [{ language: 'de', percentage: 34 }]
  }, 'fr-FR', 120), 'fr-FR');
});
