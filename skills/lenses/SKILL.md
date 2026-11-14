---
name: lenses
description: Examine a large undertaking from 40 to 90 expert angles before anything is decided — a question-first lens catalogue, one Opus expert per lens writing one sourced memo, an independent source audit with repair, gap rounds for the angles the experts report as uncovered, then a handover to a staged multi-agent synthesis into decisions and documents. Use when the user asks for a step back, for "every angle" or a concept "thought through to the end", rejects a plan or spec as shallow, or says "lenses". Costs tens of millions of tokens and hours of wall-clock, so only on the user's explicit ask.
---

# Lenses: wide expert research, then a staged synthesis

One planning agent compresses. Asked for a concept that spans twenty fields, it returns a summary with the depth of
its shallowest field. This skill separates the work: you write **questions**, one specialist per angle writes
**answers** into its own file, and a later session **decides** across them.

First run, WeatherOrb, 2026-11-14 (`~/SourceRoot/brain/wiki/weatherorb/lenses-2026-11/`): 86 lenses in four rounds
(68, 11, 5, 2), 735 seed questions, memos of 4,600 words on average, 240,000 to 350,000 subagent tokens and 20 to 30
minutes per lens with audit and repair, ten lenses at a time. The audit checked 431 cited claims: 358 confirmed, 20
contradicted, 49 not on the cited page; 38 memos were repaired. The 5-hour usage limit stopped the run twice. The
synthesis half had not run when this was written: `reference/synthesis.md` says so.

**Not for** a question one `/research` run answers, a decision inside one field, or a plan the user wants today.
Invoking this skill is the user's opt-in to the Workflow tool for its fan-outs.

## Files

| File | Use |
|-|-|
| `scripts/lenses.mjs` | `stubs` from a catalogue, `index`, `list`, `check`, `section <name>` across memos, `args` for the workflow. Its header documents `lenses.json` and the catalogue format |
| `scripts/lens-workflow.js` | the Workflow script: a pool of ten lenses, each through research, audit and repair |
| `reference/lens-brief.md` | template of the brief every expert reads first; its "How to work" and "The memo" stay verbatim |
| `reference/synthesis.md` | shape of the handover page and of the synthesis run |

The run lives where the project's reasoning lives: `brain/wiki/<domain>/lenses-<yyyy-mm>/`, with the brain's rules
(`/brain`): frontmatter, wikilinks, `node .scripts/vault-lint.mjs` before every commit.

## A · Research (this session)

1. **Collect before you design.** Read the project's memory notes, rulings, the rejected attempts and the owner's
   verdicts on them. Keep his request verbatim. List the prior material by path. You do no research of your own.
2. **Write the catalogue: questions, not answers.** 40 to 90 lenses in about nine groups. Per lens: an expert role, a
   scope, the borders to neighbouring lenses (`not:`), the prior material to read, six to ten seed questions. What
   makes a catalogue work:
   - **Borders.** Every lens names what belongs to its neighbours. Without them 80 memos converge on the same
     general architecture.
   - **Heterogeneity.** A lens earns its place if only its expertise can answer it. Split by field (a mathematician,
     a licence reader, a site-reliability engineer), never by chapter of the existing design.
   - **Both systems.** Lenses for the thing built and for the system that builds it: tests, CI, lint, documents, how
     the factory takes the work.
   - **An adversarial group, always:** the mission as a testable contract with its contradictions, a pre-mortem,
     lessons from rebuilds elsewhere, a simplicity audit that tries to delete what the others propose, and the scope
     of the first slice.
   - **Seed questions** ask for numbers, for named systems to compare with, for what must be decided now because it
     cannot be retrofitted, and for the small experiment that would decide. They never presuppose the current
     design.
3. **Write the brief** from `reference/lens-brief.md`: the mission in the owner's words, the rulings that bind, why
   earlier attempts were rejected, what is open, constraints, prior material. His request goes in verbatim at the
   end.
4. **Stubs and index.** Write `lenses.json`, run `lenses.mjs --dir <dir> stubs <catalogue>...` and `index`, lint,
   commit, push.
5. **Smoke, then pilot.** One cheap agent proves that a worker can search the web, read a page through `agw` and
   write a file. Then run eight lenses from different groups and read their Digests. Fix the brief before the rest
   repeats its flaw.
6. **Fan out.** `Workflow({scriptPath: "~/.claude/skills/lenses/scripts/lens-workflow.js", args: <output of
   lenses.mjs args>})` with the path expanded. Research runs on Opus at high effort; the audit on Haiku checks hard
   structure rules and five cited claims against their pages and stamps an `audit:` line into the memo; a repair runs
   only on a contradicted claim, two claims missing from their pages, a structure fault or forbidden content.
7. **Gap rounds.** Every expert returns `missing_perspectives`. Cluster them. An angle becomes a lens when two or
   more experts name it or when it changes the architecture; its prior material is the memos that named it. Add
   `"round": 2` to the workflow args. Stop when a round names nothing that passes that test. What you leave out goes
   into the handover as a lead. In the first run the later rounds drifted from architecture toward business matters,
   and four rounds were enough.
8. **After every wave:** `check`, `index`, lint, commit, push.

## B · Handover

Write `synthesis-handover.md` in the lens folder after `reference/synthesis.md`: the job and what done means, the
material, the stages, the thread table, the leads from the experts' return values, the rules of the run. Check that
every lens is primary in exactly one thread. Run the page through `/prose`. Give the user one line to paste into a
fresh session: read the page and carry it out, with workflows and Opus agents as it describes.

## C · Synthesis (a fresh session)

The handover page is the prompt; `reference/synthesis.md` explains its stages: dossiers per decision thread,
cross-examination, the lead decides, writers, fresh reviewers. When it has run, correct `reference/synthesis.md` and
this page with what held.

## Rules

- **At most ten units at once**, and each unit (a lens with its audit and repair) finishes before the next starts in
  its slot. An interruption then loses ten units, not sixty.
- **A usage limit stalls a workflow without failing it.** The agents' transcripts end with "You've hit your 5-hour
  limit". Arm a `Monitor` that greps the run's transcript directory for that text; stop the run when it fires,
  commit what is on disk, and relaunch with fresh `args` once the limit is lifted.
- **State is what is on disk.** `status:` and `audit:` in each memo say what is finished. `lenses.mjs args` builds the
  next run from them.
- **An expert that starts its own measurement can hang its slot.** One waited 30 minutes on a capture process that
  had died, and the run could not finish. When a memo is written and its agent does not return, stop the run and
  launch that lens again: `args` offers it as `written`, and it gets its check and audit.
- **One file, one writer.** Agents write only their own memo and run no git command that changes anything. You
  commit.
- **Stay out of the memos.** Read Digests and return values; the views script serves the rest to agents. Reading 80
  memos into the main session ends it.
- **Models.** Workflow agents take `model: 'opus'` for research, repair, dossiers, writing and review, and Haiku for
  audits. With the Agent tool an Opus worker needs `[opus: <reason>]` in its description.
- **Nothing heavy on a shared host:** agents research and write; builds, benchmarks and downloads become experiments
  in a memo.
- **The audit is narrow on purpose.** In the pilot a style-minded audit sent all eight memos to repair; with hard
  rules only, about a third.
