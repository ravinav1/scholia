/** Map a viewport selection to the actual canvas backing pixels. X and Y can
 * differ after CSS sizing and integer canvas rounding; DPR must not be applied
 * again because the backing dimensions already include it. */
export function pdfRegionPixels(selection, canvasBounds, pixelWidth, pixelHeight) {
  if (
    ![
      selection.left,
      selection.top,
      selection.width,
      selection.height,
      canvasBounds.left,
      canvasBounds.top,
      canvasBounds.width,
      canvasBounds.height,
      pixelWidth,
      pixelHeight,
    ].every(Number.isFinite) ||
    canvasBounds.width <= 0 ||
    canvasBounds.height <= 0 ||
    pixelWidth <= 0 ||
    pixelHeight <= 0
  )
    return null;
  const left = Math.max(selection.left, canvasBounds.left),
    top = Math.max(selection.top, canvasBounds.top);
  const right = Math.min(selection.left + selection.width, canvasBounds.left + canvasBounds.width);
  const bottom = Math.min(selection.top + selection.height, canvasBounds.top + canvasBounds.height);
  if (right <= left || bottom <= top) return null;
  const sx = pixelWidth / canvasBounds.width,
    sy = pixelHeight / canvasBounds.height;
  const x = Math.max(0, Math.floor((left - canvasBounds.left) * sx)),
    y = Math.max(0, Math.floor((top - canvasBounds.top) * sy));
  return {
    x,
    y,
    width: Math.min(pixelWidth, Math.ceil((right - canvasBounds.left) * sx)) - x,
    height: Math.min(pixelHeight, Math.ceil((bottom - canvasBounds.top) * sy)) - y,
  };
}

export function capturePDFRegion(canvas, selection) {
  const rect = pdfRegionPixels(
    selection,
    canvas.getBoundingClientRect(),
    canvas.width,
    canvas.height
  );
  if (!rect || rect.width < 2 || rect.height < 2) return null;
  const image = document.createElement('canvas'),
    scale = Math.min(1, 1800 / Math.max(rect.width, rect.height));
  image.width = Math.max(1, Math.round(rect.width * scale));
  image.height = Math.max(1, Math.round(rect.height * scale));
  const context = image.getContext('2d');
  context.fillStyle = '#fff';
  context.fillRect(0, 0, image.width, image.height);
  context.drawImage(
    canvas,
    rect.x,
    rect.y,
    rect.width,
    rect.height,
    0,
    0,
    image.width,
    image.height
  );
  return image.toDataURL('image/jpeg', 0.9).split(',')[1];
}
