# 8. Dedup and learning

One cause should be one Issue, and a cause seen before should arrive with its fix. The deterministic
part is proven (grouping F1 0.889 against warden's 0.744 on a held-out set); "seen before" is not
(known-fix match 0.479). Every production platform we looked at gates grouping deterministically and
keeps similarity and judgment beside the gate, not in it; none exports corrections as labels, so the
learning loop is ours to build (`research/2026-10-24-learned-correlation.md`).

## How a signal finds its Issue

| Step | Decides | How |
|-|-|-|
| **Rules** | most signals | stateful sources (Kuma, Beszel, containers): one episode per subject until the source reads healthy again — polled, so a missed recovery is caught on the next read; stateless sources (CI, logs, GitHub issues): the same refined fingerprint within a window; topology joins a container's failure to its host's |
| **Score** | the ambiguous rest: two open Issues on related subjects within 30 minutes, or a new Issue whose fingerprint or text matches a recent one | agent-gateway's decision model returns the probability that both share a cause. ≥ 0.8 merges, ≤ 0.2 keeps apart, anything between attaches them as *possibly related* for the investigator. A failed call keeps them apart; intake never waits on it |
| **Investigator** | everything the cause explains | the investigation merges or splits with a reason (`factory issue merge|split`). A merge stops the absorbed Issue's Tasks and sessions; a split starts the new Issue on its own |

## Seen before

Each new Issue is matched against closed ones by fingerprint and by Postgres full-text search over
title, root cause and fix recipe, ranked by project, subject and recency. The top matches, with their
recipes, go into the investigator's brief. A closed Issue whose recipe is a runbook becomes a known
fix: the next occurrence runs it before any investigation.

## The label loop

Every grouping decision — by a rule, the score, the investigator or you — is a row in `issue_links`
with who and why. That gives three things at no extra cost:

1. **A split rate per rule.** A rule whose groups are split more than 10 % of the time over two weeks
   is flagged as an upkeep Issue.
2. **Calibration.** The score's two thresholds are re-checked monthly against the labels and the
   frozen golden set; a change is accepted only if grouping F1 stays at or above 0.889.
3. **Regressions.** A signal matching an Issue closed in the last 30 days re-opens it as a regression,
   linked to the change that closed it.

**Not built until measured need:** embeddings and vector search. They come when full-text matching
misses known fixes you can name, or the split rate says the rules are not enough.
