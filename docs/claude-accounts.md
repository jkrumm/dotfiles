# Two Claude Max accounts — concept

Status: **W2 done** (2026-10-24); W3 = tune from picks.jsonl and `quota_sample` after 2 weeks, and decide a 20x upgrade for `me` if its weekly stays > 80 %. Accounts are `iu` (the IU-paid Max 20x at the default `~/.claude`) and
`me` (personal account, Max 5x at `~/.claude-me`), both enabled. Shipped in W1: ids renamed from
`a`/`b`, `c`/`cs`/`cf` pick (`--account iu|me` override), `rd wave`/`rd fan` pick and inject
`CLAUDE_CONFIG_DIR` through herdr `--env` at tab/workspace creation (no room pauses the spawn, never
IU), the token fallback in `claude-auth.zsh` applies to the default account only, per-account
MCP registration / theme / pre-trust, `claude agents` merged across accounts, heartbeat grades `iu`
dead = FAIL and `me` dead = WARN. Still open: agent-gateway workers (other repo), usage-tracker
`account` column (other repo), W2 displays. W2a shipped `make claude-accounts-verify`, the e2e attribution test and the daily login keepalive (§Operate). W0 shipped the registry, `claude-account`, the quota
cache, the statusline badge and `account` in `session_env`. Pick log:
`~/.local/share/claude-accounts/picks.jsonl`; `claude-account exhausted` exists but nothing calls it yet.
Decision record and the numbers behind it: `~/Reports/ai-subscription-2026-10/index.html`.

## Goal

Both subscriptions behave like one larger pool, with no manual switching and
no lost prompt cache. Every display (statusline, Tinycast, herdr overview,
heartbeat, Argo) shows both accounts, and every usage row says which account
paid for it.

## Invariants

1. **The account is chosen at spawn, never mid-session.** The prompt cache is
   scoped per organisation, and two Max accounts are two organisations. Switching
   mid-session or running `--resume` under the other account re-sends the whole
   context uncached (one rebuild ≈ 300k tok × 2× input ≈ $2.4 API-eq on Opus 5.5).
2. **Official binary, own logins, no relay.** Never route credentials through
   claude-relay-service, CCR or LiteLLM pools, and never run rotation that swaps
   logins under a live process. Anthropic staff (2026-02-18): multiple Max
   accounts are not a ToS violation; reselling is. Relays and credential
   intermediation are what enforcement targets.
3. **Split by responsibility, not by project.** The account follows the lane
   (`USAGE_LANE`), so it doesn't matter which repo or machine the work starts from.
4. **Account `iu` stays at the default path.** `CLAUDE_CONFIG_DIR` is *unset* for
   `iu`. Setting it to `~/.claude` explicitly changes the Keychain service to
   `Claude Code-credentials-<hash>` and `iu` would look logged out.

## Accounts and on-disk layout

| Id | Plan | Config dir | Keychain service | Capacity units (session / weekly) |
|-|-|-|-|-|
| `iu` | Max 20x | `~/.claude` (env unset) | `Claude Code-credentials` | 4 / 2 |
| `me` | Max 5x | `~/.claude-me` | `Claude Code-credentials-<sha256("~/.claude-me" abs)[:8]>` (`-7253dcbc`) | 1 / 1 |

The Keychain naming is verified in the 2.1.310 binary (`Jj()`: suffix =
first 8 hex of sha256 of the config dir). The capacity units come from measured
ratios: 20x/5x ≈ 3.7× per session and ≈ 2.0× per week (mulletiq regression).

Registry: `config/claude-accounts.json` is the single source (id, dir,
units, home lanes, enabled flag). `enabled` stays false until an account's login
exists, so a new account ships dark.

`~/.claude-me` is created by `make claude-accounts-setup` (idempotent):

- **Symlinked to `~/.claude`:** `skills agents hooks rules output-styles commands
  plugins CLAUDE.md projects logs`.
  - **`projects/`:** shared, so `--resume` works across accounts and usage-tracker
    keeps one root.
  - **`logs/`:** shared, so `session_env` lines land in one place.
- **`settings.json` is rendered, not linked.** Claude Code rewrites it by
  temp-file-and-rename, which silently replaces a symlink with a real file
  (agswt trap). `make setup` already merges the template into
  `~/.claude/settings.json`; it runs the same merge into `~/.claude-me/`.
  Identical `cleanupPeriodDays` in both keeps the shared `projects/` sweep safe.
- **Per account (never link):** `.claude.json` (oauthAccount,
  `cachedUsageUtilization`, trust, **user-scope MCP**), credentials,
  `history.jsonl` (symlinks rejected since 2.1.278), `file-history/`,
  `stats-cache.json`, `ide/`.
- **Never copy credentials between dirs.** Each dir does its own `/login`, because
  two homes sharing one refresh-token family invalidate each other (caam,
  ClaudeBar).
- **User-scope MCP servers** (`agent-gateway`, `research-gateway`,
  `chrome-devtools`) live in `.claude.json`, so the `make setup` registration
  loop runs once per enabled account (`CLAUDE_CONFIG_DIR=… claude mcp add-json …`).
- Same for every other `~/.claude.json` writer: `_claude_theme_auto`
  (`claude.zsh:40`) and `fan-worktree.sh:40` pre-trust. Both loop over the
  registry.

## The picker

`claude-account` (bun/TS under `scripts/`, symlinked to `~/.local/bin`, the
same pattern as `jobrun`):

```
claude-account pick --lane <lane>   # prints "export CLAUDE_CONFIG_DIR=…" or "unset CLAUDE_CONFIG_DIR"; no headroom: prints "spill", exit 3
claude-account usage [--json]       # both accounts: 5h %, 7d %, resets, auth ok
claude-account env <id>             # force an account (c --account b)
```

**Quota sources: read-only use of the account's own token for one GET.** Three feeds, freshest wins, all
written into `~/.cache/claude-accounts/` as one small file per account and kind (`<id>.sample.json`, `<id>.exhausted.json`, `<id>.auth.json`, `<id>.refresh.claim`; no lock, each writer replaces only its own file atomically, windows carry their own timestamps):

1. **Statusline (live, free):** every render gets native `rate_limits` for the
   session's own account. `statusline.sh` writes `{account, five_hour,
   seven_day, resets_at, ts}` keyed by `CLAUDE_CONFIG_DIR`. While any session
   runs on an account, its numbers are seconds old (the herdr-grazr pattern).
2. **Limit events (instant):** a `StopFailure` / `rate_limit` hook marks the
   account exhausted until `resets_at` the moment a wall is hit (the
   agent-relay pattern). No poll needed to learn about a wall.
3. **Idle accounts:** `GET https://api.anthropic.com/api/oauth/usage` (headers `Authorization: Bearer`, `anthropic-beta:
   oauth-2025-04-20`, as in `fetch_usage.py`) with that account's own Keychain token: service `Claude Code-credentials`
   (default dir) or `Claude Code-credentials-<sha256(abs dir)[:8]>`, read with `security find-generic-password -s <svc> -w`
   (`claudeAiOauth.accessToken`). 0 tokens, no window priming, 10 s timeout, in-process. The token is used for that one
   request and nothing else: never copied, logged, written to the cache or written back to the Keychain (invariant 2: we
   never become co-owner of the login). `utilization` / `resets_at` of `five_hour` / `seven_day` become the sample
   (`src: oauth`). Any failure (Keychain locked or denied, HTTP 401/429/5xx, unparseable body) means *no sample* and
   never an auth mark: a 401 or a locked Keychain proves nothing about the login, so the run falls through to the
   `claude auth status` verdict (§Operate, Login keepalive). It runs only when an account's newest sample is older than
   10 minutes, at most once every 5 minutes per account (the claim, unchanged), because the endpoint rate-limits per
   token (a 429 can block for up to an hour: claude-swap, ClaudeBar). `claude -p "/usage"` was the source until Claude
   Code 2.1.310; it now prints an analysis and no longer updates `cachedUsageUtilization`, so it is gone.
   `readClaudeJson` still merges whatever `cachedUsageUtilization` the binary writes during real sessions (newest
   timestamp wins).

`fetch_usage.py` becomes a reader of this cache. It still writes
`/tmp/claude_sl/usage_api.json` (account `iu`, the old shape) for backward
compatibility, plus `usage_accounts.json` (all accounts).

**Rule v1.2:**

```
eligible(x) = enabled ∧ auth_ok ∧ not exhausted ∧ session% < 85 ∧ weekly% < 90 ∧ sample age < 6 h
              (sample > 10 min old: `pick` uses it and refreshes in the background, budgeted; a refresh takes
               a couple of seconds. Only an account with no sample is refreshed synchronously.
               The pick log carries `stale: true`)
pace(x)     = 100 × elapsed share of x's 7-day window (seven_day_resets_at, clamped 0..1)
overPace(x) = eligible(x) ∧ weekly%(x) > pace(x) + 15      # PACE_MARGIN; no weekly reset → never over pace
home(lane)  = iu for interactive, agent-gateway:review, headless
              me for wave, fan, agent-gateway:* (other tools)
pick(lane):
  1. bulk lane ∧ ∃ eligible x with weekly reset < 24 h ∧ weekly% < 70 → x   # use expiring capacity first
  2. eligible(home) ∧ overPace(home) ∧ eligible(other) ∧ ¬overPace(other) → other   # pace guard, every lane
  3. eligible(home) ∧ eligible(other) ∧ ¬overPace(other) ∧ session%(home) − session%(other) > 20 → other   # balance the 5h windows
  4. eligible(home) → home
  5. eligible(other) → other
  6. interactive → iu (Claude Code shows the limit itself)
     bulk        → "spill": the caller spills to its IU path
                   (`rd` pauses — Herdr work never spills to IU; agw keeps its IU path for gateway workers)
```

Why the pace step (v1.1): on 2026-10-24 `c` picked `iu` at 89 % weekly with about
four days to its reset while `me` sat at 2 %. v1 only leaves home at weekly ≥ 90 %,
so interactive work burned iu's last 11 % while `me` idled. An over-pace home now
yields to an under-pace account (iu 88 % at pace 44 → `me`, reason `pace`). Picks
are per spawn, so no hysteresis. Expiring capacity (rule 1) still wins for bulk lanes.

Why the session step (v1.2): `me`'s 5h window is a quarter of `iu`'s and runs out
fast, so an idle `me` window is capacity that is gone at the next reset. A spawn moves
to the other account when its 5h is more than 20 points emptier (`SESSION_MARGIN`)
and it is not over weekly pace; reason `session`. Within the margin home stays, so
cache and routing remain stable.

Why these homes: the waves are steady, unattended and start a fresh context
per wave, so each wave is a free re-pick point. Together they are 63% of Max
spend, which fits `me`'s small session window better than bursty interactive work
does. `me` cannot hold all of it (its weekly is about half of `iu`'s); rule 3 spills
the rest to `iu`, which gains headroom because the waves left it.

Every decision is appended as JSONL (`ts, lane, picked, reason, a{s,w}, b{s,w}`)
to `~/.claude/logs/`. That pick log is the dataset for v2 tuning.

**v2 (later, from data):** replace the fixed thresholds with pace.
`projected_w(x) = weekly% + burn_rate(lane mix) × hours_to_reset`. Pick the
account with the most slack left at its own reset, which spends capacity before
it expires. Upgrade `me` to 20x if its weekly stays > 80% two weeks running.

## Spawn integration

| Spawner | Today | Change |
|-|-|-|
| bare `claude` in an interactive zsh (`claude()` in `claude-auth.zsh`; what `herdr agent start` types into a pane) | the binary: always iu | `claude-account pick --lane ${USAGE_LANE:-interactive}` unless `CLAUDE_ACCOUNT_PICKED` is set (see Account marker); `--resume` pins; non-interactive shells, `-p`, info flags and subcommands (`auth`, `mcp`, …) never pick |
| `c` / `cs` / `cf` (`claude.zsh` `_claude_launch`) | default dir | `claude-account pick --lane interactive`; `--account iu\|me` override (strips the flag, runs in a subshell; a failing pick answers `iu` and says so on stderr); sets the marker for the `claude` it calls |
| `rd wave` / `rd fan` (`remote-dev.sh:304-310, 603-711`) | pane exports `USAGE_LANE` only | pick before spawn and pass it with herdr's `--env CLAUDE_CONFIG_DIR=…` at pane creation (herdr's only spawn-time injection point; it has no account concept); `CLAUDE_ACCOUNT_PICKED=<id>` rides the same spawn-time `--env` (herdr's `--env` repeats; iu included, so no typed `export` can race the pane's shell); `agent_pane_setup` still types only `USAGE_LANE`. When no account has room `rd` pauses the spawn (no IU spill) |
| agent-gateway workers (`session-runner.ts:373 buildWorkerEnv`, spawn `:1308`) | inherited default dir; reactive IU fallback | set `CLAUDE_CONFIG_DIR` from pick (`lane = agent-gateway:<tool>`); on a quota error retry once on the *other* account, then IU |
| `claude-auth.zsh` token fallback (mini; `_claude_auth_run`, called by `claude()` after the pick) | one token `op://mini/claude/oauth-token` | `op://mini/claude/oauth-token` is injected **only** when `CLAUDE_CONFIG_DIR` is unset (`iu`) and its `claude auth status` fails. For any other dir the wrapper never injects a token: a dead login prints a `/login` hint on stderr and `claude` runs normally (the IU token on `me` ran the session on IU, verified live). Never export it otherwise (#37512: the env token deletes the Keychain entry on exit) |
| `herdr-reap.py`, `remote-dev.sh` `claude agents --json` | default dir | query once per enabled account and merge |
| warden | spawns no `claude` | none; it goes through agent-gateway |

Resume pins the account: `c --resume <id>` (also `-r`, `--resume=<id>`) looks the session up in the
`session_env` hook log (`claude-account session <id>`) and launches on the account it ran on, so the
cache stays warm and the work never changes provider. `--account` overrides; an unknown session
falls through to the normal pick (the hook log is kept for a few days, so the pin holds for that long). agent-gateway pins its own resumed workers the same way.
A running session never changes account: `CLAUDE_CONFIG_DIR` is fixed at spawn and subagents inherit it.

**Account marker (`CLAUDE_ACCOUNT_PICKED=<id>`).** An iu pick is `unset CLAUDE_CONFIG_DIR`, indistinguishable
from "nobody chose", so the decision travels in this variable instead:

- every chooser sets it: `c`/`cs`/`cf` (in their subshell, with `--account`/resume pins), `rd wave`/`fan`
  (herdr `--env` at pane creation, from `pick_account`'s `# picked=` line). Children inherit it, so a nested `claude` never re-picks.
- bare `claude` in an interactive zsh picks unless the marker is set **and consistent**: the marked account's registry dir
  must equal the current `CLAUDE_CONFIG_DIR` (iu = unset; one `jq` read, only when the marker is set). A stale marker
  inherited from a long-lived parent (herdr server env, an old shell) fails that check and is ignored, so it cannot
  silently skip the pick; every chooser sets marker and dir together. An unreadable registry lets the marker stand. It
  then sets the marker inside a subshell (the pane's own
  environment stays unmarked: the next `claude` typed there is a new spawn and picks again).
- result: exactly one `picks.jsonl` line per spawn (`scripts/claude-launcher.test.sh` counts them for `rd`,
  `c` and bare `claude`). Never export it from a profile (it would be ignored whenever it disagrees with the dir, but a matching one still skips the pick).

One `claude` function serves both machines (`config/zsh/claude-auth.zsh`): the pick runs everywhere, then
`_claude_auth_run` applies the mini's token fallback (defined as a plain `command claude` off the dev host).
`~/.zshenv` sources only that file for non-interactive mini shells, so `ssh mini 'claude …'` keeps the fallback and
never picks. `ca`/`claude_iu` call the binary through `env`, bypassing the function by design.

**Trust.** A fresh config dir asks "trust this folder?" on the first start in a path and `herdr agent start` then
reports not-ready. `make claude-accounts-setup` runs `scripts/claude-pretrust.sh "$HOME"` (atomic jq write of
`.projects[$HOME].hasTrustDialogAccepted` in every registered account that has a `.claude.json`; re-run after the first
`/login`); `fan-worktree.sh` does the same for each worktree. Other project paths still prompt once per account.

Known gaps:

- **herdr restart:** panes come back via `claude --resume <id>`. If the pane
  `--env` isn't restored, a `me` session resumes on `iu`: it works because `projects/`
  is shared, but the cache is cold. Verify whether herdr persists `--env`;
  accepted for v1 if not.
- **`claude --bg` / `claude agents`:** the background supervisor is a long-lived
  daemon bound to one identity. caam defaults `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`
  for non-default profiles for this reason. Keep `--bg` (herdr-upgrade) on `iu`
  only; `herdr-reap` queries `claude agents` once per account.

## Operate

**Verify (read-only, no tokens).** `make claude-accounts-verify` prints one `PASS|WARN|FAIL` line per check and
exits 1 on any FAIL; `make doctor` runs it on the mini.

| Check | What it proves | FAIL means |
|-|-|-|
| `auth/<id>` | `claude auth status` is loggedIn with the expected `configDirectory`; keychain service `Claude Code-credentials` (iu) / `…-<sha256(abs dir)[:8]>` exists (`security find-generic-password -s`, never `-w`) | "Claude Code changed credential naming" or config-dir resolution; a logged-out `me` is a WARN, `iu` a FAIL |
| `quota/<id>`, `statusline/<id>` | the `cachedUsageUtilization` the binary keeps in `.claude.json` still has `five_hour`/`seven_day` `utilization` + `resets_at` (its age is informational: only sessions refresh it now); the statusline fed the cache in the last 24 h if sessions ran | field renamed by an update (quota); WARN for a silent statusline |
| `launcher/*` | static: `c cs cf` reach `claude-account pick --lane interactive` and set the marker; bare `claude` picks unless the marker is set; `rd` exports the marker; `claude_iu` never touches `CLAUDE_CONFIG_DIR` and keep the IU env; `rd wave`/`fan` call `pick_account`; agent-gateway's session-runner calls `claude-account pick` | someone rewired a launcher past the picker |
| `pick/<lane>` | `claude-account pick --dry` (no pick-log line, no refresh) for interactive, wave, fan, agent-gateway:review, agent-gateway:dispatch, headless: account + reason | the picker errors or stops explaining itself |
| `attribution/*` | last 24 h: every Claude `session_env` line carries a registered account; no `billing='max'` usage row without an account; `account='me'` rows exist once `me` sessions ran (WARN for the first 2 h: ingest lag) | the hook or the usage-tracker join lost the account |
| `version` | compares `claude --version` with the stamp in `~/.local/state/claude-accounts/verified-version` | (never FAIL; WARN when unstamped) |

Verify never writes. `make claude-accounts-stamp` runs it and, only with no FAIL, records the running version in the stamp. The heartbeat (`check_claude_version`) WARNs `unverified Claude Code version` whenever the running version differs from the
recorded one, until the stamp is renewed. Subagents run inside the parent process and inherit its account (and its
`CLAUDE_CONFIG_DIR`) automatically; nothing picks for them.

**E2E (manual, a few Haiku tokens).** `make claude-accounts-e2e` (`ARGS=--subagent` adds one Haiku run that spawns a
subagent). Per enabled account it builds the launcher env, runs `claude -p "reply ok" --model haiku`, ingests with
usage-tracker, and asserts the session's `usage_record` rows say `billing=max` + the expected account and `session_env`
has the account (with `--subagent`: every row of the subagent session carries the parent's account). Break tests need
no tokens and run against a throw-away copy of the cache, pick log and registry (the real ones are never written):

| Break | Expected |
|-|-|
| exhausted mark on `me` | `wave` picks `iu` (reason `spill`; `rd` then pauses only if iu has no room either); removing the mark restores `me` (`home`) |
| `CLAUDE_CONFIG_DIR` at an unregistered dir | `claude-account account` -> `?`, the session-env hook logs `account: null` |
| registry unreadable | `pick` exits 4 and answers `unset CLAUDE_CONFIG_DIR` |
| `me` dir without credentials | `claude auth status` loggedIn=false; `refresh` marks it auth-failed; `wave` never picks it |

**Login keepalive.** `com.jkrumm.claude-accounts-keepalive` (06:30, under jobrun) runs `claude-account refresh --all`:
per enabled account: the OAuth usage endpoint first (source 3), and when that gives no sample `claude auth status` for that account's `CLAUDE_CONFIG_DIR`. The two are decoupled: the auth mark follows the verdict, never the sample. loggedIn=true clears the mark (`auth-ok`), loggedIn=false sets it (`auth-failed`), and a fresh sample or a statusline `record` also clears it (both prove the login). Both calls cost 0 tokens and prime no window. The run exits 1 when an account got neither a sample nor a verdict, and also when the account is logged in but the endpoint gave no sample and its stored sample is older than 6 h (or missing): a dying feed must turn the jobrun grade red instead of fading out quietly. An endpoint failure with a clean `auth status` and a sample younger than 6 h is exit 0. stderr names the account and the age. `claude auth status` is also what keeps an idle account's OAuth login alive. `--all` ignores the 10-minute freshness and the auth cooldown but not the
5-minute claim. Log: `~/Library/Logs/claude-accounts-keepalive.log`; installed by `make claude-accounts-keepalive-setup`
(part of `make setup`, dev host only).

**After a Claude Code update.** The heartbeat shows `unverified Claude Code version`. Run `make claude-accounts-verify` (or `make claude-accounts-stamp`, which verifies and then stamps):

1. No FAIL -> `make claude-accounts-stamp` records the version, the WARN clears on the next heartbeat.
2. `auth/*` FAIL -> the credential naming or config-dir resolution changed. Re-derive the keychain suffix from the new
   binary, fix `scripts/claude-accounts-verify.sh` and the table above, and check `claude-auth.zsh` still agrees.
3. `quota/*` FAIL -> the `cachedUsageUtilization` shape changed; fix `sampleFromClaudeJson` in
   `scripts/lib/claude-accounts.ts` (until then the picker routes on the statusline and OAuth feeds). If refreshes stop
   producing samples (`refresh` logs `usage endpoint gave no sample` / `no Keychain token`), check `sampleFromOAuthUsage`
   against a live `/api/oauth/usage` body and `keychainService` against the binary.
4. Optional: `make claude-accounts-e2e` for the real attribution round trip.

**Re-login for `me`** (dead login, revoked session): on the mini, in a herdr pane (the login Keychain is only
reachable from the GUI session; never `ssh mini 'claude …'`):

1. `CLAUDE_CONFIG_DIR=$HOME/.claude-me command claude`
2. `/login`, press `c` to copy the URL.
3. Open the URL in the personal browser profile (signed in to `me`), approve, paste the code back into the pane.
4. `claude-account refresh --ids me`, then `make claude-accounts-verify`.

**Troubleshooting**

| Symptom | Likely cause | Fix |
|-|-|-|
| `auth/me` WARN, heartbeat `account me NOT logged in` | login revoked or aged out | re-login steps above |
| `launcher/agent-gateway` FAIL | session-runner lost its `claude-account pick` call (or agent-gateway not deployed with it) | check agent-gateway `master`, redeploy |
| `attribution/session_env` FAIL with old timestamps | lines from sessions that started before the `account` field shipped | ages out within 24 h; newest timestamp in the row says when |
| `attribution/me-rows` FAIL | usage-tracker has not ingested, or the join lost the account | `cd ~/SourceRoot/usage-tracker && bun run src/cli.ts ingest`, rerun |
| `pick/*` all `iu`, reason `interactive-fallback` or `spill` | `me` has no fresh sample or is auth-failed | `claude-account usage`, `claude-account refresh --ids me` |
| a `me` session shows `IU` quota | session started with `CLAUDE_CONFIG_DIR` unset (herdr restart, `--env` not restored) | known gap; restart the session through `c --account me` |
| `quota/<id>` WARN "no cachedUsageUtilization" | no session ever ran on that account (only sessions write it now) | informational; `claude-account refresh --ids <id>` feeds the picker's cache regardless |
| `usage` shows `auth FAILED` right after a fresh `/login` | the mark only clears on a verdict, a sample or a statusline record | `claude-account refresh --ids <id>` (`auth status` loggedIn=true clears it) |
| keepalive exits 1, log `no fresh sample and no auth verdict` or `logged in but still without a fresh sample` | neither the endpoint (Keychain locked / 429 / network) nor `claude auth status` answered, or only the verdict did and the stored sample is over 6 h old | `~/Library/Logs/claude-accounts-keepalive.log` says which; a locked Keychain on the mini needs the GUI session unlocked, retry `claude-account refresh --all` |
| `usage` shows `src oauth` samples but old ages for an account | its refresh is failing quietly (429, Keychain) | run `claude-account refresh --ids <id>` and read the stderr line |

## Borrowed from open source (2026-10 survey)

No existing tool does per-lane spawn-time selection across herdr panes and
agent-gateway workers. The per-spawn tools (diranged/claude-profile, ccs native
profiles, RA1NM4KER/agent-relay, CarlosTheory/claude-multi-account) are profile
launchers that are about 30 lines here. The global-swap tools (claude-swap
`switch`, herdr-account-switch, herdr-grazr, cc-account-switcher, caam vault
mode) rewrite the one live credential under running sessions, which kills
concurrency and cache. So we build a thin picker and take the parts:

| Idea | From | Used as |
|-|-|-|
| statusline `rate_limits` as the quota feed, no polling | wazum/herdr-grazr | quota source 1 |
| `StopFailure` hook for event-driven limit detection | RA1NM4KER/agent-relay | quota source 2 |
| `claude -p "/usage"` → `cachedUsageUtilization`, 0 tokens | n2ns/plan-swap | quota source 3 until Claude Code 2.1.310 (dead since); now the OAuth usage endpoint |
| poll budget ≥ 3 min, shared backoff, honour `Retry-After`, cache successes only | claude-swap, paddo/ccseats, ClaudeBar | idle-account refresh |
| `consume-first` / `earliest-reset-headroom`, 10-pt hysteresis | claude-swap, caam | rule 1 + v2 pace |
| pin a session to one account for its lifetime; re-pin only on 401/quota | hbinhng/ccm `--sticky` | invariant 1 |
| auto-re-prompt agents after a limit wall resets | rcosteira79/herdr-autocontinue | W2: interactive panes that hit the wall resume at `resets_at` |
| never symlink `settings.json`; locked keychain looks logged out | fujibee/agswt | layout rules, heartbeat |
| `CLAUDE_CODE_DISABLE_AGENT_VIEW` for non-default identities | caam | `--bg` stays on `iu` |
| profile badge + chained statusline env | diranged/claude-profile | statusline `IU`/`ME` badge |

Avoid: relay class (claude-relay-service, CCR pools, OmniRoute, `ccs cliproxy`,
doxaras/claude-rotate, 2solarmax/maxpool, tuxevil-rotator). Also any tool that
writes refreshed tokens back into Claude Code's store (ClaudeBar API mode, Raycast
Agent Usage), which makes the tool co-owner of the login. Window priming
(`claude -p ping` to start the 5h window early) is undocumented meter-gaming.
Cache keep-alive is redundant; Claude Code ships its own `cache_touch`.

## Attribution (usage-tracker → Argo)

- `hooks/session-env.ts` adds `account` to its line: the registry id resolved
  from `CLAUDE_CONFIG_DIR` (unset → `iu`). agent-gateway's `writeSessionEnv` does
  the same.
- usage-tracker gets a new `account` column on `session_env` and `usage_record`.
  `billing` keeps its meaning (`max` = sunk, `iu` = metered); account is a
  separate dimension. Backfill: all historical `max` rows → `iu`. `billing-audit`
  learns the account.
- The claude-code collector needs no new root: `projects/` and `logs/` are shared.
- Argo: an account filter and split on the usage page (`apps/api/src/routes/usage.ts`,
  `lib/usage-query.ts`).

## Displays

| Surface | Change |
|-|-|
| Claude Code statusline | Native `rate_limits` already comes from the session's own account, so the numbers are correct for free. Add an `IU`/`ME` badge (from `CLAUDE_CONFIG_DIR`); the fallback fetch reads the right account's entry |
| agent-gateway `/api/usage` (`routes/usage.ts`) | from one `current` object to `{accounts: {a, b}}`; POSTs carry `account` |
| herdr overview pane (`/api/overview.txt`) | a two-line quota header (`iu` and `me`: 5h/7d/reset) plus an account column per agent |
| Tinycast (MacBook, `extension/src/usage/quota.ts`) | read `https://agent-gateway.mini.jkrumm.com/api/usage` (the tailnet door exists via the Caddyfile vhost), local `fetch_usage.py` as fallback; show both accounts, each with 5h/7d and reset |
| Heartbeat (`devhost-health-check.sh:1133, 1148`) | `quota` shows both accounts (WARN never pages, as today). In `claude auth`, `iu` dead = FAIL; `me` dead = WARN (built in W1), because the picker routes around it |
| Hermes digests | inherit from the heartbeat; no change |

## Login logistics

- **Where to log in:** on the mini, inside a herdr pane (the login Keychain is
  only reachable from the GUI session; never `ssh mini 'claude …'`). Run
  `CLAUDE_CONFIG_DIR=~/.claude-me claude`, then `/login`, then press `c` to copy
  the URL.
- **Browser:** paste the URL into a second browser profile on the MacBook that
  stays signed in to `me`; the first profile keeps `iu` and work. If
  the callback can't reach the mini, paste the code back into the pane.
- **How often:** the login refreshes itself; expect re-login only after a revoke
  or a long idle.
- **1Password:** an item for `me`'s login email. No token fallback for `me`: a dead
  login is a WARN and a `/login`.
- **MacBook:** no `me` login needed. Tinycast reads the mini.
- **Hygiene:** real identity, own card, no VPN hopping. Use `me` at normal intensity
  on day one; ban reports cluster right after a purchase or upgrade.

## Rollout

| Wave | When | Contents | Done when |
|-|-|-|-|
| W0 | now, B absent | registry (`me` disabled), `claude-accounts-setup`, `claude-account` with tests, quota cache with the three feeds (`iu` only), fetch_usage as a cache reader, session-env `account`, usage-tracker column + backfill, statusline badge, pick log | `make check` green; every pick returns `iu`; no behaviour change (at W0 no `api/oauth/usage` calls from `claude-account`; source 3 now makes them, budgeted) |
| W1 | after the `me` login | enable `me`; `rd wave`/`fan` + agw workers pick; MCP registration per account; claude-auth token fallback `iu`-only | a wave lands on `me`, its rows say `account=me`, cache-read share on `me` > 90% |
| W2 | after W1 | `/api/usage` multi-account, overview pane, Tinycast, heartbeat, Argo split | both accounts visible on every surface |
| W3 | +2 weeks | read the pick log and usage rows; tune thresholds or move to v2 pace; decide on a 20x upgrade for `me` | written decision |
