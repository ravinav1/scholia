import { readFile, writeFile, rename, rm } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { normalizeStudyPlans, studyPlanResourceURL } from './lib/ntnu-study-plans.mjs';

const directory = new URL('../packages/core/data/', import.meta.url);
const config = JSON.parse(await readFile(new URL('ntnu-study-plan-sources.json', directory), 'utf8'));
if (!Array.isArray(config.programmes) || !config.programmes.length || config.programmes.length > 8 ||
    config.programmes.some(p => !/^[A-Z0-9]{2,20}$/.test(p.programmeCode) ||
      p.admissionYears !== 'published' || !Number.isInteger(p.defaultAdmissionYear) ||
      p.defaultAdmissionYear < 2000 || p.defaultAdmissionYear > 2100 ||
      !Number.isInteger(p.studyYears) || p.studyYears < 1 || p.studyYears > 10)) throw new Error('Invalid programme source configuration.');

async function get(url) {
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const response = await fetch(url, { method: 'GET', redirect: 'error', credentials: 'omit',
        headers: { Accept: 'application/json,text/html', 'User-Agent': 'Scholia public study-plan import' },
        signal: AbortSignal.timeout(45_000) });
      if (!response.ok) throw new Error(`NTNU returned HTTP ${response.status}.`);
      const chunks = []; let size = 0;
      for await (const chunk of response.body) {
        size += chunk.length;
        if (size > 4_000_000) { await response.body.cancel().catch(() => {}); throw new Error('Study plan is too large.'); }
        chunks.push(chunk);
      }
      return Buffer.concat(chunks);
    } catch (error) { if (attempt === 1) throw error; }
  }
}
const html = (await get('https://www.ntnu.no/studier/studieplan')).toString('utf8');
const resource = studyPlanResourceURL(html), yearsResource = studyPlanResourceURL(html, 'yearlist');
const programmes = [];
for (const programme of config.programmes) {
  const url = new URL(yearsResource); url.searchParams.set('code', programme.programmeCode);
  const data = JSON.parse((await get(url)).toString('utf8'));
  if (!Array.isArray(data.yearList) || !data.yearList.length || data.yearList.length > 50 ||
      data.yearList.some(year => typeof year !== 'string' || !/^20\d{2}$/.test(year)) ||
      new Set(data.yearList).size !== data.yearList.length || !data.yearList.includes(String(programme.defaultAdmissionYear)))
    throw new Error(`Unsupported admission-year list for ${programme.programmeCode}.`);
  programmes.push(...data.yearList.map(year => ({ ...programme, admissionYear: Number(year) })));
}
if (programmes.length > 200) throw new Error('Too many admission-year plans.');
const sources = [];
for (let i = 0; i < programmes.length; i += 2) {
  const batch = await Promise.all(programmes.slice(i, i + 2).map(async programme => {
    const url = new URL(resource);
    url.searchParams.set('code', programme.programmeCode);
    url.searchParams.set('year', programme.admissionYear);
    const raw = await get(url);
    return { ...programme, resourceURL: url.href, data: JSON.parse(raw.toString('utf8')),
      sha256: createHash('sha256').update(raw).digest('hex') };
  }));
  sources.push(...batch);
}
const catalog = normalizeStudyPlans(sources, new Date().toISOString());
catalog.defaultAdmissionYears = Object.fromEntries(config.programmes.map(p => [p.programmeCode, p.defaultAdmissionYear]));
const destination = new URL('ntnu-study-plans.json', directory);
const temporary = new URL(`ntnu-study-plans.${process.pid}.tmp`, directory);
try {
  await writeFile(temporary, JSON.stringify(catalog, null, 2) + '\n', { flag: 'wx' });
  await rename(temporary, destination);
} finally { await rm(temporary, { force: true }); }
for (const plan of Object.values(catalog.plans)) {
  console.log(`${plan.programmeCode} ${plan.admissionYear}: ${plan.periods.length}/${plan.studyYears * 2} published semesters, all branches imported.`);
}
console.log(`${Object.keys(catalog.courses).length} unique course/requirement definitions; ${Object.keys(catalog.groups).length} distinct course groups.`);
