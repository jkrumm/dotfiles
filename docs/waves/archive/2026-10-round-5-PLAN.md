# Round 5 — the dark factory

**Goal:** the owner sits at the wheel and nothing else. Work flows from signal to
shipped fix or feature without him; every layer has one job and every repo says
so; Argo is the one place he looks, and it tells him in a few precise sentences
what happened, what is running and the rare thing that needs him.

**Targets, measured on warden's ledger and herdr, 14-day windows:**

| KPI | Baseline 2026-10-21 | After this round | Direction |
|-|-|-|-|
| New items that reach the owner | 74 / 228 = **32 %** | ≤ 3 % (the genuine-decision floor measured today) | 0.1 % |
| Owner escalations that are genuine (class a) | 7 / 74 | ≥ 90 % | 100 % |
| `awaiting_owner` older than 24 h | 37 | 0 | 0 |
| Finished-but-open herdr tabs older than 24 h | 8 (+2 `claude --bg`) | 0 | 0 |
| Implement episodes outside herdr | 326 agw implement in 12 d | 0 | 0 |
| Slack channels a human needs to read | 6 | 0 (Argo + one push lane) | 0 |
| Services in one trace from warden item to gateway call | 0 | warden → agw → herdr/OpenCode → gateways | all |

**Gate:** each wave runs its repo's `make check`, `/review` on anything non-trivial,
deploys and verifies its own change (`make deploy` + `make verify`), and records
the KPI it moved in **Left behind**. No wave parks on the owner unless the change
needs a decision listed under *What reaches the owner* below.

**Mode:** orchestrated, from an orchestrator tab in the `dotfiles` herdr workspace.
Each wave is an `rd wave <repo>` tab in the repo it changes; a wave that touches
two repos runs in the one it changes most and commits to each repo separately.
One active wave per repo. Parallel only across disjoint repos (see *Order*).
Model: `RD_WAVE_MODEL` default; W4 and W6-design may raise to Fable — say why in the spawn.

**Quota note:** Max 7-day usage read 97 % during the audit. Nothing here starts on
Max before the weekly reset (2026-10-21 afternoon).

---

## The model — locked

This replaces the role table in `docs/agent-platform.md`. W1 writes it there; every
other place links to it.

| Layer | Component | Does | Never does |
|-|-|-|-|
| **L0 tools** | agent-gateway | bounded, non-mutating jobs: triage, decide, investigate (read-only, with host read verbs), review, check, prose, narrative, `read_image`/`read_drawing`, overview, `update_pr` (rebase only), the brain door (W8) | write feature or fix code, decide what to work on, merge |
| | research-gateway | cited research | — |
| | audio-gateway | speech in / speech out | own editorial pipelines (podcast pipeline: W8 decides where it lives) |
| | image-gateway | image generation and editing | image understanding (agw owns it) |
| | email-gateway | mail **and calendar** for every consumer (Argo, Hermes, agents) | — |
| | usage-tracker | usage and cost, every tool and every backend | — |
| **L1 execution** | herdr (mini; MacBook for Mac-only repos) | **the only place code is written.** One workspace per repo; every tab carries role, lane, origin and plan; a janitor closes finished tabs | — |
| **L2 orchestration** | warden | the autonomous loop: intake → triage → investigate → **spawn a herdr worker** → merge train → deploy → verify; owns escalation policy and the improve loop | write code itself, ask for anything a policy can answer |
| **L3 interfaces** | Argo | the human control plane: needs-you inbox, briefings, notification stream, live agents, warden board, monitoring, usage, Hermes chat | hold state another service owns |
| | Hermes | conversation and narration over every door; files work through `warden run` / `rd`; one client per door | implement, commit, patch repos, read another service's DB |
| | Slack | nothing, once W7 lands (until then: #alerts mirror + one push line) | carry briefings, chats or cards |
| **Knowledge** | brain | the vault; **one writer** (W8) | — |

Engine policy for L1 (who types the code inside a herdr tab) is the one open owner
question — see *Open*.

## What reaches the owner

Only these, each as one card with two options and a pre-selected default:
product direction, spend, irreversible data loss, other people, security policy.
Everything else is decided by policy, by an agent, or by a timeout with the cheap
reversible default (park, revert, leave the PR unmerged) — Sheridan–Verplank
level 6. Ack stops a card's re-push but does not resolve it (PagerDuty's model).
Each genuine escalation must retire a *class*: the wave that answers it writes the
policy line into agent-gateway `server/skills/dispatch/_common.md`.

---

## Established facts (audit 2026-10-21 — do not re-derive)

**Warden** (`~/SourceRoot/warden`, ledger `~/.warden/warden.db`):
- 30 d: 368 items, 201 finished unattended, **99 escalated (27 %)**; 14 d: **74/228 (32 %)**. Of the 74, ~7 genuine.
- **~30 of 74 are one contradiction:** agw's `agw-readonly` allows only git/rg/cat/ls/head/tail/wc/jq/curl (`agent-gateway/server/mcp/opencode-server.ts:122-140`) while warden's brief promises `Bash`/`make logs` (`warden/scripts/loop/work.py:264`). Investigate episodes can't read the host → "grant access or close?" page. One outage on 10-17 21:22 became 16 pages.
- Recovered alerts auto-close only for `uk`/`hyperdx` (`warden/scripts/loop/intake.py:444,619`); `slack_alert` pages sit forever.
- ~17 pages are terminal non-questions: "already fixed on master" (`no_changes` with a PR), revision ceiling, uncategorised verdicts.
- ~24 are class b — exactly the false positives `_common.md` already lists (which PR, upstream vs local, strict vs dampened, re-pin vs retire, defer to a wave, security finding that has a code fix).
- **Feature work is dropped silently:** Hermes-filed 1708 (Argo ingest), 1709 (session projects), 1711 (brain door), 1712 (Hermes consolidation) were closed "resolved — a feature, not a fix" with no change.
- Improve loop dead since 10-17 (`~/.warden/improve.cursor` 10-15; the `improve` tab `w1E:pZ` is a bare shell); when it ran it wrote code in-session (`docs/improve/LOOP.md:76-78`).
- Decision shadow: 124 settled rows, 93 % agreement, 68/68 at ≥0.95 — warden's promotion rule (`docs/decision-shadow.md:82-95`) is met. agw's own accounting says 77 % action accuracy; reconcile before promoting. Promotion saves cost, not pages.
- Argo's `WARDEN_ACTION_VERBS` lacks `adopt` (`argo/apps/api/src/routes/warden.ts:64-71` vs `warden/scripts/loop/notify.py:165`).
- 42 `awaiting_owner` now; 37 older than 24 h; failed: 543, 1576 (rebase-merge can't auto-revert), 1584.

**herdr / waves** (`dotfiles/scripts/remote-dev.sh`, `skills/wave`):
- 28 workspaces, 16 Claude agents, 1 working. Finished-but-open: homelab `w3N:p1`, brain `w11:pY`/`w11:p0`, dotfiles `wR:pK`/`wR:p1G`, modelpick `wG:pV`, prometheus-scripts `wJ:p37`, sy-serendipity `w35:p1`. basalt-ui mother `wK:p5T` idle 40 h with Wave 42 `active` but never spawned. Two `claude --bg` leftovers (research-gateway, weatherorb).
- Nothing closes non-`wave <n>` tabs; chain mode leaves tabs open by design (`wave/SKILL.md:82`).
- **herdr has push events** (`events.subscribe` with `pane.agent_status_changed`, `tab.closed`, `pane.exited`, per `herdr api schema`); nothing subscribes. Everything polls (overview 30 s, wave-watch 90 s, wait-quiet 120 s, Argo push 10 min).
- Waves hand edits to agw: `wave/SKILL.md:116-119` → 22 dispatch jobs today. Hermes launches by typing `c`/`cf` into panes (`hermes-agent/skills/herdr/SKILL.md:119`), bypassing `rd`'s green gate and prompt-delivery check. `remote-dev.sh:603,606,705` hard-code model ids.
- herdr state and `claude agents` disagree (`wJ:p2Z`); overview has no timestamps, no role, no MacBook.
- Recurring wave failures: dropped prompts (fixed by `deliver_prompt`), lead ends turn while workers run, `--until done` never fires on a watched tab, DONE before push, shared live checkout races, incomplete close-outs / "Review: none", workers weakening tests, `ask` rules stalling unattended agents, context rotation at ~60 %.

**agent-gateway** (`~/SourceRoot/agent-gateway`):
- 12 d: 326 implement starts (312 worktree, 14 in-place), 89 PRs opened, 102 updated, 83 `no_changes`; weatherorb 149, warden 67, agw 28. Every repo except dotfiles-private/homelab-private/brain is implement-reachable (`AGENTS.md:713`); `dotfiles/docs/ops-signals.md:21` says "warden implements from day one".
- Fail rates: dispatch 5.5 %, triage 7.3 % (all IU 503, no fallback), review 1.6 %. ~29 failures are bad `cwd`.
- OpenCode used: session create/env/prompt (steer, resume)/wait/messages/interrupt/active, agents with permission rules, `share: disabled`. **Not used:** durable per-session log (`GET /api/experimental/session/{id}/log?after=&follow=true`), inbox list/cancel, permission-reply API, forms, staged revert, export/import, compaction, plugins, `background`. `/api/event` is volatile by contract — build live views on the per-session log. OpenCode server restart still kills attached episodes (`AGENTS.md:579`). V2 runs no LSP. Upstream: `@opencode/cli` 2.1.2 (2026-10-21) breaks SDK/plugin contracts again (`session.compacted` removed).
- `job_stats` has no tier/outcome; backend/model null for dispatch/review/check.

**Observability:** OTel traces/logs only from research-, email-, audio-gateway (hand-rolled OTLP, `research-gateway/src/lib/otel.ts`); **no metrics from any gateway; nothing from agw, warden, Hermes, OpenCode, image-gateway, usage-tracker; no `traceparent` anywhere**. Max quota lives only in agw memory, statusline and heartbeat. No IU budget source.

**Hermes** (`~/SourceRoot/hermes-agent`, runtime `~/.hermes`):
- SOUL says "code changes are never yours", but Slack + CLI toolsets include `file`, `code_execution`, `terminal` (`config.yaml:708-730`). 30 d: 132 `git commit`, 218 `patch` (185 on warden). Today's desktop session committed 5cb6f68 + e45b366 itself.
- Private agw clients: `agents-overview.py` (552 lines), `prose.py` (213), `project-narratives.py` (773). `briefing-context.py:22-25,47` and `watchdog-summary.py` read `warden.db` directly. Briefing TTS curl duplicates native `text_to_speech`.
- Vision configured twice: Hermes `config.yaml:182` (sonnet-5-5, needs gateway restart) vs agw `routing.ts:283` (gemini-3.5-flash; Hermes' bake-off says 3.5-flash burns its budget on reasoning).
- email-gateway has **no** consumer: not in Hermes, Claude Code or agw.
- Crons: morning 07:00 Mon–Fri and evening 22:00 Mon–Thu → #briefings; brain drift Sat 09:00 → #watchdog; narratives 06:30 → #hermes + Argo `/agents/narratives`. `jobs.json:96` still says sideclaw.
- 1703 (Argo chat fallback `model: "hermes"`, briefing block, cron parity, herdr skill drift) is on PR #7, revision 5. 1706 is `needs_decision` (Obsidian KeepAlive — the Hermes session already decided KeepAlive; the dotfiles AGENTS.md says deliberately *no* KeepAlive; W3 settles it).

**Slack today:** #hermes (chat, narratives), #inbox (homelab drops), #alerts (Kuma, homelab watchdog, torrent-app, HyperDX — warden reads it), #updates (Watchtower, RollHook — warden polls), #media (podcasts, torrents), #agents (warden cards, human-queue), #watchdog (drift audit), #briefings. #journal/#news referenced, no poster.

**Argo** (`~/SourceRoot/argo`, basalt-ui 2.27.2):
- Today page = agents overview, narratives, warden snapshot, calendars, TickTick (one query per project), health. Control-plane pages sit in a "System" group below Health; Today is not a mobile tab; badges only for calendar/M365; 3 "Needs you" cards max.
- Data exists: `agent_overview_snapshots` (agw, 10 min), `agent_narratives` (daily), `warden_snapshots` (10 min), `warden_actions`, `usage_record` (15 min), `hermes_thread`/`hermes_message` (chat only; types todo/podcast/infra/note/research/general).
- Missing: server-side ingest, briefing thread type, stored notifications with read state, merged inbox (M365 important, email, GitLab reviews, failed jobs), live herdr view (VPS can't reach the mini — relay via agw or mini push), monitoring page (Kuma/Docker/`/summary` routes exist, unused by the UI), Max quota, HyperDX.
- Duplicates: `/gmail` reads Google itself (email-gateway `docs/vision.md:63-64` already decided Gmail moves there); `/slack` is a pure proxy for Hermes; `lib/ai-usage.ts:42,66` copies usage-tracker's pricing.
- Hermes chat V2: P0–P1, B1–B4, A1–A3, A5 shipped; A4 (Slack rows) and A6 hermes half deferred.

**Docs** contradict the model: no doc puts agw in a tool layer; agent-platform.md says herdr "never runs unattended work" while `rd wave` runs exactly that; "Four lanes" heads a five-row table; wave shapes differ between `agent-platform.md:228-234` and `wave/SKILL.md:29-31`; models in `agent-platform.md:198-202` are stale and break its own no-model-ids rule; warden is called "the control plane" in architecture.md, global-reference.md:101, hermes-agent AGENTS.md:8, jkrumm.com `facts.ts:304`; CodeRabbit lives on in `/pr`, `/ship`, `/commit`, `/git-cleanup`, `rules/commit-conventions.md`; email docs say Resend (now SES); no repo AGENTS.md except hermes-agent states what it must not do. jkrumm.com `guide/agent-infrastructure.mdx` mirrors 10-10; `personal-stack.mdx` claims Proxmox/TrueNAS and a nonexistent `scripts/deploy.ts`.

**Landscape** (research-gateway, 2026-10-21): nobody publishes a measured approval rate — 0.1 % has no precedent, so the KPI is ours. Converged pattern: deny-first risk tiers + autonomy ceiling; agent review is a *signal*, deterministic checks are the *blocking* gate (agent-only-reviewed PRs merge at 45 % vs 68 % human). Copy: Blume's "delivery" unit (brief, task tree, runs, revision, tests, screenshots → one decision) and five states incl. `approval`; Conductor's Checks tab + one "next thing needing me" jump; Vibe Kanban's schema (status on the task, execution on the attempt, per-attempt base commit); Omnara's interaction card (one schema for question and approval, first-writer-wins, answerable from any surface); Sculptor's CI babysitter. Attention: push only the blocking tier, cap "Needs you" at ~5, digest not feed, heartbeat + explicit **stuck** card, never make the human the monitor. Claude Code: `auto`/`bypassPermissions` can't come from project settings; PreToolUse `http` hooks can post to warden.

---

## Open — the one owner decision

**Engine inside herdr for warden's unattended implement work.** Moving 326 episodes /
12 days from agw-OpenCode-Haiku onto Max would land on a quota that read 97 % this week.

- **A — Claude Code on Max for everything.** Best quality, one engine. Risk: the weekly limit stops the factory, and the owner's own sessions with it.
- **B — herdr always, engine by class (recommended).** Warden's routine fixes (alert remediation, dependency bumps, small bugs) run OpenCode in a herdr tab on IU models — visible, steerable, same lane, same janitor. Features, waves and attempt-3 escalations run Claude Code on Max. A quota guard flips new Max work to the IU engine above a 7-day threshold.

W4 is the only wave blocked on this. Everything else proceeds.

---

## Order

```
W1 constitution (dotfiles + one Role line per repo)
 ├─ W2 escalation cut (warden, agw)        ─┐
 ├─ W3 execution layer (dotfiles)          ─┼─ W4 implementation into herdr (warden, agw, dotfiles) ── W9 observability
 ├─ W5 thin Hermes (hermes-agent)          ─┤
 └─ W6 Argo control plane (argo, basalt-ui)─┴─ W7 Slack retirement (warden, hermes-agent, homelab, vps, argo)
W8 brain door (agw, brain, audio-gateway) — after W2 releases agw
W10 docs + website — last
```

W6's owner-steered design session can start the moment quota resets; it does not wait for W1.

---

## Wave 1 — Constitution: one model, written once            <!-- status: pending -->
Repo: dotfiles (+ one commit per repo for its Role line).

- [ ] Rewrite `docs/agent-platform.md` around *The model — locked* above: layer table, never-list per component, *What reaches the owner*, the engine policy as "pending owner (W4)". Fix: lane count, wave shapes (adopt the skill's sequential / fan-out / fleet and say orchestrated vs chain is a mode of sequential), drop model ids from prose (point at `agw routing`), herdr's "never unattended" line, notifications table (Argo-first, Slack as transitional).
- [ ] `docs/architecture.md`: warden is "the autonomous loop", not "the control plane"; link to agent-platform for roles; fix heartbeat count (19), diagram count, Resend → SES, the backwards "superseded" link at :153-154. Same wording in `docs/global-reference.md:101` and `config/global.CLAUDE.md` if it carries any.
- [ ] Every repo's AGENTS.md gets one line under its title: `Role: <layer> — does X; never Y. Model: ~/SourceRoot/dotfiles/docs/agent-platform.md`. Repos: warden, agent-gateway, hermes-agent, argo, research-gateway, audio-gateway, image-gateway, email-gateway, usage-tracker, brain, basalt-ui. `docs:` commit per repo, pushed (basalt-ui: PR, its own commit).
- [ ] Remove CodeRabbit from `skills/{pr,ship,commit,git-cleanup}` and `rules/commit-conventions.md`.
- [ ] `docs/ops-signals.md:21` ("warden implements from day one") → point at the engine policy.
- [ ] Exit: `make check` green; `grep -rn "control plane" ~/SourceRoot/*/AGENTS.md dotfiles/docs` only names Argo; `/review` on the agent-platform diff.

## Wave 2 — Escalation cut: 32 % → ≤ 3 %            <!-- status: pending -->
Repos: warden, agent-gateway (separate commits; both direct-to-master).

**Factory Phase 0 (2026-10-22):** the no-regret subset of this wave runs as agent-gateway
Wave 12 (host reads, dispatch policy lines) and warden Wave 8 (recovery auto-close,
co-firing fold, terminal non-questions, features kept, drain), each in its repo's own
`docs/waves/PLAN.md`. The rest is dispositioned in `docs/factory/waves.md`.

- [ ] **Host reads for investigate.** Add read-only host verbs to `agw-readonly` (`make logs`, `make verify`, `make status`, `launchctl print`, bounded `tail` on `~/Library/Logs/*`, `curl` to loopback health) with a deny list for anything mutating; make warden's brief (`work.py:264`) state exactly that set. A verdict "could not read the host" is retried, then closed `quiet` — never a page.
- [ ] **Correlate and recover.** Co-firing alerts inside one window fold into one item (same host/time window, triage `attach`). Extend `resolve_recovered_decisions` to `slack_alert` and Kuma.
- [ ] **No terminal non-questions.** `no_changes` + "already on master" closes the PR and resolves. Revision ceiling lands with residual findings filed as follow-up items (if checks are green and no blocker is security/data) or fails as work — no page. Uncategorised `human` verdicts from implement episodes are re-driven once, then the agent's recommendation is taken.
- [ ] **Tighten categories.** security/data_loss findings that have a code fix revise first. Write the missing policies into `server/skills/dispatch/_common.md`: retention, upgrade windows, roadmap sequencing (defer to the repo's PLAN → file there, don't ask), KeepAlive vs watchdog (follow the repo's documented framework), which-of-two-PRs (newer green one, close the other). `[chronic]` → deeper investigate, not a page.
- [ ] **Timeout default.** A `needs_decision` card carries a default option and an expiry (48 h); on expiry warden takes the default if it is reversible, otherwise re-pushes once and holds. Ack ≠ resolve.
- [ ] **Features are never dropped.** A feature-shaped item is not closed "resolved": until W4 it becomes a GitHub issue labelled `feature` in its repo with the item's brief and stays linked; after W4 warden spawns it as a herdr worker. Re-file 1708, 1709, 1711, 1712 this way.
- [ ] **Improve loop as a scheduled job.** Daily launchd → `rd wave warden` with `docs/improve/LOOP.md`, closes itself; it files changes through `warden run`, never edits code in-session (`LOOP.md:76-78`). KPI on `/metrics`: escalation rate, class-a share, stuck count, autonomy ratio.
- [ ] Reconcile the decision-shadow numbers (warden 93 % vs agw 77 %) and promote if the rule holds on the reconciled number. Fix rebase-merge auto-revert (543, 1576). Argo `adopt` verb (one-line argo commit).
- [ ] **Drain the queue:** re-run every `awaiting_owner` item through the new policy; only class a stays.
- [ ] Exit: 72 h of live loop after deploy; escalation share of new items in that window recorded; `awaiting_owner` = genuine only.

## Wave 3 — Execution layer: herdr as a clean, observable factory floor            <!-- status: pending -->
Repo: dotfiles.

**Factory Phase 0 (2026-10-22):** the event recorder and the janitor run as their own
wave from `docs/factory/phase0/docs/waves/PLAN.md`. The rest is dispositioned in
`docs/factory/waves.md`.

- [ ] **Event daemon** `com.jkrumm.herdr-events`: `events.subscribe` → `~/Library/Logs/herdr-events.jsonl` + POST to agw (overview), warden (stuck/finished) and, after W6, Argo. `wave-watch.sh --events` reads it. Remove the polling loops it replaces. Listed in `architecture.md`.
- [ ] **Tab metadata:** every spawn (`rd wave|fan|work`, warden, Hermes) sets role, lane, origin (owner / warden item / Hermes), plan path and created time via `workspace.report_metadata` or the label; the overview groups by it.
- [ ] **Janitor `rd reap`**, every 30 min: close idle tabs that are clean, pushed and older than N h with no `active` plan wave; message (not close) dirty or unpushed ones and list them in the overview; kill `claude --bg` leftovers. Mother/lead tabs close when their plan is `done`. Kuma WARN on finished-but-open > 24 h.
- [ ] **One launcher:** `rd` is the only spawner. Hermes' herdr skill calls `rd wave|work`; `remote-dev.sh` reads models from `agw routing`, no ids in the script. Ensure every repo with a runtime has a workspace (`rd repos --ensure`), groups re-applied.
- [ ] **Overview truth:** show herdr vs claude-side state disagreements explicitly; LLM recommendation pass on a schedule; MacBook snapshot (`machine: iumac`) pushed through the same producer.
- [ ] Settle Obsidian on the mini (warden 1706): pick by the documented framework (`make obsidian-autostart` + watchdog vs KeepAlive), update AGENTS.md accordingly.
- [ ] Clean today's backlog: close the finished-but-open tabs listed in *Established facts* (clean + pushed only; report others), resume or close basalt-ui Wave 42 via its mother.
- [ ] Exit: event daemon live with a 24 h log; zero finished-but-open tabs > 24 h; `make check` green.

## Wave 4 — Implementation moves into herdr            <!-- status: blocked: owner engine decision -->
Repos: warden, agent-gateway, dotfiles. Needs W2, W3.

- [ ] **Worker primitive** `rd job <repo> --brief-file <f> --engine claude|opencode --origin warden:<id>`: worktree from fetched origin, a tab in the repo's workspace, brief delivered and verified, result contract (`.wave/result.json`: branch, PR, outcome, summary) written by the worker; returns a handle warden can wait on through the event daemon.
- [ ] Warden's implement stage spawns `rd job` instead of agw `dispatch implement`; revisions re-spawn on the prior branch; per-repo lease and concurrency cap (start: 1 per repo, 4 global); engine chosen by the owner's policy + quota guard. Review, check, `update_pr` stay agw jobs.
- [ ] agent-gateway: default dispatch ceiling `investigate` for every repo; implement tier off; in-place mode removed; docs updated.
- [ ] `wave/SKILL.md:116-119`: waves implement in their own session; agw `dispatch` is for verdicts only.
- [ ] Hard stops that stay: never two workers in one checkout; `ask` rules never in checked-in settings.
- [ ] Exit: a week of warden fixes landed through herdr workers, no agw implement job, Max quota curve recorded next to the IU spend.

## Wave 5 — Thin Hermes            <!-- status: pending -->
Repo: hermes-agent (+ `~/.hermes` config through its tracked templates).

- [ ] Toolsets: drop `file` and `code_execution` from Slack, CLI and desktop; `terminal` on an allowlist (`rd`, `herdr`, `warden`, `agw`, `research`, `imgcli`, curl to the doors). A Hermes request to change code becomes `rd wave` / `warden run`.
- [ ] One client per door: `agw overview` and `agw narrative` verbs (agw commit), delete `agents-overview.py`, `prose.py`, the client half of `project-narratives.py`; briefing reads `warden /board`, never `warden.db`; briefing uses native `text_to_speech`.
- [ ] One vision source: Hermes' vision slot points at agw routing's pick (agw owns image understanding); align agw `routing.ts` to the bake-off result (sonnet-5-5 or 3.8-flash, measured).
- [ ] email-gateway: register its `/mcp` with Hermes (and Claude Code if useful); Hermes reads mail and calendar only through it.
- [ ] Session projects (1709): plugin on `on_session_start`/`pre_gateway_dispatch` sets project by channel/cwd rules, LLM only for ambiguity; auto-archive cron/Slack sessions.
- [ ] Land 1703 (PR #7), cron registry parity check, purge `sideclaw` from `jobs.json`, herdr skill generated from dotfiles.
- [ ] Exit: 7 d of `state.db` with zero `patch`/`git commit` tool calls from Hermes; gateway restarted and vision live.

## Wave 6 — Argo becomes the control plane            <!-- status: pending -->
Repos: argo, basalt-ui (basalt-ui: its own commits, PR). Starts as an **owner-steered design session** (orchestrator + owner, this afternoon), then implementation waves the session writes into this section.

Design brief for the session:
- **Home = control plane.** Line 1: one sentence of state ("2 need you · 5 agents working · all systems up · €3.20 AI today"). Lane 1 **Needs you** (≤ 5 cards; Omnara-style card: one decision, why now, evidence, 2–3 options, default pre-selected, expiry and what happens on expiry; one keyboard jump to the next). Lane 2 **In flight** (one row per agent / warden item / wave: Blume's states running / idle / error / approval / stuck, heartbeat age, plan link). Lane 3 **Done today** as a digest written in the owner's voice, not a feed. Then the briefing card, then calendar, then body metrics.
- **Delivery view** for any item or wave: brief, task tree, runs, revision, checks, review findings, screenshots, decision — one object, one page (Blume / Conductor Checks).
- **Notifications** become stored rows with read/ack state and dedup keys, written by warden, agw, the herdr event daemon and Hermes through one ingest route; web push only for the blocking tier.
- **Briefings** (morning, evening) are Hermes threads of type `briefing`, rendered as cards with audio, replyable in place.
- **Live agents** via agw relay of the herdr event stream and OpenCode's durable per-session log; reply into a pane through the same relay (`rd say`).
- **Monitoring** page: Kuma states, HyperDX alert summary, gateway health, Max 5h/7d quota, IU spend, job success/latency from W9.
- Nav: control-plane group on top; Today is a mobile tab; badges for needs-you and stuck.
- Backend: Gmail and Calendar reads move to email-gateway; `/slack` proxy dies with W7; pricing comes from usage-tracker only. Prototypes (`decision-card`, `schedule-row`, `event-list`, `entity-card`, the two status chips) move upstream into basalt-ui.
- Copy rule: every sentence on these pages is written for a human, short, non-technical by default, technical on expand. Narrative text goes through agw `prose` with `brain/voice.md`.

- [ ] Session output: `argo/docs/CONTROL-PLANE.md` (spec, supersedes the overlapping parts of `HERMES-CHAT-V2.md`) and W6a…W6n appended here.

## Wave 7 — Slack retirement            <!-- status: pending -->
Repos: warden, hermes-agent, homelab, vps, argo. Needs W5 and W6's notification ingest.

- [ ] Warden cards, human-queue, briefings, narratives, drift audit, podcast results → Argo ingest. Web push (Argo PWA) for the blocking tier; ack from the phone writes the warden ledger.
- [ ] #alerts / #updates feeds go straight to warden ingest (webhooks), Slack mirror off after 14 quiet days.
- [ ] Remove `/slack` from Argo, `#journal`/`#news` refs from Hermes skills; archive the channels.
- [ ] Exit: no service posts to Slack; the owner's phone gets only blocking-tier pushes.

## Wave 8 — Brain door: one writer            <!-- status: pending -->
Repos: agent-gateway, brain, audio-gateway, hermes-agent. After W2.

- [ ] agw `brain` job: `capture` / `develop` / `audit` / `linkfix`; rules loaded from brain's AGENTS.md, `voice.md`, vault-lint; `develop` runs the prose pipeline; one writer (`brain-commit.sh` under the brain-sync lock).
- [ ] Move every writer onto it: Hermes `obsidian`/`capture`/`wildrift`/`reading`, `project-narratives.py`, `audio-gateway/src/brain-note.ts`, `dotfiles/scripts/brain-note.sh`, `/brain` skill. Inbox capture may stay in-process only if it goes through the same writer script.
- [ ] One project frontmatter schema; de-duplicate basenames across `Projects/` and `wiki/engineering/projects/`.
- [ ] Weekly drift audit = `brain audit` cron, findings to Argo.
- [ ] Decide where the podcast pipeline lives (audio-gateway keeps speech only).

## Wave 9 — Observability: one trace, real metrics            <!-- status: pending -->
Repos: warden, agent-gateway, research-, audio-, email-, image-gateway, usage-tracker. Needs W4.

- [ ] Warden opens the root span per item (trace id from item id) and sends `traceparent` on every agw call and `rd job`; agw stores it per job, forwards it to gateways and into OpenCode session metadata / the herdr worker env.
- [ ] agw, warden, image-gateway emit OTel (reuse research-gateway's OTLP module); metrics for jobs by tool/status/duration, queue age, escalations, steers, fallbacks, cost.
- [ ] `job_stats` gains tier, outcome, backend, model, cost; `GET /api/jobs/stats?days=N` for Argo.
- [ ] Max quota and IU spend into usage-tracker → Argo. Triage fallback route for IU 503. Refuse a missing `cwd` at submit. Kuma push for research-gateway and the mini audio instance.
- [ ] OpenCode restart safety (drain, refuse while sessions run, re-attach on `resume`); build agw's live session view on the durable per-session log. Pin OpenCode against 2.1's contract breaks before upgrading.

## Wave 10 — Docs and website            <!-- status: pending -->
Repos: dotfiles, brain, jkrumm.com. Last.

- [ ] Final pass over agent-platform.md, architecture.md, remote-dev.md, opencode.md against what W2–W9 shipped.
- [ ] brain: `wiki/engineering/gateways.md` links the layer definition; prune or banner `agent-overview-loop.md` history.
- [ ] jkrumm.com: rewrite `guide/agent-infrastructure.mdx` from the new model (frontmatter records the dotfiles commit it mirrors); fix `personal-stack.mdx` (homelab facts, no fake snippet); `facts.ts:304,422`. Voice: `brain/voice.md`, then `/prose`.
- [ ] Exit: `/review` on each repo's diff; site deployed and verified.
