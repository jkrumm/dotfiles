# Cross-lab review — resolutions

agent-gateway `review` (angles on IU Haiku, adversary on IU GPT) over the decision documents as one
diff (job `30ffdffb`): outcome *actionable* — 17 blocking findings, 5 improvements, 3 test gaps.
Every finding is resolved below; none adds an owner gate or an open decision.

## Blocking

| # | Finding | Resolution |
|-|-|-|
| R1 | D3 has no expiry, against ADR-014 rule 2 | D3's default A (read, investigate, open PRs) is already the state; expiry 2026-12-31, after which A stays and the card is re-pushed once. |
| R2 | W4 is too large for its one rollback | **Split W4**: W4a — ready queue, claim leases, `rd` cutover writing Agent records (rollback: symlink flip; PLAN.md keeps task ids, the old `rd` ignores ledger tasks); W4b — Witness actions, mothers and leads, the admission module, the MacBook actuator (rollback: Witness to observe-only by one config flag). |
| R3 | W10's gate needs ≥ 30 decision candidates that history cannot supply | The escalation and known-error readings leave W10's gate; they are standing SLOs read when the pre-registered fresh sample reaches its size. W10's gate: one item per improve class shipped end to end, gameday rows 3, 4, 14, 16. |
| R4 | W11's 7-day soak is a waiting period | Measured exit: replay the last 30 days of owner requests to Hermes through the new Hermes — zero file, code or commit tool calls — plus a capability test (a code-tool call is refused). |
| R5 | W3's glance closure waits on a ≥ 24 h hold | W3 gate (c) measures recipe executed, health green and the condition resolved within MTTR; the incident's own closure after its hold is not part of the gate. |
| R6 | Admission inside `rd` reads `ledger.db` directly | Admission lives in warden (`warden admit`, the factory API); `rd` stays a thin spawner that calls it and fails closed; nothing outside warden reads the ledger for policy. |
| R7 | Holdout binding after 7 days is a clock on the ship path | A holdout set binds on measurement: it passes against the current production release, and each scenario has been seen to fail against a seeded fault (the verified-producer rule). The owner may edit at any time; there is no timer. D4 restated. |
| R8 | The import's file swap contradicts "rows after the stop stay" | Order fixed: stop the old loop → import into a new file → swap → only then does the new ledger go live; no rows exist in it before the swap. |
| R9, R15 | The legacy rollback would re-execute effects the new ledger already took | W1a's legacy rollback is valid only until the new ledger performs its first external effect; that moment is recorded. After it, rollback is roll-forward (fix in the new ledger, its adopt mode) — never the legacy loop. |
| R10, R14 | A nightly copy loses up to 24 h of operations and owner intents | Continuous WAL replication of `ledger.db` to the homelab bucket (Litestream-class; `research/2026-10-22-durable-await-sqlite.md` §1; version pinned after `/research` in W1b) — recovery point in seconds. Restore enters adopt mode; test gap T1 is W1b's gate. |
| R11 | Adoption applies stale owner intents | An imported intent applies only if its target's observed state still matches the state when it was issued; otherwise it ends `expired(stale)` and shows once in *Since you left*. |
| R12 | Webhook intake is lost across a warden restart | Level-triggered recovery: webhooks only schedule reconciles; every resync reads monitor state from the source (Kuma's status API or metrics, HyperDX alert state), so a missed webhook delays detection by at most one resync interval and never loses the condition. |
| R13 | "Pushes work with the mini dark" is not supported | Corrected: with the mini dark only the dead-man push is sent (it originates on the VPS); decision and heads-up pushes originate on the mini, and their expiries are extended by the downtime (dur-7). Test gap T2 asserts exactly that. |
| R16 | The watchdog's rollback cannot read a migrated ledger | `factory-self` releases use expand/contract migrations only; the ledger carries a schema stamp; the watchdog restores the last held release only if it supports the current stamp, otherwise it stops automation and sends a heads-up. Test gap T3 is W5's gameday. |
| R17 | `correlation` NOT NULL has no root for a fresh Signal | A Signal is its own root until correlated (`correlation` = the signal id); attaching it emits `incident.member_added`, which records the merge of roots. Items count only Incident and Task roots. |

## Improvements and test gaps

| # | Finding | Resolution |
|-|-|-|
| I1 | Wave sizes are implausible; W3 in 3 days | **Split W3**: W3a intake (adapters, Signals, log shipping, the read slice), W3b conditions, correlation, known errors and the restart recipe; the calendar grows by three days on the spine. |
| I2 | No monitoring between W1a and W6 | W1a keeps the dev-host heartbeat and adds a new-warden liveness component to it from day 1. |
| I3 | The deploy lock has no staleness rule | The lock records holder pid, boot id and start time; it is stale when the holder is dead or the boot id differs. |
| I4 | A push never accepted stays pending silently | Permanent push failures open `push.channel_dead` (a factory-self condition); a decision's expiry runs from its creation, and acceptance only stops re-pushes. |
| I5 | D5's default contradicts the irreversible rule | D5's default takes only the reversible half (archive); local deletion is never defaulted — re-pushed once and held. |
| T1 | Restore without re-execution | W1b gate: lose a day of operations from a restored copy, assert 0 re-executed effects. |
| T2 | Mini dark with a Decision open | Gameday row 13 asserts the dead-man push and the extended expiry. |
| T3 | A bad migrating release | W5 gameday: a deliberately migrating bad release; assert the watchdog's rollback or its safe stop. |
