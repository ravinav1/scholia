import test from 'node:test';
import assert from 'node:assert/strict';
import { recentReadings, readingPosition, continueReadingMarkup, studyPrompt, appendStudyPrompt, readerRenderKey, studyPollDelay, studyRenderKey, readingSourceSummary } from '../../apps/web/workspace/study-session.js';
import { courseLibraryMarkup, courseLibraryRenderKey } from '../../apps/web/workspace/course-library.js';

const document = (id, lastOpenedAt, lastPage = 1) => ({ id, title: id, kind: 'pdf', pageCount: 12, lastPage, lastOpenedAt });
test('reading evidence summary reports actual included page ranges by document', () => {
  assert.equal(readingSourceSummary([
    ...[2, 127, 128, 129, 2].map((page) => ({ documentID: 'compendium', title: 'Compendium', page })),
    { documentID: 'project', title: 'Project', page: 1 },
  ]), 'Compendium · pp. 2, 127–129; Project · p. 1');
});
function fixture() {
  return { library: { selectedCourseID: 'a', selectedDocumentID: 'older', courseLibraryView: 'all', courses: [
    { id: 'a', name: 'Algebra', code: 'MA101', documents: [document('older', 10, 5), document('unread', undefined)], threads: [] },
    { id: 'b', name: 'Biology', code: 'BIO101', documents: [document('newest', 30), document('middle', 20)], threads: [] },
  ] }, materialGroups: [], page: 5, pageText: 'Linear maps', mode: 'Explain', messages: [], busy: false };
}

test('continue reading uses actual visits, orders across courses, and excludes unopened imports', () => {
  const state = fixture(), readings = recentReadings(state.library.courses, 2);
  assert.deepEqual(readings.map(({ document }) => document.id), ['newest', 'middle']);
  assert.equal(readings[0].course.id, 'b');
  assert.equal(readingPosition(state.library.courses[0].documents[0]), 'Page 5 of 12');
  assert.equal(readingPosition({ kind: 'notebook', pageCount: 8, lastPage: 100 }), 'Cell 8 of 8');
  assert.equal(readingPosition({ kind: 'code', pageCount: 0, lastPage: -2 }), 'Section 1 of 1');
  assert.equal(continueReadingMarkup(recentReadings([])), '');
});

test('recent reading window agrees with full chronological ordering across ties and limits', () => {
  const courses = Array.from({ length: 7 }, (_, course) => ({ id: String(course), documents:
    Array.from({ length: 300 }, (_, i) => document(`${course}-${i}`, i % 17 ? (i * 19 + course) % 83 : NaN)) }));
  const expected = courses.flatMap((course) => course.documents
    .filter((document) => Number.isFinite(document.lastOpenedAt)).map((document) => ({ course, document })))
    .sort((a, b) => b.document.lastOpenedAt - a.document.lastOpenedAt || a.document.id.localeCompare(b.document.id));
  for (const limit of [0, -1, 1, 3, 15, 5000])
    assert.deepEqual(recentReadings(courses, limit), expected.slice(0, Math.max(0, limit)));
});

test('resume cards escape imported names and respect the library filter', () => {
  const state = fixture(); state.library.courses[1].documents[0].title = '<img src=x onerror=bad()> "hello"';
  const html = courseLibraryMarkup(state);
  assert.match(html, /data-action="resume" data-id="newest"/);
  assert.match(html, /&lt;img/); assert.doesNotMatch(html, /<img src=x/);
  assert.doesNotMatch(courseLibraryMarkup(state, 'Algebra'), /data-action="resume"/);
  state.library.courseLibraryView = 'favorites';
  assert.doesNotMatch(courseLibraryMarkup(state), /data-action="resume"/);
});

test('library updates when a saved reading position changes', () => {
  const state = fixture(), before = courseLibraryRenderKey(state);
  state.library.courses[0].documents[0].lastPage = 6;
  assert.notEqual(courseLibraryRenderKey(state), before);
});

test('chat updates and reading timestamps cannot recreate the current reading surface', () => {
  const state = fixture(), before = readerRenderKey(state);
  state.library.courses[0].threads.push({ id: 'thread', draft: 'A question', updatedAt: 500 });
  state.library.selectedThreadID = 'thread'; state.messages.push({ content: 'Streaming answer' });
  state.library.courses[0].documents[0].lastOpenedAt = 40;
  state.busy = true;
  assert.equal(readerRenderKey(state), before);
  state.library.courses[0].documents[0].classification = { categoryID: 'notes', topic: 'Linear maps' };
  state.library.courses[0].documents[0].materialAnalysis = { categoryID: 'notes', topic: 'Linear maps' };
  assert.equal(readerRenderKey(state), before, 'background organization must not recreate the reader');
  state.library.courses[0].documents[0] = Object.fromEntries(Object.entries(state.library.courses[0].documents[0]).reverse());
  assert.equal(readerRenderKey(state), before, 'native JSON property ordering must not redraw the document');
  state.page = 6;
  assert.notEqual(readerRenderKey(state), before);
  state.page = 5; state.library.courses[0].documents[0].sourceVersion = 'updated';
  assert.notEqual(readerRenderKey(state), before);
});

test('render keys ignore JSON property ordering but detect changed answer content', () => {
  const a = { messages: [{ id: 'one', content: 'An answer' }], sources: { one: [{ page: 3, title: 'Reading' }] } };
  const b = { sources: { one: [{ title: 'Reading', page: 3 }] }, messages: [{ content: 'An answer', id: 'one' }] };
  assert.equal(studyRenderKey(a), studyRenderKey(b));
  b.messages[0].content += ' with another token';
  assert.notEqual(studyRenderKey(a), studyRenderKey(b));
});

test('study starters ask for an attempt, use the available source, and preserve existing work', () => {
  const prompt = studyPrompt('Practice', null);
  assert.match(prompt, /downloaded course materials/);
  assert.match(prompt, /Wait for my answer/);
  assert.match(studyPrompt('Guide me', { kind: 'code' }), /this section/);
  assert.match(studyPrompt('Explain', { kind: 'notebook' }), /this notebook cell/);
  assert.equal(appendStudyPrompt('My own question', prompt), `My own question\n\n${prompt}`);
  assert.equal(appendStudyPrompt(prompt, prompt), prompt);
  assert.equal(appendStudyPrompt('  ', prompt), prompt);
});

test('polling backs off while idle, hidden or disconnected and speeds up for answers', () => {
  assert.ok(studyPollDelay({ streaming: true }) < 900);
  assert.ok(studyPollDelay({ loadingDocument: true }) < 900);
  assert.ok(studyPollDelay({}) > studyPollDelay({ busy: true }));
  assert.ok(studyPollDelay({}) > studyPollDelay({ assignmentPreparing: true }));
  assert.ok(studyPollDelay({}, true) > studyPollDelay({}));
  assert.ok(studyPollDelay({}, false, true) > studyPollDelay({}));
});
