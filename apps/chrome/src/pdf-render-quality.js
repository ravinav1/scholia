// Full pages stay bounded in memory. A second, viewport-sized render supplies
// vector detail when a page exceeds that budget (or on a low-density display).
const MAX_DETAIL_PIXELS = 16_000_000;
const MAX_CANVAS_DIMENSION = 8192;
const DETAIL_MARGIN = 128;

export function pdfRenderDensity(devicePixelRatio = 1) {
  return Math.max(2, Number.isFinite(devicePixelRatio) ? devicePixelRatio : 1);
}

export function pdfCanvasScale(width, height, devicePixelRatio, maxPixels) {
  return Math.min(
    pdfRenderDensity(devicePixelRatio),
    Math.sqrt(maxPixels / Math.max(1, width * height)),
    MAX_CANVAS_DIMENSION / Math.max(1, width, height)
  );
}

export function pdfDetailPlan(bounds, visibleBounds, viewport, devicePixelRatio = 1) {
  if (![bounds.left, bounds.top, bounds.width, bounds.height, viewport.width, viewport.height,
    visibleBounds.left, visibleBounds.top, visibleBounds.right, visibleBounds.bottom].every(Number.isFinite)
      || bounds.width <= 0 || bounds.height <= 0 || viewport.width <= 0 || viewport.height <= 0) return null;
  const visible = {
    left: Math.max(0, visibleBounds.left - bounds.left),
    top: Math.max(0, visibleBounds.top - bounds.top),
    right: Math.min(bounds.width, visibleBounds.right - bounds.left),
    bottom: Math.min(bounds.height, visibleBounds.bottom - bounds.top)
  };
  if (visible.right <= visible.left || visible.bottom <= visible.top) return null;
  const left = Math.max(0, Math.floor(visible.left - DETAIL_MARGIN));
  const top = Math.max(0, Math.floor(visible.top - DETAIL_MARGIN));
  const right = Math.min(bounds.width, Math.ceil(visible.right + DETAIL_MARGIN));
  const bottom = Math.min(bounds.height, Math.ceil(visible.bottom + DETAIL_MARGIN));
  const width = right - left, height = bottom - top;
  const density = pdfCanvasScale(width, height, devicePixelRatio, MAX_DETAIL_PIXELS);
  // Floor the backing dimensions, then use those exact scales in the transform
  // so fractional page widths never clip text at the right or bottom edge.
  const pixelWidth = Math.max(1, Math.floor(width * density));
  const pixelHeight = Math.max(1, Math.floor(height * density));
  const sx = pixelWidth / width, sy = pixelHeight / height;
  return {
    left, top, right, bottom, width, height, pixelWidth, pixelHeight, density, visible,
    transform: [sx * bounds.width / viewport.width, 0, 0,
      sy * bounds.height / viewport.height, -left * sx, -top * sy]
  };
}

function covers(plan, visible) {
  return plan.left <= visible.left && plan.top <= visible.top
    && plan.right >= visible.right && plan.bottom >= visible.bottom;
}

function releaseCanvas(canvas) {
  if (!canvas) return;
  canvas.remove();
  canvas.width = canvas.height = 0;
}

export class PDFDetailRenderer {
  constructor({ container, getPages, getVisibleBounds, signal }) {
    this.container = container;
    this.getPages = getPages;
    this.getVisibleBounds = getVisibleBounds || (() => container.getBoundingClientRect());
    this.pages = new Map();
    this.abort = new AbortController();
    const events = { passive: true, signal: this.abort.signal };
    // Capture also sees horizontal scrolling and scrolling inside page layouts.
    window.addEventListener('scroll', () => this.schedule(), { ...events, capture: true });
    window.addEventListener('resize', () => this.schedule(), events);
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) { this.schedule(); return; }
      clearTimeout(this.timer);
      this.timer = null;
      for (const [key, state] of this.pages) if (state.task) this.forget(key);
    }, events);
    this.resizeObserver = new ResizeObserver(() => this.schedule());
    this.resizeObserver.observe(container);
    this.watchDensity();
    signal?.addEventListener('abort', () => this.destroy(), { once: true });
  }

  watchDensity() {
    this.densityQuery?.removeEventListener('change', this.densityChanged);
    this.densityQuery = matchMedia(`(resolution: ${window.devicePixelRatio || 1}dppx)`);
    this.densityChanged = () => {
      this.watchDensity();
      this.schedule();
    };
    this.densityQuery.addEventListener('change', this.densityChanged, { once: true });
  }

  schedule() {
    if (this.abort.signal.aborted || document.hidden) return;
    // Refining on every scroll frame repeatedly rasterizes the same page on
    // CPU-only browsers. Keep the base/last tile while moving, then refine.
    clearTimeout(this.timer);
    this.timer = setTimeout(() => {
      this.timer = null;
      this.update();
    }, 120);
  }

  forget(key) {
    const state = this.pages.get(key);
    if (!state) return;
    this.pages.delete(key);
    state.task?.cancel();
    releaseCanvas(state.canvas);
    releaseCanvas(state.retainedCanvas);
  }

  invalidate() {
    for (const key of this.pages.keys()) this.forget(key);
  }

  update() {
    if (this.abort.signal.aborted || document.hidden) return;
    const bounds = this.getVisibleBounds();
    const visibleBounds = {
      left: Math.max(0, bounds.left), top: Math.max(0, bounds.top),
      right: Math.min(innerWidth, bounds.right), bottom: Math.min(innerHeight, bounds.bottom)
    };
    const active = new Set();
    for (const spec of this.getPages()) {
      const { key, page, viewport, canvas, host } = spec;
      if (!page || !canvas?.isConnected || !canvas.width || !host?.isConnected) continue;
      const rect = canvas.getBoundingClientRect();
      const plan = pdfDetailPlan(rect, visibleBounds, viewport, window.devicePixelRatio);
      if (!plan || Math.min(canvas.width / rect.width, canvas.height / rect.height) >= plan.density - 0.01) continue;
      active.add(key);
      const previous = this.pages.get(key);
      const sameGeometry = previous?.baseCanvas === canvas && previous.scale === viewport.scale
        && previous.rotation === viewport.rotation && previous.width === rect.width
        && previous.height === rect.height;
      const samePage = sameGeometry && previous.density === plan.density;
      if (samePage && covers(previous.plan, plan.visible)) continue;
      // Keep the last sharp tile visible while its replacement paints offscreen.
      // Removing it on each scroll exposed the blurry base for every render.
      const retainedCanvas = sameGeometry ? previous.canvas || previous.retainedCanvas : null;
      if (previous) {
        previous.task?.cancel();
        if (previous.canvas !== retainedCanvas) releaseCanvas(previous.canvas);
        if (previous.retainedCanvas !== retainedCanvas) releaseCanvas(previous.retainedCanvas);
        previous.retainedCanvas = null;
      }
      const state = {
        baseCanvas: canvas, scale: viewport.scale, rotation: viewport.rotation,
        width: rect.width, height: rect.height, density: plan.density, plan, retainedCanvas
      };
      this.pages.set(key, state);
      this.render(spec, state);
    }
    for (const key of this.pages.keys()) if (!active.has(key)) this.forget(key);
  }

  async render(spec, state) {
    const { plan } = state;
    const canvas = document.createElement('canvas');
    canvas.className = 'pdf-detail-canvas';
    canvas.setAttribute('aria-hidden', 'true');
    canvas.width = plan.pixelWidth;
    canvas.height = plan.pixelHeight;
    const hostRect = spec.host.getBoundingClientRect();
    const baseRect = spec.canvas.getBoundingClientRect();
    Object.assign(canvas.style, {
      position: 'absolute', pointerEvents: 'none', inset: 'auto', zIndex: '0',
      left: `${baseRect.left - hostRect.left + plan.left}px`,
      top: `${baseRect.top - hostRect.top + plan.top}px`,
      width: `${plan.width}px`, height: `${plan.height}px`
    });
    try {
      state.task = spec.page.render({
        ...spec.renderOptions,
        canvasContext: canvas.getContext('2d', { alpha: false }),
        viewport: spec.viewport, transform: plan.transform
      });
      await state.task.promise;
      if (this.pages.get(spec.key) !== state || !spec.canvas.isConnected) return;
      state.canvas = canvas;
      spec.host.append(canvas);
      releaseCanvas(state.retainedCanvas);
      state.retainedCanvas = null;
    } catch (error) {
      // Refinement is optional: a difficult PDF still has its full-page render.
      if (error?.name !== 'RenderingCancelledException') console.warn('PDF detail render failed.', error);
      if (this.pages.get(spec.key) === state) this.forget(spec.key);
    } finally {
      state.task = null;
      if (state.canvas !== canvas) releaseCanvas(canvas);
    }
  }

  destroy() {
    this.abort.abort();
    clearTimeout(this.timer);
    this.resizeObserver.disconnect();
    this.densityQuery?.removeEventListener('change', this.densityChanged);
    this.invalidate();
  }
}
