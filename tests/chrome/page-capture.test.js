import test from 'node:test';
import assert from 'node:assert/strict';
import {
  currentSelectionCapture,
  overleafEditorSelection
} from '../../apps/chrome/src/page-capture.js';

test('a single selected character creates a text capture', () => {
  const previousNode = globalThis.Node;
  globalThis.Node = { ELEMENT_NODE: 1 };

  try {
    const rect = { left: 24, right: 32, top: 40, bottom: 58, width: 8, height: 18 };
    const textNode = { nodeType: 3, parentElement: { closest: () => null } };
    const range = {
      cloneContents: () => ({ querySelectorAll: () => [], textContent: 'A' }),
      cloneRange: () => range,
      getClientRects: () => [rect],
      getBoundingClientRect: () => rect
    };
    const selection = {
      anchorNode: textNode,
      focusNode: textNode,
      isCollapsed: false,
      rangeCount: 1,
      getRangeAt: () => range,
      toString: () => 'A'
    };

    const capture = currentSelectionCapture('', selection);
    assert.equal(capture?.kind, 'text');
    assert.equal(capture?.selection, 'A');
    assert.equal(capture?.rect, rect);
  } finally {
    if (previousNode === undefined) delete globalThis.Node;
    else globalThis.Node = previousNode;
  }
});

test('Overleaf CodeMirror selections remain available to Scholia', () => {
  const previousNode = globalThis.Node;
  const previousLocation = globalThis.location;
  globalThis.Node = { ELEMENT_NODE: 1 };
  globalThis.location = { hostname: 'www.overleaf.com', href: 'https://www.overleaf.com/project/example' };

  try {
    const editor = {};
    const editable = { closest: (selector) => selector.includes('input') ? {} : editor };
    const anchor = { nodeType: 3, parentElement: editable };
    const focus = { nodeType: 3, parentElement: editable };
    const rect = { left: 20, right: 100, top: 30, bottom: 50, width: 80, height: 20 };
    const range = {
      cloneRange: () => range,
      getClientRects: () => [rect],
      getBoundingClientRect: () => rect
    };
    const selection = {
      anchorNode: anchor,
      focusNode: focus,
      isCollapsed: false,
      rangeCount: 1,
      getRangeAt: () => range,
      toString: () => '\\begin{align}\n  x &= y + 1\n\\end{align}'
    };

    assert.equal(overleafEditorSelection(anchor, focus), true);
    const capture = currentSelectionCapture('', selection);
    assert.equal(capture?.kind, 'latex');
    assert.equal(capture?.selection, '\\begin{align}\n  x &= y + 1\n\\end{align}');
    assert.equal(capture?.rect, rect);
  } finally {
    if (previousNode === undefined) delete globalThis.Node;
    else globalThis.Node = previousNode;
    if (previousLocation === undefined) delete globalThis.location;
    else globalThis.location = previousLocation;
  }
});

test('editable selections stay private outside one Overleaf editor', () => {
  const previousNode = globalThis.Node;
  globalThis.Node = { ELEMENT_NODE: 1 };
  try {
    const firstEditor = {};
    const secondEditor = {};
    const first = { nodeType: 3, parentElement: { closest: () => firstEditor } };
    const second = { nodeType: 3, parentElement: { closest: () => secondEditor } };
    assert.equal(overleafEditorSelection(first, first, { hostname: 'example.com' }), false);
    assert.equal(overleafEditorSelection(first, second, { hostname: 'overleaf.com' }), false);
  } finally {
    if (previousNode === undefined) delete globalThis.Node;
    else globalThis.Node = previousNode;
  }
});
