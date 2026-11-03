import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, unlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { AttachmentCorpus } from '../apps/server/attachment-corpus.js';

async function fixture(t, options) {
  const root = await mkdtemp(join(tmpdir(), 'scholia-attachment-corpus-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  return { root, corpus: new AttachmentCorpus(root, options), account: { id: '11111111-1111-1111-1111-111111111111', settings: {} } };
}

test('account-scoped attachment corpora retain distinct same-name files and survive a new reader instance', async (t) => {
  const { root, corpus, account } = await fixture(t);
  const files = await corpus.retain(account, [
    { id: 'old-model', name: 'model.slx', sourcePath: '/books/model.slx', text: 'old source\n'.repeat(30_000) + 'tailgain = 13;' },
    { id: 'actual-model', name: 'model.slx', sourcePath: '/programming/model.slx', text: 'new source\n'.repeat(30_000) + 'tailgain = 28;' },
  ]);
  assert.notEqual(files[0].textCorpusID, files[1].textCorpusID);
  assert.equal(files[1].sourcePath, '/programming/model.slx');
  const reopened = new AttachmentCorpus(root);
  const selected = await reopened.select(account.id, files, { question: 'What is tailgain?' });
  assert.equal(selected.length, 2);
  assert.equal(selected[0].id, 'old-model');
  assert.match(selected[0].text, /tailgain = 13/);
  assert.equal(selected[1].id, 'actual-model');
  assert.match(selected[1].text, /tailgain = 28/);
  await assert.rejects(corpus.retain(account, [{ ...files[0], id: 'forged' }], files), /current conversation/);
  await assert.rejects(corpus.retain(account, [{ ...files[0], textCorpusID: files[1].textCorpusID }], files), /current conversation/);
  const other = await reopened.fullText('22222222-2222-2222-2222-222222222222', files[0]);
  assert.equal(other.status, 'partial');
  assert.doesNotMatch(other.text, /tailgain = 13/);
  assert.match(other.notice, /Full saved text is unavailable/);
});

test('excluded corpora do not load or spend prompt budget, and missing stored text is disclosed', async (t) => {
  const { corpus, account } = await fixture(t);
  const [saved] = await corpus.retain(account, [{ name: 'large.txt', text: 'known material\n'.repeat(30_000) + 'latevalue = 7;' }]);
  const original = corpus.fullText.bind(corpus);
  corpus.fullText = () => { throw new Error('Excluded text must not be opened'); };
  assert.deepEqual(await corpus.select(account.id, [{ ...saved, enabled: false }], { question: 'latevalue' }), []);
  corpus.fullText = original;
  await unlink(corpus.path(account.id, saved.textCorpusID));
  const [partial] = await corpus.select(account.id, [saved], { question: 'latevalue' });
  assert.equal(partial.status, 'partial');
  assert.match(partial.contextCoverage, /remaining corpus was not searched/);
  assert.doesNotMatch(partial.text, /latevalue = 7/);
});

test('corpus storage limits fail explicitly instead of silently saving a prefix', async (t) => {
  const { corpus, account } = await fixture(t, { maxCharacters: 20_000, quotaBytes: 18_000 });
  await assert.rejects(corpus.retain(account, [{ name: 'too-long.txt', text: 'a'.repeat(20_001) }]), /No shortened copy was saved/);
  await assert.rejects(corpus.retain(account, [{ name: 'quota.txt', text: 'a'.repeat(19_000) }]), /complete attachment could not be saved/);
  assert.equal(account.settings.storageBytes, undefined);
});
