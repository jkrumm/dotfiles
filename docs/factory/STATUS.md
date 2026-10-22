# Factory design — status

Checkpoint for a fresh context. Read `BRIEF.md` first, then this file, then the newest
artifacts it names. Orchestrator: herdr tab `factory` (SourceRoot workspace), Opus, max
effort. Started 2026-10-22 07:40 UTC.

## Phases

| Phase | State | Artifacts |
|-|-|-|
| 0 — stop the bleeding | done: agw W12 (69deb89), dotfiles W3 (6e8a45c..16f3373), usage-tracker W1 (a5fbd23); running: warden-w8 | see *Phase 0* below |
| 1 — evidence | 8 workers running: kpi (warden), kpi (delivery/DORA/quota/herdr), postmortem, incidents, interventions, golden sampling, toil, signals | `evidence/` (conventions `evidence/README.md`, metric definitions `evidence/DEFINITIONS.md`) |
| 2 — model | pending | |
| 3 — loops | pending | |
| 4 — spikes → ADRs | spikes 1 (beads), 2 (durable: ledger vs DBOS-Python-on-SQLite), 4 (CLI vs MCP), 5 (artifact review), 6 (telemetry) running; 3 (correlation) waits on the golden set | `spikes/`, `adr/` |
| 5 — Argo | pending | |
| 6 — proof | pending | |
| 7 — panel ×2 | pending | |
| 8 — migration | pending | `waves.md` |
| report | pending | `report.html` |

## Fixed inputs

- `AS_OF = 2026-10-22T08:00:00Z`. Frozen snapshots of the mutable stores (warden.db,
  agw jobs.db, usage.db, research jobs) in `~/.local/share/factory/snapshots/2026-10-22/`
  (`evidence/snapshot.sh`, read-only files, never in git).
- Max quota at start: 5 h 3 %, 7 d 14 % — fan-out is affordable.
- Every evidence output passes `evidence/lib/redact.py --check` before commit (public repo).

## Phase 0 — what was launched and why

Rule from the brief: launch only Round 5 fixes that no open decision in this design can
invalidate. Each runs as an orchestrated `rd wave` tab from its repo's own plan.

| Wave | Repo / plan | Scope | Why it survives any redesign |
|-|-|-|-|
| agw Wave 12 | agent-gateway `docs/waves/PLAN.md` | host read verbs in `agw-readonly`; host-access gap as a structured verdict field; `_common.md` policy lines | whatever runs investigate must read the host; the policy lines encode the fixed owner-decision rule |
| warden Wave 8 | warden `docs/waves/PLAN.md` | brief tells the truth; recovered `slack_alert`/Kuma auto-close; co-firing fold (15 min window); terminal non-questions closed; features kept open on the ledger; drain `needs_decision` | level-triggered recovery, folding and "never drop a feature" are properties of every candidate design; the drain empties a queue that no redesign keeps |
| Round 5 Wave 3 (cut) | dotfiles `docs/factory/phase0/docs/waves/PLAN.md` (own plan: the gate needs a `done` predecessor and Round 5 W1–W2 are pending) | herdr event recorder (raw JSONL, no consumers) + `rd reap` janitor | raw agent-lifecycle material is lost daily; reaping finished tabs is needed under any agent topology |
| usage-tracker Wave 1 (added 10:40) | usage-tracker `docs/waves/PLAN.md` | collect agw's OpenCode v2 store (all IU OpenCode spend missing since 10-14, collector stale yet reporting ok); staleness fails loudly | cost is a control input in every design; raw material lost daily, same rationale as the herdr recorder |

Deliberately **not** launched (an open decision here owns them): timeout default
(durable await-decision design), improve loop job (Phase 3 improve), shadow promotion
(decide lane), feature store as GitHub issues (task SoR spike), herdr POST fan-out and
poll removal (event log design), tab metadata (Agent id scheme), one launcher (spawner),
overview truth, Obsidian 1706, Round 5 W1 and W4–W10 (dispositioned in `waves.md`).

Shared checkout: the dotfiles wave and this session both write the dotfiles checkout —
this session commits only `docs/factory/**` with explicit paths.

## Log

- 07:51 snapshots frozen; evidence conventions and definitions written.
- 08:20 Phase 0 waves launched (orchestrated). 08:25 Phase 1 workers ×8 launched (background subagents, sonnet).
- 08:35 research jobs (local research-gateway, `job` table): 19fe9e52 known-error store + regression detection (deep), 9235cd92 durable await semantics + SQLite-capable engines (deep), 382ddeb9 small-host healing/attack detection (standard). Export each to `research/` when done.
- 08:40 spikes 1, 4, 5, 6 launched.
- 09:05 research exported: `research/2026-10-22-known-error-regression.md`, `research/2026-10-22-durable-await-sqlite.md`, `research/2026-10-22-small-host-healing.md`. Spike 2 launched. Phase 1 adds: owner-question inventory (`evidence/questions/`), Argo/basalt-ui inventory (Explore).
- 09:40 golden frame done (959 packets = 404 sampled + 555 context; 21 chunks; 105 of 114 ever-escalated items; 50 homelab-private entities withheld by the self-contained rule). Labelling workflow `golden-labels` (run wf_f5b1aefd-ccf) launched: 21 labellers + second opinion on chunks 05, 13, 19 → `labels/`, `labels_b/`.
- Flag for the owner (doc contradiction, not fixed here): the global CLAUDE.md lists *security policy* as an owner decision; the brief's fixed rule (business only: product direction, spend, irreversible data loss, other people) excludes it. This design follows the brief; a migration wave aligns the global file.
- 10:35 kpi baseline done (`evidence/kpi/baseline.*`, `cost.*`): autonomy 64.3 % (14d) / 52.2 % (30d); escalated 32.2 % / 28.8 %; reopen 10.4–17.5 %; regression 10.4 % (5/48); cost per resolved item IU $0.36 + Max-equivalent $1.08 (14d). Found: usage-tracker blind to agw OpenCode since 10-14 → Phase 0 wave added.
- 10:50 incidents done (`evidence/incidents/`): ten costliest = 180 pages → ≈ 8 under the ideal path; 10-17 = a 7.9-min VPS kernel reboot (20:49–20:56) that became 18 pages via Slack duplicates; relay lag median 16 min; agent spend negligible, owner attention is the cost; 577 owner-facing notifications vs 140 decision entries → `owner_pages` metric added.
- 10:55 signals done (`evidence/signals/`): 63.7 % via Slack; slack_update (713, RollHook) unconsumed; relay loses structure, recovery pairing, timing (lag 15.7 min; 79.6 % of Kuma outages end inside one poll) and caps at 50 msgs; 37/40 Kuma-via-Slack rows duplicate the live webhook. Topology: 117 units (`topology.out.json`); blind spots 19/36 vps services unmonitored. Steered warden-w8: cross-source dedupe by monitor + window on message ts (inside its fold bullet).
- 11:05 postmortem done (`evidence/postmortem/`): 26 claims across 6 locks, 18 false at AS_OF, 15 of them within 7 d (median 0.9 d); enforced 7/7 held, prose 1/11, cross-repo 0/2; 9 false at lock; lane text copied into 19 files; 55 % of 293 open Left-behind items name no owner. Design rule adopted: every invariant is enforced (capability limit + test, CI lint, generated doc) or labelled `target`.
- 11:10 questions done (`evidence/questions/`): 27 canonical questions from 1,111 owner messages; 199/211 asked in Claude Code, 12 in Hermes, 2 in Argo chat; median answer 48 s / 5 tool calls, rebuilt each time. #1 owner action = 50 'continue/go' nudges to parked agents (quota resets, ended turns) → design must auto-resume at quota reset and auto-nudge idle agents with open plan work. MacBook was offline >1 h during the run; re-run fills its answer paths.
- 11:20 delivery/DORA/quota/herdr done (`evidence/kpi/{git_delivery,dora,quota,herdr_hygiene}.*`): 721 commits/wk; rework 25.6 % (argo 51.8 %); 110 deploys/wk, lead time median 0.53 h, CFR 2.0 % (attributed), recovery median 0.27 h; Max 7d p50 46 / p90 96 %, ≥ 90 % on 12 of 45 days, Sep 16–20 effectively unavailable; Max = 97.8 % of cost, 32 % of tokens; herdr 20 finished-but-open tabs (2 > 24 h), 2 blocked `--bg` leftovers 705 h / 386 h. RollHook notice stream collapsed since 10-11 (deploys invisible to warden).
- 11:35 interventions done (`evidence/interventions/`): latest 20 (40 h, 12 episodes) — 4 genuinely the owner's (business), 16 removable: present-human infra 5, agent stopped/asked needlessly 4, missing capability 3, wrong output 2, other 2; 26 'continue' messages after transient API-error stalls (median 1.2 h). Mechanisms covering 15/16: durable resume + await-condition, host verbs, known-error recipes, policy lines. Caveat for every transcript KPI: `rd say` text is marked owner-typed (61 % of marked entries are agent-authored). Owner-message excerpts now live only in `~/.local/share/factory/private/`; public candidate files carry ids, times and tags.
- 11:50 Phase 0 close-outs reviewed against diffs and live state. agw W12: verbs in `hostReadShellRules()`, gap signal = `rootCause: host-access-gap` (+ `nextAction: human`, `escalationCategory: blocker`), live job 2db20b08 read launchctl/logs/make verify; non-loopback curl kept (review angles need it). dotfiles W3: recorder live since 08:02Z (`~/.local/share/herdr-events/`), `rd reap` every 30 min, backlog reaped 4 tabs; 2 dead `claude --bg` records left (needs `claude rm`, deletes the conversation — folded into a migration wave with archive-then-remove as default). usage-tracker W1: `agent-gateway-opencode` source, 33,652 rows / $58.47 backfilled from 10-14, stale collectors fail `make verify`. Tabs closed with `rd close`.
- 12:20 spike 2 done (`spikes/02-durable/REPORT.md`, extracted from the agent transcript — subagent writes of REPORT.md were refused): ledger+statecharts (A) and DBOS-Python-on-SQLite (B) both 0 duplicates / 0 lost work over ~200 kills; B strands flows on redeploy (source-hash version), honours late answers, dead-letters crash loops, adds a 2nd SoR; recommendation A (~75 %).
- 12:25 repo classification (`evidence/projects/classify.*`, rule fixed first: planned units closed 90 d ≥ 10 ∧ commits/week ≥ 25): fleet = basalt-ui, argo, weatherorb, shutterflow (fleet/ handoff convention, 286 phase merges), dotfiles, warden; everything else session, prometheus-scripts included (92 commits, 0 waves).
- 12:45 engine numbers (`evidence/kpi/engine_policy.*`): agw OpenCode workload = $52/week on IU; at Sonnet list rates $783/week; Max window ≈ $32 list per 1 % (median of 7 cycles) → moving it onto Max adds ≈ 24 % of the weekly window (p50 46 → 70, p90 96 → 120). Decides Round 5's open question for option B.
- 12:50 spike 5 done (`spikes/05-artifact-review/REPORT.md`): adopt plannotator 0.28.26's Inbox behind our own `rv submit|wait|status` contract (prototype `rv/rv-pn.ts`, 51 lines, survives an Inbox crash); Argo reads its JSONL; do not build a review UI (≈ 2.5k lines); reject human-review (60–120 s auto-close, 38 px phone column). Risks: one maintainer, 34 releases in 30 days; vendor tailnet path refuses tagged devices → our own Caddy door.
- 13:10 toil done (`evidence/toil/`): owner — `c` launcher 479/month, `reset` 337, `claude --resume` 123, 87 human-queue asks/30 d (28 1Password writes, 10 failed on op's stdin template); agents — 5,782 `sleep` + 3,499 poll loops, 515 harness-blocked sleeps, 530 macOS-vs-GNU syntax failures. Top automation: fold outage pages (3.4 h/month), policy lines (2.7), `rd resume`/auto-restore (1.5), known errors for recurring log items (3.1), event-driven wake instead of polling (4.9 agent h).
- 13:15 spike 1 done (`spikes/01-beads/REPORT.md`, extracted from the transcript): do NOT adopt beads now — `external:` deps inert in v1.3.1 (0/9), lease TTL fixed at 5 min (305 s reclaim vs 30 s), contributor mode still commits tracked files, shared Dolt server never self-restarts, lockstep migrations; a 65-line SQLite extension passes the same oracle and crash tests at 3–14× less CPU. Extend the ledger (tasks, task_deps, ready CTE, leases), keep bd's verbs and JSON names. ~80 %.
- 13:35 ADRs written: 001 (tasks in the ledger), 002 (durable = ledger), 005 (plannotator Inbox behind `rv`), 007 (agents), 008 (engine B with numbers), 009 (Argo split), 010 (manifest), 011 (ledger + event log), 012 (verification ladder), 013 (primary-source intake), 014 (owner decisions). Pending: 003 (correlation, after labels + spike 3), 004 (CLI vs MCP, spike 4), 006 (telemetry, spike 6).
- 13:40 baseline gameday running (`evidence/gameday/baseline_gameday.py`, background): `docker stop glance` on the homelab at ≈ 13:40 UTC; restore by script at T0+30 min if nothing heals it; observe closure 15 min. Today's system includes warden W8 (on master).
- 14:05 spike 6 done (`spikes/06-telemetry/REPORT.md`, extracted): headless workers join one trace (25 spans, 3 services); interactive herdr panes ignore TRACEPARENT → join by `warden.item.id` resource attribute; Claude Code telemetry is OFF via `settings.template.json` (`CLAUDE_CODE_ENABLE_TELEMETRY=0` beats env); research-gateway needs a 30-line patch; ≈ 47.6k spans/day, ≈ 6 MB/day. ADR-006 written.
- 14:20 golden labels done (workflow wf_f5b1aefd-ccf, 24 agents): 959 labels, 458 incident groups; genuine y 6 / n 150 / na 803; known_fix y 20; uncertain 185 (19 %). Agreement on the 3 double-labelled chunks (`evidence/golden/agreement.out.md`): B-cubed F1 1.0 on grouping, κ 1.0 on genuine; free text differs (independent labellers) — caveat: both saw the same mechanical pre_* hints, so this is reliability, not validity. Spike 3 (backtest) launched.
