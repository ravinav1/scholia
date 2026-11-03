import test from 'node:test';
import assert from 'node:assert/strict';
import { workspaceMemory, saveWorkspaceMemory, buildWorkspaceMemory } from '../apps/server/workspace-memory.js';
import { FileNameSearch } from '../apps/server/file-search.js';
import { WorkspaceSearch } from '../apps/server/workspace-search.js';

test('persistent workspace and assignment memory keeps scopes separate and pins relevant file pages', async () => {
  let course = { id: 'course', documents: [{ id: 'book', title: 'Course book', kind: 'pdf' }, { id: 'other', title: 'Lab data', kind: 'text' }],
    canvasMaterials: ['a', 'b'].map((id) => ({ id, kind: 'assignments' })) };
  saveWorkspaceMemory(course, null, 'Use SI units', ['book']);
  saveWorkspaceMemory(course, 'a', 'Our plant is a motor', ['other']);
  saveWorkspaceMemory(course, 'b', 'A separate pendulum', []);
  course = JSON.parse(JSON.stringify(course));
  const input = { course, question: 'torque', readIndex: async (doc) => ({ pages: [
    { number: 1, text: `Introduction to ${doc.title}` },
    { number: 2, text: `torque: ${doc.id} reference information` },
  ] }) };
  const a = await buildWorkspaceMemory({ ...input, assignmentID: 'a' });
  assert.match(a.context, /Use SI units/);
  assert.match(a.context, /Our plant is a motor/);
  assert.match(a.context, /other reference information/);
  assert.doesNotMatch(a.context, /pendulum/);
  assert.equal(a.sources[0].page, 2);
  const b = await buildWorkspaceMemory({ ...input, assignmentID: 'b' });
  assert.match(b.context, /pendulum/);
  assert.doesNotMatch(b.context, /motor|Lab data/);
  const c = await buildWorkspaceMemory(input);
  assert.doesNotMatch(c.context, /motor|pendulum|Lab data/);
  assert.throws(() => saveWorkspaceMemory(course, 'a', 'bad', ['foreign']), /belong/);
  assert.throws(() => saveWorkspaceMemory(course, 'unknown', '', []), /Assignment not found/);
  course.documents = [];
  assert.deepEqual(workspaceMemory(course, 'a').documentIDs, []);
});

test('file finding matches course codes and typos without reading an index, and sees edits and removals', async () => {
  const search = new WorkspaceSearch({ directory() { throw new Error('Filename search touched disk paths'); } });
  const document = { id: 'book', title: 'KybintroKompendium.pdf', originalFileName: 'KybintroKompendium.pdf', kind: 'pdf' };
  const account = { id: 'user', library: { courses: [{ id: 'course', code: 'TTK4100', name: 'Kybernetikk introduksjon', documents: [document], canvasMaterials: [] }] } };
  const result = await search.search(account, 'ttk4100 kybtintro kompendium', { mode: 'files' });
  assert.equal(result.results[0].documentID, 'book');
  assert.equal(result.results[0].approximate, true);
  assert.equal(result.strategy, 'names');
  assert.equal(search.slots.every((slot) => !slot.worker), true);
  await search.close();
  const index = new FileNameSearch();
  const file = { ...document, documentID: document.id, courseID: 'course', courseName: 'TTK4100' };
  assert.equal(index.search([file], 'TTK4100 kompendium').total, 1);
  assert.equal(index.search([file], 'TTK4100 kompendium', { courseID: 'other' }).total, 0);
  assert.equal(index.search([{ ...file, title: 'New title', originalFileName: '' }], 'kompendium').total, 0);
  assert.equal(index.search([], 'kompendium').total, 0);
});
