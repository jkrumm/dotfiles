# Owner reply to the v2.3 chat summary (2026-10-25, night)

Verbatim, as sent in chat:

> - "agw dispatch_implement" may not be needed anymore soon anyways
> - otel is token hungry but not soo hard or difficult so we could maybe even use OpenCode with DeepSeek or Haiku or so?
> - "mothers and the steward are now one agent" you are saying this about the implementation of factory it self OR about the Herdr orchestration then once we have build it by the factory? Because building the factory is what i meant where a orchestrator of orchestrator will make sense because it basically touches every repo on my machine
> - I reconsidered an think IuRoot might really be fully disabled here and on ly SourceRoot is read because my endavors of AthenaTeamchat there BUT that will probably resul in two different global Agents.MD needed per project root
> - This claude code "wrapping" where you say not claude -p or maybe claude --bg but Herdr we will need to revisit that once the ecosystem matures but the broad flow would remain anyways so probably fine yes
> - dedub through decision model puh we will really need to measure how well that works
> - No  project.yaml for not orchestrator based may not be optimal because I would maybe still want to trigger work there over Factory but just maybe without an orchestrator and rather just many tabs or most usually one at a time
>
> Thanks for the brain stuff knowledge base so maybe still some few things open before i would read the report again throughly, right? What do we need to decide on still? Also really give the plan a review and think about it kinda fresh with all the iterations in concept I am feared things arent matching up perfectly anymore. Maybe we even want to switch to a fresh agent doing that or actually as you compacted we have that maybe anywys already

## Reading

1. `agw dispatch implement` retires once the factory takes requests; a factory Issue replaces it.
2. `otel` moves off Max to a cheap model on the OpenCode lane, picked on recorded queries.
3. The orchestrator of orchestrators was meant for *building* the factory, which touches nearly every
   repo. The running factory keeps two layers; the build gets a build orchestrator over one wave
   orchestrator per wave until W3.
4. IuRoot is outside the factory entirely; only `~/SourceRoot` is read. Per-root agent instructions are
   an AthenaTeamchat question; the factory's standing orders travel in each brief.
5. The runtime choice is revisited as the ecosystem matures; the flow stays.
6. The dedup judge must be measured; its numbers go on the scorecard.
7. Repos without a manifest still take requests through the factory, one lead at a time by default,
   without the orchestrator.
8. A fresh, unanchored review of the whole design for consistency after many iterations.
