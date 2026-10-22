# Baseline definitions — one per metric

Fixed before any number was computed (2026-10-22). Scripts cite the key in brackets.
Windows: items whose `triage_items.created_at` (or event `first_seen` where noted) falls
in `[AS_OF − window, AS_OF)`; outcomes observed up to `AS_OF`, open items counted as
censored, never dropped silently.

| Key | Definition | Source |
|-|-|-|
| `item` | One `triage_items` row. Rows with `close_reason = 'duplicate'` or `duplicate_of` set are **not** items; they are occurrences of their parent and are reported separately. | warden.db |
| `escalated` | The item has ≥ 1 transition into `needs_decision` ("reached the owner"). This one definition replaces Round 5's 14-day "reached the owner" and the findings' "ever reached `needs_decision`"; the KPI script reproduces both old numbers and explains any gap. | `item_transitions` |
| `owner_touch` | The item is `escalated`, **or** has a transition whose note starts with `closed by hand` or `re-investigation requested`, **or** an `operations` row with `authorized_by` like `owner:%` or `cli:%`. Any action from outside the autonomous loop counts, whoever typed it. | `item_transitions`, `operations` |
| `autonomy_rate` | `1 − owner_touch items / items`. SLO ≥ 99 % (owner: "sub 1 %"), stretch ≥ 99.9 % — amended 2026-10-22. Report 14d, 30d, all. | derived |
| `owner_pages` | Every owner-facing notification about an item: `needs_decision` entries, legacy `notified_at` posts and reminders (`reminder_count`). Attention cost; today's escalation KPI sees only the decision entries (140 of 577). Added 2026-10-22 after `incidents/` showed the gap — reported beside, never instead of, `escalated`. | warden.db |
| `genuine_escalation_share` | Escalated items whose golden-set label `genuine_owner_decision = y` / escalated items in the golden set. Genuine = the decision is the owner's by the fixed rule: product direction, spend, irreversible data loss, other people. Nothing else is genuine (security policy included). | `golden/labels.jsonl` |
| `resolved` | The item reached `fixed`, or `closed` with `close_reason ∈ {resolved, fixed_by}`, or `quiet` after recovery. `failed` and `ignored` are not resolved; `ignored` is reported as its own bucket. | `item_transitions`, `triage_items` |
| `time_to_resolve` | First event `first_seen` of the item → first transition into a `resolved` state. Median, p90, n, censored n. | warden.db |
| `reopen_rate` | Items with a transition out of `{closed, quiet, fixed, failed}` back to any non-terminal state / items that ever reached one of those states. | `item_transitions` |
| `regression_rate` | Fixes whose fingerprint recurs: an item resolved by a change (`merged_sha`, `pr_url`, `fixed_by_pr`, or a `closed by hand` note naming a commit) whose `signature` — or, where signatures differ by volatile tokens, its normalised title — reappears in a new item within 30 d after the fix / items resolved by a change. | warden.db |
| `revert_rate` | Per repo, 90 d: commits whose subject starts `Revert "` or has type `revert` / all commits. Plus warden's own: items with `revert_pr` or `reverting_sha` / items merged by warden. | git, warden.db |
| `rework_share` | Per repo, 90 d: commits of type `fix` or `revert` that touch ≥ 1 file changed by another commit in the preceding 7 days / all commits. The older proxy (`fix` commits / all) is reported alongside for continuity only. | git |
| `dora.*` | Where data allows: deployment frequency, lead time for changes (first commit of a change → deployed), change failure rate (a deploy followed within 24 h by an item on the same repo or a revert, each item charged to the latest preceding deploy only — amended 2026-10-22 after `dora.py` showed the literal rule charges every deploy in the window: 18.4 % literal vs 2.0 % attributed), failed-deployment recovery time, deployment rework rate (deploys that ship an unplanned fix / all deploys). Each states its data source and coverage. | warden.db `operations`/events, git, deploy notices |
| `cost_per_resolved_item` | Cost of every agent job attributable to an item (agw jobs via `dispatches.job_id` and the job store, plus usage-tracker rows carrying the job or session id) / resolved items, per window. States the attribution coverage. | agw-jobs.db, usage.db |
| `max_headroom` | Distribution of the Max 7-day and 5-hour utilisation over the observable history; days at ≥ 90 % (7-day); when the window last hit 100 %. | best available quota log (state it) |
| `herdr_hygiene` | Point in time (AS_OF, plus live at measurement): workspaces, tabs, agents by status, finished-but-open (`done`/`idle`) tabs older than 24 h, `claude --bg` leftovers. No history exists (herdr events are not recorded). | herdr API / `rd agents` |
