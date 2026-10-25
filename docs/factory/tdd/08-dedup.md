# 8. Dedup and learning

One cause should be one Issue, and a cause seen before should arrive with its verified fix. The
deterministic part is proven: grouping F1 is 0.889 against warden's 0.744 on a held-out set. "Seen
before" is not proven: v1's known-fix match scored 0.479. Every production platform we looked at
gates grouping deterministically and keeps similarity and judgment beside the gate, not in it. None
exports corrections as labels, so the learning loop is ours to build
(`research/2026-10-24-learned-correlation.md`).

## Two tiers: symptom at intake, cause in the lead

Your comment named the catch: true dedup needs the root cause, and the root cause needs a smart
model. So dedup happens twice:

| Tier | Who | Asks | Cost |
|-|-|-|-|
| **Symptom**, at intake | factory: rules; from W4 a cheap judge, if it passes the bake-off | is this the same thing happening again? | free or one cheap call; never waits |
| **Cause**, during investigation | the lead | do these Issues share a cause? | part of the lead's work; `factory issue merge\|split` with a reason |

Intake only has to catch the obvious repeats: the same monitor flapping, the same error fingerprint
in a window. Two Issues that look different but share a cause are the lead's catch. A lead running in
a project receives *possibly related* signals as notes (§4), so a second lead never starts on the
same cause. A merge stops the absorbed Issue's lead, if one was running, and hands its notes over.

## How a signal finds its Issue

| Step | Decides | How |
|-|-|-|
| **Rules** | most signals | stateful sources (Kuma, Beszel, containers): one episode per subject until the source reads healthy again. Sources are polled, so a missed recovery is caught on the next read. Stateless sources (CI, logs, GitHub issues): the same refined fingerprint within a window. Topology joins a container's failure to its host's |
| **Judge** | the ambiguous rest: two open Issues on related subjects within 30 minutes, or a new Issue whose fingerprint or text matches a recent one | a cheap judge returns the probability that both are the same symptom. ≥ 0.8 attaches, ≤ 0.2 keeps apart, anything between links them as *possibly related*. A failed call keeps them apart; intake never waits |
| **Lead** | everything the cause explains | merge or split, with the reason as a label |

## The judge has to earn its place

Until W4, the judge is off: ambiguous pairs stay apart and are linked as *possibly related*. A wrong
merge hides work, while a missed merge costs one note to a lead, so the judge must be precise
before it may merge anything.

**The W4 bake-off**, on labelled pairs from the golden set plus every merge and split the leads have
made by then:

| Candidate | Context it gets |
|-|-|
| agent-gateway's decision model, one call | a context pack: both Issues' signals, subjects, topology neighbours, timing, the project's recent deploys |
| a DeepSeek session in agent-gateway's OpenCode | the same pack plus read access to the factory database and the logs, to check the symptom further; it returns a probability, never a cause for a lead |

It reports precision and recall on merges and the cost per pair. The winner must reach a merge
precision ≥ 0.95 without dropping grouping F1 below 0.889; if neither does, the judge stays off and
leads keep catching duplicates. Recall can grow later; wrong merges cannot be tolerated.

## Seen before

Each new Issue is matched against closed ones by fingerprint and by Postgres full-text search over
title, the lead's root cause and fix, ranked by project, subject and recency. The top matches go into
the lead's brief as history, marked *past, may not apply* (§4).

## The learning loop

Every grouping decision (by a rule, the judge, a lead or you) is a row in `issue_links` with who and
why. Every closed Issue carries the lead's verified cause and fix. From those, the learn step (a cheap
model) maintains four things:

1. **Labels.** Lead merges are ground truth for what intake missed; lead splits are ground truth for
   what it wrongly joined. A rule whose groups are split more than 10 % of the time over two weeks
   becomes an upkeep Issue.
2. **Known fixes.** Cause and fix per closed Issue, searchable as "seen before".
3. **Runbooks.** A fix verified twice for the same cause and subject (a restart, a cache purge, a
   rerun) becomes an upkeep Issue: "add this as a runbook". A lead adds it to the project's
   `heal:` list through review, and from then on code runs it before any lead is spawned.
4. **Calibration.** The judge's thresholds are re-checked monthly against the labels and the frozen
   golden set; a change is accepted only if F1 stays at or above 0.889.

**Whether it actually learns is measured, not hoped.** You are right that this is the tricky part.
The scorecard (§9) tracks, per month:
- the missed-at-intake rate (lead merges per 100 Issues)
- the wrong-join rate (lead splits)
- the seen-before hit rate (a lead confirms the suggested past cause)
- the runbook share (incidents closed by a runbook, without a lead)

If none of the four improves over two months, the steward opens an Issue that says so.

**Not built until measured need:** embeddings and vector search. They come when full-text matching
misses known fixes you can name, or the split rate says the rules are not enough.
