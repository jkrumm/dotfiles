# Owner voice note on platform concept v2 (2026-10-27)

Transcribed voice message after the two 2026-10-26 podcasts ("Wiedervorlage" and "Wer besitzt den
Agenten"). It answers `design/gateways.md` (concept v2) and the order in TDD v2.4. Summary of what it
asked, in the order it came:

1. **Order flips: platform first.** Switch warden off now, as a step of its own, not inside W1a. Then
   rebuild agent-gateway as the platform, slim down the Claude Code and Hermes setups on top of it,
   and only then build the factory on that cleaner base, so the factory needs no later refactor.
2. **The platform's promise, confirmed:** one project and one dependency tree; usage tracking, model
   choice and telemetry centralised into fewer tools; one framework that stations implement thinly.
3. **No MCP**, except perhaps chrome-devtools. Agents discover tools through the CLI; no lost
   connections, no tool-definition bloat. Typing from OpenAPI. Durable execution and clean restarts
   that never abort a job. Separate runtimes per station.
4. **Flexible OpenCode agents stay the default** (skills, tools, writing throwaway code), with fixed
   angles where they matter (review lenses, whether OCR runs).
5. **Gap: workflows.** Many stations need structure around the agent, not only an agent:
   - before: decide whether prep is needed, run a decision model, fire initial prompts, research first
   - core: the flexible agent, which may itself call tools, research, compute, read the brain
   - after the agent: a small eval; on its result nudge the agent again or improve; add a summary or title
   - after the workflow: fixed steps such as MP3 conversion
   The factory needs the same: intake → existing-issue check and classification → grouping →
   queue placement and re-prioritisation, with dynamic agents inside each step.
6. **research-, audio-gateway and the otel tool become stations** too, each with AGENTS.md, skills,
   tools and code, plus structured workflow where it helps.
7. **Vercel:** the podcast's claim that the Vercel AI SDK has a workflow primitive is doubted; Mastra
   has one; unclear for OpenCode.
8. **Measurement from the start:** duration and cost per part; evals that show whether a change to a
   station, workflow, toolset, model or effort helped — better, cheaper, faster, fewer tokens, fewer
   tool calls.
9. **Self-improvement loop:** not every run needs analysis; triggers may be deterministic. Periodic,
   factory-coordinated investigations: which tools to change, which code gets written repeatedly,
   which mistakes recur, how to change a station's AGENTS.md, workflow, skills or tools. The platform
   concept is missing this and needs it before the factory, to judge the build itself.
10. **The same loop applies beyond stations:** per-project Claude Code setup, skills, basalt-ui, the
    telemetry stack and its alerts and metrics. Is model and effort configured well everywhere?
11. **Everything on the Mac mini** (always available): research-gateway already is, audio-gateway
    should be; Argo follows in the factory rebuild. Coding agents and Hermes use all tools locally,
    can read and run the code (Bun), and report issues into the channels — the base for the
    self-improvement loop.
12. **Next:** a spoken back-and-forth to close gaps and misreadings, then a new order, priorities and
    strategy — before anything is rebuilt.
