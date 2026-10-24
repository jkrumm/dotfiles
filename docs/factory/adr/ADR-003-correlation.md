# ADR-003 — Correlation is deterministic; judgment stays with the investigating agent; Keep is not adopted

> **v2 status (2026-10-24):** revised — + decision-model score, investigator merge/split, labels (TDD v2 §8). The text below is v1 history.

- Status: accepted · 2026-10-22 · revised after panel pass 1 and pass 2 (cor-1…cor-7, mig-1, int-11, sre-3, sre-5, ver-8)
- Evidence: `evidence/golden/backtest.out.md` (held-out, scored once; `backtest.py --verify` reproduces every result field. Since two amendments were appended to `PREREGISTRATION.md`, with thresholds unchanged and scoped to future samples, it exits 1 on that file's hash alone. The pre-amendment text still hashes to `3f142e52…`), `spikes/03-correlation/REPORT.md`, `evidence/golden/PREREGISTRATION.md`, `evidence/kpi/decision_shadow.out.md`, `research/2026-10-22-ops-correlation-catalog-eval.md`, `research/2026-10-22-known-error-regression.md`, `evidence/incidents/incidents.md` #6 (the 10-17 timeline)

## Context and problem statement

One outage became 18 pages (10-17); today's warden recall on incident grouping is 0.595. How
should signals and conditions become incidents, where does model judgment belong, and should Keep
be adopted?

## Results — v1, the rule set that was scored (held-out half, against thresholds fixed before any label existed)

Every number in this section describes **v1**: the rules `backtest.py` ran. The revised rules (**v2**,
decision 1) have not been scored, and none of these figures is claimed for them.

| Threshold | v1 (proposed) | Today's warden | Keep-style |
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
the gain over warden does not. **Scope of the pass:** gold groups are chunk-local
(`evidence/golden/LABELS.md`; chunks are bursts with gaps ≤ 30 min), so recall is claimed only for
incidents inside one burst — slow-burn and recurring incidents spanning chunks are unscored. The
uncertain-label reading flips by *detach* only, so the precision pass holds under the detach reading
only; the *join* reading is added for future samples by a dated PREREGISTRATION amendment.
Disclosure: before writing rules the spike listed the ids and notes of
the positive events in both halves to size the problem; it states that no held-out packet was read
for design.

**v1 beside v2.** v2 is v1 plus the changes of decisions 1 and 6.

| Rule set | Split | B-cubed P / R / F1 (labelled) | Source |
|-|-|-|-|
| v1 | held-out (odd chunks), scored once | 0.937 / 0.846 / 0.889 | `backtest.out.md` §1, §4 |
| v1 | development (even chunks), where the parameters were fitted | 0.990 / 0.887 / 0.936 | `backtest.out.md` §2, §4 |
| v2 | development only | not yet scored — `backtest.py` v2 produces it, and its change against v1 is published here, labelled development-only | W3, first deliverable (Confirmation) |
| v2 | held-out | never: the held-out is spent for grouping as well as escalation | — |

## Decision outcome

1. **Grouping is deterministic** — default fingerprint per source plus refinements, dedup, topology
   fold over the manifests' host → container/job → service → project graph, time windows, Keep's
   candidate gate, regression link. The rules and their parameters are stated once, in
   `design/loops.md` §2 (v1's frozen values: `backtest.out.md` §3). Three limits the replay frame
   (events within ±30 min of a sample, one reused row per fingerprint — `backtest.out.md`) cannot
   test were added after the held-out was scored; with decision 6 they define v2:
   - **Windows follow the source kind, in the code's parameters** (cor-2, cor-3; `loops.md` §2.2,
     §2.4): stateful sources run on subject state, stateless ones on `w_dedup`, which also bounds
     them while an incident is open. The scored code ran `w_dedup` (720 min) only on stateless
     families and `w_open` (360 min) on stateful ones; pass 1 gave the 12 h dedup to stateful
     sources, which never ran it, and set stateless dedup to 30 min, a grid value the development
     fit rejected (`backtest.out.md` §3). Window-class splits are the largest class among the ten
     largest held-out split errors (`backtest.out.md` §8), so the v2 value is read off the
     development re-score, not asserted.
   - **The host fold needs host-level evidence, and late evidence merges** (cor-5; `loops.md` §2.3).
     v1 folded on any two distinct infrastructure subjects (`k_host` 2). A boot record exists only
     once the host is back, so evidence arrives after the child signals: a logged, reversible
     `merge` folds the open child incidents under the host incident when it does.
   - **Close by member, with a concrete split** (cor-3, cor-4; `loops.md` §2.5): an incident closes
     when every member's own Condition has resolved, and a member still open after the rest resolved
     splits off. Members with no condition type — chat, requests, issues, log lines — join only by an
     explicit, reversible edge: the four largest held-out merge errors are `fp` merges on chat,
     `hermes_log`, human and chat sources (`backtest.out.md` §8).
2. **Actions are chosen per incident, not per member** (sre-3, sre-5; `loops.md` §2.6): child
   recipes wait for the open host condition and for host reachability and mount checks, and the
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
   W3b builds this rule (int-11). It was designed from held-out misses, so it counts as a new rule
   and is scored on a fresh sample, as a standing SLO, read when the fresh sample reaches its size — never at a wave's gate.
   Promotion and demotion follow the post-deploy hold (ADR-012 §8); a recipe that is not promoted
   goes into the investigator's brief on an exact match.

### Consequences

- Good: one outage is one incident (v1: F1 +0.145 over today); no LLM call per signal; three escalation classes cannot be missed by construction.
- Bad: v2 is unscored until `backtest.py` v2 runs, so v1's numbers support the shape of the design, not the revised rules; escalation and known-error matching are unproven on this data — 6 genuine decisions in 959 events cannot carry a recall estimate; grouping recall is proven only inside one burst and precision only under the detach reading; the parameters were fitted on warden's Slack-heavy stream and run on ADR-013's primary sources.

### Confirmation

- **W3b gate (a) is a fixture regression, not a score.** `backtest.py` v2 — the revised rules behind a
  flag, v1 kept — writes its frozen output for all 959 events, and the live correlator must reproduce
  it event for event; no thresholds (cor-1). v2 is built first: it runs on the development chunks
  only, and its P / R / F1, plus the change in the `fp`-class merge and window-class split masses
  (`backtest.out.md` §8), are published in the table above beside v1, labelled development-only.
  v1 stays reproducible with `backtest.py --verify`. The held-out is declared spent for grouping as
  well as escalation.
- **W3b gate (b) is a replay** (mig-1): a never-labelled window of recorded primary-source history —
  Kuma webhook rows since 10-16, HyperDX alerts, Docker events after the golden set's `AS_OF`, the
  10-17 burst — labelled blind from packets of raw signal text, source time and topology only;
  hinted packets are a second, reported reading. The comparator is old warden's recorded grouping of
  the same signals. The three grouping thresholds of `PREREGISTRATION.md`, unchanged, must pass
  under the labelled, detach and join readings.
- **The sample is fixed before any label exists**, by a dated PREREGISTRATION amendment (cor-7): the
  frame and unit (stratified time windows per source × host, weights from that design, independent
  of any correlator — cor-6), ≥ 400 elements, ≥ 30 decision candidates for escalation, the
  blind-packet fields and the comparator. Cross-burst gold comes from a blind labeller searching ±7 d
  for the same subject, topology ancestor or fingerprint — never along `entity.peers`, which is
  warden's own duplicate chain (`evidence/golden/LABELS.md`). Reported beside the thresholds, not
  gating: B-cubed over non-noise gold groups, and the hidden-incident rate (the weighted share of
  non-noise gold groups whose events all sit inside a predicted group dominated by another gold group).
- **Late host evidence** (cor-5): gameday row 2 replays 10-17 in event order, each piece of host
  evidence entering when it became observable — first Down 20:52:02, boot record 20:56:42
  (`evidence/incidents/incidents.md` #6). Pass: one incident after the `merge`, no recipe fired at the
  unreachable host, 0 pages. An unrelated container crash injected at 0–45 min offsets measures the
  host-fold merge rate (reported).
- **Escalation and known-error thresholds** are standing SLOs, not wave gates (int-11): first measured
  on the fresh sample drawn under the same frame, once ≥ 30 decision candidates exist. The
  gold-label doubts the spike listed (1071/1074/1078/1079, 1372/1373/1380/1381, 1450/1451) are
  re-labelled by two labellers before that test.
