import test from 'node:test';
import assert from 'node:assert/strict';
import { pdfRegionPixels } from '../../apps/web/reader/pdf-region.js';

test('PDF crop maps zoom, scrolling, spread offsets and Retina to backing pixels exactly once', () => {
  for (const zoom of [.5, .75, 1, 1.5, 2]) for (const dpr of [1, 2, 3]) {
    const bounds = { left: 300 - 80 * zoom, top: 120 - 200 * zoom, width: 600 * zoom, height: 800 * zoom };
    const selection = { left: bounds.left + 100 * zoom, top: bounds.top + 250 * zoom, width: 160 * zoom, height: 90 * zoom };
    assert.deepEqual(pdfRegionPixels(selection, bounds, 600 * zoom * dpr, 800 * zoom * dpr), {
      x: Math.floor(100 * zoom * dpr), y: Math.floor(250 * zoom * dpr), width: Math.ceil(260 * zoom * dpr) - Math.floor(100 * zoom * dpr), height: Math.ceil(340 * zoom * dpr) - Math.floor(250 * zoom * dpr),
    });
  }
});

test('PDF crop clamps to the canvas and handles independent fractional X/Y scales', () => {
  assert.deepEqual(pdfRegionPixels({ left: 8, top: 18, width: 7, height: 8 }, { left: 10, top: 20, width: 10, height: 10 }, 21, 19), { x: 0, y: 0, width: 11, height: 12 });
  assert.deepEqual(pdfRegionPixels({ left: 19, top: 29, width: 8, height: 8 }, { left: 10, top: 20, width: 10, height: 10 }, 21, 19), { x: 18, y: 17, width: 3, height: 2 });
  assert.equal(pdfRegionPixels({ left: 0, top: 0, width: 5, height: 5 }, { left: 10, top: 20, width: 10, height: 10 }, 20, 20), null);
});
