# 5. Decision map

Each ADR with the evidence that decided it, how sure it is, and what would reverse it. Full text in
`adr/`; spike reports in `spikes/`.

| ADR | Decision | Evidence | Confidence | Reverse if |
|-|-|-|-|-|
| 001 | Tasks in the ledger with bd's verbs; the ledger is the only home of task state (PLAN.md checklists generated from it); no Attempt noun — a Task's attempts are its worker Agents | spike 1: `external:` inert 0/9, 305 s fixed lease vs 30 s, work repos touched; 65-line baseline passes the oracle | 80 % | a stable beads enforces cross-repo deps and ships two minors without schema migration; a second writer host |
| 002 | Durable execution = ledger + statecharts + effect registry, generation keys and lease epochs; no engine | spike 2: both options 0 duplicates over ~200 kills (against a key-honouring stub; W1 re-runs kills on real-shaped adapters); DBOS strands flows on redeploy (0/5), honours late answers; Mastra not run — TS-only, semantics unverifiable by the research | 75 % | ≥ 6 flow types with fan-out past ~150 lines; ledger moves to Postgres; 2 duplicate/lost-work incidents in a quarter |
| 003 | Deterministic correlation (windows by source kind, host fold only on host evidence, close by member); no single-shot decision model — judgment in the investigate worker on OpenCode/IU; escalation by typed class + capability limits; Keep not adopted | backtest held-out: F1 0.889 vs 0.744, owner touch 0.62 % (within one burst, detach reading); Keep-style 0.737 = singletons; decision model 92 % vs LLM triage, 60 % vs truth | 80 % grouping, low for escalation and known errors | the fresh blind cross-burst sample after W3 fails grouping; known-error match stays < 0.50 after the cross-source fix |
| 004 | CLI-first, one agent contract, one factory CLI (`warden manifest …`, `warden artifact …`), schema snapshots as the IR, routing rendered once; `--wait` default with a harness budget; MCP only for research-gateway and chrome-devtools | owner decision; spike 4: one policy sentence fixes the long-job spiral (2 calls, 38.9k tokens) — now built into the CLI | high | a non-shell client becomes primary for a gateway |
| 005 | Artifacts are ours: `warden artifact` module, threads in the ledger, versions in git, Argo view; plannotator interim | owner intent; spike 5: plannotator denies framing, `rv` prototype 14/14 | 70 % | the build exceeds 3 waves of work; the owner prefers plannotator's UI |
| 006 | One trace per item; derived id; `traceparent` + resource attribute | spike 6: 25-span trace joined; interactive panes ignore TRACEPARENT | high | Claude Code accepts inbound context in interactive sessions (simplify to one carrier) |
| 007 | On-demand mothers with persistent identity for 6 fleet projects, sessions elsewhere, one spawner with an admission queue, Witness with per-Task budgets and the `idle.parked` substate | classify rule; 50 nudges; 26 API-error stalls; Gas Town research | 70 % | mothers cost more tokens than the work they schedule (measured per week after W4) |
| 008 | herdr always, engine by class, forecast quota guard over every Max consumer, owner reserve from data, inverse rule onto lapsing Max | quota p90 96 %; moving agw onto Max = +22–29 %; owner share per cycle p90 57.6 %, Max lapsed p90 30.6 % (`kpi/forecast`) | high | Max headroom doubles (tier change, D2) |
| 009 | Argo split: factory API on the mini, SPA + life data on the VPS; `as_of` on every read model; web push from the VPS half; heartbeat carries an egress probe | data locality; 2 mini reboots since Aug 29; questions need live state | 75 % | the mini proves as available as the VPS for 90 days |
| 010 | One `project.yaml` + directory contract per repo, everything generated; integrations reconciled; effective autonomy computed from evidence producers; `slo` or `slo: none` per runtime | 9 disagreeing identity stores; 19 hand copies of the lanes | high | — |
| 011 | Fresh ledger + event log, one writer per entity, one-time import with an adoption pass; effectors record deliveries; one warden process | 65-column row; 437 owner pages invisible to the KPI | high | — |
| 012 | Verification ladder per action class, failing closed to propose-only; `factory-self` verified by N-1; rollback redeploys the last verified Deployment; squash merges; breaker per lineage with budgets, without pages | 0 of 52 auto-reverts (rebase merges); reopen 10.4 % | 75 % | a ladder rung lets a regression through twice in a quarter (tighten that rung) |
| 013 | Signals from primary sources (log alerts on structured severity, a git ref adapter, quota and usage adapters); Slack intake retires | 63.7 % via Slack, 16 min lag, 37/40 duplicates | high | — |
| 014 | Owner decides business only; default + expiry; SLO < 1 %; `needs_hands` and pause are never Decisions; product-surface changes without a brief become product-class | 4 of 20 interventions genuine; golden set 6 genuine | fixed by the brief | — |
| 015 | Argo writes intents, executed by reconcilers; each ends `applied`, `rejected` or `expired` within a per-verb budget | today's pull queue and hand-mirrored verbs | 75 % | intents prove too slow for steering (measure *requested → applied* latency in W6) |

## Spike results

| Spike | Question | Result |
|-|-|-|
| 1 | beads as the Task system of record | no — extend the ledger (`spikes/01-beads/REPORT.md`) |
| 2 | durable engine, killed mid-step | ledger + statecharts; DBOS equal on crashes, worse on redeploys (`spikes/02-durable/`) |
| 3 | correlation over the golden set vs Keep's model | proposed passes grouping (F1 0.889) and owner touch (0.62 %); fails escalation (underpowered: 1 genuine decision held out) and known-error match (0.479); Keep-style no better than singletons (`spikes/03-correlation/`, `evidence/golden/backtest.out.md`) |
| 4 | CLI vs MCP on three gateways | measured both; owner chose CLI-first; one policy sentence closes the CLI's only gap, now moved into the CLI as the `--wait` default (`spikes/04-cli-mcp/`) |
| 5 | artifact review | plannotator's semantics, our service (`spikes/05-artifact-review/`) |
| 6 | one trace end to end | joins for headless workers; attribute join for herdr panes (`spikes/06-telemetry/`) |
