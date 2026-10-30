# Owner comments on report v2.1, 2026-10-25 (Plannotator, verbatim)

Plus the chat message of the same day: "Claude Code should do the full end-to-end thing … approach it with what the problem is, and then let Claude Code figure out and decide on how it is going to solve it … the dumb models will not build it as good as the smart tier-one models, and even they could be confused by the claims the cheap model already made."

I've reviewed this document and have 25 pieces of feedback:
### 1. Feedback on: "Claude Code implements; cheap models do the rest. Claude Code on Max, in herdr, does all implementation. Cheap models on IU API tokens (DeepSeek V4.1 Flash, Haiku 5.5, the decision model) do everything else that needs a model — dedup, root causes, planning, wording, review. Plain code does what needs no model."
> I don't know. I think we are not fully yet here. So I mean, before it, you described it quite well with the loop of how we ingest everything and categorize and deduplicate and and queue it basically. But Claude Code is the smart actor here. I think it shouldn't only implement. It should also find the root causes, and. Plan it, and implement it. Test and verify it. Ship it. Verify it again, and then communicate back to the factory, queuing what the state of that is. So, I don't know if you're finding the right balance here still already. 
### 2. Feedback on: "Short durable workflows. DBOS runs each stage — investigate, verify and merge, deploy — as a workflow of a few minutes; anything that waits lives in a table. A crash or a redeploy repeats at most one short stage."
> Not sure what DBOS will need to do in the end and if and how it is needed and used I feel like I maybe pushed you too hard for DBOS but I just wanted to get your weird claim "we dont use because node not bun" 
### 3. Feedback on: "Dedup is deterministic first and learns. Rules group signals (F1 0.889 on the held-out set); a decision model scores the ambiguous rest; the investigator merges and splits; every grouping decision is kept as a label."
> We need to see if a decision model can even do that well and how we need to provide the sufficient context for it and contruct ir or if we need use a DepeSeek based OpenCode flow here
### 4. Feedback on: "Verification gates shipping, and the candidate cannot weaken it. Checks run on the merge result with the base branch's own Makefile and tests; a failed post-deploy check rolls back to the last deploy that held."
> Honsetly I am not so sure with that rollback stuff .. yeah in theory sounds great but honestly in my career we just usally fixes it asap haha AND many things e.g. infra or dotifles or data changes etc. cant even be rolled back ... so a forward oriented approach may even be smoother
### 5. Feedback on: "You ask for work in one sentence — in Argo, to Hermes, as a TickTick item tagged #factory, or factory issue new weatherorb "…". It is planned, queued, built in herdr, verified and shipped; you read about it in the morning briefing."
> Yeah exactly we just need to queue what ever into factory and it then has its OpenCode based agent loop queueing the work to waves OR just creating ClaudeCode sessions in Herdr to let is cook (implement, verify, test, review, ship, verify, ... in Herdr ClaudeCode) then of course it now about the item and the state and I can chat about it in Hermes or so OR just see and chat with it in Argo Dashbaord or see in it Herdr. Factory is a lifecycle around that feat/issue/bug
### 6. Feedback on: "Work repos stay yours. IuRoot is never monitored and the factory never starts work there."
> We do not listen to bugs what so ever yes BUT we maybe use wave implementations and the faactory to manage lyfecycle of implementation but yeah no auto triage etc. but yeah eventually it is easier to jsut keep those out the way for now anyways not really sure here if that makes the factory implementation worse and more instable and complicated we maybe better like you suggest here
### 7. Feedback on: "Code, cheap models, Claude Code — in that order. What a script can decide, a script decides. Everything else that needs judgment or words goes to a cheap model, freely. Implementation goes to Claude Code."
> Suggested else previously
### 8. Feedback on: "Max writes code, IU API tokens think. Claude Code on the iu and me Max accounts is the only thing that changes a repo, and it runs in herdr, where you can watch it. IU API tokens pay for gateways, OpenCode, Hermes, research and review. A full Max pool means waiting, never spilling."
> Adjsuted above as well
### 9. Feedback on: "make targets, agent-gateway review, merge, deploy, hold"
> BUT coordinated still through Max in Herdr using those tools yes 
### 10. Feedback on: "root cause, fix recipe, grouping labels"
> Yes afterwards for docs and next issue intake, dedup, known fix docs etc.
### 11. Feedback on: "cheap model in an agent-gateway OpenCode session"
> Naah this is too dificult we just hand over the task to the smart ClaudeCode triaging it properly we just try dedubbing and classifying it potentially but understanding and planning needs smart model
### 12. Feedback on: "Requests — Argo, Hermes, a TickTick item tagged #factory, factory issue new — start at Investigate + plan. A request that already has a plan starts at Admit."
> And my users GitHub issues OR GitHub issues where my user tags factory or so in a comment
### 13. Feedback on: "What every Claude Code session gets#"
> outdated with previous alignment
### 14. Feedback on: "Verify, ship, roll back#"
> All handled by ClaudeCode in Max soo difficult for factory too cleanly coordinate and mange with dumb models and ClaudeCode can then also itereate and resolve better fully but of course uses all that
### 15. Feedback on: "everything else that needs a model: dedup, root-cause search, linking signals and jobs, structured JSON, wave planning, naming, every message and briefing, job summaries, review, research, the gateways, Hermes"
> Yes except maybe root-cause search, and actual planning but YES ... hmm maybe though I am condraticting my self here becasue we maybe need to find root cause already for dedub and or merge with other issues hmm
### 16. Feedback on: "Adopted. DBOS Transact (TypeScript SDK, MIT, a library — no extra server) runs on Postgres and gives the factory durable steps, queues with concurrency and priority, scheduled jobs and a recorded history of every run, which Argo shows on Factory. Its TypeScript SDK runs on Node, not Bun, so the factory service runs on Node 24. Your call was right twice: v1's spike used it wrong, and Node is no reason to skip it."
> People even got it working with bun : https://github.com/runablehq/dbos-starter-template
### 17. Feedback on: "DBOS, with short workflows#"
> I will learn about DBOS as well but I am not sure if we use it or can learn a ton from it 
### 18. Feedback on: "TickTick stays your personal list. A project's manifest names its list; Argo shows the open items on the project page, and an item tagged #factory becomes a request."
> Yeah stuff that I as a human need to do 
### 19. Feedback on: "agent-gateway's decision model returns the probability that both share a cause. ≥ 0.8 merges, ≤ 0.2 keeps apart, anything between attaches them as possibly related for the investigator. A failed call keeps them apart; intake never waits on it"
> Needs to be tested
### 20. Feedback on: "8. Dedup and learning"
> Sounds good especially if continous learning and maturity and self improvement is part of it just not sure if that is really going to work well. Will be tricky!
### 21. Feedback on: "A job is a small TypeScript module, not an agent. Code does the looking; a cheap model writes up and groups what it found. Swamp's ideas, without its runtime: typed steps in code, assertions as first-class steps, nothing spent when everything is fine."
> NICE I think there is soo much more to learn from Swamp Club as well AND we maybe want more and more deterministic paths as well where possible but always use agentic smartness where neded
### 22. Feedback on: "The changelog is not a job of its own: the brain page section is written from conventional commits on each merge (§7)."
> Naah concentional commits are not that nice concise and for humans in the end haha ... I want and insanely sharp summary in my brain and to be seen in Argo 
### 23. Feedback on: "First jobs#"
> Also maybe we want to monitor success of subscription choosing AND the dedub and learn perfromance AND the whoel factory pipeline it self 
### 24. Feedback on: "12. The plan"
> I yeah I'm not reading the following as of now because I think there is still some little bit of rework to be done and I'm going to read it. But what I'm thinking already is that this is posing an even greater implementation effort than everything we have seen until now, and we maybe even need a like a daddy orchestrator maybe that watches overall the mother agents of each project and. This whole project as a whole, like really really careful, to not spend tokens and to stay lean and efficient and routing everything down, to also check for the usage limits, to check for the routing of the subscriptions, and to check for the five hour window, especially of our me subscription, to handle everything nicely and to really look carefully at this whole long running endeavor of implementations to succeed nicely, and to really steer this whole endeavor. Yeah, this will be a great great cloud code implementation challenge. What we are building here.  At the same time, of course, I want to be spending efficient. So we can only achieve this in our two subscriptions, or in the next weeks. Actually, we'll spend a lot of tokens if we are choosing the model and effort wisely. Actually, even Haiku nowadays is a smart model, yeah. 
### 25. Feedback on: "Default: W1 starts on the me account on Mon 26 Oct, unless your comments change §4–§12. A fresh orchestrator session in the SourceRoot workspace reads §4, §6 and this section and runs W1 as a /wave chain. From W3's gate on, factory wave run queues the remaining waves in the factory itself."
> Nah we start soon already after my final review and we some final things to resolve here in the plan
---
