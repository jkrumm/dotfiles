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

## Open

Nothing to land. argo #202 (payer split, migration 0024) merged and deployed 2026-10-24T19:13Z after a deep review (5 improvements taken: stricter twin match, Max-scoped cutoff, one PAYER_EXPR, real timezone test, payer ids derived from the registry). Post-deploy: archive `argo.usage_record_dedupe_0024` holds 24,803 `duplicate_null_machine` + 7,165 `account_backfill` rows (matches the doc), Max rows 631,145 iu / 973 me / 0 account-less, 48 h reconciliation clean except gateway-posted iu-api rows, page rendered dark+light. dotfiles #31 merged 18:58Z. Worker tabs closed.

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

## Final status (2026-10-24 ~21:30)

- Checklist 2, 3, 4, 5, 6, 7 done. 1: one FAIL (account-less session_env lines, ages out 2026-10-25 17:30Z) -> then `make claude-accounts-stamp`. 9: stale agent-gateway MCP children age out.
- MacBook: dotfiles pulled (owner's uncommitted theme edits kept via autostash), `claude-account`, `~/.claude-me` links + settings, MCP for both accounts, verify machine-aware (usage-db row WARNs where usage-tracker is absent). iu path proven end to end (MacBook `billing=max account=iu` rows arrive via the mirror). **Open: `me` login on the MacBook** is interactive: `CLAUDE_CONFIG_DIR=$HOME/.claude-me command claude` -> `/login` in the personal browser profile. Until then MacBook spawns pick `iu`.
- Tinycast already reads both accounts from Argo `/agents/overview` (primary), local `fetch_usage.py` as fallback.
- Owner questions: pin `~/IuRoot` spawns to `iu`? Drop `argo.usage_record_dedupe_0024` (a typed "drop the archive table now" was seen in the argo worker's input box; not executed, it is the only restore path)?
- MacBook orchestrator report (2026-10-24 ~22:00Z): after a kickstarted collector run 50 `billing=max account=iu` MacBook rows landed in usage.db (the 19:51-21:40Z iumac-unreachable runs were the MacBook asleep, woke 21:42Z). Statusline bug fixed in 59aab6c: before the first API response the quota fallback read `usage_api.json` (iu only), so a `me` pane showed iu numbers; it now reads `usage_accounts.json` for the resolved account or shows nothing. MacBook `me` login still open (`claude-account usage` shows me auth FAILED, picks fall back to iu). A MacBook herdr agent `subs` is reworking the Tinycast Claude usage menu bar/view (both subs + per-machine routing); its result will be forwarded.
- Tinycast rework live on the MacBook (tinycast-extensions 824b8ef, 1125e8f, 72346a2): menu bar title `▸iu89 me8⚠…` (▸ = this Mac's interactive pick, ⚠ = login expired), dropdown/view show each account's 5h/7d, eligibility per machine (local `claude-account` vs Argo `/agents/overview`), lane picks on this Mac and a divergence warning; header freshness follows the newest account sample. Routing by hand: MacBook every lane `iu` (interactive/review/headless `home`; wave/fan/dispatch `spill` while `me` auth failed), mini every lane `me` (wave/fan/dispatch `home`; interactive/review/headless `pace`). Candidate (not started): `snapshot.quota.picks = {lane: {picked, reason, stale}}` from the mini's `claude-account pick --dry --why` so Argo carries per-lane picks (agent-gateway + argo change).
- 2026-10-25: `me` logged in on the MacBook (the login URL opened in Chrome, the work profile; the personal `me` session is in Helium — press `c` in `/login` and paste the URL into Helium). Two follow-ups found: `~` was untrusted for `~/.claude-me` (headless `claude -p` ignored settings; pre-trust written to its `.claude.json`), and `claude -p /usage` no longer refreshes the quota cache on Claude Code 2.1.310, so refresh never clears an auth-failed mark — fix in progress (brief `/tmp/claude-accounts-refresh-brief.md`).
- 2026-10-25 refresh fix landed (ff84617): `claude-account refresh` samples via `GET /api/oauth/usage` with the account's own Keychain token (read-only), `claude auth status` decides the login verdict and clears/sets the auth mark, `refresh --all` exits 1 when logged in but no sample and the stored one is >= 6 h old. Deep review: 2 blocking + 5 improvements, blocking and cheap ones fixed. Not done: re-read the token and retry once after a 401 (idle account past `expiresAt`). Proof: mini `refresh --all` rc 0, both accounts fresh; MacBook `me` fresh (5h 7 %, 7d 9 %), every lane picks `me` there too (interactive/headless `pace`, wave/fan `home`), `me` Haiku run on the MacBook, 3 `account=me` MacBook rows in usage.db, MacBook verify 0 FAIL and stamped. Mini verify still has the one aging session_env FAIL (clears 2026-10-25 17:30Z) -> then `make claude-accounts-stamp` on the mini.
- Tinycast Claude usage rework landed (tinycast-extensions 6e9d829, 357eaa6): one summary drives everything: the working account (this Mac's interactive pick), a plan-weighted pool (iu x20 + me x5; 73 % used, 6.8x of 25x left), weekly pace, severity (spill > broken > low > ok); menu bar title `me 9%`. Real screenshot pass pending until the MacBook is unlocked.
- 2026-10-25 bare `claude` routing landed (e14f6c0): `claude()` in claude-auth.zsh picks on `${USAGE_LANE:-interactive}` unless `CLAUDE_ACCOUNT_PICKED` is set (c/cs/cf and `rd` via herdr `--env`), `--resume` keeps the session account, pre-trust of `$HOME` per account in `make claude-accounts-setup`, 59 launcher tests, deep review clean (hardening taken). MacBook acceptance: fresh herdr pane, `herdr agent start accept --kind claude` -> exactly one new pick-log line (`me`, `pace`) and the claude process env carries `CLAUDE_CONFIG_DIR=~/.claude-me` + `CLAUDE_ACCOUNT_PICKED=me`; it then waits on the per-folder trust dialog for a never-seen cwd (a safety gate, not pre-accepted). Gaps: `--continue` is not pinned to the session account; a stale `CLAUDE_ACCOUNT_PICKED` in a long-lived parent (herdr server env) would skip the pick. The MacBook's GitHub SSH signing needs it unlocked: dotfiles reached it via `git bundle` + scp.

## Retrospective (2026-10-25, final orchestrator)

Worked: deep reviews on every non-trivial change found real defects (0024 twin match and Max-scoped cutoff, a keepalive that stayed green with a dead quota feed, a username in a test); migrations archived before deleting; the e2e suite and break tests caught regressions without spending tokens; one worker tab per change kept the tab count at zero when idle.

Went wrong, and the fix:
- **"Verified" quota source died on a version bump.** `claude -p /usage` stopped refreshing the cache on 2.1.310 and nothing noticed for hours, because the statusline feed masked it and `quota/*` only checks that fields exist. Improvement (not built): `quota/<id>` should WARN when an account's newest sample is older than 6 h and report the sample `src`, and the keepalive exit rule now catches the same class (shipped).
- **Docs contradicted reality.** "MacBook: no `me` login needed" was wrong the moment `iu` went over pace: a MacBook without `me` routes everything to `iu`. Fixed in practice (login done); the Login logistics paragraph still says otherwise.
- **Parallel writers on master.** Two orchestrators plus a worker appended to the same handover file and a worker's `git commit --amend` landed on someone else's commit (recovered by soft reset). Rule for next time: workers use new commits or `--fixup`, never `--amend`, while anyone else can commit; one writer per handover file.
- **The MacBook is a flaky target.** Asleep or locked it fails `ssh iumac`, and its GitHub SSH signing dies while locked. `git bundle` + scp is the fallback; check `ssh -o ConnectTimeout=8 iumac true` before queuing MacBook steps.
- **Not observed:** the session-balance rule sending new spawns to `iu` once `me` passes 85 % in its 5h window (me peaked at 36 %). Watch `picks.jsonl` for reason `session`.

Candidates, nobody started: lane picks in the Argo snapshot (`snapshot.quota.picks`) so Tinycast can show per-lane routing for the mini; pin `~/IuRoot` spawns to `iu` (owner decision); `--continue` account pin; stamp automation after the session_env lines age out; token retry once after a 401 on an idle account; drop `argo.usage_record_dedupe_0024` (owner decision, only restore path); MacBook agent-gateway absence makes `launcher/agent-gateway` a permanent WARN there.
