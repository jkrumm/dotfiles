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
| **Symptom**, at intake | factory: rules; a cheap judge once its shadow run earns trust | is this the same thing happening again? | free or one cheap call; never waits |
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

## The judge: shadow first, then trusted

There is one candidate and no contest: agent-gateway's decision model, one call per ambiguous pair,
with a context pack of both Issues' signals, subjects, topology neighbours, timing and the project's
recent deploys. It returns a probability, never a cause.

| Stage | From | What the judge may do | Moves on when |
|-|-|-|-|
| **Off** | W1 | nothing; ambiguous pairs stay apart, linked as *possibly related* | intake goes live (W2) |
| **Shadow** | W2 | logs its verdict on every ambiguous pair and acts on none; the leads' merges and splits label the truth | merge precision ≥ 0.95 over at least 30 labelled pairs, grouping F1 still ≥ 0.889 |
| **Trusted** | when earned | ≥ 0.8 attaches, ≤ 0.2 keeps apart, anything between links as *possibly related* | precision falls below 0.95 over the last 30 pairs: back to shadow |

A wrong merge hides work, while a missed merge costs one note to a lead, so precision is the gate and
recall can grow later. If the judge never earns trust, nothing is lost: the leads keep catching
duplicates by cause, as they do from W1. Only if shadow mode shows the judge failing for lack of
context would a richer judge (a DeepSeek session in OpenCode that can query the logs) be tried, and
then through the same shadow stage.

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

If none of the four improves over two months, the orchestrator opens an Issue that says so.

**Not built until measured need:** embeddings and vector search. They come when full-text matching
misses known fixes you can name, or the split rate says the rules are not enough.
