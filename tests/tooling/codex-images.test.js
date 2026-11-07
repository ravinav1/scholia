import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import os from 'node:os';
import { join } from 'node:path';
import { materializeCodexImages } from '../../scripts/bridges/lib/codex-images.mjs';

test('Codex image blocks become private temporary files and are cleaned up', () => {
  const temporaryRoot = mkdtempSync(join(os.tmpdir(), 'scholia-codex-images-test-'));
  try {
    const attachment = materializeCodexImages([{
      role: 'user',
      content: [
        { type: 'text', text: 'What is shown?' },
        { type: 'image_url', image_url: { url: 'data:image/png;base64,aGVsbG8=' } }
      ]
    }], { temporaryRoot });
    assert.equal(attachment.paths.length, 1);
    assert.equal(readFileSync(attachment.paths[0], 'utf8'), 'hello');
    assert.equal(statSync(attachment.paths[0]).mode & 0o777, 0o600);
    attachment.cleanup();
    assert.equal(existsSync(attachment.paths[0]), false);
    attachment.cleanup();
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true });
  }
});

test('Codex bridge rejects remote and unsupported image inputs', () => {
  assert.throws(() => materializeCodexImages([{
    role: 'user', content: [{ type: 'image_url', image_url: { url: 'https://example.test/image.png' } }]
  }]), /base64 data URLs/);
  assert.throws(() => materializeCodexImages([{
    role: 'user', content: [{ type: 'image_url', image_url: { url: 'data:image/svg+xml;base64,PHN2Zy8+' } }]
  }]), /does not accept image\/svg\+xml/);
});
