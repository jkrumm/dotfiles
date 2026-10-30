# ADR-007 — Agent topology and lifecycle: on-demand mothers for fleets, sessions for the rest, one spawner

> **v2 status (2026-10-24):** revised — herdr = Claude Code on Max; fleet mothers own plans; workers by default (TDD v2 §4, §5). The text below is v1 history.

- Status: accepted · 2026-10-22 · revised after panel pass 1 (int-1, sim-3, sim-6, sim-7, ux-1, cos-4, ver-5, dur-2), pass 2 (sim-3, sim-4, dur-1, dur-2, dur-8, ux-1, cos-9) and the cross-lab review (R2, R6). In the body, `p2` marks a pass-2 id; `R<n>` ids are rows of `panel/review-resolutions.md`.
- Evidence: `evidence/projects/classify.out.md` (fleet/session rule), `evidence/questions/questions.md` (50 `continue` nudges, #1 owner action; 41 of 50 from Claude Code on the MacBook, 38 in shutterflow), `evidence/interventions/interventions.md` (26 API-error stalls, median 1.2 h), `evidence/kpi/herdr_hygiene.out.md` (20 finished-but-open tabs), `research/2026-10-22-agents-durable-mcp-otel.md` §2 (Gas Town), Round 5 *Established facts* (326 implement episodes outside herdr in 12 days; Hermes typing `c`/`cf` into panes)

## Context and problem statement

The owner's drawing puts mother → lead → wave on fleet projects and plain sessions elsewhere.
Today fleets exist ad hoc (basalt-ui's mother, shutterflow's mother-6/lead-8 on the MacBook,
weatherorb wave 84); four paths start agents; agents stop and wait for a human to type
`continue`; finished tabs pile up. Who runs, who spawns, and how does an agent's life end?

## Decision drivers

Zero owner nudges; one way to start an agent; work survives the death of the session doing it;
LLM tokens only where judgment is needed; the manual Claude Code + herdr lane keeps working.

## Decision outcome

1. **Class comes from the manifest** (ADR-010), decided by evidence: fleet ⇔ ≥ 10 planned units
   closed in 90 days and ≥ 25 commits/week. Fleet today: basalt-ui, argo, weatherorb, shutterflow,
   dotfiles, warden. Everything else is session.
2. **Roles.**
   - *Mother* (one identity per fleet project): **persistent identity, on-demand sessions**
     (tradeoff with sim-7, below). Identity and continuity live in the mother's hook; no context is
     resident between wakes. The planner wakes a project's mother only for judgment the code does
     not hold: a Condition with no recipe, a submitted brief that needs breaking into Tasks, a plan
     that needs re-sequencing. Deterministic Task creation (correlator, planner, plan projector,
     ready queue + `rd`) stays code. The mother never edits code and rotates through the hook at
     the context mark.
   - *Lead* (p2 sim-3): a mother wake scoped to one plan — the same identity and hook mechanism,
     shown in Argo as the plan's lead. It is woken only to re-sequence its plan or to resolve a
     conflict a worker returned unresolved; it claims no Task and spawns no worker. Sequencing is
     `task_deps` and the ready queue (ADR-001), spawning is `rd` (§3), rebases and train returns
     are Change transitions (`design/model.md` §2), review is the ladder (ADR-012).
   - *Worker*: an Agent with a `task_id` and its hook; implements and verifies inside the hook,
     hands back a Change. Attempt is dropped as a noun (sim-3): a Task's attempts are its worker
     Agents.
   - *Session*: one agent per task for session-class projects and ad-hoc work.
   - *Hermes*: the conversational door; answers from read models, files Tasks, asks the spawner for
     sessions. Never edits code — enforced by its tool allowlist, not by prose (postmortem: prose
     claims held 1 of 11).
3. **One spawner: `rd`.** The only code path that creates a herdr agent. warden, mothers and
   Hermes call it; it writes the Agent record through warden's API (optional `task_id`), cuts the
   hook, delivers and verifies the brief, and sets tab metadata (role, project, task, origin,
   engine). Engine per ADR-008. Tasks are claimed only through the ready queue and `rd`. `rd` stays
   a thin spawner (R6): it never opens `ledger.db`, and nothing outside warden reads the ledger for
   policy.
   - **One admission module, in warden** (p2 sim-4, R6): `warden admit`, a verb of the factory API,
     decides every spawn and every resume: `admit(task, class, lineage)` → run on engine X, defer
     until T, or reject(budget). `rd` calls it before it creates anything and acts on the verdict.
     It folds the quota guard and the admission order (ADR-008) with the per-Task, per-lineage and
     per-wake budgets (ADR-012 rule 12), so a resume at a quota reset passes the same module at the
     forecast's token rate and never bursts (cos-4). The breaker and the per-action rate limits
     stay on the ship side (ADR-012): they gate shipping, not spawning.
   - **`rd` fails closed** (p2 dur-1, R6): a spawn carrying a `task_id` is refused while
     `warden admit` cannot answer — warden down or the ledger unreadable — and every spawn is
     refused in adopt mode (ADR-011); none is spooled. The spool exists only for the owner's manual
     `rd wave` sessions without a task; each line carries a client uuid, and replay records an
     observed Agent (adopt), never a spawn.
4. **The hook owns the work** (Gas Town): worktree + branch + base sha + `.factory/attempt.md`
   (task, progress, handover) + the lease **epoch** + an inbox for messages to the agent (§5). A
   successor resumes from the hook, never from a re-prompt. Branch and PR naming: ADR-002.
5. **Witness = the agent reconciler**, deterministic code driven by the herdr event record
   (Phase 0): *parked* (quota limit, transient API error, turn ended with open plan items) →
   writes `idle.parked{reason, resume_at}` and asks the admission module to resume it — after a
   quota reset at the forecast's token rate, never from a timer firing at the reset; after a
   backoff for an API error; or a nudge with the plan's next step; *stuck* (working, no output
   past the idle limit) → re-drive from the hook; *dead* (pane gone) → resume by session id or
   re-drive; *finished-but-open* → reap (Phase 0 janitor). Auto-continues and re-drives count
   against the Task's and lineage's budget in attempts and engine-tagged tokens, with backoff —
   never wall clock; exhaustion opens `lineage.breaker` (ver-5, ADR-012).
   - **Messages go to the hook inbox** (p2 dur-8). A nudge or a steer is written to the agent's
     inbox; Witness then nudges the pane once, carrying the message id — `rd say` probes the herdr
     pane record for that id before any retry (the effect registry's probe-before-retry, ADR-002).
     The agent answers with `warden agent reply`, the one writer of `agent.replied` (ADR-015).
   - Every Witness action is a registered effect (ADR-002): its timer row clears in the
     transaction that writes the `operations` row, so after a crash the open operation is probed,
     never re-fired.
6. **Re-drive is fenced, in the ledger and in the checkout** (dur-2, p2 dur-2). Every lease grant
   (task claim, agent) issues an **epoch**, written into the hook; every mutating call carries it
   and a stale epoch is rejected. A pane frozen by a TCC dialog or revived by herdr's own
   `claude --resume` can still run `git` and `gh` itself, so the checkout is fenced too:
   - the successor inherits the same hook (worktree and branch) only after the predecessor is
     confirmed dead — its pane process tree killed and verified through herdr and `ps`; otherwise
     it gets a fresh worktree on a new branch cut from the ledger-recorded sha;
   - a per-worktree pre-push hook calls `warden lease check --epoch` and rejects a stale epoch;
   - commits carry `Factory-Agent` and `Factory-Epoch` trailers, and the merge train accepts only
     heads pushed under the current epoch; git effects stay fenced by
     `push --force-with-lease=<ledger sha>` and merge `sha=`.
7. **Rotation** at the context mark (~60 %): the agent writes its handover into the hook, the
   spawner starts the successor, the predecessor is reaped. A mother's rotation is the same path;
   with on-demand sessions there is no daily restart.
8. **Two herdr hosts, one record, one actuator each** (ux-1, p2 ux-1). The MacBook herdr observer —
   the Phase 0 event recorder plus an actuator — pushes events to the mini's ingest when online
   and pulls resume, steer and stop intents from the mini, applies them to the local herdr and
   acknowledges (ADR-015); Witness queues the same resume intent for a parked MacBook agent. While
   the laptop is closed its agents carry `host_asleep since hh:mm`, written only on an explicit
   sleep event: a recorder gone silent without one is a stale source (ADR-009), never asleep.
   Intents for a sleeping laptop queue and expire per ADR-015. shutterflow's fleet stays on the
   MacBook (Mac-only work) and is observed and actuated there, not moved.
9. **agw is a bounded tool server, no loop** (sim-6). Before W8 its `decide`, `triage`,
   `narrative` and `investigate` tools are unregistered (their code stays on disk until W12); W8 wraps review, check, prose, read_image and
   read_drawing.
10. **Gas Town, explicitly.** Copy: the hook, Witness, Refinery (warden's merge train), Deacon
    (reconcilers on patrol), persistent identity with ephemeral sessions (the mother). Reject: a
    global Mayor LLM (scheduling is code), idle LLM patrols (≈ 10× token cost reported), convoys
    (Task dependencies), tmux (herdr).

### Tradeoff: mothers (int-1 with sim-7)

The owner asked for mothers on the big projects; the simplifier showed a resident mother
duplicates the code that already turns Conditions and plan items into Tasks, and a lead that
spawns workers duplicates the spawner and the ready queue. Kept: one mother identity per fleet
project, its continuity in the hook, plan-scoped lead wakes, handover and rotation through the
hook. Given up: an idle resident context per project — the mother runs only when the planner wakes
it — and a separate lead mechanism. W4b builds mothers and lead wakes explicitly (R2).

### Consequences

- Good: the #1 owner action (nudging) is handled by Witness, MacBook agents included, with no burst at a quota reset; implementation leaves agent-gateway (it keeps bounded tool jobs: review, check, prose, read_image, read_drawing); no resident mother contexts burn Max between wakes; one mechanism (a mother wake) replaces mother plus lead, and one module, in warden, decides every spawn — so `rd` carries no policy and no ledger access.
- Bad: `rd`, `warden admit` and epoch fencing (the pre-push hook included) are critical-path code with their own tests; a mother's wake carries hook-reload cost every time; a task-carrying spawn waits while warden or the ledger is down, because admission lives in warden; the MacBook actuator is a second small component, and an intent for a sleeping laptop expires instead of waiting.

### Confirmation

KPIs from read-only scripts: owner `continue` nudges per week (baseline 50 in 45 days → 0,
MacBook included); finished-but-open tabs > 24 h (→ 0); agent spawns not through `rd` (→ 0, from
tab metadata); Task claims outside the ready queue and `rd` (→ 0); implement episodes outside
herdr (326 per 12 days → 0).

CI: a check fails if `rd` opens `ledger.db` (R6).

Gamedays, one set per half of W4 (R2; the halves and their gates are in `waves.md`).

**W4a** — ready queue, claim leases, the `rd` cutover:

- `ledger.db` unreadable or warden unreachable → a spawn carrying a `task_id` is refused and a
  manual `rd wave` still spawns; replaying the spool twice adds 0 rows; in adopt mode 0 spawns.

**W4b** — Witness actions, mothers and leads, the admission module, the MacBook actuator:

- kill and rotate a mother mid-plan → 0 lost or duplicated tasks, 0 owner nudges;
- SIGSTOP a worker past its TTL, re-drive, SIGCONT, and have the revived pane run raw `git commit`,
  `git push` and `gh pr create` → the successor's tree never contains its edits, the push is
  rejected, no PR from it survives, the train merges no head pushed under a stale epoch;
- kill warden between `rd say` and the timer-clear commit, 20 times, across resume, nudge and steer
  → each message appears once in the pane transcript, and a resume admitted before the crash is not
  admitted again;
- a MacBook pane with the lid open, hit by an injected API-error stop, continues through the
  actuator; steer and stop from the phone end `applied` on its acknowledgement; with the lid closed
  they show `host_asleep` and expire on budget; killing only the MacBook recorder with the lid open
  renders stale, not asleep.
