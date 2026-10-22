# ADR-005 — Artifact review: plannotator's Inbox behind our own `rv` contract

- Status: accepted · 2026-10-22
- Evidence: `spikes/05-artifact-review/REPORT.md` (exercise scripts: plannotator 24/24, human-review 15/15, rv 14/14, rv-pn 6/6), `research/2026-10-21-review-tools.md`, `findings-2026-10-22.md` §Artifact review

## Context and problem statement

Agents produce plans and reports (Markdown, sometimes HTML) that the owner sometimes wants to
read and comment on. Comments must reach the agent durably, grouped by project, readable on the
phone — and review must never become a gate: the owner decides business questions only, so an
unanswered review proceeds on a default.

## Decision drivers

Markdown and HTML; one inbox across sessions and projects; durable comments agents read back;
non-blocking (timeout plus default); Argo integration; phone over the tailnet; little to operate.

## Considered options

- **A — plannotator 0.28.26** on the mini (its Inbox: project-grouped, threads, `wait_for_reply`, `supersedes`, JSONL with a global sequence).
- **B — build a review service** (Bun + SQLite + per-repo docs dir; `rv submit` / `rv wait`; anchored threads; project inbox).
- **C — `petergyang/human-review` v0.8.2.**

## Decision outcome

**Chosen: A's Inbox behind B's contract.** Agents call only `rv submit | wait | status`
(`spikes/05-artifact-review/rv/rv-pn.ts`, 51 lines, survives an Inbox crash). `rv wait` returns
`feedback | closed | superseded | timeout`; on `timeout` the agent proceeds with its stated default.
A projector mirrors Inbox events into the event log as Artifact events, so Argo's Artifacts view
and the reconcilers read the ledger, never the Inbox's files directly.

### Consequences

- Good: the expensive parts (inbox, anchoring UI, HTML rendering, phone layout, durable JSONL) are adopted, not built (building B ≈ 2.2–2.8k lines, about 3 waves).
- Bad: one maintainer shipping 34 releases in 30 days — pin the version and upgrade through `/upgrade-deps`; framing is denied, so Argo links out instead of embedding; the vendor's tailnet path refuses tagged devices, so the phone uses our own Caddy door.
- C is rejected (closes an unopened review after 60–120 s and tells the agent to stop; a 38 px document column on a 390 px phone); copy its anchor triple and its "agent listening" indicator.

### Confirmation

The `rv` contract tests run in CI against the pinned version. Tripwires to build B: the pinned
plannotator breaks the contract twice in a quarter, the project goes quiet for 90 days, or a
needed capability (Argo embed, per-repo storage) cannot be added upstream.
