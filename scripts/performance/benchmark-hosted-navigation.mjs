// Service-only benchmark. Browser paint is measured separately by the Chromium harness.
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir, cpus, totalmem, release } from 'node:os';
import { join, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { randomUUID } from 'node:crypto';
import { AccountStore } from '../../apps/server/store.js';
import { Workspaces } from '../../apps/server/workspaces.js';
const samples = Number(process.env.SAMPLES || 30), warmup = 3;
const results = [];
const percentile = (values, fraction) => [...values].sort((a,b) => a-b)[Math.ceil(values.length*fraction)-1];
for (const size of [6, 89, 500]) {
  const root = await mkdtemp(join(tmpdir(), 'scholia-service-bench-'));
  const store = new AccountStore(root);
  const user = await store.createUser('bench@example.test', 'isolated benchmark password');
  const login = await store.login('bench@example.test', 'isolated benchmark password');
  const session = store.session(login.value);
  let writes = 0, navigationWrites = 0, indexReads = 0, inventories = 0;
  const save = store.save.bind(store), navigate = store.navigate.bind(store);
  store.save = (...args) => { writes++; return save(...args); };
  store.navigate = (...args) => { navigationWrites++; return navigate(...args); };
  const workspace = new Workspaces(store, { index: async () => { indexReads++; return { pages: Array.from({ length: 50 }, (_,i) => ({page:i+1,text:'A deterministic source passage. '.repeat(100)})) }; } });
  const inventory = workspace.materialInventory.bind(workspace);
  workspace.materialInventory = (...args) => { inventories++; return inventory(...args); };
  const account = workspace.account(user.id);
  account.settings.automaticallyUpdateMathWiki = false;
  account.library.courses = Array.from({ length: size }, (_,i) => ({ id: randomUUID(), name: `Workspace ${String(i).padStart(3,'0')}`, code: `TEST${i}`, term: `${2024+i%3} ${i%2?'Autumn':'Spring'}`, favorite: i%7===0,
    documents: Array.from({length:12},(_,d)=>({id:randomUUID(),title:`Reading ${d}`,fileName:`reading-${d}.txt`,kind:'text',pageCount:50,lastPage:3,indexVersion:999,materialAnalysis:{version:999},lastOpenedAt:800000000+i+d})),
    canvasMaterials: Array.from({length:32},(_,m)=>({id:`${m<8?'assignments':'files'}:${m}`,kind:m<8?'assignments':'files',remoteID:String(m),title:`Material ${m}`,version:'v1',assignment:m<8?{dueAt:1800000000+m*86400,status:'unsubmitted',submissionTypes:['online_upload']}:undefined})),
    threads: Array.from({length:3},(_,t)=>({id:randomUUID(),title:`Discussion ${t}`,messages:Array.from({length:40},(_,m)=>({id:randomUUID(),role:m%2?'assistant':'user',content:'Long conversation. '.repeat(100)})),sources:{},draft:t===0?'An unfinished question':'',draftFiles:t===0?[{id:'fixture',name:'attachment.txt',text:'Attachment context',enabled:true}]:[]})) }));
  const first = account.library.courses[0]; first.threads[0].documentID=first.documents[0].id;
  Object.assign(session.navigation,{selectedCourseID:first.id,selectedDocumentID:first.documents[0].id,selectedThreadID:first.threads[0].id,showingCourseLibrary:true,page:3});
  store.save(account); store.navigate(session);
  // Suppress background classifier upgrades: this benchmark measures projection/navigation only.
  workspace.analyzeStoredMaterials = async () => {};
  workspace.upgradeOpenedDocument = () => {};
  const rows=[];
  for (const workflow of ['dashboardState','dashboardReturn','workspaceOpen','readerOpen']) {
    const times=[], bytes=[]; const before={writes,navigationWrites,indexReads,inventories}; const cpu=process.cpuUsage();
    for (let n=-warmup;n<samples;n++) {
      const start=performance.now();
      const state=workflow==='dashboardState'?await workspace.state(session):await workspace.action(session, workflow==='dashboardReturn'?{action:'library'}:workflow==='workspaceOpen'?{action:'course',id:first.id}:{action:'resume',id:first.documents[0].id});
      const encoded=JSON.stringify(state);
      if(n>=0){times.push(performance.now()-start);bytes.push(Buffer.byteLength(encoded));}
    }
    rows.push({workflow,p50Ms:percentile(times,.5),p95Ms:percentile(times,.95),samplesMs:times,bytes:bytes[0],work:{writes:writes-before.writes,navigationWrites:navigationWrites-before.navigationWrites,indexReads:indexReads-before.indexReads,inventories:inventories-before.inventories},cpu:process.cpuUsage(cpu),memory:process.memoryUsage()});
  }
  results.push({workspaces:size,materials:size*32,documents:size*12,messages:size*3*40,rows});
  await workspace.stop(); store.close(); await rm(root,{recursive:true,force:true});
}
const result={kind:'service (not UI)',environment:{node:process.version,os:release(),platform:process.platform,arch:process.arch,cpu:cpus()[0].model,memory:totalmem()},samples,warmup,results};
const output=process.argv[2];
if(output) await writeFile(resolve(output),JSON.stringify(result,null,2)+'\n');
console.log(JSON.stringify(result,null,2));
