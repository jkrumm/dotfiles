---
name: wave
description: Turn a plan into factory Issues - the lead's playbook for filing them (rd issue / factory issue new), splitting work into independent Issues, ordering with --after, and following them with factory issue list|show and factory status. Use for work too large for one context, staged migrations, plans saying "then in the next session", or N changes that should ship on their own.
---

# Wave — turn a plan into Issues

A plan's waves or steps become **Issues** in the software factory. The factory starts the lead of each Issue, which builds, reviews, deploys and verifies it, so this skill never spawns a terminal. File, order, follow.

## Split the plan

- **One Issue = one change that ships on its own** and is verifiable without the others. If it cannot be verified alone, merge it into its neighbour.
- **Independent Issues** (disjoint files, no shared validation resource) carry no `--after`; the factory runs them in parallel.
- **Dependent Issues** hold with `--after <id>` (repeatable, up to 20): the Issue waits until those are closed. Each id must exist and be open, else nothing is filed.
- A step that needs the owner's decision (product, spend, outward-facing) is not an Issue; ask first.
- Do not implement inside the filing session. Edits that must land in this session's live tree go to `@implementer`.

## What each Issue carries

`--facts` is JSON (up to 32 KiB) from a file or stdin. The lead cannot see this session, so the facts hold everything:

- **the ask** and **why**: the end state and the reason, one paragraph
- **what** and **change**: exact paths, the behaviour to add or remove, existing code to match
- **acceptance**: the checks that prove it (commands, tests, the live behaviour to verify)
- **scope limits**: files and areas that stay untouched; which sibling Issue owns them
- **research baked in**: versions, signatures, doc facts you already verified; the lead should not re-research them

## File

```bash
rd issue <repo> '<title>' --facts @facts.json [--after <id> …] [--key <key>]
factory issue new --repo <path> --title <text> --facts @file|- [--after <id> …] [--key <key>]
```

- A stable `--key` makes a replay return the stored Issue (and ignores `--after`); use one per plan step so a re-run files nothing twice.
- No factory, no Issue: `rd issue` has no fallback. `factory health` says whether it is up.
- File dependencies first and pass the returned ids to `--after`.

## Follow and steer

- `factory issue list`, `factory issue show <id>` (facts, timeline, evidence, questions), `factory status` (asks, health).
- `factory issue prio <id> <n>` orders the ready ones (higher first, none is 0).
- `factory issue answer <id> <text>` answers an ask; `factory issue note <id> <text>` adds context.
- `factory issue stop|resume|reopen <id>` when a lead must stop or restart.
- **Done** is the Issue closing with its evidence (verify, review, ship). Tick the plan from that, not from a report.

## Waiting

Nothing polls. File the Issues, report their ids and end the turn; the factory's wake note and `factory status` bring the next step.

## Plan document

A plan too big for one message lives in `docs/waves/PLAN.md` of the target repo: **Goal**, **Gate** (the check every Issue must pass), three to six steps per wave. State the gate: no gate, no acceptance. Each step becomes one Issue; the Issue ids go next to the step.
