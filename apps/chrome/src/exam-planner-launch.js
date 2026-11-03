export const EXAM_WORKSPACE_KEY = 'scholia.exam-workspace-url.v1';
export const DEFAULT_EXAM_WORKSPACE_URL = 'http://127.0.0.1:8792/';

export function examWorkspaceUrl(value = DEFAULT_EXAM_WORKSPACE_URL) {
  let url;
  try { url = new URL(String(value).trim()); } catch {
    throw new Error('Enter the full address of your Scholia website, including https:// or http://.');
  }
  const local = url.hostname === 'localhost' || url.hostname.endsWith('.localhost')
    || url.hostname === '[::1]' || /^127(?:\.\d{1,3}){3}$/.test(url.hostname);
  if (url.username || url.password || url.search) {
    throw new Error('Use the Scholia website address without credentials or query parameters.');
  }
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && local)) {
    throw new Error('Use HTTPS for your Scholia website, or HTTP for a website on this device.');
  }
  url.hash = '';
  return url.href;
}

export async function loadExamWorkspaceUrl() {
  const saved = await chrome.storage.local.get(EXAM_WORKSPACE_KEY);
  return examWorkspaceUrl(saved[EXAM_WORKSPACE_KEY] || DEFAULT_EXAM_WORKSPACE_URL);
}

export async function saveExamWorkspaceUrl(value) {
  const url = examWorkspaceUrl(value);
  await chrome.storage.local.set({ [EXAM_WORKSPACE_KEY]: url });
  return url;
}

export async function openExamPlanner(value) {
  const url = new URL(value === undefined ? await loadExamWorkspaceUrl() : examWorkspaceUrl(value));
  url.hash = 'exams';
  // Navigation only: exam details and Studentweb sign-in stay in their own pages.
  return chrome.tabs.create({ url: url.href, active: true });
}
