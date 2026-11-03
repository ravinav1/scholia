import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeStudyPlans, studyPlanResourceURL } from '../scripts/lib/ntnu-study-plans.mjs';
import { StudyPlanIndex, ntnuStudyPlans } from '../packages/core/src/study-plans.js';

const course = (code, status = 'O', overrides = {}) => ({ code, version: '1', name: `Course ${code}`, credit: '7.5',
  planelement: false, studyChoice: { code: status, name: status, description: null }, ...overrides });
const group = courses => ({ code: 'GROUP', name: 'Choose within this group', description: 'Choose two.',
  deadlinedate: null, relperiod: 1, courses, waypoint: false });
const node = (courseGroups = [], studyWaypoints = [], code = null) => ({ code, name: code,
  studyDirectionDesignationCode: null, studyDirectionDesignationName: null,
  studyDirection: code, courseGroups, studyWaypoints });
function fixture(startTerm = 'HØST') {
  const shared = group([course('TEST1000', 'M2A'), course('AM500218', 'V')]);
  const waypoint = { code: 'TRACKS', name: 'Select a track', description: null, deadlineDate: null,
    studyDirections: [node([shared], [], 'TRACK-A'), node([shared, group([course('TEST1001')])], [], 'TRACK-B')] };
  return { programmeCode: 'DEGREE', admissionYear: 2023, studyYears: 2, resourceURL: 'https://www.ntnu.no/', sha256: 'fixture',
    data: { publishedYears: [2023], studyplan: { code: 'DEGREE', name: 'Synthetic degree', year: 2023,
      startTerm, updated: 'fixture', studyPeriods: [
        { periodNumber: '1', direction: node([group([course('PRACTICE', 'O', { planelement: true, version: null, credit: '0' })])], [waypoint]) },
        { periodNumber: '2', direction: node([shared]) },
      ] } } };
}

test('normalization retains every branch, group rule and non-course requirement without duplicating course definitions', () => {
  const source = fixture(), catalog = normalizeStudyPlans([source], '2026-10-11T00:00:00Z');
  const index = new StudyPlanIndex(catalog);
  assert.equal(Object.keys(catalog.courses).length, 4);
  assert.equal(Object.keys(catalog.groups).length, 3);
  assert.equal(index.byPlan.get('DEGREE:2023').length, 8);
  assert.equal(index.course('TEST1000').length, 3);
  assert.equal(index.year('DEGREE', 2023, 1).length, 8);
  assert.equal(index.semester('DEGREE', 2023, 1, 'spring').length, 2);
  const matches = index.course('TEST1000');
  assert.deepEqual(matches.map(r => catalog.choices[r.choiceID].code), ['M2A', 'M2A', 'M2A']);
  assert.deepEqual(matches.map(r => r.branch.map(id => catalog.nodes[id].code)), [['TRACK-A'], ['TRACK-B'], []]);
  assert.equal(catalog.courses[index.course('PRACTICE')[0].courseID].kind, 'requirement');
  assert.deepEqual(index.summary('DEGREE:2023').missingPeriods, [3, 4]);
  assert.deepEqual(source, fixture(), 'Import must not mutate the source response');
});

test('calendar dates respect the admission year and spring-start plans', () => {
  const autumn = normalizeStudyPlans([fixture()], 'fixture').plans['DEGREE:2023'].periods;
  const spring = normalizeStudyPlans([fixture('VÅR')], 'fixture').plans['DEGREE:2023'].periods;
  assert.deepEqual(autumn.map(p => [p.term, p.calendarYear]), [['autumn', 2023], ['spring', 2024]]);
  assert.deepEqual(spring.map(p => [p.term, p.calendarYear]), [['spring', 2023], ['autumn', 2023]]);
});

test('wrong cohort, missing structure, malformed course and cyclic graph fail rather than silently dropping data', () => {
  for (const mutate of [s => { s.data.studyplan.year = 2024; }, s => { s.data.studyplan.studyPeriods = []; },
    s => { s.data.studyplan.studyPeriods[0].direction = null; },
    s => { delete s.data.studyplan.studyPeriods[0].direction.studyWaypoints; },
    s => { s.data.studyplan.studyPeriods[0].direction.courseGroups[0].courses[0].planelement = 'true'; }]) {
    const source = fixture(); mutate(source);
    assert.throws(() => normalizeStudyPlans([source], 'fixture'), /Unsupported/);
  }
  const catalog = normalizeStudyPlans([fixture()], 'fixture');
  const root = catalog.plans['DEGREE:2023'].periods[0].nodeID;
  catalog.nodes[root].choices[0].nodeIDs.push(root);
  assert.throws(() => new StudyPlanIndex(catalog), /direction graph/);
});

test('public read-only resource discovery rejects foreign hosts and mutation resources', () => {
  const value = 'https://www.ntnu.no/web/studier/studieplan?p_p_lifecycle=2&p_p_resource_id=studyplan';
  assert.equal(studyPlanResourceURL(`studyplanUrl:'${value}'`).href, value);
  for (const bad of [value.replace('www.ntnu.no', 'www.ntnu.no.evil.test'), value.replace('https:', 'http:'),
    value.replace('resource_id=studyplan', 'resource_id=updateCourseCombinations'), value.replace('lifecycle=2', 'lifecycle=1')])
    assert.throws(() => studyPlanResourceURL(`studyplanUrl:'${bad}'`), /Unexpected/);
  assert.throws(() => studyPlanResourceURL('<html>No widget</html>'), /not found/);
});

test('2023 snapshots cover all published semesters and every branch for both requested degrees', () => {
  assert.deepEqual(ntnuStudyPlans.defaultPlanIDs, ['MTNANO:2023', 'MTTK:2023']);
  for (const programme of ntnuStudyPlans.options.programmes) {
    assert.deepEqual(programme.plans.map(p => p.admissionYear), Array.from({ length: 18 }, (_, i) => 2026 - i));
    assert.equal(programme.defaultAdmissionYear, 2023);
  }
  for (const [id, membershipCount, courseCount, branchCount] of [['MTTK:2023', 1299, 194, 12], ['MTNANO:2023', 333, 149, 3]]) {
    const rows = ntnuStudyPlans.byPlan.get(id), summary = ntnuStudyPlans.summary(id);
    assert.equal(rows.length, membershipCount);
    assert.equal(new Set(rows.filter(r => ntnuStudyPlans.catalog.courses[r.courseID].kind === 'course')
      .map(r => ntnuStudyPlans.catalog.courses[r.courseID].code)).size, courseCount);
    assert.equal(new Set(rows.flatMap(r => r.branch).map(n => ntnuStudyPlans.catalog.nodes[n].code)).size, branchCount);
    assert.deepEqual(summary.publishedPeriods, [1, 2, 3, 4, 5, 6, 7, 8]);
    assert.deepEqual(summary.missingPeriods, [9, 10]);
    assert.equal(summary.admissionYear, 2023);
  }
  assert.equal(ntnuStudyPlans.course('TTK4100').find(p => p.planID === 'MTTK:2023').studyYear, 1);
  assert.equal(ntnuStudyPlans.course('TFY4330').find(p => p.planID === 'MTNANO:2023').studyYear, 3);
  assert.ok(ntnuStudyPlans.course('AM500218').length > 0, 'Six-digit course codes must not be dropped');
});

test('explicit degree choices override question/history and retain only the selected cohort, year, term and branch', () => {
  const selection = { programmeCode: 'MTTK', admissionYear: 2023, studyYear: 4, term: 'autumn', branchPath: ['MTTK-RFRO'] };
  const reference = ntnuStudyPlans.reference('What next for MTNANO?', [{ role: 'user', content: 'MTNANO' }], [], [selection]);
  assert.equal(reference.scope, 'selected-plans');
  assert.deepEqual(reference.plans.map(p => p.planID), ['MTTK:2023']);
  assert.deepEqual(reference.plans[0].selectedPeriods, [7]);
  assert.deepEqual(reference.plans[0].periods.map(p => p.number), [7]);
  assert.deepEqual([...new Set(Object.values(reference.nodes).map(n => n.directionCode).filter(Boolean))], ['MTTK-RFRO']);
  assert.match(reference.plans[0].selection.specialisation, /Robotsystemer/);
  assert.ok(Object.values(reference.courses).length > 5);
  const common = ntnuStudyPlans.selectedReference([{ ...selection, studyYear: 1, term: null }]);
  assert.ok(Object.values(common.courses).some(c => c.code === 'TTK4100'), 'Common first-year courses survive a later branch choice');
  const unpublished = ntnuStudyPlans.selectedReference([{ ...selection, studyYear: 5 }]);
  assert.deepEqual(unpublished.plans[0].selectedPeriods, [9]);
  assert.deepEqual(unpublished.plans[0].periods, []);
  assert.deepEqual(unpublished.plans[0].missingPeriods, [9, 10]);
  assert.deepEqual(unpublished.courses, {});
  assert.equal(ntnuStudyPlans.reference('MTTK', [], [], []), null, 'Turning off plans disables automatic detection');
});

test('a nested specialisation keeps ancestor requirements and excludes sibling tracks and profiles', () => {
  const source = fixture();
  source.data.studyplan.studyPeriods[0].direction.studyWaypoints[0].studyDirections[0].studyWaypoints = [{
    code: 'PROFILES', name: 'Profiles', studyDirections: [node([group([course('TEST2000')])], [], 'PROFILE-1'), node([group([course('TEST2001')])], [], 'PROFILE-2')],
  }];
  const index = new StudyPlanIndex(normalizeStudyPlans([source], 'fixture'));
  const chosen = { programmeCode: 'DEGREE', admissionYear: 2023, branchPath: ['TRACK-A', 'PROFILE-1'] };
  const selected = index.selectedReference([chosen]);
  assert.deepEqual(Object.values(selected.courses).map(c => c.code).sort(), ['AM500218', 'PRACTICE', 'TEST1000', 'TEST2000']);
  assert.equal(index.options.programmes[0].plans[0].branches.find(b => b.path.length === 2).name, 'TRACK-A / PROFILE-1');
  const parent = index.selectedReference([{ ...chosen, branchPath: ['TRACK-A'] }]);
  assert.ok(Object.values(parent.courses).some(c => c.code === 'TEST2001'), 'Selecting an area keeps its alternative profiles');
});

test('invalid or obsolete selections fail closed before assembling advice', () => {
  const base = { programmeCode: 'MTNANO', admissionYear: 2023 };
  for (const value of ['MTNANO', {}, [{ ...base, admissionYear: 2027 }], [{ ...base, admissionYear: '2023' }],
    [{ ...base, studyYear: 0 }], [{ ...base, studyYear: 6 }], [{ ...base, studyYear: '3' }], [{ ...base, term: 'winter' }],
    [{ ...base, branchPath: ['MTTK-RFRO'] }], [{ ...base, branchPath: 'MTNANO-BT' }],
    [{ ...base, unexpected: 'private data' }], [base, base]])
    assert.throws(() => ntnuStudyPlans.selectedReference(value), /Choose/);
});

test('every published cohort and profile can produce a bounded, connected selection reference', () => {
  for (const programme of ntnuStudyPlans.options.programmes) for (const plan of programme.plans) {
    for (const branchPath of [[], ...plan.branches.map(b => b.path)]) {
      const selected = ntnuStudyPlans.selectedReference([{ programmeCode: programme.programmeCode, admissionYear: plan.admissionYear, branchPath }]);
      assert.ok(JSON.stringify(selected).length < 200_000);
      for (const node of Object.values(selected.nodes)) for (const choice of node.choices)
        for (const child of choice.nodeIDs) assert.ok(selected.nodes[child]);
      for (const period of selected.plans[0].periods) assert.ok(selected.nodes[period.nodeID]);
    }
  }
});

test('advice gets small exact course lookups, full degree context when needed, and retains follow-up context', () => {
  const question = 'TTK4100 or TFY4330 for MTTK and MTNANO?';
  const reference = ntnuStudyPlans.reference(question);
  assert.equal(reference.scope, 'course-lookup');
  assert.equal(reference.matches.length, 2);
  assert.ok(JSON.stringify(reference).length < 5000);
  assert.deepEqual(reference.matches.map(r => [reference.courses[r.courseID].code, r.planID, r.studyYear]),
    [['TFY4330', 'MTNANO:2023', 3], ['TTK4100', 'MTTK:2023', 1]]);
  const full = ntnuStudyPlans.reference('What should I study next in MTTK?', [{ role: 'user', content: question }]);
  assert.equal(full.scope, 'full-plans');
  assert.deepEqual(full.plans.map(p => p.planID), ['MTTK:2023'], 'An explicit follow-up programme narrows the earlier comparison');
  assert.ok(Object.keys(full.courses).length >= 194);
  assert.equal(ntnuStudyPlans.reference('Why that course?', [{ role: 'user', content: 'TTK4100 or TFY4330?' }]).matches.length, 2);
  assert.equal(ntnuStudyPlans.reference('General revision advice'), null);
  assert.equal(ntnuStudyPlans.reference('No course question', [{ role: 'assistant', content: 'MTTK' }]), null);
});
