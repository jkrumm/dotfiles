### 6 [section:nth-of-type(2) > ol:nth-of-type(1) > li:nth-of-type(3)]
> Signals come from their primary sources, with source time. Slack intake stops at W1a, and the adapters replace it from W3a.
But over slack maybe some other incidents reach us that can't trigger webhooks to Tailscale protected Argo, right??

### 7 [ol:nth-of-type(1) > li:nth-of-type(7) > ul > li:nth-of-type(2)]
> Routine work and factory judgment, meaning mother wakes: OpenCode/IU.
Does could also run just in OpenCode over AgentGateway or not? Not sure about the tradeoffs maybe better still with Herdr not sure. OpenCode v2 has good durable long running and better communication between warden back and forth possible? Maybe I am wrong here

### 8 [section:nth-of-type(2) > div:nth-of-type(2) > table > tbody > tr:nth-of-type(1) > td:nth-of-type(2)]
> Tasks live in the ledger with bd's verbs; beads' runtime is not adopted (cross-repo deps inert, 5-min fixed lease, work repos touched)
If we dont use bd maybe the CLI doesnt need to be named like it? Maybe then wave or so may be a better CLI naming or so?

### 9 [section:nth-of-type(2) > div:nth-of-type(2) > table > tbody > tr:nth-of-type(9) > td:nth-of-type(2)]
> Argo split: factory read API on the mini, SPA and life data on the VPS, dead-man's switch on the VPS
Does that make sense splitting it? We could just unify it on the always on mini, no?

### 10 [section:nth-of-type(2) > ol:nth-of-type(2) > li:nth-of-type(1)]
> IU cash for factory-originated work — default: A, 3 mother wakes per mother per day, ≈ $294/week with the ≈ $28 base. The forecast's rate, 8 per mother per day, is ≈ $735/week.
Confusing factory, warden, etc. can use cheap models for all their work of classificaiton, deduplication, orchestration etc. e.g. DeepSeek Flash or so. THEN we give the issues to be triaged as new waves to the ClaudeCode Max mothers which actually implement, verify, test, ship etc. them, right?!

### 11 [section:nth-of-type(2) > ol:nth-of-type(2) > li:nth-of-type(3)]
> Autonomy in work repos — default: read, investigate and open PRs; never merge or deploy.
Nah in StudentEnrolment often the agent can auto merge things in prometheus-scripts AND data-analysis stuff in StudentEnrolment. The other repos as well as actual domain code we maybe be rather careful. Also we dont need it in the normal warden etc. monitoring so that would just be agentic dev work initiated by me in sessions or mothers etc.

### 12 [section:nth-of-type(2) > ol:nth-of-type(2) > li:nth-of-type(4)]
> Who defines "it works" for each product — default: the project's mother drafts holdout scenarios from W5. A set binds on measurement, never on a timer, and you can edit it at any time.
Dont understand what you want here from me? But yeah i guess fine

### 13 [ol:nth-of-type(2) > li:nth-of-type(5)]
> Retention of agent transcripts and dead sessions — default: archive to the homelab and keep the local copies. Deleting them (after 90 days) is never defaulted and waits for your yes.
ok

### 14 [#s1b-during-the-rewrite]
> During the rewrite#
Its totally fine to shutdown all this warden or argo or hermes during rewrite no worries on anything below haha i can still just use ClaudeCode in Herdr 

### 15 [#s1b-during-the-rewrite]
> During the rewrite#
Its totally fine to shutdown all this warden or argo or hermes during rewrite no worries on anything below haha i can still just use ClaudeCode in Herdr. Maybe this even simplifies your transition and maybe introduces less sideeffects in the meantime. We can also drop all old data in warden 

### 16 [li:nth-of-type(2) > ul > li:nth-of-type(5)]
> the morning and evening briefing: one push with an audio link
Does go to argo and are nicely rendered there? Maybe even not really needed anymore anyways other than maybe nice TTS if so. Probably only morning briefing is fine as well

### 17 [#s2-2-2-where-the-owner-s-attention-goes]
> 2.2 Where the owner's attention goes#
Honestly my attention was never there because soo many alerts/quetsion where unecessary and should have been automatically resovled AND the writing was overcomplicated AI slop with unecessary technical details

### 18 [section:nth-of-type(5) > div:nth-of-type(1) > table > tbody > tr:nth-of-type(7) > td:nth-of-type(5)]
> the deploy reconciler, only — it consumes started / deployed / failed Signals from every source (make deploy wrapper, RollHook, WUD, CI) keyed target + artifact, change optional; a container replaced with no recorded intent is an unplanned Deployment
No all thinks are automatically deployed and need individual deterministic make commands or agentic pipelines

### 19 [#s3-5-warden-s-65-column-row-decomposed]
> 5. Warden's 65-column row, decomposed#
Told you as well we can fully drop current warden and fulyl rebuild we dont even need ot migrate data or whatever. Also with outage it doesn need to be kept running. So maybe even full sunset and full fresh hreworked sunrise makes sense. To build a more mature simple product without legacy quirks and workaround and weight. We wanna look into the future here

### 20 [section:nth-of-type(5) > div:nth-of-type(4) > table > tbody > tr:nth-of-type(5) > td:nth-of-type(1)]
> dotfiles
hmm i dont think dotfiles should be fleet and should be session 

### 21 [section:nth-of-type(6) > ol:nth-of-type(2) > li:nth-of-type(2)]
> Dedup, by source kind. Stateful sources, whose recovery signal closes the episode (Kuma, Beszel): subject state — a firing repeated while no Up was seen stays in its incident within w_open, a re-fire right after an Up rejoins within w_reopen, and the recovery closes the episode. Stateless sources (CI failures, log lines, issues, chat): the same refined fingerprint inside w_dedup, also while an inc
Yeah but maybe we also need agentic support here with cheap models or even decisions models probably also like a workflow with probability etc. not exactly sure this needs fine tuning

### 22 [section:nth-of-type(6) > ol:nth-of-type(2) > li:nth-of-type(2)]
> Dedup, by source kind. Stateful sources, whose recovery signal closes the episode (Kuma, Beszel): subject state — a firing repeated while no Up was seen stays in its incident within w_open, a re-fire right after an Up rejoins within w_reopen, and the recovery closes the episode. Stateless sources (CI failures, log lines, issues, chat): the same refined fingerprint inside w_dedup, also while an inc
Yeah but maybe we also need agentic support here with cheap models or even decisions models probably also like a workflow with probability etc. not exactly sure this needs fine tuning. Maybe we can also learn through past dedubs

### 23 [section:nth-of-type(6) > ol:nth-of-type(2) > li:nth-of-type(2)]
> Dedup, by source kind. Stateful sources, whose recovery signal closes the episode (Kuma, Beszel): subject state — a firing repeated while no Up was seen stays in its incident within w_open, a re-fire right after an Up rejoins within w_reopen, and the recovery closes the episode. Stateless sources (CI failures, log lines, issues, chat): the same refined fingerprint inside w_dedup, also while an inc
Yeah but maybe we also need agentic support here with cheap models or even decisions models probably also like a workflow with probability etc. not exactly sure this needs fine tuning. Maybe we can also learn through past dedubs OR autcome of investigation etc. OR even merge and dedub during investigation

### 24 [section:nth-of-type(6) > div:nth-of-type(3) > table > tbody > tr:nth-of-type(1) > td:nth-of-type(3)]
> none needed; 2 failed restarts → escalate to code fix / infra
Nice yes many things are partially self healing already so we often just need to wait or increase timeouts on e.g. uptime kuma alerts or so to let it wait for self healing 

### 25 [section:nth-of-type(6) > div:nth-of-type(4) > table > tbody > tr:nth-of-type(1) > td:nth-of-type(2)]
> Renovate opens the PRs (release age ≥ 14 d; automerge is off fleet-wide); the train merges them through the dependency rung (§3); the reconciler watches Renovate's failures and majors
Not sure if we really want to use renovate. Smth deterministic would be nice but often we also need to pull changelogs and migration guides and do the changes agentically and actually use and benefit from new stuff. Oftne maybe rather whole new tickets or waiting for major maturity or yeah whole big improvements around the new things and often things need to move toegether as well. I suaully every now and then run full Claude session to upgrade packages tbh

### 26 [section:nth-of-type(6) > div:nth-of-type(4) > table > tbody > tr:nth-of-type(4) > td:nth-of-type(2)]
> CLAUDE.md/AGENTS.md size, skill count, resident tool-definition tokens
CLAUDE.md are deprecated ONLY AGENTS.md also for ClaudeCode

### 27 [section:nth-of-type(6) > div:nth-of-type(4) > table > tbody > tr:nth-of-type(5) > td:nth-of-type(2)]
> components duplicated in consumers
OR improvements and missing pieces that would help everybdoy being dogfooded back up to basal-ui

### 28 [section:nth-of-type(6) > p:nth-of-type(11)]
> Recurring jobs are reconcilers on schedules; their Conditions flow through correlate → plan → spawn → verify like any outage.
We need to be usage and token efficient all that is great AND especially here again i would like to pomote Swamp https://swamp-club.com/ which has great concepts of using more determinsitc pipelines pieces as well which could help here as well in quality AND costs actually. So I think many can run over either just Haiku for inspection and detmerinistic scripts and code and pipelines or endpoints summarising already or cheap model OpenCode of course as well 

### 29 [section:nth-of-type(7) > div > table > tbody > tr:nth-of-type(2) > td:nth-of-type(1)]
> the mother stays lean and coordinates progress across Beads
Thought we dont use Beads so we should drop the name, right? 

### 30 [section:nth-of-type(7) > div > table > tbody > tr:nth-of-type(6) > td:nth-of-type(2)]
> adapters per primary source; no Slack pulling (ADR-013)
Yeah not sure Slack may receive alerts from other tools but I think we actually are building integration to pool on all those tools etc. right? So we eventually really don't need slack anymore other as my own Hermes interface? Lets see haha. Also it could still be useful for receiving notifications or we switch back to ntfy not sure 

### 31 [#s4b-aligned-dev-setup]
> Aligned dev setup#
Sometimes I have the feeling too much is always going to Herdr and sometimes our single OpenCode durable execution think with cheap DeepSeek model might also be useful or more approiate e.g. research-gateway or warden or audio-gateway etc.

### 32 [section:nth-of-type(8) > div:nth-of-type(1) > table > tbody > tr:nth-of-type(1) > td:nth-of-type(2)]
> Tasks in the ledger with bd's verbs; the ledger is the only home of task state (PLAN.md keeps task ids only); no Attempt noun — a Task's attempts are its worker Agents
Gave critic already that we maybe rather do a through factory CLI concept and take from bd and beads what is good for us and change and extend where we benefit

### 33 [section:nth-of-type(8) > div:nth-of-type(1) > table > tbody > tr:nth-of-type(2) > td:nth-of-type(2)]
> Durable execution = ledger + statecharts + effect registry, generation keys and lease epochs that also fence pushes and merges; no engine
Not sure here especially regarding DBOS but lets see

### 34 [section:nth-of-type(8) > div:nth-of-type(1) > table > tbody > tr:nth-of-type(5) > td:nth-of-type(2)]
> Artifacts are ours: warden artifact module, threads in the ledger, versions in git (committed by the submitting agent), Argo view; plannotator interim
"interim" not essentially needed told you we can stop and rebuild clean. A long running great smart wave implementation for all this will happen right

### 35 [section:nth-of-type(8) > div:nth-of-type(1) > table > tbody > tr:nth-of-type(8) > td:nth-of-type(2)]
> herdr always, engine by class; a forecast guard over every Max consumer that projects the owner's in-cycle burn instead of a fixed reserve, with a victim order (unattended owner waves continue on IU at a trip); inverse rule late in light cycles
We use IU API to our limits anyways ongoingly not sure if we should push wave implementation to it as well. Eventually I am actually buying another Claude/OpenAI subscription soon 

### 36 [section:nth-of-type(8) > div:nth-of-type(1) > table > tbody > tr:nth-of-type(8) > td:nth-of-type(2)]
> herdr always, engine by class; a forecast guard over every Max consumer that projects the owner's in-cycle burn instead of a fixed reserve, with a victim order (unattended owner waves continue on IU at a trip); inverse rule late in light cycles
We use IU API to our limits anyways ongoingly not sure if we should push wave implementation to it as well and rather just let them wait for limit reset especially not urgent tasks. Eventually I am actually buying another Claude/OpenAI subscription soon 

### 37 [section:nth-of-type(8) > div:nth-of-type(1) > table > tbody > tr:nth-of-type(9) > td:nth-of-type(2)]
> Argo split: factory API on the mini, SPA + life data on the VPS; read models read the ledger only and carry as_of, and what has no event source is a labelled live probe; web push from the VPS half, but with the mini dark only the dead-man push is sent (it originates on the VPS; decision and heads-up pushes originate on the mini and their expiries are extended by the downtime); heartbeat carries an
Not sure if this brings more friction than it helps. mini is always on high availability anyways we never have problems with it

### 38 [section:nth-of-type(8) > div:nth-of-type(2) > table > tbody > tr:nth-of-type(2) > td:nth-of-type(3)]
> ledger + statecharts; DBOS equal on crashes, worse on redeploys (spikes/02-durable/)
Maybe you were using DBOS wrong and this can be avoided but also not 100% sure if we really should adopt it anyways

### 39 [section:nth-of-type(8) > div:nth-of-type(2) > table > tbody > tr:nth-of-type(4) > td:nth-of-type(3)]
> measured both; owner chose CLI-first; one policy sentence closes the CLI's only gap, now moved into the CLI as the --wait default (spikes/04-cli-mcp/)
YES I am big on CLI over MCP especially if the CLI is auto gen through the actual codebase like e.g. https://github.com/BrianPugh/cyclopts achieves 

### 40 [ul:nth-of-type(2) > li:nth-of-type(9)]
> Traffic — per-project request volume and anomalies, after the exception-first pages (he named it; it was never asked in 60 days, so it sits last). A live probe: the manifest's integrations.traffic names the OTel service whose request volume it reads; no adapter turns it into events.
Also we maybe need to use more of what Umami offers and integrate it more tightly into our apps

### 41 [section:nth-of-type(9) > div:nth-of-type(2) > table > tbody > tr:nth-of-type(2) > td:nth-of-type(1)]
> B. All on the mini
What I would still recommend

### 42 [section:nth-of-type(6) > div:nth-of-type(1) > table > tbody > tr:nth-of-type(8) > td:nth-of-type(2)]
> CrowdSec decisions, auth anomalies
Maybe https://github.com/cloudflare/security-audit-skill also interesting ... depending on how much even changes in the repo haha

### 43 [section:nth-of-type(2) > ol:nth-of-type(1) > li:nth-of-type(3)]
> Signals come from their primary sources, with source time. Slack intake stops at W1a, and the adapters replace it from W3a.
But over slack maybe some other incidents reach us that can't trigger webhooks to Tailscale protected Argo, right??

### 44 [ol:nth-of-type(1) > li:nth-of-type(7) > ul > li:nth-of-type(2)]
> Routine work and factory judgment, meaning mother wakes: OpenCode/IU.
Does could also run just in OpenCode over AgentGateway or not? Not sure about the tradeoffs maybe better still with Herdr not sure. OpenCode v2 has good durable long running and better communication between warden back and forth possible? Maybe I am wrong here

### 45 [section:nth-of-type(2) > div:nth-of-type(2) > table > tbody > tr:nth-of-type(1) > td:nth-of-type(2)]
> Tasks live in the ledger with bd's verbs; beads' runtime is not adopted (cross-repo deps inert, 5-min fixed lease, work repos touched)
If we dont use bd maybe the CLI doesnt need to be named like it? Maybe then wave or so may be a better CLI naming or so?

### 46 [section:nth-of-type(2) > div:nth-of-type(2) > table > tbody > tr:nth-of-type(9) > td:nth-of-type(2)]
> Argo split: factory read API on the mini, SPA and life data on the VPS, dead-man's switch on the VPS
Does that make sense splitting it? We could just unify it on the always on mini, no?

### 47 [section:nth-of-type(2) > ol:nth-of-type(2) > li:nth-of-type(1)]
> IU cash for factory-originated work — default: A, 3 mother wakes per mother per day, ≈ $294/week with the ≈ $28 base. The forecast's rate, 8 per mother per day, is ≈ $735/week.
Confusing factory, warden, etc. can use cheap models for all their work of classificaiton, deduplication, orchestration etc. e.g. DeepSeek Flash or so. THEN we give the issues to be triaged as new waves to the ClaudeCode Max mothers which actually implement, verify, test, ship etc. them, right?!

### 48 [section:nth-of-type(2) > ol:nth-of-type(2) > li:nth-of-type(3)]
> Autonomy in work repos — default: read, investigate and open PRs; never merge or deploy.
Nah in StudentEnrolment often the agent can auto merge things in prometheus-scripts AND data-analysis stuff in StudentEnrolment. The other repos as well as actual domain code we maybe be rather careful. Also we dont need it in the normal warden etc. monitoring so that would just be agentic dev work initiated by me in sessions or mothers etc.

### 49 [section:nth-of-type(2) > ol:nth-of-type(2) > li:nth-of-type(4)]
> Who defines "it works" for each product — default: the project's mother drafts holdout scenarios from W5. A set binds on measurement, never on a timer, and you can edit it at any time.
Dont understand what you want here from me? But yeah i guess fine

### 50 [ol:nth-of-type(2) > li:nth-of-type(5)]
> Retention of agent transcripts and dead sessions — default: archive to the homelab and keep the local copies. Deleting them (after 90 days) is never defaulted and waits for your yes.
ok

### 51 [#s1b-during-the-rewrite]
> During the rewrite#
Its totally fine to shutdown all this warden or argo or hermes during rewrite no worries on anything below haha i can still just use ClaudeCode in Herdr. Maybe this even simplifies your transition and maybe introduces less sideeffects in the meantime. We can also drop all old data in warden 

### 52 [li:nth-of-type(2) > ul > li:nth-of-type(5)]
> the morning and evening briefing: one push with an audio link
Does go to argo and are nicely rendered there? Maybe even not really needed anymore anyways other than maybe nice TTS if so. Probably only morning briefing is fine as well

### 53 [#s2-2-2-where-the-owner-s-attention-goes]
> 2.2 Where the owner's attention goes#
Honestly my attention was never there because soo many alerts/quetsion where unecessary and should have been automatically resovled AND the writing was overcomplicated AI slop with unecessary technical details

### 54 [section:nth-of-type(5) > div:nth-of-type(1) > table > tbody > tr:nth-of-type(7) > td:nth-of-type(5)]
> the deploy reconciler, only — it consumes started / deployed / failed Signals from every source (make deploy wrapper, RollHook, WUD, CI) keyed target + artifact, change optional; a container replaced with no recorded intent is an unplanned Deployment
No all thinks are automatically deployed and need individual deterministic make commands or agentic pipelines

### 55 [#s3-5-warden-s-65-column-row-decomposed]
> 5. Warden's 65-column row, decomposed#
Told you as well we can fully drop current warden and fulyl rebuild we dont even need ot migrate data or whatever. Also with outage it doesn need to be kept running. So maybe even full sunset and full fresh hreworked sunrise makes sense. To build a more mature simple product without legacy quirks and workaround and weight. We wanna look into the future here

### 56 [section:nth-of-type(5) > div:nth-of-type(4) > table > tbody > tr:nth-of-type(5) > td:nth-of-type(1)]
> dotfiles
hmm i dont think dotfiles should be fleet and should be session 

### 57 [section:nth-of-type(6) > ol:nth-of-type(2) > li:nth-of-type(2)]
> Dedup, by source kind. Stateful sources, whose recovery signal closes the episode (Kuma, Beszel): subject state — a firing repeated while no Up was seen stays in its incident within w_open, a re-fire right after an Up rejoins within w_reopen, and the recovery closes the episode. Stateless sources (CI failures, log lines, issues, chat): the same refined fingerprint inside w_dedup, also while an inc
Yeah but maybe we also need agentic support here with cheap models or even decisions models probably also like a workflow with probability etc. not exactly sure this needs fine tuning. Maybe we can also learn through past dedubs OR autcome of investigation etc. OR even merge and dedub during investigation

### 58 [section:nth-of-type(6) > div:nth-of-type(3) > table > tbody > tr:nth-of-type(1) > td:nth-of-type(3)]
> none needed; 2 failed restarts → escalate to code fix / infra
Nice yes many things are partially self healing already so we often just need to wait or increase timeouts on e.g. uptime kuma alerts or so to let it wait for self healing 

### 59 [section:nth-of-type(6) > div:nth-of-type(4) > table > tbody > tr:nth-of-type(1) > td:nth-of-type(2)]
> Renovate opens the PRs (release age ≥ 14 d; automerge is off fleet-wide); the train merges them through the dependency rung (§3); the reconciler watches Renovate's failures and majors
Not sure if we really want to use renovate. Smth deterministic would be nice but often we also need to pull changelogs and migration guides and do the changes agentically and actually use and benefit from new stuff. Oftne maybe rather whole new tickets or waiting for major maturity or yeah whole big improvements around the new things and often things need to move toegether as well. I suaully every now and then run full Claude session to upgrade packages tbh

### 60 [section:nth-of-type(6) > div:nth-of-type(4) > table > tbody > tr:nth-of-type(4) > td:nth-of-type(2)]
> CLAUDE.md/AGENTS.md size, skill count, resident tool-definition tokens
CLAUDE.md are deprecated ONLY AGENTS.md also for ClaudeCode

### 61 [section:nth-of-type(6) > div:nth-of-type(4) > table > tbody > tr:nth-of-type(5) > td:nth-of-type(2)]
> components duplicated in consumers
OR improvements and missing pieces that would help everybdoy being dogfooded back up to basal-ui

### 62 [section:nth-of-type(6) > p:nth-of-type(11)]
> Recurring jobs are reconcilers on schedules; their Conditions flow through correlate → plan → spawn → verify like any outage.
We need to be usage and token efficient all that is great AND especially here again i would like to pomote Swamp https://swamp-club.com/ which has great concepts of using more determinsitc pipelines pieces as well which could help here as well in quality AND costs actually. So I think many can run over either just Haiku for inspection and detmerinistic scripts and code and pipelines or endpoints summarising already or cheap model OpenCode of course as well 

### 63 [section:nth-of-type(7) > div > table > tbody > tr:nth-of-type(2) > td:nth-of-type(1)]
> the mother stays lean and coordinates progress across Beads
Thought we dont use Beads so we should drop the name, right? 

### 64 [section:nth-of-type(7) > div > table > tbody > tr:nth-of-type(6) > td:nth-of-type(2)]
> adapters per primary source; no Slack pulling (ADR-013)
Yeah not sure Slack may receive alerts from other tools but I think we actually are building integration to pool on all those tools etc. right? So we eventually really don't need slack anymore other as my own Hermes interface? Lets see haha. Also it could still be useful for receiving notifications or we switch back to ntfy not sure 

### 65 [#s4b-aligned-dev-setup]
> Aligned dev setup#
Sometimes I have the feeling too much is always going to Herdr and sometimes our single OpenCode durable execution think with cheap DeepSeek model might also be useful or more approiate e.g. research-gateway or warden or audio-gateway etc.

### 66 [section:nth-of-type(8) > div:nth-of-type(1) > table > tbody > tr:nth-of-type(1) > td:nth-of-type(2)]
> Tasks in the ledger with bd's verbs; the ledger is the only home of task state (PLAN.md keeps task ids only); no Attempt noun — a Task's attempts are its worker Agents
Gave critic already that we maybe rather do a through factory CLI concept and take from bd and beads what is good for us and change and extend where we benefit

### 67 [section:nth-of-type(8) > div:nth-of-type(1) > table > tbody > tr:nth-of-type(2) > td:nth-of-type(2)]
> Durable execution = ledger + statecharts + effect registry, generation keys and lease epochs that also fence pushes and merges; no engine
Not sure here especially regarding DBOS but lets see

### 68 [section:nth-of-type(8) > div:nth-of-type(1) > table > tbody > tr:nth-of-type(5) > td:nth-of-type(2)]
> Artifacts are ours: warden artifact module, threads in the ledger, versions in git (committed by the submitting agent), Argo view; plannotator interim
"interim" not essentially needed told you we can stop and rebuild clean. A long running great smart wave implementation for all this will happen right

### 69 [section:nth-of-type(8) > div:nth-of-type(1) > table > tbody > tr:nth-of-type(8) > td:nth-of-type(2)]
> herdr always, engine by class; a forecast guard over every Max consumer that projects the owner's in-cycle burn instead of a fixed reserve, with a victim order (unattended owner waves continue on IU at a trip); inverse rule late in light cycles
We use IU API to our limits anyways ongoingly not sure if we should push wave implementation to it as well and rather just let them wait for limit reset especially not urgent tasks. Eventually I am actually buying another Claude/OpenAI subscription soon 

### 70 [section:nth-of-type(8) > div:nth-of-type(1) > table > tbody > tr:nth-of-type(9) > td:nth-of-type(2)]
> Argo split: factory API on the mini, SPA + life data on the VPS; read models read the ledger only and carry as_of, and what has no event source is a labelled live probe; web push from the VPS half, but with the mini dark only the dead-man push is sent (it originates on the VPS; decision and heads-up pushes originate on the mini and their expiries are extended by the downtime); heartbeat carries an
Not sure if this brings more friction than it helps. mini is always on high availability anyways we never have problems with it

### 71 [section:nth-of-type(8) > div:nth-of-type(2) > table > tbody > tr:nth-of-type(2) > td:nth-of-type(3)]
> ledger + statecharts; DBOS equal on crashes, worse on redeploys (spikes/02-durable/)
Maybe you were using DBOS wrong and this can be avoided but also not 100% sure if we really should adopt it anyways

### 72 [section:nth-of-type(8) > div:nth-of-type(2) > table > tbody > tr:nth-of-type(4) > td:nth-of-type(3)]
> measured both; owner chose CLI-first; one policy sentence closes the CLI's only gap, now moved into the CLI as the --wait default (spikes/04-cli-mcp/)
YES I am big on CLI over MCP especially if the CLI is auto gen through the actual codebase like e.g. https://github.com/BrianPugh/cyclopts achieves 

### 73 [ul:nth-of-type(2) > li:nth-of-type(9)]
> Traffic — per-project request volume and anomalies, after the exception-first pages (he named it; it was never asked in 60 days, so it sits last). A live probe: the manifest's integrations.traffic names the OTel service whose request volume it reads; no adapter turns it into events.
Also we maybe need to use more of what Umami offers and integrate it more tightly into our apps

### 74 [section:nth-of-type(9) > div:nth-of-type(2) > table > tbody > tr:nth-of-type(2) > td:nth-of-type(1)]
> B. All on the mini
What I would still recommend

### 75 [section:nth-of-type(6) > div:nth-of-type(1) > table > tbody > tr:nth-of-type(8) > td:nth-of-type(2)]
> CrowdSec decisions, auth anomalies
Maybe https://github.com/cloudflare/security-audit-skill also interesting ... depending on how much even changes in the repo haha

