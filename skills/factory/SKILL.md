---
name: factory
description: "Work with the software factory from any repo: file an Issue (`factory issue new`), plan several dependent Issues (`docs/plan.yaml` rows or `--after` edges), follow them, change an edge, and report friction with the factory (`factory signal file`). Use when work should ship on its own, when the user says issue, queue, plan, after, chain or factory, or when a factory command refused or surprised you. Not for an edit this session must land itself (`@implementer`)."
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

## When the factory surprises you

A refusal you could not predict from `--help`, a hidden limit, an id format, a wrong state: report it once with
`factory signal file --from agent:<this-repo> --repo software-factory --title "<what happened>" --text "<command, answer, what you expected>"`. Triage merges duplicates
into one Issue. Do not file the Issue yourself, and do not work around it silently.
