import test from 'node:test';
import assert from 'node:assert/strict';
import {
  pageContextWithHtml,
  sanitizedPageHtml
} from '../../apps/chrome/src/page-html.js';

function textNode(value) {
  return { nodeType: 3, nodeValue: value };
}

function element(tagName, attributes = {}, children = []) {
  return {
    nodeType: 1,
    localName: tagName,
    tagName: tagName.toUpperCase(),
    id: attributes.id || '',
    attributes: Object.entries(attributes).map(([name, value]) => ({ name, value })),
    childNodes: children,
    ownerDocument: { baseURI: 'https://example.test/course/' }
  };
}

test('page HTML keeps semantic DOM while removing executable and private browser state', () => {
  const root = element('html', { lang: 'en' }, [
    element('head', {}, [
      element('title', {}, [textNode('Proof notes')]),
      element('script', {}, [textNode('window.secret = "do not include"')]),
      element('style', {}, [textNode('.answer { display: none }')])
    ]),
    element('body', { class: 'lesson', onclick: 'steal()', style: 'color:red' }, [
      element('main', { id: 'proof', 'data-topic': 'induction' }, [
        element('a', { href: 'https://reader:secret@example.test/paper?q=induction' }, [textNode('Read <paper>')]),
        element('img', { src: 'data:image/png;base64,oversized', alt: 'Diagram' }),
        element('input', { type: 'password', name: 'password', value: 'visible-secret' })
      ]),
      element('div', { id: 'scholia-extension-root' }, [textNode('Extension controls')])
    ])
  ]);

  const html = sanitizedPageHtml(root);
  assert.match(html, /^<html lang="en"><head><title>Proof notes<\/title><\/head>/);
  assert.match(html, /<main id="proof" data-topic="induction">/);
  assert.match(html, /href="https:\/\/example\.test\/paper\?q=induction"/);
  assert.match(html, /Read &lt;paper&gt;/);
  assert.match(html, /src="\[inline URL omitted\]" alt="Diagram"/);
  assert.match(html, /<input type="password" name="password">/);
  assert.doesNotMatch(html, /window\.secret|display: none|onclick|color:red|visible-secret|Extension controls/);
});

test('page HTML and combined model context are explicitly bounded and labelled', () => {
  const root = element('article', {}, Array.from({ length: 80 }, (_, index) => (
    element('p', { id: `paragraph-${index}` }, [textNode(`Paragraph ${index} ${'detail '.repeat(20)}`)])
  )));
  const html = sanitizedPageHtml(root, { maxChars: 700, maxNodes: 10 });
  assert.ok(html.length <= 700);
  assert.match(html, /Scholia HTML snapshot truncated/);

  const context = pageContextWithHtml('Visible theorem text.', html);
  assert.match(context, /<scholia-rendered-page>\nVisible theorem text\./);
  assert.match(context, /<scholia-page-html>\n<article>/);
  assert.match(context, /active code, styles, live form values/);
});
