# Factory v2 — where we stand and what changed (source for the audio briefing, 2026-10-24)

Listener: Johannes, who owns this design, wrote the 33 review comments on v1 and will decide whether
the rewrite starts. He read v1 up to the "proof" section and expects the plan to change. Speak to him
directly. No basics, no hype; he dislikes AI-slop and unnecessary technical detail.

## Where we are

- v1 of the factory design was finished on 22 October: a rebuild of warden as reconcilers over a
  SQLite ledger, `project.yaml` per repo, Argo split between the mini and the VPS, five open owner
  decisions. It came with a solid evidence base: 32 % of new items reached Johannes in 14 days
  (74 of 230), about 62 notifications a week, 50 "continue" nudges in 45 days, and only 3.8 % of
  escalations were genuinely his.
- Johannes commented 33 times in the review Inbox plus a global reply. The thrust: drop warden
  completely and start fresh in a new `factory` repo; route all work — not just incidents — through
  one loop; cheap models judge, Claude Code on Max builds; no IU tokens for code; Postgres instead of
  SQLite; maybe DBOS was used wrong; everything on the mini; no Renovate; learn from Swamp, Sandcastle,
  Agent Orchestrator, oh-my-hermes, pstack; pele instead of Mermaid; a unified make contract.
- Since then a second Claude Max subscription went live: `iu` (Max 20x, IU-paid) and `me` (Max 5x,
  personal). A picker chooses the account at spawn with a pace guard and 5-hour balancing; a
  resumed session stays on its account so the prompt cache survives. Herdr work no longer spills to
  IU — it pauses. Today agent-gateway's implement lane moved off IU onto Max as well.
- `iu` is at 88 % of its week until Wednesday 28 October, 17:00; `me` is almost empty.

## The v2 design in one breath

One loop for every piece of work. Deterministic code does everything it can — polling the sources,
dedup rules, grace windows, runbooks, make targets, merge, deploy, rollback — at zero tokens. Cheap
models through agent-gateway (Haiku 5.5, DeepSeek V4.1 Flash, the decision model) score the ambiguous
cases, investigate, plan and review. Claude Code on the two Max accounts writes every line of code,
only in herdr. Verification, never Johannes, gates shipping — and the change under test cannot weaken
it. One new `factory` service runs on the mini: a reconcile loop over Postgres 18, written in Bun.
Argo moves to the mini as its cockpit and reads the same database. Warden is switched off and
deleted, not migrated.

## What changed from v1, and why

1. **New repo, warden deleted.** No history import, no shadow mode, as Johannes asked.
2. **Feature work rides the same loop.** "Add X to weatherorb" in Argo, Hermes, TickTick (tagged
   #factory) or the CLI becomes an Issue, gets planned by a cheap model, waits for capacity, is built
   by a Claude Code session, verified and shipped.
3. **Engines split cleanly.** Herdr is only for Claude Code writing code. Judgment lives in
   agent-gateway's OpenCode sessions, which the factory can resume and steer. v1's open question about
   ≈ $294 a week of IU money for mother wakes is gone; the realistic add-on is ≈ $10–40 a week, mostly
   review, once review-depth gating is switched on.
4. **Capacity in three classes, decided by the existing picker.** Urgent work — production down —
   takes any headroom. Normal work — bugs, requests, planned waves — goes when an account is under its
   weekly pace. Upkeep — upgrades, docs, code health — uses capacity that would otherwise lapse, with a
   floor of one upkeep task per fleet project per week so it never starves. Otherwise tasks wait for
   the reset; nothing spills to IU. The account stays fixed while the prompt cache is warm.
5. **Postgres yes, DBOS no — and why.** Johannes suspected DBOS was used wrong in v1's spike. It was:
   SQLite and a default version setting. Configured right it works. v2 still does not adopt it,
   because the factory is a control plane: every action must first re-read the real world — is the PR
   there, is the container up — which a reconcile loop does by nature, while DBOS replays recorded
   results. The design review found five ways that replay would bite here. The loop also keeps the
   factory on Bun; DBOS's TypeScript SDK needs Node.
6. **Argo all on the mini**, as Johannes recommended: Now, Projects, Factory, Usage, Artifacts. Push
   only for decision cards and the morning briefing. The only alert left in Slack: the mini or the
   factory is down — the factory pushes a heartbeat to the homelab Kuma.
7. **No public endpoint.** The mini can reach the homelab and the VPS, not the other way round, so the
   factory polls every source. A missed recovery is caught on the next read. Sources that can only
   talk to Slack come in through a Slack adapter. Raw Slack alerts are removed source by source.
8. **Dedup learns.** The rules stay (F1 0.889 against warden's 0.744). For the ambiguous rest,
   agent-gateway's decision model returns a probability: high merges, low keeps apart, the middle goes
   to the investigator, who can merge and split. Every decision is a label; embeddings come only when
   the labels say the rules are not enough.
9. **Verification the candidate cannot weaken.** Checks run on the merge result with the base
   branch's own Makefile and tests; acceptance checks are written from the plan by a separate session;
   a deploy must hold for half an hour before it counts; a failed check rolls back to the last deploy
   that held. The factory deploys itself through a small script outside its own loop.
10. **Jobs are small TypeScript scripts** that cost nothing when green. The first five: dependencies
    (planned upgrade waves instead of Renovate), docs and agent setup, code health, infra and backups,
    and the morning briefing — a template, no model.

## The plan

Six waves, safety floor first, about eleven build days in three lanes, then two weeks of observing
the SLOs. Max sets the pace: the whole rewrite costs roughly 20 to 40 percent of one `iu` week.

- W1 Skeleton and safety floor: factory repo, warden deleted, Postgres and the reconcile loop, Kuma
  polled and its Slack alerts removed, the first runbook, heartbeat, nightly backup with a restore
  drill, the factory's own safe deployer. Gate: a stopped container restarts itself within five
  minutes, and killing the factory mid-action never duplicates anything.
- W2 Work path: tasks, the admission classes, workers in herdr, Witness, verification on the merge
  result, merge, deploy, hold, rollback, review-depth gating. Gate: a pre-planned request ships end to
  end; a bad deploy rolls itself back.
- W3 Judgment: investigations, plans, decision cards, dedup scoring, the stuck exit. From here the
  factory builds the rest of itself.
- W4 projects and intake, W5 Argo on the mini with Artifacts, W6 jobs and tooling (generated
  AGENTS.md routing, agent-gateway's MCP removed, `rd` folded into `factory`, pele in the dataviz skill).

Default start: Wednesday 28 October after the `iu` reset, unless Johannes's comments change the
design — or earlier on the `me` account if he says go.

## What is left for Johannes

Nothing is waiting on him. Five choices he may want to override before their wave: the reconcile
loop instead of DBOS; TypeScript instead of Python with cyclopts; fleet mothers only for multi-wave
plans, fresh workers for everything else; the CLI name `factory`; Argo web push instead of ntfy. A
third subscription is his call whenever: another Claude account is one config line; a ChatGPT plan
would add Codex as a second code engine from another model family.
