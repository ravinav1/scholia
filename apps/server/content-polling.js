import { createHash } from 'node:crypto';
import { contentPollAttempt, contentPollDecision, contentPollSnapshot, newContentPollingModel, observeContentPoll } from '../../packages/core/src/content-polling.js';
import { mathWikiCourse } from './math-wiki.js';

export const pollingInterval = source => source === 'mathWiki' ? 120 : 300;
export const pollingModel = (course, source) => course[`${source}Polling`] ||= newContentPollingModel(
  course.canvasOrigin?.includes('ntnu.no') ? 'Europe/Oslo' : Intl.DateTimeFormat().resolvedOptions().timeZone);
export const workspaceExtras = account => account.library.courses.flatMap(c => [
  ...(c.canvasPolling?.extraChecks || []), ...(c.mathWikiPolling?.extraChecks || []),
]);
export function pollDecision(account, course, source, time) {
  return contentPollDecision(pollingModel(course, source), { time: time / 1000,
    interval: pollingInterval(source), workspaceExtras: workspaceExtras(account),
    lastRegular: course[source === 'mathWiki' ? 'mathWikiUpdateAttemptedAt' : 'contentUpdateAttemptedAt'] });
}
export function beginPoll(course, source, time, reason) {
  contentPollAttempt(pollingModel(course, source), time / 1000, reason);
  if (reason === 'regular') course[source === 'mathWiki' ? 'mathWikiUpdateAttemptedAt' : 'contentUpdateAttemptedAt'] = time / 1000;
}
export function observePoll(course, source, items, complete, time) {
  const signature = createHash('sha256').update(contentPollSnapshot(items, source)).digest('hex');
  observeContentPoll(pollingModel(course, source), { time: time / 1000, signature, complete, interval: pollingInterval(source) });
}
export function observeCatalog(course, catalog, time, includePublic = true) {
  observePoll(course, 'canvas', catalog.items, catalog.canvasComplete, time);
  if (includePublic && mathWikiCourse(course)?.terms.length) {
    beginPoll(course, 'mathWiki', time, 'regular');
    observePoll(course, 'mathWiki', catalog.items, catalog.mathWikiComplete, time);
  }
}
