const MAX_VERSION_COMPONENT = 65_535;
const VERSION_PATTERN = /^(?:0|[1-9]\d*)(?:\.(?:0|[1-9]\d*)){0,3}$/;

export function chromeVersionParts(value) {
  const version = String(value || '').trim();
  if (!VERSION_PATTERN.test(version)) return null;
  const parts = version.split('.').map(Number);
  if (parts.some((part) => part > MAX_VERSION_COMPONENT) || parts.every((part) => part === 0)) return null;
  return parts;
}

export function isChromeExtensionVersion(value) {
  return chromeVersionParts(value) !== null;
}

function compareChromeVersions(left, right) {
  const leftParts = chromeVersionParts(left);
  const rightParts = chromeVersionParts(right);
  if (!leftParts || !rightParts) return null;
  for (let index = 0; index < 4; index += 1) {
    const difference = (leftParts[index] || 0) - (rightParts[index] || 0);
    if (difference) return Math.sign(difference);
  }
  return 0;
}

function incrementChromeVersion(value) {
  const parts = chromeVersionParts(value);
  if (!parts) return null;
  while (parts.length < 4) parts.push(0);
  for (let index = parts.length - 1; index >= 0; index -= 1) {
    if (parts[index] < MAX_VERSION_COMPONENT) {
      parts[index] += 1;
      return parts.join('.');
    }
    parts[index] = 0;
  }
  throw new Error(`Chrome extension version ${value} cannot be incremented.`);
}

export function localChromeExtensionVersion(date = new Date(), previousVersion = '') {
  if (!(date instanceof Date) || Number.isNaN(date.valueOf())) throw new TypeError('A valid build date is required.');
  const version = [
    date.getUTCFullYear(),
    (date.getUTCMonth() + 1) * 100 + date.getUTCDate(),
    date.getUTCHours() * 100 + date.getUTCMinutes(),
    date.getUTCSeconds() * 1000 + date.getUTCMilliseconds()
  ].join('.');
  if (!isChromeExtensionVersion(version)) throw new Error(`Generated invalid Chrome extension version ${version}.`);
  return compareChromeVersions(version, previousVersion) === 1
    ? version
    : incrementChromeVersion(previousVersion) || version;
}
