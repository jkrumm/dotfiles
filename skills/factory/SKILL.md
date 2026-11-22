---
name: factory
description: "Work with the software factory from any repo: file an Issue (`factory issue new`), choose its lead's seat, plan several dependent Issues (`docs/plan.yaml` rows or `--after` edges), follow them, rework a chain (seats, edges), and report friction with the factory (`factory signal file`). Use when work should ship on its own, when the user says issue, queue, plan, after, chain, seat or factory, or when a factory command refused or surprised you. Not for an edit this session must land itself (`@implementer`)."
---

# The factory, from any session

The factory takes an Issue for one repo and its lead builds, reviews, deploys and verifies it. The CLI is the contract:
`factory issue schema` for filing, `factory <verb> --help` for the rest. Read them before a flag;
this page holds only what the help cannot decide for you.

## Which repo, which lane

- **One Issue, one repo: the repo whose files change.** Work this session found for another repo goes to that repo
  (`factory issue new --repo rollhook …`, `--repo vps …`), never to this session's repo, never to software-factory unless the factory's
  own code changes, and never to another session to file for you.
- An edit that must land in this session's live tree is `@implementer`, not an Issue.
- The lead cannot see this session: the facts carry the ask, the why, exact paths, scope limits and any research done.

## Decide before you file

Settle every open point in this session before `factory issue new`: look, decide, or ask the owner here while he is in the room. The lead can only guess at what this session left open.

- Write each settled choice into the facts as a `Decided` line, with its reason. A direction the owner gave is quoted with his words and the date: the lead and the Judge read a quote as his.
- Leave to the lead what only the code can answer, and say so in `change`.
- `--checkpoint spec` makes the lead write its plan first; nobody waits on it, and the owner reads it only if he comments. It is no sign-off. Its cases are in `factory issue schema`.
- `--checkpoint gate` is the one way to hold a chain for the owner: a product gate, rare.
- A question for the owner that survives this session is one sentence under an `Ask the owner` fact, with its options. The lead raises it as a Decision.
- Give `--after` only where the Issue needs another Issue's output or the owner's answer. A row that could start today gets no edge (`--alone`), even when its chain sits behind a gate.

## The seat

File no seat. The factory seats the Issue itself: the light row (haiku, high) when its rule names the Issue, else the lead row
(sonnet, high), and a light lead that struggles is moved up. A filed seat always wins, so naming one switches that off.

| Seat | File it when | Per started Issue, 2026-11-22 |
|-|-|-|
| none | the default, also for a large feature whose facts carry exact paths and acceptance | lead row 3.81 dollars, 40 min; light row 0.52 |
| `{"role":"light","moveUp":true}` | a mechanical sweep the light rule would not name: one pattern over many files, proven by a check | |
| `{"tier":"opus","effort":"high"}` | a design other rows build on (a contract, a data model, an architecture cut), or novel hard logic where a wrong first attempt is costly to undo | 24.78 dollars, 119 min |

- Size is no reason for opus. When a row looks too hard for the lead row, first sharpen its facts or split it.
- Opus-seated Issues were an eighth of the Issues, over half of the leads' cost and a third of the weekly quota. Say why in the
  facts, one sentence (`Seat: opus because ...`).
- In a plan each row gets its own answer, never one seat for the whole plan: the foundation row may need opus, the rows that
  build on it rarely do.
- Figures now: `factory read seats`. The seat an open Issue will start on: `factory issue show <id>` (`leadSeat`).

## One Issue, a few, or a plan

| Shape | How |
|-|-|
| One change | `factory issue new --repo <repo> --title <title> --facts @file.json` |
| A few changes with an order | file the first, then the next with `--after <id>` (`609` or `issue_609`); `--after` names only open Issues |
| A program of rows in one repo, or rows waiting on another repo | rows in that repo's `docs/plan.yaml`, pushed to its default branch; the factory files each row when its `after` rows closed. Format: software-factory's `docs/plan.md` |

Give every filing a `--key` when a retry could run it twice. State the edges you know when filing; an Issue filed without
them is settled by triage, which may add some.

## Follow and change

- `factory issue list`, `factory read chain` (what blocks what), `factory issue show <id>`. Nothing polls: the factory wakes a
  lead (`factory issue defer`), and the owner reads Needs you.
- An edge was wrong: `factory planning after` / `factory planning unafter` on the open Issue. A plan row: edit the row
  and push.
- A note to a running lead: `factory issue note <id> <text>`.

## Rework a chain

Asked to optimise a chain, a queue or its seats:

1. `factory read chain --format json`: every open Issue and unfiled plan row with its seat, its state and what blocks it.
2. Seats: hold each not-started node with a filed seat against the table in "The seat". Lower an Issue with
   `factory issue seat <id> --role lead` (refused once a lead started; `--tier`/`--effort` name a row-less seat); for an
   unfiled row, edit or delete its `seat` in that repo's `docs/plan.yaml` and push.
3. Edges: an `after` stays only where the node needs the other's output. `factory planning unafter --issue <id> --after <id>`
   frees an Issue; a row loses the entry in `docs/plan.yaml`.
4. Report one table: node, seat before and after, edge removed, and why for each node left on opus.

## When the factory surprises you

A refusal you could not predict from `--help`, a hidden limit, an id format, a wrong state: report it once with
`factory signal file --from agent:<this-repo> --repo software-factory --title "<what happened>" --text "<command, answer, what you expected>"`. Triage merges duplicates
into one Issue. Do not file the Issue yourself, and do not work around it silently.