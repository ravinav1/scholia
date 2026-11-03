import test from 'node:test';
import assert from 'node:assert/strict';
import { Canvas } from '../apps/server/canvas.js';
import { CourseWebsites, courseWebsiteSeeds, parseCourseWebsite } from '../apps/server/course-websites.js';
import { courseLinkTarget } from '../packages/core/src/course-documents.js';
import { withinWebsite, courseWebsiteLink, knownCourseWebsiteSeeds } from '../packages/core/src/course-websites.js';

const origin = 'https://canvas.ntnu.no', site = 'https://teaching.ntnu.no/tdt4120/2026h/';
const course = { code: 'TDT4120-26H', name: 'Algorithms', term: '2026 HØST', canvasOrigin: origin, canvasID: 1, canvasMaterials: [], documents: [] };

test('known teaching sites match an exact NTNU course code, including Canvas semester suffixes', () => {
  const expected = [{ url: 'https://algdat.idi.ntnu.no/', evidenceURL: 'https://algdat.idi.ntnu.no/' }];
  assert.deepEqual(knownCourseWebsiteSeeds(course), expected);
  assert.deepEqual(knownCourseWebsiteSeeds({ name: 'tdt4120 Algoritmer og datastrukturer' }), expected);
  assert.deepEqual(knownCourseWebsiteSeeds({ code: 'TDT4120' }), expected);
  assert.deepEqual(knownCourseWebsiteSeeds({ code: 'TDT41201' }), []);
  assert.deepEqual(knownCourseWebsiteSeeds({ ...course, code: 'TDT4121', name: 'Follow-up to TDT4120' }), []);
  assert.deepEqual(knownCourseWebsiteSeeds({ ...course, canvasOrigin: 'https://canvas.other.edu' }), []);
});

test('TDT4120 fetches its dedicated site without a Canvas link and keeps public resources in normal course search/import paths', async () => {
  const official = 'https://algdat.idi.ntnu.no/';
  const requested = [];
  let unavailable = false;
  const client = new Canvas(origin, 'private-fixture', { request: async (url, options) => {
    requested.push(url.href);
    if (url.origin === origin) {
      assert.equal(options.headers.Authorization, 'Bearer private-fixture');
      return { status: 200, headers: {}, data: Buffer.from(JSON.stringify(url.pathname === '/api/v1/courses/1' ? { syllabus_body: '' } : [])) };
    }
    assert.equal(url.origin + '/', official);
    assert.equal(options.headers.Authorization, undefined);
    assert.equal(options.headers.Cookie, undefined);
    if (unavailable) return { status: 503, headers: {}, data: Buffer.alloc(0) };
    if (options.method === 'HEAD') return { status: 200, headers: { etag: 'v1', 'content-length': '30' }, data: Buffer.alloc(0) };
    let body, type = 'text/html';
    if (url.pathname === '/') body = '<main><h1>TDT4120 Algorithms</h1><a href="forelesn.html">Lectures</a><a href="pensum.pdf">Syllabus</a><a href="ovinger.html">Exercises</a><a href="ovsys/">Exercise system</a><a href="inginious/course/TDT4120-2026">Submit exercises</a><a href="queue/">Queue</a><a href="login/">Sign in</a></main>';
    else if (url.pathname === '/forelesn.html') body = '<main><h1>Forelesninger</h1><a href="lysark/01.pdf">Lecture 1</a><a href="/">Home</a></main>';
    else if (url.pathname === '/ovinger.html') body = '<title>Redirecting</title><meta http-equiv="refresh" content="0; url=/%C3%B8vinger.html"><script>throw new Error("Never execute this")</script>';
    else if (url.pathname === '/%C3%B8vinger.html') body = '<main><h1>Øvinger</h1><p>Practice algorithms each week.</p></main>';
    else if (url.pathname.endsWith('.pdf')) { body = '%PDF-1.4 public course notes'; type = 'application/pdf'; }
    else assert.fail(`Unexpected dedicated-site request ${url.href}`);
    return { status: 200, headers: { 'content-type': type }, data: Buffer.from(body) };
  } });
  const catalog = await client.catalog(course);
  assert.deepEqual(catalog.warnings, []);
  assert.equal(catalog.items.length, 5);
  assert.ok(catalog.items.every(ref => ref.websiteRootURL === official && ref.websiteEvidenceURL === official));
  assert.equal(requested.filter(url => url === official).length, 1);
  assert.ok(!requested.some(url => /\/(ovsys|login|inginious|queue)\//.test(url)));
  assert.ok(catalog.items.some(ref => ref.sourceURL.endsWith('/%C3%B8vinger.html')));
  assert.ok(!catalog.items.some(ref => ref.sourceURL.endsWith('/ovinger.html')));
  const slides = catalog.items.find(ref => ref.fileName === '01.pdf');
  assert.equal(slides.linkedFromTitle, 'Forelesninger');
  assert.equal(courseLinkTarget(slides.sourceURL, { ...course, canvasMaterials: catalog.items }).material.id, slides.id);
  assert.match((await client.material(slides, course)).data.toString(), /^%PDF-/);
  const page = catalog.items.find(ref => ref.sourceURL.endsWith('forelesn.html'));
  assert.match((await client.material(page, course)).data.toString(), /<base href=/);

  unavailable = true;
  const failed = await client.catalog({ ...course, canvasMaterials: catalog.items });
  assert.equal(failed.items.length, 5);
  assert.deepEqual(failed.changes.removed, []);
  assert.match(failed.warnings.join(), /503/);

  requested.length = 0;
  await client.catalog(course, { includePublic: false });
  assert.ok(requested.every(url => new URL(url).origin === origin), 'Extra Canvas polls must still skip public sites');
});

test('HTML course redirects stay inside the teaching site and stop loops and login targets', async () => {
  const requested = [];
  const websites = new CourseWebsites({ request: async (url) => {
    requested.push(url.href);
    let body;
    if (url.href === site) body = '<main><h1>Course</h1><a href="outside.html">Outside</a><a href="private.html">Private</a><a href="loop.html">Loop</a></main>';
    else if (url.pathname.endsWith('outside.html')) body = '<meta http-equiv="refresh" content="0; url=https://elsewhere.ntnu.no/">';
    else if (url.pathname.endsWith('private.html')) body = '<meta http-equiv="refresh" content="0; url=queue/">';
    else if (url.pathname.endsWith('loop.html')) body = '<meta http-equiv="refresh" content="0; url=loop.html">';
    else assert.fail(`Unexpected redirect request ${url.href}`);
    return { status: 200, headers: {}, data: Buffer.from(body) };
  } });
  const result = await websites.catalog(course, [{ url: site }]);
  assert.equal(result.items.length, 1);
  assert.equal(result.warnings.length, 3);
  assert.equal(result.complete, false);
  assert.ok(requested.every(url => url.startsWith(site) && !url.includes('/queue/')));
  assert.equal(requested.filter(url => url.endsWith('loop.html')).length, 4);
});

test('an old-exam-only discovery does not suppress the dedicated teaching site', async () => {
  const requested = [];
  const websites = new CourseWebsites({ request: async (url) => {
    requested.push(url.href);
    return { status: 200, headers: {}, data: Buffer.from('<main><h1>Course resources</h1></main>') };
  } });
  const archive = { url: 'https://teaching.ntnu.no/tdt4120/exams/', filesOnly: true };
  const result = await websites.catalog(course, [archive]);
  assert.deepEqual(new Set(requested), new Set([archive.url, 'https://algdat.idi.ntnu.no/']));
  assert.equal(result.items.length, 2);
});
function fixture({ failedSite = false } = {}) {
  const requested = [];
  const client = new Canvas(origin, 'private-fixture', { request: async (url, options) => {
    requested.push(url.href);
    let body = [], headers = {}, status = 200;
    if (url.origin === origin) {
      assert.equal(options.headers.Authorization, 'Bearer private-fixture');
      if (url.pathname.endsWith('/discussion_topics')) {
        assert.equal(url.searchParams.get('only_announcements'), 'true');
        if (url.searchParams.has('page')) body = [{ message: `<p>We use this course website for all lecture notes: <a href='${site}'>here</a>.</p>`, html_url: origin + '/courses/1/discussion_topics/2' }];
        else { body = [{ message: 'Recent announcement with no site link' }]; headers.link = `<${origin}/api/v1/courses/1/discussion_topics?only_announcements=true&page=2>; rel="next"`; }
      }
      if (url.pathname.endsWith('/modules')) body = [{ id: 1, name: 'Links', items_count: 1, items: [{ type: 'ExternalUrl', title: 'Course homepage', external_url: site }] }];
      if (url.pathname === '/api/v1/courses/1') body = { syllabus_body: `<a href='${site}'>Course website</a>` };
      return { status, headers, data: Buffer.from(JSON.stringify(body)) };
    }
    assert.equal(options.headers.Authorization, undefined);
    assert.equal(options.headers.Cookie, undefined);
    if (failedSite) return { status: 503, headers, data: Buffer.alloc(0) };
    if (options.method === 'HEAD') return { status, headers: { etag: 'file-v1', 'content-length': '30' }, data: Buffer.alloc(0) };
    if (url.href === site) body = `<html><head><title>Algorithms, Autumn 2026</title></head><body><main><h1>Algorithms, Autumn 2026</h1>
      <a href='weeks/one.html'>Week 1</a><a href='notes.pdf'>Lecture notes</a>
      <a href='../2025h/'>Wrong semester</a><a href='/tdt4120/2026h-other/'>Outside</a>
      <a href='?action=logout'>Log out</a><a href='javascript:alert(1)'>Script</a></main></body></html>`;
    else if (url.href === site + 'weeks/one.html') body = `<html><body><h1>Week one</h1><a href='../'>Back</a><a href='https://folk.ntnu.no/teacher/algorithms.ipynb'>Notebook</a></body></html>`;
    else if (url.pathname.endsWith('.pdf')) { body = '%PDF-1.4 notes'; headers['content-type'] = 'application/pdf'; }
    else if (url.pathname.endsWith('.ipynb')) body = '{"cells":[]}';
    else assert.fail(`Unexpected website request ${url.href}`);
    return { status, headers, data: Buffer.from(body) };
  } });
  return { client, requested };
}

test('older paginated announcements, syllabus and module URLs discover one bounded course website and its attachments', async () => {
  const { client, requested } = fixture();
  const catalog = await client.catalog(course);
  assert.deepEqual(catalog.warnings, []);
  assert.equal(catalog.items.length, 4);
  assert.equal(requested.filter(url => url === site).length, 1, 'same site in three sources is crawled once');
  assert.ok(requested.some(url => url.includes('only_announcements=true&page=2')));
  assert.ok(!requested.some(url => /2025h|2026h-other|logout/.test(url)));
  assert.ok(catalog.items.every(ref => ref.websiteRootURL === site));
  const pdf = catalog.items.find(ref => ref.fileName === 'notes.pdf');
  assert.equal((await client.material(pdf, course)).data.toString(), '%PDF-1.4 notes');
  assert.equal(courseLinkTarget(pdf.sourceURL, { ...course, canvasMaterials: catalog.items }).material.id, pdf.id);
  const next = fixture({ failedSite: true });
  const result = await next.client.catalog({ ...course, canvasMaterials: catalog.items });
  assert.equal(result.items.length, 4);
  assert.deepEqual(result.changes.removed, []);
  assert.match(result.warnings.join(), /503/);
});

test('announcement hints avoid unrelated references and institutional course descriptions', () => {
  const sources = [{ url: origin + '/courses/1/announcements', html: `<p>Our course website is <a href='https://algorithms.example.org/'>here</a>.</p>
    <p>Reference: <a href='https://random.example.org/'>external article</a></p>
    <p><a href='https://www.ntnu.no/studier/emner/TDT4120'>Official course description</a></p>
    <p><a href='https://youtube.com/tdt4120'>Recording</a></p>` }];
  assert.deepEqual(courseWebsiteSeeds(sources, course).map(seed => seed.url), ['https://algorithms.example.org/']);
  assert.equal(withinWebsite('https://teaching.ntnu.no/tdt4120/2026h-other/', site), false);
  assert.equal(withinWebsite('https://folk.ntnu.no/teacher/OTHER1000.html', 'https://folk.ntnu.no/teacher/TFY4345.html'), false);
  assert.equal(courseWebsiteLink('https://web.phys.ntnu.no/ovsys/admin/studentliste.php?course=TFY4115'), null);
  const file = courseWebsiteLink('https://www.ntnu.no/documents/10422/123/Exam.pdf/abcd-1234?t=123');
  assert.equal(file.kind, 'files');
  assert.equal(file.fileName, 'Exam.pdf');
  assert.equal(file.url, 'https://www.ntnu.no/documents/10422/123/Exam.pdf/abcd-1234');
  assert.equal(withinWebsite('https://teaching.ntnu.no/hub/login', 'https://teaching.ntnu.no/'), false);
  assert.equal(courseWebsiteLink('https://github.com/teacher/notes/edit/main/chapter.ipynb'), null);
  assert.equal(courseWebsiteLink('https://colab.research.google.com/github/teacher/notes/blob/main/chapter.ipynb').url,
    'https://raw.githubusercontent.com/teacher/notes/main/chapter.ipynb');
});

test('course entry redirects and NTNU short links resolve to teaching sites without importing login pages', async () => {
  const requested = [];
  const websites = new CourseWebsites({ request: async (url, options) => {
    requested.push(url.href);
    assert.deepEqual(options.headers, {});
    if (url.pathname === '/shortcourse') return { status: 200, headers: {}, data: Buffer.from(`<title>Shorty · Shorty</title><a class='action-button' href='${site}'>Yes, take me there!</a>`) };
    if (url.pathname === '/redirect') return { status: 302, headers: { location: site }, data: Buffer.alloc(0) };
    if (url.pathname === '/old') return { status: 302, headers: { location: site.replace('2026h', '2025h') }, data: Buffer.alloc(0) };
    if (url.pathname === '/private') return { status: 302, headers: { location: '/hub/login' }, data: Buffer.alloc(0) };
    assert.equal(url.href, site);
    return { status: 200, headers: {}, data: Buffer.from('<html><body><h1>Algorithms Autumn 2026</h1><p>Lecture notes</p></body></html>') };
  } });
  const result = await websites.catalog(course, ['https://s.ntnu.no/shortcourse', 'https://teaching.ntnu.no/redirect', 'https://teaching.ntnu.no/private', 'https://teaching.ntnu.no/old'].map(url => ({ url })));
  assert.equal(result.items.length, 1);
  assert.equal(result.items[0].websiteRootURL, site);
  assert.equal(result.warnings.length, 2);
  assert.equal(result.complete, false);
  assert.ok(!requested.some(url => /hub\/login|2025h/.test(url)));
  assert.throws(() => parseCourseWebsite('<html><head><title>JupyterHub</title></head><body>Sign in with Feide</body></html>'), /sign-in/);
  assert.throws(() => parseCourseWebsite('<html><head><title>Shorty · Shorty</title></head><body>Continue</body></html>'), /link-shortener/);
});
