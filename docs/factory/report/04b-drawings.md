# The owner's drawings, mapped

Two Excalidraw notes from 2026-10-21 (`brain/Areas/Engineering/Excalidraw/26-10-21-aligned-dev-setup` and
`…-argo-projects-wireframe`), read from their text elements. Each element is kept, changed or
dropped — with the evidence that decided it.

## Aligned dev setup

| Drawing says | Design | Verdict | Why |
|-|-|-|-|
| mother → lead → wave for the big projects; *sessions* are simple agents outside that flow | six fleet projects get mother → lead → workers; every other repo runs sessions (ADR-007) | **kept** | the rule picked six by evidence: basalt-ui, argo, weatherorb, shutterflow, dotfiles, warden — prometheus-scripts is session (92 commits, no waves) |
| the mother stays lean and coordinates progress across Beads | mothers own their project's ready queue and spend tokens only on judgment | **kept** | scheduling is code (no idle LLM patrols, Gas Town's cost failure) |
| the lead coordinates waves, issue resolution, rebases | leads sequence tasks, spawn workers, take merge-train returns | **kept** | — |
| waves implement, review, test, deploy, verify, ship | workers implement in hooks; the verification ladder and merge train ship (ADR-012) | **kept** | ship is gated by evidence, never by the owner |
| Beads holds the tasks | Tasks live in the ledger with bd's verbs and JSON names (ADR-001) | **changed** | spike 1: cross-repo deps inert in v1.3.1, a 5-minute fixed lease, work repos touched even in contributor mode; a 65-line SQLite baseline passed the same oracle |
| Warden receives issues per webhook or by pulling HyperDX and Slack | adapters per primary source; no Slack pulling (ADR-013) | **changed** | 63.7 % of signals came through Slack, 16 min late, with duplicates; 37 of 40 Kuma rows duplicated the webhook |
| Warden writes issues to Beads, where the mother triages them | warden's correlator triages deterministically (dedup, topology, window, known errors) and files Tasks; mothers judge and plan | **changed** | an LLM per signal costs tokens on noise, and model triage matched true grouping only 60–62 % (`kpi/decision_shadow`) |
| Warden and Beads share triage progress | one ledger: incidents and tasks linked, no sync between stores (ADR-011) | **kept, simplified** | two stores sharing progress is the two-way sync the model forbids |
| an Artifact holds the plan for many waves whose tasks then live in Beads | a plan is an Artifact; its projector turns checklists into Tasks (ADR-001, ADR-005) | **kept** | — |
| Hermes talks to mothers or spawns sessions (brain, investigation, planning) | Hermes is the conversational door: steer and submit verbs, sessions through `rd` (ADR-015, W11) | **kept** | and loses every code tool (capability limit with a test) |
| mother and lead run the strong model at medium effort; hard waves on the strongest, easy ones on the mid tier, OpenCode when quota is low; modelpick suggests, the lead decides | engine by class and a quota guard in the spawner (ADR-008); a lead may raise the model with a stated reason; model ids live only in `agw routing` | **changed** | Max's 7-day window sits at p90 96 %; moving agw's workload onto it would add ≈ 24 %, so the guard is code, not judgment |
| the cheap tier for exploration and lookups | Explore subagents and investigate workers on the cheap tier | **kept** | — |
| agent-, research-, image-gateway as supporting systems and CLIs | CLI-first on one agent contract; MCP only for research-gateway and chrome-devtools (ADR-004) | **kept, sharpened** | — |
| "maybe a decision model can help here again" | a decision model only for the correlator's ambiguous residue (ADR-003) | **changed** | it agreed 92 % with LLM triage but 60 % with the truth |
| Herdr | where code gets written; its event record feeds Witness | **kept** | — |
| GPUI (a native herdr GUI) | not part of the design; Argo's Fleet view and `herdr --remote` cover it | **dropped** | nothing on the owner's question list needs a second cockpit |
| Slack | out of intake (W1), out of briefings and changelogs (W11, W13); a human channel until Argo replaces it | **dropped** | — |

## Argo project wireframe

Every block survives; the Project page composes them by the project's capabilities
(`design/argo.md` §3): project name and links (herdr workspace, app, repo, brain note) · key stats ·
needs attention · tasks · todos (TickTick, read-only) · artifacts · health · changelog · cost · traffic
· git status · dependency state.
