# Root AGENTS.md split ledger

The root `AGENTS.md` was 55,764 bytes against the 12,000-byte budget of `rules/writing-for-agents.md`. Every block of it and where it went; the table follows the original line order. A moved block keeps its words (dates and pointers rewritten); a destination named `docs/…` holds the block under the heading shown.

| Original lines | Bytes | Entry | Destination |
|-|-|-|-|
| 3-16 | 761 | What this repo is | root `AGENTS.md` §What this repo is, rewritten |
| 20-62 | 7720 | Symlink map table | `docs/symlink-map.md` |
| 63-73 | 708 | Not symlinked (rendered or copied files) | `docs/symlink-map.md` |
| 74-76 | 221 | Per-repo skills | `docs/symlink-map.md` |
| 80-96 | 2982 | Setup, status, doctor: make target table | `docs/make-targets.md` |
| 97-102 | 449 | make doctor on both machines | `docs/make-targets.md` |
| 103-108 | 367 | Exit codes are graded | `docs/make-targets.md` |
| 109-114 | 346 | settings.json merge | `config/AGENTS.md` §settings.json merge |
| 115-120 | 1126 | Hooks, the three guards | `hooks/AGENTS.md` (one section per guard); root §Machines names herdr-core-guard |
| 121-124 | 244 | Adding a global skill, per-repo skill, global rule | `skills/AGENTS.md`; the always-on-rule gotcha stays in root §Gotchas |
| 125-136 | 675 | Changing how Claude talks (output style) | `config/AGENTS.md` §Output style |
| 137-139 | 233 | Keep this file under 40k chars | deleted: superseded by the 12,000-byte budget in `rules/writing-for-agents.md`; root line 3 states it |
| 141-146 | 525 | Validate | root §Validate, rewritten |
| 147-150 | 169 | Deploy | root §Deploy, rewritten |
| 151-153 | 267 | make setup restarts hc-events / hc-resume | `scripts/AGENTS.md` §Restarts of script agents |
| 155-160 | 434 | Verify & Monitor | root §Verify & Monitor, rewritten |
| 162-169 | 525 | Gotchas | root §Gotchas, rewritten |
| 171-176 | 241 | Machines & remote dev: stack | root §Machines & remote dev; full text `docs/remote-dev.md` §Reach, housekeeping and facts to hold |
| 177-183 | 597 | Lane table | deleted: the same two lanes are in `config/global.CLAUDE.md` §Stay the orchestrator and skill `factory`; root keeps one line |
| 184-191 | 1285 | Want / Command table (terminal, rd, janitor, event record, sidebar) | `docs/remote-dev.md` |
| 192-218 | 2751 | Commands take a repo name; facts to hold (core restart, core-up, ssh iumac, never ssh mini claude, core env, Full Disk Access) | `docs/remote-dev.md`; guardrails also in root §Machines & remote dev |
| 219-230 | 1323 | human-queue | `docs/remote-dev.md` §human-queue; root keeps the `ask-human ask` line |
| 231-238 | 841 | IuRoot deploy-gate pins | `scripts/AGENTS.md` §Deploy gate pins; root names the four scripts |
| 239-242 | 204 | /remote-dev and herdr pointers | root §Machines & remote dev |
| 243-262 | 1085 | Dev-server doors | `config/AGENTS.md` §Dev-server doors |
| 263-283 | 1635 | Service registry (mini) | `config/mini/AGENTS.md` |
| 284-300 | 1496 | Colima and the boot path | `colima/AGENTS.md` |
| 301-310 | 824 | Postgres (mini) | `config/postgres/AGENTS.md` |
| 311-335 | 1589 | Homebrew | `docs/homebrew.md` §Commands and rules |
| 336-346 | 1081 | Heartbeat make targets | `docs/make-targets.md` |
| 347-355 | 1327 | Heartbeat components | `docs/devhost-health.md` §Heartbeat components |
| 356-369 | 1067 | Kuma door | `kuma-door/AGENTS.md` |
| 370-384 | 1053 | Collie | `docs/collie.md` §Commands and rules |
| 385-394 | 511 | Secrets: accounts, the secrets-run shim | root §Secrets |
| 395-466 | 5407 | Secrets: backends, seed, tiering, reseal, 1Password and TCC traps, keychain, rotate | `scripts/AGENTS.md` §Secrets |
| 467-474 | 460 | Secrets: edit guardrail, data half | root §Secrets (`scripts/AGENTS.md` repeats the data half) |
| 475-479 | 415 | Keychain-cached CLAUDE_SDK credentials, ANTHROPIC_API_KEY never exported | `config/zsh/AGENTS.md`; the API-key rule also in root §Secrets |
| 480-499 | 2003 | MCP servers | `docs/browser.md` §MCP servers; root keeps a Host topics row |
| 500-541 | 3814 | Claude Code launchers: table, picked marker, orchestrator principal, claude-auth | `config/zsh/AGENTS.md`; root §Claude Code launchers keeps the short form |
| 542-559 | 1178 | Codex, OpenCode, tailnet | `config/AGENTS.md` |
| 560-568 | 511 | Unattended boot posture | `docs/devhost-health.md` §Unattended boot posture; root Host topics row keeps the pmset rule |
| 569-576 | 505 | MacBook-only subsystems | `docs/macbook.md` |
| 580-588 | 674 | Agent logs | `docs/background-jobs.md` §Agent logs; root §Gotchas keeps one line |
| 589-592 | 324 | File shuttle | `docs/remote-dev.md` §File shuttle |
| 593-594 | 425 | Host waste | `docs/host-waste.md` |
| 595-599 | 314 | Disk | `docs/disk.md` |
| 600-605 | 510 | External volume | `docs/external-ssd.md` |
| 606-608 | 199 | Storage | `docs/storage.md` |
| 609-622 | 1164 | HomeLab files (hl) | `docs/storage.md` §HomeLab files |
| 623-628 | 451 | The look | `docs/theme.md` §Commands and rules |
| 629-634 | 408 | Obsidian must keep running | `docs/brain-access.md` §Obsidian on the mini |
| 635-637 | 238 | Debug logs | `hooks/AGENTS.md` §Debug logs |

Rows add up to 55662 bytes; the headings and blank lines between them are the rest of the 55,764.

## Sizes

| File | Before | After |
|-|-|-|
| `AGENTS.md` | 55,764 | 8,879 |
| `scripts/AGENTS.md` | new | 6,878 |
| `config/zsh/AGENTS.md` | new | 4,247 |
| `config/AGENTS.md` | new | 3,314 |
| `config/mini/AGENTS.md` | new | 1,642 |
| `hooks/AGENTS.md` | new | 1,564 |
| `colima/AGENTS.md` | new | 1,476 |
| `kuma-door/AGENTS.md` | new | 1,079 |
| `config/postgres/AGENTS.md` | new | 822 |
| `skills/AGENTS.md` | new | 253 |

## Pointers rewritten

Sections the other files name: `AGENTS.md` §Machines & remote dev, §Secrets and §Claude Code launchers stay in the root under their names. `§review-bypass-guard` is now `hooks/AGENTS.md` §review-bypass-guard (`config/global.CLAUDE.md`); `§Codex` is `config/AGENTS.md` §Codex, OpenCode, tailnet (`config/codex/config.toml.tpl`); `§Secrets` in `docs/tcc.md` and `docs/macbook.md` is `scripts/AGENTS.md` §Secrets; the "Condensed reference lives in AGENTS.md" lines of `docs/homebrew.md`, `docs/theme.md`, `docs/collie.md` and `docs/opbackup.md` name their own sections; `docs/global-reference.md` §Launchers names `config/zsh/AGENTS.md`; `skills/remote-dev` names `docs/remote-dev.md` §File shuttle; the Kuma door plist, `README.md`, `docs/devhost-health.md` and four script comments follow.

## Marker proof

An interactive `claude` session (Sonnet) started with `hc run` in this worktree, one unique marker line in the root, `scripts/`, `hooks/`, `config/zsh/`, `colima/` and `docs/symlink-map.md`. Asked which markers are in context:

| Step | Markers reported |
|-|-|
| Before any file work | root |
| After `head` through Bash on `scripts/secrets-run` and `hooks/herdr-core-guard.ts` | root only: a Bash read does not load a nested file |
| After the Read tool on `config/zsh/claude.zsh` and `scripts/doctor.sh` | root, `config/zsh`, `scripts` |
| After the Read tool on `hooks/protect-branches.ts` | adds `hooks` |
| After a question on Colima, answered from the root's Host topics row | adds `colima`, the file the agent opened itself |
| Never reached | `docs/symlink-map.md` (a pointer target, read only on demand) |

Trial tasks in the same session, answered from the new layout without hints: the steps to add a service to the Kuma door and the rule against editing generated monitors (`kuma-door/AGENTS.md`), the Colima restart rule (`colima/AGENTS.md`) and the cost of editing `scripts/ask-human.sh` (root §Machines & remote dev, then `scripts/AGENTS.md` §Deploy gate pins). Nothing was missing.
