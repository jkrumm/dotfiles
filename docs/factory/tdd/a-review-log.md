# A. Review log

Where each of your comments on v1 landed. Numbering follows your Inbox reply; your words are
shortened, the full text is in `feedback/2026-10-23-owner-comments-raw.md`.

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
