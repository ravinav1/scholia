import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { AccountStore } from '../../apps/server/store.js';
import { Workspaces } from '../../apps/server/workspaces.js';
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'scholia-performance-test-'));
  const store = new AccountStore(root);
  const user = await store.createUser('a@example.test','a private test password');
  const login = await store.login('a@example.test','a private test password');
  const session = store.session(login.value);
  let reads=0, writes=0, inventory=0, analysis=0;
  const save=store.save.bind(store); store.save=(...args)=>{writes++;return save(...args);};
  const workspaces = new Workspaces(store,{index:async()=>{reads++;return {pages:[{text:'UNRELATED PRIVATE TEXT'}]};}});
  workspaces.analyzeStoredMaterials=async()=>{analysis++;};
  const materialInventory=workspaces.materialInventory.bind(workspaces);
  workspaces.materialInventory=(...args)=>{inventory++;return materialInventory(...args);};
  const account=workspaces.account(user.id);
  const doc={id:randomUUID(),title:'Reading',fileName:'reading.txt',kind:'text',pageCount:10,lastPage:3};
  const thread={id:randomUUID(),documentID:doc.id,title:'Discussion',messages:[{role:'assistant',content:'A'.repeat(20000)}],sources:{1:{text:'Excerpt'}},draft:'Complete draft',draftImage:'YWJj',draftFiles:[{name:'attachment.txt',text:'Attachment'}]};
  const course={id:randomUUID(),name:'Course',documents:[doc],threads:[thread],canvasMaterials:[]};
  account.library.courses=[course];
  Object.assign(session.navigation,{selectedCourseID:course.id,selectedDocumentID:doc.id,selectedThreadID:thread.id,page:3,showingCourseLibrary:false});
  store.save(account);store.navigate(session);
  t.after(async()=>{await workspaces.stop();store.close();await rm(root,{recursive:true,force:true});});
  return {store,session,account,course,doc,thread,workspaces,counts:()=>({reads,writes,inventory,analysis})};
}
test('dashboard projection preserves complete draft and destination without any hidden reader work',async t=>{
  const f=await fixture(t), owner=f.workspaces.owner(f.account,f.session.navigation), before=f.counts();
  const state=await f.workspaces.action(f.session,{action:'library'});
  assert.deepEqual(f.counts(),before);
  assert.equal(state.library.selectedDocumentID,f.doc.id);
  assert.equal(state.page,3);assert.equal(state.draft,'Complete draft');
  assert.equal(state.draftImage,'YWJj');assert.deepEqual(state.draftFiles,f.thread.draftFiles);
  assert.deepEqual(state.draftOwner,owner);
  assert.deepEqual(state.messages,[]);assert.deepEqual(state.sources,{});
  assert.equal(state.pageText,'');assert.equal(state.assignmentText,'');
});
test('an absent assignment ID never matches a document with an absent sourceKey',async t=>{
  const f=await fixture(t), state=await f.workspaces.state(f.session);
  assert.equal(state.assignmentText,'');assert.equal(f.counts().reads,1);
  f.course.canvasMaterials.push({id:'assignments:1',kind:'assignments',title:'Exercise'});
  f.doc.sourceKey='assignments:1';f.session.navigation.selectedAssignmentID='assignments:1';
  f.workspaces.normalizeAssignmentIndexes=async()=>{};
  assert.match((await f.workspaces.state(f.session)).assignmentText,/UNRELATED PRIVATE TEXT/);
});
test('session navigation avoids account saves while durable edits still save',async t=>{
  const f=await fixture(t), before=f.counts().writes;
  for(const action of [{action:'library'},{action:'semester',id:'all'},{action:'course',id:f.course.id},{action:'libraryView',id:'favorites'}]) await f.workspaces.action(f.session,action);
  assert.equal(f.counts().writes,before);
  assert.equal(f.store.session((await f.store.login('a@example.test','a private test password')).value).navigation.selectedCourseID,undefined);
  await f.workspaces.action(f.session,{action:'favorite',id:f.course.id});
  assert.equal(f.counts().writes,before+1);
  assert.equal(f.store.account(f.account.id).library.courses[0].favorite,true);
});
test('atomic reading validates before mutation, restores bounds and preserves the correct conversation',async t=>{
  const f=await fixture(t);
  f.workspaces.upgradeOpenedDocument=()=>{};
  const previous=structuredClone(f.session.navigation);
  for(const command of [{id:'missing'},{id:f.doc.id,page:0},{id:f.doc.id,page:1.5},{id:f.doc.id,conversationPolicy:'unknown'}]) {
    await assert.rejects(f.workspaces.action(f.session,{action:'openReading',...command}));
    assert.deepEqual(f.session.navigation,previous);
  }
  const opened=await f.workspaces.action(f.session,{action:'openReading',id:f.doc.id,page:999,navigationID:'destination-1'});
  assert.equal(opened.page,10);assert.equal(f.doc.lastPage,10);
  assert.equal(opened.library.navigationID,'destination-1');assert.equal(opened.draft,'Complete draft');
  const other={...f.doc,id:randomUUID(),lastPage:2};f.course.documents.push(other);
  const cited=await f.workspaces.action(f.session,{action:'openReading',id:other.id,page:2,conversationPolicy:'preserve'});
  assert.equal(cited.library.selectedThreadID,f.thread.id);assert.equal(cited.draft,'Complete draft');
  const own=await f.workspaces.action(f.session,{action:'openReading',id:other.id});
  assert.equal(own.library.selectedThreadID,null);assert.equal(own.draft,'');assert.equal(f.thread.draft,'Complete draft');
});
test('newer navigation generations win even when an older command is already queued',async t=>{
  const f=await fixture(t);f.workspaces.upgradeOpenedDocument=()=>{};
  let release;const blocked=f.workspaces.serial(f.account.id,()=>new Promise(r=>{release=r;}));
  await new Promise(r=>setImmediate(r));
  const old=f.workspaces.action(f.session,{action:'openReading',id:f.doc.id,page:2,navigationClientID:'test-tab',navigationGeneration:1});
  const rejected=assert.rejects(old,/superseded/);
  const newer=f.workspaces.action(f.session,{action:'openReading',id:f.doc.id,page:7,navigationClientID:'test-tab',navigationGeneration:2});
  release();await blocked;await rejected;
  assert.equal((await newer).page,7);
  await assert.rejects(f.workspaces.action(f.session,{action:'openReading',id:f.doc.id,page:1,navigationClientID:'test-tab',navigationGeneration:1}),/superseded/);
  assert.equal(f.session.navigation.page,7);
});
test('atomic reading does not publish a document deleted during availability validation',async t=>{
 const f=await fixture(t),previous=structuredClone(f.session.navigation);
 f.workspaces.documents.available=async()=>{f.course.documents=[];return true;};
 await assert.rejects(f.workspaces.action(f.session,{action:'openReading',id:f.doc.id,page:7}),/changed/);
 assert.deepEqual(f.session.navigation,previous);
});
