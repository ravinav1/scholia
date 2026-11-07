const DEFAULT_PRINT_RESOLUTION = 150;
const PDF_POINTS_PER_INCH = 72;

function abortError() {
  return new DOMException('PDF printing was cancelled.', 'AbortError');
}

function throwIfAborted(signal) {
  if (signal?.aborted) throw abortError();
}

function canvasBlob(canvas) {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (blob) resolve(blob);
      else reject(new Error('Chrome could not prepare a PDF page for printing.'));
    }, 'image/png');
  });
}

function waitForImage(image) {
  return new Promise((resolve, reject) => {
    image.addEventListener('load', resolve, { once: true });
    image.addEventListener('error', () => reject(new Error('A prepared PDF page could not be loaded.')), { once: true });
  });
}

function printPageStyle(document, size) {
  const style = document.createElement('style');
  style.dataset.scholiaPdfPrintPage = 'true';
  style.textContent = `@page { size: ${size.width}pt ${size.height}pt; margin: 0; }`;
  document.head.append(style);
  return style;
}

export async function preparePdfPrint({
  pdfDocument,
  pdfjs,
  printContainer,
  document = globalThis.document,
  signal,
  resolution = DEFAULT_PRINT_RESOLUTION,
  onProgress = () => {}
}) {
  if (!pdfDocument || !Number.isInteger(pdfDocument.numPages) || pdfDocument.numPages < 1) {
    throw new Error('Open a PDF before printing.');
  }
  if (!printContainer || !document) throw new Error('The PDF print surface is unavailable.');

  const blobUrls = [];
  const scratchCanvas = document.createElement('canvas');
  const printUnits = Math.max(72, Number(resolution) || DEFAULT_PRINT_RESOLUTION) / PDF_POINTS_PER_INCH;
  const optionalContentConfigPromise = pdfDocument.getOptionalContentConfig({ intent: 'print' });
  const printAnnotationStorage = await (pdfDocument.annotationStorage?.print || Promise.resolve());
  let pageStyle = null;
  let destroyed = false;

  const destroy = () => {
    if (destroyed) return;
    destroyed = true;
    scratchCanvas.width = 0;
    scratchCanvas.height = 0;
    printContainer.replaceChildren();
    pageStyle?.remove();
    for (const url of blobUrls) URL.revokeObjectURL(url);
    document.body.removeAttribute('data-pdf-printing');
  };

  try {
    printContainer.replaceChildren();
    document.body.setAttribute('data-pdf-printing', 'true');
    for (let pageNumber = 1; pageNumber <= pdfDocument.numPages; pageNumber += 1) {
      throwIfAborted(signal);
      onProgress(pageNumber - 1, pdfDocument.numPages);
      const page = await pdfDocument.getPage(pageNumber);
      throwIfAborted(signal);
      const viewport = page.getViewport({ scale: 1 });
      if (!pageStyle) pageStyle = printPageStyle(document, viewport);

      scratchCanvas.width = Math.max(1, Math.floor(viewport.width * printUnits));
      scratchCanvas.height = Math.max(1, Math.floor(viewport.height * printUnits));
      const context = scratchCanvas.getContext('2d', { alpha: false });
      context.save();
      context.fillStyle = 'rgb(255, 255, 255)';
      context.fillRect(0, 0, scratchCanvas.width, scratchCanvas.height);
      context.restore();

      const renderTask = page.render({
        canvasContext: context,
        transform: [printUnits, 0, 0, printUnits, 0, 0],
        viewport,
        intent: 'print',
        annotationMode: pdfjs.AnnotationMode.ENABLE_STORAGE,
        optionalContentConfigPromise,
        printAnnotationStorage
      });
      const cancelRender = () => renderTask.cancel();
      signal?.addEventListener('abort', cancelRender, { once: true });
      try {
        await renderTask.promise;
      } finally {
        signal?.removeEventListener('abort', cancelRender);
      }
      throwIfAborted(signal);

      const blob = await canvasBlob(scratchCanvas);
      throwIfAborted(signal);
      const blobUrl = URL.createObjectURL(blob);
      blobUrls.push(blobUrl);
      const image = document.createElement('img');
      image.alt = `PDF page ${pageNumber}`;
      const imageReady = waitForImage(image);
      image.src = blobUrl;
      const wrapper = document.createElement('div');
      wrapper.className = 'printed-page';
      wrapper.style.width = `${viewport.width}pt`;
      wrapper.style.height = `${viewport.height}pt`;
      wrapper.append(image);
      printContainer.append(wrapper);
      await imageReady;
    }
    throwIfAborted(signal);
    onProgress(pdfDocument.numPages, pdfDocument.numPages);
    return { destroy, pageCount: pdfDocument.numPages };
  } catch (error) {
    destroy();
    throw error;
  }
}

export { DEFAULT_PRINT_RESOLUTION };
