import test from 'node:test';
import assert from 'node:assert/strict';
import { partitionState, mergeStateSurfaces } from '../../packages/core/src/state-surfaces.js';
test('surface partition round trips optional fields, navigation and future fields',()=>{
 const state={hosted:true,library:{version:1,courses:[{id:'c',documents:[]}],selectedCourseID:'c',page:9},draft:null,draftFiles:[],messages:[],futureField:'preserved',page:9};
 assert.deepEqual(mergeStateSurfaces(null,partitionState(state)),state);
 const next=mergeStateSurfaces(state,{reader:{library:{selectedDocumentID:'d'},page:2},conversation:{messages:[{id:'new'}]}});
 assert.equal(next.library.courses,state.library.courses);assert.equal(next.library.selectedCourseID,'c');assert.equal(next.page,2);
 assert.equal(state.page,9);assert.deepEqual(state.messages,[]);
});
