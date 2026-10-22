# ADR-003 — Correlation is deterministic; judgment stays with the investigating agent; Keep is not adopted

- Status: accepted · 2026-10-22
- Evidence: `evidence/golden/backtest.out.md` (held-out, scored once; `backtest.py --verify` reproduces it), `spikes/03-correlation/REPORT.md`, `evidence/golden/PREREGISTRATION.md`, `evidence/kpi/decision_shadow.out.md`, `research/2026-10-22-ops-correlation-catalog-eval.md`, `research/2026-10-22-known-error-regression.md`

## Context and problem statement

One outage became 18 pages (10-17); today's warden recall on incident grouping is 0.595. How
should signals and conditions become incidents, where does model judgment belong, and should Keep
be adopted?

## Results (held-out half, against thresholds fixed before any label existed)

| Threshold | Proposed | Today's warden | Keep-style |
|-|-|-|-|
| B-cubed precision ≥ 0.90 (labelled / uncertain flipped) | 0.937 / 0.902 **pass** | 0.993 | 0.968 |
| B-cubed recall ≥ 0.80 | 0.846 / 0.881 **pass** | 0.595 | 0.595 |
| F1 above warden | 0.889 vs 0.744 **pass** (+0.145, 95 % CI +0.098…+0.194) | — | 0.737 (singletons score 0.740) |
| Owner touch ≤ 1 % of items | 0.62 % **pass** | 14.09 % | 0.62 % |
| Known-error false match ≤ 0.05 | 0.007 **pass** | 0 | 0 |
| Known-error match ≥ 0.50 | 0.479 **fail** | 0 | 0 |
| Escalation recall 1.00 | **fail** (1 genuine decision in the held-out half; the miss is labelled uncertain) | fail | fail |
| Escalation precision ≥ 0.80 | **fail** (0 / 4) | 0 / 57 | 0 / 4 |

Ablations: without topology F1 falls to 0.850, without per-source refinements to 0.713. The 95 %
intervals of held-out precision [0.893, 0.970] and recall [0.797, 0.890] straddle their thresholds;
the gain over warden does not. Disclosure: before writing rules the spike listed the ids and notes of
the positive events in both halves to size the problem; it states that no held-out packet was read
for design.

## Decision outcome

1. **Grouping is deterministic** — default fingerprint per source plus refinements, dedup, topology
   fold over the manifests' host → container/job → service → project graph, time windows, Keep's
   candidate gate, regression link. Parameters frozen from the development half (topology window
   45 min, dedup 12 h, open window 6 h, recurrence 7 d, reopen 10 min, similarity fallback θ 0.2
   within 4 h, candidate gate T 30 min / N 1).
2. **Keep is not adopted:** its model — partial dedup on fingerprint fields plus attribute rules,
   no topology graph, no known errors — scored no better than leaving every event alone.
3. **Model judgment stays where it is judgment, not classification:** the decision model agreed 92 %
   with warden's LLM triage but 60 % with the true grouping (LLM triage itself 62 %), so no
   single-shot model groups or triages. Judgment lives in the **investigating agent** (root cause,
   recipe choice among known errors, the decision class) — an investigate worker on OpenCode/IU in
   herdr (ADR-008).
4. **Escalation is structural, not keyword-matched.** The keyword policy overfit five development
   positives. Instead: the investigator's verdict carries a typed `decision_class` (none | product |
   spend | data_loss | other_people) with question, options and default (ADR-014); and **three of the
   four classes are guaranteed by capability limits** — the tools that delete data irreversibly, spend
   money or contact other people refuse to run without an open owner Decision of that class. Product
   direction remains the agent's call, visible in Argo's digest, with a reversible default.
5. **Known errors:** a fixing Change is attached to its incident at closure (not inferred from notes);
   fingerprints are normalised across sources through the topology subject, so a Kuma monitor, its
   Slack relay and a HyperDX alert share priors (the misses were cross-source: 1449→1458, 1585→1497).

### Consequences

- Good: one outage is one incident (F1 +0.145 over today); no LLM call per signal; three escalation classes cannot be missed by construction.
- Bad: escalation and known-error matching are unproven on this data — 6 genuine decisions in 959 events cannot carry a recall estimate.

### Confirmation

W3's gate re-runs the frozen backtest on the live code (same held-out numbers). Escalation and
known-error thresholds are re-tested on a **fresh labelled sample** of live events once ≥ 30 genuine
decision candidates exist (new held-out; the old one is spent). The gold-label doubts the spike listed
(1071/1074/1078/1079, 1372/1373/1380/1381, 1450/1451) are re-labelled by two labellers before that test.
