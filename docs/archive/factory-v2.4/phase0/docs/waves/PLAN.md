# Factory Phase 0 — dotfiles

One wave, cut from Round 5 Wave 3 by the factory design session (`docs/factory/STATUS.md`).
It lives in its own plan because Round 5's Waves 1–2 are still `pending` and the green gate
requires the predecessor to be `done`.

## Wave 3 — herdr event recorder and janitor (Round 5 W3, Phase 0 cut)            <!-- status: done -->
Repo: dotfiles. Round 5 Wave 3 (`docs/waves/PLAN.md`), cut to Phase 0.

**Factory Phase 0 scope (2026-10-22).** The factory design session (`docs/factory/BRIEF.md`
§Phase 0, progress in `docs/factory/STATUS.md`) runs only the two pieces no open design
decision can invalidate: the raw event record and the janitor. Deferred to the factory
plan, do **not** do them here: POST fan-out to agw/warden/Argo, removing the polling loops,
tab metadata, one launcher, overview truth, Obsidian (1706), basalt-ui Wave 42.
**Shared checkout:** the factory session writes `docs/factory/**` in this checkout at the
same time. Never stage, stash, clean, reset or commit those paths — except this plan file, which your close-out commits; stage with explicit
paths only (`git add <file>…`, never `-A`/`.`); `git pull --rebase` before every push.

- [x] **Event recorder** `com.jkrumm.herdr-events` (LaunchAgent, mini): subscribe to herdr `events.subscribe` for every event type `herdr api schema` offers (at least `pane.agent_status_changed`, `tab.closed`, `pane.exited`) and append each event, with a receive timestamp, to `~/.local/share/herdr-events/YYYY-MM-DD.jsonl` (data, not a log: never rotated or truncated; no retention policy yet). Reconnect with backoff when the herdr server restarts; write a `recorder.started` / `recorder.gap` line so gaps are visible in the record. No consumers: no POST fan-out, polling loops stay. Listed in `docs/architecture.md`; `make doctor` grades it.
- [x] **Janitor `rd reap`** (+ `com.jkrumm.herdr-reap`, every 30 min): close a tab only when its agent is `done` or `idle` for longer than `REAP_IDLE_H` (start 12), its checkout is clean and pushed, and no `active` wave in that repo's plan owns it. Message (never close) dirty or unpushed ones and print them. Never touch a `working`/`blocked` agent, a mother/lead tab whose plan has an `active` wave, or a tab whose cwd is not a git repo (the `~/SourceRoot` design tabs). Kill finished `claude --bg` leftovers older than 24 h. `--dry-run` prints the plan; every live action is one line in `~/Library/Logs/herdr-reap.log`.
- [x] Clean today's backlog through `rd reap` (dry run reviewed first, then live), not by hand; report what stayed and why.
- [x] Exit: recorder live with ≥ 1 h of events (the 24 h log is measured by the factory session); one `rd reap --dry-run` and one live run in the log; `make check` green; `/review` on the diff; `make deploy` on the mini.
**Left behind:**
- **Recorder** `com.jkrumm.herdr-events` (`scripts/herdr-events.ts`, KeepAlive, `make herdr-events-setup|status|teardown`) live since 2026-10-22T08:02:13Z;       69 lines by 09:03Z (>1 h, 3 `recorder.started`, 0 gaps). Records the 24 type-only event kinds read from `herdr api schema` at start (envelope `{ts, event, data}`, `event` in underscore form, e.g. `tab_closed`) plus `pane.agent_status_changed` (dotted form) via one connection per live pane. Deliberately **not** recorded: `pane.output_matched` (needs a match spec) and `pane.scroll_changed` (viewport firehose). `recorder.gap` (from/to/why) is written on reconnect after a lost connection; a **process** restart writes only `recorder.started`, so each `recorder.started` after the first marks a possible hole back to the previous line (three before close-out: deploy-time restarts). Also `recorder.subscribe_failed`, `recorder.unparsed`, `recorder.pane_list_failed`, `recorder.pane_unwatched`.
- The 30 min schedule is proven live: the 10:35 CEST run fired by itself and is in the log.
- **Janitor** `rd reap [--dry-run]` (`scripts/herdr-reap.py`, `com.jkrumm.herdr-reap` every 30 min under `jobrun`, hermetic suite `make herdr-reap-test` in `make check`). Idle age = last timestamped record of the agent's Claude transcript (file mtime lies: resumes rewrite trailing metadata). Extra guards beyond the spec: never a tab holding a non-agent pane, never the caller's own tab, never a checkout (by git toplevel) a `working`/`blocked` agent also uses, `claude --bg` stopped only in state blocked/idle/done. Agents whose transcript is not found (non-Claude) have unknown age and are never closed.
- **Backlog run** (log `~/Library/Logs/herdr-reap.log`, 10:02 CEST): closed 4 tabs (modelpick 43 h, rb `verify` 23 h, brain x2 41 h/39 h), messaged 2 agents (hermes-agent 2 unpushed commits, epos.student-enrolment 1 uncommitted path). **Stayed, and why:** everything done/idle under 12 h; `dotfiles`, `prometheus-scripts` and the `~/SourceRoot` design tabs share a checkout with a working agent or are not git repos; `basalt-ui` fan tabs under 12 h or in a repo with an active plan; `w35:t1` holds a shell pane; `wJ:t31` has no transcript.
- **Two stale `claude --bg` records not cleaned** (`4eca7240` research-gateway 705 h, `7d5572c0` weatherorb 386 h): the bg daemon's control socket is gone, `claude stop` fails; logged once as `bg-stop-failed`, left in place. Removing them needs `claude rm` (deletes the conversation) — owner call.
- Known gaps (review improvements, not done): action replies are judged by substring `"error"` not parsed JSON; no timeout on `sh()` in the janitor; lock contention exits 0.
- `make check` green, `/review` clean on round 2 (round 1: 3 blocking, all fixed), `make deploy` run on the mini; `make doctor` grades both agents ok (its one failure, tailscale drift, predates this wave).
