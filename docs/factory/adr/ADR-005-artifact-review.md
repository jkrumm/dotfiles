# ADR-005 — Artifacts are ours: an `rv` review service with Argo's Artifacts view; plannotator only until it lands

- Status: accepted · 2026-10-22 (revised the same day: owner intent — "a custom implementation for artifacts", Artifacts as an Argo page)
- Evidence: `spikes/05-artifact-review/REPORT.md` (plannotator 24/24, human-review 15/15, `rv` 14/14, `rv-pn` 6/6), `research/2026-10-21-review-tools.md`, `findings-2026-10-22.md` §Artifact review, the owner's prompt

## Context and problem statement

Agents produce plans and reports (Markdown, sometimes HTML) that the owner reads and comments on.
Comments must reach the agent durably, grouped by project, on the phone too — and review is never a
gate: an unanswered review proceeds on a default. The owner asked for a custom implementation that
learns from plannotator, with Artifacts as a page in Argo and basalt-ui maturing alongside.

## Decision drivers

Markdown and HTML; one inbox, grouped by project; durable anchored comments agents read back;
non-blocking (timeout plus default); **Artifacts as an Argo view built from basalt-ui**; **storage per
repo** (the directory contract, ADR-010); phone over the tailnet; one system of record (ADR-011).

## Considered options

- **A — plannotator 0.28.26** on the mini (its Inbox: project-grouped, threads, `wait_for_reply`, `supersedes`, JSONL with a global sequence).
- **B — our review service** behind `rv submit | wait | status | comment`, Argo as its UI.
- **C — `petergyang/human-review` v0.8.2.**

## Decision outcome

**Chosen: B as the target, A as the interim backend.**
- **Contract:** agents call only `rv submit | wait | status | comment` (agent-CLI contract, ADR-004). `rv wait` returns `feedback | closed | superseded | timeout`; on `timeout` the agent proceeds with its stated default.
- **Target (W7):** Artifact entities in the ledger; versions stored per repo in `docs/artifacts/<slug>/`; comments as anchored threads (quote + prefix + suffix, human-review's anchor triple) with resolve; plannotator's semantics copied — `supersedes`, wait-for-reply, a global sequence for read-back. The UI is **Argo's Artifacts view** (project-grouped inbox, the rendered artifact, threads in the margin, phone layout), built from basalt-ui components; the **comment thread is a new basalt-ui export**, in its own PR.
- **Interim (until W7):** plannotator's Inbox behind the same `rv` contract (`spikes/05-artifact-review/rv/rv-pn.ts`), pinned, reached through our own Caddy door (its tailnet path refuses tagged devices).
- **Rejected:** C (closes an unopened review after 60–120 s and tells the agent to stop; a 38 px document column on a 390 px phone).

ADR-005's own build tripwires are met: plannotator denies framing (no Argo embed) and per-repo
storage is an owner requirement.

### Consequences

- Good: one system of record for artifacts and their threads; the owner reviews in the place he already looks; basalt-ui gains a reusable comment thread.
- Bad: ≈ 2.2–2.8k lines to build (spike 5's estimate, about 3 waves of work compressed into W7); plannotator stays a dependency until then — pinned, upgraded only through `/upgrade-deps`.

### Confirmation

The spike's `rv` contract suite runs against both backends in CI; W7's gate is a review round trip
from phone and desktop on the new service, then plannotator is removed.
