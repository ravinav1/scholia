import { readFile } from 'node:fs/promises';
import { contentPollAttempt, newContentPollingModel, observeContentPoll } from '../../packages/core/src/content-polling.js';
export const pollingFixtures = JSON.parse(await readFile(new URL('../fixtures/content-polling.json', import.meta.url)));
export function trainedPollingModel(fixture = pollingFixtures.daily, interval = 300, timeZone = 'UTC') {
  const model = newContentPollingModel(timeZone), start = Date.parse(fixture.start) / 1000;
  let revision = 0;
  const observe = (time) => observeContentPoll(model, { time, signature: String(revision), complete: true, interval });
  for (let day = 0; day < fixture.days; day++) {
    const date = start + day * 86400;
    for (let offset = 8 * 3600; offset <= 18 * 3600; offset += interval) {
      if (offset === 12.5 * 3600 && fixture.weekdays.includes(new Date(date * 1000).getUTCDay())) revision++;
      observe(date + offset);
    }
  }
  const time = Date.parse(fixture.predict) / 1000;
  observe(time);
  contentPollAttempt(model, time, 'regular');
  return { model, time };
}
