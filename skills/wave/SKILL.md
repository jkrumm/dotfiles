---
name: wave
description: Run a long implementation as a chain of fresh agent contexts on the mini — chain mode or orchestrated mode. Use for work too large for one context, staged migrations, plans saying "then in the next session"; also to author a plan, close out a wave, or continue a chain.
---

# Wave — a chain of fresh contexts

**Wave** = one agent context (one pane, one fresh Claude). **Step** = work inside a wave; spawns nothing. Rename plan "round/phase/stage/milestone/iteration" at authoring time.

## Pick the shape first

| Shape | Use when | Mechanics |
|-|-|-|
| **sequential** (default) | One change stream, or a shared validation resource (app build, e2e lock). | One wave at a time, main checkout. |
| **fan-out** | N independent changes, disjoint files, cheap independent validation. | Briefs from `roles/worker.md`; `rd fan <repo> <briefs…>` makes a worktree (from *fetched* origin) and a Claude tab per brief; the orchestrator waits (below), then `rd merge <repo> <branches…>` (`docs/remote-dev.md`). `rd fan --clean <repo>` after. |
| **fleet** | Multi-phase work that outlives one context. | **mother** (`roles/mother.md`, never reads code), standing **lead** (`roles/lead.md`, owns review and merge), fresh **worker** per task (`roles/worker.md`). Rotation via `docs/waves/handoff/<name>.md`. |

### Waiting on workers

The spawner is the worker's parent (`rd fan`, and `rd wave` with `RD_ORCHESTRATED=1`; a plain chain `rd wave` is parentless), so the factory follows it. Never poll:

1. Spawn, then `factory session wait --on workers` and end the turn.
2. When the last child finishes, the factory types one note, `workers done: <child> <state>, …`; it starts the next turn.
3. Look: `rd read <agent>`, `factory status`.

- Only `factory session wait --done` closes a wait; a new turn clears nothing. After a wake the wait is spent (one wake per declaration) but still open, which also mutes send-back. **Declare `--on workers` again after every spawn or `rd say` fix, before ending the turn.** `--done` only cancels. A wake means no child is unfinished, not that a fix landed: if it precedes the fix turn, wait again.
- Workers running, no wait declared: the Stop hook sends the turn back once. Declare it then.
- Not a factory session (an owner's own session, or `rd` fell back to herdr): nothing wakes you. Wait in the foreground: `timeout <s> herdr agent wait <agent> --until idle --until done --until blocked`.
- A held spawn (`queued: <reason>`) is a worker too: the wake waits for it. A failed spawn does not (`factory status`).

### Fan-out rules

- Brief from the `Base:` line `rd fan` prepends (fetched origin), never the local checkout; a worker idle after its one re-send: `rd read` it.
- Gates: cheap check per change in the worker, full `make check` at merge (`roles/lead.md`).
- Push a worktree's branch with `git -C <worktree>`, never from the orchestrator's cwd (`protect-branches` judges the right tree).
- Probe LLM endpoints with `opencode-safe` and `timeout` (bare `opencode run` retries forever).

## Two modes

- **chain**: the finishing wave spawns the next; nobody looks between waves.
- **orchestrated**: a visible orchestrator tab spawns each wave; for review points or a different model next.

**"Do NOT spawn the next wave"** (or any mention of an orchestrator) in the brief means orchestrated: end at the committed close-out, spawn nothing. Otherwise chain.

### Orchestrated mode — the loop

PLAN.md is the state; the orchestrator holds none.

1. Spawn: `RD_ORCHESTRATED=1 rd wave <repo> 'Read docs/waves/PLAN.md. Execute the active wave (Wave <n>). Follow the /wave skill, but do NOT spawn the next wave — the orchestrator tab does that after reviewing your close-out.'` `RD_ORCHESTRATED=1` skips only the gate's outward-facing keyword stop and keeps you the parent. The caller's own tab does not block the spawn; any other working agent in the checkout does.
2. Wait (above). `blocked` → `rd read` it before answering.
3. Review the close-out: PLAN.md (**Left behind**, status flips), `git log`, the diff; the report is a claim, the diff the proof. Re-run `/check` if the gate result is not in Left behind.
4. Red or incomplete → fix inline or `rd say` the wave. Green → `rd close <repo>-w<n>` (refuses unless a clean, pushed `wave <n>` tab with no working agent), then spawn the next. An outward-facing next step (merge, publish, release, deploy) stops at the owner.
5. One active wave per repo; parallel only across repos.

Chain mode leaves its tabs open.

## The plan is the handover

`docs/waves/PLAN.md` in the target repo, committed, so a chain survives a herdr restart.

```markdown
# <title>
**Goal:** <end state>
**Gate:** <the check/review command every wave must pass>

## Wave 1 — <name>            <!-- status: done -->
- [x] step
**Left behind:** <branch, decisions, known gaps wave 2 inherits>

## Wave 2 — <name>            <!-- status: active -->
- [ ] step
```

Exactly one wave is `active`. `rd wave` ignores the status comments; `(Wave <n>)` in the prompt names the tab and agent `<repo>-w<n>` (else the next free number).

## Running a wave

1. **Orient.** Read PLAN.md; your wave is the `active` one. None, or already complete: stop and say so.
2. **Execute.** Delegate: `@implementer` (live tree), `rd fan` (independent same-repo changes), `Explore`, `/research`. The wave agent orchestrates; it does not grind.
3. **Close out**, in order:
   - `/check` (the plan's **Gate**), failures verbatim.
   - `/review` non-trivial work; fixes via `@implementer`.
   - `/commit` per concern.
   - PLAN.md: tick steps, write **Left behind**, flip this wave `done`, the next `active`.
   - Prune what the wave made stale (dead docs, obsolete TODOs, closed issues).
   - Commit the plan, push (PR-required repo: the branch): `rd close` refuses an unpushed wave and the next starts from the remote.
4. **Gate, then chain**, or stop at the committed close-out (orchestrated).

## Ending the turn

Ending the turn is right once a wait is declared; a background shell, monitor or agent still running at the end strands the chain.

- Foreground work is bounded: `timeout <s> <cmd>` or a poll loop of ~10 minutes at most. No `Monitor` or `run_in_background` as the last act of a turn; collect (`TaskOutput`) or stop (`TaskStop`) background tasks before the close-out commit.
- A close-out ends in exactly one of: the next wave spawned, or "stopped: <reason>" in **Left behind**. `queued: <reason>` from `rd wave` (a drain, no capacity) is a spawn.

## The green gate

**A wave spawns its successor only if its own close-out was green** (`/check` passed, review findings resolved: the wave's own judgment, `rd wave` trusts it). The rest is mechanical, `rd wave` → `scripts/wave-gate.py`:

- An `active` wave with a done, fully-ticked predecessor: spawn it.
- No `active` wave, or the predecessor isn't `done`/fully ticked: **stop.** Write the failure into the active wave's **Left behind**, commit, leave the pane open.
- Next step outward-facing (merge, publish, release, deploy, ship): stop and hand back to the human; `/ship` is a human's call. The gate matches keywords only; notice subtler cases yourself.

## Spawning the next wave (chain mode)

Orchestrated mode skips this. From the finishing wave:

```bash
rd wave <repo> 'Read docs/waves/PLAN.md. Execute the active wave (Wave <n+1>). Follow the /wave skill.'
```

Keep the prompt to those two sentences.

`RD_WAVE_MAX` (default 10) bounds the chain; `RD_DRY_RUN=1` only prints. Model and effort come from the factory role table (`--role mother|lead|wave|worker|mechanical`; `RD_WAVE_MODEL` / `RD_WAVE_EFFORT` override; `docs/remote-dev.md`). Fable: set per spawn.

**Never `rd wave` a repo whose live agent is `working`**: two Claudes in one checkout silently race each other's edits (it refuses).

## Authoring a plan

Write PLAN.md; do not implement. Three to six steps per wave. State the **Gate**: no gate, no green.
