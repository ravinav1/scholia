import test from 'node:test';
import assert from 'node:assert/strict';
import { parseHTML } from 'linkedom';
import { workspacePanelMarkup, filterWorkspacePanel, workspaceCatalog, libraryCourses, workspacePanelRenderKey, assignmentPanelRenderKey } from '../../apps/web/workspace/course-library.js';
import { assignmentAgendaMarkup } from '../../apps/web/workspace/assignments.js';
const fixture = (count = 500) => ({ library: { courses: Array.from({length:count},(_,i)=>({id:String(i),name:`Workspace ${i}`,code:`TEST${i}`,term:'Autumn',favorite:i===0,documents:[],canvasMaterials:[]})), courseLibraryView:'all' }, selectedSemesterID:'all', semesters:[] });
test('rapid workspace filtering preserves every card, input identity', () => {
  const state=fixture(); const {document}=parseHTML(workspacePanelMarkup(state,'',{retainCards:true}));
  const panel=document.querySelector('.workspace-panel'), input=document.querySelector('#course-search'), cards=[...document.querySelectorAll('.course-card')];
  for(const query of ['T','TE','TEST49','Workspace','no match','']) {
    input.value=query; assert.equal(filterWorkspacePanel(panel,query), libraryCourses(state,query).length);
    assert.equal(document.querySelector('#course-search'),input);
    assert.deepEqual([...document.querySelectorAll('.course-card')],cards);
  }
});
test('prepared ordering invalidates metadata but resolves document contents from current data', () => {
  const state=fixture(2), original=workspaceCatalog(state), document={id:'new-reading'};
  state.library.courses=structuredClone(state.library.courses);state.library.courses[0].documents.push(document);
  assert.equal(workspaceCatalog(state),original);assert.equal(libraryCourses(state)[0].documents[0],document);
  for(const field of ['id','name','code','term','favorite']) {
    const before=workspaceCatalog(state);state.library.courses[0][field]=field==='favorite'?false:`changed-${field}`;
    assert.notEqual(workspaceCatalog(state),before,field);
  }
  assert.notEqual(workspaceCatalog(state,'en-US'),workspaceCatalog(state,'nb-NO'));
  const before=workspaceCatalog(state);state.library.courses.reverse();assert.notEqual(workspaceCatalog(state),before);
});
test('draft typing and streamed messages do not invalidate dashboard panels', () => {
  const state=fixture(2), workspace=workspacePanelRenderKey(state), assignments=assignmentPanelRenderKey(state);
  state.messages=[{content:'streamed token'}];state.draft='typing';state.library.courses[0].threads=[{messages:[{content:'token'}]}];
  assert.equal(workspacePanelRenderKey(state),workspace);assert.equal(assignmentPanelRenderKey(state),assignments);
  state.library.courses[0].canvasMaterials.push({id:'a',kind:'assignments',assignment:{dueAt:'2026-12-01'}});
  assert.notEqual(assignmentPanelRenderKey(state),assignments);
});
test('dashboard assignments bound DOM work and complete view exposes all matching results', () => {
  const state=fixture(1);state.library.courses[0].canvasMaterials=Array.from({length:600},(_,i)=>({id:`a${i}`,kind:'assignments',title:`Exercise ${i}`,assignment:{dueAt:'2026-12-01T12:00:00Z',status:'notSubmitted',submissionTypes:['online_upload']}}));
  const parse=(options)=>parseHTML(assignmentAgendaMarkup(state.library.courses,options)).document;
  const dashboard=parse({});assert.equal(dashboard.querySelectorAll('.agenda-item').length,30);
  assert.match(dashboard.textContent||dashboard.toString(),/Showing 30 of 600 matching assignments/);
  assert.ok(dashboard.querySelector('[data-action=assignments]'));
  const complete=parse({dedicated:true,limit:600});assert.equal(complete.querySelectorAll('.agenda-item').length,600);
  assert.equal(complete.querySelector('[data-action=moreAssignments]'),null);
});
