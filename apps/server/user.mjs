import { resolve } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { Writable } from 'node:stream';
import { AccountStore, token } from './store.js';
import { promisify } from 'node:util';
import { scrypt } from 'node:crypto';

async function readPassword() {
  const terminal = Boolean(process.stdin.isTTY);
  // Readline still handles editing and restores terminal settings, but never echoes input.
  const output = new Writable({
    write(_chunk, _encoding, done) {
      done();
    },
  });
  const input = createInterface({ input: process.stdin, output, terminal });
  const controller = new AbortController();
  let interrupted = false;
  const cancel = () => {
    interrupted = true;
    controller.abort();
  };
  input.once('SIGINT', cancel);
  input.once('close', () => controller.abort());
  process.once('SIGINT', cancel);
  if (terminal) process.stderr.write('Password (12+ characters; hidden): ');
  try {
    return await input.question('', { signal: controller.signal });
  } catch (error) {
    if (interrupted) throw Object.assign(new Error('Cancelled.'), { exitCode: 130 });
    if (error.name === 'AbortError') throw new Error('No password supplied on standard input.');
    throw error;
  } finally {
    input.close();
    process.removeListener('SIGINT', cancel);
    if (terminal) process.stderr.write('\n');
  }
}

async function main() {
  const args = process.argv.slice(2),
    email = args[args.indexOf('--email') + 1];
  if (!args.includes('--email') || !email) {
    throw new Error(
      'Usage: npm run web:user -- --email person@example.com [--reset]. Enter the password when prompted or supply it on standard input.'
    );
  }
  const password = await readPassword();
  const store = new AccountStore(resolve(process.env.SCHOLIA_DATA_DIR || '.data'), {
    secret: process.env.SCHOLIA_SECRET_KEY,
  });
  try {
    if (args.includes('--reset')) {
      if (!password || password.length < 12 || password.length > 256) {
        throw new Error('Use a password between 12 and 256 characters.');
      }
      const user = store.db
        .prepare('SELECT id FROM users WHERE email=?')
        .get(email.trim().toLowerCase());
      if (!user) throw new Error('Account not found.');
      const salt = token(),
        digest = await promisify(scrypt)(password, salt, 64);
      store.db
        .prepare('UPDATE users SET salt=?,password=? WHERE id=?')
        .run(salt, digest.toString('hex'), user.id);
      store.db.prepare('DELETE FROM sessions WHERE user_id=?').run(user.id);
      console.log('Password updated; existing sessions revoked.');
    } else {
      await store.createUser(email, password);
      console.log('Account created.');
    }
  } finally {
    store.close();
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = error.exitCode || 1;
});
