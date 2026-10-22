# Argo — draft 2 (Phase 5)

Built from `evidence/questions/` (1,111 owner messages, 27 canonical questions) and the
Argo/basalt-ui inventory. Report section 6 is built from this file.

## 1. What the evidence says before any view is drawn

- He asks his session agents, not his tools: 199 of 211 classified asks went to a Claude Code
  session, 12 to Hermes, 2 through Argo's chat in 60 days. Each answer is rebuilt from scratch:
  median 48 s and 5 tool calls (`git log`, `herdr agent`, `curl`, ssh probes).
- The loudest owner action is not a question: 50 `continue` nudges to parked agents (quota
  reset, API-error stall, ended turn) on 25 of 45 days. Argo cannot fix that by displaying it;
  the factory must auto-resume (loops §5). Argo shows the exception when it fails.
- The morning briefing already covers five classes he asked about 37 times anyway: a push
  he does not trust or cannot act on does not replace a place to look.
- Traffic and dependency state are named in his prompts but never asked in 60 days. Evidence orders
  the pages; it does not delete them: Traffic keeps its own page, after the exception-first ones.
- **What the cockpits he named actually do** (`research/2026-10-22-cockpit-ux-patterns.md`): Blume is a
  narrow desktop sidecar (a rail of Deliveries, Projects, Agents, Usage; five session states; count
  badges; no mobile). Worth copying: Vibe Kanban's row-level state with a grouped/flat toggle and a
  raised-hand *needs attention* state; Conductor's ambient status matrix instead of banners and one key
  that jumps to the next thing needing attention; cmux's layered attention (a notification body carries
  no context, so the inbox must); agent-deck's two-axis grouping (by project, by lineage) and an
  escalation-only phone bridge. Nobody publishes situation-adaptive layouts; the shared pattern is one
  shell that never changes shape, with ambient status, one attention queue and detail on selection.

## 2. Questions → read model → view

{{asset:chart-questions}}


`n` = classified asks (last 14 d). Every read model is a projection of the event log plus the
manifests (model invariant 8); "answer budget" is the timed-test target.

| # | Question | n | Read model | View | Budget |
|-|-|-|-|-|-|
| 1 | Which parked agent must I nudge? | 50 (24) | `agents_live`: status, idle since, stop reason (quota / API error / turn end / waiting), open plan items, auto-resume ETA | Home line 1 counts *parked*; Fleet "Parked" lane; target state: empty because auto-resume works | 3 s |
| 2 | Where are we on this effort? | 28 (18) | `plan_progress`: tasks done / ready / blocked per plan, last event, active attempt | Project header + Home "In flight" row per plan | 5 s |
| 3 | Is it done, merged, deployed and live? | 19 (11) | `delivery`: task → attempt → change → deployment → verification chain | Delivery view: one lifecycle strip per task | 5 s |
| 4 | Where is my quota and when does it reset? | 12 (10) | `quota`: Max 5 h / 7 d %, reset time, burn rate, forecast; IU spend today | Home line 1 + Usage | 2 s |
| 5 | Is anything broken right now? | 11 (7) | `incidents_open` + `conditions_open` by severity | Home line 1 (one sentence when quiet) + Incidents | 2 s |
| 6 | Why does X not work? | 11 (6) | `incident_detail`: signals, conditions, topology path, suspect deployments, known-error match, investigation | Incident view | 10 s |
| 7 | Which approvals could the agent take itself? | 15 (5) | `decisions_open` with decider and class | Needs you — expected empty; any non-business card is a defect counted on the KPI page | 3 s |
| 8 | What happened while I was away? | 8 (5) | `digest(since = last visit)`: shipped, fixed alone, opened, decided | Home "Since you left" | 5 s |
| 9 | Which tabs can close? | 9 (4) | `agents_live` finished-but-open, reaper log | Fleet: reaped automatically; shows only what the janitor would not touch and why | 3 s |
| 10 | Is that agent running, stuck or done? | 10 (5) | `agents_live` + heartbeat age + last output | Fleet row: status chip, heartbeat age, last line, link into the pane | 3 s |
| 11 | Broken connection or login? | 9 (4) | `conditions_open` of type auth / connectivity (secret-cache age, Claude auth, tailnet, GitHub credential) | Health / infra | 5 s |
| 12 | Disk or CPU pressure? | 6 (5) | host metrics + `infra.*` conditions | Health / infra | 5 s |
| 13 | How are all my agents doing? | 7 (4) | `agents_live` grouped by project and role | Fleet | 3 s |
| 14 | What does it cost; is tracking wired? | 7 (4) | `cost` by project / engine / day + collector freshness | Usage / cost | 5 s |
| 15 | Are the docs current? | 6 (5) | `docs.*` conditions per project, manifest drift | Project → Maintenance | 5 s |
| 16 | Where is the report, PR or dashboard? | 6 (3) | `artifacts` + manifest links | Artifacts; Project links row | 3 s |
| 17 | What is still pending in the plan? | 4 (3) | `plan_progress` | Project → Tasks | 5 s |
| 18 | What is waiting for me? | 5 (4) | `decisions_open` + `artifacts_awaiting` | Needs you | 2 s |
| 19 | Did self-healing work? | 5 (1) | incidents closed without an owner touch, with their verification | Home "Fixed alone" + Incidents filter | 5 s |
| 20 | Is X wired end to end? | 3 (3) | manifest drift check per integration key + last trace through the project | Project → Wiring | 10 s |
| 21 | What shipped since yesterday, and did it stick? (brief) | — | deployments + post-deploy verification + regressions | Home digest; Project → Changelog | 5 s |
| 22 | Is project X healthy — cost, traffic, deps? (brief) | — | project scorecard from conditions | Project page header | 5 s |
| 23 | What burns quota? (brief) | — | usage by agent / session / project, 7 d | Usage | 5 s |

## 2b. The write half — intent verbs (ADR-015)

Seven verbs, each writing an intent to the ledger through the factory API and executed by a
reconciler or `rd`: **submit** a brief or task to a project · **message / steer** a running agent ·
**pause / resume** automation per project or globally · **decide / override** a Decision ·
**comment** on an artifact · **re-verify / retry** · **stop / reap** an agent. Each shows *requested →
applied* on the lifecycle strip, writes an audit event, and has a phone affordance (ADR-015 table).

## 3. Information architecture

Exception-first: when nothing is wrong, each surface says so in one line and stops. **The shell never
changes shape** (rail, ambient status, one attention queue, detail on selection); **the content does.**

**Home adapts to the situation**, decided by a pure function of the read models:
| Situation | Trigger | Home shows, in this order |
|-|-|-|
| quiet | no open incident, no decision, nothing parked or stuck | the status line, *Since you left*, *Fixed alone* — nothing else |
| incident | an open incident affecting a production project | the incident card (cause, suspects, what automation is doing, ETA), then the status line |
| decision | a business Decision is open | the card with options, default and expiry, above everything else |
| many in flight | more than 5 agents working | the fleet matrix (ambient status per agent) replaces *In flight* rows |
| degraded factory | breaker open, quota guard tripped, mini unreachable | one banner naming the degraded part and what still runs |

**Project pages are composed from the manifest's capabilities**, not from one template:
| Capability (manifest) | Widgets |
|-|-|
| `runtime` with a deployed service | health and SLO burn, deploys and their verification, traffic, error rate, cost |
| `spec.type: library` | release line, consumers (basalt-ui → argo, rb), dependency state, open upstream components |
| `spec.type: infra` (host projects) | containers, disk, certs, backups, security signals |
| `class: fleet` | mother and leads, plan progress, ready queue, attempts in flight |
| any | links row, needs attention, tasks, todos (TickTick), artifacts, changelog, git state |

Pages:

- **Home (cockpit).** Line 1, one sentence: `0 need you · 4 working · 0 parked · all up · Max 46 % (resets Wed 16:00) · €3.20 IU today`.
  Then, only if non-empty: *Needs you* (≤ 5 cards, each one decision with options, default and
  expiry), *Broken* (open incidents), *Parked/stuck*, *In flight* (one row per plan or
  incident being worked), *Since you left* (digest), *Fixed alone* (count + list).
- **Project** (from the owner's wireframe): name, links (herdr workspace, app, repo, brain
  note), key stats (health, SLO burn, deploys 7 d, cost 7 d), needs attention, tasks, artifacts,
  health, changelog, cost, git state, maintenance (deps, docs, code health); traffic as a
  sparkline that turns red only on anomaly.
- **Needs you** — decisions and artifacts awaiting review, across projects.
- **Incidents** — open first, then closed with "fixed alone" vs owner-touched.
- **Fleet** — agents by project and role, parked/stuck first.
- **Artifacts** — the review inbox, grouped by project (ADR-005).
- **Health / infra** — hosts, containers, certs, backups, secrets cache, collectors.
- **Usage / cost** — Max quota, IU spend, by project and engine.
- **Traffic** — per-project request volume and anomalies, after the exception-first pages (he named it; it was never asked in 60 days, so it sits last).
- The life pages (Garmin, strength, body, reading, walking pad, astro) stay as they are, in
  their own nav group.

## 4. Where Argo runs (ADR-009 draft)

{{asset:argo-control-plane}}


| Option | Data locality | Availability | Cost of change |
|-|-|-|-|
| A. All on the VPS (today) | factory data arrives as 10-min snapshots; warden is loopback-only, so actions go through a pull queue; live herdr state impossible | life pages and the cockpit survive a mini outage, but the cockpit shows stale data then | none, but every question pays the relay |
| B. All on the mini | ledger, herdr, OpenCode, usage.db, Hermes read directly | mini down → no Argo at all, life pages included; the mini rebooted twice since Aug 29 and shares power with the homelab | move Postgres life data and crons |
| **C. Split (recommended)** | the SPA and the life API stay on the VPS; a **factory read API runs on the mini** next to the ledger; the browser (MacBook, phone — both on the tailnet, which already reaches the mini on 443) calls it directly | life pages always up; the cockpit shows "mini unreachable since hh:mm" from the VPS dead-man instead of stale numbers | new mini API; delete the snapshot pushes (agw overview, warden snapshot, usage records) |

**Dead-man's switch, off-site:** Kuma runs on the homelab, in the same house and on the same
power as the mini, so it cannot be the switch. A VPS-side receiver expects the mini's 5-min
heartbeat and pushes to the phone after 15 min of silence; Argo's VPS half shows the same fact.

## 5. basalt-ui: have, land, build

| Need | State | Action |
|-|-|-|
| shells, data table, stat cards, charts, command palette, mobile nav, notifications, markdown/Mermaid, chat | on master, tested | use |
| event list (feed and timeline) | branch `w44-eventlist`, tested | land (basalt Wave 44) |
| status chip with tones | two Argo copies | upstream one |
| decision card, entity card, schedule row | Argo prototypes (`UPSTREAM.md`) | upstream as package exports with tests |
| board (kanban) | basalt Wave 45 pending | not needed for the cockpit; tasks render as lists |
| lifecycle strip (an entity's statechart path with times) | missing | build in basalt-ui, its own PR |
| quiet line (one-sentence all-clear with drill-down) | `StatusVerdict` close | extend |

Dogfooding loop: Argo prototypes, basalt promotes, Argo deletes its copy (`argo/docs/design/UPSTREAM.md`);
the improve loop's `ui.upstream` condition counts components duplicated in consumers.

## 6. Proof for Argo

- Timed test: each question in §2 answered from Argo alone within its budget, on phone and
  desktop, scripted with the browser driver against fixtures plus one live run.
- "Left Argo to find out" is measured, not asked: the weekly count of status-class owner
  messages in Claude Code and Hermes (`evidence/questions/questions.py` classes 2–23). Baseline:
  211 in 60 days ≈ 25 per week. Target: ≤ 5 per week.
