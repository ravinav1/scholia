import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
import {
  randomUUID,
  randomBytes,
  scrypt as derive,
  timingSafeEqual,
  createHash,
  createCipheriv,
  createDecipheriv,
} from 'node:crypto';
import { promisify } from 'node:util';
const scrypt = promisify(derive);
export const hash = (text) => createHash('sha256').update(text).digest('hex');
export const token = () => randomBytes(32).toString('hex');
export const emptyLibrary = () => ({
  version: 1,
  courses: [],
  canvasOrigin: 'https://canvas.ntnu.no',
  courseLibraryView: 'all',
});

export class AccountStore {
  constructor(root, { secret } = {}) {
    this.root = root;
    mkdirSync(root, { recursive: true, mode: 0o700 });
    const keyPath = join(root, 'encryption.key');
    if (secret) {
      if (!/^[a-f0-9]{64}$/i.test(secret))
        throw new Error('SCHOLIA_SECRET_KEY must contain 64 hex characters.');
      this.key = Buffer.from(secret, 'hex');
    } else {
      try {
        this.key = readFileSync(keyPath);
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
        this.key = randomBytes(32);
        writeFileSync(keyPath, this.key, { mode: 0o600, flag: 'wx' });
      }
    }
    if (this.key.length !== 32)
      throw new Error('SCHOLIA_SECRET_KEY must contain 64 hex characters.');
    this.db = new DatabaseSync(join(root, 'accounts.sqlite'));
    chmodSync(join(root, 'accounts.sqlite'), 0o600);
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, email TEXT UNIQUE NOT NULL, salt TEXT NOT NULL, password TEXT NOT NULL, library TEXT NOT NULL, settings TEXT NOT NULL DEFAULT '{}');
      CREATE TABLE IF NOT EXISTS sessions (token TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, csrf TEXT NOT NULL, expires INTEGER NOT NULL, navigation TEXT NOT NULL DEFAULT '{}');
      CREATE INDEX IF NOT EXISTS sessions_user_expiry ON sessions(user_id, expires);
      CREATE TABLE IF NOT EXISTS credentials (user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, name TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(user_id,name));
      CREATE TABLE IF NOT EXISTS learning (user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE, revision INTEGER NOT NULL, data TEXT NOT NULL);`);
  }
  async createUser(email, password) {
    email = String(email).trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254)
      throw new Error('Enter a valid email address.');
    if (typeof password !== 'string' || password.length < 12 || password.length > 256)
      throw new Error('Use a password between 12 and 256 characters.');
    const salt = token(),
      digest = await scrypt(password, salt, 64),
      id = randomUUID();
    this.db
      .prepare('INSERT INTO users(id,email,salt,password,library) VALUES(?,?,?,?,?)')
      .run(id, email, salt, digest.toString('hex'), JSON.stringify(emptyLibrary()));
    return { id, email };
  }
  async login(email, password) {
    const user = this.db
      .prepare('SELECT id,email,salt,password FROM users WHERE email=?')
      .get(String(email).trim().toLowerCase());
    const digest = await scrypt(
      String(password).slice(0, 257),
      user?.salt || 'scholia-invalid-account',
      64
    );
    if (!user || !timingSafeEqual(digest, Buffer.from(user.password, 'hex'))) return null;
    const value = token(),
      csrf = token(),
      expires = Date.now() + 7 * 86400000;
    this.db.prepare('DELETE FROM sessions WHERE expires<?').run(Date.now());
    this.db
      .prepare('INSERT INTO sessions(token,user_id,csrf,expires) VALUES(?,?,?,?)')
      .run(hash(value), user.id, csrf, expires);
    this.db
      .prepare(
        'DELETE FROM sessions WHERE user_id=? AND token NOT IN (SELECT token FROM sessions WHERE user_id=? ORDER BY expires DESC, rowid DESC LIMIT 20)'
      )
      .run(user.id, user.id);
    return { value, csrf, user: { id: user.id, email: user.email } };
  }
  session(value) {
    if (!value || !/^[a-f0-9]{64}$/.test(value)) return null;
    const row = this.db
      .prepare(
        'SELECT s.*,u.email FROM sessions s JOIN users u ON s.user_id=u.id WHERE s.token=? AND s.expires>?'
      )
      .get(hash(value), Date.now());
    return row ? { ...row, navigation: JSON.parse(row.navigation) } : null;
  }
  logout(value) {
    this.db.prepare('DELETE FROM sessions WHERE token=?').run(hash(value || ''));
  }
  account(id) {
    const row = this.db.prepare('SELECT email,library,settings FROM users WHERE id=?').get(id);
    if (!row) throw new Error('Account not found.');
    return {
      id,
      email: row.email,
      library: JSON.parse(row.library),
      settings: JSON.parse(row.settings),
    };
  }
  save(account) {
    this.db
      .prepare('UPDATE users SET library=?,settings=? WHERE id=?')
      .run(JSON.stringify(account.library), JSON.stringify(account.settings), account.id);
  }
  learning(id, state, expectedRevision = 0) {
    if (state === undefined) {
      const row = this.db.prepare('SELECT data FROM learning WHERE user_id=?').get(id);
      return row ? JSON.parse(row.data) : null;
    }
    const result = this.db.prepare(`INSERT INTO learning(user_id,revision,data) VALUES(?,?,?)
      ON CONFLICT(user_id) DO UPDATE SET revision=excluded.revision,data=excluded.data WHERE learning.revision=?`)
      .run(id, state.revision, JSON.stringify(state), expectedRevision);
    if (!result.changes) throw Object.assign(new Error('Practice changed in another process. Refresh and retry; your draft is retained.'), { status: 409 });
  }
  refreshNavigation(session) {
    const row = this.db
      .prepare('SELECT navigation FROM sessions WHERE token=? AND user_id=? AND expires>?')
      .get(session.token, session.user_id, Date.now());
    if (!row) throw Object.assign(new Error('Sign in to continue.'), { status: 401 });
    session.navigation = JSON.parse(row.navigation);
  }
  navigate(session) {
    this.db
      .prepare('UPDATE sessions SET navigation=? WHERE token=? AND user_id=?')
      .run(JSON.stringify(session.navigation), session.token, session.user_id);
  }
  credential(id, name, value) {
    if (value !== undefined) {
      if (!value) {
        this.db.prepare('DELETE FROM credentials WHERE user_id=? AND name=?').run(id, name);
        return;
      }
      const iv = randomBytes(12),
        cipher = createCipheriv('aes-256-gcm', this.key, iv);
      cipher.setAAD(Buffer.from(`${id}:${name}`));
      const encrypted = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
      this.db
        .prepare('INSERT OR REPLACE INTO credentials(user_id,name,value) VALUES(?,?,?)')
        .run(id, name, Buffer.concat([iv, cipher.getAuthTag(), encrypted]).toString('base64'));
      return;
    }
    const row = this.db
      .prepare('SELECT value FROM credentials WHERE user_id=? AND name=?')
      .get(id, name);
    if (!row) return '';
    const data = Buffer.from(row.value, 'base64'),
      cipher = createDecipheriv('aes-256-gcm', this.key, data.subarray(0, 12));
    cipher.setAAD(Buffer.from(`${id}:${name}`));
    cipher.setAuthTag(data.subarray(12, 28));
    return Buffer.concat([cipher.update(data.subarray(28)), cipher.final()]).toString('utf8');
  }
  close() {
    this.db.close();
  }
}
