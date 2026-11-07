---
name: wave
description: Turn a plan into factory Issues - the lead's playbook for a multi-step plan (docs/plan.yaml, the server files the rows), a one-off Issue (rd issue / factory issue new), splitting work into independent Issues, ordering with after/--after, and following them with factory issue list|show and factory read overview. Use for work too large for one context, staged migrations, plans saying "then in the next session", or N changes that should ship on their own.
---

# Wave — turn a plan into Issues

A plan's steps become **Issues** in the software factory. The factory starts the lead of each Issue, which builds, reviews, deploys and verifies it, so this skill never spawns a terminal.

- **A plan that outlives one message** is a `docs/plan.yaml` in the target repo. The server files each row once its `after` rows are closed; nobody files the next step by hand.
- **A one-off Issue** (one change, no successor) is filed by hand.

## Split the plan

- **One Issue = one change that ships on its own** and is verifiable without the others. If it cannot be verified alone, merge it into its neighbour.
- **Independent rows** (disjoint files, no shared validation resource) carry no `after`; the factory runs them in parallel.
- **Dependent rows** name the rows they wait for in `after`. A row is done when its Issue is closed, whatever the outcome.
- A step that needs the owner's decision (product, spend, outward-facing) is not a row; ask first.
- Do not implement inside the filing session. Edits that must land in this session's live tree go to `@implementer`.

## The plan file

`docs/plan.yaml` in the repo the plan belongs to, committed like any change. Format, row states, conditions and the health line: `~/SourceRoot/software-factory/docs/design.md` §4 "The plan files its next Issue". Do not restate it here.

```yaml
version: 1
rows:
  - key: schema                 # first step, filed by hand and adopted
    issue: 201
  - key: backfill
    after: [schema]
    title: Backfill the new column
    facts:
      why: The reader switches to the column in the next step; old rows must carry it first.
      what: scripts/backfill.ts and its test.
      change: Fill `status` for every row from the legacy flag, in batches, idempotent.
      acceptance: The query counting rows with a NULL `status` returns 0; make check passes.
  - key: switch-reader
    after: [backfill]
    stable_days: 7
    title: Read from the new column
    facts:
      why: The legacy flag can go once nothing reads it.
      what: src/reader.ts.
      change: Read `status`; drop the legacy flag read.
      acceptance: make verify green; no reader of the legacy flag remains.
```

- **Facts are inline** and hold everything the lead needs (it cannot see this session): the ask and why, what and change with exact paths, acceptance as checks that prove it, scope limits (which sibling row owns what), research you already verified. A plan states its **gate** (the check every row must pass) in each row's acceptance.
- **Adopt, don't duplicate:** a step you must start now is filed by hand (below), then adopted with `issue: <id>` — no title, facts or other condition on that row.
- `repo:` points a row at another project; `not_before:` and `stable_days:` hold a row for a date or a quiet week.
- Commit the file, then check `factory project show <name>`: every row has its state, Issue and reason, and a parse error is shown there.
- A prose `docs/waves/PLAN.md` is not a plan the server reads; a new multi-step plan goes in `docs/plan.yaml`.

## File one by hand

For a one-off Issue, or the first step of a plan you adopt:

```bash
rd issue <repo> '<title>' --facts @facts.json [--after <id> …] [--key <key>]
factory issue new --repo <path> --title <text> --facts @file|- [--after <id> …] [--key <key>]
```

- `--facts` is JSON (up to 32 KiB) from a file or stdin, with the same content as a row's `facts`.
- `--after <id>` (repeatable, up to 20) holds the Issue until those are closed; each id must exist and be open, else nothing is filed.
- A stable `--key` makes a replay return the stored Issue (and ignores `--after`).
- No factory, no Issue: `rd issue` has no fallback. `factory health` says whether it is up.

## Follow and steer

- `factory issue list`, `factory issue show <id>` (facts, timeline, evidence, questions), `factory read overview` (asks, health, counts).
- `factory issue prio <id> <n>` orders the ready ones (higher first, none is 0).
- `factory issue answer <id> <text>` answers an ask; `factory issue note <id> <text>` adds context.
- `factory issue cancel|reopen <id>` when a lead must stop or the Issue should run again; the owner stops a row by cancelling its Issue.
- **Done** is the Issue closing with its evidence (verify, review, ship). The plan file needs no ticking: the server derives row state from the Issues.

## Waiting

Nothing polls. Commit the plan (and any hand-filed Issues), report the ids and end the turn; the factory's wake note and `factory read overview` bring the next step.
