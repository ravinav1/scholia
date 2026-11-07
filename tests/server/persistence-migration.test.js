import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { mkdtemp, rm, copyFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { AccountStore } from '../../apps/server/store.js';
function legacyFixture(count=89) {
 return {version:1,examPlan:[],courses:Array.from({length:count},(_,i)=>({id:`course-${i}`,name:`Course ${i}`,term:`202${i%3+4} Autumn`,canvasMaterials:Array.from({length:20},(_,j)=>({id:`files:${j}`,title:`Material ${j}`})),documents:Array.from({length:6},(_,j)=>({id:`doc-${i}-${j}`,title:`Reading ${j}`,lastPage:2,lastOpenedAt:100+j})),threads:[{id:`thread-${i}`,title:'Long discussion',documentID:`doc-${i}-0`,draft:'Unfinished question',draftFiles:[{id:'file',name:'appendix.txt',text:'Attachment'}],messages:Array.from({length:30},(_,j)=>({id:`message-${j}`,role:j%2?'assistant':'user',content:'Long answer. '.repeat(60)})),sources:{1:{documentID:`doc-${i}-0`,page:2}}}]}))};
}
async function legacy(t,library=legacyFixture()) {
 const original=await mkdtemp(join(tmpdir(),'scholia-legacy-source-')),copy=await mkdtemp(join(tmpdir(),'scholia-legacy-copy-'));
 const db=new DatabaseSync(join(original,'accounts.sqlite'));
 db.exec(`CREATE TABLE users(id TEXT PRIMARY KEY,email TEXT UNIQUE NOT NULL,salt TEXT NOT NULL,password TEXT NOT NULL,library TEXT NOT NULL,settings TEXT NOT NULL DEFAULT '{}');`);
 db.prepare('INSERT INTO users VALUES(?,?,?,?,?,?)').run('user','a@example.test','salt','password',JSON.stringify(library),'{}');db.close();
 await copyFile(join(original,'accounts.sqlite'),join(copy,'accounts.sqlite'));
 t.after(async()=>{await rm(original,{recursive:true,force:true});await rm(copy,{recursive:true,force:true});});
 return {root:copy,library,original};
}
test('realistic copied legacy data migrates transactionally and repeated startup preserves all optional values/order',async t=>{
 const f=await legacy(t);let store=new AccountStore(f.root);
 assert.deepEqual(store.account('user').library,f.library);
 assert.equal(store.db.prepare('PRAGMA user_version').get().user_version,2);
 assert.deepEqual(JSON.parse(store.db.prepare('SELECT library FROM users').get().library),f.library,'Legacy backup is unchanged');
 store.close();store=new AccountStore(f.root);assert.deepEqual(store.account('user').library,f.library);store.close();
 const untouched=new DatabaseSync(join(f.original,'accounts.sqlite'));assert.equal(untouched.prepare('PRAGMA user_version').get().user_version,0);untouched.close();
});
test('targeted draft, page and message persistence do not rewrite unrelated rows and survive restart',async t=>{
 const f=await legacy(t,legacyFixture(3));let store=new AccountStore(f.root),account=store.account('user');
 const p=store.libraryPersistence,c=account.library.courses[0],thread=c.threads[0];
 p.resetMetrics();thread.draft='Latest draft';store.save(account,{kind:'draft',courseID:c.id,threadID:thread.id});
 assert.deepEqual(p.metrics.rows,{drafts:1});assert.ok(p.metrics.serializedBytes<2000);
 p.resetMetrics();c.documents[0].lastPage=7;store.save(account,{kind:'progress',courseID:c.id,documentID:c.documents[0].id});
 assert.deepEqual(p.metrics.rows,{progress:1});assert.ok(p.metrics.serializedBytes<100);
 p.resetMetrics();thread.messages.at(-1).content='Updated final answer';store.save(account,{kind:'thread',courseID:c.id,threadID:thread.id});
 assert.deepEqual(p.metrics.rows,{messages:1});
 store.close();store=new AccountStore(f.root);account=store.account('user');
 assert.equal(account.library.courses[0].threads[0].draft,'Latest draft');assert.equal(account.library.courses[0].documents[0].lastPage,7);
 assert.equal(account.library.courses[0].threads[0].messages.at(-1).content,'Updated final answer');
 assert.deepEqual(account.library.courses.slice(1),f.library.courses.slice(1));store.close();
});
test('failed writes roll back atomically; another document can save and restart restores last successful draft',async t=>{
 const f=await legacy(t,legacyFixture(2));const store=new AccountStore(f.root),account=store.account('user');
 const c=account.library.courses[0],thread=c.threads[0];
 store.db.exec("CREATE TRIGGER fail_draft BEFORE UPDATE ON composer_drafts WHEN NEW.id='thread-0' BEGIN SELECT RAISE(ABORT,'simulated disk failure'); END;");
 thread.draft='Must not be committed';assert.throws(()=>store.save(account,{kind:'draft',courseID:c.id,threadID:thread.id}),/simulated disk failure/);
 assert.equal(store.account('user').library.courses[0].threads[0].draft,'Unfinished question');
 const other=account.library.courses[1];other.documents[0].lastPage=9;
 store.save(account,{kind:'progress',courseID:other.id,documentID:other.documents[0].id});
 assert.equal(store.account('user').library.courses[1].documents[0].lastPage,9);
 store.db.exec('DROP TRIGGER fail_draft');thread.draft='Retried';store.save(account,{kind:'draft',courseID:c.id,threadID:thread.id});
 assert.equal(store.account('user').library.courses[0].threads[0].draft,'Retried');store.close();
});
test('interrupted migration leaves version and legacy data recoverable, then retry succeeds',async t=>{
 const f=await legacy(t,legacyFixture(2));const db=new DatabaseSync(join(f.root,'accounts.sqlite'));
 db.prepare('UPDATE users SET library=?').run('{broken');db.close();
 assert.throws(()=>new AccountStore(f.root),/JSON/);
 const repair=new DatabaseSync(join(f.root,'accounts.sqlite'));
 assert.equal(repair.prepare('PRAGMA user_version').get().user_version,0);
 assert.equal(repair.prepare("SELECT count(*) AS n FROM sqlite_master WHERE name='library_roots'").get().n,0);
 repair.prepare('UPDATE users SET library=?').run(JSON.stringify(f.library));repair.close();
 const store=new AccountStore(f.root);assert.deepEqual(store.account('user').library,f.library);store.close();
});
test('rollback export reconstructs latest saved data in a separate legacy database',async t=>{
 const {exportLegacyStore}=await import('../../scripts/performance/export-legacy-store.mjs');
 const f=await legacy(t,legacyFixture(2));const store=new AccountStore(f.root),account=store.account('user');
 account.library.courses[0].threads[0].draft='Saved after migration';
 store.save(account,{kind:'draft',courseID:'course-0',threadID:'thread-0'});store.close();
 const destination=join(f.root,'rollback.sqlite');
 await exportLegacyStore(join(f.root,'accounts.sqlite'),destination);
 const old=new DatabaseSync(destination);assert.equal(old.prepare('PRAGMA user_version').get().user_version,0);
 assert.equal(JSON.parse(old.prepare('SELECT library FROM users').get().library).courses[0].threads[0].draft,'Saved after migration');old.close();
 const current=new AccountStore(f.root);assert.equal(current.db.prepare('PRAGMA user_version').get().user_version,2);current.close();
 await assert.rejects(exportLegacyStore(join(f.root,'accounts.sqlite'),destination),/already exists/);
});
