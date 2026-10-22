# 10. Open decisions — business only

Five. Each has a default that applies on its expiry date if nobody answers, so none of them
blocks a wave. Everything else in this report is decided.

## D1 — How much IU cash may factory-originated work use? (spend)

- **Why it is a decision now:** Max demand is already 120 % (109–144) of a weekly window per week before any factory judgment (report §2.1, `kpi/forecast`). Mother wakes — a lead is a wake scoped to one plan — therefore run on IU with a Claude-class model unless Max would otherwise lapse (ADR-008).
- **The meter is factory-originated IU only**, tagged by the spawner. The base today is ≈ $28/week (agw OpenCode, `kpi/forecast`; warden-owned items cost ≈ $3.90/day, `kpi/cost`). Not in D1: agw review, research and Hermes ($91, $18 and $4 a week of today's IU) and the spillover of owner-started work to IU, which D2 prices.
- **The price per wake is an assumption:** $2.11 at list price (0.25 × the median wave session, `kpi/forecast`). W4 replaces it — after its first week the per-wake budget is set at the measured p90 × 1.5 and the wake rate becomes the planner's measured trigger rate.
- **A — 3 mother wakes per mother per day** (18 a day, 126 a week): ≈ $266/week at the assumed price, ≈ $294 with the base. That is the first draft's ≈ $300 ceiling restated on this meter: ($300 − $28) ÷ $2.11 ≈ 129 wakes a week. Mothers wake for briefs and unmatched conditions within a per-mother budget; non-urgent judgment queues.
- **B — the forecast's rate, 8 mother wakes per mother per day** (6 mothers × (4 wakes + 1 rotation) plus 3 leads × 6 = 48 a day, 336 a week): ≈ $707/week at the assumed price, ≈ $735 with the base.
- **Tradeoff:** ≈ $441/week more than A, for 5 more wakes per mother per day, against the speed of autonomous judgment work; incidents are never capped either way.
- **Recommendation:** A, then re-decide with 8 weeks of measured wakes and cost per action class × engine. The wake rate is the weak number: doubling it doubles the wake line ($707 → $1,414) and, if the wakes ran on Max, moves the window from 142 % to 164 % (`wake_load_x2`).
- **Default:** A from W4; expires 2026-12-31.

## D2 — Raise the Claude subscription tier? (spend)

- **Context:** Max demand is 120 % (109–144) of a weekly window per week over 30 days, and 4 of 7 complete cycles peaked at 96–100 % (`kpi/forecast`). It fitted only because 2 of 8 resets were unscheduled and Max was down Sep 16–20 (`kpi/quota`). The last 7 days burned at 204 % across two resets — a burn rate, not a window reading. The load is the owner's own, so his sessions are at risk whatever the factory does.
- **The spillover has a measured price.** At a trip the guard moves work in a fixed order (ADR-008): his interactive sessions and the waves he attends keep Max, his unattended waves continue on IU with a Claude-class model, factory fleet work moves to IU or parks, improve chores park. One point of the weekly window moved off Max costs ≈ $2.1 of IU cash ($32.25 list per point × the measured 0.0665 IU-to-list ratio, `kpi/forecast`). Points over 100 % × $2.1 is the upper bound of the spillover: ≈ $19 a week at 109 %, ≈ $43 at 120 %, ≈ $94 at 144 % — ≈ $80, $190 and $410 a month. The ratio comes from the models agent-gateway's OpenCode workload runs on; W4's first week measures a Claude-class model on the IU Anthropic route, and D2 is re-priced then. The rewrite's own lane-A waves land on the same line while they run.
- **A — keep the tier and pay the spillover:** up to the figures above, logged per class (agw review and unattended owner waves at a trip, the rewrite's waves); his heavy weeks still push work off Max.
- **B — raise the tier** (if a higher one exists): the price is the next tier's monthly price, which you read from your account, minus today's. It absorbs the overflow, lets factory judgment use Max and shrinks D1's IU spend.
- **Tradeoff:** the tier's monthly price difference vs the logged IU spillover, plus owner sessions blocked on heavy weeks.
- **Recommendation:** price B from your account now, and compare it with the first four weeks of logged spillover scaled to a month: raise the tier if the spillover is dearer. Until then A.
- **Default:** A; re-decide when his interactive sessions are blocked by the quota on ≥ 1 day in a month (KPI from W4) or when the logged spillover exceeds the tier difference; expires 2026-12-31.

## D3 — May the factory merge and deploy in work repos? (other people)

- **Context:** 20 IuRoot repos (session class, names only here); colleagues review and own those codebases; every work repo is PR-against-main today.
- **A — read, investigate, open PRs;** never merge, deploy or close colleagues' items.
- **B — autonomous merge** where the owner alone works on the repo (e.g. a direct-to-main agent repo), A elsewhere.
- **Tradeoff:** throughput on solo work repos vs touching an employer's systems without a second pair of eyes.
- **Recommendation:** A everywhere until a repo's manifest names the owner as its only maintainer, then B for that repo.
- **Default:** A; no expiry.

## D4 — Who defines "it works" for each product? (product direction)

- **Context:** holdout scenarios (ADR-012) are the end-to-end user stories the verifier runs after each deploy of a fleet product; they encode product intent. Until a project's set binds, its code fixes are opened and verified, not merged (propose-only; report §1b).
- **A — mothers draft them** from each product's docs and history; each set binds 7 days after submission unless the owner edits it.
- **B — the owner writes them.**
- **Tradeoff:** the owner's time vs scenarios that encode an agent's reading of the product.
- **Recommendation:** A; the owner reads one product's set in Argo's Artifacts view when it lands.
- **Default:** A from W5; expires per product 7 days after its scenarios are submitted — the expiry of that product's product-class Decision (ADR-014).

## D5 — What may be deleted, and when? (irreversible data loss)

- **Context:** 18 GB of agent transcripts on the mini, a stale 3.3 GB OpenCode store, two dead `claude --bg` sessions that only `claude rm` removes, warden's pre-migration backups.
- **A — archive, then delete locally after 90 days:** everything goes to the homelab bucket first; restore is one `hl` copy.
- **B — keep everything locally;** the disk budget absorbs it.
- **Tradeoff:** ≈ 20 GB of mini disk and a restore step vs zero risk of losing a local copy.
- **Recommendation:** A.
- **Default:** A from W14; expires 2026-12-31.
