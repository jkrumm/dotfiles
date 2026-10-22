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
the gain over warden does not. **Scope of the pass** (panel pass 1): gold groups are chunk-local
(`evidence/golden/LABELS.md`; chunks are bursts with gaps ≤ 30 min), so recall is claimed only for
incidents inside one burst — slow-burn and recurring incidents spanning chunks are unscored. The
uncertain-label reading flips by *detach* only, so the precision pass holds under the detach reading
only; the *join* reading is added for future samples by a dated PREREGISTRATION amendment.
Disclosure: before writing rules the spike listed the ids and notes of
the positive events in both halves to size the problem; it states that no held-out packet was read
for design.

## Decision outcome

1. **Grouping is deterministic** — default fingerprint per source plus refinements, dedup, topology
   fold over the manifests' host → container/job → service → project graph, time windows, Keep's
   candidate gate, regression link. Parameters frozen from the development half (topology window
   45 min, dedup 12 h, open window 6 h, recurrence 7 d, reopen 10 min, similarity fallback θ 0.2
   within 4 h, candidate gate T 30 min / N 1), with three limits the replay frame (events within
   ±30 min of a sample, one reused row per fingerprint — `backtest.out.md`) cannot test:
   - **Windows by source kind.** The long windows (dedup 12 h, open 6 h, similarity 4 h) apply only
     to stateful sources whose recovery signal closes the episode (Kuma Up, Beszel recovery).
     Stateless sources (CI failures, log lines, issues) get dedup ≤ 30 min and open ≤ 60 min. A
     longer link is an explicit, undoable edge the investigator proposes.
   - **Host fold needs host-level evidence** — a boot record, a Beszel host-down, a Docker daemon
     event, or ≥ 50 % of the host's monitored subjects firing. Otherwise a fold goes no higher than
     service/project.
   - **Close by member.** An incident closes only when every member's own Condition has resolved; a
     `split` operation detaches a member whose condition outlives the group, timeline kept.
2. **Actions are chosen per incident, not per member.** While a topology ancestor has an open host
   condition (boot, mount, reachability), child recipes are held for the host's hold window and the
   host runbook runs first.
3. **Keep is not adopted:** its model — partial dedup on fingerprint fields plus attribute rules,
   no topology graph, no known errors — scored no better than leaving every event alone.
4. **Model judgment stays where it is judgment, not classification:** the decision model agreed 92 %
   with warden's LLM triage but 60 % with the true grouping (LLM triage itself 62 %), so there is
   **no single-shot decision model anywhere in the loop** — none groups, triages or handles a
   residue. The owner's "decision models" become the **investigate worker** on OpenCode/IU in herdr
   (ADR-008), making the judgment calls: root cause, recipe choice among known errors, the
   `decision_class`.
5. **Escalation is structural, not keyword-matched.** The keyword policy overfit five development
   positives. Instead: the investigator's verdict carries a typed `decision_class` (none | product |
   spend | data_loss | other_people) with question, options and default (ADR-014); and **three of the
   four classes are guaranteed by capability limits** — the tools that delete data irreversibly, spend
   money or contact other people refuse to run without an open owner Decision of that class. Product
   direction remains the agent's call, visible in Argo's digest, with a reversible default.
6. **Known errors:** a fixing Change is attached to its incident at closure (not inferred from notes);
   fingerprints are normalised across sources through the topology subject, so a Kuma monitor, its
   Slack relay and a HyperDX alert share priors (the misses were cross-source: 1449→1458, 1585→1497).
   This rule was designed from held-out misses, so it is scored as a new rule on the fresh sample. A
   recipe is promoted to automatic reuse only after the post-deploy hold confirms it — per condition
   type, ≥ 2 × the fingerprint's median inter-occurrence gap and ≥ 24 h for crash, OOM and flap types
   (ADR-012); until then an exact match puts the recipe in the investigator's brief.

### Consequences

- Good: one outage is one incident (F1 +0.145 over today); no LLM call per signal; three escalation classes cannot be missed by construction.
- Bad: escalation and known-error matching are unproven on this data — 6 genuine decisions in 959 events cannot carry a recall estimate; grouping recall is proven only inside one burst and precision only under the detach reading; the parameters were fitted on warden's Slack-heavy stream and run on ADR-013's primary sources.

### Confirmation

- **W3 gate:** the frozen held-out becomes a **byte-level regression check of the correlator code**
  (the held-out numbers reproduce exactly on the live code). The held-out is declared spent for
  grouping as well as escalation.
- **Grouping acceptance** moves to a **fresh post-cutover sample**, labelled from **blind packets**
  (raw signal text, source time, topology only); hinted packets are a second, reported reading.
  Cross-burst gold is built for it: labellers join groups across adjacent chunks using
  `entity.peers`. It passes under the labelled, detach and join readings.
- **Escalation and known-error thresholds** are re-tested on the same fresh sample once ≥ 30
  genuine decision candidates exist. The gold-label doubts the spike listed (1071/1074/1078/1079,
  1372/1373/1380/1381, 1450/1451) are re-labelled by two labellers before that test.
