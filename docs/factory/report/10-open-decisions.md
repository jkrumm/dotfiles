# 10. Open decisions — business only

Five. Each has a default that applies on its expiry date if nobody answers, so none of them
blocks a wave. Everything else in this report is decided.

## D1 — How much IU spend may the factory use for non-urgent work? (spend)

- **Context:** the factory's IU spend today is ≈ $34/day (agw direct calls $23, agw OpenCode $7, research $4; `kpi/cost`, usage-tracker since 10-14). Moving implementation into herdr (W7) keeps routine fixes on IU; the improve and heal jobs (W12) add more.
- **A — $30/day cap** on non-urgent IU work: today's level; improve jobs queue behind incidents.
- **B — $60/day cap:** the improve loop runs daily without waiting; ≈ $900/month more at the ceiling.
- **Tradeoff:** speed of non-urgent improvement vs ≈ $900/month at the ceiling. Incidents are never capped either way.
- **Recommendation:** A, revisit with 8 weeks of cost-per-resolved-item data.
- **Default:** A from W7; expires 2026-12-31 (then the measured spend decides).

## D2 — Raise the Claude subscription tier? (spend)

- **Context:** the 7-day window sat at p90 96 % and ≥ 90 % on 12 of 45 days; the owner's own sessions share it (`kpi/quota`).
- **A — keep the tier;** the quota guard routes non-urgent work to IU and reserves 15 % for the owner.
- **B — raise the tier** (if a higher one exists): more judgment-heavy work on Claude, fewer reroutes.
- **Tradeoff:** subscription cost vs quality on work the guard sends to IU models.
- **Recommendation:** A; switch to B if the owner's own sessions are blocked by the quota on ≥ 1 day in a month after W7.
- **Default:** A; expires 2026-12-31.

## D3 — May the factory merge and deploy in work repos? (other people)

- **Context:** 20 IuRoot repos (session class, names only here); colleagues review and own those codebases; every work repo is PR-against-main today.
- **A — read, investigate, open PRs;** never merge, deploy or close colleagues' items.
- **B — autonomous merge** where the owner alone works on the repo (e.g. a direct-to-main agent repo), A elsewhere.
- **Tradeoff:** throughput on solo work repos vs touching an employer's systems without a second pair of eyes.
- **Recommendation:** A everywhere until a repo's manifest names the owner as its only maintainer, then B for that repo.
- **Default:** A; no expiry.

## D4 — Who defines "it works" for each product? (product direction)

- **Context:** holdout scenarios (ADR-012) are the end-to-end user stories the verifier runs after each deploy of a fleet product; they encode product intent.
- **A — leads draft them** from each product's docs and history; binding after 7 days unless the owner edits.
- **B — the owner writes them.**
- **Tradeoff:** the owner's time vs scenarios that encode an agent's reading of the product.
- **Recommendation:** A; the owner reads one product's set in Argo's Artifacts view when it lands.
- **Default:** A from W8; expires per product 7 days after its scenarios are submitted.

## D5 — What may be deleted, and when? (irreversible data loss)

- **Context:** 18 GB of agent transcripts on the mini, a stale 3.3 GB OpenCode store, two dead `claude --bg` sessions that only `claude rm` removes, warden's pre-migration backups.
- **A — archive, then delete locally after 90 days:** everything goes to the homelab bucket first; restore is one `hl` copy.
- **B — keep everything locally;** the disk budget absorbs it.
- **Tradeoff:** ≈ 20 GB of mini disk and a restore step vs zero risk of losing a local copy.
- **Recommendation:** A.
- **Default:** A from W14; expires 2026-12-31.
