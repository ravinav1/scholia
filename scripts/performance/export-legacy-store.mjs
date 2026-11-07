// Offline recovery utility. Always operates on a new copy, never the source database.
// Stop the service first; copy encryption.key and files/ alongside the exported database.
import { DatabaseSync, backup } from 'node:sqlite';
import { resolve } from 'node:path';
import { stat } from 'node:fs/promises';
import { LibraryPersistence } from '../../apps/server/persistence.js';
export async function exportLegacyStore(source, destination) {
 source=resolve(source);destination=resolve(destination);
 if(source===destination) throw new Error('Choose a different, unused output database.');
 try { await stat(destination); throw new Error('The output database already exists.'); }
 catch(error) { if(error.code!=='ENOENT') throw error; }
 const input=new DatabaseSync(source,{readOnly:true});
 try { await backup(input,destination); } finally { input.close(); }
 const output=new DatabaseSync(destination);
 try {
  output.exec('PRAGMA foreign_keys=ON');
  const storage=new LibraryPersistence(output);
  storage.transaction(()=>{
   for(const user of output.prepare('SELECT id FROM users').all())
    output.prepare('UPDATE users SET library=? WHERE id=?').run(JSON.stringify(storage.read(user.id)),user.id);
   output.exec(`DROP TABLE conversation_messages; DROP TABLE composer_drafts; DROP TABLE library_threads;
    DROP TABLE reading_progress; DROP TABLE library_documents; DROP TABLE library_courses; DROP TABLE library_roots;
    PRAGMA user_version=0;`);
  });
 } finally { output.close(); }
}
if(process.argv[1] && resolve(process.argv[1])===new URL(import.meta.url).pathname) {
 if(process.argv.length!==4) throw new Error('Usage: node scripts/performance/export-legacy-store.mjs SOURCE.sqlite NEW-OUTPUT.sqlite');
 await exportLegacyStore(process.argv[2],process.argv[3]);
 console.log('Exported current saved state into a separate legacy-compatible SQLite database.');
}
