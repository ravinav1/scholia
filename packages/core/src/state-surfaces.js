// Protocol v1 partitions the legacy state without changing its product semantics.
// A patch replaces complete fields in one surface. `library` is merged one level deep.
export const stateSurfaceNames = ['catalog', 'dashboard', 'reader', 'conversation', 'activity', 'settings'];
export const surfaceFields = {
  catalog: ['semesters', 'warnings'],
  dashboard: ['learningRevision', 'reviewDue'],
  reader: ['showingLibrary', 'selectedSemesterID', 'materialGroups', 'materialFiles', 'page', 'pageText',
    'loadingDocument', 'assignmentText', 'assignmentFiles', 'assignmentPDFs', 'assignmentFileNotices',
    'assignmentNotice', 'context', 'contextScope', 'includeCourse', 'workspaceMemory'],
  conversation: ['messages', 'sources', 'draft', 'draftImage', 'draftFiles', 'draftOwner',
    'automaticContextEnabled', 'mode', 'entirePDF', 'editing', 'canSend', 'answerStartedAt'],
  activity: ['streaming', 'busy', 'status', 'error', 'assignmentRefreshBusy'],
  settings: ['hosted', 'account', 'capabilities', 'models', 'providerID', 'modelID', 'studyModelMode', 'reasoningEffort', 'language'],
};
const navigationFields = new Set(['selectedCourseID', 'selectedDocumentID', 'selectedThreadID',
  'selectedAssignmentID', 'showingCourseLibrary', 'selectedSemesterID', 'courseLibraryView', 'page',
  'selection', 'mode', 'assignmentNotice', 'automaticContextEnabled', 'includeCourse', 'editing', 'navigationID']);
export function partitionState(state) {
  const surfaces = Object.fromEntries(stateSurfaceNames.map(name => [name, {}]));
  for (const [surface, fields] of Object.entries(surfaceFields))
    for (const field of fields) if (field in state) surfaces[surface][field] = state[field];
  for (const [key,value] of Object.entries(state.library || {})) {
    const surface = key === 'courses' ? 'catalog' : navigationFields.has(key) ? 'reader' : 'dashboard';
    (surfaces[surface].library ||= {})[key] = value;
  }
  // Future legacy fields retain compatibility rather than silently disappearing.
  const known = new Set(Object.values(surfaceFields).flat());
  for (const [key,value] of Object.entries(state))
    if (key !== 'library' && !known.has(key)) surfaces.reader[key] = value;
  return surfaces;
}
export function mergeStateSurfaces(state, patches) {
  const next = { ...state, library: { ...state?.library } };
  for (const name of stateSurfaceNames) {
    const patch = patches[name];
    if (!patch) continue;
    const { library, ...fields } = patch;
    Object.assign(next, fields);
    if (library) Object.assign(next.library, library);
  }
  return next;
}
