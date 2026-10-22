# What the owner asks about the estate -- question inventory

AS_OF 2026-10-22T08:00:00Z. Built by `questions.py` from his own messages (`questions.out.json`, `candidates.out.json`). Phase 1/5 evidence: Argo is designed from these questions, so every row below is a class of real owner messages, not an imagined one. Numbers here are rendered from the JSON; nothing is typed by hand except the paraphrases and the verdict wording.

## Verdict

- **1111 owner messages** survive the provenance gate (Claude Code on the mini 682, on the MacBook 352, Hermes 77). **211** (18%) fall into one of **27 canonical questions**; 119 of them are phrased as a question. The remaining messages are direction, product feedback and personal research.
- **He asks his session agents, not his tools.** 199 classified asks went to a Claude Code session in a repo root, 12 to Hermes. Hermes drew 77 owner messages in 60 days, 2 of them through Argo's chat (Argo UI views are not logged in these sources). Besides Slack alerts, the standing push is the 07:00 briefing.
- **Ranking (frequency x recency):** continue-nudges to parked agents (50); where are we / how is it going (28); is it done, merged, live (19); Claude quota and reset time (12); is anything broken (11); why does X not work (11); approvals the agent could take (15); what happened while I was away (8). Classes marked implied are needs he states instead of asks.
- **The loudest signal is not a question.** 50 messages are `continue` / `go` / `limit resets in 5 min` typed at an agent that had stopped with work left, on 25 of the last 45 days; consecutive nudges in one session are a median 4.4 h apart. Which agent is parked, and why, is something he has to find out himself.
- **Answer not at hand:** 18 of 27 classes were asked on a day with at least two asks; 14 asks repeat within 2 h in the same session (strongest in: nudge_continue, where_are_we, quota_now).
- **The push does not stop the asking.** 37 classified asks fall in classes the Hermes morning briefing already touches (infrastructure, warnings, agents and projects, needs-decision counts); he asked anyway, mid-session, with the repo's agent. The briefing counts and lists; it does not say which agent is stuck, what shipped, or what the quota is.
- **Every answer is rebuilt from scratch.** Across answered turns the median is 48 s to a final answer after 5.0 tool calls; 7% are answered with no tool call. The agent runs `git read (log/status/diff/branch)`, `curl (HTTP probe)`, `herdr agent`, `host probe (ps/df/launchctl)`, `ssh` -- there is no read model to ask (answered turns measured: 80).
- **Named in the prompts, never a question in the logs:** per-project traffic and dependency state appear only as tool setup and directives (see the design-prompt table). Build them behind the exception line.

## Method and limits

- **Owner message:** `origin.kind == human`, CLI entrypoint, not sidechain, not a wrapper, not an agent brief, session cwd not a worktree, deduplicated by uuid. Briefs, relays and fleet traffic typed into panes look human to Claude Code, so they are removed by pattern (`AGENT_FED`) and by cwd. This errs towards dropping real messages: precision over recall.
- **A class counts a message once;** one message can hold several questions. Classes are plain regex rules in `CATALOG`, nothing is learned. `question form` = a `?`, an interrogative or status stem, or an uncertainty marker.
- **Rank** = sum of 0.5^(age/14 d) over the class's messages. Days are UTC. Repeat day = a day with >= 2 asks of the class across all sessions; fast repeat = the same class re-asked in the same session within 2 h.
- **Latency** = owner message to the first final answer (`stop_reason end_turn`); turns that were interrupted or ran past 150 assistant entries are not timed. Hermes uses the first `finish_reason stop`.
- **Probes excluded:** Hermes API sessions `api-*`, `oneshot` and `cli` messages are run by agents ("reply with pong", "Validation r3: how many open watchdog items?"): 47 in the window, listed under *Synthetic probes*.
- **Privacy:** excerpts are <= 160 chars and redacted; IuRoot sessions contribute counts and repo names only. Sessions in `brain/` and `~` count only when they name an estate entity.
- **MacBook leg degraded:** ssh unavailable (remote rc=255: ssh: connect to host iumac port 2222: Operati); rows from an earlier raw dump of the same window, no turn metrics. Counts include those rows; latency and answer paths for MacBook-only asks are missing.

## Funnel

| Stage | n |
|-|-|
| transcript files in window, mini | 5620 |
| human-origin entries in window, mini | 2703 |
| of which agent-fed briefs / wrappers removed | 1985 |
| owner messages, mini | 682 |
| MacBook leg | ssh unavailable (remote rc=255: ssh: connect to host iumac port 2222: Operati); rows from an earlier raw dump of the same window, no turn metrics |
| human-origin entries in window, MacBook | 3066 |
| of which agent-fed briefs / wrappers removed | 2714 |
| owner messages, MacBook | 352 |
| Hermes user messages scanned (60 d) | 1677 |
| Hermes owner messages (slack, desktop, tui, cli) | 77 |
| Hermes agent-authored probes | 47 |
| owner messages, all channels | 1111 |
| classified into a canonical question | 211 |
| of which in question form | 119 |
| question-form, no class (residue) | 80 |

## The questions, ranked by frequency x recency

| # | Question | Asks (q-form) | Last 14 d / prior 31 d | Days | Repeat days (max/day) | Fast repeats | Channels | Median answer | Push |
|-|-|-|-|-|-|-|-|-|-|
| 1 | (implied) Which parked agent must I nudge to continue -- quota reset, laptop closed, crash? | 50 (0) | 24 / 26 | 25 | 12 (6) | 8 | cc macbook 41, cc mini 9 | - | no |
| 2 | Where are we on this effort -- how is it going? | 28 (26) | 18 / 10 | 19 | 7 (3) | 1 | cc macbook 10, cc mini 15, h slack 3 | 38 s (n=14) | no |
| 3 | Is it done, merged, deployed and verified live? Can I close the thread? | 19 (19) | 11 / 8 | 11 | 3 (5) | 0 | cc macbook 3, cc mini 16 | 46 s (n=15) | no |
| 4 | Where is my Claude quota (5 h / 7 d) and when does it reset? | 12 (2) | 10 / 2 | 7 | 2 (4) | 1 | cc macbook 7, cc mini 4, h slack 1 | 34 s (n=4) | no |
| 5 | Is everything healthy -- is anything broken right now? | 11 (11) | 7 / 4 | 9 | 2 (2) | 0 | cc macbook 5, cc mini 4, h slack 1, h tui 1 | 47 s (n=6) | yes |
| 6 | Why does X not work / fail / show the wrong thing? | 11 (11) | 6 / 5 | 10 | 1 (2) | 0 | cc macbook 5, cc mini 6 | 24 s (n=6) | no |
| 7 | (implied) Which approvals am I still giving that the agent could decide itself? | 15 (4) | 5 / 10 | 9 | 3 (4) | 0 | cc mini 15 | - | no |
| 8 | What happened while I was away (overnight, vacation, laptop closed)? | 8 (4) | 5 / 3 | 7 | 1 (2) | 0 | cc macbook 4, cc mini 3, h slack 1 | 54 s (n=3) | partial |
| 9 | Which herdr tabs / agents are finished and can be closed? Why are so many open? *(implied)* | 9 (4) | 4 / 5 | 7 | 2 (2) | 0 | cc macbook 3, cc mini 5, h slack 1 | - | no |
| 10 | Is that agent still running, stuck, or done -- does it need something? | 10 (7) | 5 / 5 | 10 | 0 (1) | 0 | cc macbook 2, cc mini 7, h slack 1 | 2 min (n=8) | no |
| 11 | Is a connection or credential broken -- do I need to log in / unlock something? | 9 (8) | 4 / 5 | 9 | 0 (1) | 0 | cc macbook 4, cc mini 4, h slack 1 | 21 s (n=5) | no |
| 12 | Is a host low on disk / CPU / memory -- what is eating it? *(implied)* | 6 (0) | 5 / 1 | 4 | 1 (3) | 0 | cc macbook 3, cc mini 3 | - | partial |
| 13 | How are all my agents / tabs / waves doing, across projects and hosts? | 7 (6) | 4 / 3 | 6 | 1 (2) | 0 | cc macbook 1, cc mini 3, h slack 3 | 29 s (n=6) | partial |
| 14 | What does it cost -- is cost / usage tracking wired and right? | 7 (5) | 4 / 3 | 7 | 0 (1) | 0 | cc macbook 2, cc mini 5 | 10 s (n=3) | no |
| 15 | Are the docs / AGENTS.md / skills current and consistent? | 6 (5) | 5 / 1 | 6 | 0 (1) | 0 | cc macbook 1, cc mini 5 | 58 s (n=4) | no |
| 16 | Where do I see the report / PR / dashboard / result? | 6 (3) | 3 / 3 | 5 | 1 (2) | 0 | cc macbook 2, cc mini 4 | 38 s (n=4) | no |
| 17 | What is still pending / missing / open in the plan? | 4 (4) | 3 / 1 | 3 | 1 (2) | 0 | cc mini 4 | 37 s (n=3) | no |
| 18 | What is waiting for me? Which agent or item needs my input? | 5 (3) | 4 / 1 | 5 | 0 (1) | 0 | cc macbook 2, cc mini 2, h slack 1 | 6 min (n=2) | partial |
| 19 | Did the automatic recovery / self-healing work -- or did I have to intervene? | 5 (4) | 1 / 4 | 3 | 1 (3) | 1 | cc macbook 4, cc mini 1 | 68 s (n=1) | no |
| 20 | Is X wired end to end -- observability, cost tracking, Hermes access? | 3 (2) | 3 / 0 | 2 | 1 (2) | 1 | cc mini 2, h desktop 1 | 34 s (n=3) | no |
| 21 | Which version runs where -- is the latest code on stage and prod? | 3 (3) | 2 / 1 | 2 | 1 (2) | 1 | cc mini 3 | 3 min (n=3) | no |
| 22 | Are my machines / tools / dependencies up to date -- what still needs an update or restart? | 4 (4) | 2 / 2 | 3 | 1 (2) | 1 | cc macbook 3, cc mini 1 | n/a (n=0) | no |
| 23 | Which model / tool / version is configured -- do we have access to the new one? | 4 (4) | 1 / 3 | 3 | 1 (2) | 0 | cc mini 3, h argo 1 | 42 s (n=4) | no |
| 24 | What did warden / the loop handle alone -- why did this reach me? *(implied)* | 3 (3) | 2 / 1 | 3 | 0 (1) | 0 | cc macbook 1, cc mini 2 | - | no |
| 25 | Is the data / report / page fresh -- how old is it? | 2 (2) | 1 / 1 | 2 | 0 (1) | 0 | cc mini 2 | 4 min (n=2) | no |
| 26 | Did the nightly / scheduled / auto-update job run, and did it succeed? | 2 (2) | 1 / 1 | 2 | 0 (1) | 0 | cc mini 2 | 6 min (n=2) | no |
| 27 | Why does this keep coming back -- is the recurring issue resolved? | 3 (3) | 0 / 3 | 3 | 0 (1) | 0 | cc mini 2, h slack 1 | 63 s (n=3) | no |

`Repeat days`: a number here means the answer was not at hand on that day. `Push`: whether the Hermes morning briefing already carries the class (yes, partial, no). Implied classes are needs the owner states instead of asks.

## Per question: paraphrase, entities, how he gets the answer today

### 1. (implied) Which parked agent must I nudge to continue -- quota reset, laptop closed, crash?

- **Paraphrase:** 'continue' / 'go' / 'limit resets in 5 min' typed at an agent that stopped and waited for him.
- **Asked:** 50 messages (0 in question form) over 25 days, 2026-09-20 to 2026-10-21; last 14 d 24. Where: shutterflow 38, weatherorb 3, tinycast-extensions 2, research-gateway 2, basalt-ui 2, dotfiles 1
- **Entities the answer needs:** Agent, Quota window, Infra host (MacBook power/lid). Named in the asks: Agent 4, Cost/quota 3, Task/plan 2, Deployment 1, Infra host 1
- **What the agent does next:** `git read (log/status/diff/branch)` 78%, `subagent (Explore/worker)` 33%, `rd agents` 33%, `herdr agent` 33%; also Read file 11%, fs read (cat/ls/grep) 100%, git write (add/commit/push/pull) 67%, script run (python/node/bun) 67%. Tool calls per answered turn (median) 8.0; answered without a tool call 0%.
- **Time:** an action, not an answer. After it the agent runs a median 80 s before it ends its turn again (n=8); consecutive asks in one session are a median 4.4 h apart.
- **Repeated within a day:** 12 day(s) with >= 2 asks (max 6 in one day); fast same-session repeats 8. Days: 2026-09-20, 2026-09-24, 2026-09-27, 2026-10-02, 2026-10-03, 2026-10-06, 2026-10-11, 2026-10-15

### 2. Where are we on this effort -- how is it going?

- **Paraphrase:** Where are we at with the thing you are working on, how is it going?
- **Asked:** 28 messages (26 in question form) over 19 days, 2026-09-13 to 2026-10-21; last 14 d 18. Where: tinycast-extensions 6, prometheus-scripts 4, (hermes) 3, weatherorb 3, shutterflow 3, email-gateway 2
- **Entities the answer needs:** Agent, Task (wave/plan), Project, Change, Attempt. Named in the asks: Agent 3, Infra host 2, Project 1, Incident/alert 1, Task/plan 1
- **Answer today:** `git read (log/status/diff/branch)` 53%, `herdr agent` 33%, `rd agents` 33%, `curl (HTTP probe)` 27%; also edit/write files 7%, fs read (cat/ls/grep) 93%, git write (add/commit/push/pull) 20%, script run (python/node/bun) 60%. Tool calls per answered turn (median) 4.5; answered without a tool call 7%.
- **Time:** median 38 s, p90 4 min to a final answer after 9.5 assistant entries (n=14 of 15 measured turns); first visible text 54 s. Consecutive asks in one session: median 11.9 h apart.
- **Repeated within a day:** 7 day(s) with >= 2 asks (max 3 in one day); fast same-session repeats 1. Days: 2026-10-07, 2026-10-09, 2026-10-10, 2026-10-16, 2026-10-18, 2026-10-20, 2026-10-21

### 3. Is it done, merged, deployed and verified live? Can I close the thread?

- **Paraphrase:** Is everything merged and shipped, is it live, can we close this?
- **Asked:** 19 messages (19 in question form) over 11 days, 2026-09-23 to 2026-10-19; last 14 d 11. Where: dotfiles 3, prometheus-scripts 3, modelpick 2, shutterflow 2, audio-gateway 2, warden 1
- **Entities the answer needs:** Change, Deployment, Verification, Task, Project. Named in the asks: Deployment 6, Change/PR 4, Agent 3, Project 2, Infra host 2
- **Answer today:** `git read (log/status/diff/branch)` 73%, `curl (HTTP probe)` 33%, `gh run` 20%, `ssh` 20%; also fs read (cat/ls/grep) 87%, git write (add/commit/push/pull) 33%, script run (python/node/bun) 27%. Tool calls per answered turn (median) 4.0; answered without a tool call 7%.
- **Time:** median 46 s, p90 2 min to a final answer after 10.0 assistant entries (n=15 of 15 measured turns); first visible text 11 s. Consecutive asks in one session: median 11.6 h apart.
- **Repeated within a day:** 3 day(s) with >= 2 asks (max 5 in one day); fast same-session repeats 0. Days: 2026-09-23, 2026-10-15, 2026-10-19

### 4. Where is my Claude quota (5 h / 7 d) and when does it reset?

- **Paraphrase:** What is my Claude usage, when does the limit reset, can we keep spending tokens?
- **Asked:** 12 messages (2 in question form) over 7 days, 2026-09-23 to 2026-10-21; last 14 d 10. Where: shutterflow 5, tinycast-extensions 2, basalt-ui 2, weatherorb 2, (hermes) 1
- **Entities the answer needs:** Quota window, Agent (consumer), Cost. Named in the asks: Cost/quota 12, Agent 4, Task/plan 3, Project 1
- **Answer today:** `git read (log/status/diff/branch)` 60%, `curl (HTTP probe)` 20%, `TaskStop` 20%, `rd agents` 20%; also fs read (cat/ls/grep) 60%, git write (add/commit/push/pull) 40%, script run (python/node/bun) 60%. Tool calls per answered turn (median) 3.5; answered without a tool call 25%.
- **Also today:** The agents are told, not asked: he reads the 5 h / 7 d windows himself in a Claude Usage menu-bar extension he built (its unauthorized state is itself one of the asks) and the statusline, then types the reset time at the agents. Hermes can run the usage fetcher on request.
- **Time:** median 34 s, p90 84 s to a final answer after 8.5 assistant entries (n=4 of 5 measured turns); first visible text 27 s. Consecutive asks in one session: median 23.5 h apart.
- **Repeated within a day:** 2 day(s) with >= 2 asks (max 4 in one day); fast same-session repeats 1. Days: 2026-10-20, 2026-10-21

### 5. Is everything healthy -- is anything broken right now?

- **Paraphrase:** Are all systems healthy, is it all good, why so many alerts at once?
- **Asked:** 11 messages (11 in question form) over 9 days, 2026-08-27 to 2026-10-21; last 14 d 7. Where: tinycast-extensions 3, (hermes) 2, shutterflow 2, modelpick 1, email-gateway 1, vps 1
- **Entities the answer needs:** Incident, Condition, Project, Infra host. Named in the asks: Infra host 3, Agent 2, Incident/alert 2, Project 1
- **Answer today:** `curl (HTTP probe)` 50%, `ssh` 33%, `host probe (ps/df/launchctl)` 33%, `skill argo-api` 33%; also Read file 17%, fs read (cat/ls/grep) 100%, script run (python/node/bun) 33%. Tool calls per answered turn (median) 10.0; answered without a tool call 0%. **Push:** yes -- Kuma, Docker, watchdog, 24 h warnings, warden counts.
- **Time:** median 47 s, p90 3 min to a final answer after 8.0 assistant entries (n=6 of 6 measured turns); first visible text 19 s. Consecutive asks in one session: median 21.1 h apart.
- **Repeated within a day:** 2 day(s) with >= 2 asks (max 2 in one day); fast same-session repeats 0. Days: 2026-10-05, 2026-10-16

### 6. Why does X not work / fail / show the wrong thing?

- **Paraphrase:** Why is this not working, why does the page still show the old thing?
- **Asked:** 11 messages (11 in question form) over 10 days, 2026-09-21 to 2026-10-21; last 14 d 6. Where: tinycast-extensions 4, warden 1, dotfiles 1, jkrumm.com 1, research-gateway 1, modelpick 1
- **Entities the answer needs:** Incident, Project, Deployment, Signal. Named in the asks: Incident/alert 2, Project 1, Agent 1, Task/plan 1, Cost/quota 1
- **Answer today:** `git read (log/status/diff/branch)` 33%, `subagent (Explore/worker)` 17%, `MCP research-gateway job_wait` 17%, `MCP research-gateway research` 17%; also fs read (cat/ls/grep) 50%, git write (add/commit/push/pull) 33%, script run (python/node/bun) 17%. Tool calls per answered turn (median) 2.5; answered without a tool call 33%.
- **Time:** median 24 s, p90 3 min to a final answer after 4.5 assistant entries (n=6 of 6 measured turns); first visible text 17 s.
- **Repeated within a day:** 1 day(s) with >= 2 asks (max 2 in one day); fast same-session repeats 0. Days: 2026-10-09

### 7. (implied) Which approvals am I still giving that the agent could decide itself?

- **Paraphrase:** You can approve and merge that yourself -- permission handed over, case by case.
- **Asked:** 15 messages (4 in question form) over 9 days, 2026-09-15 to 2026-10-16; last 14 d 5. Where: jkrumm.com 3, weatherorb 2, epos.student-enrolment 2, prometheus-scripts 2, bun-email-api 1, warden 1
- **Entities the answer needs:** Decision, Change, Verification. Named in the asks: Change/PR 5, Deployment 5, Project 2, Agent 2
- **What the agent does next:** `git read (log/status/diff/branch)` 77%, `curl (HTTP probe)` 31%, `herdr agent` 31%, `ssh` 23%; also Read file 23%, edit/write files 31%, fs read (cat/ls/grep) 100%, git write (add/commit/push/pull) 62%, script run (python/node/bun) 62%. Tool calls per answered turn (median) 9.0; answered without a tool call 0%.
- **Time:** an action, not an answer. After it the agent runs a median 2 min before it ends its turn again (n=12); consecutive asks in one session are a median 2.5 h apart.
- **Repeated within a day:** 3 day(s) with >= 2 asks (max 4 in one day); fast same-session repeats 0. Days: 2026-09-23, 2026-10-01, 2026-10-09

### 8. What happened while I was away (overnight, vacation, laptop closed)?

- **Paraphrase:** I am back / good morning -- what got built or changed since I left?
- **Asked:** 8 messages (4 in question form) over 7 days, 2026-10-05 to 2026-10-20; last 14 d 5. Where: tinycast-extensions 2, prometheus-scripts 2, shutterflow 2, (hermes) 1
- **Entities the answer needs:** Change, Deployment, Agent, Incident, Task. Named in the asks: Project 2, Agent 2, Infra host 2, Incident/alert 1, Task/plan 1
- **Answer today:** `git read (log/status/diff/branch)` 100%, `host probe (ps/df/launchctl)` 67%, `herdr agent` 67%, `docker` 33%; also fs read (cat/ls/grep) 100%, git write (add/commit/push/pull) 33%, script run (python/node/bun) 33%. Tool calls per answered turn (median) 13.0; answered without a tool call 0%. **Push:** partial -- per-project changelog lines, 24 h warnings; no per-agent record.
- **Time:** median 54 s, p90 72 s to a final answer after 17.0 assistant entries (n=3 of 3 measured turns); first visible text 24 s.
- **Repeated within a day:** 1 day(s) with >= 2 asks (max 2 in one day); fast same-session repeats 0. Days: 2026-10-10

### 9. Which herdr tabs / agents are finished and can be closed? Why are so many open?

- **Paraphrase:** Why are there still so many tabs open; which are needed; close the finished ones.
- **Asked:** 9 messages (4 in question form) over 7 days, 2026-09-27 to 2026-10-16; last 14 d 4. Where: shutterflow 2, (hermes) 1, dotfiles 1, agent-gateway 1, basalt-ui 1, email-gateway 1
- **Entities the answer needs:** Agent, Project (herdr workspace), Attempt. Named in the asks: Agent 9, Project 2, Change/PR 1, Cost/quota 1
- **What the agent does next:** `herdr agent` 75%, `herdr tab` 75%, `git read (log/status/diff/branch)` 75%, `herdr workspace` 50%; also fs read (cat/ls/grep) 100%, script run (python/node/bun) 75%. Tool calls per answered turn (median) 8.5; answered without a tool call 0%.
- **Also today:** He asks an agent to review the tabs and close what is not needed ("review where they are, what is really still needed"); the closing decision is not automated.
- **Time:** an action, not an answer. After it the agent runs a median 60 s before it ends its turn again (n=4).
- **Repeated within a day:** 2 day(s) with >= 2 asks (max 2 in one day); fast same-session repeats 0. Days: 2026-10-07, 2026-10-15

### 10. Is that agent still running, stuck, or done -- does it need something?

- **Paraphrase:** Are you still going? Why are you stuck? Is it done, what does it say, does it need anything?
- **Asked:** 10 messages (7 in question form) over 10 days, 2026-09-13 to 2026-10-19; last 14 d 5. Where: shutterflow 2, (hermes) 1, modelpick 1, jkrumm.com 1, email-gateway 1, weatherorb 1
- **Entities the answer needs:** Agent, Attempt, Task. Named in the asks: Agent 5, Incident/alert 5, Task/plan 2, Change/PR 1
- **Answer today:** `herdr agent` 50%, `git read (log/status/diff/branch)` 50%, `host probe (ps/df/launchctl)` 50%, `herdr pane` 25%; also fs read (cat/ls/grep) 100%, git write (add/commit/push/pull) 25%, script run (python/node/bun) 38%. Tool calls per answered turn (median) 9.5; answered without a tool call 0%.
- **Time:** median 2 min, p90 6 min to a final answer after 24.5 assistant entries (n=8 of 8 measured turns); first visible text 12 s.

### 11. Is a connection or credential broken -- do I need to log in / unlock something?

- **Paraphrase:** Why does it say unauthorized; are the agents losing connection; do I need to re-auth; the keychain prompt again.
- **Asked:** 9 messages (8 in question form) over 9 days, 2026-09-08 to 2026-10-21; last 14 d 4. Where: dotfiles 2, (hermes) 1, shutterflow 1, warden 1, research-gateway 1, weatherorb 1
- **Entities the answer needs:** Condition (credential/connection), Infra host, Agent. Named in the asks: Agent 5, Infra host 4, Project 3, Cost/quota 3, Task/plan 2
- **Answer today:** `host probe (ps/df/launchctl)` 40%, `sqlite3 (db read)` 40%, `git read (log/status/diff/branch)` 40%, `skill hyperdx` 20%; also fs read (cat/ls/grep) 100%, script run (python/node/bun) 20%. Tool calls per answered turn (median) 8.0; answered without a tool call 0%.
- **Time:** median 21 s, p90 3 min to a final answer after 10.0 assistant entries (n=5 of 5 measured turns); first visible text 11 s.

### 12. Is a host low on disk / CPU / memory -- what is eating it?

- **Paraphrase:** The disk is nearly full, CPU is at 100% all the time -- is it us?
- **Asked:** 6 messages (0 in question form) over 4 days, 2026-10-06 to 2026-10-19; last 14 d 5. Where: shutterflow 2, weatherorb 2
- **Entities the answer needs:** Infra host, Condition, Project (consumer). Named in the asks: Infra host 6, Agent 2, Project 1
- **What the agent does next:** `herdr agent` 100%, `host probe (ps/df/launchctl)` 100%, `Skill herdr` 50%, `docker` 50%; also fs read (cat/ls/grep) 100%, script run (python/node/bun) 50%. Tool calls per answered turn (median) 9.0; answered without a tool call 0%. **Push:** partial -- Dev Host heartbeat warnings; no disk or CPU series.
- **Time:** an action, not an answer. After it the agent runs a median 3 min before it ends its turn again (n=2).
- **Repeated within a day:** 1 day(s) with >= 2 asks (max 3 in one day); fast same-session repeats 0. Days: 2026-10-15

### 13. How are all my agents / tabs / waves doing, across projects and hosts?

- **Paraphrase:** Show me every running agent and wave: working, idle, done, stuck -- on the mini and on the MacBook.
- **Asked:** 7 messages (6 in question form) over 6 days, 2026-09-12 to 2026-10-19; last 14 d 4. Where: (hermes) 3, modelpick 1, shutterflow 1, basalt-ui 1, weatherorb 1
- **Entities the answer needs:** Agent, Project, Task (wave/plan), Infra host. Named in the asks: Agent 6, Task/plan 2, Project 1, Incident/alert 1, Deployment 1
- **Answer today:** `herdr agent` 50%, `git read (log/status/diff/branch)` 50%, `curl (HTTP probe)` 33%, `herdr workspace` 33%; also fs read (cat/ls/grep) 83%, git write (add/commit/push/pull) 33%, script run (python/node/bun) 33%. Tool calls per answered turn (median) 3.0; answered without a tool call 17%. **Push:** partial -- agent overview section (unavailable on 2026-10-22); counts, not per agent.
- **Also today:** He also reads herdr himself and gets lost in it ("confused by the Herdr setup and what is active or not"); Hermes answers from `herdr` workspace/agent lists, the warden skill and `git log`.
- **Time:** median 29 s, p90 4 min to a final answer after 8.5 assistant entries (n=6 of 6 measured turns); first visible text 16 s.
- **Repeated within a day:** 1 day(s) with >= 2 asks (max 2 in one day); fast same-session repeats 0. Days: 2026-10-19

### 14. What does it cost -- is cost / usage tracking wired and right?

- **Paraphrase:** What does this cost, which model is cheaper, is usage tracking wired end to end?
- **Asked:** 7 messages (5 in question form) over 7 days, 2026-09-24 to 2026-10-19; last 14 d 4. Where: modelpick 2, sideclaw 1, shutterflow 1, tinycast-extensions 1, image-gateway 1, weatherorb 1
- **Entities the answer needs:** Cost, Usage record, Project. Named in the asks: Cost/quota 5, Project 2, Agent 1, Task/plan 1
- **Answer today:** `ssh` 33%; also fs read (cat/ls/grep) 100%. Tool calls per answered turn (median) 1.0; answered without a tool call 0%.
- **Time:** median 10 s, p90 23 s to a final answer after 3.0 assistant entries (n=3 of 3 measured turns); first visible text 5 s.

### 15. Are the docs / AGENTS.md / skills current and consistent?

- **Paraphrase:** Is the documentation up to date everywhere, not stale or confusing?
- **Asked:** 6 messages (5 in question form) over 6 days, 2026-10-05 to 2026-10-16; last 14 d 5. Where: shutterflow 1, image-gateway 1, dotfiles 1, prometheus-scripts 1
- **Entities the answer needs:** Project (docs), Artifact. Named in the asks: Agent 2, Project 1, Change/PR 1, Deployment 1
- **Answer today:** `herdr agent` 50%, `git read (log/status/diff/branch)` 50%, `rd agents` 50%, `subagent (Explore/worker)` 25%; also edit/write files 25%, fs read (cat/ls/grep) 100%, git write (add/commit/push/pull) 75%, script run (python/node/bun) 50%. Tool calls per answered turn (median) 7.0; answered without a tool call 0%.
- **Time:** median 58 s, p90 2 min to a final answer after 18.0 assistant entries (n=4 of 4 measured turns); first visible text 5 s.

### 16. Where do I see the report / PR / dashboard / result?

- **Paraphrase:** Where can I look at it -- I do not see a link, a PR, or a verdict; reports land in random folders.
- **Asked:** 6 messages (3 in question form) over 5 days, 2026-09-10 to 2026-10-19; last 14 d 3. Where: prometheus-scripts 2, homelab-private 1, shutterflow 1, email-gateway 1, ShutterflowOps 1
- **Entities the answer needs:** Artifact, Change, Project (links). Named in the asks: Task/plan 2, Project 1, Change/PR 1, Infra host 1
- **Answer today:** `ssh` 50%, `docker` 25%, `Skill research` 25%, `MCP research-gateway research` 25%; also Read file 25%, edit/write files 25%, fs read (cat/ls/grep) 75%, git write (add/commit/push/pull) 25%, script run (python/node/bun) 50%. Tool calls per answered turn (median) 5.5; answered without a tool call 0%.
- **Time:** median 38 s, p90 2.1 h to a final answer after 11.0 assistant entries (n=4 of 4 measured turns); first visible text 21 s.
- **Repeated within a day:** 1 day(s) with >= 2 asks (max 2 in one day); fast same-session repeats 0. Days: 2026-10-14

### 17. What is still pending / missing / open in the plan?

- **Paraphrase:** How much of the plan is still open, what did you achieve, what is left?
- **Asked:** 4 messages (4 in question form) over 3 days, 2026-09-20 to 2026-10-21; last 14 d 3. Where: weatherorb 2, basalt-ui 2
- **Entities the answer needs:** Task (wave/plan), Change, Project. Named in the asks: Task/plan 3, Agent 2, Project 1
- **Answer today:** `git read (log/status/diff/branch)` 33%, `gh issue` 33%, `rd say` 33%, `rd agents` 33%; also fs read (cat/ls/grep) 100%, git write (add/commit/push/pull) 67%, script run (python/node/bun) 33%. Tool calls per answered turn (median) 3.0; answered without a tool call 0%.
- **Time:** median 37 s, p90 66 s to a final answer after 7.0 assistant entries (n=3 of 3 measured turns); first visible text 29 s.
- **Repeated within a day:** 1 day(s) with >= 2 asks (max 2 in one day); fast same-session repeats 0. Days: 2026-10-19

### 18. What is waiting for me? Which agent or item needs my input?

- **Paraphrase:** What needs me right now, and what happens if I ignore it?
- **Asked:** 5 messages (3 in question form) over 5 days, 2026-09-23 to 2026-10-15; last 14 d 4. Where: shutterflow 2, warden 1, (hermes) 1, weatherorb 1
- **Entities the answer needs:** Decision, Agent, Incident, Artifact. Named in the asks: Agent 1, Task/plan 1
- **Answer today:** `git read (log/status/diff/branch)` 100%, `gh api` 50%, `subagent (Explore/worker)` 50%, `gh run` 50%; also fs read (cat/ls/grep) 100%, git write (add/commit/push/pull) 50%, script run (python/node/bun) 50%. Tool calls per answered turn (median) 13.0; answered without a tool call 0%. **Push:** partial -- warden needs_decision count and items that ask a question.
- **Also today:** The lists he has are the briefing's agents-and-projects section and warden's Slack cards; mid-session he asks the repo's agent.
- **Time:** median 6 min, p90 9 min to a final answer after 18.5 assistant entries (n=2 of 2 measured turns); first visible text 12 s.

### 19. Did the automatic recovery / self-healing work -- or did I have to intervene?

- **Paraphrase:** Was the recovery optimal; why did the watchdog not recover it; I had to restart and reconnect manually.
- **Asked:** 5 messages (4 in question form) over 3 days, 2026-10-06 to 2026-10-14; last 14 d 1. Where: tinycast-extensions 4, homelab-private 1
- **Entities the answer needs:** Condition, Attempt (heal), Verification, Incident. Named in the asks: -
- **Answer today:** `subagent (Explore/worker)` 100%, `ssh` 100%; also fs read (cat/ls/grep) 100%. Tool calls per answered turn (median) 4.0; answered without a tool call 0%.
- **Time:** median 68 s, p90 68 s to a final answer after 10.0 assistant entries (n=1 of 1 measured turns); first visible text 68 s. Consecutive asks in one session: median 1.8 h apart.
- **Repeated within a day:** 1 day(s) with >= 2 asks (max 3 in one day); fast same-session repeats 1. Days: 2026-10-06

### 20. Is X wired end to end -- observability, cost tracking, Hermes access?

- **Paraphrase:** Is monitoring/cost/usage wired up everywhere; are all gateways reachable from Hermes?
- **Asked:** 3 messages (2 in question form) over 2 days, 2026-10-13 to 2026-10-21; last 14 d 3. Where: image-gateway 2, (hermes) 1
- **Entities the answer needs:** Project (integrations), Cost, Signal (telemetry). Named in the asks: Project 2, Agent 1, Cost/quota 1
- **Answer today:** `ssh` 33%, `git read (log/status/diff/branch)` 33%, `execute_code` 33%; also fs read (cat/ls/grep) 67%, git write (add/commit/push/pull) 33%, script run (python/node/bun) 33%. Tool calls per answered turn (median) 4.0; answered without a tool call 0%.
- **Time:** median 34 s, p90 70 s to a final answer after 7.0 assistant entries (n=3 of 3 measured turns); first visible text 4 s. Consecutive asks in one session: median 2 min apart.
- **Repeated within a day:** 1 day(s) with >= 2 asks (max 2 in one day); fast same-session repeats 1. Days: 2026-10-13

### 21. Which version runs where -- is the latest code on stage and prod?

- **Paraphrase:** Is the most recent code deployed to both stage and prod?
- **Asked:** 3 messages (3 in question form) over 2 days, 2026-10-07 to 2026-10-15; last 14 d 2. Where: prometheus-scripts 3
- **Entities the answer needs:** Deployment, Change, Project (environment). Named in the asks: Deployment 3, Project 1, Change/PR 1
- **Answer today:** `glab api` 100%, `git read (log/status/diff/branch)` 100%, `glab mr` 33%; also edit/write files 33%, fs read (cat/ls/grep) 100%, git write (add/commit/push/pull) 33%, script run (python/node/bun) 33%. Tool calls per answered turn (median) 5.0; answered without a tool call 0%.
- **Time:** median 3 min, p90 6 min to a final answer after 11.0 assistant entries (n=3 of 3 measured turns); first visible text 7 s. Consecutive asks in one session: median 4 min apart.
- **Repeated within a day:** 1 day(s) with >= 2 asks (max 2 in one day); fast same-session repeats 1. Days: 2026-10-15

### 22. Are my machines / tools / dependencies up to date -- what still needs an update or restart?

- **Paraphrase:** Is the herdr setup on the mini and here up to date; ready for all the restarts; do the macOS update.
- **Asked:** 4 messages (4 in question form) over 3 days, 2026-10-01 to 2026-10-11; last 14 d 2. Where: dotfiles 4
- **Entities the answer needs:** Project (dependencies), Infra host, Condition (drift). Named in the asks: Project 1, Agent 1, Infra host 1
- **Answer today / time:** not measured -- no turn data for these asks (MacBook-only rows when the ssh leg is down).
- **Repeated within a day:** 1 day(s) with >= 2 asks (max 2 in one day); fast same-session repeats 1. Days: 2026-10-01

### 23. Which model / tool / version is configured -- do we have access to the new one?

- **Paraphrase:** Do we already have the new model, which model does X use, is that integration available?
- **Asked:** 4 messages (4 in question form) over 3 days, 2026-08-25 to 2026-10-19; last 14 d 1. Where: modelpick 2, (hermes) 1, email-gateway 1
- **Entities the answer needs:** Project (config), Agent (engine), Cost. Named in the asks: Project 1, Deployment 1
- **Answer today:** `secrets` 75%, `skill argo-api` 25%, `curl (HTTP probe)` 25%, `subagent (Explore/worker)` 25%; also Read file 25%, fs read (cat/ls/grep) 75%, script run (python/node/bun) 25%. Tool calls per answered turn (median) 6.0; answered without a tool call 0%.
- **Time:** median 42 s, p90 45 s to a final answer after 11.5 assistant entries (n=4 of 4 measured turns); first visible text 11 s.
- **Repeated within a day:** 1 day(s) with >= 2 asks (max 2 in one day); fast same-session repeats 0. Days: 2026-10-05

### 24. What did warden / the loop handle alone -- why did this reach me?

- **Paraphrase:** Should this not have gone through automatically; are the policies too strict; why is the agent so cautious?
- **Asked:** 3 messages (3 in question form) over 3 days, 2026-10-06 to 2026-10-16; last 14 d 2. Where: warden 1, shutterflow 1, prometheus-scripts 1
- **Entities the answer needs:** Decision, Incident, Verification, Project (policy). Named in the asks: Change/PR 1
- **What the agent does next:** `git read (log/status/diff/branch)` 100%, `make check` 50%, `warden close` 50%, `warden run` 50%; also edit/write files 50%, fs read (cat/ls/grep) 100%, git write (add/commit/push/pull) 100%, script run (python/node/bun) 100%. Tool calls per answered turn (median) 9.0; answered without a tool call 0%.
- **Time:** an action, not an answer. After it the agent runs a median 3 min before it ends its turn again (n=2).

### 25. Is the data / report / page fresh -- how old is it?

- **Paraphrase:** How old is this data, is the report current?
- **Asked:** 2 messages (2 in question form) over 2 days, 2026-09-11 to 2026-10-19; last 14 d 1. Where: homelab-private 1, weatherorb 1
- **Entities the answer needs:** Signal (freshness), Project, Deployment. Named in the asks: Task/plan 2, Project 1, Agent 1
- **Answer today:** `ssh` 100%, `SendUserFile` 50%, `subagent (Explore/worker)` 50%, `git read (log/status/diff/branch)` 50%; also edit/write files 50%, fs read (cat/ls/grep) 50%, script run (python/node/bun) 50%. Tool calls per answered turn (median) 15.5; answered without a tool call 0%.
- **Time:** median 4 min, p90 4 min to a final answer after 32.5 assistant entries (n=2 of 2 measured turns); first visible text 2 min.

### 26. Did the nightly / scheduled / auto-update job run, and did it succeed?

- **Paraphrase:** Did last night's run happen, what did the auto-update do, check the log tomorrow morning.
- **Asked:** 2 messages (2 in question form) over 2 days, 2026-09-23 to 2026-10-14; last 14 d 1. Where: dotfiles 1, homelab-private 1
- **Entities the answer needs:** Deployment (job run), Verification, Infra host. Named in the asks: Deployment 2, Task/plan 1
- **Answer today:** `ssh` 100%, `make image-share-deploy` 50%, `gh run` 50%, `git read (log/status/diff/branch)` 50%; also fs read (cat/ls/grep) 50%, git write (add/commit/push/pull) 50%, script run (python/node/bun) 50%. Tool calls per answered turn (median) 19.5; answered without a tool call 0%.
- **Time:** median 6 min, p90 7 min to a final answer after 44.5 assistant entries (n=2 of 2 measured turns); first visible text 14 s.

### 27. Why does this keep coming back -- is the recurring issue resolved?

- **Paraphrase:** Why does this alert/issue keep happening; is it resolved or do I have to help manually?
- **Asked:** 3 messages (3 in question form) over 3 days, 2026-09-01 to 2026-10-01; last 14 d 0. Where: warden 2, (hermes) 1
- **Entities the answer needs:** Incident, Signal (fingerprint), Known error, Project. Named in the asks: Incident/alert 2, Task/plan 2, Agent 1
- **Answer today:** `git read (log/status/diff/branch)` 67%, `sqlite3 (db read)` 67%, `search_files` 33%, `read_file` 33%; also fs read (cat/ls/grep) 67%, script run (python/node/bun) 33%. Tool calls per answered turn (median) 10.0; answered without a tool call 0%.
- **Time:** median 63 s, p90 89 s to a final answer after 12.0 assistant entries (n=3 of 3 measured turns); first visible text 16 s.

## By area: what each cluster of questions needs

| Area | Distinct asks | Classes | Entities the answers draw on |
|-|-|-|-|
| Fleet | 80 | all_agents, needs_me, agent_alive, nudge_continue, tab_cleanup | Agent, Project, Task, Infra host, Decision, Incident, Artifact, Attempt, Quota window |
| Orientation | 38 | where_are_we, since_away, what_pending | Agent, Task, Project, Change, Attempt, Deployment, Incident |
| Delivery | 28 | done_shipped_live, version_per_env, scheduled_ran, where_to_see | Change, Deployment, Verification, Task, Project, Infra host, Artifact |
| Health | 27 | anything_broken, why_recurring, why_failing, fresh_data | Incident, Condition, Project, Infra host, Signal, Known error, Deployment |
| Autonomy | 22 | healing_worked, warden_handled, delegate_decision | Condition, Attempt, Verification, Incident, Decision, Project, Change |
| Infra | 19 | infra_resources, connectivity_auth, update_state | Infra host, Condition, Project, Agent |
| Cost | 19 | quota_now, spend | Quota window, Agent, Cost, Usage record, Project |
| Setup | 12 | config_state, docs_current, is_wired | Project, Agent, Cost, Artifact, Signal |

## Entity demand

How many classified asks touch each entity (keyword match on the matched unit and short messages; a lower bound). This is the read-model shopping list.

| Entity | Asks |
|-|-|
| Agent | 42 |
| Project | 23 |
| Task/plan | 20 |
| Infra host | 19 |
| Cost/quota | 19 |
| Deployment | 18 |
| Incident/alert | 12 |
| Change/PR | 12 |

## Named in the design prompts, and what the logs say

| Prompt | Wants to see | Maps to | Owner asks in those classes | Keyword probe (q-form / any) |
|-|-|-|-|-|
| A | Argo shows the state of fleets, agents, warden and projects | all_agents, agent_alive, needs_me, where_are_we | 49 | - |
| A | Per-project page: links (herdr mother, app, git), key stats | where_are_we | 28 | - |
| A | Per-project: needs attention | needs_me | 5 | - |
| A | Per-project: tasks and todos (Beads, TickTick) | what_pending | 4 | - |
| A | Per-project: artifacts (plans, reports to comment on) | where_to_see | 6 | - |
| A | Per-project: health | anything_broken | 11 | - |
| A | Per-project: changelog (today a Slack cron) | since_away | 8 | - |
| A | Per-project: cost stats / usage tracking | quota_now, spend | 19 | - |
| A | Per-project: traffic | (no class) | - | 2 / 9 |
| A | Per-project: git status | where_are_we | 28 | - |
| A | Per-project: dependency state | (no class) | - | 0 / 7 |
| A | Pages for health, usage-tracking, traffic, needs attention, artifacts | anything_broken, quota_now, needs_me | 28 | - |
| A | Infra of mini, homelab, vps monitored and self-healed; anomalies and attacks | anything_broken, infra_resources | 17 | - |
| A | Herdr cleanup: close finished tabs, truncate or compact old agents | tab_cleanup | 9 | - |
| A | A human business decision in < 1 % of cases | needs_me, delegate_decision | 20 | - |
| B | Where things are, where the agents are | all_agents | 7 | - |
| B | Show what is important, what to do, where to look, what happened | needs_me, since_away, anything_broken | 24 | - |
| B | Morning and evening briefings, Hermes chat, Slack alerts inside Argo | since_away, anything_broken | 19 | - |
| B | Things I must still look at; things that are finished, close them | needs_me, tab_cleanup | 14 | - |
| B | Requests I must allow that the agent could decide alone | warden_handled, delegate_decision | 17 | - |
| B | How warden really ran | warden_handled | 3 | - |
| B | Mini remote-dev status and the MacBook's local herdr (Shutterflow) | all_agents | 7 | - |
| B | Metrics, monitoring and cross-tracking, all in one place | is_wired, spend | 9 | - |

Prompt A = session 94025058 (2026-10-22); prompt B = session b224d6e5 (2026-10-21, German). Asks = distinct classified owner messages in the mapped classes. Wants with no class (traffic 2/9; dependency state 0/7 question-form / any keyword mention) show only tool setup and directives in the logs (an Umami key, "update the dependencies"), never a question about the state itself. They are design wishes, not recurring questions: put them behind the exception line, not on the home view.

## Standing questions already answered by push (Hermes cron, 60 d)

| Job | Runs |
|-|-|
| Morning briefing | 44 |
| Evening report | 35 |
| Brain drift audit | 7 |
| homelab-pr6-hardening-followup | 2 |
| weatherorb-dwd_icon-stall-recheck | 1 |
| warden-rg-consistency-round5 | 1 |

The morning briefing (07:00 host time) carries: weather, appointments, **Infrastruktur** (Kuma monitors up/total, homelab and VPS containers, watchdog items, warden state counts), 24 h warnings, health and training, work sprint and reviews, GitHub, **Agenten & Projekte** (per-project changelog lines; on 2026-10-22 the agent overview itself was unavailable), tasks. The 22:00 evening report is personal only (training, recovery, tomorrow). Neither says which agent is stuck, what is waiting for him with a deadline, or what the quota is.

## Synthetic probes (not owner messages)

47 agent-authored Hermes API/CLI probes in the window, 6 phrased as status questions ("which of my Claude agents need me, where does basalt-ui stand", "what is going on with warden, short status", "how is the infrastructure, all healthy", "how many containers on homelab and VPS, which has the most restarts", "how many open watchdog items"). They show what the integrators assume he asks; none is counted above.

## Hand check

Seeded sample (seed 20261022): up to 8 classified messages per class (`python3 -I questions.py --sample` prints them), read and judged: does the message really ask this question (or state it as a need) of the estate? Verdicts live in `labels.json`; 158 verdicts over 27 classes.

| Class | Sampled | Correct | Precision |
|-|-|-|-|
| where_are_we | 8 | 8 | 100% |
| since_away | 8 | 6 | 75% |
| all_agents | 7 | 7 | 100% |
| needs_me | 5 | 3 | 60% |
| what_pending | 4 | 4 | 100% |
| agent_alive | 8 | 7 | 88% |
| nudge_continue | 8 | 8 | 100% |
| tab_cleanup | 8 | 7 | 88% |
| done_shipped_live | 8 | 8 | 100% |
| version_per_env | 3 | 3 | 100% |
| scheduled_ran | 2 | 2 | 100% |
| where_to_see | 6 | 3 | 50% |
| anything_broken | 8 | 8 | 100% |
| why_recurring | 3 | 3 | 100% |
| why_failing | 8 | 8 | 100% |
| fresh_data | 2 | 2 | 100% |
| infra_resources | 6 | 6 | 100% |
| connectivity_auth | 8 | 8 | 100% |
| quota_now | 8 | 8 | 100% |
| spend | 7 | 6 | 86% |
| config_state | 4 | 4 | 100% |
| healing_worked | 5 | 5 | 100% |
| warden_handled | 3 | 3 | 100% |
| delegate_decision | 8 | 8 | 100% |
| update_state | 4 | 3 | 75% |
| docs_current | 6 | 6 | 100% |
| is_wired | 3 | 3 | 100% |

Overall 147/158 (93%). Single annotator, small per-class samples: read the per-class figures as a sanity check, not as a confidence interval. Recall is not measured; see the residue.

## Residue: question-form messages no class caught

80 owner messages (<= 700 chars) are in question form or carry a status stem, name an estate entity (agent, tab, warden, deploy, quota, host ...) and match no class (per repo in `candidates.out.json`; no excerpts are stored for them). Reading them: product feedback on the apps he builds (Shutterflow, TinyCast), model and tool choices, personal research, and directions phrased as questions. No further estate-state class stood out above two messages.

