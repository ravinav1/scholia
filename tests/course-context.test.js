import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildCourseContext,
  courseMetadataContext,
  courseContextScope,
  isCourseScheduleQuestion,
  requestedReadingPages,
} from '../apps/server/course-context.js';

const course = (documents = [], canvasMaterials = []) => ({
  id: 'course-a',
  name: 'Course in geometric computing',
  code: 'MATH204',
  term: 'Autumn 2026',
  documents,
  canvasMaterials,
});
const document = (id) => ({ id, title: `Reading ${id}`, kind: 'text', pageCount: 3 });

test('schedule questions skip reading indexes but mixed and content questions retain retrieval', async () => {
  for (const question of ["What's due next?", 'When is Exercise 5 due?', 'List the deadlines']) {
    assert.equal(isCourseScheduleQuestion(question), true);
    const packed = await buildCourseContext({
      course: course([document('large')]), question,
      readIndex: () => assert.fail('A deadline lookup must not scan reading contents'),
    });
    assert.match(packed.context, /Reading contents were not loaded/);
    assert.equal(packed.sources.length, 0);
  }
  for (const question of ['When is the essay due and how should I structure it?', 'Explain what is due to electromagnetic induction', 'Summarize the course']) {
    assert.equal(isCourseScheduleQuestion(question), false);
  }
});

test('course catalog supports metadata-only questions without implying remote content is read', async () => {
  const c = course(
    [],
    [
      { id: 'files:1', kind: 'files', title: 'Remote syllabus', moduleTitle: 'Getting started' },
      {
        id: 'assignments:1',
        kind: 'assignments',
        title: 'First exercise',
        assignment: { dueAt: '2026-10-02T10:00:00+02:00', status: 'submitted' },
      },
    ]
  );
  const packed = await buildCourseContext({
    course: c,
    readIndex: () => assert.fail('No file to read'),
  });
  assert.match(packed.context, /MATH204[\s\S]*Autumn 2026/);
  assert.match(packed.context, /Remote syllabus \| remote only; contents unavailable/);
  assert.match(packed.context, /module: Getting started/);
  assert.match(
    packed.context,
    /First exercise \| due: 2026-10-02T10:00:00\+02:00 \| submission: submitted/
  );
  assert.match(packed.context, /No readable excerpts/);
  assert.deepEqual(packed.sources, []);
});

test('course and reading context retain actual paper URLs and restore known links from legacy lists', async () => {
  const paperURL = 'https://doi.org/10.1136/medethics-2020-107095';
  const title = 'Before and beyond trust: reliance in medical AI';
  const syllabus = { ...document('syllabus'), title: 'Syllabus', sourceKey: 'pages:syllabus', sourceURL: 'https://canvas.example/courses/1/pages/syllabus' };
  const paper = { ...document('paper'), title, sourceKey: 'files:paper' };
  const c = course([syllabus, paper], [
    { id: paper.sourceKey, kind: 'files', title, sourceURL: paperURL, linkedFromID: syllabus.sourceKey },
    { id: 'remote', kind: 'files', title: 'Saving or Creating', sourceURL: 'https://doi.org/10.1080/15265161.2017.1340988' },
    { id: 'unsafe', kind: 'files', title: 'Unsafe reference', sourceURL: 'javascript:alert(1)' },
    { id: 'credentials', kind: 'files', title: 'Private reference', sourceURL: 'https://user:password@example.com/paper' },
    { id: 'oversized', kind: 'files', title: 'Long reference', sourceURL: 'https://example.com/' + 'x'.repeat(2100) },
  ]);
  const readIndex = async (doc) => ({ pages: [{ number: 1, text: doc.id === syllabus.id ? title : 'Paper excerpt.' }] });
  const packed = await buildCourseContext({ course: c, question: 'Suggest an essay reading about medical AI', readIndex });
  assert.ok(packed.context.includes(`[${title}](${paperURL})`));
  assert.ok(packed.context.includes(`Source URL (this document): ${syllabus.sourceURL}`));
  assert.ok(packed.context.includes(`Source URL (this document): ${paperURL}`));
  assert.match(packed.context, /Saving or Creating \| remote only; contents unavailable \| source URL: https:\/\/doi.org\/10.1080\/15265161.2017.1340988/);
  assert.doesNotMatch(packed.context, /javascript:|user:password|https:\/\/example.com\/x/);
  assert.equal(packed.sources.some((source) => source.documentID === 'remote'), false);
  const readingOnly = await buildCourseContext({ course: c, readIndex, selectedDocument: paper, includeCourse: false, includeMetadata: false });
  assert.ok(readingOnly.context.includes(`Source URL (this document): ${paperURL}`));
  assert.doesNotMatch(readingOnly.context, /15265161|courses\/1\/pages\/syllabus/);
});

test('question retrieval reaches later documents and pages while tolerating an unavailable index', async () => {
  const documents = Array.from({ length: 30 }, (_, index) => document(String(index)));
  const read = [];
  const packed = await buildCourseContext({
    course: course(documents),
    question: 'Explain the zebraquantum result',
    readIndex: async (doc) => {
      read.push(doc.id);
      if (doc.id === '0') throw new Error('Missing file');
      return {
        pages: [
          { number: 1, text: 'An introduction to this reading.' },
          { number: 2, text: 'Routine background.' },
          {
            number: 3,
            text:
              doc.id === '27'
                ? 'The zebraquantum result is exactly 41 units.'
                : 'Further background.',
          },
        ],
      };
    },
  });
  assert.equal(read.length, 30);
  assert.match(packed.context, /zebraquantum result is exactly 41 units/);
  assert.match(packed.context, /Unavailable saved text: Reading 0/);
  assert.ok(packed.sources.some((source) => source.documentID === '27' && source.page === 3));
  assert.ok(packed.context.length <= 48_000);
});

test('reading-only scope honors context exclusion and keeps its selected page', async () => {
  const selected = document('selected'),
    other = document('other');
  const packed = await buildCourseContext({
    course: course([selected, other]),
    question: 'Explain the proof',
    selectedDocument: selected,
    selectedPage: 3,
    includeCourse: false,
    includeMetadata: false,
    readIndex: async (doc) => {
      assert.equal(doc.id, 'selected');
      return {
        pages: [
          { number: 1, text: 'Introduction.' },
          { number: 3, text: 'The selected proof uses induction.' },
        ],
      };
    },
  });
  assert.match(packed.context, /selected proof uses induction/);
  assert.doesNotMatch(packed.context, /COURSE INFORMATION|Reading other/);
  assert.deepEqual(packed.sources, [
    { documentID: 'selected', title: 'Reading selected', page: 3 },
  ]);
});

test('reading context stays on the current page for local questions and finds distant relevant pages', async () => {
  const selected = { ...document('compendium'), title: 'Feedback control compendium', pageCount: 150 };
  const pages = Array.from({ length: 150 }, (_, index) => ({ number: index + 1,
    text: index === 1 ? 'CURRENT_PAGE: An introduction to control systems.'
      : index === 126 ? 'DISTANT_EVIDENCE: The phase margin collapses when additional delay changes the loop phase.'
      : `Routine discussion on indexed page ${index + 1}.` }));
  const options = { course: course([selected]), selectedDocument: selected, selectedPage: 2,
    includeCourse: false, includeMetadata: false, readIndex: async () => ({ pages }) };
  const local = await buildCourseContext({ ...options, question: 'Explain this page.' });
  assert.deepEqual(local.sources.map((source) => source.page), [2]);
  assert.match(local.context, /CURRENT_PAGE/);
  assert.doesNotMatch(local.context, /DISTANT_EVIDENCE/);
  const distant = await buildCourseContext({ ...options, question: 'Why does the phase margin collapse?' });
  assert.equal(distant.sources[0].page, 2);
  assert.ok(distant.sources.some((source) => source.page === 127));
  assert.match(distant.context, /DISTANT_EVIDENCE/);
  assert.match(distant.context, /Searched all 150 indexed pages/);
  assert.match(distant.context, /included excerpts from pages: 2, 127/);
  assert.ok(distant.context.length < 5_000);
  const followup = await buildCourseContext({ ...options, question: 'Why?', previousQuestions: ['Why does the phase margin collapse?'] });
  assert.match(followup.context, /DISTANT_EVIDENCE/);
  const afterOverview = await buildCourseContext({ ...options, question: 'Why?', previousQuestions: ['Summarize the whole document.'] });
  assert.deepEqual(afterOverview.sources.map((source) => source.page), [2]);
});

test('explicit page requests find distant pages without topic keywords and report unavailable pages', async () => {
  assert.deepEqual([...requestedReadingPages('Explain pages 120–122 and side 8')], [120, 121, 122, 8]);
  assert.deepEqual([...requestedReadingPages('Compare pages 10 and 50')], [10, 50]);
  assert.deepEqual([...requestedReadingPages('Sammenlign sider 10 og 50')], [10, 50]);
  assert.deepEqual([...requestedReadingPages('Explain pages 10,50–52')], [10, 50, 51, 52]);
  assert.equal(requestedReadingPages('Explain pages 1–50').truncated, true);
  assert.equal(requestedReadingPages('Explain pages 10 and 50').truncated, false);
  const selected = { ...document('long'), pageCount: 130 };
  const pages = Array.from({ length: 130 }, (_, index) => ({ number: index + 1, text: `Evidence unique to index ${index + 1}.` }));
  const options = { course: course([selected]), selectedDocument: selected, selectedPage: 2, includeCourse: false,
    includeMetadata: false, readIndex: async () => ({ pages }) };
  const explicit = await buildCourseContext({ ...options, question: 'Explain page 120.' });
  assert.deepEqual(explicit.sources.map((source) => source.page), [2, 120]);
  assert.match(explicit.context, /Evidence unique to index 120/);
  const changed = await buildCourseContext({ ...options, question: 'Explain page 90.', previousQuestions: ['Explain page 120.'] });
  assert.deepEqual(changed.sources.map((source) => source.page), [2, 90]);
  const followup = await buildCourseContext({ ...options, question: 'Utdyp.', previousQuestions: ['Explain page 120.'] });
  assert.match(followup.context, /Evidence unique to index 120/);
  const missing = await buildCourseContext({ ...options, question: 'Explain page 900.' });
  assert.match(missing.context, /Requested pages without supplied text: 900/);
  const capped = await buildCourseContext({ ...options, question: 'Explain pages 1–50.' });
  assert.match(capped.context, /Only the first 20 distinct requested page numbers were targeted/);
  assert.match(capped.context, /Additional requested pages were not included/);
  assert.match(capped.context, /Use Whole document mode/);
});

test('a local reading question avoids other indexes but a remote concept still searches them', async () => {
  const selected = document('selected'), remote = document('remote');
  const read = [];
  const options = { course: course([selected, remote]), selectedDocument: selected, selectedPage: 2,
    readIndex: async (doc) => { read.push(doc.id); return { pages: [{ number: 2, text: doc.id === remote.id ? 'remoteconcept connects the equation to the project.' : 'The current equation.' }] }; } };
  await buildCourseContext({ ...options, question: 'Explain this page.' });
  assert.deepEqual(read, ['selected']);
  const remoteAnswer = await buildCourseContext({ ...options, question: 'How does this equation relate to remoteconcept?' });
  assert.match(remoteAnswer.context, /remoteconcept connects/);
  assert.ok(remoteAnswer.sources.some((source) => source.documentID === remote.id));
});

test('broad reading overviews cover later sections while ordinary questions stay compact', async () => {
  const selected = { ...document('overview'), pageCount: 9 };
  const pages = Array.from({ length: 9 }, (_, index) => ({ number: index + 1, text: `Chapter evidence ${index + 1}.` }));
  const packed = await buildCourseContext({ course: course([selected]), selectedDocument: selected, selectedPage: 4,
    question: 'Summarize the whole document.', includeCourse: false, includeMetadata: false, readIndex: async () => ({ pages }) });
  assert.equal(packed.sources.length, 9);
  assert.match(packed.context, /Chapter evidence 1/);
  assert.match(packed.context, /Chapter evidence 9/);
});

test('a parameter match deep inside a long page survives excerpt packing', async () => {
  const selected = { ...document('project'), pageCount: 2 };
  const text = `${'Routine background and derivation. '.repeat(3000)}\nKp = 7.25 is the configured controller gain.\n${'Additional unrelated material. '.repeat(2000)}`;
  const packed = await buildCourseContext({ course: course([selected]), selectedDocument: selected,
    selectedPage: 1, question: 'What is Kp?', includeCourse: false, includeMetadata: false, maxChars: 4_000,
    readIndex: async () => ({ pages: [{ number: 1, text: 'Current reading page.' }, { number: 2, text }] }) });
  assert.match(packed.context, /Kp = 7.25 is the configured controller gain/);
  assert.deepEqual(packed.sources.map((source) => source.page), [1, 2]);
  assert.ok(packed.context.length <= 4_000);
});

test('large course context is bounded and transparently reports omitted catalog entries', async () => {
  const documents = Array.from({ length: 120 }, (_, index) => ({
    ...document(String(index)),
    title: `Reading ${index}: ` + 'Long title '.repeat(30),
  }));
  const c = course(documents);
  const metadata = courseMetadataContext(c, 4000);
  assert.ok(metadata.length <= 4000);
  assert.match(metadata, /additional catalog entries omitted/);
  const packed = await buildCourseContext({
    course: c,
    question: 'What does this course cover?',
    maxChars: 18_000,
    readIndex: async () => ({
      pages: [{ number: 1, text: 'Many facts about a subject. '.repeat(2000) }],
    }),
  });
  assert.ok(packed.context.length <= 18_000);
  assert.ok(packed.sources.length > 1);
  assert.ok(packed.sources.length <= 20);
});

test('course threads keep their scope when a citation opens a document', () => {
  assert.equal(
    courseContextScope(
      { documentID: null, assignmentID: null },
      { selectedDocumentID: 'citation' }
    ),
    'course'
  );
  assert.equal(courseContextScope({ documentID: 'reading', assignmentID: null }, {}), 'document');
  assert.equal(
    courseContextScope({ documentID: null, assignmentID: 'assignment' }, {}),
    'assignment'
  );
  assert.equal(courseContextScope(null, { selectedAssignmentID: 'assignment' }), 'assignment');
});

test('a specific assignment stays available when the catalog exceeds the metadata budget', () => {
  const assignments = Array.from({ length: 100 }, (_, index) => ({
    id: `assignments:${index}`,
    kind: 'assignments',
    title: index === 99 ? 'Capstone orbit project' : `Ordinary exercise ${index}`,
    assignment: { dueAt: '2026-12-03T14:00:00Z', status: 'not_submitted' },
  }));
  const context = courseMetadataContext(
    course([], assignments),
    2000,
    'When is the capstone orbit project due?'
  );
  assert.match(context, /Capstone orbit project \| due: 2026-12-03T14:00:00Z/);
  assert.match(context, /additional catalog entries omitted/);
  assert.ok(context.length <= 2000);
});

test('cancelling retrieval stops before reading saved course indexes', async () => {
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    buildCourseContext({
      course: course([document('a')]),
      signal: controller.signal,
      readIndex: () => assert.fail('Cancelled work must not read a file'),
    }),
    { name: 'AbortError' }
  );
});
