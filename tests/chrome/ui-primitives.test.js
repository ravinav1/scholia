import test from 'node:test';
import assert from 'node:assert/strict';
import {
  HTML_NAMESPACE,
  createHtmlElement,
  ISOLATED_UI_EVENT_TYPES,
  isolateUiInputEvents,
  isQuickChatShortcut,
  responseSelectionInteractionProtected,
} from '../../apps/chrome/src/ui-primitives.js';

test('content UI elements are always created in the HTML namespace', () => {
  const calls = [];
  const ownerDocument = {
    createElement() {
      throw new Error('XML documents must not use unqualified element creation.');
    },
    createElementNS(namespace, tagName) {
      calls.push([namespace, tagName]);
      return { namespaceURI: namespace, localName: tagName };
    },
  };

  const host = createHtmlElement('div', ownerDocument);
  const template = createHtmlElement('template', ownerDocument);
  const canvas = createHtmlElement('canvas', ownerDocument);

  assert.deepEqual(calls, [
    [HTML_NAMESPACE, 'div'],
    [HTML_NAMESPACE, 'template'],
    [HTML_NAMESPACE, 'canvas'],
  ]);
  assert.equal(host.namespaceURI, HTML_NAMESPACE);
  assert.equal(template.localName, 'template');
  assert.equal(canvas.localName, 'canvas');
});

test('in-page composer input events stop at the Scholia shadow boundary', () => {
  const listeners = new Map();
  const root = {
    addEventListener(type, listener) {
      listeners.set(type, listener);
    },
  };
  isolateUiInputEvents(root);

  assert.deepEqual([...listeners.keys()], [...ISOLATED_UI_EVENT_TYPES]);
  for (const type of [
    'keydown',
    'keyup',
    'beforeinput',
    'input',
    'focusin',
    'paste',
    'compositionend',
  ]) {
    let stopped = false;
    listeners.get(type)({
      stopPropagation() {
        stopped = true;
      },
    });
    assert.equal(stopped, true, `${type} should not reach the host page`);
  }
});

test('Quick Chat recognizes Command-Shift-K on macOS', () => {
  assert.equal(
    isQuickChatShortcut(
      { key: 'K', metaKey: true, ctrlKey: false, shiftKey: true, altKey: false },
      'MacIntel'
    ),
    true
  );
  assert.equal(
    isQuickChatShortcut(
      { key: 'k', metaKey: false, ctrlKey: true, shiftKey: true, altKey: false },
      'MacIntel'
    ),
    false
  );
});

test('Quick Chat recognizes Ctrl-Shift-K off macOS and rejects extra modifiers', () => {
  assert.equal(
    isQuickChatShortcut(
      { key: 'k', metaKey: false, ctrlKey: true, shiftKey: true, altKey: false },
      'Linux x86_64'
    ),
    true
  );
  assert.equal(
    isQuickChatShortcut(
      { key: 'k', metaKey: false, ctrlKey: true, shiftKey: true, altKey: true },
      'Linux x86_64'
    ),
    false
  );
  assert.equal(
    isQuickChatShortcut(
      { key: 'k', metaKey: false, ctrlKey: true, shiftKey: true, altKey: false, repeat: true },
      'Linux x86_64'
    ),
    false
  );
});

test('response selection remains attached while its Explain composer takes focus', () => {
  assert.equal(responseSelectionInteractionProtected({ pointerInteraction: true }), true);
  assert.equal(responseSelectionInteractionProtected({ focusInside: true }), true);
  assert.equal(responseSelectionInteractionProtected({}), false);
});
