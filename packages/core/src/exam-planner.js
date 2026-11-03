// The exam planner accepts local, user-provided data only. Importers deliberately
// retain scheduling fields, never complete Studentweb pages or calendar events.
export const MAX_EXAMS = 500;
export const MAX_EXAM_IMPORT_LENGTH = 1_000_000;
export function examToday(now = new Date()) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/Oslo', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(now).map(({ type, value }) => [type, value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}
export function isPastExam(exam, today = examToday()) {
  const lastDay = exam.endDate || exam.date;
  return Boolean(lastDay) && lastDay < today;
}
export const isOralExam = (exam) => /\b(oral|muntlig)\b/i.test(exam.component || '');
const DAY = 24 * 60;
const MONTHS = Object.fromEntries(
  [
    ['januar', 'january', 'jan'],
    ['februar', 'february', 'feb'],
    ['mars', 'march', 'mar'],
    ['april', 'apr'],
    ['mai', 'may'],
    ['juni', 'june', 'jun'],
    ['juli', 'july', 'jul'],
    ['august', 'aug'],
    ['september', 'sep'],
    ['oktober', 'october', 'okt', 'oct'],
    ['november', 'nov'],
    ['desember', 'december', 'des', 'dec'],
  ].flatMap((names, index) => names.map((name) => [name, String(index + 1).padStart(2, '0')]))
);
const CODE = new RegExp(
  `\\b(?!(?:${Object.keys(MONTHS).join('|')}|spring|summer|autumn|winter|fall|vår|høst|semester)[- ]?\\d{3,5}\\b)([A-ZÆØÅ]{2,8})[- ]?(\\d{3,5}[A-Z]?)\\b`,
  'i'
);
const DATE = new RegExp(
  `\\b(\\d{4}-\\d{2}-\\d{2}|\\d{1,2}[./]\\d{1,2}[./]\\d{4}|\\d{1,2}\\.?\\s+(?:${Object.keys(MONTHS).join('|')})\\.?\\s+\\d{4})\\b`,
  'gi'
);
const PRIORITY = { unselected: -1, clear: 0, unknown: 1, possible: 2, collision: 3 };

function field(value, max = 180) {
  return String(value ?? '')
    .replace(/[\u0000-\u001f\u007f]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, max);
}

function validDate(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const [year, month, day] = value.split('-').map(Number);
  if (year < 1900 || year > 2200) return false;
  const date = new Date(Date.UTC(year, month - 1, day));
  return (
    date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day
  );
}

function validTime(value) {
  return /^([01]\d|2[0-3]):[0-5]\d$/.test(value);
}
function dateMinute(value) {
  return Date.parse(`${value}T00:00:00Z`) / 60_000;
}
function timeMinute(value) {
  const [hours, minutes] = value.split(':').map(Number);
  return hours * 60 + minutes;
}
function fingerprint(row) {
  return [
    row.courseCode.toUpperCase() || row.courseName.toLowerCase(),
    row.component.toLowerCase(),
    row.kind,
    row.date,
    row.startTime,
    row.endDate,
    row.endTime,
  ].join('|');
}
function stableId(row) {
  let hash = 2166136261;
  for (const char of fingerprint(row)) hash = Math.imul(hash ^ char.charCodeAt(0), 16777619);
  return `exam-${(hash >>> 0).toString(36)}`;
}

export function normalizeExam(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw))
    throw new Error('Each exam must be an object.');
  if (raw.selected !== undefined && typeof raw.selected !== 'boolean')
    throw new Error('Exam selection must be true or false.');
  if (raw.flexible !== undefined && typeof raw.flexible !== 'boolean')
    throw new Error('Flexible timing must be true or false.');
  if (raw.source !== undefined && !['studentweb', 'manual'].includes(raw.source))
    throw new Error('Exam source must be Studentweb or manual.');
  const row = {
    id: field(raw.id, 100),
    courseCode: field(raw.courseCode, 40)
      .toUpperCase()
      .replace(/[\s-]+/g, ''),
    courseName: field(raw.courseName),
    component: field(raw.component, 120),
    kind: raw.kind || 'other',
    date: field(raw.date, 40),
    startTime: field(raw.startTime, 20),
    endTime: field(raw.endTime, 20),
    endDate: field(raw.endDate, 40),
    selected: raw.selected === true,
    source: raw.source === 'studentweb' ? 'studentweb' : 'manual',
    flexible: raw.flexible ?? isOralExam(raw),
  };
  if (!row.courseCode && !row.courseName)
    throw new Error('Add a course code or course name for each exam.');
  if (!['midterm', 'final', 'other'].includes(row.kind))
    throw new Error('Choose midterm, final, or other as the exam type.');
  if (row.date && !validDate(row.date))
    throw new Error('Use a valid exam date in YYYY-MM-DD format.');
  if (row.endDate && !validDate(row.endDate))
    throw new Error('Use a valid end date in YYYY-MM-DD format.');
  for (const key of ['startTime', 'endTime'])
    if (row[key] && !validTime(row[key]))
      throw new Error('Use a valid time in HH:mm format (00:00–23:59).');
  if (!row.date && (row.endDate || row.startTime || row.endTime))
    throw new Error('Add an exam date before entering times or an end date.');
  if (row.endDate && row.endDate < row.date)
    throw new Error('The end date cannot be before the exam date.');
  if (row.date && row.startTime && row.endTime) {
    const start = dateMinute(row.date) + timeMinute(row.startTime);
    const end = dateMinute(row.endDate || row.date) + timeMinute(row.endTime);
    if (end <= start)
      throw new Error(
        'The exam must end after it starts. For an overnight exam, add its end date.'
      );
  }
  // Equivalent same-day representations must have the same import identity.
  if (row.endDate === row.date) row.endDate = '';
  if (!row.component)
    row.component =
      row.kind === 'midterm' ? 'Midterm' : row.kind === 'final' ? 'Final exam' : 'Exam';
  if (!row.id) row.id = stableId(row);
  return row;
}

export function normalizeExamPlan(rows) {
  if (!Array.isArray(rows)) throw new Error('The exam plan must be a list.');
  if (rows.length > MAX_EXAMS)
    throw new Error(`An exam plan can contain at most ${MAX_EXAMS} exams.`);
  const result = rows.map(normalizeExam);
  const ids = new Set();
  for (const row of result) {
    if (ids.has(row.id)) throw new Error('Each exam must have a unique ID.');
    ids.add(row.id);
  }
  return result;
}

export function mergeExamImports(existing, incoming) {
  const result = normalizeExamPlan(existing);
  if (!Array.isArray(incoming) || incoming.length > MAX_EXAMS)
    throw new Error(`Import at most ${MAX_EXAMS} exams at a time.`);
  const identities = new Set(result.map(fingerprint));
  const ids = new Set(result.map((row) => row.id));
  for (const raw of incoming) {
    const row = normalizeExam(raw);
    const identity = fingerprint(row);
    if (identities.has(identity)) continue;
    identities.add(identity);
    const base = row.id;
    let suffix = 2;
    while (ids.has(row.id)) row.id = `${base}-${suffix++}`;
    ids.add(row.id);
    result.push(row);
  }
  return normalizeExamPlan(result);
}

export function compareExamDates(a, b) {
  return String(a.date || '9999').localeCompare(String(b.date || '9999')) ||
    String(a.startTime || '99:99').localeCompare(String(b.startTime || '99:99')) ||
    String(a.courseCode || a.courseName || '').localeCompare(String(b.courseCode || b.courseName || '')) ||
    String(a.id).localeCompare(String(b.id));
}

export function groupExams(exams) {
  const groups = new Map();
  // Grouping also drives the editor while its fields are incomplete. Validate
  // only when saving or calculating collisions, and retain the draft objects.
  for (const exam of Array.isArray(exams) ? exams : []) {
    const courseCode = field(exam.courseCode, 40)
      .toUpperCase()
      .replace(/[\s-]+/g, '');
    const courseName = field(exam.courseName);
    const key = courseCode || courseName.toLocaleLowerCase() || `draft-${exam.id || groups.size}`;
    if (!groups.has(key)) groups.set(key, { key, courseCode, courseName, exams: [] });
    const group = groups.get(key);
    if (!group.courseName) group.courseName = exam.courseName;
    group.exams.push(exam);
  }
  for (const group of groups.values())
    group.exams.sort(compareExamDates);
  return [...groups.values()].sort((a, b) => a.key.localeCompare(b.key));
}

function examWindow(row) {
  if (!row.date) return null;
  const start = dateMinute(row.date) + (row.startTime ? timeMinute(row.startTime) : 0);
  const end = dateMinute(row.endDate || row.date) + (row.endTime ? timeMinute(row.endTime) : DAY);
  return { start, end, certain: Boolean(row.startTime && row.endTime) };
}

export function analyzeExamCollisions(exams) {
  const rows = normalizeExamPlan(exams);
  const windows = new Map(rows.map((row) => [row.id, row.flexible ? null : examWindow(row)]));
  const byId = Object.create(null);
  const collisions = [];
  const summary = { selected: 0, collision: 0, possible: 0, unknown: 0, clear: 0, flexible: 0 };
  for (const row of rows) {
    const window = windows.get(row.id);
    byId[row.id] = {
      status: !row.selected ? 'unselected' : row.flexible ? 'flexible' : !window?.certain ? 'unknown' : 'clear',
      conflicts: [],
    };
  }
  const selected = rows.filter((row) => row.selected);
  for (let i = 0; i < selected.length; i++) {
    const first = selected[i];
    if (first.flexible) continue;
    const a = windows.get(first.id);
    if (!a) continue;
    for (let j = i + 1; j < selected.length; j++) {
      const second = selected[j];
      if (second.flexible) continue;
      const b = windows.get(second.id);
      if (!b || a.start >= b.end || b.start >= a.end) continue;
      const status = a.certain && b.certain ? 'collision' : 'possible';
      collisions.push({ firstId: first.id, secondId: second.id, status });
      for (const [row, other] of [
        [first, second],
        [second, first],
      ]) {
        const entry = byId[row.id];
        if (PRIORITY[status] > PRIORITY[entry.status]) entry.status = status;
        entry.conflicts.push({ id: other.id, status });
      }
    }
  }
  summary.selected = selected.length;
  for (const row of selected) summary[byId[row.id].status]++;
  return { byId, collisions, summary };
}

// Canvas appends semester suffixes to course codes; compare the actual code.
export function examCourseKey(course) {
  const code = String(course.code ?? course.courseCode ?? '')
    .replace(/-(?:\d{2}[HV])(?:-\d{2}[HV])*$/i, '')
    .toUpperCase()
    .replace(/[\s-]+/g, '');
  return (
    code ||
    String(course.name ?? course.courseName ?? '')
      .trim()
      .toLowerCase()
  );
}

export function examFavoriteCourseIDs(exams, courses) {
  const { byId } = analyzeExamCollisions(exams);
  const ready = new Set(
    groupExams(exams)
      .filter((group) => {
        const selected = group.exams.filter((exam) => exam.selected);
        return selected.length && selected.every((exam) => ['clear', 'flexible'].includes(byId[exam.id].status));
      })
      .map((group) => examCourseKey(group))
  );
  return courses.filter((course) => ready.has(examCourseKey(course))).map((course) => course.id);
}

export function examFocusCourses(exams, courses, today = examToday()) {
  const ready = new Set(examFavoriteCourseIDs(exams, courses));
  const next = new Map();
  for (const exam of [...exams].filter((exam) => exam.selected && !isPastExam(exam, today)).sort(compareExamDates)) {
    const key = examCourseKey(exam);
    if (!next.has(key)) next.set(key, exam);
  }
  return courses.filter((course) => ready.has(course.id) && next.has(examCourseKey(course)))
    .sort((a, b) => compareExamDates(next.get(examCourseKey(a)), next.get(examCourseKey(b))));
}

// Resolve one pair explicitly. Keep a course's components together when setting
// it aside; a collision within one course only sets aside the opposing exam.
export function resolveExamConflict(exams, keepId, dropId) {
  const rows = normalizeExamPlan(exams);
  const analysis = analyzeExamCollisions(rows);
  if (!analysis.byId[keepId]?.conflicts.some((peer) => peer.id === dropId))
    throw new Error('This pair no longer conflicts. Review the updated schedule.');
  const keep = rows.find((exam) => exam.id === keepId);
  const drop = rows.find((exam) => exam.id === dropId);
  const sameCourse = examCourseKey(keep) === examCourseKey(drop);
  return rows.map((exam) => ({
    ...exam,
    selected:
      exam.selected &&
      !(sameCourse ? exam.id === dropId : examCourseKey(exam) === examCourseKey(drop)),
  }));
}

export function setExamFlexibleTiming(exams, id, flexible) {
  const rows = normalizeExamPlan(exams);
  if (typeof flexible !== 'boolean') throw new Error('Flexible timing must be true or false.');
  const exam = rows.find((row) => row.id === id);
  if (!exam) throw new Error('This exam is no longer in your plan. Review the updated schedule.');
  exam.flexible = flexible;
  return rows;
}

function importDate(value) {
  const text = field(value, 60);
  let match;
  if ((match = text.match(/^(\d{1,2})[./](\d{1,2})[./](\d{4})$/)))
    return `${match[3]}-${match[2].padStart(2, '0')}-${match[1].padStart(2, '0')}`;
  if (
    (match = text.toLowerCase().match(/^(\d{1,2})\.?\s+([a-z]+)\.?\s+(\d{4})$/)) &&
    MONTHS[match[2]]
  )
    return `${match[3]}-${MONTHS[match[2]]}-${match[1].padStart(2, '0')}`;
  return text;
}
function importTime(value) {
  const match = field(value, 30).match(/^(\d{1,2})[:.](\d{2})(?::00)?$/);
  return match ? `${match[1].padStart(2, '0')}:${match[2]}` : field(value, 30);
}
function examKind(value) {
  if (/\b(midterm|midtsemester|midtveis|deleksamen)\b/i.test(value)) return 'midterm';
  if (
    /\b(final|slutteksamen|skoleeksamen|skriftlig|muntlig|oral|written|hjemmeeksamen|home exam)\b/i.test(
      value
    )
  )
    return 'final';
  return 'other';
}
function privateFree(value) {
  return field(value)
    .replace(/\b[^\s@]+@[^\s@]+\.[^\s@]+\b/g, '')
    .replace(/\b\d{6,}\b/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}
function courseFrom(value) {
  const match = String(value).match(CODE);
  return match ? `${match[1]}${match[2]}`.toUpperCase() : '';
}
function importedRow(row) {
  return normalizeExam({
    ...row,
    courseName: privateFree(row.courseName),
    component: privateFree(row.component),
    source: 'studentweb',
    selected: false,
  });
}

function applyDuration(row, minutes) {
  if (!Number.isFinite(minutes) || minutes <= 0 || minutes > 366 * DAY)
    throw new Error('Use a positive exam duration of at most 366 days.');
  if (!row.date || !row.startTime || row.endTime) return;
  const end = new Date(
    (dateMinute(row.date) + timeMinute(row.startTime) + minutes) * 60_000
  ).toISOString();
  row.endDate = end.slice(0, 10);
  row.endTime = end.slice(11, 16);
}

function durationMinutes(value) {
  const hours = value.match(/(\d+(?:[.,]\d+)?)\s*(?:hours?|hrs?|timer?|timar|h)\b/i);
  const minutes = value.match(/(\d+)\s*(?:minutes?|mins?|minutter?|minutt|min)\b/i);
  return hours || minutes
    ? Number((hours?.[1] || '0').replace(',', '.')) * 60 + Number(minutes?.[1] || 0)
    : null;
}

const HEADER_NAMES = {
  courseCode: ['coursecode', 'course', 'emnekode', 'emne', 'kode', 'subjectcode'],
  courseName: ['coursename', 'emnenavn', 'name', 'navn', 'subjectname'],
  component: [
    'component',
    'exam',
    'examtype',
    'assessment',
    'vurdering',
    'vurderingsform',
    'vurderingsdel',
    'eksamen',
    'eksamenstype',
  ],
  kind: ['kind', 'type'],
  date: ['date', 'examdate', 'dato', 'eksamensdato', 'startdate', 'startdato'],
  startTime: ['starttime', 'starttid', 'start', 'time', 'tid', 'klokkeslett'],
  endTime: ['endtime', 'sluttid', 'slutttid', 'slutt', 'end'],
  endDate: ['enddate', 'sluttdato'],
  duration: ['duration', 'varighet', 'lengde'],
};
const headerKey = (value) =>
  field(value)
    .toLowerCase()
    .replace(/[^a-zæøå]/g, '');

function csvRows(text, delimiter) {
  const rows = [];
  let row = [],
    cell = '',
    quoted = false;
  for (let i = 0; i < text.length; i++) {
    const char = text[i];
    if (char === '"') {
      if (quoted && text[i + 1] === '"') {
        cell += '"';
        i++;
      } else quoted = !quoted;
    } else if (char === delimiter && !quoted) {
      row.push(cell);
      cell = '';
    } else if ((char === '\n' || char === '\r') && !quoted) {
      if (char === '\r' && text[i + 1] === '\n') i++;
      row.push(cell);
      if (row.some((value) => value.trim())) rows.push(row);
      row = [];
      cell = '';
    } else cell += char;
  }
  if (quoted) throw new Error('The CSV contains an unclosed quoted field.');
  row.push(cell);
  if (row.some((value) => value.trim())) rows.push(row);
  return rows;
}

function parseCsv(text, warnings) {
  const first = text.split(/\r?\n/, 1)[0];
  const delimiter = ['\t', ';', ','].sort(
    (a, b) => first.split(b).length - first.split(a).length
  )[0];
  const rows = csvRows(text, delimiter);
  if (!rows.length) return [];
  const headers = rows
    .shift()
    .map(
      (value) =>
        Object.keys(HEADER_NAMES).find((key) => HEADER_NAMES[key].includes(headerKey(value))) || ''
    );
  if (!headers.includes('courseCode') && !headers.includes('courseName'))
    throw new Error('The CSV needs a course code or course name column.');
  const exams = [];
  for (const [index, values] of rows.entries()) {
    const row = {};
    headers.forEach((key, i) => {
      if (key) row[key] = values[i] || '';
    });
    row.date = importDate(row.date);
    row.endDate = importDate(row.endDate);
    row.startTime = importTime(row.startTime);
    row.endTime = importTime(row.endTime);
    const range = row.startTime.match(/^(\d{1,2}[:.]\d{2})\s*[-–—]\s*(\d{1,2}[:.]\d{2})$/);
    if (range) {
      row.startTime = importTime(range[1]);
      row.endTime = row.endTime || importTime(range[2]);
    }
    row.kind = ['midterm', 'final', 'other'].includes(row.kind)
      ? row.kind
      : examKind(`${row.kind || ''} ${row.component || ''}`);
    if (row.courseCode) {
      const code = courseFrom(row.courseCode);
      if (code) {
        row.courseName ||= field(row.courseCode)
          .replace(CODE, '')
          .replace(/^\s*[-:–]\s*/, '')
          .trim();
        row.courseCode = code;
      }
    }
    try {
      if (row.duration) {
        const minutes = durationMinutes(row.duration);
        if (minutes !== null) applyDuration(row, minutes);
        else
          warnings.push(`Row ${index + 2}: check the end time; the duration was not recognized.`);
      }
      exams.push(importedRow(row));
    } catch (error) {
      warnings.push(`Row ${index + 2}: ${error.message}`);
    }
  }
  return exams;
}

function icsValue(value) {
  return value.replace(/\\[nN]/g, ' ').replace(/\\([,;\\])/g, '$1');
}
function calendarDate(value, parameters) {
  if (/^\d{8}$/.test(value)) {
    const date = `${value.slice(0, 4)}-${value.slice(4, 6)}-${value.slice(6, 8)}`;
    if (!validDate(date)) throw new Error('Invalid calendar date.');
    return { date, time: '', allDay: true };
  }
  const match = value.match(/^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?(Z)?$/);
  if (!match) throw new Error('Unsupported calendar date or time.');
  const date = `${match[1]}-${match[2]}-${match[3]}`,
    time = `${match[4]}:${match[5]}`;
  if (!validDate(date) || !validTime(time) || Number(match[6] || 0) > 59)
    throw new Error('Invalid calendar date or time.');
  const zone = parameters.match(/(?:^|;)TZID=(?:"([^"]+)"|([^;]+))/i);
  const timezone = match[7] ? 'UTC' : zone ? zone[1] || zone[2] : 'Europe/Oslo';
  // Resolve an IANA-zoned wall time to an instant, then display it in Oslo.
  const partsFor = (instant, timeZone) =>
    Object.fromEntries(
      new Intl.DateTimeFormat('en-GB', {
        timeZone,
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit',
        hourCycle: 'h23',
      })
        .formatToParts(new Date(instant))
        .map((part) => [part.type, part.value])
    );
  const desired = Date.UTC(
    +match[1],
    +match[2] - 1,
    +match[3],
    +match[4],
    +match[5],
    +(match[6] || 0)
  );
  let instant = desired;
  if (timezone !== 'UTC') {
    for (let i = 0; i < 3; i++) {
      const p = partsFor(instant, timezone);
      const shown = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +p.second);
      const correction = desired - shown;
      instant += correction;
      if (!correction) break;
    }
    const p = partsFor(instant, timezone);
    if (`${p.year}-${p.month}-${p.day}` !== date || `${p.hour}:${p.minute}` !== time)
      throw new Error('This calendar time falls in a daylight-saving gap.');
  }
  const local = partsFor(instant, 'Europe/Oslo');
  return {
    date: `${local.year}-${local.month}-${local.day}`,
    time: `${local.hour}:${local.minute}`,
    allDay: false,
    instant,
  };
}

function parseIcs(text, warnings) {
  const lines = text.replace(/\r?\n[ \t]/g, '').split(/\r?\n/);
  const exams = [];
  let event = null,
    nested = 0,
    count = 0;
  for (const line of lines) {
    if (/^BEGIN:VEVENT$/i.test(line)) {
      event = {};
      nested = 0;
      count++;
      continue;
    }
    if (!event) continue;
    if (/^END:VEVENT$/i.test(line)) {
      try {
        if (event.STATUS?.value === 'CANCELLED') {
          warnings.push(`Calendar event ${count} is cancelled and was skipped.`);
          event = null;
          continue;
        }
        const title = icsValue(event.SUMMARY?.value || '');
        const courseCode = courseFrom(title);
        if (!courseCode) {
          warnings.push(`Calendar event ${count} has no recognizable course code and was skipped.`);
          event = null;
          continue;
        }
        if (event.RRULE || event.RDATE)
          throw new Error(
            'Recurring events are unsupported; enter the intended exam dates individually.'
          );
        const start = event.DTSTART
          ? calendarDate(event.DTSTART.value, event.DTSTART.parameters)
          : null;
        if (!start) throw new Error('Missing calendar start date.');
        const end = event.DTEND ? calendarDate(event.DTEND.value, event.DTEND.parameters) : null;
        if (end && start.allDay !== end.allDay)
          throw new Error('Calendar start and end use different date formats.');
        let endDate = end?.date || '';
        if (end?.allDay)
          endDate = new Date(Date.parse(`${end.date}T00:00:00Z`) - 86_400_000)
            .toISOString()
            .slice(0, 10);
        const kind = examKind(title);
        const row = {
          courseCode,
          courseName: title
            .replace(CODE, '')
            .replace(/^\s*[-:–]\s*/, '')
            .trim(),
          component: kind === 'midterm' ? 'Midterm' : kind === 'final' ? 'Final exam' : 'Exam',
          kind,
          date: start.date,
          startTime: start.time,
          endTime: end?.time || '',
          endDate,
        };
        if (!end && event.DURATION) {
          const duration = event.DURATION.value.match(/^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?)?$/);
          if (duration && start.time) {
            const minutes =
              Number(duration[1] || 0) * DAY +
              Number(duration[2] || 0) * 60 +
              Number(duration[3] || 0);
            applyDuration(row, minutes);
            const stamp = new Date(start.instant + minutes * 60_000)
              .toISOString()
              .replace(/[-:]/g, '')
              .replace(/\.\d{3}Z$/, 'Z');
            const finish = calendarDate(stamp, '');
            row.endDate = finish.date;
            row.endTime = finish.time;
          } else
            warnings.push(
              `Calendar event ${count}: duration was not imported; check the end time.`
            );
        }
        exams.push(importedRow(row));
      } catch (error) {
        warnings.push(`Calendar event ${count}: ${error.message}`);
      }
      event = null;
      continue;
    }
    if (/^BEGIN:/i.test(line)) {
      nested++;
      continue;
    }
    if (/^END:/i.test(line)) {
      nested = Math.max(0, nested - 1);
      continue;
    }
    if (nested) continue;
    const match = line.match(/^([A-Z]+)((?:;[^:]*)?):(.*)$/i);
    if (
      match &&
      ['SUMMARY', 'DTSTART', 'DTEND', 'STATUS', 'RRULE', 'RDATE', 'DURATION'].includes(
        match[1].toUpperCase()
      )
    )
      event[match[1].toUpperCase()] = { parameters: match[2], value: match[3] };
  }
  if (event) warnings.push('An incomplete calendar event was skipped.');
  return exams;
}

function parseText(text, warnings) {
  const lines = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
  const exams = [];
  let context = null,
    current = null,
    pendingComponent = '';
  const finish = () => {
    if (!current) return;
    try {
      exams.push(importedRow(current));
    } catch (error) {
      warnings.push(`Exam ${exams.length + 1}: ${error.message}`);
    }
    current = null;
  };
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    // Drop non-schedule personal/account lines before extracting anything.
    if (
      /^(student(?:nummer|\s*(?:name|id))?|fødsels(?:nummer|dato)|fodsels|personnummer|candidate|kandidat(?:nummer)?|e-?mail|e-?post|adresse|address|telefon|phone|navn)\s*[:\t]/i.test(
        line
      )
    )
      continue;
    const courseCode = courseFrom(line);
    const matches = [...line.matchAll(DATE)];
    if (courseCode) {
      finish();
      const match = line.match(CODE);
      let courseName = line
        .slice(match.index + match[0].length)
        .replace(/^\s*[-:–]\s*/, '')
        .split(/\t|\s{2,}|\b(?:Dato|Date|Tid|Time|Vurdering|Assessment|Eksamen|Exam)\s*:/i)[0]
        .trim();
      courseName = courseName.split(DATE)[0].replace(/[\s|;,–-]+$/, '');
      context = { courseCode, courseName: privateFree(courseName) };
      pendingComponent = '';
    }
    if (!context) continue;
    const componentLabel = line.match(
      /^(?:vurdering(?:s(?:form|del))?|eksamenstype|exam\s*type|assessment|component)\s*:\s*(.+)$/i
    );
    const kind = examKind(line);
    if (componentLabel || kind !== 'other') {
      const component = componentLabel
        ? componentLabel[1].split(DATE)[0].trim()
        : kind === 'midterm'
          ? 'Midterm'
          : /\b(oral|muntlig)\b/i.test(line)
            ? 'Oral exam'
          : 'Final exam';
      pendingComponent = privateFree(component);
      if (current && !current.component) {
        current.component = pendingComponent;
        current.kind = kind;
      }
    }
    // Import scheduling-labelled dates or dates adjacent to an exam heading.
    if (matches.length) {
      if (
        /\b(\w*frist|deadline|registration|oppmelding|avmelding|publisert|published|semesterstart|birth|birthday|fødsels\w*|sensur\w*|results?)\b/i.test(
          line
        )
      )
        continue;
      const previous = lines[index - 1] || '';
      const labelled = /\b(?:eksamensdato|exam date|dato|date)\s*:?\s*\d/i.test(line);
      const dateOnly = line.replace(DATE, '').replace(/[\s–—\-/]|\b(?:til|to)\b/g, '') === '';
      const adjacentLabel =
        /^(?:eksamensdato|exam date|dato|date)\s*:?$/i.test(previous) ||
        examKind(previous) !== 'other' ||
        Boolean(courseFrom(previous));
      if (!courseCode && !labelled && kind === 'other' && !(dateOnly && adjacentLabel)) continue;
      finish();
      current = {
        ...context,
        component: pendingComponent,
        kind: examKind(pendingComponent),
        date: importDate(matches[0][0]),
        startTime: '',
        endTime: '',
        endDate: '',
      };
      if (
        matches.length > 1 &&
        /[-–—]|\b(?:til|to)\b/.test(
          line.slice(matches[0].index + matches[0][0].length, matches[1].index)
        )
      )
        current.endDate = importDate(matches[1][0]);
    }
    if (current) {
      const withoutDates = line.replace(DATE, '');
      const times = [...withoutDates.matchAll(/\b(\d{1,2})[:.](\d{2})\b/g)].map(
        (match) => `${match[1].padStart(2, '0')}:${match[2]}`
      );
      if (times.length) {
        if (/\b(end|slutt(?:id|tid)?)\b/i.test(withoutDates) && times.length === 1)
          current.endTime = times[0];
        else {
          current.startTime = times[0];
          if (times[1]) current.endTime = times[1];
        }
      }
      if (
        /\b(varighet|duration)\b/i.test(line) ||
        /^\d+(?:[.,]\d+)?\s*(?:hours?|hrs?|timer?|h|min)/i.test(line)
      ) {
        const minutes = durationMinutes(line);
        if (minutes !== null) {
          try {
            applyDuration(current, minutes);
          } catch (error) {
            warnings.push(`Exam duration: ${error.message}`);
          }
        }
      }
    }
  }
  finish();
  if (exams.length)
    warnings.push(
      'Copied text can be ambiguous. Check every course, assessment, date and time against Studentweb before adding it.'
    );
  return exams;
}

export function parseExamImport(input, format = 'auto') {
  if (typeof input !== 'string')
    throw new Error('Paste exam text or choose a text, CSV, or ICS file.');
  if (input.length > MAX_EXAM_IMPORT_LENGTH)
    throw new Error('This import is too large. Use a file or selection smaller than 1 MB.');
  const text = input
    .replace(/^\uFEFF/, '')
    .replace(/\u0000/g, '')
    .trim();
  if (!text) return { exams: [], warnings: ['No exam data was provided.'] };
  if (!['auto', 'text', 'csv', 'ics'].includes(format))
    throw new Error('Choose text, CSV, or ICS format.');
  const warnings = [];
  const first = text.split(/\r?\n/, 1)[0];
  const tabularHeader = first
    .split(/[\t;,]/)
    .some(
      (value) =>
        HEADER_NAMES.courseCode.includes(headerKey(value)) ||
        HEADER_NAMES.courseName.includes(headerKey(value))
    );
  const detected =
    format === 'auto'
      ? /BEGIN:VCALENDAR|BEGIN:VEVENT/i.test(text)
        ? 'ics'
        : tabularHeader && /[\t;,]/.test(first)
          ? 'csv'
          : 'text'
      : format;
  const imported =
    detected === 'ics'
      ? parseIcs(text, warnings)
      : detected === 'csv'
        ? parseCsv(text, warnings)
        : parseText(text, warnings);
  if (imported.length > MAX_EXAMS) throw new Error(`Import at most ${MAX_EXAMS} exams at a time.`);
  const exams = mergeExamImports([], imported);
  if (exams.length < imported.length) warnings.push('Duplicate exam entries were combined.');
  if (!exams.length)
    warnings.push(
      'No exams were recognized. Paste course codes with full exam dates, use a CSV with named columns, or add exams manually.'
    );
  if (exams.some((exam) => !exam.date || !exam.startTime || !exam.endTime))
    warnings.push(
      'Some exams have incomplete dates or times. Their overlap status cannot be confirmed until those details are entered.'
    );
  return { exams, warnings: [...new Set(warnings)].slice(0, 30) };
}
