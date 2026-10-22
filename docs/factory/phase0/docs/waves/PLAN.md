# Factory Phase 0 — dotfiles

One wave, cut from Round 5 Wave 3 by the factory design session (`docs/factory/STATUS.md`).
It lives in its own plan because Round 5's Waves 1–2 are still `pending` and the green gate
requires the predecessor to be `done`.

## Wave 3 — herdr event recorder and janitor (Round 5 W3, Phase 0 cut)            <!-- status: active -->
Repo: dotfiles. Round 5 Wave 3 (`docs/waves/PLAN.md`), cut to Phase 0.

**Factory Phase 0 scope (2026-10-22).** The factory design session (`docs/factory/BRIEF.md`
§Phase 0, progress in `docs/factory/STATUS.md`) runs only the two pieces no open design
decision can invalidate: the raw event record and the janitor. Deferred to the factory
plan, do **not** do them here: POST fan-out to agw/warden/Argo, removing the polling loops,
tab metadata, one launcher, overview truth, Obsidian (1706), basalt-ui Wave 42.
**Shared checkout:** the factory session writes `docs/factory/**` in this checkout at the
same time. Never stage, stash, clean, reset or commit those paths — except this plan file, which your close-out commits; stage with explicit
paths only (`git add <file>…`, never `-A`/`.`); `git pull --rebase` before every push.

- [ ] **Event recorder** `com.jkrumm.herdr-events` (LaunchAgent, mini): subscribe to herdr `events.subscribe` for every event type `herdr api schema` offers (at least `pane.agent_status_changed`, `tab.closed`, `pane.exited`) and append each event, with a receive timestamp, to `~/.local/share/herdr-events/YYYY-MM-DD.jsonl` (data, not a log: never rotated or truncated; no retention policy yet). Reconnect with backoff when the herdr server restarts; write a `recorder.started` / `recorder.gap` line so gaps are visible in the record. No consumers: no POST fan-out, polling loops stay. Listed in `docs/architecture.md`; `make doctor` grades it.
- [ ] **Janitor `rd reap`** (+ `com.jkrumm.herdr-reap`, every 30 min): close a tab only when its agent is `done` or `idle` for longer than `REAP_IDLE_H` (start 12), its checkout is clean and pushed, and no `active` wave in that repo's plan owns it. Message (never close) dirty or unpushed ones and print them. Never touch a `working`/`blocked` agent, a mother/lead tab whose plan has an `active` wave, or a tab whose cwd is not a git repo (the `~/SourceRoot` design tabs). Kill finished `claude --bg` leftovers older than 24 h. `--dry-run` prints the plan; every live action is one line in `~/Library/Logs/herdr-reap.log`.
- [ ] Clean today's backlog through `rd reap` (dry run reviewed first, then live), not by hand; report what stayed and why.
- [ ] Exit: recorder live with ≥ 1 h of events (the 24 h log is measured by the factory session); one `rd reap --dry-run` and one live run in the log; `make check` green; `/review` on the diff; `make deploy` on the mini.
**Left behind:**
