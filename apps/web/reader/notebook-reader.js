import { renderMarkdown, escapeHtml } from '../../chrome/src/render.js';

export function notebookMarkup(pages) {
  return `<article class="paper notebook-paper">${pages.map((cell) => `<section class="notebook-cell" data-cell="${cell.number}" aria-label="Cell ${cell.number}">${renderMarkdown(cell.text)}<div class="embedded-images">${(cell.images || []).map((name) => `<figure data-output="${escapeHtml(name)}"><img alt="Saved output from cell ${cell.number}" loading="lazy"><button type="button" data-notebook-image>Ask about this output</button></figure>`).join('')}</div></section>`).join('')}</article>`;
}

export class StudyNotebookReader {
  constructor({ host, document: item, token, request, page, onPage, onImage, notify }) {
    Object.assign(this, { host, item, token, request, page, onPage, onImage, notify });
    this.id = item.id;
    this.urls = [];
    this.visible = new Set();
    this.abort = new AbortController();
    this.pendingPages = 0;
    this.opened = this.open();
  }
  async open() {
    const index = await this.request(`/api/index/${this.id}`, null, this.abort.signal);
    if (this.abort.signal.aborted) return;
    this.host.innerHTML = notebookMarkup(index.pages);
    this.cells = [...this.host.querySelectorAll('[data-cell]')];
    this.observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            this.visible.add(entry.target);
            this.loadImages(entry.target).catch((error) => {
              if (error.name !== 'AbortError') this.notify(error.message);
            });
          } else this.visible.delete(entry.target);
        }
        this.trackCell();
      },
      { root: this.host }
    );
    for (const cell of this.cells) this.observer.observe(cell);
    this.host.addEventListener('scroll', () => this.trackCell(), {
      passive: true,
      signal: this.abort.signal,
    });
    this.host.addEventListener(
      'click',
      async (event) => {
        const button = event.target.closest('[data-notebook-image]');
        if (!button) return;
        const image = button.closest('figure').querySelector('img');
        if (!image.src) return;
        try {
          await this.onImage(
            await (await fetch(image.src)).blob(),
            Number(button.closest('[data-cell]').dataset.cell)
          );
        } catch (error) {
          this.notify(error.message);
        }
      },
      { signal: this.abort.signal }
    );
    this.ready = true;
    this.setPage(this.page, true);
  }
  async loadImages(cell) {
    for (const figure of cell.querySelectorAll('[data-output]:not([data-loaded])')) {
      figure.dataset.loaded = 'true';
      try {
        const response = await fetch(
          `/api/image/${this.id}/${encodeURIComponent(figure.dataset.output)}`,
          { headers: { 'X-Scholia-Token': this.token }, signal: this.abort.signal }
        );
        if (!response.ok) throw new Error('A saved notebook output could not be opened.');
        const blob = await response.blob();
        if (this.abort.signal.aborted) return;
        const url = URL.createObjectURL(blob);
        this.urls.push(url);
        figure.querySelector('img').src = url;
      } catch (error) {
        delete figure.dataset.loaded;
        throw error;
      }
    }
  }
  setPage(page, force = false) {
    // Earlier scroll-context replies must not pull the reader backwards.
    if (!force && this.pendingPages) return;
    if (!force && page === this.page) return;
    this.page = page;
    if (!this.ready) return;
    const cell = this.cells.find((element) => Number(element.dataset.cell) === page);
    if (cell)
      this.host.scrollTop +=
        cell.getBoundingClientRect().top - this.host.getBoundingClientRect().top - 24;
  }
  trackCell() {
    cancelAnimationFrame(this.frame);
    this.frame = requestAnimationFrame(() => {
      const top = this.host.getBoundingClientRect().top + 30;
      const cell = [...this.visible]
        .filter((el) => el.getBoundingClientRect().bottom > top)
        .sort((a, b) => Number(a.dataset.cell) - Number(b.dataset.cell))[0];
      if (!this.ready || !cell) return;
      const page = Number(cell.dataset.cell);
      if (page !== this.page) {
        this.page = page;
        this.pendingPages++;
        Promise.resolve(this.onPage(page))
          .finally(() => {
            this.pendingPages--;
          })
          .catch(() => {});
      }
    });
  }
  destroy() {
    this.abort.abort();
    this.observer?.disconnect();
    cancelAnimationFrame(this.frame);
    for (const url of this.urls) URL.revokeObjectURL(url);
  }
}
