import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_EXAM_WORKSPACE_URL, EXAM_WORKSPACE_KEY, examWorkspaceUrl,
  loadExamWorkspaceUrl, openExamPlanner, saveExamWorkspaceUrl
} from '../../apps/chrome/src/exam-planner-launch.js';

test('planner addresses allow local HTTP and hosted HTTPS, but reject unsafe URLs and credentials', () => {
  assert.equal(examWorkspaceUrl(), DEFAULT_EXAM_WORKSPACE_URL);
  assert.equal(examWorkspaceUrl('https://study.example.com/scholia/#documents'), 'https://study.example.com/scholia/');
  assert.equal(examWorkspaceUrl('http://localhost:3000'), 'http://localhost:3000/');
  assert.equal(examWorkspaceUrl('http://[::1]:8792'), 'http://[::1]:8792/');
  for (const url of [
    'javascript:alert(1)', 'file:///tmp/index.html', 'https://name:password@example.com/',
    'https://example.com/?token=secret', 'http://example.com/', 'http://127.0.0.1.example.com/', ''
  ]) assert.throws(() => examWorkspaceUrl(url));
});

test('launcher uses the saved workspace and carries only the planner deep link', async (t) => {
  const saved = {};
  const opened = [];
  const previous = globalThis.chrome;
  globalThis.chrome = {
    storage: { local: { async get() { return saved; }, async set(value) { Object.assign(saved, value); } } },
    tabs: { async create(value) { opened.push(value); return { id: 1 }; } }
  };
  t.after(() => { globalThis.chrome = previous; });
  assert.equal(await loadExamWorkspaceUrl(), DEFAULT_EXAM_WORKSPACE_URL);
  await openExamPlanner();
  assert.deepEqual(opened[0], { url: `${DEFAULT_EXAM_WORKSPACE_URL}#exams`, active: true });
  await saveExamWorkspaceUrl('https://study.example.com/scholia/#old');
  assert.equal(saved[EXAM_WORKSPACE_KEY], 'https://study.example.com/scholia/');
  await openExamPlanner();
  assert.deepEqual(opened[1], { url: 'https://study.example.com/scholia/#exams', active: true });
  await assert.rejects(saveExamWorkspaceUrl('https://example.com/?token=secret'));
  assert.equal(saved[EXAM_WORKSPACE_KEY], 'https://study.example.com/scholia/');
});
