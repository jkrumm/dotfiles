# Round 4 — `config/global.CLAUDE.md` old → new map

Wave 8. Committed **before** the edit, followed by it. Line numbers refer to
`config/global.CLAUDE.md` at `dc313ee`. Rule: nothing leaves the file without a
home; every row is **kept** (verbatim), **reworded** (same concept, listed
change) or **moved** (target named). No row is dropped.

## The global file

| Old (line) | Concept / guardrail | New home |
|-|-|-|
| 1-7 | Identity, iterative style, German chat / English artifacts, `voice.md` for prose | kept verbatim |
| 9-10 | `--dangerously-skip-permissions`: permission pre-granted | kept verbatim |
| 12-14 | Operating contract header, tone lives in Direct.md | kept verbatim |
| 18-19 | Infer from context, never ask what the repo answers | kept verbatim |
| 20-21 | One question max | kept verbatim |
| 22-25 | Never ask permission; the owner-decision stop list | kept verbatim |
| 26-29 | **A PR is not a human gate** | kept verbatim (meaning and words) |
| 30-31 | Critique over validation | kept verbatim |
| 35-37 | Deliver the whole ask; route around obstacles | kept verbatim |
| 38-40 | Scope; flag contradictions with AGENTS.md | kept verbatim |
| 41-43 | Something seems wrong: flag, don't route around | kept verbatim |
| 47-54 | Validate / read the diff / review; never claim done unrun | kept verbatim |
| 58-59 | Main session holds plan and verdicts; delegation pre-authorized | kept verbatim |
| 61-62 | Lane table rows `@implementer`, header | kept verbatim |
| 64 | `agw dispatch` row: "Settled, bounded work in a repo … default for settled multi-file edits" | **reworded**: "one bounded change, unattended, in a repo you are not working in; result is a branch/PR or a verdict". The "default for settled multi-file edits" clause is removed (it pushed the prometheus run into dispatch first) |
| new row | N independent changes in one repo | **added**: `/wave` fan-out (`rd fan`, `rd merge`), worktree + Claude tab per change. Home of the detail: `skills/wave/SKILL.md` |
| 65-66 | `rd wave` and `warden run` rows | kept verbatim |
| 67-71 | Explore, `/check`, `@verifier`, `/research`, `/review` rows | kept verbatim |
| 73-74 | "Those four lanes … are the only ways to start agent work" | **reworded** to resolve the contradiction with the rows above: the four lanes are the only ways to *start another agent*; Explore, `@verifier`, `/check`, `/research`, `/review` are in-session tools, not lanes. Spec link `docs/agent-platform.md` kept |
| 74-78 | Brief completely; worker owns its files; disjoint parallelism; delegate for context; editorial inline | kept verbatim |
| 80-81 | Model ids only in `agw routing`, never in prose | kept verbatim |
| 82-84 | Subagents pinned off the orchestrator's model; `model-discipline.ts`; raise only for novel logic | kept verbatim |
| 85-86 | Don't switch model mid-session; worktree isolation only up front | kept verbatim |
| 87-88 | Grep before reading, never re-read | kept verbatim |
| 90-95 | Async jobs contract | kept verbatim |
| 97-108 | Workspaces: SourceRoot / IuRoot, PR-required list, basalt-ui own commit, homelab-private | kept verbatim |
| 110-116 | Machines: mini is the dev host, `desk`, `rd`, `/remote-dev`, `make doctor` | kept verbatim |
| 118-124 | Secrets: `op_account_for_cwd`, never `op` on the mini, `secrets-run` | kept verbatim |
| 126-137 | Workflow: `/commit` → `/ship`, check first, changed files only, never start dev servers, fnm, `gback`, Docker via Makefile, launchers | kept verbatim |
| 139-143 | Config hierarchy: global file density rule | kept verbatim |
| 144-147 | Per-repo AGENTS.md + shim + `.claude/{rules,skills}` | kept; **extended** by one clause: checked-in `.claude/settings.json` carries no `ask` rules (they still prompt under yolo and stall unattended agents) — hard stops go in `deny`, personal prompts in `settings.local.json`. Detail lives in `docs/agents-md.md` §Permissions |
| 148-149 | Rules: always-on roster, lazy `paths:` | kept verbatim |
| 150 | Output style: tone only, does not reach subagents | kept verbatim |

## Other files this wave touches (same no-loss rule)

| Old | New |
|-|-|
| `docs/global-reference.md` §Parallelism "Tier 1 … the default for fan-out" | reworded to the lane sentence: parallel gateway calls are for independent *reads/checks*; independent *changes* are `/wave` fan-out; the tier table stays |
| `skills/implement/SKILL.md` "Settled implementation now defaults to dispatch" (lines 10, 39, 49, 56, 61, 117, 190) | reworded: dispatch = one bounded change unattended in a repo you are not working in; N independent changes in one repo → `/wave` fan-out; live tree → `@implementer`. Content of each bullet stays |
| `docs/agents-md.md` | new §Permissions: no `ask` in checked-in `.claude/settings.json` |
| `AGENTS.md:441-445` model ids in the launcher table | replaced by "default per `agw routing`" / `docs/opencode.md` / `docs/codex.md`; the `-m` and variant flags stay |
| `docs/{opencode,codex,agents-md,agent-platform}.md`, `skills/podcast/SKILL.md` model ids | prose ids removed or pointed at `agw routing`; config keys, env defaults and tables that *are* the configuration stay (an id in a config example is not prose) |
| `rules/dockerfile.md:11,86` reference to `docker-makefile.md` (no such file) | points at `hooks/docker-makefile.ts` |
| `hooks/docker-makefile.ts` shrink to a deny list | **not done**: the global file's "Docker via Makefile targets only (a hook enforces it)" is a guardrail and the owner constraint is no guardrail lost. A deny list of destructive verbs would drop it. Recorded in Left behind |
| `~/.claude/skills/.trash`, `docs/hooks.md` header, `docs/herdr.md` | trash emptied; hooks.md header/count corrected; herdr.md folded into `remote-dev.md` |
| `sc-note.md` | untracked, gitignored personal scratch note: left in place |
