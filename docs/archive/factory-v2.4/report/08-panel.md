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
| **Mothers built and gamedayed in W4b** as persistent identities with on-demand sessions; leads are scoped mother wakes | owner-intent advocate, simplifier |
| **Product direction made structural** via derived product surfaces and an owner-trace rule | owner-intent advocate |
| **MacBook observer and actuator**, so the owner's most frequent action (nudging parked agents) is handled where those agents run | UX designer |
| **Freshness on every read model; one slot per entity on Home; pause as a runtime override; seven verbs with end states and budgets** | UX designer |
| **One-command onboarding; routing in one global file; pinned generation inputs; contract sha; CLI-owned waiting** | DX engineer |
| **Rewrite plan made runnable**: consumer inventory, dispatch kept until W4a's cutover, W1 and W2 split, measurable gates, a rollback per wave, honest calendar | migration lead |

## Tradeoffs the panel accepted

- **Serial warden spine** (≈ 26 working days instead of 17) rather than parallel waves in one repo.
- **On-demand mothers with persistent identity** — the owner's mother → lead → worker shape without an idle resident context.
- **One digest, three renderings** (Home, briefing, per-project changelog).
- **Biometric renewals** stay a physical-presence KPI (≤ 2 asks a month, coalesced), outside the decision SLO.
- **OpenCode lanes during the rewrite**, with a tested fallback to Claude Code on the IU endpoint.
- **A small independent watchdog** that rolls warden back to its last held release when the ledger's schema stamp allows it, and stops automation otherwise — a bad factory deploy cannot be trusted to roll itself back.

## What the panel could not settle

Escalation recall and known-error matching cannot be proven on today's data — six genuine
decisions in 959 events. They are standing SLOs, read on the fresh pre-registered sample when it
reaches its size — no wave's gate waits for them; three of the four business classes are guaranteed
by capability limits in the meantime (ADR-003, ADR-014).

## Cross-lab review

After revision 2 an independent cross-lab read — agent-gateway `review`, its angle reviewers and its
adversary on models from different labs, over the decision documents as one diff (job `30ffdffb`) —
returned *actionable*: 25 findings, 17 blocking, 5 improvements and 3 test gaps, each resolved in
`panel/review-resolutions.md`. None adds an owner gate or an open decision: D3 gains an expiry, D4 is
restated as binding by measurement instead of by timer, and D5's default takes only its reversible
half (section 10).

The two largest fixes:

- **Oversized waves split.** W4 becomes W4a (ready queue, claim leases, the `rd` cutover) and W4b
  (Witness actions, mothers and leads, the admission module, the MacBook actuator), each with its own
  rollback; W3 becomes W3a (intake) and W3b (conditions, correlation, known errors, the restart
  recipe). The calendar grows by three days on the spine.
- **The ledger's recovery point.** A nightly copy lost up to 24 h of operations and owner intents, so
  `ledger.db` is replicated continuously to the homelab bucket (recovery point in seconds), a restore
  enters adopt mode, and the legacy loop is a way back only until the new ledger's first external
  effect. W1b's gate loses a day of operations from a restored copy and asserts 0 re-executed effects
  (gameday row 20, `design/proof.md` §2).

The rest are narrower — gate exits measured instead of waited for, admission moved into warden,
level-triggered webhook recovery, a corrected claim about pushes with the mini dark, a
schema-stamped watchdog rollback — and are logged finding by finding. The three test gaps became
gameday rows 13, 20 and 21.
