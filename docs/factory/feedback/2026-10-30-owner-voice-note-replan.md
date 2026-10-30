# Owner voice note: the re-plan after agent-workflows (2026-10-30)

Transcribed voice message at the start of the factory re-plan, after agent-workflows closed Wave 11
(`agent-workflows/docs/factory-input.md`). Summary of what it asked, in the order it came:

1. **Review agent-workflows** and where it left off. It is wired to Hermes and to the new Mac/iOS
   interface (iris).
2. **The Apple app** (SwiftUI, macOS and iOS) is the personal front: better speech-to-text and
   interaction with Hermes on the iPhone; live view of running waves and herdr state; transcribe and
   send to Hermes; Claude subscription status with rich visualisations.
3. **Argo is for deeper insight and data analysis.** Clear separation of concerns: the agentic Hermes
   integration leaves Argo (not urgent; a side task may do it).
4. **The whole Claude Code setup must adhere to the new platform:** no old wiring, skills and
   mentions up to date.
5. **Argo moves to the mini**, database included. Rethink usage tracking: the old data model may not
   fit what was learned in the rewrite; write to a local database and move to Argo, or write into
   Argo directly? What changes now that everything is local? Architecture of Argo and its server
   once local; telemetry wired automatically.
6. **Infrastructure reporting in Argo:** mini, homelab, VPS. Connect to Beszel, or drop it and write
   our own.
7. **agent-workflows insight in Argo:** behaviour, performance telemetry, tool use, cost, bottlenecks.
8. **Not all of it gets built now;** the ask is an optimal architecture for the mini-hosted Argo.
9. **The factory:** monitoring tools ingest issues; the owner plans features; waves, their overview,
   ordering and centralised implementation. Recent waves were run in different ways each time and
   not perfectly: model and effort choices, parallelism, pausing when the Max subscriptions are
   exhausted and continuing when limits reopen, agents stuck on permission prompts. The CLIs that
   manage agents in herdr and the wave implementations need fine-tuning into a stable, mature system
   with clear communication patterns and rules.
10. **herdr spaces:** a space per project exists, yet new spaces keep being opened. Fine when it is a
    separate plan and worktree (mostly work projects run in parallel); for personal projects it is
    overwhelming.
11. **The factory build:** data model, flows, how and when the API is used, which agent-workflows
    tools exist and how they are wired most stably; end-to-end telemetry. Own UI for the factory, or
    inside Argo? Argo needs improving: it lived on other infrastructure and bridged everything over
    the network; locally it can use the code of usage-tracker, Hermes and agent-workflows directly.
12. **email-gateway** holds the calendar and mail authentication; those go through it.
13. **Finances** runs on the MacBook today; move it to the mini (1Password still needed to decrypt)
    and perhaps its interface into Argo.
14. **Factory quality bar:** stable, mature, good wiring, deduplication and flows; token and cost
    efficient; right model, effort and usage configuration; mostly deterministic babysitting of wave
    implementations; reordering and managing the queue; interaction with Claude Code throughout.
15. **Effect (Effect-TS):** evaluate it for the factory; many use it to handle side effects, errors
    and complex flows more robustly. Not in the plan yet.
16. **Next:** investigate everything, then challenge the current setups together and decide how to
    move on.
