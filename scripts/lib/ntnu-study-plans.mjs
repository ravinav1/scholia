import { createHash } from 'node:crypto';

const fail = () => { throw new Error('Unsupported or incomplete NTNU study-plan data.'); };
const text = (value, limit = 500) => {
  if (value == null) return null;
  if (typeof value !== 'string' || value.length > limit) return fail();
  return value.trim();
};
const list = value => value == null ? [] : Array.isArray(value) && value.length <= 5000 ? value : fail();
const dictionary = () => Object.create(null);

// Course definitions, choice rules, course groups and direction nodes are
// interned separately. Repeated elective lists across tracks are stored once.
// Choice status belongs to group membership, never to the course definition.
export function normalizeStudyPlans(sources, fetchedAt) {
  const catalog = { schemaVersion: 1, fetchedAt, courses: dictionary(), choices: dictionary(),
    groups: dictionary(), nodes: dictionary(), plans: dictionary() };
  let visited = 0;
  function intern(table, prefix, value) {
    const json = JSON.stringify(value);
    const id = prefix + createHash('sha256').update(json).digest('hex').slice(0, 20);
    if (table[id] && JSON.stringify(table[id]) !== json) throw new Error('Study-plan identifier collision.');
    table[id] = value;
    return id;
  }
  function course(row) {
    if (!row || typeof row.planelement !== 'boolean' || !row.studyChoice) return fail();
    const code = text(row.code, 40), version = text(row.version, 40);
    if (!code || (!row.planelement && !/^[A-ZÆØÅ]{2,8}\d{3,6}[A-Z]?$/.test(code))) return fail();
    const credits = row.credit == null || row.credit === '' ? null : Number(row.credit);
    if (credits !== null && (!Number.isFinite(credits) || credits < 0 || credits > 300)) return fail();
    const name = text(row.name); if (!name) return fail();
    const courseID = intern(catalog.courses, 'c', { code, version, name, credits,
      kind: row.planelement ? 'requirement' : 'course' });
    const choice = { code: text(row.studyChoice.code, 40), name: text(row.studyChoice.name),
      description: text(row.studyChoice.description, 8000) };
    if (!choice.code) return fail();
    return { courseID, choiceID: intern(catalog.choices, 'r', choice) };
  }
  function group(value) {
    if (!value || value.waypoint !== false || !Object.hasOwn(value, 'courses') ||
        !Number.isInteger(Number(value.relperiod)) || Number(value.relperiod) < 1) return fail();
    return intern(catalog.groups, 'g', { code: text(value.code, 120), name: text(value.name),
      description: text(value.description, 20_000), relativePeriod: Number(value.relperiod),
      deadline: text(value.deadlinedate, 100), entries: list(value.courses).map(course) });
  }
  function node(value, depth = 0) {
    if (!value || !Object.hasOwn(value, 'courseGroups') || !Object.hasOwn(value, 'studyWaypoints') ||
        depth > 12 || ++visited > 20_000) return fail();
    const choices = list(value.studyWaypoints).map(waypoint => ({ code: text(waypoint.code, 120),
      name: text(waypoint.name), description: text(waypoint.description, 20_000),
      deadline: text(waypoint.deadlineDate, 100),
      nodeIDs: list(waypoint.studyDirections).map(direction => node(direction, depth + 1)) }));
    return intern(catalog.nodes, 'n', { code: text(value.code, 120), name: text(value.name),
      directionCode: text(value.studyDirection, 120), designation: text(value.studyDirectionDesignationName),
      groupIDs: list(value.courseGroups).map(group), choices });
  }
  for (const { data, programmeCode, admissionYear, studyYears, resourceURL, sha256 } of sources) {
    const value = data?.studyplan;
    if (!value || value.code !== programmeCode || value.year !== admissionYear ||
        !['HØST', 'VÅR'].includes(value.startTerm) || !Number.isInteger(studyYears) || studyYears < 1 || studyYears > 10) return fail();
    const id = `${programmeCode}:${admissionYear}`;
    if (catalog.plans[id]) return fail();
    const seen = new Set();
    const periods = list(value.studyPeriods).map(period => {
      const number = Number(period.periodNumber);
      if (!Number.isInteger(number) || number < 1 || number > studyYears * 2 || seen.has(number)) return fail();
      seen.add(number);
      const autumn = value.startTerm === 'HØST' ? number % 2 === 1 : number % 2 === 0;
      return { number, studyYear: Math.ceil(number / 2), term: autumn ? 'autumn' : 'spring',
        calendarYear: admissionYear + Math.floor((number - (value.startTerm === 'HØST' ? 0 : 1)) / 2),
        nodeID: node(period.direction) };
    }).sort((a, b) => a.number - b.number);
    if (!periods.length || periods[0].number !== 1) return fail();
    if (list(data.publishedYears).some(year => !Number.isInteger(year) || year < 2000 || year > 2100)) return fail();
    catalog.plans[id] = { programmeCode, admissionYear, name: text(value.name), studyYears,
      startTerm: value.startTerm === 'HØST' ? 'autumn' : 'spring',
      sourceURL: `https://www.ntnu.no/studier/studieplan#programmeCode=${programmeCode}&year=${admissionYear}`,
      resourceURL, sourceUpdatedAt: text(value.updated, 100), sha256,
      publishedAcademicYears: list(data.publishedYears), periods };
  }
  return catalog;
}

// Discover the same read-only public resource used by NTNU's study-plan page.
// Never invoke updateCourseCombinations or any authenticated Studentweb route.
export function studyPlanResourceURL(html, kind = 'studyplan') {
  if (!['studyplan', 'yearlist'].includes(kind)) throw new Error('Unexpected NTNU study-plan resource.');
  const match = html.match(new RegExp(`${kind}Url\\s*:\\s*['"]([^'"]+)['"]`));
  if (!match) throw new Error('NTNU study-plan resource was not found.');
  const url = new URL(match[1].replaceAll('&amp;', '&'));
  if (url.origin !== 'https://www.ntnu.no' || url.username || url.password ||
      url.pathname !== '/web/studier/studieplan' || url.searchParams.get('p_p_resource_id') !== kind ||
      url.searchParams.get('p_p_lifecycle') !== '2') throw new Error('Unexpected NTNU study-plan resource.');
  return url;
}
