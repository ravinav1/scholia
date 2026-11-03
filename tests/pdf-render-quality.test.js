import test from 'node:test';
import assert from 'node:assert/strict';
import { pdfCanvasScale, pdfDetailPlan, pdfRenderDensity } from '../apps/chrome/src/pdf-render-quality.js';

test('PDF rendering supersamples ordinary screens and retains Retina density', () => {
  assert.equal(pdfRenderDensity(1), 2);
  assert.equal(pdfRenderDensity(1.25), 2);
  assert.equal(pdfRenderDensity(3), 3);
  assert.equal(pdfRenderDensity(NaN), 2);
  assert.equal(pdfCanvasScale(800, 1000, 2, 16_000_000), 2);
  const scale = pdfCanvasScale(10_000, 20_000, 3, 16_000_000);
  assert.ok(10_000 * 20_000 * scale ** 2 <= 16_000_001);
  assert.ok(pdfCanvasScale(100, 50_000, 3, 16_000_000) * 50_000 <= 8192);
});

test('zoomed PDF detail keeps screen density while bounding memory to the visible area', () => {
  const bounds = { left: -1800, top: -9000, width: 6000, height: 8000 };
  assert.equal(pdfDetailPlan(bounds, { left: 0, top: 60, right: 1200, bottom: 900 }, bounds), null);
  bounds.top = -3000;
  const view = { left: 0, top: 60, right: 1200, bottom: 900 };
  const plan = pdfDetailPlan(bounds, view, { width: 6000, height: 8000 }, 2);
  assert.equal(plan.density, 2);
  assert.ok(plan.pixelWidth * plan.pixelHeight < 7_000_000);
  assert.deepEqual(plan.visible, { left: 1800, top: 3060, right: 3000, bottom: 3900 });
  // The visible PDF point maps into the refinement canvas at the same screen
  // position, including the negative translation needed after scrolling.
  const [sx, , , sy, tx, ty] = plan.transform;
  assert.equal((1800 * sx + tx) / 2 + plan.left + bounds.left, view.left);
  assert.equal((3060 * sy + ty) / 2 + plan.top + bounds.top, view.top);
});

test('detail handles fractional CSS scaling, page edges and extreme displays', () => {
  const bounds = { left: 80.25, top: 60.5, width: 815.6, height: 1055.8 };
  const plan = pdfDetailPlan(bounds, { left: 0, top: 0, right: 1000, bottom: 1200 }, { width: 816, height: 1056 }, 1.25);
  assert.equal(plan.left, 0);
  assert.equal(plan.top, 0);
  assert.equal(plan.right, bounds.width);
  assert.equal(plan.bottom, bounds.height);
  assert.equal(plan.transform[0] * 816, plan.pixelWidth);
  assert.equal(plan.transform[3] * 1056, plan.pixelHeight);
  const huge = pdfDetailPlan({ left: 0, top: 0, width: 10000, height: 20000 },
    { left: 0, top: 0, right: 10000, bottom: 20000 }, { width: 10000, height: 20000 }, 4);
  assert.ok(huge.pixelWidth * huge.pixelHeight <= 16_000_000);
  assert.ok(Math.max(huge.pixelWidth, huge.pixelHeight) <= 8192);
  assert.equal(pdfDetailPlan({ ...bounds, width: 0 }, bounds, bounds), null);
});
