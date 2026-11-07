import test from 'node:test';
import assert from 'node:assert/strict';
import { DOMParser } from 'linkedom';
import { researchUrl, researchLinksFromDocument, promptResearchLinks } from '../apps/chrome/src/research-links.js';
import { crawlResearch, packResearchContext } from '../apps/chrome/src/research-crawl.js';
import { createResearchAccess, fetchResearchPage } from '../apps/chrome/src/browser-research.js';
import { normalizeChatRecord } from '../apps/chrome/src/chat/chat-history.js';

test('research retains meaningful queries, deduplicates tracking, and refuses actions and credentials', () => {
  assert.equal(researchUrl('/notes?chapter=2&utm_source=mail#heading', 'https://course.test/'), 'https://course.test/notes?chapter=2');
  for (const url of ['/logout', '/submissions/submit', '/files/4/delete', '/%64elete', '/account/reset', '/login',
    '/page?action=destroy', '/page?delete=true', '/page?token=secret', 'javascript:alert(1)', 'https://user:pass@course.test/']) {
    assert.equal(researchUrl(url, 'https://course.test'), '', url);
  }
  assert.deepEqual(promptResearchLinks('Read https://course.test/?page=2, and [notes](https://other.test/notes).').map(x => x.url),
    ['https://course.test/?page=2', 'https://other.test/notes']);
  const doc = new DOMParser().parseFromString('<html><body><a href="/notes">Diffusion</a><a href="/notes#same">Duplicate</a><a href="https://other.test/course">Course</a><a data-method="post" href="/update">Update</a><form><a href="/confirm">Confirm</a></form></body></html>', 'text/html');
  assert.deepEqual(researchLinksFromDocument(doc, 'https://course.test/').map(x => x.url), ['https://course.test/notes', 'https://other.test/course']);
});

test('normal mode requires site decisions, remembers denials for this run, and never silently approves', async () => {
  const reviewed = [];
  const access = createResearchAccess({ settings: {}, review: async sites => {
    reviewed.push(sites.map(site => site.origin)); return ['https://course.test'];
  } });
  const links = [{ url: 'https://course.test/notes' }, { url: 'https://other.test/wiki' }];
  assert.deepEqual([...await access.approve(links)], ['https://course.test']);
  assert.deepEqual([...await access.approve(links)], ['https://course.test']);
  assert.equal(reviewed.length, 1);
  assert.equal((await createResearchAccess({ settings: {} }).approve(links)).size, 0);
});

test('YOLO skips review but still enforces site restrictions and cancellation', async () => {
  const controller = new AbortController();
  const access = createResearchAccess({ settings: { siteAccessMode: 'allowlist', allowedSites: ['course.test'] }, yolo: true,
    signal: controller.signal, review: () => { throw new Error('YOLO should not review'); } });
  const approved = await access.approve([{ url: 'https://course.test/notes' }, { url: 'https://other.test/private' }]);
  assert.deepEqual([...approved], ['https://course.test']);
  assert.equal(access.canRead('https://course.test/logout'), false);
  controller.abort();
  await assert.rejects(access.approve([{ url: 'https://course.test/notes' }]), { name: 'AbortError' });
});

test('each prompt prioritizes different links, follows cross-site and multi-hop evidence, and preserves citations', async () => {
  const initial = { url: 'https://course.test/', title: 'Course', text: 'Course overview', links: [
    { url: '/algebra', title: 'Algebra' }, { url: '/diffusion', title: 'Diffusion' }
  ] };
  const read = [];
  const readPage = async url => {
    read.push(url);
    return { url, title: 'Diffusion notes', text: 'Diffusion coefficient is measured in square metres per second.',
      links: url.endsWith('/diffusion') ? [{ url: 'https://wiki.test/diffusion?chapter=2', title: 'More diffusion' }] : [] };
  };
  await crawlResearch({ question: 'Find diffusion', initialPages: [initial], maxRequests: 1, approve: async () => true, readPage });
  assert.equal(read[0], 'https://course.test/diffusion');
  read.length = 0;
  await crawlResearch({ question: 'Find algebra', initialPages: [initial], maxRequests: 1, approve: async () => true, readPage });
  assert.equal(read[0], 'https://course.test/algebra');
  const result = await crawlResearch({ question: 'Find diffusion', initialPages: [initial], approve: async () => true, readPage });
  assert.ok(result.pages.some(page => page.url === 'https://wiki.test/diffusion?chapter=2'));
  const packed = packResearchContext(result, { question: 'diffusion coefficient', maxChars: 6000 });
  assert.match(packed, /URL: https:\/\/wiki.test\/diffusion\?chapter=2/);
  assert.match(packed, /square metres per second/);
  assert.ok(packed.length <= 6000);
});

test('cycles, duplicates and failed reads stay within the attempt budget', async () => {
  let calls = 0;
  const result = await crawlResearch({ question: 'Find notes', links: Array.from({ length: 60 }, (_, i) => ({ url: `https://course.test/${i}` })),
    maxRequests: 5, approve: async () => true, readPage: async () => { calls++; throw new Error('Denied'); } });
  assert.equal(calls, 5); assert.equal(result.failures.length, 5); assert.equal(result.truncated, true);
  calls = 0;
  const cycle = await crawlResearch({ links: [{ url: 'https://course.test/a' }], approve: async () => true,
    readPage: async url => { calls++; return { url, text: 'Notes', links: [{ url }, { url: 'https://course.test/b' }] }; } });
  assert.equal(calls, 2); assert.equal(cycle.pages.length, 2);
});

test('Stop during approval performs no read; Stop during reads aborts every in-flight request and never follows children', async () => {
  const pending = new AbortController(); let reads = 0;
  await assert.rejects(crawlResearch({ links: [{ url: 'https://course.test/start' }], signal: pending.signal,
    approve: async () => { pending.abort(); return true; }, readPage: async () => { reads++; } }), { name: 'AbortError' });
  assert.equal(reads, 0);
  const active = new AbortController(); const aborted = [];
  await assert.rejects(crawlResearch({ links: [1, 2, 3, 4].map(i => ({ url: `https://course.test/${i}` })), signal: active.signal,
    approve: async () => true, readPage: async (url, { signal }) => new Promise((resolve, reject) => {
      reads++; signal.addEventListener('abort', () => { aborted.push(url); reject(signal.reason); }, { once: true });
      if (reads === 3) queueMicrotask(() => active.abort());
    }) }), { name: 'AbortError' });
  assert.equal(reads, 3); assert.equal(aborted.length, 3);
});

test('reader makes only GET requests, blocks unapproved URLs, and does not silently follow redirects', async () => {
  const requests = [];
  const fetchImpl = async (url, options) => { requests.push({ url, options }); return new Response('Diffusion evidence', { headers: { 'content-type': 'text/plain' } }); };
  assert.equal((await fetchResearchPage('https://course.test/notes.txt', { fetchImpl })).text, 'Diffusion evidence');
  assert.equal(requests[0].options.method, 'GET');
  assert.equal(requests[0].options.redirect, 'error');
  await assert.rejects(fetchResearchPage('https://course.test/logout', { fetchImpl }));
  await assert.rejects(fetchResearchPage('https://other.test/', { fetchImpl, canRead: () => false }));
  assert.equal(requests.length, 1);
  await assert.rejects(fetchResearchPage('https://course.test/huge', { fetchImpl: async () => new Response('', {
    headers: { 'content-type': 'text/plain', 'content-length': String(4 * 1024 * 1024) }
  }) }), /size limit/);
});

test('the network deadline cancels a slow reader and reports partial coverage', async () => {
  let aborted = false;
  const result = await crawlResearch({ links: [{ url: 'https://course.test/slow' }], maxDurationMs: 15,
    approve: async () => true, readPage: async (_url, { signal }) => new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Deadline did not abort')), 2000);
      signal.addEventListener('abort', () => { clearTimeout(timer); aborted = true; reject(signal.reason); }, { once: true });
    }) });
  assert.equal(aborted, true); assert.equal(result.truncated, true); assert.equal(result.requests, 1);
  assert.equal(result.pages.length, 0);
});

test('saved chats retain research controls and evidence URLs without credentials or inherited YOLO', () => {
  const record = normalizeChatRecord({ id: 'research-chat', capture: { followLinks: true, researchYolo: true,
    researchUrl: 'https://course.test/?page=2', researchSources: [{ url: 'https://course.test/notes', title: 'Notes' }, { url: 'https://course.test/file?token=secret' }] }, messages: [{ role: 'user', content: 'Find notes' }] });
  assert.equal(record.capture.followLinks, true); assert.equal(record.capture.researchYolo, true);
  assert.equal(record.capture.researchUrl, 'https://course.test/?page=2'); assert.equal(record.capture.researchSources.length, 1);
  assert.equal(normalizeChatRecord({ id: 'new-chat', messages: [{ role: 'user', content: 'Hello' }] }).capture.researchYolo, false);
});
