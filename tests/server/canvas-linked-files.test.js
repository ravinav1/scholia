import test from 'node:test';
import assert from 'node:assert/strict';
import { Canvas } from '../../apps/server/courses/canvas.js';

function fixture({ courseStatus = 403, locked = false, hidden = true, globalStatus = 200 } = {}) {
  const paths = [];
  const canvas = new Canvas('https://canvas.example', 'fixture-token', {
    hosts: ['canvas.example'],
    request: async (url, options) => {
      paths.push(url.pathname);
      if (url.hostname === 'storage.example') {
        assert.equal(options.headers.Authorization, undefined);
        return { status: 200, headers: {}, data: Buffer.from('%PDF-exercise-5') };
      }
      assert.equal(options.headers.Authorization, 'Bearer fixture-token');
      const status = url.pathname.startsWith('/api/v1/courses/') ? courseStatus : globalStatus;
      return { status, headers: {}, data: Buffer.from(JSON.stringify({
        id: 1308344, filename: 'Exercise 5.pdf', display_name: 'Exercise 5.pdf',
        hidden_for_user: hidden, locked_for_user: locked, url: 'https://storage.example/exercise-5.pdf',
      })) };
    },
  });
  return { canvas, paths };
}
const ref = { kind: 'files', remoteID: '1308344' };
const course = { canvasID: 24623 };

test('assignment attachment downloads when Files tab is unavailable and file is link-only', async () => {
  const { canvas, paths } = fixture();
  const result = await canvas.material(ref, course);
  assert.equal(result.name, 'Exercise 5.pdf');
  assert.equal(result.data.toString(), '%PDF-exercise-5');
  assert.deepEqual(paths, ['/api/v1/courses/24623/files/1308344', '/api/v1/files/1308344', '/exercise-5.pdf']);
});

test('locked files and denied global endpoints stay unavailable', async () => {
  await assert.rejects(fixture({ locked: true }).canvas.material(ref, course), /Locked/);
  await assert.rejects(fixture({ globalStatus: 403 }).canvas.material(ref, course), /403/);
});

test('authentication and server errors never trigger fallback requests', async () => {
  for (const courseStatus of [401, 500]) {
    const { canvas, paths } = fixture({ courseStatus });
    await assert.rejects(canvas.material(ref, course), (error) => {
      assert.equal(error.canvasStatus, courseStatus);
      assert.equal(error.status, undefined, 'Canvas auth errors must not log the user out of Scholia');
      return true;
    });
    assert.equal(paths.length, 1);
  }
});
