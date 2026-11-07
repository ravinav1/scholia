# Web responsiveness implementation

## Baseline
Measured original checkout `92a8e16` in actual headless Chromium on this Mac, using production-minified assets and isolated real hosted service/accounts. Script: `scripts/performance/benchmark-web-responsiveness.mjs`. Raw results: `results/performance/web-before.json`; screenshots alongside. Three transition warmups, four filter warmups, 25 samples. Measurements end after the rendered destination and two animation frames; they include a conservative paint opportunity, not merely handler or service time.

| Workspaces | Documents | Assignments | Reader → dashboard p95 | Filter p95 |
| --- | ---: | ---: | ---: | ---: |
| 6 | 144 | 72 | 49.5 ms | 33.4 ms |
| 89 | 2,136 | 1,068 | 250.0 ms | 34.2 ms |
| 500 | 12,000 | 6,000 | 1,474.8 ms | 88.3 ms |

Fixture limitations are explicit in raw results: metadata has many documents, but only one is actually indexed/readable; each workspace has 80 stored messages and a retained attachment draft. This isolates catalog/projection/render costs. It does not measure concurrent real extraction or large-PDF rendering; those need separate transfer and reader smokes.

## Focused stage
- Retain the dashboard DOM across reader returns, with independent keys for workspace cards, assignments, exam dates and recent readings.
- Prepared workspace ordering/search metadata caches only IDs and display fields; each snapshot resolves current document contents.
- Filtering toggles existing cards, retaining input, caret, composition and selection; the assignment panel is untouched.
- Dashboard assignment preview bounds rendered rows to 30 with accurate totals and View all matches. Complete view initially renders 100 and has an accessible Show 100 more control. Query/filter persist into complete view.
- Quick Jump reuses prepared normalized items while open; keyboard selection updates only the old and new row.
- Contextual coursework search now defaults to the current workspace; explicit Search all uses all workspaces.
- Reader navigation aborts pending HTML/index/image transfers, revokes object URLs and releases hidden reader DOM; expected cancellation does not show an error. Hidden conversations no longer render during dashboard polling/streaming.
- Existing bounded top-N recentReadings implementation was already correct and is retained.

Verification: web unit suite passed; real Chromium hosted smoke passed (sign-in, independent panels, reading, content search, import, tutor, account isolation, mobile). Focused behavior/work-count regressions in `tests/web/study-dashboard-performance.test.js` cover 500-card identity preservation, cache invalidation/current content, independent sections and 600-assignment access.

## Remaining integration
Atomic navigation callers, revision envelopes/notifications, streamed upload client, stress concurrency and final after measurements are in progress. This is not a final performance claim.
