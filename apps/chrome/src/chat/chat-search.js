const MAX_CHAT_SEARCH_RESULTS = 500;

function searchableMessageText(message) {
  const attachment = message?.attachment?.text;
  return [message?.content, message?.reasoning, attachment, ...(message?.files || []).flatMap((file) => [file.name, file.text])]
    .filter((value) => typeof value === 'string' && value)
    .join('\n');
}

export function matchingMessageIndexes(messages, rawQuery, limit = MAX_CHAT_SEARCH_RESULTS) {
  const query = String(rawQuery || '').trim().toLowerCase();
  if (!query || !Array.isArray(messages) || limit <= 0) return [];

  const matches = [];
  for (const [index, entry] of messages.entries()) {
    if (searchableMessageText(entry).toLowerCase().includes(query)) matches.push(index);
    if (matches.length >= limit) break;
  }
  return matches;
}

export function searchRanges(text, rawQuery, limit = MAX_CHAT_SEARCH_RESULTS) {
  const source = String(text || '');
  const query = String(rawQuery || '').trim();
  if (!source || !query || limit <= 0) return [];

  const haystack = source.toLowerCase();
  const needle = query.toLowerCase();
  const ranges = [];
  let cursor = 0;
  while (cursor <= haystack.length - needle.length && ranges.length < limit) {
    const start = haystack.indexOf(needle, cursor);
    if (start < 0) break;
    ranges.push({ start, end: start + needle.length });
    cursor = start + needle.length;
  }
  return ranges;
}

export function movedSearchIndex(currentIndex, resultCount, direction) {
  if (!Number.isInteger(resultCount) || resultCount <= 0) return -1;
  const step = direction < 0 ? -1 : 1;
  const current = Number.isInteger(currentIndex) && currentIndex >= 0
    ? currentIndex
    : step < 0 ? 0 : -1;
  return (current + step + resultCount) % resultCount;
}

export { MAX_CHAT_SEARCH_RESULTS };
