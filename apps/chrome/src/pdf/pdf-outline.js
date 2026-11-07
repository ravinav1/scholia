export function pdfOutlineItemCount(items) {
  if (!Array.isArray(items) || !items.length) return 0;
  let count = 0;
  const stack = [...items];
  while (stack.length) {
    const item = stack.pop();
    if (!item || typeof item !== 'object') continue;
    count += 1;
    if (Array.isArray(item.items)) stack.push(...item.items);
  }
  return count;
}

export function activePdfOutlineEntry(entries, pageNumber) {
  if (!Array.isArray(entries) || !Number.isInteger(pageNumber) || pageNumber < 1) return null;
  let active = null;
  for (const entry of entries) {
    if (!Number.isInteger(entry?.pageNumber) || entry.pageNumber > pageNumber) continue;
    if (!active
        || entry.pageNumber > active.pageNumber
        || (entry.pageNumber === active.pageNumber && (entry.order ?? 0) > (active.order ?? 0))) {
      active = entry;
    }
  }
  return active;
}
