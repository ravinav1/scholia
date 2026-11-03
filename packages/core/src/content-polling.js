// Online Gamma–Poisson model: changes per observed hour, by hour of the week.
// Exposure (rather than number of polls) prevents extra checks from training
// themselves into an increasingly aggressive schedule. All times are Unix seconds.
const hour = 3600, day = 24 * hour, halfLife = 28 * day;
export const contentPollingLimits = Object.freeze({ perSource: 2, perWorkspace: 8, cooldown: hour });
const formatters = new Map();
function slot(time, timeZone) {
  let formatter = formatters.get(timeZone);
  if (!formatter) {
    formatter = new Intl.DateTimeFormat('en-GB', { timeZone, weekday: 'short', hour: '2-digit', hourCycle: 'h23' });
    formatters.set(timeZone, formatter);
  }
  const parts = Object.fromEntries(formatter.formatToParts(new Date(time * 1000)).map(p => [p.type, p.value]));
  return ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(parts.weekday) * 24 + Number(parts.hour);
}
export function newContentPollingModel(timeZone = 'Europe/Oslo') {
  return { version: 1, timeZone, bins: {}, failures: 0, extraChecks: [] };
}
export function recentExtraChecks(model, time) {
  // Retain future entries too: moving the clock backwards must not refill a budget.
  return (model?.extraChecks || []).filter(t => t > time - day);
}
export function contentPollAttempt(model, time, reason) {
  model.attemptedAt = time;
  model.extraChecks = recentExtraChecks(model, time);
  if (reason === 'predicted') model.extraChecks.push(time);
}
export function observeContentPoll(model, { time, signature, complete, interval }) {
  if (!complete) {
    model.failures = Math.min(10, (model.failures || 0) + 1);
    model.retryAfter = time + Math.min(hour, interval * 2 ** (model.failures - 1));
    delete model.observedAt;
    delete model.signature;
    return;
  }
  const elapsed = time - (model.observedAt ?? time);
  const decay = 2 ** (-Math.max(0, time - (model.updatedAt ?? time)) / halfLife);
  for (const bin of Object.values(model.bins)) {
    bin.hours *= decay;
    bin.events *= decay;
    bin.days = bin.days.filter(t => t > time - 84 * day);
  }
  // A first import, an offline gap or a partial catalog cannot date a change.
  if (model.signature != null && elapsed > 0 && elapsed <= 30 * 60) {
    const changed = signature !== model.signature;
    for (let start = model.observedAt; start < time;) {
      const end = Math.min(time, (Math.floor(start / 60) + 1) * 60);
      const middle = (start + end) / 2;
      const bin = model.bins[slot(middle, model.timeZone)] ||= { hours: 0, events: 0, days: [] };
      bin.hours += (end - start) / hour;
      if (changed) {
        // Spread an interval-censored event across the interval it was observed in.
        bin.events += (end - start) / elapsed;
        const date = Math.floor(middle / day) * day;
        if (!bin.days.includes(date)) bin.days.push(date);
        bin.days = bin.days.slice(-8);
      }
      start = end;
    }
  }
  model.updatedAt = model.observedAt = time;
  model.signature = signature;
  model.failures = 0;
  delete model.retryAfter;
}
export function contentPollRate(model, time) {
  if (!model || model.signature == null || time - model.observedAt > 30 * 60 || time < model.observedAt) return 0;
  const current = slot(time, model.timeZone);
  const decay = 2 ** (-Math.max(0, time - (model.updatedAt ?? time)) / halfLife);
  const aggregate = predicate => {
    let hours = 0, events = 0;
    const days = new Set();
    for (const [index, bin] of Object.entries(model.bins)) if (predicate(Number(index))) {
      hours += bin.hours * decay; events += bin.events * decay;
      for (const date of bin.days) if (date > time - 84 * day) days.add(date);
    }
    // Weak Gamma prior: 0.1 events in two hours. No cold-start speculation.
    return { hours, days: days.size, rate: (events + 0.1) / (hours + 2) };
  };
  const baseline = aggregate(() => true);
  if (baseline.hours < 8) return 0;
  const daily = aggregate(i => i % 24 === current % 24), weekly = aggregate(i => i === current);
  return Math.max(0, ...[daily, weekly]
    .filter(b => b.days >= 3 && b.hours >= 1 && b.rate >= 0.5 && b.rate >= baseline.rate * 3)
    .map(b => b.rate));
}
export function contentPollDecision(model, { time, interval, lastRegular, workspaceExtras = [] }) {
  if (time < (model?.retryAfter || 0) || time - (model?.attemptedAt ?? -Infinity) < interval / 2) return null;
  if (time - (lastRegular ?? -Infinity) >= interval) return 'regular';
  const extras = recentExtraChecks(model, time);
  if (extras.length >= contentPollingLimits.perSource ||
      workspaceExtras.filter(t => t > time - day).length >= contentPollingLimits.perWorkspace ||
      extras.some(t => time - t < contentPollingLimits.cooldown) ||
      lastRegular + interval - time < 30) return null;
  return contentPollRate(model, time) > 0 ? 'predicted' : null;
}

// Exclude student grades/submissions, source ordering and synthetic cache-bust
// versions. They aren't evidence that teaching material has been published.
export function contentPollSnapshot(items, source) {
  return JSON.stringify(items.filter(ref => source === 'mathWiki' ? ref.id.startsWith('math-wiki:')
    : !ref.id.startsWith('math-wiki:') && !ref.id.startsWith('course-web:'))
    .map(ref => [ref.id, ref.title || '', ref.fileName || '',
      ref.version?.startsWith('unvalidated:') ? '' : ref.version || '', ref.byteCount == null ? '' : String(ref.byteCount)])
    .sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
}
