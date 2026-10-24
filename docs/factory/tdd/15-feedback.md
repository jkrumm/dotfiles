# 15. Your feedback, and where it went

Numbering follows your Inbox reply (33 comments). Your words are shortened; the full text is in
`feedback/2026-10-23-owner-comments-raw.md`.

## The 33 comments

| # | You said | v2 |
|-|-|-|
| 1 | Some incidents only reach us through Slack — they can't call a tailnet webhook | Slack stays as a fallback intake adapter; outside sources get a signed Funnel `/ingest` path (§10) |
| 2 | Couldn't routine work run in OpenCode through agent-gateway instead of herdr? | Yes for judgment: investigation, planning, review run in agent-gateway's OpenCode server. herdr is only Claude Code writing code (§4, §5) |
| 3 | If we don't use bd, don't name the CLI after it — maybe `wave` | `factory`, with `wave`, `task`, `issue` underneath (§10, §14 override) |
| 4 | Why split Argo? Unify it on the mini | All on the mini (§10) |
| 5 | Cheap models for classification, dedup, orchestration; Max mothers implement | Exactly the engine split (§5); D1 is gone (§14) |
| 6 | prometheus-scripts and SE data-analysis may auto-merge; domain code careful; work repos not monitored | Per-path autonomy, IuRoot never monitored (§7) |
| 7 | Don't understand the holdout question | Not a question any more: mothers write them, you may edit (§12) |
| 8 | Retention: ok | Archive to the homelab, keep local copies (§6) |
| 9 | Fine to shut warden, Argo, Hermes down during the rewrite; drop warden's data | W0 switches them off; data archived, not imported (§2, §13) |
| 10 | Briefings in Argo? Only the morning one, TTS is nice | Morning only, an Argo page with optional audio (§9, §10) |
| 11 | My attention was never there: too many unnecessary alerts, and AI-slop writing | Principle 8 and the three-line lint (§2, §3); push only for decisions and the briefing |
| 12 | Not everything deploys automatically; deploys need make commands or agentic pipelines | `deploy.mode`: auto, make, agentic, none (§7) |
| 13 | Drop warden fully, no migration, fresh sunrise | New `factory` repo, nothing imported (§13) |
| 14 | dotfiles is a session project, not fleet | Done (§7) |
| 15 | Dedup needs cheap-model support, probabilities, learning from past dedups and investigations, merging during investigation | Three tiers + the label loop + investigator merge/split (§8) |
| 16 | Much heals itself — wait, or raise Kuma timeouts | Settle stage with grace windows; `heal` in `project.yaml` (§4, §7) |
| 17 | Not Renovate: upgrades need changelogs, migration guides, adopting new things, grouping | Agentic upgrade waves from a deterministic scan (§9) |
| 18 | CLAUDE.md is deprecated, only AGENTS.md | Measured and enforced on AGENTS.md (§3, §9) |
| 19 | Dogfooding also means improvements and missing pieces upstream to basalt-ui | The upstream job covers both (§9) |
| 20 | Be token-efficient; look at Swamp's deterministic pipeline pieces; Haiku, scripts, cheap OpenCode | Jobs as pipelines at zero tokens when green (§9, §11) |
| 21 | Drop the Beads name | Dropped (§4) |
| 22 | We pull from every tool, so Slack only for Hermes? Or ntfy for notifications? | Slack = Hermes + fallback adapter; push from Argo; ntfy as the fallback (§10, §14) |
| 23 | Too much goes to herdr; OpenCode with DeepSeek may fit research, warden, audio better | herdr = code only; everything else on agent-gateway's OpenCode or a gateway (§5) |
| 24 | Build a proper factory CLI, take what is good from bd/beads | `factory task` with the ready queue and blockers, our names (§4, §11) |
| 25 | Not sure about durable execution, especially regarding DBOS | DBOS on Postgres, gated by W1 (§6) |
| 26 | No "interim" — we can stop and rebuild clean | No `rv` shim; plannotator just keeps running until Argo's artifacts land (§10) |
| 27 | Don't push wave implementation to IU; let non-urgent work wait for the reset; maybe another subscription | No spill; P1–P3 wait; O1 for a third subscription (§5, §14) |
| 28 | The Argo split adds friction; the mini is always on | All on the mini (§10) |
| 29 | Maybe DBOS was used wrong | It was: default version on SQLite. Pinned + patched on Postgres (§6) |
| 30 | CLI over MCP, generated from the code like cyclopts | One router → CLI + API + docs (§10) |
| 31 | Use more of Umami, integrate it into the apps | Events and goals per app in W8; *Traffic* page (§9, §10) |
| 32 | "B. All on the mini" | Adopted |
| 33 | Cloudflare's security-audit skill | Quarterly quick audits on lapsing capacity (§9) |

## The global reply

| You said | v2 |
|-|-|
| A new repo `factory` with a holistic CLI instead of warden | §13 W0, §10 |
| Queue normal feature work through the same loop, cheap models judging, Claude Code in herdr building | §4 "three ways in" |
| Learn from Swamp, Sandcastle, Agent Orchestrator, oh-my-hermes, pstack, Gas Town | §11 |
| pele instead of Mermaid in dataviz and artifacts | adopted as the renderer for Mermaid syntax; this document's diagrams use it (§11) |
| Postgres instead of SQLite; Argo on local Postgres too; DBOS | §6 |
| This document as the source of truth, later a public guide on jkrumm.com | it moves to `factory/docs/` at W0; the guide is written from it once W9's numbers exist |
| A unified make structure, changeset-based, for CI and review | the make contract (§7) |

## The brief of 2026-10-24

| You asked | Done / where |
|-|-|
| Use both subscriptions balanced, keep caching | picker v1.2 + admission + cache affinity (§5) |
| Herdr and all development on subscriptions only, never IU; pause rather than spill | enforced in dotfiles (691ae1b) and agent-gateway (Phase 0, §13) |
| IU for gateways, OpenCode, Hermes | §5 |
| Drop tooling that breaks this | `ca`/`cap`/`cdf`/`cdp` gone; agent-gateway implement on Max |
| Clean up herdr tabs | six finished tabs closed; the two-accounts tabs close when their last workers finish |
| New report + a podcast of the changes | this document; the podcast is in Audiobookshelf |
| Spend less than the last run | research on IU (≈ $1), transcript digests on Haiku, panel on Sonnet; the v1 run used ≈ 45M tokens in its main session |
