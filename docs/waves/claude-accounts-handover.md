# Claude accounts — orchestrator handover (2026-10-24 ~21:00)

Spec: `docs/claude-accounts.md` (read fully). You are the **final orchestrator** for this project:
land the last open PRs, verify the whole concept end to end on the mini AND the MacBook, monitor it,
and close the project out. Workers are `rd fan` tabs; review with `mcp__agent-gateway__review`
(submit → `job_wait`), fixes via `rd say`, land with `rd merge`, deploy, verify. One tab per open
change at most — the owner asked to keep the tab count small; `rd close` / `rd fan --clean` as soon
as something lands.

## Accounts

| id | plan | dir | notes |
|-|-|-|-|
| `iu` | IU-paid Max 20x | `~/.claude` (CLAUDE_CONFIG_DIR **unset**) | weekly ~89 %, resets Wed 2026-10-28 17:00 |
| `me` | personal Max 5x | `~/.claude-me` (keychain `Claude Code-credentials-7253dcbc`) | mini only so far; MacBook has no `me` login |

## Owner rules (non-negotiable)

- Account chosen **at spawn, never mid-session**; `--resume` stays on the session's account (PR #31).
- **Development runs on the Max subscriptions only** (global CLAUDE.md, #30): `ca`/`cap`/`cdf`/`cdp`
  are gone, `rd` pauses instead of spilling to IU. IU tokens are for gateways/OpenCode/Hermes only.
- Split by lane, route automatically. Picker rule v1.1: expiring capacity → **pace** (an over-pace
  home yields to an under-pace other) → **session balance** (emptier fresh 5h window) → home → other.
  Today interactive/headless/review → `me` (pace) because iu is far over pace.

## Live (merged + deployed + verified)

| repo | what |
|-|-|
| dotfiles | registry `iu`/`me`, `claude-account` picker (pace + session balance), `c`/`cs`/`cf` pick, `rd wave/fan` pick (no IU spill), per-account MCP registration, per-account claude-auth fallback, `make claude-accounts-verify` (in doctor) / `-stamp`, `scripts/claude-accounts-e2e.sh`, keepalive LaunchAgent (06:30 `refresh --all`), heartbeat quota line both accounts, statusline POST per account |
| agent-gateway | workers pick per spawn (`agent-gateway:<tool>`), wall → other account → iu, session pins, `session_env.account`, sessions-log `account` (b8f2d0c); `/api/usage` `{data, accounts}` from the cache (SWR), overview header + account column, `quota` in the overview pushed to Argo |
| usage-tracker | `account` column (iu/me), `quota_sample` + `account_pick` tables synced to Argo, agent-gateway-sessions rows attributed from the line `account`, NULL→iu repair one-off (user_version 2), conditional sync mark |
| argo | `account` on usage_record (COALESCE upsert, normalised ingest), account filter/groupBy, quota history (`/usage/quota`, `/usage/account-picks/summary`) + "Claude accounts" section |
| tinycast-extensions | both accounts from Argo `GET /agents/overview` → `latest.snapshot.quota` (agent-gateway stays loopback-only), local fallback; deployed on the MacBook 77866aa |

E2E proof 2026-10-24 ~17:30–20:45Z: verifier PASS on every path (launchers, real Haiku runs iu/me,
subagent inherits, rd wave/fan → me, agent-gateway otel worker → me incl. its session row, 0 Max rows
without account since rollout, displays). `claude-accounts-e2e.sh` all pass after #12.

## Open — land these first

| repo | PR | tab | state |
|-|-|-|-|
| argo | #202 feat/usage-payer | `argo-usage-payer` | payer split `iu-sub`/`me-sub`/`iu-api`/`me-api`(=billing openrouter), colours me blue / iu gold-orange, UTC buckets, **migration 0024 changes prod data** (deletes 24,803 NULL-machine duplicate rows = $3,081 double count; sets account=iu on 7,165 old Max rows) with every touched row archived + restore SQL in docs/usage-reconciliation.md. Deep review job `bd87b289-5c51-46d2-9d61-1f5fe76a7e5c` (job_wait it). Its 48 h reconciliation: everything matches except 21 iu-api rows the VPS gateways post directly (expected). After deploy: screenshot the usage page (`make design-shot` in argo, or `@verifier`) — not yet seen rendered. Note: the tab showed an autocompact prompt; dismiss with Esc before `rd say`. |
| dotfiles | #31 feat/resume-pins-account | `dotfiles-claude-accounts-pace` (wR:p1V) | `c --resume` pins to the session's account via `claude-account session <id>`; owner-driven, mid-review in that tab — let it finish, then verify and close the tab |

## Final verification checklist (the owner's ask: "fully verify it all, then round it up")

1. `make claude-accounts-verify` 0 FAIL (the one FAIL today is account-less session_env lines; newest is a 17:29:36Z probe via a stale MCP child, ages out 2026-10-25 17:30Z) → `make claude-accounts-stamp`.
2. `scripts/claude-accounts-e2e.sh --subagent` all pass.
3. Picks behave: `tail ~/.local/share/claude-accounts/picks.jsonl` — reasons pace/session/home plausible against `claude-account usage`.
4. No running session ever switched account: for every session id in the last 24 h `session_env`, one account only (a resumed session keeps it — #31).
5. Attribution: `sqlite3 ~/.local/share/usage-tracker/usage.db` — no billing=max row with NULL account; per machine × account counts plausible (MacBook rows appear as `MacBook Pro (M2 Max)`).
6. Argo: payer split renders, reconciliation re-run after 0024 (docs/usage-reconciliation.md), quota history chart shows both accounts.
7. Displays: `/api/usage`, overview header, Tinycast (MacBook menu bar shows `iu x/y · me x/y`), heartbeat quota line.
8. MacBook (below) done and verified.
9. Stale agent-gateway MCP children: sessions started before agent-gateway #32 pick nothing (run on iu) until restarted — `make deploy RESTART_MCP=1` in agent-gateway when no long session depends on its MCP, or let them age out.
10. Monitor for a day: picks.jsonl distribution, `quota_sample` series in Argo, heartbeat. Then write the closing note (docs/claude-accounts.md status → W2 done; W3 = tune from picks after 2 weeks; 20x upgrade decision for `me` if its weekly stays > 80 %).

## MacBook

The MacBook (ssh `iumac`, user `johannes.krumm`) is behind: dotfiles at 254a23d with an uncommitted
`docs/macbook.md` edit, no `claude-account`, no `~/.claude-me`. Its Claude Code usage reaches the mini's
usage-tracker through the rsync mirror (`~/.claude/projects` + `~/.claude/logs`, src/remote.ts), today
all `iu`. The owner starts a MacBook agent with `~/claude-accounts-macbook-handover.md` (copied there;
source `~/.local/share/claude-accounts-final/macbook-handover.md` on the mini). Verify its result from
the mini: MacBook rows with account `me` appear after a MacBook `me` session + the next ingest.

## Known gaps / decisions

- agent-gateway pre-existing test failure: `tests/dispatch-worktree.test.ts:1121` fails because the
  CommandLineTools system gitconfig sets `credential.helper osxkeychain` and the worker git overlay does
  not set `GIT_CONFIG_NOSYSTEM=1` (worker git can reach the keychain helper). Merges use
  `rd merge agent-gateway --check 'GIT_CONFIG_NOSYSTEM=1 make check' …`. Owner decision; not fixed.
- dotfiles full `make check` fails only on 8 pre-existing unmapped `com.iu.teamchat-*` LaunchAgents.
- herdr restart may resume a `me` pane on iu if herdr does not persist pane `--env` (unverified).
- Argo upsert: `COALESCE(excluded.account, usage_record.account)` — null never clears.
- Picks before 2026-10-24T16:25Z were W1 test fixtures and were removed (backup `picks.jsonl.bak-2026-10-24`).
- Briefs of all workers: `~/.local/share/claude-accounts-w1/`, `~/.local/share/claude-accounts-w2/`.
