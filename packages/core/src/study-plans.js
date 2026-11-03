import catalog from '../data/ntnu-study-plans.json' with { type: 'json' };
import { branchKey, compatibleBranch, selectedPeriodNumbers, studyPlanOptions } from './study-plan-selection.js';

export const STUDY_PLAN_INSTRUCTIONS = `Use the attached NTNU study-plan reference for programme placement, study year, semester and choice rules. The retrieved-plans catalogue is a small index of available degrees at the selected, locked admission years. It is not enrolment evidence. results contains only the model-requested local lookups. For a comparison of exam X in one degree and exam Y in another, start with which exam to take and why, use passedCourseCodes as completed background when supplied, and relate each option to its actual year and branch placement. Distinguish filling a foundation gap from advancing in a specialisation; compare relevant requirements and preparation rather than automatically preferring the earlier-year course. Do not replace the requested comparison with all available degrees or courses. A required course (O) is required within its branch; never combine alternative branches into one set of requirements. VA, VB and V are elective statuses; M1A/M2A are group minimums, not a requirement to complete every listed course. Keep group descriptions and non-course requirements separate from exam courses. Course lookups show only the requested placements. Year lookups preserve common and ancestor requirements for the retrieved branch. These are retrieval choices, not confirmation of the student’s chosen specialisation. Course definitions are shared; choice rules belong to group entries. Missing periods are unpublished, not empty or optional. An unmatched course code was not found in this cohort snapshot; it does not prove ineligibility or equivalence. Omitted records are outside this lookup, not absent from the degree. Never substitute another admission year or assume old chat claims override the current cohorts or passed-course list. Do not infer prerequisites, eligibility, equivalences or degree completion percentages from placements and passes alone. If a decisive rule, study direction or preparation level is missing, give a conditional recommendation and ask a focused question. Use sourceURL when citing requirements.`;

export class StudyPlanIndex {
  constructor(data) {
    if (data?.schemaVersion !== 1 || !data.plans || Object.keys(data.plans).length > 200 ||
        !data.nodes || !data.groups || !data.courses || !data.choices)
      throw new Error('Unsupported study-plan catalog.');
    this.catalog = data;
    this.options = studyPlanOptions(data);
    this.defaultPlanIDs = this.options.programmes.map(p => `${p.programmeCode}:${p.defaultAdmissionYear}`).sort();
    this.byCourse = new Map();
    this.byPlanYear = new Map();
    this.byPlan = new Map();
    let count = 0;
    for (const [planID, plan] of Object.entries(data.plans)) {
      this.byPlan.set(planID, []);
      const walk = (nodeID, period, branch, ancestors = new Set()) => {
        const node = data.nodes[nodeID];
        if (!node || ancestors.has(nodeID) || ancestors.size > 12) throw new Error('Invalid study-plan direction graph.');
        const route = branchKey(node) ? [...branch, nodeID] : branch;
        for (const groupID of node.groupIDs) {
          const group = data.groups[groupID];
          if (!group) throw new Error('Missing study-plan group.');
          for (const entry of group.entries) {
            const course = data.courses[entry.courseID];
            if (!course || !data.choices[entry.choiceID] || ++count > 100_000) throw new Error('Invalid study-plan membership.');
            const hit = { planID, studyYear: period.studyYear, period: period.number, term: period.term,
              calendarYear: period.calendarYear, branch: route, groupID, ...entry };
            this.byPlan.get(planID).push(hit);
            const yearKey = `${planID}:${period.studyYear}`;
            if (!this.byPlanYear.has(yearKey)) this.byPlanYear.set(yearKey, []);
            this.byPlanYear.get(yearKey).push(hit);
            if (!this.byCourse.has(course.code)) this.byCourse.set(course.code, []);
            this.byCourse.get(course.code).push(hit);
          }
        }
        for (const choice of node.choices)
          for (const child of choice.nodeIDs) walk(child, period, route, new Set([...ancestors, nodeID]));
      };
      for (const period of plan.periods) walk(period.nodeID, period, []);
    }
  }

  course(code) { return this.byCourse.get(String(code).toUpperCase()) || []; }
  year(programmeCode, admissionYear, studyYear) {
    return this.byPlanYear.get(`${programmeCode.toUpperCase()}:${admissionYear}:${studyYear}`) || [];
  }
  semester(programmeCode, admissionYear, studyYear, term) {
    return this.year(programmeCode, admissionYear, studyYear).filter(row => row.term === term);
  }
  summary(planID) {
    const plan = this.catalog.plans[planID];
    if (!plan) return null;
    const publishedPeriods = plan.periods.map(period => period.number);
    return { planID, programmeCode: plan.programmeCode, admissionYear: plan.admissionYear, name: plan.name,
      studyYears: plan.studyYears, sourceURL: plan.sourceURL, sourceUpdatedAt: plan.sourceUpdatedAt,
      fetchedAt: this.catalog.fetchedAt, publishedPeriods,
      missingPeriods: Array.from({ length: plan.studyYears * 2 }, (_, i) => i + 1).filter(n => !publishedPeriods.includes(n)) };
  }

  selectedReference(selections) {
    if (!Array.isArray(selections) || selections.length > 8) throw new Error('Choose valid degree plans.');
    if (!selections.length) return null;
    const seen = new Set(), plans = [], nodes = {}, groups = {}, courses = {}, choices = {};
    for (const selection of selections) {
      const invalid = () => { throw new Error('Choose an available admission year, study year, semester and specialisation.'); };
      if (!selection || typeof selection !== 'object' || Array.isArray(selection) ||
          Object.keys(selection).some(key => !['programmeCode', 'admissionYear', 'studyYear', 'term', 'branchPath'].includes(key)) ||
          typeof selection.programmeCode !== 'string' || !Number.isInteger(selection.admissionYear)) invalid();
      const id = `${selection.programmeCode}:${selection.admissionYear}`, plan = this.catalog.plans[id];
      if (!plan || seen.has(selection.programmeCode) || (selection.studyYear != null &&
          (!Number.isInteger(selection.studyYear) || selection.studyYear < 1 || selection.studyYear > plan.studyYears)) ||
          (selection.term != null && !['autumn', 'spring'].includes(selection.term))) invalid();
      seen.add(selection.programmeCode);
      const path = selection.branchPath ?? [];
      const option = this.options.programmes.find(p => p.programmeCode === selection.programmeCode).plans.find(p => p.planID === id);
      if (!Array.isArray(path) || (path.length && !option.branches.some(b => JSON.stringify(b.path) === JSON.stringify(path)))) invalid();
      const visit = (nodeID, route = []) => {
        const node = this.catalog.nodes[nodeID], key = branchKey(node);
        if (key) route = [...route, key];
        if (!compatibleBranch(route, path)) return null;
        // A shared node can be pruned differently in two selected programmes.
        const outputID = `${id}/${nodeID}/${route.join('/')}`;
        if (nodes[outputID]) return outputID;
        nodes[outputID] = { ...node, choices: node.choices.map(choice => ({ ...choice,
          nodeIDs: choice.nodeIDs.map(child => visit(child, route)).filter(Boolean) })).filter(choice => choice.nodeIDs.length) };
        for (const groupID of node.groupIDs) {
          const group = this.catalog.groups[groupID]; groups[groupID] = group;
          for (const entry of group.entries) {
            courses[entry.courseID] = this.catalog.courses[entry.courseID];
            choices[entry.choiceID] = this.catalog.choices[entry.choiceID];
          }
        }
        return outputID;
      };
      const selectedPeriods = selectedPeriodNumbers(plan, selection);
      const periods = plan.periods.filter(p => selectedPeriods.includes(p.number))
        .map(period => ({ ...period, nodeID: visit(period.nodeID) })).filter(p => p.nodeID);
      plans.push({ ...this.summary(id), selection: { ...selection, branchPath: path,
        specialisation: option.branches.find(b => JSON.stringify(b.path) === JSON.stringify(path))?.name ?? null },
        selectedPeriods, periods });
    }
    return { scope: 'selected-plans', plans, nodes, groups, courses, choices };
  }

  reference(question, history = [], extraCourseCodes = [], selections = null) {
    if (selections != null) return this.selectedReference(selections);
    const text = [question, ...history.filter(m => m.role === 'user').map(m => m.content)].join('\n').toUpperCase();
    const tokens = new Set(text.match(/[A-ZÆØÅ0-9]+/g) || []);
    const currentTokens = new Set(question.toUpperCase().match(/[A-ZÆØÅ0-9]+/g) || []);
    const currentPlans = this.defaultPlanIDs.filter(id => currentTokens.has(this.catalog.plans[id].programmeCode));
    const selected = currentPlans.length ? currentPlans
      : this.defaultPlanIDs.filter(id => tokens.has(this.catalog.plans[id].programmeCode));
    const codesIn = value => [...new Set((value.toUpperCase().match(/(?<![\p{L}\p{N}_])[A-ZÆØÅ]{2,8}\d{3,6}[A-Z]?(?![\p{L}\p{N}_])/gu) || []))];
    const currentCodes = codesIn(question);
    const codes = currentCodes.length ? currentCodes : selected.length ? [] : codesIn(text);
    if (!selected.length && !codes.some(code => this.byCourse.has(code))) return null;
    const planIDs = selected.length ? selected : this.defaultPlanIDs;
    const plans = planIDs.map(id => this.summary(id));
    if (codes.length) {
      const wanted = [...new Set([...codes, ...extraCourseCodes])].sort();
      const matches = wanted.flatMap(code => this.course(code).filter(row => planIDs.includes(row.planID)));
      const pick = (table, ids) => Object.fromEntries([...new Set(ids)].sort().map(id => [id, table[id]]));
      const groups = pick(this.catalog.groups, matches.map(row => row.groupID));
      return { scope: 'course-lookup', plans, requestedCourseCodes: codes, matches,
        courses: pick(this.catalog.courses, matches.map(row => row.courseID)),
        choices: pick(this.catalog.choices, matches.map(row => row.choiceID)),
        groups: Object.fromEntries(Object.entries(groups).map(([id, group]) => [id,
          { code: group.code, name: group.name, description: group.description, totalEntries: group.entries.length }])),
        branches: Object.fromEntries([...new Set(matches.flatMap(row => row.branch))].sort().map(id => {
          const node = this.catalog.nodes[id];
          return [id, { code: node.code, name: node.name, directionCode: node.directionCode, designation: node.designation }];
        })) };
    }
    const nodes = {}, groups = {}, courses = {}, choices = {};
    const visit = id => {
      if (nodes[id]) return;
      const node = this.catalog.nodes[id]; nodes[id] = node;
      for (const groupID of node.groupIDs) {
        const group = this.catalog.groups[groupID]; groups[groupID] = group;
        for (const entry of group.entries) {
          courses[entry.courseID] = this.catalog.courses[entry.courseID];
          choices[entry.choiceID] = this.catalog.choices[entry.choiceID];
        }
      }
      for (const choice of node.choices) choice.nodeIDs.forEach(visit);
    };
    for (const id of planIDs) this.catalog.plans[id].periods.forEach(period => visit(period.nodeID));
    return { scope: 'full-plans', plans: plans.map(plan => ({ ...plan, periods: this.catalog.plans[plan.planID].periods })),
      nodes, groups, courses, choices };
  }
}

export const ntnuStudyPlans = new StudyPlanIndex(catalog);
