# Synthesis: from memos to decisions and documents

The shape of the handover page (`synthesis-handover.md` in the lens folder) and of the run it describes. The first
instance is `~/SourceRoot/brain/wiki/weatherorb/lenses-2026-11/synthesis-handover.md`: copy its sections, replace its
content.

**Status: designed, first run pending.** The research half of the skill ran end to end on 2026-11-14. This half has
not. After a synthesis run, correct this page with what held and what did not.

## Why it is staged

In the first run 86 memos held about 400,000 words. No context holds that, and a summary of summaries loses the detail the owner asked
for. So agents read, files carry the state, and the lead decides instead of summarizing. The lead's own reading is the
brief, the index and the `digest` view (about 200 words per lens), then `challenges` and `owner`.

## What the handover page contains

| Section | Content |
|-|-|
| The job | what the memos are, what the owner asked for in his words, and "done" as four checkable statements: every decision written once with options, positions, evidence and verdict; every contradiction resolved or handed to the owner with a default; every "must" traced or rejected with a reason; the document set reviewed and filed |
| The material | where the memos, views, prior research, rulings and contracts are |
| The stages | the table below, then one subsection per stage |
| The thread table | 10 to 14 decision threads; every lens is primary in exactly one, secondary where its verdicts bear |
| Leads | what the experts' return values already show: rulings several lenses challenge in the same direction, conflicts between lenses, facts that change a tool choice. Marked as leads to verify in the memos |
| Rules of the run | the limits and habits under "Rules" in `SKILL.md` |

## The stages

| Stage | Who | Agents | Output |
|-|-|-|-|
| 1 Orient | the lead, inline | 0 | the thread table, adjusted |
| 2 Dossiers | one agent per thread | 10 to 14 | one dossier per thread |
| 3 Cross-examination | one agent per task | about 15 | ledgers of contradictions, open handoffs, orphans, unmitigated risks |
| 4 Decide | the lead, inline | 0 | the decision ledger, the owner's list, the experiment programme |
| 5 Write | one agent per document | about 12 | the document set |
| 6 Review, deliver | one agent per role | about 8 | findings, fixes, the filed Spec |

**Dossiers.** A thread is a set of decisions that must be taken together (for example grid, bands, regridding and
coast). Its agent reads the primary memos in full and pulls `options`, `guarantees` and `handoffs` of the secondary
lenses. Per decision it writes: the question; every option, including those a lens rejected; each lens's position
with number and section; the evidence and its grade (verified, measured, prior, assumed); a proposed verdict; what the
verdict forces in other threads; how it fails and how one would notice; the cost at ten times the scale; the experiment
that would overturn it, with the deciding number; one-way door or reversible. Then the thread's requirements,
deduplicated, each with its source. Rules: no verdict by majority, the evidence grade decides; at equal grade the
option that is cheaper to reverse wins and its experiment is marked as owed; where two lenses disagree, quote both;
never soften a number.

**Cross-examination.** Threads overlap on purpose, so two dossiers that rule differently on a shared edge expose a
contradiction. One agent per task:

- contradictions, one agent per pair of dossiers that share an edge, and one that holds the scope thread against all
  others;
- handoffs: what a lens asked a neighbour to settle and nobody settled;
- coverage: every "must" of the `guarantees` view mapped to a dossier decision, or listed as an orphan;
- simplicity: the simplicity lens's test on every proposed mechanism (which mission point it serves, what happens
  without it, first day or behind a named trigger);
- pre-mortem: the failure stories without a countermeasure;
- rulings: every proposed verdict that breaches a ruling without flagging it;
- mission: for each point of the owner's mission, the decision that fulfils it and the KPI that measures it.

**Decide.** The lead reads the dossiers' decision tables and the ledgers and writes the decision ledger: one entry per
decision with verdict, reason, evidence grade, source lenses, dissent, the gating experiment, and the ADR it becomes if
it is a one-way door. Only the owner changes a ruling: one short list, each entry with the ruling's cost as a number,
the experts' proposal and the default. The default is the ruling as it stands. Then the experiment programme: every
experiment of the memos, deduplicated, ordered by risk removed per cost.

**Write.** One writer per document, each with one reader: the PRD, the design document, one ADR per one-way door, the
specifications the threads imply, the engineering foundation (rules, lint configuration, tests, CI), the plan rows for
the factory, the traceability table, and the system on one page for the owner. The why stays in the brain; the present
goes into the repo.

**Review, deliver.** Fresh agents that saw none of the stages, each briefed with the owner's words and one role, among
them a simplicity auditor and a gap hunter who walks the traceability table and the mission points. Fix and review
until a round is clean. Then commit, ship, file the Spec, and tell the owner in one short message: the verdict, the
decisions he owns with their defaults, the first plan rows, the one-page model.
