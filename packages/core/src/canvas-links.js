// Resolve only explicit Canvas resources. Queries such as wrap, verifier and
// module_item_id do not change identity and are never stored in the catalog.
export function canvasContentLink(value, origin, courseID, sourceURL = origin) {
  try {
    const url = new URL(value, sourceURL);
    if (url.origin !== origin || url.protocol !== 'https:' || url.username || url.password)
      return null;
    const path = url.pathname.replace(/^\/api\/v1\//, '/');
    const match = path.match(/^\/(?:courses\/(\d+)\/)?(files|pages|assignments)\/([^/]+)(?:\/(download|preview))?\/?$/);
    if (!match || (match[1] && String(courseID) !== match[1])) return null;
    const [, course, kind, encodedID, suffix] = match;
    const remoteID = decodeURIComponent(encodedID);
    if (kind !== 'files' && (!course || suffix)) return null;
    if (kind !== 'pages' && !/^[1-9]\d*$/.test(remoteID)) return null;
    if (!remoteID || /[/\u0000-\u001f]/.test(remoteID)) return null;
    return { id: `${kind}:${remoteID}`, kind, remoteID };
  } catch { return null; }
}

export function canvasDocumentLinks(doc, origin, courseID, sourceURL) {
  doc.querySelectorAll('script,style').forEach((node) => node.remove());
  const links = new Map();
  let section;
  for (const node of doc.querySelectorAll('h1,h2,h3,h4,h5,h6,[href],[src],[data-api-endpoint]')) {
    if (/^H[1-6]$/.test(node.tagName)) section = node.textContent.trim() || undefined;
    for (const attribute of ['href', 'src', 'data-api-endpoint']) {
      const value = node.getAttribute(attribute);
      if (!value) continue;
      const link = canvasContentLink(value, origin, courseID, sourceURL);
      if (link && !links.has(link.id)) links.set(link.id, { ...link, section });
    }
  }
  return [...links.values()];
}

