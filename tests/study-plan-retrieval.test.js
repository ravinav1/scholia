import test from 'node:test';
import assert from 'node:assert/strict';
import { ntnuStudyPlans as index } from '../packages/core/src/study-plans.js';
import { degreeCatalogue, retrieveDegreeInformation as retrieve } from '../packages/core/src/study-plan-retrieval.js';

const cohorts = [{ programmeCode: 'MTTK', admissionYear: 2023 }, { programmeCode: 'MTNANO', admissionYear: 2022 }];
const response = queries => JSON.stringify({ queries });
test('the routing catalogue advertises only selected cohorts without sending course lists', () => {
  const value = degreeCatalogue(index, cohorts);
  assert.deepEqual(value.plans.map(p => p.planID), ['MTTK:2023', 'MTNANO:2022']);
  assert.ok(JSON.stringify(value).length < 9000);
  assert.ok(!JSON.stringify(value).includes('TTK4100'));
  assert.ok(value.plans.every(p => p.years.length === 5 && !p.nodes && !p.groups && !p.courses));
  assert.equal(value.admissionYearsLocked, true);
  assert.equal(degreeCatalogue(index, []), null);
});

test('a cross-degree exam comparison retrieves named courses and selected background years, not entire plans', () => {
  const result = retrieve(index, response([
    { kind: 'courses', programmeCode: 'MTTK', courseCodes: ['TTK4100', 'TDT4109'] },
    { kind: 'courses', programmeCode: 'MTNANO', courseCodes: ['TFY4330'] },
    { kind: 'year', programmeCode: 'MTTK', studyYear: 1 },
    { kind: 'year', programmeCode: 'MTNANO', studyYear: 3, term: 'spring', branchPath: ['MTNANO-BT'] },
  ]), cohorts);
  assert.equal(result.scope, 'retrieved-plans');
  assert.equal(result.results[0].data.planID, 'MTTK:2023');
  assert.equal(result.results[1].data.planID, 'MTNANO:2022');
  assert.ok(result.results[0].data.matches.some(m => result.results[0].data.courses[m.courseID].code === 'TTK4100' && m.studyYear === 1));
  assert.ok(result.results[1].data.matches.some(m => m.studyYear === 3));
  assert.deepEqual(result.results[2].data.plans[0].periods.map(p => p.number), [1, 2]);
  assert.deepEqual(result.results[3].data.plans[0].periods.map(p => p.number), [6]);
  assert.ok(!JSON.stringify(result.results).includes('MTTK-RFRO'), 'No unrelated MTTK profile course data is retrieved (catalogue branch names are metadata only)');
});

test('lookup commands cannot change cohort, access files or URLs, invent branches, or exceed bounds', () => {
  const year = { kind: 'year', programmeCode: 'MTTK', studyYear: 1 };
  for (const query of [{ ...year, admissionYear: 2024 }, { ...year, programmeCode: 'UNSELECTED' },
    { ...year, studyYear: true }, { ...year, studyYear: 0 }, { ...year, term: 'winter' },
    { ...year, branchPath: ['MTNANO-BT'] }, { kind: 'read', url: 'https://example.invalid' },
    { kind: 'overview', programmeCode: 'MTTK', path: '/private' }, { kind: 'toString', programmeCode: 'MTTK' },
    { kind: 'courses', programmeCode: 'MTTK', courseCodes: [] },
    { kind: 'courses', programmeCode: 'MTTK', courseCodes: Array(21).fill('TTK4100') }])
    assert.throws(() => retrieve(index, response([query]), cohorts), /valid degree information/);
  for (const text of ['not JSON', '{}', '{"queries":{}}', response(Array(9).fill(year)), ' '.repeat(8001)])
    assert.throws(() => retrieve(index, text, cohorts), /valid degree information/);
  assert.throws(() => retrieve(index, response([1, 2, 3, 4, 5].map(studyYear => ({ kind: 'year', programmeCode: 'MTTK', studyYear }))), cohorts), /too broad/);
});

test('overview, unpublished years, unmatched codes and no relevant degree retain explicit limits', () => {
  const result = retrieve(index, response([{ kind: 'overview', programmeCode: 'MTTK' },
    { kind: 'year', programmeCode: 'MTTK', studyYear: 5 },
    { kind: 'courses', programmeCode: 'MTTK', courseCodes: ['UNKNOWN1000'] }]), cohorts);
  assert.deepEqual(result.results[0].data.missingPeriods, [9, 10]);
  assert.deepEqual(result.results[1].data.plans[0].periods, []);
  assert.deepEqual(result.results[2].data.unmatchedCourseCodes, ['UNKNOWN1000']);
  assert.deepEqual(retrieve(index, response([]), cohorts).results, []);
  assert.equal(retrieve(index, response([]), []), null);
});
