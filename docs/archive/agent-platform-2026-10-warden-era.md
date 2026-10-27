> Archived: the warden-specific parts of the agent platform design (loop, nine states, ingest trust model, status rows, lane, notifications).
> Warden was switched off 2026-10-27 (agent-workflows P0); nothing below describes a running system.
> Live doc: `docs/agent-platform.md`.

Text moved verbatim from `docs/agent-platform.md` (adopted 2026-10-02, landed 2026-10-10).

## Status table, warden rows

| Part | State |
|-|-|
| warden: gates cut, nine states, one queue | **landed** (W1–W2) |
| warden: intake fingerprint + triage dedup, revisions as attempts | **landed** (W3) |
| warden: merge train, deploy + verify, automatic revert, fixed-by sweep | **landed** (W4); review is not yet delta-only (needs an agent-gateway PR delta scope) |
| warden: docs, loop split into modules, own `check`/`deploy`/`verify`/`logs` | **landed** (W5) |

## Why this rewrite

Measured 2026-09-08 → 10-01 on the live ledger and logs:

| Symptom | Number | Root cause |
|-|-|-|
| Warden items merged by its own path | ~10 of 414 dispatches | 23 trust/approval/policy gates nobody asked for |
| Items that were duplicates or follow-ups | 30–40 % | raw log titles as identity, revisions filed as new items, no issue↔alert link |
| Failed dispatches from one policy drift | 281 | repo/tier policy defined in warden **and** agent-gateway |
| Hermes skills | 126 (≈105 self-authored) | upstream skill-review nudge + Hermes replying to every warden card |
| Ways to start an agent episode | 10+ | lanes added, never removed |
| Model ids hard-coded in docs | 6+ files, 3 different answers | no single source |

## The picture

Interactive version (pan/zoom, trace, export): [`diagrams/agent-platform.html`](diagrams/agent-platform.html).

```
 trusted sources                       front doors
 GitHub issues (owner/agents)          herdr: orchestrator tab → wave tabs   (owner drives)
 Kuma · HyperDX/OTel alerts            Hermes: Slack/Argo chat               (narrate, answer, route)
 watchdogs · `warden run`                   │
        │                                   │ file work → `warden run` / GitHub issue
        ▼                                   ▼
 WARDEN  intake → triage → investigate → implement → merge train → deploy → verify
        │            │            │             │            │
        │            └── single-shot triage     └────────────┴── agent-gateway jobs
        ▼
 Argo /warden = the one queue · Slack = one line on "done" / "needs decision"

 AGENT-GATEWAY the one worker engine: triage · dispatch(investigate|implement) · review · check
           OpenCode + cheap models by default, Sonnet only where judgment gates a merge
           model ids live ONLY in `GET /api/routing`

 core      ~/.claude (global CLAUDE.md, skills, agents) + per-repo AGENTS.md + Makefile
           read identically by Claude Code, OpenCode and every agent-gateway worker
```

## Roles, warden and related rows

| Component | Does | Never does |
|-|-|-|
| **warden** | owns the ledger; decides and drives every unattended item to `fixed` | hold per-repo config, ask for approval, edit code itself |
| **Hermes** | answers, narrates in one line per item, files work via `warden run` or an issue, opens herdr tabs when asked | dispatch on its own, land PRs, repeat warden cards, author skills unattended |
| **herdr + `rd`** | the owner's cockpit: orchestrator tab spawns wave tabs and waits on them | run unattended work (that is warden) |
| **Argo** | the single status + "needs you" surface | hold state of its own |

## Lane row

| Lane | When | Engine |
|-|-|-|
| `warden run` / issue | unattended, tracked to `fixed` | warden → agent-gateway |

## Repo contract, warden paragraph

Warden reads nothing else about a repo. Routing a signal to a repo uses the
signal's own label (Kuma tag, OTel `service.name`, GitHub repo) and falls back to
the triage step reading the candidate repos' `## Verify & Monitor` sections.

## Warden — the loop

Warden is the **sole remediation loop**: every alert source (jobs via `jobrun`/`jobs-grade`, Kuma and HyperDX by webhook, Slack and log lines, GitHub, `warden run`) opens an item here, and nothing else dispatches a fix. Hermes narrates, Kuma only watches the chain itself. Source model and thresholds: `docs/ops-signals.md`.

Nine states:

```
new → triaged → working → merging → verifying → fixed
                   │          │          │
                   └──────────┴──────────┴──→ needs_decision | failed
quiet · closed (terminal, with a reason: duplicate | fixed_by | ignored | resolved)
```

1. **Intake.** Every source writes an event. The fingerprint is the title after
   stripping timestamps, hex ids, paths, numbers and the log-file name — the
   same line from two log files is one event.
2. **Triage — single-shot, no tools** (agent-gateway `triage`, cheap single-shot model
   per `GET /api/routing`, ~1–10 s, cents). Input: the new event, the open items of the candidate
   repos, items fixed in the last 14 days with their PR titles. Output:
   `attach(item) | new(repo, title) | fixed_by(item|PR) | ignore(reason)`.
   Debounce stays one knob: alerts need ≥3 occurrences or ≥30 min open;
   issues and `warden run` are immediate.
3. **Investigate → implement** run as one item. The verdict returns a ≤200-char
   `summary`, a `rootCause` key and a `nextAction`. Any confidence goes to
   implement — review is the gate, not the investigator's self-assessment. A
   matching `rootCause` on another open item merges the two.
4. **Revisions are attempts, not items.** A blocked review re-dispatches on the
   same item from the prior branch (agent-gateway cuts the worktree from it). The
   cap counts only *stalled* rounds — a review that still finds a prior blocking
   finding unresolved (or a red check, conflict or revert); a round whose findings
   are all new is converging and keeps revising. Three stalled rounds land
   `failed`; attempt 3 onward runs on the stronger implement model. A blocking
   finding that repeats a prior one on a file the PR no longer changes is not a
   block: the revision dropped that change, so the diff resolved it.
5. **Merge train, one per repo, single-flight:**
   update the PR onto the latest default branch → `make check` / CI green on that
   SHA → review on that SHA (delta-only if a prior review confirmed) → squash
   merge pinned to the SHA. A conflict is not hand-resolved: the item gets a new
   attempt from the new base with the old diff as context. A CI red on the head
   SHA while the base is green first re-runs the failed jobs once on that same
   SHA; only a second red goes back for a revision (a flaky test is not the PR's
   defect, and a worker sent to fix it edits code outside its brief).
6. **Deploy + verify:** `make deploy`, then `make verify` and the item's own
   signal quiet for its window. Failure → automatic `git revert` PR through the
   same train, item back to `working` with the evidence. `make verify` also runs
   once just before the merge, as a baseline: red before AND after the deploy is
   pre-existing, not the merge's doing — it neither fails the item nor reverts
   it, and the item is judged on its own signal (the verify twin of a CI red that
   is also red on the base, which parks instead of revising).
7. **Fixed-by sweep:** after every merge, triage re-checks the repo's open items
   against the merged diff; plausible matches move to `verifying` and close when
   their own signal stays quiet.
8. **Retries are the default.** An infrastructure failure (503, synthesis
   error, idle timeout) retries with backoff; three strikes → `failed`, listed
   in Argo, never a page.

**`needs_decision` is the only human exit.** The verdict must name a concrete
question with two options (≤200 chars). Product decisions, irreversible data
operations, spend, and anything touching another person qualify. Missing
permissions, CI, review hiccups and "low confidence" do not.

Kept gates — quality, not trust: CI/`make check` green, review confirmed on the
merged SHA, GitHub rulesets, the debounce, quiet hours for pings.

### Ingest trust model

Kuma and HyperDX reach warden's ingest door (`POST` webhook, Wave 14/15) with **one shared bearer token**.
Whoever holds it can open an item that goes to triage and, for a routable repo, to an agent. Each event is fenced
as untrusted data in every brief (`intake._fence`), exactly like Slack and Kuma text, so the token is the control,
not the payload. Consequences: the token is `op://mini/warden-ingest/token` (the mini's secret cache) plus the two senders' configs, and the door is loopback with an off-box forward of `/ingest/*` only; rotating it
means re-seeding both; one compromised sender can forge the other's events. Per-sender tokens are the known
upgrade, deliberately not built (two senders, solo owner).

## Hermes — the front door

- Answers and narrates; files work through `warden run` or a GitHub issue; opens
  a herdr tab when the owner asks for one.
- **One reporting format:** one line per item —
  `<icon> <repo>: <what> — <state>[ → next/who] [PR]`, max three lines, then
  `Rest: …`. No ids, PIDs or mechanism unless asked.
- Mentions-only in #agents; never replies to warden's own posts.
- Skill creation by the background nudge is off; ~20 curated skills.
- Reads warden only through its API, never the database.

## Notifications

| Event | Where |
|-|-|
| item `fixed` | Slack #agents, one line |
| `needs_decision` | Slack #agents, one line with the question + Argo link |
| `failed` | Argo only; daily one-line count |
| everything else | Argo `/warden` |
