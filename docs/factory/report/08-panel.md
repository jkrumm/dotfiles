# 8. Panel — every objection and its resolution

Eleven experts — SRE, correlation scientist, durable-systems engineer, autonomy and verification
engineer, data architect, platform/DX engineer, operator-UX designer, cost and capacity planner,
simplifier, migration lead, and an **owner-intent advocate** holding the owner's verbatim prompt —
reviewed the full draft twice, each with the evidence and a mandate to return objections with a
severity and the test that would settle them. Every objection is resolved by a changed design, an
explicit tradeoff or an open decision; the per-objection logs are `panel/pass1-resolutions.md` and
`panel/pass2-resolutions.md`, the raw objections `panel/pass1/` and `panel/pass2/`.

| Pass | Objections | Blockers | Majors | Minors | Outcome |
|-|-|-|-|-|-|
| 1 | 85 | 18 | 57 | 10 | 82 changed designs, 3 tradeoffs, 0 new open decisions |
| 2 | 76 new + 85 re-checked | 12 | 53 | 11 | pass-1 items: 21 resolved, 63 partially (carry-through gaps), 1 not — all fixed in revision 2; new items: changed designs and 3 tradeoffs, 0 new open decisions |

## What the panel changed

| Change | Raised by |
|-|-|
| **Attempt dropped — eleven nouns**; a Task's attempts are its worker Agents | simplifier |
| **Effect registry, generation keys, epochs, deliveries**: no side effect without a declared idempotency strategy; stale lease holders are fenced, including their git pushes | durable-systems engineer |
| **Evidence fails closed**: a rung without a verified producer drops to propose-only; a producer counts only after the verifier has seen it fail | verification engineer |
| **`factory-self`**: changes to the factory's own gate are verified by the previous release; autonomy can only be lowered by a Change | verification engineer |
| **Rollback is a Deployment operation** to the last *held* Deployment, with bisect attribution | verification engineer |
| **Lineage breaker and budgets** (attempts, engine-tagged tokens — never wall clock), closed only by a held fix | verification, cost |
| **Correlation narrowed to what the data can see**: short windows for stateless sources, host fold only on host evidence, close-by-member and split, reversible merge; v1 numbers no longer credited to v2 rules | correlation scientist |
| **Fresh, blind, correlator-independent acceptance sample**, pre-registered before any label exists | correlation scientist, migration lead |
| **Capacity forecast**: owner-started work already fills Max (120 % of a weekly window per week), so factory judgment runs on IU unless capacity would lapse; D1 and D2 restated with numbers | cost planner |
| **`needs_hands`, `infra.egress`, log shipping, two independent observations before a restart** | SRE |
| **Mothers built and gamedayed in W4** as persistent identities with on-demand sessions; leads are scoped mother wakes | owner-intent advocate, simplifier |
| **Product direction made structural** via derived product surfaces and an owner-trace rule | owner-intent advocate |
| **MacBook observer and actuator**, so the owner's most frequent action (nudging parked agents) is handled where those agents run | UX designer |
| **Freshness on every read model; one slot per entity on Home; pause as a runtime override; seven verbs with end states and budgets** | UX designer |
| **One-command onboarding; routing in one global file; pinned generation inputs; contract sha; CLI-owned waiting** | DX engineer |
| **Rewrite plan made runnable**: consumer inventory, dispatch kept until W4, W1 and W2 split, measurable gates, a rollback per wave, honest calendar | migration lead |

## Tradeoffs the panel accepted

- **Serial warden spine** (≈ 23 working days instead of 17) rather than parallel waves in one repo.
- **On-demand mothers with persistent identity** — the owner's mother → lead → worker shape without an idle resident context.
- **One digest, three renderings** (Home, briefing, per-project changelog).
- **Biometric renewals** stay a physical-presence KPI (≤ 2 asks a month, coalesced), outside the decision SLO.
- **OpenCode lanes during the rewrite**, with a tested fallback to Claude Code on the IU endpoint.
- **A small independent watchdog** that rolls warden back to its last held release — a bad factory deploy cannot be trusted to roll itself back.

## What the panel could not settle

Escalation recall and known-error matching cannot be proven on today's data — six genuine
decisions in 959 events. They are standing SLOs, measured on the fresh pre-registered sample; three
of the four business classes are guaranteed by capability limits in the meantime (ADR-003, ADR-014).
