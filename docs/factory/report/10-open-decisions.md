# 10. Open decisions — business only

Five. Each has a default that applies on its expiry date if nobody answers, so none of them
blocks a wave. Everything else in this report is decided.

## D1 — How much IU cash may factory-originated work use? (spend)

- **Why it is a decision now:** owner-started work alone fills the Max window — fleet waves 74 % plus interactive sessions 32 % of a weekly window per week, 120 % in total over 30 days, 204 % over the last 7 (`kpi/forecast`). Factory judgment (mother and lead wakes, attempt ≥ 3 escalations) therefore runs on IU with a Claude-class model unless Max would otherwise lapse (ADR-008).
- **Measured:** all IU today $147/week (agw tools $91, agw OpenCode $28, research $18, Hermes $4; `kpi/forecast`); warden-owned items cost ≈ $3.90/day (`kpi/cost`).
- **Projected at the forecast's assumption** (336 wakes a week at ≈ $2.11 — an assumption, not a measurement): mothers and leads add ≈ $707/week; moving agw review off Max adds up to ≈ $469/week. Full design on IU: ≈ $1,320/week.
- **A — cap factory IU at ≈ $300/week** (twice today's IU): mothers wake for briefs and unmatched conditions within a per-mother budget; non-urgent judgment queues; review stays on Max while the forecast allows.
- **B — ≈ $1,320/week:** mothers and leads wake at the forecast rate; review moves to IU.
- **Tradeoff:** ≈ $4,000 a month at the upper bound vs speed of autonomous judgment work; incidents are never capped either way.
- **Recommendation:** A, then re-decide with 8 weeks of measured wakes and cost per action class × engine — the wake rate is the weak number (doubling it moves the Max-only projection from 142 % to 164 %).
- **Default:** A from W4; expires 2026-12-31.

## D2 — Raise the Claude subscription tier? (spend)

- **Context:** Max ran at 120 % of a weekly window per week over 30 days and 204 % over the last 7; it fitted only because 2 of 8 resets were unscheduled and Max was down Sep 16–20 (`kpi/forecast`, `kpi/quota`). Owner-started work alone exceeds the window on heavy weeks, so his own sessions are at risk whatever the factory does.
- **A — keep the tier:** the factory stays off Max except to use capacity that would lapse; the owner's heavy weeks still hit the limit.
- **B — raise the tier** (if a higher one exists): absorbs owner-started load, lets factory judgment use Max, and shrinks D1's IU spend.
- **Tradeoff:** a higher subscription vs IU cash for factory judgment and owner sessions blocked on heavy weeks.
- **Recommendation:** B is worth pricing now: the measured load is the owner's own, not the factory's.
- **Default:** A; re-decide when the owner's sessions are blocked by the quota on ≥ 1 day in a month (KPI from W4); expires 2026-12-31.

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
