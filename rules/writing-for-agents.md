---
description: How to write what an agent reads — AGENTS.md, global CLAUDE.md, rules, skills, agent files, Issue facts. Where a fact goes, byte budgets, what a line must do, how a CLI is wired, format, pointer wording, how to prove a document.
paths: ["**/AGENTS.md", "**/SKILL.md", "**/.claude/rules/**", "**/.claude/skills/**", "**/rules/*.md", "**/agents/*.md", "**/global.CLAUDE.md"]
---

# Writing for Agents

An agent acts on every line it loads, so a line costs twice: its tokens on every turn of every session and subagent, and the
steps it causes. In the one controlled study, instruction files raised a task's cost by 20 % without raising success; in
another, the share of answers that kept every rule fell from 9 in 10 at 10 rules to 1 in 4 at 40. The target is the smallest set of facts
the agent cannot find out itself, loaded only by the work that needs them. Measurements and sources: `docs/writing-for-agents.md`
in dotfiles. Prose for humans is `brain/voice.md`. A document is judged by running it, not by debate.

## Where a fact goes

The first row that fits decides.

| The fact | Goes to |
|-|-|
| Readable from the code, the Makefile, `--help` or the directory tree | nowhere |
| A check a script can make | the script, lint rule or test; one line names it |
| Every task in the repo needs it: validate, ship, verify, a requirement a general model would not assume, a time or cost warning | root `AGENTS.md` |
| Only work in one directory needs it | that directory's `AGENTS.md` |
| Only one kind of file needs it, in any repo | a rule with `paths:` |
| A procedure with steps, or the judgment around a CLI | a skill |
| Why something was decided, a feature's design, history | `docs/`, behind a pointer in the nearest loaded file |

## Budgets

Bytes from `wc -c`; four bytes are about one token.

| Text | Budget | Loaded |
|-|-|-|
| Root `AGENTS.md`, global `CLAUDE.md` | 12,000 each | every turn, every subagent |
| Always-on rule | 2,000 | every turn |
| Skill description | 600 characters, the main use first | every turn |
| Nested `AGENTS.md`, rule with `paths:`, skill body | 8,000, then split by branch | on reach |
| Command output a skill injects | 4,000 | on skill load |

A file at its budget takes a new line only by losing one. A lesson learned while working goes where the table above puts it,
never to the root file by default: that is how one root file reached 128 KB in three weeks.

## What a line must do

- **Change behaviour against the default.** A sentence the agent would follow unprompted goes. So does an overview, a directory
  listing and generic good practice: measured, they do not help.
- **Name the behaviour wanted, with its reason in a clause.** "Run the layout suite in a test slot: it holds 500 MiB a worker."
  The reason lets the agent decide the case you did not write. Plain words: `IMPORTANT`, `NEVER` and capitals make current
  models apply a line where it does not belong. Keep a bare prohibition for a hard guardrail, paired with its positive.
- **Be checkable.** The exact command and path. A step ends on an exhaustive criterion: "every modified model accounted for",
  not "produce a change list".
- **Keep time and cost warnings.** "The full suite takes 20 minutes" is the kind of line that measurably changed what agents did.
- **Hold one meaning in one place.** A second copy goes stale; point at the first. Dates and Issue numbers belong to the
  record in `docs/` or git, the rule stays without them.
- **Order by weight.** What must hold comes first; rules early in a file are kept more often.
- **Say what this project cares about** that a general model would not assume: the stakes, who the users are, the scar behind
  a rule. Name a recurring failure once, then use the name.

## A CLI

An agent opens help only for a capability it knows exists. Three layers, each with one source:

1. **That it exists and what it is for,** in capability words, always loaded: the description of its skill, and its row in
   the always-on CLI index. Written by hand.
2. **Which verbs it has,** when the skill loads, live from the CLI: a line that starts with `!` and holds the list command in
   backticks, which Claude Code replaces with the command's output. End it with `|| echo "<cli> is not on this machine"`,
   because a failing command aborts the whole skill. Never a copied list.
3. **The flags of one verb,** from `--help` or the schema at the moment of use. Never copied.

The skill's own text is what a listing cannot say: when to reach for a verb, the order of steps, a trap, an exit code to act on.

## Format

- **Full sentences.** Dropping articles and abbreviating raised cost where it was measured, and a clipped line is read two ways.
- **A table for a lookup with two or more attributes per row,** a list otherwise. A table costs about 1.4 times the tokens of
  the same text in lines.
- **Reference rows as `name<TAB>summary` lines.** JSON and YAML cost two to three times as much for flat data.
- **Three to five examples** when the shape of an output matters, in place of a paragraph describing it.
- No emphasis for decoration: bold marks the term a row or bullet is about.

## Pointers

A pointer's wording decides whether the material is ever reached: a skill description and an `AGENTS.md` line naming a doc are
the same object. Write one trigger per branch that should reach it, the leading word first, no praise and no identity the body
carries. Sharpen the wording before inlining the target. Reuse a word the model already holds and repeat it as one token; a
coined word costs its definition.

## Skills

- A model-invoked skill pays its description on every turn; a user-invoked one (`disable-model-invocation: true`) pays nothing
  and is unreachable for agents. Johannes never types skill names, so here almost every skill is model-invoked.
- Reference two skills share lives in a plain file both point at.
- A skill body over its budget splits into reference files one level down, each named in the body with when to read it.

## Prove it

1. `wc -c` before and after, in the commit message or ship note.
2. Run the document on one real task of its kind and put back what the shorter text no longer carried.
3. For text moved behind a pointer or into a nested file: show it is still reached. Put a unique marker in the moved text, start
   a session, do work that should reach it, ask which markers are in context (`docs/agents-md.md` has the method).
