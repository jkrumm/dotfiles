# A. Review log

Where each of your comments landed, version by version. Each table records what that version did
with your words; where they differ, the later table wins, and the v2.2 table at the end is current.
Numbering follows your Inbox replies; your words are shortened, the full texts are in `feedback/`.

## The 33 comments

| # | You said | Now |
|-|-|-|
| 1 | Some incidents only reach us through Slack | a Slack adapter for exactly those; everything else is polled (§10) |
| 2 | Could routine work run in OpenCode through agent-gateway instead of herdr? | yes for judgment: investigations are agent-gateway OpenCode sessions the factory resumes and steers; herdr is only for code (§4, §5) |
| 3 | Don't name the CLI after bd — maybe `wave` | `factory`, with `wave` underneath (§13) |
| 4 | Why split Argo? | all on the mini (§10) |
| 5 | Cheap models judge, Max mothers implement | the engine split (§5); v1's D1 is gone |
| 6 | Some IuRoot paths may auto-merge; not monitored | a rule in your sessions' AGENTS.md block; the factory stays out (§7) |
| 7 | Didn't understand the holdout question | not a question: acceptance checks are written from each plan by a separate session (§4) |
| 8 | Retention: ok | archive, keep local copies (§6) |
| 9 | Shut warden, Argo, Hermes down during the rewrite; drop warden's data | warden deleted at W1; Argo and Hermes may go dark during their own cutovers (W5, W6); no dual running (§12) |
| 10 | Morning briefing only, in Argo, TTS nice | on *Now*, with optional audio (§9, §10) |
| 11 | Too many unnecessary alerts, and AI-slop writing | sources repointed off Slack, three-line cards with a lint, push for two things only (§2, §10) |
| 12 | Not everything deploys automatically | `deploy.mode`: auto, make, agentic, none (§4, §7) |
| 13 | Drop warden fully, fresh sunrise | new repo, nothing imported (§12) |
| 14 | dotfiles is a session project | done (§7) |
| 15 | Dedup needs cheap-model help, probabilities, learning, merging during investigation | rules + decision-model probability + investigator merge/split + labels (§8) |
| 16 | Much heals itself — wait, raise Kuma timeouts | settle stage; Kuma retries raised when its adapter lands (§4, §10) |
| 17 | Not Renovate; upgrades need changelogs and real adoption | the deps job opens planned upgrade waves (§9) |
| 18 | Only AGENTS.md | measured on AGENTS.md (§3, §9) |
| 19 | Dogfooding includes missing pieces upstream | the basalt-ui upstream job covers both (§9) |
| 20 | Be token-efficient, take Swamp's deterministic pieces | jobs are code; a cheap model writes up findings; a clean run costs nothing (§9) |
| 21 | Drop the Beads name | dropped |
| 22 | Slack only for Hermes? ntfy? | Slack = Hermes, the adapter and the dead-man alert; push from Argo (§10, §13) |
| 23 | Too much goes to herdr | herdr = code only (§5) |
| 24 | A proper factory CLI, take the good parts of bd | ready queue and dependencies, our names (§4, appendix B) |
| 25 | Not sure about durable execution and DBOS | DBOS on Postgres with short workflows (§6) |
| 26 | No "interim" | no shim; plannotator stays the review surface until *Artifacts* lands in W5 |
| 27 | Don't push waves to IU; let non-urgent work wait | no spill; normal and upkeep classes wait (§5) |
| 28 | The split adds friction; the mini is always on | all on the mini |
| 29 | Maybe DBOS was used wrong | it was; adopted, on Node (§6) |
| 30 | CLI over MCP, generated from the code | one router → CLI, API, docs (§10) |
| 31 | Use more of Umami | traffic job once events and goals are wired in (§9) |
| 32 | "B. All on the mini" | adopted |
| 33 | Cloudflare's security-audit skill | audits triggered by the amount of change (§9) |

## The global reply

| You said | Now |
|-|-|
| A new repo `factory`, a holistic CLI | §12 W1, §10 |
| Feature work through the same loop | §4, three ways in |
| Learn from Swamp, Sandcastle, Agent Orchestrator, oh-my-hermes, pstack | appendix B |
| pele instead of Mermaid | Mermaid syntax rendered by pele — this document, then the dataviz skill and Argo (§10) |
| Postgres; Argo on local Postgres; DBOS | §6 |
| This document as source of truth and a later public guide | moves to `factory/docs/` in W1; the guide is written once W6's numbers exist |
| One make structure, changeset-based | §7 |

## The brief of 2026-10-24

| You asked | Done |
|-|-|
| Both subscriptions balanced, caching kept | picker classes and cache rules (§5) |
| Herdr and all development on subscriptions only, never IU API tokens | enforced in dotfiles and agent-gateway (Phase 0) |
| Drop tooling that breaks this | IU launchers removed; agent-gateway implement on Max |
| Clean up herdr tabs | six finished tabs closed (SourceRoot 1, 2, factory; dotfiles 1–3); the two-accounts workers were closed by their orchestrator, whose final tab stays open for you |
| New report and a podcast | this document; the episode "Factory v2 — fünf Entscheidungen, offene Lücken" (19:50, Audiobookshelf → Podcasts) |
| Spend less than the last run | five research jobs on IU API ($1.25), digests on Haiku, panel and implementer on Sonnet |

## Your reply to the podcast (2026-10-24)

Verbatim in `feedback/2026-10-24-owner-podcast-reply.md`.

| You said | Now |
|-|-|
| The DBOS blocker is unclear — use Node if that is it | DBOS adopted on Node with short workflows; the pitfalls the review found vanish with that rule (§6) |
| IU API tokens are avoided too aggressively; €500 is fine, just not for implementing | cheap models do dedup, root causes, linking, JSON, wave planning, naming, every message and the briefing (§5) |
| Watch that both subscriptions fill up balanced, switching rarely but smartly | balance goal and measures, weekly tuning from the picker's own data (§5) |
| Too many odd worries; classify, order, then let Claude Code work | §4 centres on what a session gets; edge-case handling moved to appendix D |
| Slack barely needed; briefing structured in Argo | Slack keeps Hermes' chat and Slack-only sources; briefing on *Now* (§10) |
| Why less on the phone? | nothing is less: push notifies of two things, Argo shows everything on the phone (§2, §10) |
| Hermes needs restructuring | W6: chat front over the factory API, crons become jobs (§10) |
| We can build on `me` | W1 starts on `me` on Mon 26 Oct (§12) |
| The report could be more precise | v2.1 is shorter; detail moved to appendices |

## Your comments on v2.1 (2026-10-25)

Verbatim in `feedback/2026-10-25-owner-comments-raw.md`, with the chat message of the same day.

| # | You said | Now |
|-|-|-|
| 1 | Claude Code is the smart actor: root cause, plan, implement, test, verify, ship, verify again, report back | the lead owns the Issue end to end; the factory runs the lifecycle around it (§1, §4) |
| 2 | Not sure what DBOS would do; maybe I pushed too hard | answered from engrams' source: for a lifecycle of hours or days, not much; an Issue machine with an inbox instead; your decision (§6, §13) |
| 3 | Can a decision model dedup well, with what context, or a DeepSeek OpenCode flow? | off until a W4 bake-off of both with the same context pack; merge precision ≥ 0.95 or it stays off (§8) |
| 4 | Rollback rarely works in practice; fix forward | the lead fixes forward; a revert is its call; no automatic rollback (§4) |
| 5 | Queue it, then let Claude Code cook in herdr; the factory is the lifecycle around the item | §4 as a whole; you follow an Issue in herdr, Argo or Hermes (§2) |
| 6 | IuRoot: no triage; maybe wave lifecycles later; keep it out for now | out of W1–W6; lifecycle tracking is a later option (§7) |
| 7, 8 | Principles 1 and 2 contradicted your earlier answer | rewritten: the factory sorts and words, leads reason (§3) |
| 9 | Make targets, review, merge, deploy: coordinated by Max in herdr | all of it is the lead's, with those tools (§4) |
| 10 | Root cause and fix recipe afterwards feed docs, intake, dedup, known fixes | the learning loop reads the lead's verified report (§8) |
| 11 | Investigation by a cheap model is too hard; hand it to Claude Code | no cheap-model investigation or plan; classification only routes (§4) |
| 12 | Also my GitHub issues, or issues where I tag the factory | requests from your issues and `/factory` comments, your user only (§4, §10) |
| 13 | "What every session gets" was outdated | replaced by the lead's job, done-means-evidence and the brief (§4) |
| 14 | Verify, ship, roll back: all Claude Code, too hard to coordinate with dumb models | same as 9 (§4) |
| 15 | Root cause may be needed for dedup | two tiers: symptom at intake, cause in the lead (§8) |
| 16 | DBOS runs on Bun | confirmed: officially Node-only, but Cortex runs it on Bun 1.4.3 in production; the runtime decides nothing (§6) |
| 17 | Not sure we use DBOS, or learn a lot from it | learn a lot, use little: engrams' patterns are in §6, its engine is not (appendix B) |
| 18 | TickTick: things I as a human need to do | and the factory adds items there when an Issue needs your hand (§7) |
| 19 | The decision model needs testing | the W4 bake-off (§8) |
| 20 | Continuous learning sounds good; tricky | four learning measures on the scorecard; a stalled loop becomes an Issue (§8, §9) |
| 21 | More from Swamp; more deterministic paths, agentic where needed | principle 7: fixes verified twice become runbooks or job checks (§3, §8, §9) |
| 22 | Conventional commits make a poor changelog | leads write three-line summaries; a cheap model compiles them for the brain and Argo (§9) |
| 23 | Monitor subscription picking, dedup and learning, the pipeline | the scorecard job (§9) |
| 24 | A "daddy orchestrator" above the mothers that watches tokens, limits, routing, `me`'s 5-hour window | the steward (§5); the build orchestrator plays it during the rewrite (§12) |
| 25 | We start after my final review, not on a fixed date | start on your sign-off (§12) |

## Your voice note on v2.2 (2026-10-25, evening)

Summary in `feedback/2026-10-25-owner-voice-note-v22.md`. This table supersedes rows 2, 3, 17, 19 and
24 above.

| You said | Now (v2.3) |
|-|-|
| Mother, lead and wave agents feel like three layers; I see two | two: an orchestrator over the leads. The mothers and the steward are both the orchestrator now; a lead's subagents and worktrees are its own tools, not a layer. Warp's factories make the same split, one level deep (§4) |
| The orchestrator should be compacted or restarted at meaningful boundaries | it is never long-lived: one fresh session per event, starting from the factory's state and the initiative's plan (§4, §5) |
| Is herdr right, or `claude -p` or the Agent SDK in a more managed setup? | Postgres owns the work and the session id is the handle; herdr only hosts interactive sessions. `claude -p` costs ≈ 1.8× the 5-hour window per token (claude-code#97074) and cannot be steered mid-turn; the SDK's subscription use is contested. Claude Code's own background sessions, with herdr only the view, get a W3 spike (§6) |
| I want to look back into old chats | transcripts archived at close, since Claude Code deletes its own after 30 days; `factory issue resume` reopens any attempt as a fork (§6) |
| Plain sessions for simpler repos must stay possible | repos without a `project.yaml` stay outside the factory; Hermes starts a plain session there (§4, §7) |
| DBOS: I don't care | decided: no DBOS (§6, §13) |
| The dedup part of the podcast was confusing | one judge, no contest: shadow from W2, trusted only at ≥ 0.95 merge precision over 30 cases; leads catch duplicates by cause regardless (§8) |
| Dig into Warp's factories; learn the language and the field; solo versus company | `research/2026-10-25-warp-factories.md`; appendix E; Warp's scorers, self-improvement trigger, autonomy KPIs and manifest schema adopted (§7, §9) |
| I want to become an expert and publish a guide | the field guide in the brain, `wiki/engineering/software-factories.md`: the twelve decisions every factory makes, converged patterns, metrics, references, vocabulary with origins |
