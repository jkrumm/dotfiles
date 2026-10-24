# 8. Dedup, correlation and learning

One cause should be one Issue, and a cause seen before should arrive with its fix. v1 proved the
deterministic part (grouping F1 0.889 vs warden's 0.744 on a held-out set) and failed the "seen
before" part (known-fix match 0.479 against a 0.50 bar). v2 keeps the first and builds a learning
loop for the second.

## What the field does

Every grouping layer that gates in production is deterministic: Keep's fingerprint fields,
incident.io's 10-minute window, Datadog's 20-minute window, PagerDuty's rolling window with a
24-hour incident age and a 5-minute dependency rule. Similarity over past incidents exists only as an
investigator-facing layer, never as the gate. No vendor documents an LLM judging only the ambiguous
residue with a calibrated confidence, and none exports merge and split corrections as labels —
PagerDuty learns from them but refuses corrections made through its API
(`research/2026-10-24-learned-correlation.md`). So the gate stays deterministic, and the learning
loop is ours to build.

## Three tiers

| Tier | Decides | How | Cost |
|-|-|-|-|
| 1. Rules | same Issue or not, for most signals | stateful sources (Kuma, Beszel): the episode stays open until the source reports recovery; stateless sources (CI, logs, issues): the refined fingerprint inside a window; topology joins a container's failure to its host's (v1 `design/loops.md` §2, backtested) | 0 |
| 2. Similarity | which past Issues look like this one | an embedding of title + fingerprint + root cause, ranked by pgvector and fused with project, topology and recency; top 5 attached to the Issue for the investigator, with their fix recipes; the embedding model is picked in W3 (an IU embedding route through agent-gateway, or a local one) | ≈ 0 |
| 3. Judge | the residue tier 1 cannot place: two open Issues on related subjects inside 30 minutes, or a new Issue with a past neighbour above the similarity threshold | one call on DeepSeek V4.1 Flash with both Issues, answering `same`, `related`, `different` or `unsure` plus evidence; `unsure` leaves them apart | ≈ $0.001 a call |

**During investigation**, the agent may merge or split Issues (`factory issue merge|split` with a
reason). The investigation is where the cause becomes known, so it is also where the best grouping
decisions are made.

## The label loop

Every grouping decision is stored as a pair: `(signal or issue a, b, same | different, actor, reason,
time)`, where the actor is tier 1, the judge, the investigator or you. Three uses:

1. **Evaluation.** Per-pattern merge and split counts per week (BigPanda's surface) show which rule
   over- or under-groups. A rule whose groups are split more than 10 % of the time is flagged.
2. **Refit.** Weekly, the windows and the similarity threshold are re-fitted on the labels and
   accepted only if the frozen golden backtest does not drop below 0.889 (W9).
3. **Known fixes.** A closed Issue with a root cause and a fix recipe is a known fix. Tier 2 retrieves
   it; if its runbook is deterministic, the next occurrence runs it before any investigation.

## Regressions

A signal whose fingerprint matches an Issue closed in the last 30 days re-opens that Issue as a
regression instead of creating a new one, linked to the Change that closed it. The investigator
starts from "what did the last fix miss".

## What stays fixed

- The gate is deterministic and replayable: the same signals in the same order give the same Issues.
- The judge never merges on `unsure`, and every judge call is logged with its inputs, so a bad merge is
  traceable and reversible (`factory issue split`).
- The frozen golden set (`evidence/golden/`) is the regression test for any rule change.
