# Fresh review of TDD v2.4 (2026-10-25, night)

Two agents with no history read the whole design before the v2.4 fixes. Their reports, verbatim. Where each finding landed: appendix A, "The fresh review of v2.4".

## 1. Design review

### Design review: software factory TDD v2.4 (unanchored read)

I read all of the files in ~/SourceRoot/dotfiles/docs/factory/tdd/, then checked several claims against the live setup: dotfiles (the hooks, `claude-account.ts`, `herdr-reap.py` and the account config dirs), warden's docs, and weatherorb's alert code. The core architecture is sound: an Issue state machine in Postgres driven by an inbox, interactive leads in herdr behind a `Runner` port, no DBOS, and one lead owning an Issue end to end. The problems are at the edges, where the design meets your machine, your accounts and your existing tools.

## Findings, ranked by impact

**1. Nothing says where a lead's working copy lives, so leads would share checkouts with you and with each other.**
- **Where:** 04-loop.md:60-71, 06-state.md:52-55, d-edge-cases.md:19, 13-decisions.md:23. "A branch per Issue" appears only in b-landscape.md:14.
- **Why it matters:** you work direct-to-master in the same `~/SourceRoot/<repo>` checkouts, and the factory never sees your sessions (07-projects.md:78-79). Its one-lead-per-repo claim therefore does not protect your uncommitted work. A lead's `/commit` or rebase there sweeps it up or gets blocked by it. The extra "+1 urgent" lead shares a tree with the lead already running. A W1 wave agent will default to the repo root.
- **Fix:**
  - Every attempt runs in a worktree the factory owns, on `factory/<issue>-<attempt>` (reuse `scripts/fan-worktree.sh`).
  - It merges by rebase and fast-forward, or by PR in the four repos that require one.
  - The worktree is removed at finalize. Write this into §6 and W1.

**2. Lead hooks have no scope and no defined failure behaviour, and leads can edit the factory's own machinery live.**
- **Where:** 04-loop.md:116-123 and 06-state.md:92-94. dotfiles AGENTS.md:44 says hooks are live symlinks, and "an edit applies on the next tool call". `~/.claude-me/settings.json` is a separate file from `~/.claude/settings.json`. 07-projects.md:73 says that in a repo without a manifest, "done means the commit".
- **Why it matters:**
  - Global hooks fire in your sessions and in the build's own wave sessions, and they must be kept identical in two settings files.
  - When the factory is down (a crash, a self-deploy, the W1 kill gameday), a hook that calls the `factory` CLI either loses its event or hangs the session.
  - From W3, leads edit dotfiles (hooks, the picker, `rd`) and the factory repo under "done = the commit". One bad hook edit breaks every running lead and your own sessions at once, with no hold.
- **Fix:**
  - The launcher passes a hooks file only to leads; otherwise the hooks do nothing unless `FACTORY_SESSION` is set.
  - Hooks and `factory issue` calls fail open and append to a local spool file, which the factory replays on start. The idempotency keys already make the replay safe.
  - Give dotfiles and the factory repo a manifest with `deploy.mode: make`, a hold, and one zero-token probe: run the hook scripts against a fake payload.

**3. The Stop hook fights the lead's own tools, your typing, the hold and walls.**
- **Where:** 04-loop.md:121-123, set against 04-loop.md:65 and 147-148 (`rd fan` and `/wave` as the lead's tools), 126 (you type into the tab), 129-130 (the hold) and d-edge-cases.md:13.
- **Why it matters:**
  - A lead that hands work to `rd fan` or a `/wave` chain ends its turn while that work runs. The hook sends it back, so it either keeps polling and burns tokens, or reports `ship`, `block` or `ask` early to satisfy the hook. An early `ask` becomes a card to you.
  - When the lead answers your question in its tab, that turn ends with "nothing reported", and the hook fires.
  - A regression note during the hold starts a new turn, and the hook rule does not say what that turn must report.
  - If Stop fires when a turn ends on a usage limit, the hook sends a walled lead straight back into the wall.
  - A second unreported stop becomes a card to you until W3, which contradicts the W1 gate's "without you".
- **Fix:** block only when all three hold:
  - no `factory` report since the last prompt that came in;
  - no declared wait;
  - the turn did not end on a usage limit. Test in W1 which hook event fires in that case.

  Add `factory issue wait --on workers|deploy|owner [--until]` as a valid report, and accept `phase` too. A prompt you type silences the hook until you go idle. Keep `stop_hook_active` as the loop guard. A second unreported stop parks the Issue with a line in the briefing, never a card.

**4. Usage walls will hit W1 on `me`, but wall handling lands in W3, and the wall rules rest on false premises.**
- **Where:** 12-plan.md:81-82, d-edge-cases.md:20, 05-capacity.md:46, 04-loop.md:128, 05-capacity.md:98-99, 05-capacity.md:47.
- **Why it matters:**
  - `me`'s 5-hour window "one heavy lead can fill" (05:27-28), and W1's build sessions plus its three gate leads all run on `me`. A wall during the gate means you type `continue`.
  - The weekly limit binds as well (`iu` is at 90 % today), so a wall can last days. The design says it is "never more than five hours away" (05:46 and the FAQ).
  - The prompt cache lives minutes to an hour, so "cache intact" after a wall is false.
  - Both accounts share one transcript store (`~/.claude-me/projects` links to `~/.claude/projects`), so `claude --resume <id>` already works on the other account.
  - Your reserve covers only `iu`'s 5-hour window, yet your sessions land on `me` whenever `iu` is nearly full.
  - Two leads admitted in the same tick see the same headroom.
- **Fix:**
  - In W1, Witness detects `walled` and resumes the lead at reset.
  - If the wait exceeds about an hour and the other account has headroom, resume there and count it as one deliberate switch.
  - Keep a reserve on both accounts, and on the weekly window too.
  - Admission subtracts the expected cost of leads it has admitted but not yet measured.

**5. W1 holds about 20 deliverables in two days, and part of it is circular.**
- **Where:** 12-plan.md:23; 07-projects.md:40 and 44. The manifest schema and drift check are W4 work (12-plan.md:26), yet W1 needs deploy mode, hold and probes.
- **Why it matters:**
  - The gate needs a UI change and a service change with production evidence. So W1 must also onboard two repos the plan never names, on a manifest schema it never defines. A wave agent will invent one, and W4 will rewrite it.
  - `otel`'s model is "picked on ten recorded lead queries", but no lead exists before W1 ships.
  - The transcript archive, `issue resume`, the restore drill with adopt mode, the `otel` move and warden's deletion are not part of the spine.
- **Fix:** split W1.
  - **W1a:** the Issue machine, inbox, CLI, Runner with herdr, hooks (with finding 3's rule), Witness and worktrees; one docs request closed; the kill gamedays.
  - **W1b:** a frozen `project.yaml` v0 as a Zod schema that W4 extends (name, deploy.mode, targets.verify, hold, probes); deploy, hold, verify and probes; the UI and service requests on two repos named in the plan.

  Move `otel` to a side `agw dispatch` once real queries exist. Move archive and resume to W6, and set `cleanupPeriodDays: 365` now. Switch warden off in W1 and delete it later.

**6. "An issue you open is a request" also fires on issues your machines open under your GitHub user.**
- **Where:** 10-surfaces.md:42-44, and 04-loop.md:50-52, where requests skip dedup and settle.
- **Why it matters:**
  - weatherorb opens alert issues through the mini's `gh`, which is logged in as your user (`~/SourceRoot/weatherorb/src/weatherorb/ops/alert.py:182-217`, labels `alert` and `warden:skip`).
  - Any agent running `gh issue create` is also "your user".
  - The result: a flapping alert spawns leads on Max, drills get worked, and a lead that files a follow-up issue spawns another lead.
- **Fix:**
  - Route `alert`-labelled issues through the signal path, so dedup and settle apply.
  - Keep a `factory:skip` label for drills.
  - Require a machine marker on every issue an agent opens, or switch to opt-in (owner choice 2).

**7. Switching warden off in W1 opens gaps the design says do not exist.**
- **Where:** 02-what-changes.md:37-39, 10-surfaces.md:113, faq.md:23-24.
- **Why it matters:** per `dotfiles/docs/ops-signals.md:60-64` and `background-jobs.md:34,63`:
  - Warden is the only remediation route for `jobs-grade` (13 launchd jobs and 4 Hermes crons).
  - It holds Hermes' restart verb.
  - Argo's `implement` intent calls it.
  - The `Warden Loop` Kuma push monitor will page once warden stops.
  - Kuma and HyperDX send webhooks to its ingest.

  Job failures then have no route until W4.
- **Fix:** a W1 switch-off checklist:
  - remove the monitor and both webhooks;
  - point `jobs-grade --notify` at Slack until W4;
  - disable Argo's implement button;
  - add Hermes to W2's restart runbook;
  - delete warden's code at W2.

**8. The parallel lanes contradict the hand-over, and three waves would edit the `factory` repo at once.**
- **Where:** 12-plan.md:40-49 starts W4 and W5 "after w2", in parallel with W3. 12-plan.md:73-76 hands the build to the factory "from W3's gate".
- **Why it matters:**
  - At W3's gate, W4 and W5 are still running under wave orchestrators. Handing over running waves is undefined.
  - Until then, two admission controllers (the build orchestrator and the factory's picker) spend the same windows.
  - W3, W4 and W5 all change the factory's schema and router at the same time, which breaks the one-lead-per-repo rule the factory itself enforces.
  - W3 and W4 are each overloaded. W3 carries admission, escalation, the orchestrator, initiatives, the `claude --bg` spike, scorecard v0 and review gating. W4 carries about 15 repo manifests, 8 adapters, the learning loop and scorers.
- **Fix:**
  - Run W3 alone after W2, then W4 and W5 as initiatives inside the factory. That is also the real proof that it builds itself.
  - If you keep the waves parallel, state that waves started before the gate finish under the build orchestrator, give each wave its own modules, and run schema migrations through one wave.
  - Move the `claude --bg` spike and review gating out of W3.

**9. The evidence check only tests presence, and the lead picks its own bar.**
- **Where:** 04-loop.md:79-88, 07-projects.md:73, 11-proof.md:26 and 31.
- **Why it matters:**
  - The lead chooses between `ship` and `close`. `close` ("docs, analysis") skips both the evidence and the hold.
  - Any screenshot satisfies the UI requirement.
  - The KPI "Issues closed without production evidence: 0" can never fail, because `ship` refuses anything without an attachment.
- **Fix:**
  - The factory derives the required evidence from the changed paths, via the `ship:` rules and deploy mode, and refuses `close` when merged commits touch deployable paths.
  - The deployed version that `make verify` reports must contain the merged SHA.
  - Screenshots must be newer than the deploy.
  - Change the KPI to "verify or probes failed after the hold" plus "deployed SHA ≠ merged SHA".

**10. Several gates and SLOs cannot fail, or cannot pass, at this volume.**
- **Where:** 11-proof.md:24 and 28, 08-dedup.md:42 and 63-64, 12-plan.md:23, 25 and 26.
- **Why it matters:**
  - At tens of Issues a week, "under 1 % reach you" allows no card at all in 14 days. One legitimate business decision fails the SLO.
  - A median time to resolve of ≤ 0.5 h is impossible for shipped work, because the hold alone is 30 minutes.
  - **W3:** "read by you once" and "two leads in parallel" pass trivially, and its wall test waits for a natural wall to happen.
  - **W4:** "trusted or kept in shadow" cannot fail, and the wave writes the drift check it is gated on.
  - **Judge:** its precision cannot be computed. A lead that does not merge leaves no negative label, and 30 ambiguous pairs may take months to collect.
  - **W1:** the Stop-hook and seeded-bug gamedays (11-proof.md:13 and 16) are missing from the W1 gate in 12-plan.
- **Fix:**
  - The SLO becomes zero non-business interrupts; business cards are counted and shown, not held to an SLO.
  - Split time to resolve into heal time for incidents and time to ship for requests.
  - In W3, inject a wall by faking the usage reading, and replace "read by you" with a checklist the orchestrator's output must meet.
  - Every related-signal note requires the lead to record "same" or "different". That record is the label.
  - Copy 11-proof's W1 gamedays into the W1 gate word for word.

**11. Decision cards and briefing notes have nowhere to go until W5, yet defaults still apply on expiry.**
- **Where:** 01-verdict.md:53-54, d-edge-cases.md:13, 04-loop.md:177-178, 05-capacity.md:79; push only lands in W5 (12-plan.md:27).
- **Why it matters:**
  - From W1 to W4, "without you" passes only because you cannot see the asks.
  - A card about spend or data loss takes its default unseen.
  - The W2 changelog writes brain pages, which would put homelab-private service details into the brain repo (07-projects.md:97-100).
- **Fix:**
  - Send cards through the existing human-queue or Slack #agents until W5.
  - For the four business classes, the default is always "don't, park the Issue", and the expiry clock starts only when delivery is confirmed.
  - The changelog skips homelab-private.

**12. Several pieces are over-built for one person and tens of Issues a week.**

| Cut or defer | Where | What breaks |
|-|-|-|
| p75 cost per size and model; the weekly tuning job; the "picker decisions proved wrong" measure | 05:43-46, 102-104; 09:47 | Nothing real: buckets of single digits tune on noise. Use fixed headroom per model tier; the worst case is an occasional wall mid-work, which wall-resume covers |
| Transcript scorers, monthly calibration, the orchestrator's action-item table, the Monday review, contradiction checks | 09:37-38; 08:70-71; 05:80-84 | Slower detection of bad lead habits. Read ten transcripts yourself until about 50 Issues are closed |
| The join/queue/supersede claim policies | 06:52-55 | Nothing: one active lead per repo with a FIFO queue; "join" is already the related-signal note |
| Archive and `resume` in W1 | 06:92-99 | Nothing for a year, given `cleanupPeriodDays: 365` |
| The `claude --bg` spike in W3 | 06:85-89 | Nothing; run it when the preview label goes (the design's own trigger) |
| Adopt mode as a separate mode | d:10 | Nothing; make startup reconciliation the only way the factory starts |
| Orchestrator wakes for "an account heading for more than 10 % unused" and "an Issue waiting over 24 h" | 05:77-78 | Nothing; the picker already spends capacity that would lapse. Make them briefing lines |

Keep the replay and golden tests, stop-the-line, the hold and the probes.

**13. Four mechanisms act on a lead's pane, and two of them would kill a lead the design wants alive.**
- **Where:** 03-principles.md:35-36 (idle watchdog), 04-loop.md:129-130 (Witness closes the tab when the hold passes), 01-verdict.md:48-50 (verify after the hold), `~/SourceRoot/dotfiles/scripts/herdr-reap.py:4-13`, 04-loop.md:156 (the orchestrator types notes into panes).
- **Why it matters:**
  - A lead in the hold, at a wall, or waiting on its workers is idle by design. Under `rules/agent-limits.md`, the idle watchdog kills idle workers.
  - Closing the tab when the hold passes races the verify that may reopen the Issue, so a regression reaches a cold resume instead of the warm lead.
  - herdr-reap types messages into idle tabs that have uncommitted changes. That message is an untracked prompt, and in a walled lead it starts a turn and a Stop-hook cycle.
  - Orchestrator notes typed straight into a pane bypass the prompt-id idempotency (06:49-50).
- **Fix:**
  - The factory alone owns `lead-*` panes, and herdr-reap skips them.
  - The watchdog applies only in the `working` state.
  - Close the tab only after verify and probes pass.
  - All notes go through `factory issue note`.

**14. The split of decisions between the orchestrator and the factory's rules is undefined.**
- **Where:** 04-loop.md:143-146, 05-capacity.md:37-50, 05-capacity.md:64-65 against 05:85-87 and 04:177-178, and d-edge-cases.md:23.
- **Why it matters:**
  - Can an orchestrator `prio` lift an upkeep Issue past the "only capacity that would lapse" rule, or a feature past stop-the-line? The design does not say.
  - Both the factory (automatic re-spawn one tier up) and the orchestrator react to a stalled lead, so it can be re-spawned twice.
  - Stopping an absorbed lead after a merge throws away its uncommitted work.
- **Fix:**
  - One precedence order: stop-the-line > urgent > dependencies > orchestrator `prio` (which only reorders within a class) > age.
  - The factory only raises stall events; the orchestrator alone re-tiers or splits.
  - An absorbed lead is told to push a work-in-progress branch and `drop --merged-into`, rather than being killed.

**15. Restoring the database reuses Issue ids that running panes still carry.**
- **Where:** 06-state.md:48-51, d-edge-cases.md:10, 06-state.md:132-133.
- **Why it matters:**
  - Lead panes are named `lead-<issue>-<attempt>`, and spawning attaches to an existing pane by that name.
  - After restoring last night's dump, the id sequence hands out ids whose panes still run Issues the dump lost. A new Issue then attaches to the wrong lead.
  - Orphaned leads report ids the factory does not know.
- **Fix:**
  - Use ULIDs, or move the sequences past every id seen in pane names and the hook spool.
  - At startup, rebuild orphaned Issues from the spool or park them.
  - Add this case to the restore gameday.

## Choices that are genuinely yours

1. **Where leads work.**
   - **Worktrees (my recommendation):** one per attempt, merging to master. Costs dependency and env setup on every spawn, and your own sessions have to pull.
   - **Your checkouts:** shared with your sessions, and collides with your uncommitted work.
2. **What starts work on GitHub.**
   - **Any issue you open (the current design):** needs a marker on every issue any tool opens.
   - **Opt-in (my recommendation):** a `factory` label or a `/factory` comment. It costs one word per issue and removes the loop risk, because every agent on the mini acts as your GitHub user.
3. **What a walled lead does.**
   - **Stay on its account (the current design):** zero switches, but it can wait hours or days.
   - **Resume on the other account when the wait exceeds about an hour (my recommendation):** the cache is gone by then anyway, so it costs one counted switch.

## Verdict

**Not ready to start W1 as written.** The changes below are document edits, about a day's work, and should land before sign-off:
- lead worktrees (finding 1);
- hooks that are scoped, fail open into a spool, and follow the new Stop-hook rule (findings 2 and 3);
- W1 split into W1a and W1b, with two named repos, a `project.yaml` v0, and basic wall detection and resume on `me` (findings 4 and 5);
- the warden switch-off checklist and the GitHub trigger fix, before W2 (findings 6 and 7);
- a place for decision cards to go before W5, with safe defaults (finding 11);
- a W1 gate made of 11-proof's W1 gamedays plus the deployed-SHA check (findings 9 and 10).

Everything else can be fixed in the wave where it lands.


## 2. Consistency audit

The design agrees with itself on its headline decisions and thresholds, but ten stale spots carry v2.1–v2.3 wording and a number of things the text relies on have no wave. All files are under `~/SourceRoot/dotfiles/docs/factory/tdd/`. I read all 20 files and edited nothing.

The items run most likely to mislead an implementer first. Where two sections disagree, the fix names the side that is right under `13-decisions.md` and the v2.4 section of `a-review-log.md`.

1. **W1 needs `project.yaml`, probes and the hold, but no wave builds the manifest until W2 or W4.**
   - `12-plan.md:23` has W1 do "hold, then `make verify` and the probes" and gate on "three real requests (a UI change, a service change, a docs change)".
   - `12-plan.md:24` first mentions "a minimal `project.yaml` for the homelab" in W2. `12-plan.md:26` builds "`project.yaml`, the make contract and journey probes" in W4.
   - `07-projects.md:40-44` says the make contract lands in W1 "for the factory and the first repos leads ship to".
   - Classification is W2 (`12-plan.md:24`) and model/effort per lead is W3 (`12-plan.md:25`), yet W1 spawns "on the picked account". `04-loop.md:37` treats these as one Classify step.
   - Why it misleads: the W1 gate cannot pass as written.
   - Fix: add to W1 the manifest schema (`deploy` with targets, hold and probes), synced into `projects`, for the factory repo and the three gate repos. State that W1 requests carry project, model and effort by hand until W2 and W3.

2. **The evidence rule disagrees with the W1 gate and with repos that have no manifest.**
   - `12-plan.md:23` has all three W1 requests (including the docs change) end "each with production evidence".
   - `04-loop.md:88` says "Nothing deployed (docs, analysis) | the commit or the document".
   - `11-proof.md:26` sets the SLO "Issues closed without production evidence | 0".
   - `04-loop.md:79-80` refuses `ship` without evidence unconditionally. `07-projects.md:73` says that with no `project.yaml` "done means the commit or the document", and its examples include "your website".
   - Why it misleads: it is unclear whether a docs Issue counts as a violation, and whether a UI change in a manifest-less repo needs a screenshot.
   - Fix: the W1 gate wants production evidence for the UI and service changes and the commit for the docs change. The `11-proof.md:26` SLO counts only deployed changes. Add a line to §4 that repos without a deploy block use commit or document evidence.

3. **The verdict, §7's opening and appendix E still say every repo has a manifest.**
   - Stale: `01-verdict.md:36-37` "Every repo describes itself in `project.yaml` and one make contract". `07-projects.md:3` "Every repo is a project with the same shape". `e-field.md:66` "many unrelated repos, each with a manifest".
   - Current: `04-loop.md:56`, `07-projects.md:68-79`, `13-decisions.md:15`, `faq.md:6`.
   - Why it misleads: §1 is the most-read section, and it negates the v2.4 decision.
   - Fix: change the three stale lines to "every repo takes requests; a manifest adds automation".

4. **CLI verbs, API intents and inbox events that other sections rely on are in no wave.**
   - `12-plan.md:23` builds only `factory issue new|show|phase|merge|split|ask|block|ship|close|drop`, `status` and `resume`.
   - Used elsewhere:
     - `04-loop.md:146` has `factory issue prio|dep`.
     - `10-surfaces.md:91` has `steer`, `decide`, `artifact`, `job` and `session`.
     - `10-surfaces.md:87` has `factory project check`.
     - `10-surfaces.md:67` lists the intents pause, stop and re-verify.
     - `06-state.md:43` has the inbox events `steer`, `pause`, `stop` and `answer`.
     - `05-capacity.md:85-87` has the orchestrator changing a lead's model or effort, pausing a project and putting a card to you.
   - Why it misleads: W3's "orchestrator: its events, initiative plans and wave reviews" gives it no verbs to act with.
   - Fix: add the orchestrator verbs and the pause and stop paths to W3, `project check` to W4, `decide` and `artifact` to W5, and `job` and `session` to W6.

5. **The SessionEnd hook is relied on but not built.** `04-loop.md:117` ("SessionEnd hook the session's end") and `06-state.md:40` (`session_ended`) need it. `12-plan.md:23` lists only "the SessionStart and Stop hooks". Fix: add SessionEnd to the W1 list.

6. **`00-reading-order.md` still has DBOS as an open decision.**
   - `00-reading-order.md:21` says "DBOS your call (§6)" and `00-reading-order.md:27` says "Owner decisions | five | one: durable execution (§6)".
   - `00-reading-order.md:10` ("no decision is open"), `13-decisions.md:3` and `06-state.md:12` say no DBOS and nothing open.
   - Fix: "an Issue state machine with an inbox, no DBOS" and "Owner decisions: none open".

7. **`02-what-changes.md:41-43` still describes the v2.3 build topology.**
   - It says "steered by one orchestrator tab… From W3 on, the factory's orchestrator takes over".
   - `12-plan.md:57-77`, `13-decisions.md:14` ("one build tab (v2.3)" is the rejected alternative) and `faq.md:41` have a build orchestrator over one wave orchestrator per wave, handing over at W3's gate.
   - Fix: replace the §2 sentence with the §12 shape.

8. **Whether a request is a Signal is inconsistent.**
   - `04-loop.md:34` has Intake take "a poller per source; your requests" and output "Signal".
   - `04-loop.md:50` says requests "go straight to Classify", skipping dedup.
   - `08-dedup.md:29` lists "GitHub issues" as a stateless signal source with fingerprint dedup. `d-edge-cases.md:18` ignores other people's GitHub issues, and `04-loop.md:51` makes yours requests.
   - Why it misleads: the implementer cannot tell whether to write a `signals` row and run dedup for a GitHub request.
   - Fix: requests create Issues directly. Remove "your requests" from the `04-loop.md:34` row and "GitHub issues" from `08-dedup.md:29`, or limit it to CI and checks.

9. **Several things §5 and §8 require have no Postgres table in §6.**
   - `05-capacity.md:83-84` says action items with a due date are "kept in Postgres", and `09-jobs.md:49` puts them on the scorecard. Neither appears in `06-state.md:106-119`.
   - `06-state.md:42` has `hold_over` as "a timer row"; the only timing column is `issues.wake_at` (`06-state.md:110`).
   - Missing too: the judge's shadow verdicts (`08-dedup.md:42`, `09-jobs.md:48`) and the scorer "label per rubric" (`09-jobs.md:37`).
   - Parent and child for initiatives (`06-state.md:110`) fits neither `issue_deps` nor the `issue_links` types.
   - Fix: add an `action_items` table and a timers table (or define `wake_at` as the timer). Add a column or event type for judge verdicts and rubric labels, and a parent link for child Issues.

10. **The weekly tuning job and several admission and learning rules appear in no wave and not in §9.**
    - The weekly tuning job is named at `00-reading-order.md:35`, `05-capacity.md:65-66`, `05-capacity.md:102-104` and `13-decisions.md:22` ("the tuning job moves the defaults"). It is absent from the `09-jobs.md:29-38` job table and from `12-plan.md`. §5 says it proposes, while §13 says it moves.
    - Also absent from the W3 row (`12-plan.md:25`): stop the line (`05-capacity.md:49-50`), the 15 % `iu` reserve (`05-capacity.md:47`) and "every factory project still gets one upkeep Issue a week" (`05-capacity.md:41`). `d-edge-cases.md:22` is the only wave tie for stop-the-line.
    - Absent from W4 (`12-plan.md:26`): monthly judge calibration (`08-dedup.md:70-71`) and label maintenance.
    - Fix: add the tuning job to the §9 table and to W3 or W6 as a job that proposes only. List the other items in the wave rows, or cut them.

11. **The manifest's `ship:` block conflicts with `deploy.mode`.**
    - `07-projects.md:12` says `deploy.mode: auto` means "a push deploys". `07-projects.md:19-20` says `ship[].mode: auto` means "the lead merges and deploys once its checks pass". The other `ship.mode` values are never defined.
    - `04-loop.md:69` says Ship runs "by the project's `deploy.mode`", while `04-loop.md:106` says "which paths ship on their own".
    - Why it misleads: the per-path autonomy schema cannot be built.
    - Fix: enumerate the `ship.mode` values in §7 and say how `ship` and `deploy.mode` combine. Rename one `mode` key.

12. **Who writes probes is stated two ways.**
    - `01-verdict.md:50-51` says probes are ones "no lead writes", and `04-loop.md:90` says they are "written by nobody who ships".
    - `04-loop.md:93`, `03-principles.md:22-23` and `d-edge-cases.md:16` say "changing a probe is an Issue of its own", and §3 says such Issues are shipped by a lead.
    - Why it misleads: it affects permissions and review rules.
    - Fix: "no lead edits a probe within the Issue it is shipping; probes change only through their own Issue."

13. **The "six numbers" differ between §11, §9, §10 and §1.**
    - `11-proof.md:19-20` calls them "a subset of the §9 scorecard", shown on *Now*.
    - `09-jobs.md:44-50` has no "Issues closed without production evidence". It uses "interrupts that reached you" where §11 says notifications. It measures time as p50 and p95 from Issue to lead, lead to ship and ship to close, where §11 has "time to resolve, median / p90 ≤ 0.5 h / ≤ 4 h". `09-jobs.md:38` places the scorecard on *Factory*.
    - `10-surfaces.md:60` does not list the numbers under *Now*.
    - `01-verdict.md:58-65` is a different "numbers" table of six with different metrics, while `12-plan.md:30` says the observation period checks "the SLOs in §11".
    - "Resolve" is undefined, and a median of 0.5 h cannot be met by any lead-handled Issue that waits out the 30-minute hold (`07-projects.md:15`).
    - Fix: make §11's six measures rows in §9 (using p90 or p95 consistently), define "resolve", name the page, and label §1's table as the v1 baseline only.

14. **Orchestrator wake triggers differ across sections, and the "idle watchdog" is undefined.**
    - `05-capacity.md:73-79` has five events plus two schedules.
    - `07-projects.md:77` says "only initiatives, stuck leads and conflicts" wake it.
    - `d-edge-cases.md:13`, `d-edge-cases.md:21` and `d-edge-cases.md:22` add stopping again unreported, three pane deaths in ten minutes, and three failed production checks.
    - `03-principles.md:35-36` says "the one liveness rule is the idle watchdog", which no other section defines or any wave builds. `05-capacity.md:75` uses "two hours of work time" instead.
    - Fix: one trigger list in §5 that includes the `d-edge-cases.md` events. Define the watchdog as that rule or delete the phrase.

15. **Cards to you appear for non-business reasons.**
    - `d-edge-cases.md:13` ("a card to you until W3") and `d-edge-cases.md:22` ("you get one card") conflict with `03-principles.md:26-28`, `01-verdict.md:53` and `04-loop.md:177` ("does not wait for you either").
    - Fix: route both to the orchestrator, or build orchestrator, from W1 (`05-capacity.md:92`). Alternatively mark them as the one explicit exception.

16. **Decision cards and TickTick items have no delivery surface before W5.**
    - `factory issue ask` ships in W1 (`12-plan.md:23`, `10-surfaces.md:90`), but web push and *Now* arrive in W5 (`12-plan.md:27`).
    - `07-projects.md:85-86` and `a-review-log.md:106` say the factory adds a TickTick item when an Issue needs your hand. W2 builds only the `#factory` read side (`12-plan.md:24`), and no verb creates the item. That is also unclear between `ask` and `block`.
    - Fix: name the interim channel for W1 to W4 and the verb or wave that writes to TickTick.

17. **The state machine has no state for park, pause or stop.**
    - `04-loop.md:161-175` has the states settling, queued, working, waiting, watching and closed. `04-loop.md:140` and `04-loop.md:178` have the orchestrator "park" an Issue.
    - `06-state.md:43` has `pause` and `stop` events, and `06-state.md:108` and `05-capacity.md:86` have a project "pause state". `06-state.md:31` builds the transition table from "the states in §4".
    - Fix: say that parked means `waiting`, stop leads to `closed` as dropped, and pause is a project flag.

18. **Gamedays assigned to W1 and W2 are not in the gate rows.**
    - `11-proof.md:12-16` assigns the seeded-bug gameday and the Stop-hook gameday to W1, and the kill mid-runbook gameday to W2.
    - `12-plan.md:23` (W1 gate) omits the first two. `12-plan.md:24` (W2 gate) omits the third.
    - "Adopt mode" (`11-proof.md:15`) is defined only at `d-edge-cases.md:10`, not in §6.
    - Fix: add the gamedays to the gate rows and a line about adopt mode to §6.

19. **The review log's header names the wrong current table.**
    - `a-review-log.md:4-5` says "the v2.2 table at the end is current". The last table is "Your reply on v2.3" (`a-review-log.md:132-146`).
    - `a-review-log.md:117` says it supersedes "rows 2, 3, 17, 19 and 24 above", but two numbered tables sit above it. Row 2 of the 33-comment table (`a-review-log.md:12`, "investigations are agent-gateway OpenCode sessions") is stale and not clearly superseded.
    - Fix: "the table at the end is current", and name the table behind the row numbers.

20. **`c-from-v1.md:43` puts the first rule change in the wrong wave.** It says "a fresh pre-registration is frozen before the first rule change in W3". Dedup rules and the golden-set gate are W2 (`12-plan.md:24`, `08-dedup.md:41-42`, `11-proof.md:5-6`), and no wave builds the freeze. Fix: W2.

21. **`b-landscape.md:18` credits a merge lane.** It says "the ready queue with blockers; Witness; a merge lane (§4)". The merge lane is listed as gone at `12-plan.md:8`, and `c-from-v1.md:50` says merge and deploy moved into the lead. Fix: delete "a merge lane".

22. **"The one revert in the design" contradicts the no-rollback wording.**
    - `d-edge-cases.md:9` says "if the health check fails, the previous release starts again. That is the one revert in the design".
    - `00-reading-order.md:49`, `13-decisions.md:20`, `12-plan.md:9` and `c-from-v1.md:52` say there is no automatic rollback, and a lead may revert at `04-loop.md:73-75`.
    - Fix: say "no automatic rollback of shipped changes; the factory's own release swap is the only automatic revert".

23. **"Wave", "orchestrator" and "lead" each carry several meanings.**
    - Wave means: the build waves W1–W6 (`12-plan.md:21`); an initiative's child Issues (`04-loop.md:53-54`, `05-capacity.md:40`); a `/wave` chain a lead uses (`04-loop.md:65`); and an "upgrade wave" (`09-jobs.md:69`, `12-plan.md:28`). `09-jobs.md:31` makes an upgrade wave one Issue, which the name does not suggest.
    - Orchestrator means the factory's orchestrator (§4), the build orchestrator and the wave orchestrator (`12-plan.md:62-63`). `02-what-changes.md:41` and `12-plan.md:68` ("the orchestrator starting it") leave it unqualified.
    - `12-plan.md:75` calls a wave orchestrator "a lead whose tool is a `/wave` chain", while `04-loop.md:138-141` defines orchestrator and lead as disjoint layers.
    - Fix: reserve "wave" for build waves and initiative waves, call the other uses "upgrade Issue" and "`/wave` chain", and always say "build orchestrator", "wave orchestrator" or "the orchestrator" for the factory's.

24. **"Hold", "evidence", "class" and "factory project" are overloaded.**
    - Hold is the 30-minute window (`04-loop.md:129`), the state `watching` (`04-loop.md:170`), the step "Watch" (`04-loop.md:41`), the timer key `hold:` (`06-state.md:42`) and a manifest key (`07-projects.md:15`). `06-state.md:52` also uses "holds" for claims.
    - Evidence is the brief's input (`04-loop.md:102`), ship output (`04-loop.md:82`), the `evidence` table (`06-state.md:116`), `open({evidence})` (`09-jobs.md:20`) and the `evidence/golden/` directory (`11-proof.md:5`).
    - "Upkeep" is both a kind (`04-loop.md:49`) and an admission class (`05-capacity.md:41`). `issues.class` and classification's "urgency" (`04-loop.md:37`) have no stated mapping, and no `feature` kind is defined.
    - "Factory project" (`05-capacity.md:41`, `09-jobs.md:59`) now means either every repo or only repos with a manifest.
    - Fix: one definition each, in §4 or §6.

25. **The retirement of the "headless implement lane" and `agw dispatch implement` is described inconsistently.**
    - `10-surfaces.md:114` says "W1 stops its only caller (warden); W6 removes the lane".
    - `a-review-log.md:139`, `12-plan.md:28` and `00-reading-order.md:74` say `agw dispatch implement` is "retired in W6". The reply reads as if there are other users.
    - `05-capacity.md:13` says the implement lane "runs on Max only".
    - Fix: name the lane once, state its callers, and say which wave removes it.

26. **`otel` moving to a cheap OpenCode route sits against "never diagnose for a lead".**
    - `12-plan.md:23` and `a-review-log.md:140` move `otel` to cheap models in W1.
    - `04-loop.md:64` makes `/otel` the lead's Investigate tool. `05-capacity.md:11` says IU API tokens "never implement and never diagnose for a lead". `03-principles.md:8-9` and `04-loop.md:98-99` say no cheap-model root cause.
    - Fix: say the `otel` route returns data and query results, not causes, or list it as an explicit exception to the §5 rule.

27. **`04-loop.md:57-58` keeps a v2.3 remnant about Hermes.** It says sessions you "ask Hermes to open (`rd work`), stay outside too". `10-surfaces.md:102-103` turns Hermes's "do X" into `factory issue new`, and `07-projects.md:73` has Hermes filing requests. The routing rule for Hermes is unclear. Fix: say which Hermes phrasing starts a plain session and which files a request.

28. **Scorers read transcripts, but §6 says the factory never parses them.** `09-jobs.md:37` and `12-plan.md:26` have scorers run over lead transcripts and open Issues from the result. `06-state.md:100-102` says the factory "never parses them for decisions". Fix: add "except the scorers job, which reads them read-only for labels".

29. **Model escalation is described three ways.**
    - `05-capacity.md:62` sends "a second attempt after a failed one" to Opus.
    - `05-capacity.md:64` and `12-plan.md:25` say "re-spawned one tier up", so Haiku goes to Sonnet.
    - `05-capacity.md:85` has the orchestrator "change a lead's model or effort", which `05-capacity.md:98` ("a lead keeps its account to the end") and the `Runner` port (`06-state.md:82`, no set-model) do not support.
    - Fix: "next tier up, Opus at most; the orchestrator's changes apply at the next spawn".

30. **Minor items.**
    - `07-projects.md:24` has `signals.umami`, but no adapter exists. `10-surfaces.md:37` omits Umami from the poll list, and `09-jobs.md:58` makes the traffic job a later trigger.
    - `10-surfaces.md:103` says Hermes crons become factory jobs, but no job covers them.
    - The gantt (`12-plan.md:43`) starts W6 "after w3" only, yet `10-surfaces.md:105-106` needs W5's Artifacts page and the `deps` job needs W4's manifests. Done in order that is about 10 days, not the "≈ 9" at `12-plan.md:52`.
    - Wrong section references: `a-review-log.md:11` points to §13 for "`factory`, with `wave` underneath", which §13 does not contain. `04-loop.md:178` cites §5 for "parks it", which §5 never mentions.
    - `05-capacity.md:113` puts "hours Issues waited" on *Usage*, while `13-decisions.md:33` says *Factory* shows it.

**Verdict.** The decision layer is consistent. DBOS is out, there are two layers, IuRoot is out, and warden goes at W1. The numbers agree everywhere I checked: F1 0.889, the 0.95 over 30 judge gate, the 0.8 and 0.2 thresholds, the 15 % and 10 % rules, the 30-minute hold, the 1.8× headless cost, $183 and $136, the pool shares and the `iu`/`me` snapshot. The damage is in two places. First, v2.1–v2.3 sentences that were never swept: items 3, 6, 7, 19–22 and 27. Second, traceability from the design to the plan, which is the larger risk because an implementer working from `12-plan.md` would miss real dependencies: items 1, 4, 5, 9, 10, 16 and 18. Items 1, 2, 4 and 8 would send an implementer down the wrong path outright, so fix those first. Most of the rest are one-line edits.
