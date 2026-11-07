import test from 'node:test';
import assert from 'node:assert/strict';
import { canonicalSiteUrl, crawlSite } from '../../apps/chrome/src/site-context.js';

test('site crawl URLs stay on-origin and omit unsafe or non-HTML targets', () => {
  const site = 'https://databaser.dog/kap7/';
  assert.equal(canonicalSiteUrl('../kap8/?from=nav#acid', site), 'https://databaser.dog/kap8/');
  assert.equal(canonicalSiteUrl('/index.html', site), 'https://databaser.dog/');
  assert.equal(canonicalSiteUrl('https://other.example/chapter', site), '');
  assert.equal(canonicalSiteUrl('/slides/queries.pdf', site), '');
  assert.equal(canonicalSiteUrl('/logout/', site), '');
  assert.equal(canonicalSiteUrl('mailto:tutor@example.com', site), '');
});

test('site crawler follows a bounded same-origin graph and deduplicates pages', async () => {
  const graph = new Map([
    ['https://course.example/', {
      title: 'Course home', text: 'Course overview',
      links: ['/chapter-1/', '/chapter-2/', 'https://outside.example/nope']
    }],
    ['https://course.example/chapter-1/', {
      title: 'Chapter one', text: 'Relational algebra', links: ['/chapter-2/', '/chapter-1/topic/']
    }],
    ['https://course.example/chapter-2/', {
      title: 'Chapter two', text: 'Transactions and recovery', links: ['/assets/slides.pdf']
    }],
    ['https://course.example/chapter-1/topic/', {
      title: 'Topic', text: 'Join algorithms', links: []
    }]
  ]);
  const requested = [];
  const result = await crawlSite({
    startUrl: 'https://course.example/',
    initialPage: { url: 'https://course.example/', ...graph.get('https://course.example/') },
    fetchPage: async (url) => {
      requested.push(url);
      return graph.get(url) || null;
    },
    concurrency: 2,
    maxDurationMs: 5_000
  });

  assert.deepEqual(result.pages.map((page) => page.title), [
    'Course home', 'Chapter one', 'Chapter two', 'Topic'
  ]);
  assert.deepEqual(requested, [
    'https://course.example/chapter-1/',
    'https://course.example/chapter-2/',
    'https://course.example/chapter-1/topic/'
  ]);
  assert.equal(result.truncated, false);
  assert.equal(result.discoveredPages, 4);
});

test('site crawler reports its safety cap', async () => {
  const result = await crawlSite({
    startUrl: 'https://course.example/',
    initialPage: {
      url: 'https://course.example/', title: 'Home', text: 'Home',
      links: ['/one/', '/two/', '/three/']
    },
    fetchPage: async (url) => ({ title: url, url, text: 'Page text', links: [] }),
    maxPages: 2
  });
  assert.equal(result.pages.length, 2);
  assert.equal(result.truncated, true);
  assert.equal(result.discoveredPages, 4);
});
