import { mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { FILE_PREVIEW_CHARACTERS, MAX_TURN_FILE_TEXT, normalizeFileAttachments, selectFileAttachments } from '../../packages/core/src/file-attachments.js';

const digest = (text) => createHash('sha256').update(text).digest('hex');
const failure = (message) => Object.assign(new Error(message), { status: 400 });

// Saved chat state holds a preview and an account-scoped reference. The complete
// extraction lives outside the polling payload and is searched for every turn.
export class AttachmentCorpus {
  constructor(root, { maxCharacters = 50_000_000, quotaBytes = 2_000_000_000 } = {}) {
    this.root = root; this.maxCharacters = maxCharacters; this.quotaBytes = quotaBytes;
  }
  directory(accountID) {
    if (!/^[a-f\d-]{36}$/i.test(accountID)) throw failure('Invalid attachment account.');
    return join(this.root, 'attachment-text', accountID);
  }
  path(accountID, corpusID) {
    if (!/^[a-f\d]{64}$/.test(corpusID)) throw failure('Invalid attachment text reference.');
    return join(this.directory(accountID), `${corpusID}.txt`);
  }
  async retain(account, raw, previous = []) {
    const known = new Map(normalizeFileAttachments(previous).filter((file) => file.id).map((file) => [file.id, file]));
    const retained = [];
    for (const file of normalizeFileAttachments(raw)) {
      const saved = known.get(file.id);
      if (file.textCorpusID) {
        if (!saved || saved.textCorpusID !== file.textCorpusID)
          throw failure('This saved attachment reference is unavailable in the current conversation. Attach the original file again.');
        retained.push({ ...saved, enabled: file.enabled });
        continue;
      }
      delete file.contextCoverage;
      delete file.textCorpusUTF16Count;
      if (file.text.length > this.maxCharacters)
        throw failure('This attachment exceeds the 50 million character extraction storage limit. No shortened copy was saved.');
      const id = file.id || randomUUID();
      if (file.text.length <= FILE_PREVIEW_CHARACTERS) {
        retained.push({ ...file, id });
        continue;
      }
      const corpusID = digest(file.text), bytes = Buffer.byteLength(file.text);
      await mkdir(this.directory(account.id), { recursive: true, mode: 0o700 });
      try {
        // Content-addressed writes deduplicate retries without weakening account isolation.
        await stat(this.path(account.id, corpusID));
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
        if ((account.settings.storageBytes || 0) + bytes > this.quotaBytes)
          throw failure('This account has reached its file storage limit. The complete attachment could not be saved.');
        try {
          await writeFile(this.path(account.id, corpusID), file.text, { flag: 'wx', mode: 0o600 });
          account.settings.storageBytes = (account.settings.storageBytes || 0) + bytes;
        } catch (error) { if (error.code !== 'EEXIST') throw error; }
      }
      retained.push({ ...file, id, text: file.text.slice(0, FILE_PREVIEW_CHARACTERS),
        textCorpusID: corpusID, textCorpusUTF16Count: file.text.length });
    }
    return retained;
  }
  async fullText(accountID, file) {
    if (!file.textCorpusID) return file;
    try {
      const text = await readFile(this.path(accountID, file.textCorpusID), 'utf8');
      if (digest(text) !== file.textCorpusID) throw new Error('Saved text failed its integrity check');
      return { ...file, text, textCorpusUTF16Count: text.length };
    } catch (error) {
      return { ...file, status: 'partial', truncated: true,
        notice: `${file.notice} Full saved text is unavailable (${error.code || error.message}); only the stored preview can be searched.` };
    }
  }
  async select(accountID, raw, options = {}) {
    const files = normalizeFileAttachments(raw).filter((file) => file.enabled);
    let remaining = Math.max(0, Math.min(options.budget ?? MAX_TURN_FILE_TEXT, MAX_TURN_FILE_TEXT));
    let pending = files.filter((file) => file.text.length || file.textCorpusUTF16Count).length;
    const selected = [];
    for (const file of files) {
      const readable = file.text.length || file.textCorpusUTF16Count;
      const allowance = readable ? Math.floor(remaining / Math.max(1, pending)) : 0;
      const full = allowance > 0 ? await this.fullText(accountID, file) : file;
      const [part] = selectFileAttachments([full], { ...options, budget: allowance });
      selected.push(part);
      remaining = Math.max(0, remaining - part.text.length);
      if (readable) pending--;
    }
    return selected;
  }
}
