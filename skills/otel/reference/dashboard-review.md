# Dashboard Review Checklist

Apply after `save_dashboard`/`patch_dashboard` and a `/browse` screenshot, before
calling the dashboard done. Every question is pass/fail — a "fail" means edit the
dashboard, not the checklist.

## Purpose

- **One question per dashboard.** Can you state, in one sentence, what decision
  this dashboard answers? If it needs "and also…", split it.
- **Top row = health-at-a-glance.** The first 3–5 tiles answer "is it healthy
  right now" without scrolling — request rate, error rate, p95 latency, and any
  domain-specific gate (queue depth, saturation). Everything below that row is
  drilldown.

## Metrics

- Rate, error rate, and latency are **p50/p95 per service** — never a bare
  average. Averages hide the tail that actually pages someone.
- Units are consistent across a tile and labeled on the axis (ms not s, req/s not
  req/min) — no unit-guessing from the number alone.
- No tile that is always zero, flat, or empty at the default time range. Delete
  it or fix the query — a dead tile trains people to stop looking.
- Group-by cardinality is ≤ 8 series per chart. More than that is a legend wall,
  not a signal — pre-filter or roll up into "other."

## Layout

- ≤ 8 tiles above the fold (roughly the first screen at 1440×900, no scroll).
- Titles name the **metric**, not the query — "p95 latency (ms)" not
  "quantile(Duration, 0.95)".
- No duplicated information — two tiles showing the same series at different
  angles is one tile too many.
- Time range defaults to 24h unless the dashboard's stated purpose needs
  otherwise (e.g. an incident-response dashboard defaulting to 1h).

## Color

- Color carries meaning: red = error/breach only. If nothing is red anywhere,
  the dashboard has no failure signal — that's a gap, not tidiness.
- Don't reuse red/orange for a healthy-but-busy state — that trains people to
  ignore red.

## Drilldown

- Every service-level tile has a path to the next level of detail — a saved
  search link, a trace waterfall link, or a linked dashboard. A dead-end number
  with no way to investigate further isn't finished.

## Chart type by question

| Question | Chart type |
|-|-|
| "What's the value right now?" | Number (single stat) |
| "How did it change over time?" | Timeseries line |
| "How do categories stack up over time?" | Stacked bar |
| "What are the top N / rank?" | Table |
| "What's the distribution / where's the tail?" | Histogram |
