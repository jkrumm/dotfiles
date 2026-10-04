---
name: wave
description: Run a long implementation as a chain of fresh agent contexts on the mini — self-continuing (chain mode) or spawned wave by wave from a visible orchestrator tab (orchestrated mode). Use when work is too large for one context and would otherwise end with a hand-written handover prompt the human copy-pastes into a new herdr pane — multi-wave/multi-round/multi-phase implementations, staged migrations, anything whose plan says "then in the next session". Also use when asked to author a wave plan, to close out a wave, or to continue/resume a wave chain.
---

# Wave — a chain of fresh contexts that continues itself

A long implementation is not one agent's job. It is N agents, each with a clean
context, each handing the next a durable plan rather than a prompt in a terminal
someone has to copy.

## Vocabulary — two words, no synonyms

| Term | Is | Test |
|-|-|-|
| **Wave** | One agent context: one herdr pane, one fresh Claude, one handover in, one handover out. | Needs a fresh context → wave |
| **Step** | A unit of work inside a wave. Spawns nothing. | Fits in the current context → step |

A plan that says round, phase, stage, milestone or iteration is renamed at
authoring time. Nothing downstream searches for synonyms.

## Two modes

| Mode | Who spawns the next wave | Use when |
|-|-|-|
| **chain** | the finishing wave, from its own session (`rd wave`, below) | the plan is settled and nobody needs to look between waves |
| **orchestrated** | the orchestrator tab — an interactive session the owner can see | the owner wants a review point between waves, or a wave may need a different model/kind next |

The brief a wave starts from says which one applies. **"Do NOT spawn the next
wave"** (or any mention of an orchestrator) means orchestrated: a wave then ends
at its committed close-out and spawns nothing. No such sentence → chain.

### Orchestrated mode — the orchestrator's loop

The orchestrator holds no plan state of its own; PLAN.md is the state.

1. Spawn: `rd wave <repo> [--kind opencode] 'Read docs/waves/PLAN.md. Execute the active wave (Wave <n>). Follow the /wave skill, but do NOT spawn the next wave — the orchestrator tab does that after reviewing your close-out.'`
   Its own tab being `working` does not block the spawn — `rd wave` excludes the caller's pane and tab. Any *other* working agent in the checkout still does.
2. Block on it, one call each: `herdr agent wait <repo>-w<n> --until working --timeout 60000`, then `herdr agent wait <repo>-w<n> --until idle --until done --until blocked`. All three settled states — `done` alone never fires while the tab is being watched (it reports `idle`). `blocked` → `rd read` it before answering.
3. Review the close-out: read PLAN.md (the wave's **Left behind**, status flips), `git log` and the diff it produced. A wave's report is a claim, the diff is the proof. Re-run `/check` if the wave's own gate result is not in its Left behind.
4. Decide: red or incomplete → fix inline or `rd say` the wave; green → `rd close <repo>-w<n>` (refuses unless the tab is a `wave <n>` tab, the agent is not working, the checkout is clean and everything is pushed), then spawn the next. A next step that is outward-facing (merge, publish, release, deploy) stops at the owner.
5. One active wave per repo; parallel waves only across repos.

Chain mode leaves its tabs open — a wave cannot close the tab it is running in.

## The plan is the handover

`docs/waves/PLAN.md` in the target repo — committed, reviewable, and the reason a
wave chain survives a herdr restart. The prompt handed to the next wave is one
line; everything else is in the file.

```markdown
# <title>
**Goal:** <one sentence — the state the last wave leaves behind>
**Gate:** <the check/review command every wave must pass>

## Wave 1 — <name>            <!-- status: done -->
- [x] step
**Left behind:** <what wave 2 inherits: branch, decisions, known gaps>

## Wave 2 — <name>            <!-- status: active -->
- [ ] step
- [ ] step
**Left behind:**

## Wave 3 — <name>            <!-- status: pending -->
```

Exactly one wave is `active`. The status comments are the machine-readable part —
`rd wave` does not parse them, but every wave agent reads them first and the human
greps them.

## Running a wave

1. **Orient.** Read `docs/waves/PLAN.md`. Your wave is the `active` one. If none
   is active, or the active one is already `[x]` complete, stop and say so — do
   not guess which wave you are.
2. **Execute the steps.** Delegate as always: `mcp__sideclaw__dispatch` (tier
   `implement`) for settled edits off Max, `@implementer` for edits needing this
   pane's live tree, `Explore` for search, `/research` for library facts. The
   wave agent orchestrates; it does not grind.
3. **Close out.** In this order, every time:
   - `/check` — the plan's **Gate**. Report failures verbatim.
   - `/review` on anything non-trivial; fix findings via `dispatch` or `@implementer`.
   - `/commit` per logical concern.
   - Update `docs/waves/PLAN.md`: tick the steps, write **Left behind**, flip this
     wave to `done` and the next to `active`.
   - Prune what this wave made stale — dead docs, obsolete TODOs, closed issues.
     A wave that leaves stale docs behind has not closed out.
   - Commit the plan update, then push (PR-required repo: the branch). An unpushed
     wave cannot be closed by `rd close`, and the next wave starts from the remote.
4. **Gate, then chain** (chain mode) — or stop at the committed close-out (orchestrated). Below.

## The green gate

**A wave spawns its successor only if its own close-out was green.**

| Condition | Action | Enforced by |
|-|-|-|
| `/check` passed, review findings resolved | Prerequisite for the rest | The finishing wave's own judgment — not re-provable from the plan file, so `rd wave` trusts it |
| Plan committed, an `active` wave with a done, fully-ticked predecessor exists | Spawn it | `rd wave` → `scripts/wave-gate.py`, mechanical |
| No `active` wave, or the predecessor isn't `done`/fully ticked | **Stop.** Write the failure into the active wave's **Left behind**, commit, and leave the pane open. Do not spawn. | `wave-gate.py` refuses before touching herdr |
| The next step is outward-facing — merge, publish, release, deploy, ship | Stop and hand back to the human. `/ship` is a human's call, not a wave's. | `wave-gate.py`'s keyword heuristic on the active wave's next unchecked step — a subtler outward-facing reason still needs the wave to notice it itself |

A red wave that chains anyway poisons every wave after it with a broken base. The
mechanical half of the gate is the reason a broken close-out fails loud instead
of silently spawning into it; the judgment half (did check/review actually pass)
is still the finishing wave's to get right.

## Spawning the next wave (chain mode)

Orchestrated mode: skip this section — the orchestrator spawns. Chain mode: one
command, from the finishing wave's own session:

```bash
rd wave <repo> 'Read docs/waves/PLAN.md. Execute the active wave (Wave <n+1>). Follow the /wave skill.'
```

That adds a `wave <n>` tab to the repo's workspace, starts the agent in solo mode
(Claude Code by default, `--kind opencode` for OpenCode on the IU endpoint), and
submits the prompt. The handover content lives in the committed plan, not in this string —
keep the prompt to the two sentences above.

`RD_WAVE_MAX` (default 10) bounds the chain. `RD_DRY_RUN=1` resolves and prints
without spawning. `rd agents` shows every wave; `rd read <agent>` watches one.
Waves run on Sonnet unless `RD_WAVE_MODEL` says otherwise; a chain that needs
Fable sets it per spawn (rationale: `brain/wiki/engineering/model-routing.md`).

**Never `rd wave` a repo whose live agent is still `working`** — the command
refuses, and the reason is that two Claudes in one checkout silently race each
other's edits across panes where you cannot see it happen.

## Authoring a plan

Asked to plan a large piece of work: write `docs/waves/PLAN.md`, do not start
implementing. Size each wave to comfortably finish inside one context — three to
six steps. A wave that will obviously overflow is two waves. State the **Gate**
explicitly; a chain with no gate cannot be green.
