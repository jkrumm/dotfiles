# Claude Max accounts — concept

Status: **W2 done** (2026-10-24); rule v1.4 (N accounts), the peer sample import and plan detection shipped 2026-10-27; W3 = tune from picks.jsonl and `quota_sample` after 2 weeks, and decide a 20x upgrade for `me` if its weekly stays > 80 %. Accounts are `iu` (the IU-paid Max 20x at the default `~/.claude`) and
`me` (personal account, Max 5x at `~/.claude-me`), both enabled, plus `me2` (second personal Max 5x at `~/.claude-me2`, Safari), registered dark (`enabled: false`) until its logins exist. Shipped in W1: ids renamed from
`a`/`b`, `c`/`cs`/`cf` pick (`--account iu|me` override), `rd wave`/`rd fan` pick and inject
`CLAUDE_CONFIG_DIR` through herdr `--env` at tab/workspace creation (no room pauses the spawn, never
IU), the token fallback in `claude-auth.zsh` applies to the default account only, per-account
MCP registration / theme / pre-trust, `claude agents` merged across accounts, heartbeat grades `iu`
dead = FAIL and `me` dead = WARN. Still open: usage-tracker
`account` column (other repo), W2 displays. W2a shipped `make claude-accounts-verify`, the e2e attribution test and the login keepalive (§Operate). W0 shipped the registry, `claude-account`, the quota
cache, the statusline badge and `account` in `session_env`. Pick log:
`~/.local/share/claude-accounts/picks.jsonl`; `claude-account exhausted` exists but nothing calls it yet.
Decision record and the numbers behind it: `~/Reports/ai-subscription-2026-10/index.html`.

## Goal

All subscriptions behave like one larger pool, with no manual switching and
no lost prompt cache. Every display (statusline, Tinycast, herdr overview,
heartbeat, Argo) shows every account, and every usage row says which account
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
| `me2` | Max 5x | `~/.claude-me2` | `Claude Code-credentials-<sha256("~/.claude-me2" abs)[:8]>` (`-a3d9de83`) | 1 / 1 |

The suffixes above are the mini's: the hash covers the absolute dir, so it differs per machine whenever `$HOME` does
(`printf %s "$HOME/.claude-me2" | shasum -a 256 | cut -c1-8` prints this machine's). `me2` shares the bulk lanes with `me`.

The Keychain naming is verified in the 2.1.310 binary (`Jj()`: suffix =
first 8 hex of sha256 of the config dir). The capacity units come from measured
ratios: 20x/5x ≈ 3.7× per session and ≈ 2.0× per week (mulletiq regression).

Registry: `config/claude-accounts.json` is the single source (id, dir, plan, optional
units, home lanes, `loginBrowser`, enabled flag). `units` defaults from `plan` (`max20x` 4 / 2, anything else 1 / 1);
a present block is still validated. `enabled` stays false until an account's login
exists, so a new account ships dark (§Adding an account).

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
- **User-scope MCP servers** (`chrome-devtools`) live in `.claude.json`, so the `make setup` registration
  loop runs once per enabled account (`CLAUDE_CONFIG_DIR=… claude mcp add-json …`).
- Same for every other `~/.claude.json` writer: `_claude_theme_auto`
  (`claude.zsh:40`) and `fan-worktree.sh:40` pre-trust. Both loop over the
  registry.

## The picker

`claude-account` (bun/TS under `scripts/`, symlinked to `~/.local/bin`, the
same pattern as `jobrun`):

```
claude-account pick --lane <lane>   # prints "export CLAUDE_CONFIG_DIR=…" or "unset CLAUDE_CONFIG_DIR"; no headroom: prints "spill", exit 3
claude-account usage [--json]       # every account: 5h %, 7d %, resets, auth ok
claude-account env <id>             # force an account (c --account b)
claude-account expiry [--json] [--ids a,b]   # when each enabled login ends (refresh token), graded PASS / WARN / FAIL; --ids names accounts, disabled ones included
```

`expiry` rows carry `grade` (PASS > 7 d, WARN <= 7 d or unreadable, FAIL <= 2 d or past), `default` (the account owns `~/.claude`) and `severity` (the grade, but a non-default account never exceeds WARN, as with `auth/<id>`); verify and the heartbeat act on `severity`. They also carry `tier` (the item's raw `claudeAiOauth.rateLimitTier`, e.g. `default_claude_max_5x`, or null) and `plan_detected` (`max20x` / `max5x` parsed from `/max_(\d+)x/`, else null); the tier is not a secret and no token field is ever read or exposed. `--ids` includes disabled accounts because a re-login must read a first login. `usage` stays a pure file read (the statusline calls it): no Keychain access, no login fields; `expiry` is the only reader of the Keychain item's timestamps and tier.

**Quota sources: read-only use of the account's own token for one GET, plus a peer import.** Four feeds, freshest wins, all
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
   never an auth mark: a locked Keychain or a 429 proves nothing about the login, so the run falls through to the
   `claude auth status` verdict (§Operate, Login keepalive). One failure is repaired instead: **HTTP 401**. The Keychain
   access token of an idle account expires and nothing renews it (seen live 2026-10-25: `me` idle 01:01 to 08:27, sample
   8.5 h old, out of routing). `claude auth status` for that account's `CLAUDE_CONFIG_DIR` (0 tokens) makes the binary
   renew the token in the Keychain, so a 401 runs it, re-reads the token and retries the GET once; a second failure is
   plain "no sample". That one `auth status` is also the run's login verdict (never run twice), so the auth mark logic is
   unchanged: only a verdict, a sample or a statusline record moves it, and no token reaches a log or a file. A refresh runs
   only when an account's newest sample is older than 10 minutes, at most once every 5 minutes per account (the claim,
   unchanged), because the endpoint rate-limits per token (a 429 can block for up to an hour: claude-swap, ClaudeBar). `claude -p "/usage"` was the source until Claude
   Code 2.1.310; it now prints an analysis and no longer updates `cachedUsageUtilization`, so it is gone.
   `readClaudeJson` still merges whatever `cachedUsageUtilization` the binary writes during real sessions (newest
   timestamp wins).
4. **Peer machine (import, refresh only):** quota is per account, not per machine, so the other machine's numbers are as
   good as ours. Seen 2026-10-27: MacBook `me` had no sample for 36 h (idle Keychain access token expired, every GET 401,
   and `claude auth status` in 2.1.311 no longer renews it) while the mini, where `me` is busy, had fresh ones.
   `runRefresh` (keepalive `--all` and the detached pick-time refresh) first fetches the peer's `claude-account usage
   --json` once (mini -> `ssh iumac`, MacBook -> `ssh mini`, the same peer resolution as `health`; BatchMode,
   ConnectTimeout 5, 20 s cap) and turns each row of a locally registered, enabled account into a sample (`src: peer`).
   Each window's timestamp is rebuilt from the row's age (now minus `*_age_s`; null age, null timestamp), so an old
   number is never laundered into a fresh one, and `mergeSample` keeps the newer window. A future `exhausted_until`
   is imported as a mark. **Auth state is never imported** (logins are per machine): an account served from the peer still
   gets its own `claude auth status` verdict. An account whose merged sample is now younger than 10 min skips the
   endpoint GET for that run and counts as `fresh` only when this machine's verdict says logged in (no verdict:
   `unresolved`, the keepalive's exit 1). An unreachable or garbled peer is one log line and the run continues
   unchanged. It runs only in the keepalive and the *detached* pick-time refresh; the synchronous refresh a
   non-interactive pick may wait for skips it, so no pick ever waits on ssh.

`fetch_usage.py` is only a reader of this cache (its own API path retired 2026-10-31; on a stale default sample it
runs `claude-account refresh --ids <default>`). It writes `/tmp/claude_sl/usage_api.json` (the default account, the
old shape the statusline and Tinycast read) plus `usage_accounts.json` (all accounts). Every consumer (the statusline,
Tinycast and the Herdr app's `jk-status`) now reads subscription data through `claude-account` (`usage`, `health`).

**Rule v1.6** (v1.5 plus the 5h guards below, 2026-10-30; v1.4 plus expiry-weighted sharing below; ceilings tightened 2026-10-27: `SESSION_MAX` 85 → 90, `WEEKLY_MAX` 90 → 95, to use more of each subscription; v1.3 plus N accounts: where v1.3 took the first match in registry order for every alternative, v1.4 takes the best one; v1.3 = `weeklyMax(x)` 98 while x's weekly window resets within 24 h, else 95, the last points of an expiring window being use-it-or-lose-it, decided 2026-10-27 after `iu` sat idle at 93 % with 14 h to its reset; v1.4 decided the same day when `me2` joined):

```
eligible(x) = enabled ∧ auth_ok ∧ not exhausted ∧ session% < 90 ∧ weekly% < weeklyMax(x) ∧ sample age < 6 h
              (sample > 10 min old: `pick` uses it and refreshes in the background on EVERY lane, interactive
               included, detached and budgeted; a refresh takes a couple of seconds. Only a non-interactive lane
               refreshes an account with no usable sample synchronously; the interactive pick never waits.
               The pick log carries `stale: true`)
pace(x)     = 100 × elapsed share of x's 7-day window (seven_day_resets_at, clamped 0..1)
overPace(x) = eligible(x) ∧ weekly%(x) > pace(x) + 15      # PACE_MARGIN; no weekly reset → never over pace
units(x)    = registry units, else from the plan "maxNx": k = max(1, N/5) → {session k, weekly 1 + (k−1)/3}
              (max5x {1,1}, max10x {2, 1.33}, max20x {4, 2}); any other plan → {1, 1}
spare(x)    = (weeklyMax(x) − weekly%(x)) × units(x).weekly     # no weekly window → WEEKLY_MAX × units.weekly
weight(x)   = spare(x) / hoursToWeeklyReset(x)^1.5    # URGENCY_EXP; ≥ 1 h; no weekly reset → a full week
best(S)     = the member of S with the highest weight (registry order breaks ties)
share(S)    = a draw from S with probability ∝ weight   # what the CLI uses; `pick --dry` and tests use best(S)
home(lane)  = share(eligible x whose homeLanes claim the lane)
              iu for interactive, headless
              me and me2 for wave, fan
coolSet      = eligible accounts with session% < 80 (SESSION_SOFT_MAX), else all eligible   # a hot 5h window is the last choice, not excluded
                 every step below reads coolSet as "eligible"
pick(lane):
  1. bulk lane ∧ ∃ eligible x with weekly reset < 24 h ∧ weekly% < 70 → x   # use expiring capacity first (soonest reset)
  2. eligible(home) ∧ overPace(home) → share(eligible x ≠ home ∧ ¬overPace(x))   # pace guard, every lane
  3. eligible(home) → the eligible x ≠ home with (¬overPace(x) ∨ session%(home) ≥ 60) ∧ session%(home) − session%(x) > 20
                      and the lowest session% (ties by weight); a sibling that shares the lane beats an outsider
                      # balance the 5h windows
  4. eligible(home) → home
  5. share(eligible)   # spill to the accounts with the most room
  6. interactive → iu (Claude Code shows the limit itself)
     bulk        → "spill": the caller spills to its IU path
                   (`rd` pauses — Herdr work never spills to IU; agw steps keep their IU path)
```

Why v1.4: with two accounts "the other" was one account, so the first match was the only match. With `me2` the
siblings `me` and `me2` share the bulk lanes, and registry order would have drained `me` while `me2` idled. Headroom
is the weekly points left below the account's own ceiling, scaled by its plan, so a 20x account with the same
percent counts for twice the room. Every threshold and the expiring-capacity step are unchanged. From v1.5 the ranking is
spare per hour to the account's own reset (a reset already past counts as a fresh week), and the CLI's draw is random
(only the outcome reaches the pick log, so a single pick is not reproducible; `pick --dry` and the tests stay deterministic).

Why v1.5 (2026-10-29): the pick log showed `me2` at 67 % weekly with three days to its reset taking about a tenth
of the bulk picks while `iu` and `me` (resets 6-7 days out) took the rest. v1.4's best-headroom pick looked at spare
points only, so an account that expires sooner was no more attractive than one that expires next week, and
argmax sends a whole fan burst to one account. v1.5 weighs each account's spare capacity per hour to *its own*
reset (sharpened ×1.5, so a window closing sooner counts for more), and the CLI draws among the home accounts in
proportion to the weights, so a burst spreads instead of landing on one account. Nothing names an account or a plan:
a new subscription is a registry entry, its reset time and quota come from the sample. With `me` and `me2` at
similar 5h load the split at the time was about 49/51; the 5h-balance step (3) still moves work to the emptier
window and keeps overriding the weekly weighting while the 5h loads differ by more than 20 points.

Why v1.6 (2026-10-30): all three accounts sat over weekly pace (`iu` 41 % vs 27 % elapsed, `me` 42 vs 18, `me2` 94 vs 68),
so step 3 had no candidate and `me` (5h window a quarter of `iu`'s) took every wave from 3 % to 99 % in 75 minutes while
`iu` idled at 5 %. A full 5h window is a wall; an over-pace week is a preference (it recovers over a weekend). So (a) the
session move ignores the other's pace once the home 5h is at 60 % (`SESSION_PRESSURE`), and (b) from 80 %
(`SESSION_SOFT_MAX`) an account only takes work when no cooler one is eligible; `SESSION_MAX` 90 stays the hard stop.

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

Why the refresh is not interactive-exempt (v1.2 text, 2026-10-25): v1.1 left the interactive lane untouched so a
pick could never block or spend anything. That exemption starved an idle account: on a machine where only interactive
picks run (the MacBook) nothing ever refreshed `me`. The refresh itself is cheap (one usage GET or `claude auth status`,
0 tokens), so the lane now spawns the same detached, claimed (5-min budget) background refresh as the others and still
never waits: the pick answers from the cache it has, the next one sees the new sample. The rule itself is unchanged.
The periodic keepalive (§Operate) is the guarantee; the pick-time refresh is the opportunistic second path.

Why these homes: the waves are steady, unattended and start a fresh context
per wave, so each wave is a free re-pick point. Together they are 63% of Max
spend, which fits `me`'s small session window better than bursty interactive work
does. `me` cannot hold all of it (its weekly is about half of `iu`'s); `me2` takes the share
`me` cannot, and step 5 spills the rest to `iu`, which gains headroom because the waves left it.

Every decision is appended as JSONL (`ts, lane, picked, reason, a{s,w}, b{s,w}`)
to `~/.claude/logs/`. That pick log is the dataset for v2 tuning.

**v2 (later, from data):** replace the fixed thresholds with pace.
`projected_w(x) = weekly% + burn_rate(lane mix) × hours_to_reset`. Pick the
account with the most slack left at its own reset, which spends capacity before
it expires. Upgrade `me` to 20x if its weekly stays > 80% two weeks running.

## Spawn integration

| Spawner | Today | Change |
|-|-|-|
| bare `claude` in an interactive zsh (`claude()` in `claude-auth.zsh`; what `herdr agent start` types into a pane) | the binary: always iu | `claude-account pick --lane ${USAGE_LANE:-interactive}` unless `CLAUDE_ACCOUNT_PICKED` is set (see Account marker); `--resume` and `--continue` pin; non-interactive shells, `-p`, info flags and subcommands (`auth`, `mcp`, …) never pick |
| `c` / `cs` / `cf` (`claude.zsh` `_claude_launch`) | default dir | `claude-account pick --lane interactive`; `--account <id>` override (strips the flag, runs in a subshell; a failing pick answers `iu` and says so on stderr); sets the marker for the `claude` it calls |
| `rd wave` / `rd fan` (`remote-dev.sh:304-310, 603-711`) | pane exports `USAGE_LANE` only | pick before spawn and pass it with herdr's `--env CLAUDE_CONFIG_DIR=…` at pane creation (herdr's only spawn-time injection point; it has no account concept); `CLAUDE_ACCOUNT_PICKED=<id>` rides the same spawn-time `--env` (herdr's `--env` repeats; iu included, so no typed `export` can race the pane's shell); `agent_pane_setup` still types only `USAGE_LANE`. When no account has room `rd` pauses the spawn (no IU spill) |
| `claude-auth.zsh` token fallback (mini; `_claude_auth_run`, called by `claude()` after the pick) | one token `op://mini/claude/oauth-token` | `op://mini/claude/oauth-token` is injected **only** when `CLAUDE_CONFIG_DIR` is unset (`iu`) and its `claude auth status` fails. For any other dir the wrapper never injects a token: a dead login prints a `/login` hint on stderr and `claude` runs normally (the IU token on `me` ran the session on IU, verified live). Never export it otherwise (#37512: the env token deletes the Keychain entry on exit) |
| `herdr-reap.py`, `remote-dev.sh` `claude agents --json` | default dir | query once per enabled account and merge |

Resume pins the account: `c --resume <id>` (also `-r`, `--resume=<id>`) looks the session up in the
`session_env` hook log (`claude-account session <id>`) and launches on the account it ran on, so the
cache stays warm and the work never changes provider. `--continue` / `-c` pins the same way: it resumes the newest
session of the cwd, so `claude-account latest "${PWD:A}"` (the physical path: Claude Code keys the transcript dir by the resolved cwd, so a symlinked `$PWD` would miss) finds that session (newest `<id>.jsonl` by mtime under the shared
`~/.claude/projects/<cwd, every non-alphanumeric as '-'>/`) and the lookup above gives its account. Both lookups fall
through to the normal pick when they find nothing: no transcript for the cwd, or a `session_env` line older than the
hook log's 3-day retention (a `--continue` into a session older than that re-picks, and the context is cold anyway).
The hook line carries no cwd, which is why the transcript directory, not the log, answers "which session". `--account` overrides.
A running session never changes account: `CLAUDE_CONFIG_DIR` is fixed at spawn and subagents inherit it.

**Account marker (`CLAUDE_ACCOUNT_PICKED=<id>`).** An iu pick is `unset CLAUDE_CONFIG_DIR`, indistinguishable
from "nobody chose", so the decision travels in this variable instead:

- every chooser sets it: `c`/`cs`/`cf` (in their subshell, with `--account`/resume pins), `rd wave`/`fan`
  (herdr `--env` at pane creation, from `pick_account`'s `# picked=` line). Children inherit it, so a nested `claude` never re-picks.
- the routing reason rides with it as `CLAUDE_ACCOUNT_REASON=<reason>` (the picker's `reason=`, `forced` for `--account`, `resume`
  for a session pin; unset when unknown), set and unset together with the marker by `_claude_enter_account` and by `pick_account`'s
  `--env`. It is display-only (kept for Tinycast and later displays; the statusline does not render it); nothing routes on it.
- bare `claude` in an interactive zsh picks unless the marker is set **and consistent**: the marked account's registry dir
  must equal the current `CLAUDE_CONFIG_DIR` (iu = unset; one `jq` read, only when the marker is set). A stale marker
  inherited from a long-lived parent (herdr server env, an old shell) fails that check and is ignored, so it cannot
  silently skip the pick; every chooser sets marker and dir together. An unreadable registry lets the marker stand. It
  then sets the marker inside a subshell (the pane's own
  environment stays unmarked: the next `claude` typed there is a new spawn and picks again).
- **A consistent marker in a pane's own environment stays valid after its agent exits (decided 2026-10-25, no code
  change).** An `rd` pane gets marker and `CLAUDE_CONFIG_DIR` from herdr's spawn-time `--env`, so they are the pane's
  environment, not a subshell's. A second `claude` typed there after the first exited skips the pick and runs on the
  pane's account. That is intended: the pane is one seat on one account (and one `USAGE_LANE`), the second session is the
  same work in the same place, and it shares the account's prompt-cache organisation, which a re-pick could only
  forfeit; the guard above exists for markers that *disagree* with the dir, and this one agrees. Costs, accepted: that
  second spawn writes no `picks.jsonl` line, and if the account was exhausted meanwhile Claude Code shows the limit
  itself (the statusline feed marks it). To re-route from such a pane, type `c` (always picks, then sets the marker for
  its own `claude`) or `c --account <id>`. A bare `claude` in a *plain* pane is the other case: its marker lives in a
  subshell, so each typed `claude` picks.
- result: exactly one `picks.jsonl` line per spawn (`scripts/claude-launcher.test.sh` counts them for `rd`,
  `c` and bare `claude`). Never export it from a profile (it would be ignored whenever it disagrees with the dir, but a matching one still skips the pick).

One `claude` function serves both machines (`config/zsh/claude-auth.zsh`): the pick runs everywhere, then
`_claude_auth_run` applies the mini's token fallback (defined as a plain `command claude` off the dev host).
`~/.zshenv` sources only that file for non-interactive mini shells, so `ssh mini 'claude …'` keeps the fallback and
never picks.

**Trust.** A fresh config dir asks "trust this folder?" on the first start in a path and `herdr agent start` then
reports not-ready. `make claude-accounts-setup` runs two steps (re-run both after the first `/login` of an account, since
an account without a `.claude.json` is skipped): `scripts/claude-pretrust.sh "$HOME"` (atomic jq write of
`.projects[$HOME].hasTrustDialogAccepted` in every registered account that has a `.claude.json`) and
`scripts/claude-trust-sync.sh`, which copies `hasTrustDialogAccepted=true` from the default `~/.claude.json` into each
extra account for exactly the project paths the default already trusts. It never loosens: it sets true only where the
default says true (false or unknown paths are left alone; entries that are not JSON objects are ignored on both sides), touches no other key, writes one atomic replace per account
(original mode kept) and nothing at all when the account is already in sync. An account dir it cannot write in prints a diagnostic and makes the run exit 1. `fan-worktree.sh` pre-trusts each new
worktree. A folder the default has never opened still prompts once per account.

Known gaps:

- **herdr restart:** panes come back via `claude --resume <id>`. If the pane
  `--env` isn't restored, a `me` session resumes on `iu`: it works because `projects/`
  is shared, but the cache is cold. Verify whether herdr persists `--env`;
  accepted for v1 if not.
- **`claude --bg` / `claude agents`:** the background supervisor is a long-lived
  daemon bound to one identity. caam defaults `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`
  for non-default profiles for this reason. Keep `--bg` (herdr-upgrade) on `iu`
  only; `herdr-reap` queries `claude agents` once per account.

## Effort per model

Claude Code has one global `effortLevel` and no per-model default, so every launch we control adds `--effort` from
`config/claude-effort.json` (decided 2026-10-27): **Sonnet high, Opus medium, Fable medium**, no `--model` = `default`
(the account's default model, Opus or Fable) = medium. It applies on every account because it rides the launch, not
the config dir: `c`/`cs`/`cf` and a bare interactive `claude` (`_claude_effort_args` in `claude-auth.zsh`), and
`rd wave`/`rd fan` (`rd_effort_flag` in `remote-dev.sh`, `RD_WAVE_EFFORT` overrides). An explicit `--effort` always
wins; an unlisted family (Haiku) gets no flag. `settings.json` `effortLevel` stays `high` in all three accounts on
purpose: it is what a spawn without the flag runs at, and those are the headless runs (the e2e). Custom
subagents pin their own (`agents/*.md` `effort: high`). A mid-session `/model` switch keeps the session's effort.

## Operate

**Verify (read-only, no tokens).** `make claude-accounts-verify` prints one `PASS|WARN|FAIL` line per check and
exits 1 on any FAIL; `make doctor` runs it on the mini.

| Check | What it proves | FAIL means |
|-|-|-|
| `auth/<id>` | `claude auth status` is loggedIn with the expected `configDirectory`; keychain service `Claude Code-credentials` (iu) / `…-<sha256(abs dir)[:8]>` exists (`security find-generic-password -s`, never `-w`) | "Claude Code changed credential naming" or config-dir resolution; a logged-out `me` is a WARN, `iu` a FAIL. Fix: `claude-relogin <id>` |
| `login/<id>` | `claude-account expiry`: the Keychain item's `claudeAiOauth.refreshTokenExpiresAt` (epoch ms; the refresh token ends 30 days after the login and rotation does not extend it). Only the two timestamps are read, never a token | PASS > 7 d left, WARN <= 7 d, FAIL <= 2 d or already past for the default account (`iu`); any other account is capped at WARN, like `auth/<id>`. An unreadable item (locked Keychain, foreign format) is a WARN, never a FAIL. Fix: `claude-relogin <id>` (§Re-login) |
| `plan/<id>` | `claude-account expiry` `plan_detected` (parsed from the Keychain item's `rateLimitTier`) equals the registry's `plan`. The picker's default units hang on that plan | WARN only: a mismatch (fix: set `"plan"` in `config/claude-accounts.json`) or an undetectable tier |
| `quota/<id>`, `statusline/<id>` | the `cachedUsageUtilization` the binary keeps in `.claude.json` still has `five_hour`/`seven_day` `utilization` + `resets_at` (its age is informational: only sessions refresh it now); the statusline fed the cache in the last 24 h if sessions ran | field renamed by an update (quota); WARN for a silent statusline |
| `launcher/*` | static: `c cs cf` reach `claude-account pick --lane interactive` and set the marker; bare `claude` picks unless the marker is set; `rd` exports the marker; `claude_iu` and the other retired IU launchers (`ca cap cdf cdp`) must stay gone; `rd wave`/`fan` call `pick_account` | someone rewired a launcher past the picker |
| `pick/<lane>` | `claude-account pick --dry` (no pick-log line, no refresh) for interactive, wave, fan, headless: account + reason | the picker errors or stops explaining itself |
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

**Quota + login keepalive.** `com.jkrumm.claude-accounts-keepalive` (**hourly, on both machines**, under jobrun with
`--every 3600`, `RunAtLoad`) runs `claude-account refresh --all`. Decision 2026-10-25: it was daily 06:30 on the mini only, so
an idle account's sample went past the 6 h eligibility window and silently left routing (and the MacBook, whose picks are
all interactive, had no refresher at all). Hourly sits far under 6 h, survives a missed run or two, and costs 24 usage GETs
a day per account (the claim keeps the 5-minute budget; the endpoint is rate-limited per token, nowhere near that).
`make claude-accounts-keepalive-setup` (part of `make setup`) installs it everywhere; it needs `~/.local/bin/jobrun` and
`claude-account` (both from `make setup`) and fails loudly without them. Each machine keeps its own cache, so each
refreshes its own (feed 4 tops up an idle account from the peer): the MacBook's picks route on the MacBook's samples. `jobs-grade` window for `every 3600` is 3 h (a
sleeping laptop fires one run on wake, not a backlog); `make doctor` maps the label in `docs/architecture.md` (mini table
and MacBook list). Per enabled account:
per enabled account: the OAuth usage endpoint first (source 3), and when that gives no sample `claude auth status` for that account's `CLAUDE_CONFIG_DIR`. The two are decoupled: the auth mark follows the verdict, never the sample. loggedIn=true clears the mark (`auth-ok`), loggedIn=false sets it (`auth-failed`), and a fresh sample or a statusline `record` also clears it (both prove the login). Both calls cost 0 tokens and prime no window. The run exits 1 when an account got neither a sample nor a verdict, and also when the account is logged in but the endpoint gave no sample and its stored sample is older than 6 h (or missing): a dying feed must turn the jobrun grade red instead of fading out quietly. An endpoint failure with a clean `auth status` and a sample younger than 6 h is exit 0. stderr names the account and the age. `claude auth status` is also what keeps an idle account's OAuth login alive. `--all` ignores the 10-minute freshness and the auth cooldown but not the
5-minute claim. The interactive and non-interactive picks run the same refresh opportunistically (detached, same
claim), so a machine in active use is fresher than hourly. Log: `~/Library/Logs/claude-accounts-keepalive.log`
(a green run prints nothing; the detached refresh a pick spawns appends its stdout/stderr to the same file). `--all` also asks for a re-login when a login is dead or inside its last 7 days (§Re-login, once per account per 24 h).

**Health on wake.** `claude-account health [--json] [--wake]` grades this machine and its peer (MacBook reaches the mini over
`ssh mini`, the mini the MacBook over `ssh iumac`; both unauthenticated reads: `usage --json`, `expiry --json`, the human-queue).
**Transport:** the peer is read through a herdr-core, never a plain ssh shell. Why: an ssh session on the mini cannot read
the login Keychain (`security` rc=36), so over ssh every login expiry is unreadable (2026-10-31: the app's chip said ok
while `me`/`me2` were logged out on the mini); the core is a launchd GUI-session child and reads it. Two routes, in order:
(1) this machine's core lists the peer `connected` (`hc exec --on <peer>`; only when `hc server status` says the core runs),
(2) one ssh hop to the peer and *its own* core (`launchctl print` first, then `hc exec` there). Neither starts a core: an
`hc` call auto-starts a stray one when none runs, so both check first. Only when no core answers does it read over plain
ssh, and then says so: a `NOTE <peer>: its herdr-core was not reachable…` line (stdout in text mode, stderr under `--json`
so the JSON stays parseable). Every peer row carries `via: "core"|"ssh"` (unreadable details end `(via ssh)`). Exit codes
and the JSON shape are unchanged.
A login with no readable expiry is `warn` (`login expiry unreadable`), never `ok`. Test seams: `CLAUDE_ACCOUNTS_HC` (the hc binary), `CLAUDE_ACCOUNTS_SSH`.
Rows: `login` (logged out = FAIL for `iu`, WARN otherwise; login ending <= 7 d = WARN), `quota` (logged in but no sample for
> 6 h: the usage endpoint is rejecting the token, the failure `auth status` alone cannot see), `queue` (re-login asks
waiting for a click). `--wake`, run 30 s after wake by `scripts/wakeup.sh` (sleepwatcher, MacBook), re-pushes the mini's
pending re-login dialogs younger than 24 h (a push that failed while this Mac slept is not retried by anything else:
2026-10-27 the `iu` ask sat 8 h) and posts one notification, repeated only when the set of bad rows changes or after 12 h.
Tinycast's Claude usage view reads `health --json` and offers each row's `fix`.
The Herdr app's `jk-status` polls `health --json` every 5 min for its ⚠ chip. A Re-login started from the chip in `jk-details`
sets `shared("jk.relogin")`; `jk-status` then re-polls from 60 s after the start, once a minute, until that row is gone or 15 min
have passed (the chip's "approve in browser" label follows the same key), so the chip clears when the login lands.

**After a Claude Code update.** The heartbeat shows `unverified Claude Code version`. Run `make claude-accounts-verify` (or `make claude-accounts-stamp`, which verifies and then stamps):

1. No FAIL -> `make claude-accounts-stamp` records the version, the WARN clears on the next heartbeat.
2. `auth/*` FAIL -> the credential naming or config-dir resolution changed. Re-derive the keychain suffix from the new
   binary, fix `scripts/claude-accounts-verify.sh` and the table above, and check `claude-auth.zsh` still agrees.
3. `quota/*` FAIL -> the `cachedUsageUtilization` shape changed; fix `sampleFromClaudeJson` in
   `scripts/lib/claude-accounts.ts` (until then the picker routes on the statusline and OAuth feeds). If refreshes stop
   producing samples (`refresh` logs `usage endpoint gave no sample` / `no Keychain token`), check `sampleFromOAuthUsage`
   against a live `/api/oauth/usage` body and `keychainService` against the binary.
4. Optional: `make claude-accounts-e2e` for the real attribution round trip.

**Re-login** (dead login, revoked session, or `login/<id>` WARN): `claude-relogin <id>`. Logins are per machine (the
mini and the MacBook keep separate Keychain items), so it runs on the machine that owns the credential; `--machine
mini|macbook` reaches the other one over ssh.

```
claude-relogin me              # log in on this machine behind the scenes, approve in the browser, get a notification
claude-relogin me --ask        # push an approval dialog to the MacBook; its one click starts the same thing
claude-relogin me --visible    # debugging: a Terminal window / herdr terminal that stays open, no notification
claude-relogin me --dry-run    # print exactly what would run, run nothing
```

1. **Where it runs.** The login Keychain is only reachable from the GUI session (never `ssh mini 'claude …'`).
   - *MacBook:* no window. A detached worker runs `CLAUDE_CONFIG_DIR=<dir> BROWSER=scripts/claude-login-browser.sh claude
     auth login --claudeai` (`CLAUDE_CONFIG_DIR` stays unset for `iu`; token env vars are stripped). Its output, with
     anything token-shaped redacted, goes to `~/Library/Logs/claude-relogin.log`. If that cannot complete (the CLI fails,
     the Keychain is locked, or there was no output for 10 minutes because the callback never arrived), it opens a
     Terminal window with the interactive login, and closes exactly that window (by id) after success. The windowless
     worker only starts in the Aqua GUI session (`launchctl managername`; `ssh iumac` lands in it, measured); from any
     other session it goes straight to that Terminal path via osascript (`launchctl asuser` would need root). The log is
     owner-only (mode 600), redacted (`sk-ant-…`, `Bearer`, and the value of any `code`/`state`/`*token`/`*secret`
     key), and rotated by `log-rotate.sh`.
   - *mini:* a terminal in the mini's herdr-core runs the same command interactively: `hc run --bg --no-parent --rm
     --name relogin-<id>` with labels `herdr.space=<the dotfiles space>` (rd's rule: the `herdr-app` doc entry for the
     folder, else the stable id from the full root; an unreadable doc refuses rather than guesses) and `herdr.tab=tb-relogin-<id>`,
     so the app shows it as the tab `relogin <id>` (named best-effort through the doc once the app has adopted it).
     The core is a launchd GUI-session child, which is why the Keychain works (`ssh mini` is not enough). After success
     the command exits and the terminal removes itself (`--rm`); the watcher sweeps it a few seconds later with `hc rm`
     (never a live one). A failed login drops into `exec $SHELL -l` in that terminal, left open for the paste fallback;
     `--visible` always keeps the shell. A second relogin for the account while its terminal is still open refuses and names
     it (`hc kill relogin-<id>` closes it); a finished one is removed first. `launchctl print` checks the core runs before
     any `hc` call (an `hc` call starts a stray core otherwise); with no core it falls back to the classic herdr workspace
     `relogin <id>` (closed after success, `TODO(Wave 7): drop classic`). From the MacBook the hop is still one ssh to the
     mini, where this script then talks to the local core.
   - *Waiting for the terminal:* the opener polls for a result file (`mktemp`, owner-checked, never a symlink) and for
     the terminal's existence (`hc get`: not found or `finished` = gone). A probe that could not ask (osascript, hc or herdr failing, timing out, answering garbage)
     never counts as "closed": the terminal is gone only after 3 clean "absent" answers in a row, and that is
     reported by notification, never silently. After 60 minutes without a result it notifies "did not finish" and
     leaves the window/terminal open.
2. The CLI calls the helper with the authorize URL (redirect_uri `http://localhost:<port>/callback`, random port). The
   helper opens it in the browser signed in to that account, registry field `loginBrowser` (`iu` Google Chrome, `me`
   Helium; no field = the system default, and it says so). On the MacBook that is `open -a <app> <url>`. On the mini the
   browser is on the MacBook: it starts `ssh -N -R 127.0.0.1:<port>:localhost:<port> iumac` (loopback only) so the
   browser's localhost callback lands on the mini's CLI, then `ssh iumac open -a <app> '<url>'`. The tunnel is its own
   ssh connection. The login process (`claude-relogin --in-pane`) owns it and kills it on any exit (trap on
   EXIT/INT/TERM); a detached watchdog covers an owner that vanished, closing it when the CLI stops listening or after 45
   minutes without a connection (an idle watchdog, not a deadline). If the tunnel dies while the login still waits, the
   terminal says so and asks you to paste the code. A registry that cannot be read never falls back to a guessed
   browser: the helper prints the URL instead.
3. **You click approve in that browser.** Nothing drives the browser or reads mail: automating the login itself is out
   of bounds (Anthropic's terms), a human always approves.
4. It then runs `claude-account refresh --ids <id>` and sends a native notification to the MacBook (locally there, over
   ssh from the mini): `Claude login me: renewed, valid until <date>`, or `Claude login me failed - retry with:
   claude-relogin me (log: <path>)`. The text is built from the id, a date and the log path only, never from CLI output.
   "Renewed" is proven: the Keychain item's `refresh_expires_at` is read before the login and again after it
   (`claude-account expiry --json --ids <id>`) and must be newer afterwards (or there was none before). A login that
   exits 0 without moving it is a failure with the text `login finished but the Keychain login did not change (still valid until
   <date>)`, on the usual failure path: notification, and on the mini the terminal stays open (seen 2026-10-27: a
   "renewed" report while the reader still saw the old item).

A registered but **disabled** account is accepted: its first login is how a new account comes out of the dark, and
`expiry --ids <id>` reads it before `enabled` is flipped (§Adding an account).

If the forward or ssh fails, the helper prints the URL and the CLI prompt is still there: open the URL yourself and paste
the code. **Manual fallback** (no script at all): on the machine that owns the login, in a herdr pane or Terminal,
`CLAUDE_CONFIG_DIR=$HOME/.claude-me command claude` (`iu`: unset it), `/login`, press `c` to copy the URL, open it in the
right profile, approve, paste the code, then `claude-account refresh --ids <id>` and `make claude-accounts-verify`.

**The ask (keepalive path).** The hourly `claude-account refresh --all` asks for a re-login by itself, never runs one:
when a refresh ends `auth-failed` for an account on this machine, or `login/<id>` has a known end of life within 7
days (an unreadable item never asks), it runs `claude-relogin <id> --ask --reason …` detached. That shows a native
dialog on the MacBook (through `scripts/ask-human.sh`: from the mini over `ssh iumac`, on the MacBook directly,
`HUMAN_QUEUE_MAC_HOST=local`) whose command is `bash "$HOME/SourceRoot/dotfiles/scripts/claude-relogin.sh" <id> --machine
<m>`; the owner reads it and clicks Run once. At most one ask per account per 24 h and one dialog per machine per hour. Both slots are claimed atomically
(exclusive create of `~/.cache/claude-accounts/<id>.relogin-ask.json` and `relogin-ask.cap`, so two keepalive runs never ask
twice) and given back when the ask process fails to start (logged `ask failed`, retried next run), so a 24 h mute only
follows an ask that really started. One account's failure never stops the others; a second account due in the same hour
is deferred to the next run. An unanswered dialog falls back to the
human queue and its Slack notification, as every `ask-human` request does.

**Adding an account**

1. Registry entry in `config/claude-accounts.json` with `"enabled": false` (`dir`, `plan`, `homeLanes`, `loginBrowser`; `units` only to override the plan default).
2. `make claude-accounts-setup` on both machines (the config dir with its links and rendered `settings.json`).
3. `claude-relogin <id>` on the mini and `claude-relogin <id> --machine macbook` (logins are per machine; a disabled account is allowed).
4. `claude-account expiry --ids <id>` on each machine: `plan_detected` must show the plan you registered.
5. Set `"enabled": true`.
6. `make setup` (per-account MCP registration), then `make claude-accounts-verify`.

**Troubleshooting**

| Symptom | Likely cause | Fix |
|-|-|-|
| `auth/me` WARN, heartbeat `account me NOT logged in` | login revoked or aged out | `claude-relogin me` (§Re-login) |
| `login/<id>` WARN or FAIL, heartbeat `<id> login valid until … (N d left)` | the 30-day refresh token is near its end | `claude-relogin <id>` on that machine; the keepalive has already asked once per 24 h |
| `login/<id>` WARN `login expiry unreadable` | Keychain locked (headless session), or the item has no `refreshTokenExpiresAt` | unlock the GUI session and rerun; `claude-account expiry` shows the reason |
| `claude-relogin` prints the URL and a paste hint | no loopback port in the URL, the reverse forward was refused (port taken on the MacBook, `iumac` sshd down) or `open` failed there | open the URL in the account's browser yourself and paste the code at the CLI prompt |
| no notification after a re-login, no window either | the windowless MacBook login is still waiting for your approval, or failed | `~/Library/Logs/claude-relogin.log` says which; a stuck one falls back to a Terminal window after 10 minutes without output, or run `claude-relogin <id> --visible` |
| the re-login dialog never appears | MacBook asleep or unreachable | the request stays in the human queue (`make human-queue` on the MacBook) and Slack; or run `claude-relogin <id>` there |
| `plan/<id>` WARN "Keychain tier … says max20x, registry says 'max5x'" | the account was upgraded or the registry plan is wrong | set `"plan"` in `config/claude-accounts.json` (the default units follow it) |
| `plan/<id>` WARN "not detectable" | Keychain item unreadable (locked) or without `rateLimitTier` | unlock the GUI session and rerun; `claude-account expiry --json` shows `tier` |
| a stale expiry or 401 right after a fresh login, `security find-generic-password -s 'Claude Code-credentials…'` without `-a` shows `"acct"<blob>="unknown"` | a Keychain twin: a process that ran without `USER` filed a second item under acct `unknown` next to the real one (acct = `$USER`) | lookups here pass `-a $USER`; delete the twin: `security delete-generic-password -s 'Claude Code-credentials' -a unknown` (add the `-<hash>` suffix for a non-default account) |
| notification `login finished but the Keychain login did not change` | the CLI exited 0 but the item the reader sees was not rewritten (Keychain twin above, a locked Keychain, a login in the wrong browser profile) | check the twin row above, then `claude-relogin <id> --visible` |
| log `refresh: peer usage unavailable` / `unreadable` | the other machine is asleep or unreachable over ssh, or answered garbage | nothing: the run continues on its own endpoint; `ssh mini claude-account usage --json` (MacBook) / `ssh iumac …` (mini) shows why |
| `attribution/session_env` FAIL with old timestamps | lines from sessions that started before the `account` field shipped | ages out within 24 h; newest timestamp in the row says when |
| `attribution/me-rows` FAIL | usage-tracker has not ingested, or the join lost the account | `cd ~/SourceRoot/usage-tracker && bun run src/cli.ts ingest`, rerun |
| `pick/*` all `iu`, reason `interactive-fallback` or `spill` | `me` has no fresh sample or is auth-failed | `claude-account usage`, `claude-account refresh --ids me` |
| a `me` session shows `IU` quota | session started with `CLAUDE_CONFIG_DIR` unset (herdr restart, `--env` not restored) | known gap; restart the session through `c --account me` |
| `quota/<id>` WARN "no cachedUsageUtilization" | no session ever ran on that account (only sessions write it now) | informational; `claude-account refresh --ids <id>` feeds the picker's cache regardless |
| `usage` shows `auth FAILED` right after a fresh `/login` | the mark only clears on a verdict, a sample or a statusline record | `claude-account refresh --ids <id>` (`auth status` loggedIn=true clears it) |
| keepalive exits 1, log `no fresh sample and no auth verdict` or `logged in but still without a fresh sample` | neither the endpoint (Keychain locked / 429 / network) nor `claude auth status` answered, or only the verdict did and the stored sample is over 6 h old | `~/Library/Logs/claude-accounts-keepalive.log` says which; a locked Keychain on the mini needs the GUI session unlocked, retry `claude-account refresh --all` |
| log `usage endpoint HTTP 401, renewing the access token via claude auth status` | the idle account's Keychain access token expired (expected after hours idle); the run renews it and retries once | nothing, unless it repeats every hour with `no sample` after it: then the refresh token is dead, check `auth/<id>` and re-login |
| an account's sample is hours old on the MacBook | keepalive agent not installed there (`launchctl list \| grep claude-accounts`) | `make setup` or `make claude-accounts-keepalive-setup` on that machine |
| `usage` shows `src oauth` samples but old ages for an account | its refresh is failing quietly (429, Keychain) | run `claude-account refresh --ids <id>` and read the stderr line |

## Borrowed from open source (2026-10 survey)

No existing tool does per-lane spawn-time selection across herdr panes. The per-spawn tools (diranged/claude-profile, ccs native
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
  from `CLAUDE_CONFIG_DIR` (unset → `iu`).
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
| Claude Code statusline | Native `rate_limits` already comes from the session's own account, so the own numbers are correct for free; the `IU`/`ME` badge stays at the front. After the duration, one final segment (files only, never a spawn in the render): every enabled account as `<id> <5h>/<wk>` in registry order, e.g. `iu 2/90 · me 41/22 ↺90m · ∑76%`. The own account is bold with the live stdin numbers (and its 5h reset countdown while line 1 fits 130 columns); the others come from `/tmp/claude_sl/usage_accounts.json`, grey when the sample is over 1 h old, `✗login` when the login failed, absent without figures. `∑` is the plan-weighted weekly pool (weight = the plan multiple, `max20x` 20 / `max5x` 5, all 1 when one is unknown; the same formula as Tinycast's `usage/summary.ts`), only with more than one account. Numbers use the context thresholds. The routing reason (`CLAUDE_ACCOUNT_REASON`, see Account marker) and a pace hint are not rendered. `usage_accounts.json` is rewritten in the background at most once a minute by `fetch_usage.py --accounts` (20 s cap). Tests: `scripts/statusline.test.sh` |
| herdr overview pane (`/api/overview.txt`) | a two-line quota header (`iu` and `me`: 5h/7d/reset) plus an account column per agent |
| Tinycast (MacBook, `extension/src/usage/quota.ts`) | read both accounts from Argo `GET /agents/overview` (`latest.snapshot.quota`), local `fetch_usage.py` as fallback; show both accounts, each with 5h/7d and reset |
| Heartbeat (`devhost-health-check.sh:1133, 1148`) | `quota` shows both accounts (WARN never pages, as today). In `claude auth`, `iu` dead = FAIL; `me` dead = WARN (built in W1), because the picker routes around it. The same check grades login expiry from `claude-account expiry` (its `severity`): anything but PASS is a WARN (never pages): inside 7 days, an unreadable item, or a check that could not run (helper missing, failing or answering garbage: `login expiry check could not run (<reason>)`, reason also on stderr). Expiry never raises past the existing `iu` policy: a dead keychain login with a working cached token stays the accepted state (WARN at worst); FAIL only where `check_claude_auth_iu` fails too |
| Hermes digests | inherit from the heartbeat; no change |

## Login logistics

- **Per machine, per account:** the mini and the MacBook keep separate Keychain items, so every machine needs its own
  login for each account it uses (a pick on the MacBook for `me` needs `me` logged in there). Never copy credentials
  between machines or dirs. `claude-relogin <id> --machine mini|macbook` logs in on the machine that owns the credential.
- **Where it runs:** in a GUI-session terminal on that machine (a herdr-core terminal on the mini, Terminal on the MacBook);
  the login Keychain is only reachable from the GUI session; never `ssh mini 'claude …'`. `claude-relogin` opens it.
- **Browser:** the registry's `loginBrowser` names the app signed in to the account (`iu` Chrome, the work session; `me`
  Helium and `me2` Safari, the personal ones). It lives on the MacBook, so a login on the mini forwards the callback through a reverse ssh
  tunnel (§Re-login). If the callback can't reach the CLI, paste the code at its prompt.
- **How often:** the access token (8 h) is renewed by the keepalive, but the refresh token ends 30 days after the login
  (`refreshTokenExpiresAt`, not extended by rotation; what the server does past that date is unproven, one report says 55
  days). Plan a re-login every ~30 days, or sooner after a revoke. `claude-account expiry` and the `login/<id>` rows say
  when, and the keepalive asks once per 24 h from 7 days out.
- **1Password:** an item for `me`'s login email. No token fallback for `me`: a dead
  login is a WARN and a re-login.
- **Tinycast (MacBook)** reads the mini's quota; it needs no login of its own.
- **Hygiene:** real identity, own card, no VPN hopping. Use `me` at normal intensity
  on day one; ban reports cluster right after a purchase or upgrade.

## Rollout

| Wave | When | Contents | Done when |
|-|-|-|-|
| W0 | now, B absent | registry (`me` disabled), `claude-accounts-setup`, `claude-account` with tests, quota cache with the three feeds (`iu` only), fetch_usage as a cache reader, session-env `account`, usage-tracker column + backfill, statusline badge, pick log | `make check` green; every pick returns `iu`; no behaviour change (at W0 no `api/oauth/usage` calls from `claude-account`; source 3 now makes them, budgeted) |
| W1 | after the `me` login | enable `me`; `rd wave`/`fan` + agw workers pick; MCP registration per account; claude-auth token fallback `iu`-only | a wave lands on `me`, its rows say `account=me`, cache-read share on `me` > 90% |
| W2 | after W1 | `/api/usage` multi-account, overview pane, Tinycast, heartbeat, Argo split | both accounts visible on every surface |
| W3 | +2 weeks | read the pick log and usage rows; tune thresholds or move to v2 pace; decide on a 20x upgrade for `me` | written decision |
