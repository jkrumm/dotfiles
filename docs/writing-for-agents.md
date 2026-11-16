# Writing for agents: what the rule rests on

The rule an agent follows is `rules/writing-for-agents.md`. This page holds its evidence: what our instruction files weighed
on 2026-11-16, what studies measured, and where each budget comes from. The short version: a repo's `AGENTS.md` is the
largest load, at the median close to everything global together, and the reason to cut it is attention and extra steps, not money.

## What loads, measured on 2026-11-16

| Text | Bytes | Loaded |
|-|-|-|
| Global `CLAUDE.md` | 10,977 | every turn, every session and subagent |
| Five always-on rules | 4,832 | every turn |
| Descriptions of 26 skills | 9,531 | every turn, while the listing budget holds |
| Root `AGENTS.md` of the repo | 484 to 127,848, median 20,717 | every turn |
| A skill body | 1,084 to 16,477 | when the skill fires |

- **35 repos carry 0.9 MB of `AGENTS.md`.** 12 are under 12,000 bytes. Of the nine repos with more than 300 commits in the last
  30 days, none is.
- **The largest grew by appending.** iris: 127,848 bytes three weeks after its first commit, 249 commits touched the file, and
  71,632 bytes sit in one section, "Gotchas": 60 entries of about 1.2 KB, each the design of one feature. Every agent in that
  repo loads all 60 on every turn, and so does every subagent it starts.
- **The second largest holds reference.** tinycast-extensions: 49,174 of 82,497 bytes are "Data sources per feature", which only
  work on one feature needs.
- **Overviews are common.** dotfiles' "Symlink map" is 8,586 bytes; tinycast-extensions' "Layout" is 10,557.
- **A CLI can be invisible.** agw has 82 commands in 48 groups; 37 groups are named in no always-loaded text.

At about four bytes a token, a session in iris starts about 38,000 tokens deep before the task, the tool definitions and the
system prompt.

## What studies measured

| Finding | Source | Weight |
|-|-|-|
| Context files raise inference cost by about 20 % and do not raise task success (-0.5 to +2.4 points, none significant) | [Gloaguen et al., ETH Zurich, v3 2026-09](https://arxiv.org/abs/2602.11988) | controlled, 438 tasks, older models |
| Agents follow the file: a tool it named was used 1.6 times per task, against under 0.01 without it. Overviews did not shorten the way to the right file | same | same |
| One file's warning "the full test suite takes >20 minutes" cut full-suite runs from 3.67 to 1.67 per task; correctness did not move with or without the file | [Khatri 2026](https://arxiv.org/pdf/2607.27250.pdf) | independent, 17 tasks, underpowered |
| With N checkable rules in one prompt, the share of answers that keep all of them: 0.94 at 10 rules, 0.24 at 40, 0 at 80 on a current Sonnet; 0.85, 0.12, 0 on Haiku. Markdown against plain text made no reliable difference | [Eliav 2026](https://arxiv.org/html/2607.19257v1) | single-author preprint, synthetic rules |
| At 500 keyword rules the best of 20 models keeps 68 %; Claude models decay linearly; earlier rules are kept more often | [IFScale 2025](https://arxiv.org/abs/2507.11538) | preprint, synthetic rules |
| The same content costs 1.26 times the tokens as markdown and 1.37 times as a table, against plain text | Eliav 2026 | measured with one tokenizer |
| For flat data JSON, YAML and XML cost two to three times CSV. No format wins on accuracy across models | [improvingagents](https://www.improvingagents.com/blog/best-input-data-format-for-llms), [TOON benchmark](https://github.com/toon-format/toon/blob/main/benchmarks/results/retrieval-accuracy.md), [Kutschka and Geiger 2026](https://arxiv.org/html/2605.29676v2) | token counts solid, accuracy thin |
| Telegraphic input raised net cost by about 15 %, because models answered longer. A terse output style saved 8.5 % of output tokens on 86 agent tasks with no quality change | [Cavewoman 2026](https://arxiv.org/html/2606.24083v1), [JetBrains 2026](https://blog.jetbrains.com/ai/2026/07/speak-to-ai-agents-like-cavemen-tosave-tokens/) | preprint; vendor's own paired test |
| Praise in a tool description moved selection by 43 points, and the first-listed of identical tools won far more often | [Wang and Zhang 2026](https://arxiv.org/html/2605.23916v2) | preregistered, two small models |

What Anthropic documents, without a published study behind the numbers:

- **Sizes.** `CLAUDE.md` under 200 lines; a skill body under 500 lines; a skill description under 1,024 characters with the
  main use first ([memory](https://code.claude.com/docs/en/memory),
  [skills best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)).
- **Emphasis.** Current models over-apply a line written with `CRITICAL` or `MUST`; a rule with its reason generalises better than a bare
  one ([prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices)).
- **The skill listing has a budget,** 1 % of the context window by a maintainer's comment, 2 % by older docs. Past it Claude
  Code drops descriptions, least-used skills first
  ([skills](https://code.claude.com/docs/en/skills)).

Not measured anywhere we found: the wording of `CLAUDE.md` or `SKILL.md` on the current models, the design of a CLI's help
text, and emphasis words on the current models.

## Why cut, if a cached token is nearly free

A cached always-loaded token costs a tenth or a twentieth of a fresh one, and development here runs on subscriptions. The money
case for moving text out of the always-loaded files is close to nothing. Three other costs are real:

- **Steps.** Agents do what the file says, so a line that does not serve the task at hand can still buy tool calls.
- **Adherence.** The more rules load together, the more often one is dropped.
- **Context.** 32,000 tokens of `AGENTS.md` are 32,000 tokens the task cannot use, in the lead and again in every subagent.

Loading on reach is the worse choice in two cases: the text is needed on most turns, or its pointer fails to fire and the rule
is silently absent. That is why the rule asks for proof that moved text is still reached.

## Where the budgets come from

| Budget | Basis |
|-|-|
| 12,000 bytes for a root `AGENTS.md` and the global `CLAUDE.md` | Anthropic's 200 lines at the 63 bytes a line of our global file |
| 8,000 bytes for text loaded on reach | our choice: 9 of 26 skill bodies exceed it today |
| 600 characters for a skill description | our choice, a cap and not a target: the mean today is 367 and three descriptions exceed 600 |
| 4,000 bytes for injected command output | our choice: the help of every dotfiles CLI fits, `factory --help` at 19 KB does not |

The three marked "our choice" are defaults to test, not findings.

## Not yet proven here

- **Load-time injection** (`!` and a command in backticks in a skill body) is read from the docs, not run. Issue 1636 is to prove
  it in an owner session and in a factory lead before any skill depends on it.
- **Whether a session's listing drops descriptions.** At four characters a token, 1 % of a 200,000-token window
  is about 8,000 characters, and our 26 descriptions are 9,531 characters before the built-in skills are counted. `/context` in
  a session of that size shows what was dropped; Issue 1636 is to read it and set `skillListingBudgetFraction` if anything was.
- **Whether a nested `AGENTS.md` is reached reliably enough** to hold what "Gotchas" held. The first repo to split is to prove
  it with the marker method in `docs/agents-md.md`.
