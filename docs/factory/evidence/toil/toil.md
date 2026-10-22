# Toil accounting: what the owner and the agents repeat by hand

As of `2026-10-22T08:00:00Z`, windows of 30 days. Produced by `toil.py` (helpers `cmdnorm.py`, `scan_transcripts.py`) into `toil.out.json`, which holds every number below. Patterns are command + subcommand with all arguments elided; no raw command, prompt or ask text is stored. Hours are estimates with the arithmetic shown in section 6; every assumption is listed in `toil.out.json` under `meta.assumptions`.

## Summary

- **Owner:** 1,840 hand-typed commands in the retained shell histories (plus 2,115 lines typed into panes by rd/herdr, which are not owner toil). The most repeated pattern is the Claude launcher followed by `reset`; 87 human-queue asks reached the owner in 30 days (119 since August), 23 of them failed and 15 were retries of an earlier ask.
- **Agents:** 145,634 Bash calls in 4,363 sessions over 30 days, 305 h of tool wall time. 1,587 calls failed (1.1 %), 1,029 were refused by the harness or a hook; the same command re-run after a failure is rare (14 exact re-runs).
- **Warden loop:** 556 items from 1,761 events; 415 items needed at least one agent job (1,268 jobs, 209 agent hours); 31 recurring families cover 84 % of the items. In the last 30 days 105 of 364 items reached the owner (`needs_decision`) and 174 were touched from outside the loop (`owner_touch`).

### At a glance

- **Owner, shell (per month, est.):** `c` 479; `reset` 337; `desk` 147; `claude --resume` 123; `sz` 60.
- **Owner, human-queue (30 days):** 1password-write 28 (10 failed); 1password-lookup 15 (3 failed); secrets-cache-reseal 14 (2 failed); tailnet-acl-push 12 (5 failed); macbook-host-action 6 (2 failed).
- **Agents, action patterns by calls:** `python3 <heredoc>` 18,049 in 911 sessions; `git diff` 10,435 in 3,013 sessions; `git status` 8,710 in 1,106 sessions; `git log --oneline` 7,935 in 1,145 sessions; `bun test` 7,377 in 854 sessions.
- **Agents, tool wall hours:** `sleep <n>` 108.2 h; `<poll-loop>` 80.8 h; `grep` 78.7 h; `cat` 51.7 h; `tail` 44.6 h.
- **Warden families (excluding intake):** `uk monitor (push)` 22 items; `hermes log agent.tool_executor: tool terminal returned error (<n>.<n>s):` 16 items; `uk monitor (http)` 16 items; `kuma http up: <n> - ok` 14 items; `hermes log tools.checkpoint_manager: git command failed: git add` 11 items.
- **Best candidates (value hours):** C01 2.6 owner + 0.8 agent h; C02 2.7 owner + 0 agent h; C03 1.5 owner + 0 agent h; C04 1.1 owner + 2 agent h; C05 1 owner + 0 agent h (see section 6).

## Sources and coverage

| source | volume | origin | notes |
|-|-|-|-|
| owner shell history (mini) | 2,937 entries, 1,173 hand-typed | ok (frozen aggregate read 2026-10-22T09:00Z) | no timestamps; window assumed 30 d |
| owner shell history (iumac) | 1,017 entries, 593 hand-typed | ok (frozen aggregate read 2026-10-22T09:00Z) | no timestamps; window assumed 30 d |
| agent Bash calls | 145,634 calls, 4,363 sessions, 6,061 files with entries in the window | transcripts, streamed | timestamps exact; entry-filtered to the window |
| warden items | 556 items, 41 duplicate rows, 1,268 agent jobs | snapshot warden.db | 2026-09-08 .. as-of |
| human-queue asks | 119 asks over 76 days | snapshot human-queue/ | ran_at is the dialog time, not the click |

## 1. What the owner repeats by hand

### Top 20 manual shell patterns

| # | pattern | kind | mini | iumac | total | per month (est.) | typing min / month (est.) |
|-|-|-|-|-|-|-|-|
| 1 | `c` | agent-orchestration | 348 | 131 | 479 | 479.0 | 33.7 |
| 2 | `reset` | terminal | 293 | 44 | 337 | 337.0 | 28.1 |
| 3 | `desk` | agent-orchestration | 0 | 147 | 147 | 147.0 | 11.8 |
| 4 | `claude --resume` | agent-orchestration | 108 | 15 | 123 | 123.0 | 29.5 |
| 5 | `sz` | terminal | 59 | 1 | 60 | 60.0 | 4.4 |
| 6 | `cs` | agent-orchestration | 27 | 17 | 44 | 44.0 | 3.2 |
| 7 | `bun run dev` | build/check | 36 | 3 | 39 | 39.0 | 4.2 |
| 8 | `cf` | agent-orchestration | 34 | 3 | 37 | 37.0 | 3.4 |
| 9 | `claude` | agent-orchestration | 28 | 0 | 28 | 28.0 | 3.0 |
| 10 | `make <target>` | build/check | 0 | 28 | 28 | 28.0 | 4.1 |
| 11 | `git push` | vcs | 24 | 1 | 25 | 25.0 | 2.9 |
| 12 | `script <other>` | files | 0 | 23 | 23 | 23.0 | 10.6 |
| 13 | `fnm` | build/check | 17 | 0 | 17 | 17.0 | 4.5 |
| 14 | `git pull` | vcs | 2 | 15 | 17 | 17.0 | 2.3 |
| 15 | `script stack-remote.sh` | files | 15 | 0 | 15 | 15.0 | 4.3 |
| 16 | `cap` | agent-orchestration | 13 | 0 | 13 | 13.0 | 1.0 |
| 17 | `open <target>` | files | 3 | 9 | 12 | 12.0 | 1.7 |
| 18 | `watch` | waiting | 11 | 0 | 11 | 11.0 | 4.6 |
| 19 | `python3 stack-dashboard.py` | scripting | 9 | 0 | 9 | 9.0 | 3.1 |
| 20 | `secrets-run run` | secrets | 9 | 0 | 9 | 9.0 | 2.5 |

Excluded as not owner-typed: 1,309 x claude launch (typed into the pane by herdr agent start); 793 x rd lane export (injected by rd/herdr); 13 x claude --bg launch (spawned by an agent). Navigation is left out of the ranking: `j` 97, `ls` 13, `cd <path>` 83. Frequencies assume each history spans about 30 days (no per-line timestamps; the implied-window check in section 7 makes the monthly figures an upper bound).

The sharpest repeat: `reset` is typed 337 times, 258 of them directly after a Claude launcher exits.

### Top repeated sequences (2-4 consecutive commands)

| sequence | times |
|-|-|
| `c > reset` | 171 |
| `reset > c` | 145 |
| `c > reset > c` | 91 |
| `reset > c > reset` | 87 |
| `c > reset > c > reset` | 59 |
| `j > c` | 58 |
| `reset > sz` | 49 |
| `reset > c > reset > c` | 48 |
| `claude --resume > reset` | 42 |
| `c > j` | 41 |
| `reset > sz > c` | 35 |
| `c > claude --resume` | 31 |

### Typed slash commands (`<command-name>` entries in user messages)

| command | entries | owner-typed | scheduled | other | sessions |
|-|-|-|-|-|-|
| `/loop` | 247 | 3 | 244 | 0 | 2 |
| `/exit` | 52 | 52 | 0 | 0 | 52 |
| `/effort` | 4 | 4 | 0 | 0 | 4 |
| `/clear` | 2 | 2 | 0 | 0 | 2 |
| `/login` | 2 | 2 | 0 | 0 | 2 |
| `/compact` | 1 | 1 | 0 | 0 | 1 |
| `/goal` | 1 | 1 | 0 | 0 | 1 |
| `/hermes-update` | 1 | 1 | 0 | 0 | 1 |
| `/mcp` | 1 | 1 | 0 | 0 | 1 |
| `/model` | 1 | 1 | 0 | 0 | 1 |
| `/wildrift-refresh` | 1 | 1 | 0 | 0 | 1 |

Typed prompts: 2,602 in 30 days, 97 % with ten words or more (rd/herdr type their briefs into panes the same way, so owner and tooling are not separable). Short prompts repeated at least five times: none. The owner does not repeat steering nudges by hand.

Skills launched in the same window (model-invoked `Skill` calls; skill launches the owner types are recorded as skill expansions without a tool call): `wave` 325, `review` 178, `browse` 49 (+34), `herdr` 21, `research` 19, `code-review` 18, `check` 16, `cloudflare` 11.

## 2. What the agents repeat by hand

145,634 Bash calls, 4,363 sessions, 2,342 distinct patterns; 139,358 of 523,240 command segments are shell glue and left out of the rankings. Lanes: interactive 115,915 calls / 994 sessions, headless 13,677 calls / 1,546 sessions, agw-job 7,747 calls / 759 sessions, sideclaw-job 7,609 calls / 959 sessions, scratch 644 calls / 97 sessions, bench 42 calls / 8 sessions.

### Top 20 patterns by calls

| # | pattern | kind | calls | sessions | top lane | fail % (as last command) | wall h | p50 s | p90 s |
|-|-|-|-|-|-|-|-|-|-|
| 1 | `grep` | inspect | 57,579 | 3,603 | interactive 82 % | 0.0 | 78.7 | 0.1 | 0.8 |
| 2 | `sed` | inspect | 29,378 | 2,598 | interactive 86 % | 1.0 | 8.0 | 0.1 | 0.2 |
| 3 | `cat` | inspect | 19,874 | 2,097 | interactive 87 % | 2.3 | 51.7 | 0.1 | 9.7 |
| 4 | `python3 <heredoc>` | scripting | 18,049 | 911 | interactive 100 % | 3.9 | 33.6 | 0.2 | 19.3 |
| 5 | `ls` | inspect | 12,914 | 1,749 | interactive 91 % | 0.0 | 19.1 | 0.1 | 1.8 |
| 6 | `git diff` | vcs | 10,435 | 3,013 | interactive 39 % | 0.0 | 3.2 | 0.1 | 0.4 |
| 7 | `git status` | vcs | 8,710 | 1,106 | interactive 98 % | 0.0 | 21.6 | 0.5 | 16.6 |
| 8 | `git log --oneline` | vcs | 7,935 | 1,145 | interactive 95 % | 0.0 | 16.8 | 0.8 | 7.8 |
| 9 | `bun test` | build/check | 7,377 | 854 | interactive 95 % | 1.3 | 19.5 | 2.3 | 40.8 |
| 10 | `git diff --stat` | vcs | 6,203 | 2,388 | interactive 74 % | 0.0 | 8.5 | 0.2 | 3.5 |
| 11 | `sleep <n>` | waiting | 5,782 | 934 | interactive 81 % | 0.8 | 108.2 | 5.7 | 336.6 |
| 12 | `git commit` | vcs | 5,059 | 962 | interactive 100 % | 4.2 | 13.0 | 2.3 | 19.2 |
| 13 | `git add` | vcs | 4,678 | 959 | interactive 100 % | - | 10.7 | 2.2 | 18.3 |
| 14 | `tail` | inspect | 4,471 | 811 | interactive 96 % | 0.6 | 44.6 | 0.3 | 132.4 |
| 15 | `wc` | inspect | 4,253 | 1,474 | interactive 74 % | 2.2 | 3.0 | 0.1 | 0.8 |
| 16 | `sed -i` | files | 3,939 | 812 | interactive 100 % | - | 10.4 | 0.3 | 28.8 |
| 17 | `uv run` | build/check | 3,749 | 243 | interactive 93 % | 4.2 | 20.3 | 2.4 | 59.1 |
| 18 | `git push` | vcs | 3,636 | 883 | interactive 100 % | 4.4 | 8.9 | 3.0 | 20.7 |
| 19 | `<poll-loop>` | waiting | 3,499 | 805 | interactive 67 % | - | 80.8 | 9.9 | 385.4 |
| 20 | `git show` | vcs | 3,244 | 797 | interactive 76 % | 0.7 | 1.5 | 0.1 | 1.0 |

### Top 20 action patterns (inspection and glue removed)

| # | pattern | kind | calls | sessions | fail % (as last command) | wall h | p90 s | calls > 120 s |
|-|-|-|-|-|-|-|-|-|
| 1 | `python3 <heredoc>` | scripting | 18,049 | 911 | 3.9 | 33.6 | 19.3 | 289 |
| 2 | `git diff` | vcs | 10,435 | 3,013 | 0.0 | 3.2 | 0.4 | 25 |
| 3 | `git status` | vcs | 8,710 | 1,106 | 0.0 | 21.6 | 16.6 | 202 |
| 4 | `git log --oneline` | vcs | 7,935 | 1,145 | 0.0 | 16.8 | 7.8 | 132 |
| 5 | `bun test` | build/check | 7,377 | 854 | 1.3 | 19.5 | 40.8 | 148 |
| 6 | `git diff --stat` | vcs | 6,203 | 2,388 | 0.0 | 8.5 | 3.5 | 74 |
| 7 | `sleep <n>` | waiting | 5,782 | 934 | 0.8 | 108.2 | 336.6 | 880 |
| 8 | `git commit` | vcs | 5,059 | 962 | 4.2 | 13.0 | 19.2 | 98 |
| 9 | `git add` | vcs | 4,678 | 959 | - | 10.7 | 18.3 | 84 |
| 10 | `sed -i` | files | 3,939 | 812 | - | 10.4 | 28.8 | 97 |
| 11 | `uv run` | build/check | 3,749 | 243 | 4.2 | 20.3 | 59.1 | 149 |
| 12 | `git push` | vcs | 3,636 | 883 | 4.4 | 8.9 | 20.7 | 58 |
| 13 | `<poll-loop>` | waiting | 3,499 | 805 | - | 80.8 | 385.4 | 742 |
| 14 | `git show` | vcs | 3,244 | 797 | 0.7 | 1.5 | 1.0 | 12 |
| 15 | `bunx oxfmt` | build/check | 2,983 | 346 | 3.6 | 11.4 | 106.6 | 137 |
| 16 | `python3 -c` | scripting | 2,922 | 409 | 6.4 | 6.2 | 12.2 | 56 |
| 17 | `bun run typecheck` | build/check | 2,900 | 562 | 0.5 | 6.4 | 25.6 | 25 |
| 18 | `bun <script>` | build/check | 2,765 | 384 | 3.9 | 13.1 | 77.4 | 105 |
| 19 | `git fetch` | vcs | 2,195 | 431 | 1.4 | 4.6 | 7.8 | 34 |
| 20 | `bun run build` | build/check | 1,986 | 493 | 1.7 | 12.2 | 120.2 | 115 |

Recurring patterns (present in at least 5 sessions): 523 of 2,342 distinct patterns, covering 98 % of all pattern occurrences. The ten with the widest spread (action patterns):

| pattern | kind | sessions | calls |
|-|-|-|-|
| `git diff` | vcs | 3,013 | 10,435 |
| `git diff --stat` | vcs | 2,388 | 6,203 |
| `git log --oneline` | vcs | 1,145 | 7,935 |
| `git status` | vcs | 1,106 | 8,710 |
| `git commit` | vcs | 962 | 5,059 |
| `git add` | vcs | 959 | 4,678 |
| `sleep <n>` | waiting | 934 | 5,782 |
| `python3 <heredoc>` | scripting | 911 | 18,049 |
| `git push` | vcs | 883 | 3,636 |
| `bun test` | build/check | 854 | 7,377 |

### Where the time goes (tool wall hours, top 8)

| pattern | wall h | calls | p50 s | p90 s | h in calls > 120 s |
|-|-|-|-|-|-|
| `sleep <n>` | 108.2 | 5,782 | 5.7 | 336.6 | 90.7 |
| `<poll-loop>` | 80.8 | 3,499 | 9.9 | 385.4 | 70.1 |
| `grep` | 78.7 | 57,579 | 0.1 | 0.8 | 60.0 |
| `cat` | 51.7 | 19,874 | 0.1 | 9.7 | 36.2 |
| `tail` | 44.6 | 4,471 | 0.3 | 132.4 | 35.7 |
| `python3 <heredoc>` | 33.6 | 18,049 | 0.2 | 19.3 | 14.9 |
| `script wave-watch.sh` | 21.7 | 1,337 | 0.6 | 362.3 | 19.2 |
| `git status` | 21.6 | 8,710 | 0.5 | 16.6 | 13.2 |

### Per repo (top 10 by calls; IuRoot repos by name, tool-level only)

| repo | calls | sessions | top patterns |
|-|-|-|-|
| `basalt-ui` | 37,288 | 540 | `python3 <heredoc>` 5,546, `bun test` 4,189, `git status` 2,743, `bunx oxfmt` 2,429, `git log --oneline` 2,382 |
| `weatherorb` | 25,203 | 307 | `python3 <heredoc>` 3,849, `uv run` 2,886, `git status` 1,612, `git diff` 1,605, `sleep <n>` 1,361 |
| `argo` | 12,929 | 277 | `python3 <heredoc>` 2,440, `bun test` 994, `bun run typecheck` 894, `git status` 851, `git commit` 843 |
| `prometheus-scripts` (IU) | 7,541 | 52 | tools: git 4,405, grep 2,776, sed 1,989, python3 1,646, cat 1,372 |
| `warden` | 7,053 | 68 | `python3 <heredoc>` 1,321, `git log --oneline` 618, `python3 -c` 434, `git status` 393, `git diff` 362 |
| `email-gateway` | 5,520 | 353 | `python3 <heredoc>` 330, `git diff` 308, `bun test` 300, `bun run typecheck` 270, `git status` 261 |
| `research-gateway` | 4,541 | 117 | `bun test` 408, `python3 <heredoc>` 359, `bun run typecheck` 301, `git log --oneline` 236, `git diff` 233 |
| `agent-gateway` | 3,672 | 129 | `git diff` 491, `python3 <heredoc>` 478, `sleep <n>` 245, `git status` 221, `bun test` 176 |
| `dotfiles` | 3,616 | 75 | `python3 <heredoc>` 531, `git status` 365, `git log --oneline` 326, `git commit` 211, `git add` 191 |
| `rb` | 3,531 | 67 | `bun run typecheck` 198, `bun test` 195, `make query` 182, `git diff` 167, `git status` 166 |

### Failures, retries and refusals

- 1,582 calls failed (non-zero exit, excluding grep no-match and similar); 967 further non-zero exits are normal. Most common failure classes: other (unclassified) 410 (270 sessions), not found 306 (183 sessions), reported error 269 (160 sessions), sed: BSD-vs-GNU syntax error 206 (164 sessions), no such file or directory 106 (85 sessions), zsh: no matches found (unquoted glob) 76 (68 sessions).
- Retries: 372 failing calls were followed by a re-run of the same action (14 the exact same command, 328 with no edit in between, 44 after an edit); 341 succeeded on the next attempt. Loops: 335 chains of 2 attempts (325 ended ok), 14 chains of 3 attempts (14 ended ok), 3 chains of 4 attempts (2 ended ok). The blind retries cost 2.8 agent hours in total.

| pattern re-run after failing | retries | exact command | no edit between | after an edit | sessions |
|-|-|-|-|-|-|
| `bun test` | 58 | 2 | 41 | 17 | 55 |
| `gh pr view` | 14 | 0 | 14 | 0 | 11 |
| `make check` | 14 | 0 | 8 | 6 | 13 |
| `git push` | 12 | 0 | 11 | 1 | 12 |
| `git commit` | 10 | 2 | 9 | 1 | 9 |
| `rd read` | 10 | 0 | 10 | 0 | 7 |
| `git remote` | 9 | 0 | 9 | 0 | 9 |
| `git show` | 9 | 0 | 9 | 0 | 8 |

| refused by | calls | sessions | agent h to next call | top repos |
|-|-|-|-|-|
| harness: sleep-then-command polling blocked | 515 | 398 | 6.22 | basalt-ui, weatherorb, argo |
| harness: worktree isolation guard -- command too complex to verify it stays inside | 365 | 51 | 0.67 | weatherorb, rb, rollhook |
| harness: worktree isolation guard -- command redirects outside the worktree | 40 | 24 | 0.22 | weatherorb, image-share, warden |
| harness: worktree isolation guard -- command runs an unverifiable command | 22 | 13 | 0.02 | weatherorb, dotfiles, rb |
| hook: Raw docker/docker-compose commands are blocked when a Makefile exists. | 21 | 16 | 0.04 | weatherorb, <iu:prometheus-scripts>, <iu:prometheus-stack> |
| permission denied by harness | 21 | 8 | 0.94 | warden, dotfiles, basalt-ui |
| hook: git push --force is blocked in Claude Code. | 15 | 15 | 0.01 | basalt-ui, <iu:prometheus-scripts>, rollhook |
| hook: Pushing to protected branch 'master' is blocked in Claude Code | 10 | 8 | 0.01 | basalt-ui, rollhook |
| hook: Pushing to protected branch 'main' is blocked in Claude Code | 8 | 4 | 0.02 | <iu:prometheus-scripts>, <iu:epos.student-enrolment> |
| hook: Pushing to a protected branch is blocked in Claude Code | 6 | 6 | 0.01 | basalt-ui |

### Call groups behind the candidates (disjoint: a call joins the first matching group)

| group | calls | sessions | agent step h | tool wall h | failed | top repos |
|-|-|-|-|-|-|-|
| `verify-loop` | 14,293 | 1,304 | 162.49 | 58.61 | 81 | basalt-ui, argo, weatherorb |
| `poll:shell-loop` | 2,516 | 558 | 148.22 | 71.9 | 37 | weatherorb, basalt-ui, <iu:prometheus-scripts> |
| `poll:orchestrator-status` | 3,766 | 258 | 116.66 | 27.61 | 33 | basalt-ui, argo, weatherorb |
| `poll:sleep` | 2,035 | 443 | 76.13 | 30.27 | 31 | basalt-ui, weatherorb, argo |
| `kill-sleep-kill-rm` | 1,031 | 340 | 10.35 | 9.5 | 25 | <sideclaw-job>, email-gateway, <agw-job> |
| `local-health-curl` | 919 | 183 | 7.8 | 0.98 | 25 | weatherorb, warden, <iu:prometheus-scripts> |
| `blocked:sleep-then-command` | 515 | 398 | 6.22 | 0.01 | 0 | basalt-ui, weatherorb, argo |
| `process-by-hand` | 818 | 275 | 5.86 | 1.12 | 7 | weatherorb, basalt-ui, <iu:prometheus-scripts> |
| `vps-homelab-container-inspect` | 455 | 68 | 3.9 | 0.43 | 17 | weatherorb, email-gateway, homelab-private |
| `fail:bsd-vs-gnu-and-glob` | 530 | 360 | 1.65 | 0.33 | 293 | basalt-ui, weatherorb, argo |
| `launchd-by-hand` | 221 | 78 | 1.65 | 0.15 | 4 | weatherorb, warden, dotfiles |
| `blocked:worktree-isolation-guard` | 433 | 55 | 0.91 | 0.01 | 0 | weatherorb, rb, modelpick |
| `dependency-updates` | 114 | 35 | 0.47 | 0.07 | 3 | weatherorb, argo, basalt-ui-obsidian |
| `blocked:git-and-docker-hooks` | 60 | 46 | 0.09 | 0.0 | 0 | basalt-ui, <iu:prometheus-scripts>, weatherorb |

Agent step time is the time from one Bash call to the next (1,296.7 h in total, median turn 5.9 s); it includes waiting inside the call, which is why polling groups look large. Only removable turns are claimed in section 6. For comparison, the proper waiting tools were called 1,138 times (`Monitor`), 2,612 times (gateway `job_wait`) and 471 times (`ScheduleWakeup`), against 2,550 `sleep` calls and 2,516 shell polling loops.

## 3. Recurring recipes (same 3-5 patterns in at least 5 sessions)

6,614 frequent 3-5-grams, 4,198 maximal after dropping sub-sequences. Top by sessions x (length - 1):

| sequence | sessions | occurrences | median calls spanned | median span s |
|-|-|-|-|-|
| `git add > git commit > git push` | 702 | 2232 | 1 | 0.0 |
| `git add > git commit > git push > git log --oneline` | 387 | 1212 | 1 | 0.0 |
| `kill > sleep <n> > kill > rm <path>` | 269 | 331 | 1 | 0.0 |
| `git add > git commit > git log --oneline` | 384 | 970 | 1 | 0.0 |
| `git add > git commit > git push > git log --oneline > git status` | 181 | 261 | 1 | 0.0 |
| `git status > git add > git commit` | 354 | 511 | 2 | 3.3 |
| `git add > git commit > git push > gh pr create` | 231 | 272 | 1 | 0.0 |
| `git remote > kill > sleep <n> > kill > rm <path>` | 165 | 165 | 2 | 5.1 |
| `git status > git add > git commit > git push` | 196 | 237 | 2 | 3.3 |
| `python3 <heredoc> > git add > git commit > git push` | 156 | 366 | 1 | 0.0 |
| `git push > git log --oneline > git status` | 233 | 360 | 1 | 0.0 |
| `python3 <heredoc> > git diff --stat > python3 <heredoc>` | 233 | 355 | 3 | 14.2 |
| `git add > git commit > git log --oneline > git status` | 153 | 246 | 1 | 0.0 |
| `python3 <heredoc> > git add > git commit` | 228 | 518 | 1 | 0.0 |
| `python3 <heredoc> > sed -i > python3 <heredoc>` | 200 | 257 | 3 | 15.4 |

A median of 1 call means the agent already chains the steps in one Bash call: a verb would save tokens, not turns. Sequences that really span several calls:

| sequence | sessions | occurrences | over several calls | median calls spanned | median span s |
|-|-|-|-|-|-|
| `git status > git add > git commit` | 354 | 511 | 282 | 2 | 3.3 |
| `git remote > kill > sleep <n> > kill > rm <path>` | 165 | 165 | 163 | 2 | 5.1 |
| `git status > git add > git commit > git push` | 196 | 237 | 124 | 2 | 3.3 |
| `python3 <heredoc> > git diff --stat > python3 <heredoc>` | 233 | 355 | 354 | 3 | 14.2 |
| `python3 <heredoc> > sed -i > python3 <heredoc>` | 200 | 257 | 249 | 3 | 15.4 |
| `bun test > git add > git commit` | 198 | 375 | 236 | 2 | 8.0 |
| `git add > git commit > git push > gh pr create > python3 <heredoc>` | 86 | 90 | 90 | 3 | 259.1 |
| `bun test > python3 <heredoc> > bunx oxfmt > bun test` | 114 | 164 | 164 | 3 | 19.5 |
| `git diff > git diff --stat > git diff` | 170 | 174 | 169 | 3 | 10.6 |
| `bun test > git add > git commit > git push` | 112 | 206 | 122 | 2 | 11.0 |

Extra calls spent on consecutive steps of one kind (distinct calls in a run minus one): 1,677 on verification (`bun test`, `bunx oxfmt`, typecheck, lint, build) and 229 on git add / commit / push / `gh pr create`.

## 4. Recurring warden item families (the toil the loop repeats)

556 items (364 in 30 days), 41 duplicate rows; 415 items needed an agent job (1,268 jobs, 209 agent hours); 114 escalated, 264 owner-touched. Families with at least 3 items (or 2 in 30 days): 31, covering 84 % of items. One-off families: 88 (88 items). `human:` and `github_go: issue` rows are intake (owner or agent briefs), listed for scale, not toil.

| family | items | 30 d | dup rows | outcomes | needed an agent job | jobs | agent min | escalated | owner touch |
|-|-|-|-|-|-|-|-|-|-|
| `human: owner/agent brief (free text)` | 162 | 112 | 0 | 153 res, 4 ign, 4 open, 1 fail | 162 (100 %) | 559 | 8193.3 | 33 | 98 |
| `github_go: issue (free text)` | 99 | 79 | 3 | 86 res, 12 open, 3 dup, 1 fail | 97 (98 %) | 402 | 3395.6 | 21 | 48 |
| `uk monitor (push)` | 22 | 10 | 1 | 11 quiet, 8 res, 2 ign, 1 dup, 1 fail | 16 (73 %) | 102 | 372.4 | 8 | 14 |
| `hermes log agent.tool_executor: tool terminal returned error (<n>.<n>s):` | 16 | 6 | 0 | 16 res | 6 (38 %) | 3 | 17.8 | 0 | 14 |
| `uk monitor (http)` | 16 | 14 | 0 | 15 quiet, 1 res | 7 (44 %) | 4 | 10.4 | 4 | 7 |
| `kuma http up: <n> - ok` | 14 | 11 | 0 | 14 ign | 0 (0 %) | 0 | 0 | 0 | 0 |
| `hermes log tools.checkpoint_manager: git command failed: git add` | 11 | 0 | 0 | 11 res | 8 (73 %) | 8 | 137.5 | 0 | 8 |
| `kuma http up: <n> - ok, keyword is found` | 11 | 8 | 0 | 11 ign | 0 (0 %) | 0 | 0 | 0 | 0 |
| `kuma docker down: container state is exited` | 10 | 1 | 10 | 10 dup, 5 quiet, 2 ign, 2 res, 1 open | 5 (50 %) | 13 | 6.5 | 1 | 4 |
| `kuma http down: request failed with status code <n>` | 10 | 7 | 1 | 7 open, 3 quiet, 1 dup | 7 (70 %) | 4 | 1.2 | 7 | 7 |
| `kuma http down: timeout of <n>ms exceeded` | 10 | 10 | 1 | 8 open, 2 res, 1 dup | 10 (100 %) | 6 | 2.8 | 8 | 9 |
| `hermes log agent.chat_completion_helpers: streaming failed before delivery: error` | 9 | 7 | 0 | 8 res, 1 quiet | 8 (89 %) | 12 | 40.2 | 1 | 3 |
| `uk monitor (docker)` | 9 | 9 | 5 | 5 dup, 5 quiet, 4 res | 9 (100 %) | 7 | 1.9 | 5 | 5 |
| `uk monitor (group)` | 8 | 1 | 1 | 8 quiet, 1 dup | 1 (12 %) | 3 | 12.3 | 0 | 0 |
| `github_go alert: store_stale` | 6 | 6 | 0 | 6 res | 6 (100 %) | 12 | 13.8 | 0 | 0 |
| `hermes log tools.checkpoint_manager: git command skipped: git rev-parse` | 6 | 4 | 0 | 6 res | 3 (50 %) | 8 | 15.0 | 3 | 6 |
| `github_go alert: workflow_failed` | 5 | 5 | 1 | 5 res, 1 dup | 5 (100 %) | 8 | 6.1 | 2 | 2 |
| `statuspage incident: auto-resolved` | 5 | 4 | 0 | 5 ign | 0 (0 %) | 0 | 0 | 0 | 0 |
| `statuspage incident: opened` | 5 | 4 | 0 | 5 ign | 0 (0 %) | 0 | 0 | 0 | 0 |
| `docker unhealthy` | 4 | 3 | 0 | 4 quiet | 1 (25 %) | 3 | 12.1 | 0 | 1 |

## 5. Human-queue asks by kind

119 asks since 2026-08-07 (87 in the last 30 days): 7 denied, 83 done, 23 failed, 4 no-result, 2 superseded. 15 asks are retries of an earlier failed ask. Failure causes: 1password-locked-or-unreachable 4, acl-push-guard-or-diff 3, op-item-validation 1, op-stdin-read-as-json-template 11, other 4.

| kind | asks | 30 d | done | failed | denied / superseded | retry asks | failure causes |
|-|-|-|-|-|-|-|-|
| `1password-write` | 32 | 28 | 21 | 11 | 0 | 9 | op-item-validation 1, op-stdin-read-as-json-template 10 |
| `secrets-cache-reseal` | 21 | 14 | 16 | 2 | 2 | 0 | op-stdin-read-as-json-template 1, other 1 |
| `1password-lookup` | 19 | 15 | 16 | 3 | 0 | 1 | 1password-locked-or-unreachable 2, other 1 |
| `tailnet-acl-push` | 13 | 12 | 5 | 5 | 3 | 5 | 1password-locked-or-unreachable 2, acl-push-guard-or-diff 3 |
| `mini-host-cleanup` | 11 | 2 | 11 | 0 | 0 | 0 | - |
| `macbook-host-action` | 7 | 6 | 4 | 2 | 0 | 0 | other 2 |
| `tcc-fda-grant-or-protected-read` | 4 | 3 | 1 | 0 | 1 | 0 | - |
| `other` | 3 | 2 | 2 | 0 | 1 | 0 | - |
| `aws-sso-login` | 2 | 0 | 0 | 0 | 2 | 0 | - |
| `owner-decision-question` | 2 | 2 | 2 | 0 | 0 | 0 | - |
| `third-party-account-or-token` | 2 | 1 | 2 | 0 | 0 | 0 | - |
| `github-credential-setting` | 1 | 1 | 1 | 0 | 0 | 0 | - |
| `service-restart` | 1 | 0 | 1 | 0 | 0 | 0 | - |
| `warden-cli-action` | 1 | 1 | 1 | 0 | 0 | 0 | - |

## 6. Candidate automation

Ranked by value hours = owner hours + 0.2 x agent hours (an agent hour is worth a fifth of an owner hour: agents run in parallel and cost quota, the owner's attention is the scarce resource). Both hour columns are always shown. Owner minutes per ask (3), per escalation (6), per resume (45 s) and per reset (3 s) are assumptions. Agent hours are removed calls x the measured median turn of 5.9 s (waiting time that would remain is not claimed; the measured step time is quoted as an upper bound where it differs), or warden job minutes where a loop investigation disappears. Shares removed are stated per row.

| id | pattern | frequency (30 d) | who repeats it | mechanism | owner h / month | agent h / month | arithmetic |
|-|-|-|-|-|-|-|-|
| C01 | Monitor and container outage items (Kuma down, uk monitor, unhealthy container, watchdog, job failure): one item and one investigation per page | 72 items, 80 agent jobs, 37 escalations | warden loop + owner (escalations) | reconciler (level-triggered conditions) + correlation (topology / 15-min window fold: one outage = one incident) | 2.6 | 0.8 | owner: 37 escalations x 6 min x 70 % / 60; agent: 72 job-min x 70 % / 60 |
| C02 | Escalations (`needs_decision`) raised on intake items, the owner's and agents' own briefs and issues | 54 escalations on 191 items, 831 agent jobs | owner (decisions) + warden loop | policy line (the fixed owner-decision rule: product direction, spend, irreversible data loss, other people) + verification ladder (everything else is decided on evidence) | 2.7 | 0 | 54 escalations x 6 min x 50 % not a genuine owner decision / 60 |
| C03 | `claude --resume <session id>` typed by hand (find the id, paste) | 123 / month | owner (shell) | reconciler (herdr restores the agents that were running after a crash or reboot) + CLI verb (`rd resume <repo>`) | 1.5 | 0 | 123 resumes x 45 s / 3600 |
| C04 | Hermes log lines opened as items (tool errors, checkpoint-manager git skips, streaming failures, second gateway instance) | 23 items, 48 agent jobs, 14 owner touches | warden loop (+ owner touches) | known-error store (fix once, recognise the fingerprint) + policy line (expected skips are logged below ERROR) | 1.1 | 2.0 | owner: 14 touches x 6 min x 80 % / 60; agent: 147 job-min x 80 % / 60 |
| C05 | 1Password item writes via the human-queue (op item create/edit/rename); stdin read as a JSON template | 28 asks, 10 failed | owner (dialog) + agent (retry ask) | CLI verb (`secrets put\|rename`, JSON-safe, idempotent) + policy line (never pipe JSON into `op item create`) | 1.0 | 0 | 10 failed asks x 2 asks (the failed one and its retry) x 3 min / 60 |
| C06 | Orchestrators polling agent and PR state (`rd agents`, `rd read`, wave-watch, `herdr agent wait\|list\|get`, `gh pr checks`) | 3766 calls in 258 sessions | agents (orchestrator tabs) | reconciler (event log + push: a finished wave or red check wakes the orchestrator) | 0 | 4.9 | 3766 calls x 80 % x 5.9 s / 3600 |
| C07 | 1Password lookups (item titles / field names, no values) | 15 asks | owner (dialog) | CLI verb (`secrets ls` answering from the sealed cache, no dialog) | 0.8 | 0 | 15 asks x 3 min x 100 % / 60 |
| C08 | Push the tailnet ACL from the private repo (diff, confirm, apply); guard aborts and retries | 12 asks, 5 failed | owner (dialog + typed confirm) | Renovate-style tool (GitOps: verify on PR, apply on merge, drift check) | 0.6 | 0 | 12 asks x 3 min x 100 % / 60 |
| C09 | `sleep <n>` polls for a job, CI run or service (one model turn per poll) | 2035 calls in 443 sessions | agents (interactive) | reconciler (event-driven wake: herdr events and job completion push to the waiting agent) | 0 | 2.7 | 2035 polls x 80 % x 5.9 s median turn / 3600 (the waiting itself is not claimed) |
| C10 | Reseal the mini secrets cache after `headless.refs` changed | 14 asks | owner (dialog) | reconciler (refs file = desired, sealed cache = observed; one batched approval instead of one per change) | 0.5 | 0 | 14 asks x 3 min x 70 % batched away / 60 |
| C11 | Verification run as separate calls in a row (`bun test`, `bunx oxfmt`, typecheck, lint, build) | 1677 extra calls | agents | CLI verb + policy line (one `make check` per repo, the same entrypoint everywhere) | 0 | 1.9 | 1677 extra calls x 70 % x 5.9 s / 3600 |
| C12 | Scheduled-job alerts as GitHub issues (store_stale, workflow_failed, job_down, disk_low): an item and an investigation each time | 22 items, 33 agent jobs | warden loop | recurring job (per-signal self-heal with the fix recipe in the known-error store) | 0.3 | 0.3 | owner: 5 touches x 6 min x 60 % / 60; agent: 29 job-min x 60 % / 60 |
| C13 | Estate chores that need a present human (sudo cleanups, TCC / Full Disk Access grants, host installs, token pages) | 14 asks | owner (dialog) | recurring job (monthly estate sweep, one batched approval) + policy line (grant TCC once per machine) | 0.3 | 0 | 14 asks x 3 min x 50 % batched or granted once / 60 |
| C14 | `reset` typed after a Claude launcher exits (terminal left in a bad state) | 337 resets / month, 258 directly after a launcher | owner (shell) | policy line in the launcher (`c` restores the TTY on exit) | 0.3 | 0 | 337 resets x 3 s / 3600 |
| C15 | Process cleanup recipe `kill -> sleep -> kill -> rm` (stale dev / test servers and lockfiles) | 1031 calls in 340 sessions | agents (incl. agw / sideclaw jobs) | recurring job (reaper for stale agent-owned processes and locks) + CLI verb (`rd kill-tree`) | 0 | 1.4 | 1031 calls x 80 % x 5.9 s / 3600 (upper bound, whole step time: 10.35 h) |
| C16 | Local health probes by hand (`curl localhost:<port>/health`) | 919 calls in 183 sessions | agents | reconciler (health probes declared in the project manifest, state read from the event log) | 0 | 0.9 | 919 calls x 60 % x 5.9 s / 3600 |
| C17 | `sleep N && <command>` polling that the harness blocks, then re-issued differently | 515 blocked calls in 398 sessions | agents (interactive) | policy line (wait with `rd wait` / `agw wait` / Monitor, never `sleep N &&`) | 0 | 0.8 | 515 blocked calls x 100 % x 5.9 s median turn / 3600 (measured time to the next call, an upper bound: 6.22 h) |
| C18 | GNU-isms on macOS: `sed -i` / `sed` syntax errors, unquoted zsh globs, `head -n -N`, GNU-only flags | 530 failing calls in 360 sessions | agents (interactive) | policy line (BSD userland: `sed -i ''`, quote globs; prefer the Edit tool) + PreToolUse rewrite | 0 | 0.8 | 530 failing calls x 90 % x 5.9 s / 3600 (upper bound, measured step time: 1.65 h) |
| C19 | Commands refused by the worktree-isolation guard and by the git / docker hooks (force push, protected branch, raw docker) | 493 blocked calls | agents (worktree and interactive sessions) | policy line (AGENTS.md: what stays inside a worktree; merge only via `rd merge` / PR) | 0 | 0.6 | 493 blocked calls x 80 % x 5.9 s / 3600 (upper bound, measured: 1.00 h) |
| C20 | Container inspection on the VPS and homelab by hand (`ssh <host>: docker ps\|logs\|exec\|inspect`) | 455 calls in 68 sessions | agents | CLI verb (`vps\|hl ps\|logs`) or an Argo read model | 0 | 0.4 | 455 calls x 50 % x 5.9 s / 3600 |
| C21 | git add / commit / push / `gh pr create` issued as separate calls in a row | 229 extra calls | agents | CLI verb (`git ship`; the `/commit` skill as the only way) | 0 | 0.3 | 229 extra calls x 90 % x 5.9 s / 3600 |
| C22 | launchd inspection and restarts by hand (`launchctl print\|list\|kickstart`) | 221 calls in 78 sessions | agents | reconciler (desired launchd jobs from the manifest, kickstart when unhealthy) | 0 | 0.3 | 221 calls x 70 % x 5.9 s / 3600 |
| C23 | Dependency checks and bumps by agents (`bun outdated\|update`, `npm outdated`, `ncu`, `uv lock`, `brew outdated\|upgrade`) | 114 calls in 35 sessions | agents | Renovate-style tool (mechanical bumps as PRs; agents only for breaking changes) | 0 | 0.2 | 114 calls x 90 % x 5.9 s / 3600 |
| C24 | Recovery notifications opened as items (Kuma up, status-page opened / auto-resolved) and closed `ignored` | 32 items, 0 agent jobs | warden loop | reconciler (an `up` event closes the matching condition and never creates an item) | 0.0 | 0.0 | 32 items, no agent job, no owner touch: noise removed, hours measured = 0 job-min / 60 |
| C25 | Shell polling loops (`until\|while\|for ... sleep`) that park a session in one long call | 2516 loops in 558 sessions, 71.9 h of wall time | agents | reconciler (event-driven wake frees the session; no turns removed, so no hours claimed) | 0 | 0 | each loop is one call: turns removed = 0; wall time parked = 71.9 h (not claimed) |

Every share removed (50 to 100 %) is an assumption stated in the row's arithmetic; the rows are disjoint (owner asks by kind, warden families by name predicate, agent calls by first matching group), so the hours add up.

- C01: 70 % folded is an assumption (the 10-17 outage folds 16 pages into 1)
- C02: 50 % is a placeholder until the golden set labels `genuine_owner_decision`; replace it with the measured share
- C03: 45 s per resume is an assumption
- C09: 80 % is an assumption; some sleeps are legitimate pacing
- C14: 3 s per reset is an assumption
- C15: 80 % is an assumption; each recipe is one chained call, so a verb alone saves tokens, the reaper saves the call
- C21: 90 % is an assumption; most commit recipes are already one chained call (median 1), only the separate ones count
- C24: pure ledger and card churn; hours are ~0 by measurement
- C25: listed so the omission is visible; latency and parallelism gain, not toil hours

Sum over all rows: 11.7 owner hours and 18.3 agent hours per month.

## 7. Caveats

- Shell histories carry no timestamps; per-month figures assume a 30-day window. Launches in the history against sessions in the transcripts give an upper bound for the real window (mini 44.8 days, iumac 37.6 days), so the monthly owner figures are upper bounds too (divide by 1.3 to 1.5 for the longer window).
- `ran_at` in the human-queue is stamped when the dialog is shown, so owner response time is not measurable; owner minutes per ask are an assumption.
- The mini history mixes hand-typed commands with lines that rd/herdr type into panes; the latter are separated by prefix and counted apart.
- A failing call is attributed to its last non-glue command; `fail %` is shown only for patterns that are the last command in at least 100 calls.
- Warden families come from rule-based title normalisation; a title the rules do not know falls into `<source>: <first words>` and is a one-off.
- Skill launches and typed slash commands are distinct records: this Claude Code version stores owner-typed skill commands as a skill expansion, so the `<command-name>` table holds mostly built-ins and `/loop`.

## Reproduce

`cd` to this directory and run `python3 -I toil.py` (about 20 s; transcripts, `warden.db` and `human-queue/` are read from the frozen snapshots and the 30-day transcript window). The two shell-history aggregates `history-mini.agg.json` and `history-iumac.agg.json` are frozen on the first successful read, because zsh history is a rolling file without timestamps and the IU MacBook is only reachable when it is awake; delete one (or set `TOIL_REFRESH_HISTORY`) to re-read it. They hold normalised patterns and counts only.

