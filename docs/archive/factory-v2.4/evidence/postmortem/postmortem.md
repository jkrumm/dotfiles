# Postmortem: why every "locked" model drifted

Evidence: `drift.out.json` (26 checkable claims over 6 locks, replayed over git history to AS_OF 2026-10-22T08:00Z) and `waves.out.json` (347 waves, 27 plans, 15 repos; 5 plans recovered from git where `PLAN.md` was overwritten). Claims are chosen for checkability, not sampled: this shows how locks fail, not how often. Cause classes and pattern tags are my judgment; dates, shas and counts are computed; git-visible claims only.

**Result.** Six locks in 41 days (gaps 21.9, 7.9, 4.1, 1.9, 5.1 d); the factory brief overrode Round 5 after 0.86 d. 18 of 26 claims are false at AS_OF, 8 held. Of the 18 replayable claims ever contradicted, 10 failed within 1 day, 15 within 7 (median 0.9 d). The premise holds, with a correction: nothing eroded. Every first contradiction is a commit by a wave or the owner.

| Model, lock (UTC), commit | Held | Drifted: claim, days from lock, first contradicting commit | Pattern |
|-|-|-|-|
| Estate round 2, 09-10 14:46, brain e7cde13 | hook `model-discipline.ts` + test; `wave-gate.py` in `rd wave` (41 d) | Hermes "no read path" 0.3 d (11bb095, planned); host fixes need a human 0.9 d (5641339, owner order, state-log §59); "un-overridable" self-pin 4.7 d (agw 673cb24); `agent-dispatch`/`rd bg` lanes 24 d (1d73c79); warden = "the control plane" 41 d (238fccf; `architecture.md:80` never changed) | field override; supersession without propagation |
| Agent platform, 10-02 13:01, dotfiles bc77d3f | repo contract 23/26 repos at round end, 24/26 at AS_OF; deleted lanes stay deleted | "never a model id in prose" 0 d (5 ids on the same page; cleaned 04fb7c3, back in 2170e19 after 5 d); herdr "never runs unattended work" 0 d (same page describes chain mode); Hermes "never changes code" false at birth (d888f9c, 2.1 d; toolsets grant `file`, `terminal`, `code_execution`); model id in `remote-dev.sh` 2.1 d; Argo verb mirror 3.3 d (healed in 55 min, `adopt` open since 10-11); "Four lanes" 7.9 d (5th row, 04fb7c3) | self-contradiction; append without restructure; hand-mirrored contract |
| Setup round 4, 10-10 10:01, dotfiles 9f20473 | no model ids in the lean global files; no `ask` rules; AGENTS.md-only (16 `CLAUDE.md` left at W11 close, true on day 4) | `/wave` shapes: skill (8b5ff37) and platform doc disagree from the lock, still at AS_OF | sibling divergence; declared done before true |
| OpenCode v2, 10-14 11:38, agw 87c7d94 | - | warden's brief promises `make logs`, `agw-readonly` allows git/rg/cat/ls/head/tail/wc/jq/curl: false from af81c7a, 1.5 h after lock, open 7.8 d, about 30 of 74 owner escalations (Round 5 facts) | cross-repo promise, no shared test |
| Background jobs, 10-16 09:51, dotfiles afec081 | Kuma and HyperDX by webhook (code) | "no investigate-only ceiling" 5.1 d: Round 5 plan reverses it, `ops-signals.md` untouched | supersession without propagation |
| Round 5, 10-21 11:03, dotfiles 238fccf | - | 3 of 3 never-lists false at lock: agw `implement`-reachable since 09-15 (673cb24, `AGENTS.md:716`), Hermes toolsets vs `SOUL.md:8` since 10-04, `LOOP.md:76-78` since 10-06; the factory brief calls the model "not a constraint" 0.86 d (83a8b7b) | aspiration as fact; owner restart |

## The failure that repeats

1. **Only claims a program runs held.** Enforced 7 of 7 held (hook + test, `rd wave` gate, the `make` contract warden executes, `CLAUDE.md` suppression, webhook filter); prose 1 of 11; cross-repo 0 of 2; deliberately reversed 0 of 6 (`drift.out.json` `summary.by_cause_class`).
2. **Drift is authored.** First contradictions: false at lock 6, the locking round's own later waves 6, a later round 4, between rounds 2. `04fb7c3` adds a fan-out lane under "Four lanes"; `3f37840` writes a model id into `rd` two days after the rule; `673cb24` drops a pin its comment called un-overridable.
3. **Targets are written as facts.** `agent-platform.md:23-26` says "landed as of 2026-10-10" (9f20473) while its never-unattended line contradicts the chain mode on the same page and "Four lanes" holds five rows; 9 claims were false at lock.
4. **One model, N hand copies.** Files restating the lane commands at each lock: 1, 7, 20, 18, 19, 19 (6 repos). W10 "docs on every surface" closed 10:01Z; `70aa142 rename leftover sideclaw mentions` followed 1.6 h later; the survivor, `~/.hermes/cron/jobs.json:96`, is outside git. "Control plane" stays on `architecture.md:80` through five later locks.
5. **Cross-repo promises have no shared test.** `opencode-server.ts:122-140` (af81c7a) denies what `work.py:264` (37e3869) promised 19 h earlier. Argo's verb list says "manually mirrored" (`warden.ts:115-119`).
6. **Locks outrun feedback.** Median wave 2.4 h; Round 4 closed 13 waves in 1.0 d, background jobs 19 in 14 h. The only feedback step, Estate W9 "field review", is owner-started and stayed `active` (`2026-09-estate-round-2.md:551`); the field look happened anyway (state-log §58-59: "if warden is confident in a fix it must do it") and the plan never learned of it.
7. **Close-out does not read state.** The gate checks clean tree, done predecessor, non-empty Left behind. Of 107 done platform waves: 11 closed with the `/review` tool failing (10 within 5.6 h on 10-04, Max OAuth expired), 19 committed but not pushed, deployed or live, 10 with a red gate left, 30 with an owner-gated item.
8. **Direction is stable, mechanism is not.** Each round removed a gate: approvals ("23 gates nobody asked for"), "no owner gates", "no ceiling", "at most 3 % reach the owner". A lock documents the last compromise; the next field look moves it.
9. **Deferrals have no sink.** 821 flagged open items (platform 293; hand-checked precision about 80 %, recall about 65 %). 55 % of the platform ones name no owner, wave, file or issue; 3 name the improve loop, dead since 10-17. Never picked up: cost per item (Estate W7/W8, 09-11; still a KPI to build on 10-22), `rd fan` documented as lane five while "never run against a live herdr" (W7), feature items closed "resolved" (1708/1709/1711/1712), the architecture-check red logged "unrelated" in five waves.

## Design implications

| Drift | Property that would have prevented it |
|-|-|
| prose never-lists, targets as facts | a never-line is a capability limit with a test (toolset, permission profile, ceiling) or carries `status: target`; a lint rejects a bare "never" |
| N copies; nouns, ids, counts | generate lanes, roles, verbs and counts from one manifest into AGENTS.md, skills and diagrams; CI contradiction lint across repos for banned nouns and ids; one system of record per entity |
| cross-repo promises | contract tests in the producer's CI: every command warden's brief names is accepted by `agw-readonly`; verb enums from one schema file |
| lock then overwrite | a model is a versioned file with `supersedes:` and `valid_until`; a new lock lists the lines it invalidates and CI fails while they remain |
| closing without state | `done` is computed: checks green in the repo and its consumers, review verdict or waiver, pushed sha equals deployed sha, every Left-behind item filed in the task system with an owner |
| owner restarts, manual field review | lock the invariants and measure them (business decisions only, owner touches at most 0.1 %); a daily reconciler replays claims against reality and files drift as items, Wave 9 made automatic |
