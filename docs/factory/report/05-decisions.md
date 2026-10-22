# 5. Decision map

Each ADR with the evidence that decided it, how sure it is, and what would reverse it. Full text in
`adr/`; spike reports in `spikes/`.

| ADR | Decision | Evidence | Confidence | Reverse if |
|-|-|-|-|-|
| 001 | Tasks in the ledger with bd's verbs | spike 1: `external:` inert 0/9, 305 s fixed lease vs 30 s, work repos touched; 65-line baseline passes the oracle | 80 % | a stable beads enforces cross-repo deps and ships two minors without schema migration; a second writer host |
| 002 | Durable execution = ledger + statecharts, no engine | spike 2: both options 0 duplicates over ~200 kills; DBOS strands flows on redeploy (0/5), honours late answers | 75 % | ≥ 6 flow types with fan-out past ~150 lines; ledger moves to Postgres; 2 duplicate/lost-work incidents in a quarter |
| 003 | Correlation: deterministic grouping, decision model for the residue | ⟨spike 3 backtest⟩; `kpi/decision_shadow`: model 60.1 % vs truth, LLM triage 61.8 % | ⟨⟩ | ⟨⟩ |
| 004 | CLI-first, one agent contract, generated routing; MCP only for research-gateway and chrome-devtools | owner decision; spike 4: one policy sentence fixes the long-job spiral (2 calls, 38.9k tokens) | high | a non-shell client becomes primary for a gateway |
| 005 | Artifacts are ours: `rv` service + Argo view; plannotator interim | owner intent; spike 5: plannotator denies framing, `rv` prototype 14/14 | 70 % | the build exceeds 3 waves of work; the owner prefers plannotator's UI |
| 006 | One trace per item; derived id; `traceparent` + resource attribute | spike 6: 25-span trace joined; interactive panes ignore TRACEPARENT | high | Claude Code accepts inbound context in interactive sessions (simplify to one carrier) |
| 007 | Mothers for 6 fleet projects, sessions elsewhere, one spawner, Witness | classify rule; 50 nudges; 26 API-error stalls; Gas Town research | 70 % | mothers cost more tokens than the work they schedule (measured per week after W4) |
| 008 | herdr always, engine by class, quota guard | quota p90 96 %; moving agw onto Max = +24 % | high | Max headroom doubles (tier change, D2) |
| 009 | Argo split: factory API on the mini, SPA + life data on the VPS | data locality; 2 mini reboots since Aug 29; questions need live state | 75 % | the mini proves as available as the VPS for 90 days |
| 010 | One `project.yaml` + directory contract per repo, everything generated | 9 disagreeing identity stores; 19 hand copies of the lanes | high | — |
| 011 | Fresh ledger + event log, one writer per entity, one-time import | 65-column row; 437 owner pages invisible to the KPI | high | — |
| 012 | Verification ladder per action class; squash merges; breaker without pages | 0 of 52 auto-reverts (rebase merges); reopen 10.4 % | 75 % | a ladder rung lets a regression through twice in a quarter (tighten that rung) |
| 013 | Signals from primary sources; Slack intake retires | 63.7 % via Slack, 16 min lag, 37/40 duplicates | high | — |
| 014 | Owner decides business only; default + expiry; SLO < 1 % | 4 of 20 interventions genuine; golden set 6 genuine | fixed by the brief | — |
| 015 | Argo writes intents, executed by reconcilers | today's pull queue and hand-mirrored verbs | 75 % | intents prove too slow for steering (measure *requested → applied* latency in W6) |

## Spike results

| Spike | Question | Result |
|-|-|-|
| 1 | beads as the Task system of record | no — extend the ledger (`spikes/01-beads/REPORT.md`) |
| 2 | durable engine, killed mid-step | ledger + statecharts; DBOS equal on crashes, worse on redeploys (`spikes/02-durable/`) |
| 3 | correlation over the golden set vs Keep's model | ⟨`spikes/03-correlation/`⟩ |
| 4 | CLI vs MCP on three gateways | measured both; owner chose CLI-first; one policy sentence closes the CLI's only gap (`spikes/04-cli-mcp/`) |
| 5 | artifact review | plannotator's semantics, our service (`spikes/05-artifact-review/`) |
| 6 | one trace end to end | joins for headless workers; attribute join for herdr panes (`spikes/06-telemetry/`) |
