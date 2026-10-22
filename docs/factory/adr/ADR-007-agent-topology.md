# ADR-007 — Agent topology and lifecycle: on-demand mothers for fleets, sessions for the rest, one spawner

- Status: accepted · 2026-10-22 · revised after panel pass 1 (int-1, sim-3, sim-6, sim-7, ux-1, cos-4, ver-5, dur-2)
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
     ready queue + `rd`) stays code. The mother spawns leads, never edits code, and rotates through
     the hook at the context mark.
   - *Lead* (one per active plan or epic): sequences tasks, spawns workers, handles rebases and
     merge-train returns, reviews worker output against the task's done-definition.
   - *Worker*: an Agent with a `task_id` and its hook; implements and verifies inside the hook,
     hands back a Change. Attempt is dropped as a noun (sim-3): a Task's attempts are its worker
     Agents.
   - *Session*: one agent per task for session-class projects and ad-hoc work.
   - *Hermes*: the conversational door; answers from read models, files Tasks, asks the spawner for
     sessions. Never edits code — enforced by its tool allowlist, not by prose (postmortem: prose
     claims held 1 of 11).
3. **One spawner: `rd`.** The only code path that creates a herdr agent. warden, mothers, leads and
   Hermes call it; it writes the Agent record (optional `task_id`), cuts the hook, delivers and
   verifies the brief, and sets tab metadata (role, project, task, origin, engine). Engine per
   ADR-008. Every spawn is admitted through one **admission queue** ordered incident >
   owner-started > fleet > improve, at the token rate the ADR-008 forecast sets — so resumes at a
   quota reset never burst (cos-4).
4. **The hook owns the work** (Gas Town): worktree + branch + base sha + `.factory/attempt.md`
   (task, progress, handover) + the lease **epoch**. A successor resumes from the hook, never from
   a re-prompt.
5. **Witness = the agent reconciler**, deterministic code driven by the herdr event record
   (Phase 0): *parked* (quota limit, transient API error, turn ended with open plan items) →
   auto-resume at the quota reset (durable timer, through the admission queue) or after a backoff,
   or nudge with the plan's next step; *stuck* (working, no output past the idle limit) → re-drive
   from the hook; *dead* (pane gone) → resume by session id or re-drive; *finished-but-open* → reap
   (Phase 0 janitor). Auto-continues and re-drives count against the Task's and lineage's budget in
   attempts, IU dollars and Max percent, with backoff — never wall clock; exhaustion opens the
   breaker for that lineage (ver-5, ADR-012).
6. **Re-drive is fenced** (dur-2). Every lease grant (task claim, agent) issues an **epoch**,
   written into the hook; every mutating call carries it and a stale epoch is rejected; git effects
   are fenced by `push --force-with-lease=<ledger sha>` and merge `sha=`. A re-drive successor is
   granted only after the predecessor's process is confirmed dead or its lease fenced — a pane
   frozen by a TCC dialog or herdr's own `claude --resume` cannot act beside its successor.
7. **Rotation** at the context mark (~60 %): the agent writes its handover into the hook, the
   spawner starts the successor, the predecessor is reaped. A mother's rotation is the same path;
   with on-demand sessions there is no daily restart.
8. **Two herdr hosts, one record** (ux-1). The Phase 0 herdr event recorder also runs on the
   MacBook and pushes to the mini's ingest when online; while the laptop is closed its agents carry
   `host_asleep since hh:mm`. shutterflow's fleet stays on the MacBook (Mac-only work) and is
   observed, not moved.
9. **agw is a bounded tool server, no loop** (sim-6). Before W8 its `decide`, `triage`,
   `narrative` and `investigate` tools are deleted; W8 wraps review, check, prose, read_image and
   read_drawing.
10. **Gas Town, explicitly.** Copy: the hook, Witness, Refinery (warden's merge train), Deacon
    (reconcilers on patrol), persistent identity with ephemeral sessions (the mother). Reject: a
    global Mayor LLM (scheduling is code), idle LLM patrols (≈ 10× token cost reported), convoys
    (Task dependencies), tmux (herdr).

### Tradeoff: mothers (int-1 with sim-7)

The owner asked for mothers on the big projects; the simplifier showed a resident mother
duplicates the code that already turns Conditions and plan items into Tasks. Kept: one mother
identity per fleet project, its continuity in the hook, leads spawning workers, handover and
rotation through the hook. Given up: an idle resident context per project — the mother runs only
when the planner wakes it. W4 builds mothers and leads explicitly.

### Consequences

- Good: the #1 owner action (nudging) becomes a timer, MacBook agents included; implementation leaves agent-gateway (it keeps bounded tool jobs: review, check, prose, read_image, read_drawing); no resident mother contexts burn Max between wakes.
- Bad: `rd`, the admission queue and epoch fencing are critical-path code with their own tests; a mother's wake carries hook-reload cost every time.

### Confirmation

KPIs from read-only scripts: owner `continue` nudges per week (baseline 50 in 45 days → 0,
MacBook included); finished-but-open tabs > 24 h (→ 0); agent spawns not through `rd` (→ 0, from
tab metadata); implement episodes outside herdr (326 per 12 days → 0).
Gamedays (W4): kill and rotate a mother mid-plan → 0 lost or duplicated tasks, 0 owner nudges;
SIGSTOP an agent past its TTL, re-drive, SIGCONT → every stale call rejected, 0 commits land.
