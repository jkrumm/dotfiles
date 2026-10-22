# ADR-007 — Agent topology and lifecycle: mothers for fleets, sessions for the rest, one spawner

- Status: accepted · 2026-10-22
- Evidence: `evidence/projects/classify.out.md` (fleet/session rule), `evidence/questions/questions.md` (50 `continue` nudges, #1 owner action), `evidence/interventions/interventions.md` (26 API-error stalls, median 1.2 h), `evidence/kpi/herdr_hygiene.out.md` (20 finished-but-open tabs), `research/2026-10-22-agents-durable-mcp-otel.md` §2 (Gas Town), Round 5 *Established facts* (326 implement episodes outside herdr in 12 days; Hermes typing `c`/`cf` into panes)

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
   - *Mother* (one per fleet project): keeps the project's ready queue honest — turns new
     Conditions, requests and plan items into Tasks, spawns leads. Never edits code. Rotates daily
     or at the context mark.
   - *Lead* (one per active plan or epic): sequences tasks, spawns workers, handles rebases and
     merge-train returns, reviews worker output against the task's done-definition.
   - *Worker* (one per Attempt): implements and verifies inside its hook, hands back a Change.
   - *Session*: one agent per task for session-class projects and ad-hoc work.
   - *Hermes*: the conversational door; answers from read models, files Tasks, asks the spawner for
     sessions. Never edits code — enforced by its tool allowlist, not by prose (postmortem: prose
     claims held 1 of 11).
3. **One spawner: `rd`.** The only code path that creates a herdr agent. warden, mothers, leads and
   Hermes call it; it writes the Agent and Attempt records, cuts the hook, delivers and verifies the
   brief, and sets tab metadata (role, project, task, origin, engine). Engine per ADR-008.
4. **The hook owns the work** (Gas Town): worktree + branch + base sha + `.factory/attempt.md`
   (task, progress, handover). A successor resumes from the hook, never from a re-prompt.
5. **Witness = the agent reconciler**, deterministic code driven by the herdr event record
   (Phase 0): *parked* (quota limit, transient API error, turn ended with open plan items) →
   auto-resume at the quota reset (durable timer) or after a backoff, or nudge with the plan's next
   step; *stuck* (working, no output past the idle limit) → re-drive from the hook; *dead* (pane
   gone) → resume by session id or re-drive; *finished-but-open* → reap (Phase 0 janitor).
6. **Rotation** at the context mark (~60 %): the agent writes its handover into the hook, the
   spawner starts the successor, the predecessor is reaped. Mothers also rotate daily.
7. **Gas Town, explicitly.** Copy: the hook, Witness, Refinery (warden's merge train), Deacon
   (reconcilers on patrol). Reject: a global Mayor LLM (scheduling is code), idle LLM patrols (≈ 10×
   token cost reported), convoys (Task dependencies), tmux (herdr).

### Consequences

- Good: the #1 owner action (nudging) becomes a timer; implementation leaves agent-gateway (it keeps bounded tool jobs: triage, review, check, prose, investigate's read-only role).
- Bad: mothers are long-lived contexts that need rotation discipline; `rd` becomes critical-path code with its own tests.

### Confirmation

KPIs from read-only scripts: owner `continue` nudges per week (baseline 50 in 45 days → 0);
finished-but-open tabs > 24 h (→ 0); agent spawns not through `rd` (→ 0, from tab metadata);
implement episodes outside herdr (326 per 12 days → 0).
