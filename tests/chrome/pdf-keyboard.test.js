import test from 'node:test';
import assert from 'node:assert/strict';
import {
  isPdfKeyboardControl,
  PDF_KEYBOARD_LINE_STEP,
  pdfKeyboardAction
} from '../../apps/chrome/src/pdf/pdf-keyboard.js';

const dimensions = { viewportHeight: 900, toolbarHeight: 60 };

test('PDF keyboard arrows navigate pages or produce Chrome-like vertical scroll steps', () => {
  assert.deepEqual(pdfKeyboardAction({ key: 'ArrowDown' }, dimensions), {
    type: 'scroll', top: PDF_KEYBOARD_LINE_STEP, left: 0
  });
  assert.deepEqual(pdfKeyboardAction({ key: 'ArrowLeft' }, dimensions), {
    type: 'page', direction: -1
  });
  assert.deepEqual(pdfKeyboardAction({ key: 'ArrowRight' }, dimensions), {
    type: 'page', direction: 1
  });
  assert.deepEqual(pdfKeyboardAction({ key: 'PageDown' }, dimensions), {
    type: 'scroll', top: 808, left: 0
  });
  assert.deepEqual(pdfKeyboardAction({ key: ' ', shiftKey: true }, dimensions), {
    type: 'scroll', top: -808, left: 0
  });
  assert.deepEqual(pdfKeyboardAction({ key: 'Home' }, dimensions), {
    type: 'edge', edge: 'start'
  });
  assert.deepEqual(pdfKeyboardAction({ key: 'End' }, dimensions), {
    type: 'edge', edge: 'end'
  });
});

test('PDF keyboard supports native-reader zoom shortcuts without stealing modifiers', () => {
  assert.deepEqual(pdfKeyboardAction({ key: '=', ctrlKey: true }, dimensions), {
    type: 'zoom', direction: 1
  });
  assert.deepEqual(pdfKeyboardAction({ key: '-', metaKey: true }, dimensions), {
    type: 'zoom', direction: -1
  });
  assert.deepEqual(pdfKeyboardAction({ key: '0', metaKey: true }, dimensions), {
    type: 'zoom', direction: 0
  });
  assert.equal(pdfKeyboardAction({ key: 'f', ctrlKey: true }, dimensions), null);
  assert.equal(pdfKeyboardAction({ key: 'ArrowDown', shiftKey: true }, dimensions), null);
  assert.equal(pdfKeyboardAction({ key: 'PageDown', altKey: true }, dimensions), null);
});

test('PDF keyboard controls preserve typing and button activation without trapping arrows', () => {
  const input = { closest: (selector) => selector.includes('input') ? input : null };
  const button = { closest: (selector) => selector.includes('button') ? button : null };
  const page = { closest: () => null };
  assert.equal(isPdfKeyboardControl(input), true);
  assert.equal(isPdfKeyboardControl(button, ' '), true);
  assert.equal(isPdfKeyboardControl(button, 'ArrowRight'), false);
  assert.equal(isPdfKeyboardControl(page), false);
});
