# ADR-005 — Artifacts are ours: ledger threads behind `warden artifact`, Argo's Artifacts view; plannotator only until it lands

> **v2 status (2026-10-24):** revised — Artifacts in Argo at W5; no `rv` (TDD v2 §10). The text below is v1 history.

- Status: accepted · 2026-10-22 (revised the same day: owner intent — "a custom implementation for artifacts", Artifacts as an Argo page; revised after panel pass 1: dat-2 / sim-5, sim-1 — the ledger is the only SoR for threads, `rv` folds into the factory CLI; after pass 2: int-8, int-14 — owner comment and resolve events are the ledger fact the ladder reads, wording aligned with the directory contract)
- Evidence: `spikes/05-artifact-review/REPORT.md` (plannotator 24/24, human-review 15/15, `rv` 14/14, `rv-pn` 6/6), `research/2026-10-21-review-tools.md`, `findings-2026-10-22.md` §Artifact review, the owner's prompt

## Context and problem statement

Agents produce plans and reports (Markdown, sometimes HTML) that the owner reads and comments on.
Comments must reach the agent durably, grouped by project, on the phone too — and review is never a
gate: an unanswered review proceeds on a default. The owner asked for a custom implementation that
learns from plannotator, with Artifacts as a page in Argo and basalt-ui maturing alongside.

## Decision drivers

Markdown and HTML; one inbox, grouped by project; durable anchored comments agents read back;
non-blocking (timeout plus default); **Artifacts as an Argo view built from basalt-ui**; **storage per
repo** (the directory contract, `design/model.md` §6.1); phone over the tailnet; one system of record (ADR-011).

## Considered options

- **A — plannotator 0.28.26** on the mini (its Inbox: project-grouped, threads, `wait_for_reply`, `supersedes`, JSONL with a global sequence).
- **B — our own artifact module** behind `submit | wait | status | comment`, Argo as its UI.
- **C — `petergyang/human-review` v0.8.2.**

## Decision outcome

**Chosen: B as the target, A as the interim backend.**
- **Contract:** agents call only `warden artifact submit | wait | status | comment` (agent-CLI contract, ADR-004; spike 5's `rv` verbs, unchanged, now a module of the factory CLI and API — no separate service, sim-1). `wait` returns `feedback | closed | superseded | timeout`; on `timeout` the agent proceeds with its stated default.
- **Target (W7):** one system of record per part, no third store:
  - **Threads:** the ledger only — Artifact entities plus comment events carrying the anchor triple (quote + prefix + suffix, human-review's) and resolve. `threads.jsonl` is dropped; a thread is rebuilt from events alone. Every comment and resolve is an event with its actor: one with actor `owner` on a plan Artifact is the ledger fact ADR-012 reads as "traces to the owner" for product-class Changes (int-8). It is evidence for the ladder, never a gate.
  - **Versions:** git, as `path@sha` (`vN.md|html`) under `docs/artifacts/<slug>/` (directory contract, `design/model.md` §6.1), committed by the **submitting agent** through the normal Change path. The artifact module never commits, so a comment from the phone writes 0 commits on any branch, and IuRoot's linked paths receive nothing from it.
  - **Semantics and UI:** plannotator's semantics copied — `supersedes`, wait-for-reply, a global sequence for read-back. The UI is **Argo's Artifacts view** (project-grouped inbox, the rendered artifact, threads in the margin, phone layout), built from basalt-ui components; the **comment thread is a new basalt-ui export**, in its own PR.
- **Interim (until W7):** plannotator's Inbox behind the same contract (`spikes/05-artifact-review/rv/rv-pn.ts`), pinned, reached through our own Caddy door (its tailnet path refuses tagged devices).
- **Rejected:** C (closes an unopened review after 60–120 s and tells the agent to stop; a 38 px document column on a 390 px phone).

ADR-005's own build tripwires are met: plannotator denies framing (no Argo embed) and per-repo
storage is an owner requirement.

### Consequences

- Good: one system of record each for threads (ledger) and versions (git), one writer of git (the Change path); no review service to run; the owner reviews in the place he already looks; basalt-ui gains a reusable comment thread.
- Bad: ≈ 2.2–2.8k lines to build (spike 5's estimate for a standalone service, about 3 waves of work compressed into W7; folding it into warden drops the service, LaunchAgent and backup from its ops column; smaller than the spike's standalone estimate, by an amount W7 measures); plannotator stays a dependency until then — pinned, upgraded only through `/upgrade-deps`.

### Confirmation

The spike's `rv` contract suite runs against both backends in CI; W7's gate is a review round trip
from phone and desktop on `warden artifact` (the phone comment lands as an event with actor
`owner`), plus the drop-and-rebuild test (delete every thread projection, rebuild from ledger
events, byte-identical) and a phone comment on an artifact in a PR-required repo and in an IuRoot
repo leaving `git status` clean in both; then plannotator is removed.
