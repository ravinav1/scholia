// Real Chromium + hosted service, isolated data only. Values are diagnostics, never CI timing assertions.
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir, cpus, totalmem, release } from 'node:os';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { chromiumSession } from '../smoke/browser/lib/chromium.mjs';
const sourceRoot = resolve(process.env.SCHOLIA_BENCH_ROOT || '.');
const { createHostedServer } = await import(pathToFileURL(join(sourceRoot, 'apps/server/server.js')));
const output = resolve(process.env.SCHOLIA_BENCH_OUTPUT || 'results/performance/web-after.json');
const counts = (process.env.SCHOLIA_BENCH_COUNTS || '6,89,500').split(',').map(Number);
const sampleCount = Number(process.env.SCHOLIA_BENCH_SAMPLES || 25);
const uuid = (value) => { const x = createHash('sha256').update(value).digest('hex'); return `${x.slice(0,8)}-${x.slice(8,12)}-4${x.slice(13,16)}-8${x.slice(17,20)}-${x.slice(20,32)}`; };
const summarize = (values) => { const sorted = [...values].sort((a,b)=>a-b); return { samples: values, p50: sorted[Math.floor(sorted.length/2)], p95: sorted[Math.ceil(sorted.length*.95)-1] }; };
const report = { environment: { date: new Date().toISOString(), commit: execFileSync('git',['rev-parse','HEAD'],{cwd:sourceRoot,encoding:'utf8'}).trim(), sourceRoot, os: release(), platform: process.platform, cpu: cpus()[0].model, cores: cpus().length, memoryBytes: totalmem(), node: process.version, configuration: 'minified production web build; headless Chromium; hosted Node service', warmup: '3 complete workspace/reading/dashboard cycles; 4 search inputs', samples: sampleCount }, fixtures: [] };
for (const count of counts) {
  const root = await mkdtemp(join(tmpdir(), 'scholia-ui-benchmark-'));
  let browser, app;
  try {
    // Bind once to discover an unused port; createHostedServer validates its configured Origin.
    const { createServer } = await import('node:net'); const reserve=createServer();
    await new Promise(r=>reserve.listen(0,'127.0.0.1',r)); const port=reserve.address().port;
    await new Promise(r=>reserve.close(r)); const origin=`http://127.0.0.1:${port}`;
    app=createHostedServer({ root, origin, assets: join(sourceRoot,'dist/web') });
    const user=await app.store.createUser('fixture@example.test','deterministic fixture password');
    const account=app.workspaces.account(user.id);
    const reading=await app.documents.import(user.id,'Linear algebra.txt',Buffer.from('Eigenvectors preserve direction. '.repeat(2000)));
    const messages=Array.from({length:80},(_,i)=>({id:uuid(`message-${i}`),role:i%2?'assistant':'user',content:`Long conversation ${i}. `+'Mathematical explanation. '.repeat(20),createdAt:1800000000+i}));
    account.library.courses=Array.from({length:count},(_,i)=>({
      id:uuid(`course-${i}`),name:`Workspace ${String(i).padStart(3,'0')} — Linear algebra`,code:`TEST${i}`,term:`${2024+i%3} ${i%2?'Autumn':'Spring'}`,favorite:i<5,
      documents:Array.from({length:24},(_,j)=>({...reading,id:i===0&&j===0?reading.id:uuid(`doc-${i}-${j}`),title:`Reading ${i}.${j}`,lastOpenedAt:1800000000+i*24+j,lastPage:1,indexUnavailable:!(i===0&&j===0)})),
      canvasMaterials:Array.from({length:12},(_,j)=>({id:`assignments:${j}`,kind:'assignments',title:`Exercise ${i}.${j}`,assignment:{dueAt:new Date(Date.UTC(2026,10,1+j)).toISOString(),status:j%4===0?'submitted':'notSubmitted',submissionTypes:['online_upload']}})),
      threads:[{id:uuid(`thread-${i}`),title:'Long conversation',documentID:i===0?reading.id:uuid(`doc-${i}-0`),draft:'Recovered draft with attachments',draftFiles:[{id:uuid(`attachment-${i}`),name:'notes.txt',mimeType:'text/plain',text:'Retained attachment context',enabled:true}],messages:structuredClone(messages),sources:{}}]
    }));
    app.store.save(account);
    const auth=await app.store.login('fixture@example.test','deterministic fixture password');
    await new Promise(r=>app.server.listen(port,'127.0.0.1',r));
    browser=await chromiumSession(); const {send,evaluate,until}=browser;
    report.environment.browser=(await send('Browser.getVersion')).product;
    await send('Network.enable'); await send('Performance.enable');
    await send('Network.setCookie',{name:'scholia_session',value:auth.value,url:origin,httpOnly:true,sameSite:'Strict'});
    await send('Emulation.setDeviceMetricsOverride',{width:1460,height:960,deviceScaleFactor:1,mobile:false});
    await send('Page.addScriptToEvaluateOnNewDocument',{source:`window.__longTasks=[];new PerformanceObserver(list=>window.__longTasks.push(...list.getEntries().map(e=>({start:e.startTime,duration:e.duration})))).observe({type:'longtask',buffered:true});window.__firstUseful=null;new MutationObserver(()=>{if(window.__firstUseful===null&&document.querySelector('.course-card'))requestAnimationFrame(()=>requestAnimationFrame(()=>{window.__firstUseful??=performance.now()}))}).observe(document,{childList:true,subtree:true});`});
    await send('Page.navigate',{url:origin}); await until('window.__firstUseful !== null',{timeoutMs:60000});
    const startup=await evaluate(`({firstUsefulPaintMs:window.__firstUseful,resources:performance.getEntriesByType('resource').map(r=>({name:new URL(r.name).pathname,bytes:r.encodedBodySize,duration:r.duration}))})`);
    const initialMetrics=await send('Performance.getMetrics');
    const transition=async(selector,condition)=>evaluate(`(async()=>{const start=performance.now();document.querySelector(${JSON.stringify(selector)}).click();await new Promise((resolve,reject)=>{const deadline=performance.now()+30000;function check(){if(${condition})requestAnimationFrame(()=>requestAnimationFrame(resolve));else if(performance.now()>deadline)reject(new Error('Navigation timeout'));else requestAnimationFrame(check)}check()});return performance.now()-start})()`);
    const times={workspace:[],reading:[],dashboard:[]};
    for(let i=-3;i<sampleCount;i++){
      const workspace=await transition(`[data-action=course][data-id="${account.library.courses[0].id}"]`,`!document.querySelector('#workspace').hidden&&!!document.querySelector('.course-materials')`);
      const readingTime=await transition(`#material-nav [data-action=document][data-id="${reading.id}"]`,`document.querySelector('#reader-content .paper')?.textContent.includes('Eigenvectors')`);
      const dashboard=await transition('.nav-all',`!document.querySelector('#library').hidden&&!!document.querySelector('.course-card')`);
      if(i>=0){times.workspace.push(workspace);times.reading.push(readingTime);times.dashboard.push(dashboard);}
    }
    const search=await evaluate(`(async()=>{const samples=[],mutations=[];for(let i=-4;i<${sampleCount};i++){const input=document.querySelector('#course-search');input.focus();const query=['W','Wo','Work','TEST1','TEST49',''][((i+6)%6)];input.value=query;input.setSelectionRange(query.length,query.length);let added=0;const observer=new MutationObserver(records=>{added+=records.reduce((n,r)=>n+r.addedNodes.length,0)});observer.observe(document.querySelector('#library'),{childList:true,subtree:true});const start=performance.now();input.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:query}));await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);if(i>=0){samples.push(performance.now()-start);mutations.push(added)}observer.disconnect()}const input=document.querySelector('#course-search');input.value='';input.dispatchEvent(new Event('input',{bubbles:true}));return{samples,addedNodes:mutations}})()`);
    const quick=await evaluate(`(async()=>{document.dispatchEvent(new KeyboardEvent('keydown',{key:'k',metaKey:true,shiftKey:true,bubbles:true}));const input=document.querySelector('#workspace-shortcuts-query');const samples=[];for(let i=0;i<${sampleCount};i++){input.value=['TEST','TEST1','Workspace',''][i%4];const start=performance.now();input.dispatchEvent(new Event('input',{bubbles:true}));await new Promise(requestAnimationFrame);await new Promise(requestAnimationFrame);samples.push(performance.now()-start)}document.querySelector('#workspace-shortcuts-dialog').close();return samples})()`);
    await send('HeapProfiler.collectGarbage'); const retainedMetrics=await send('Performance.getMetrics');
    const metric=(values,name)=>values.metrics.find(x=>x.name===name)?.value;
    const result={workspaces:count,materials:count*36,assignments:count*12,documents:count*24,conversationMessages:count*80,realIndexedDocuments:1,fixtureNote:'All metadata real; one readable 64KB document; other document indexes intentionally unavailable. No network, Canvas, or AI providers.',startup,latencyMs:Object.fromEntries(Object.entries(times).map(([k,v])=>[k,summarize(v)])),search:{...summarize(search.samples),addedNodes:search.addedNodes},quickJump:summarize(quick),memory:{initialJSHeapBytes:metric(initialMetrics,'JSHeapUsedSize'),retainedJSHeapBytes:metric(retainedMetrics,'JSHeapUsedSize'),initialDOMNodes:metric(initialMetrics,'Nodes'),retainedDOMNodes:metric(retainedMetrics,'Nodes'),taskDurationSeconds:metric(retainedMetrics,'TaskDuration')-metric(initialMetrics,'TaskDuration')},longTasks:await evaluate('window.__longTasks'),errors:browser.errors};
    report.fixtures.push(result); await mkdir(resolve(output,'..'),{recursive:true});await writeFile(output,JSON.stringify(report,null,2));
    await browser.screenshot(output.replace(/\.json$/,`-${count}.png`));
    assert.equal(browser.errors.length,0,'No unhandled browser exceptions');
    console.log(JSON.stringify({workspaces:count,dashboardP95:result.latencyMs.dashboard.p95,searchP95:result.search.p95,output}));
  } finally {await browser?.close();await app?.close();await rm(root,{recursive:true,force:true});}
}
