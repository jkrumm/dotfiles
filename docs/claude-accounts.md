# Two Claude Max accounts — concept

Status: **W1 built** (2026-10-24). Accounts are `iu` (the IU-paid Max 20x at the default `~/.claude`) and
`me` (personal account, Max 5x at `~/.claude-me`), both enabled. Shipped in W1: ids renamed from
`a`/`b`, `c`/`cs`/`cf` pick (`--account iu|me` override), `rd wave`/`rd fan` pick and inject
`CLAUDE_CONFIG_DIR` through herdr `--env` at tab/workspace creation (IU spill switches that spawn to
opencode), the token fallback in `claude-auth.zsh` applies to the default account only, per-account
MCP registration / theme / pre-trust, `claude agents` merged across accounts, heartbeat grades `iu`
dead = FAIL and `me` dead = WARN. Still open: agent-gateway workers (other repo), usage-tracker
`account` column (other repo), W2 displays. W0 shipped the registry, `claude-account`, the quota
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

**Quota sources: we never read a token.** Three feeds, freshest wins, all
written into `~/.cache/claude-accounts/` as one small file per account and kind (`<id>.sample.json`, `<id>.exhausted.json`, `<id>.auth.json`, `<id>.refresh.claim`; no lock, each writer replaces only its own file atomically, windows carry their own timestamps):

1. **Statusline (live, free):** every render gets native `rate_limits` for the
   session's own account. `statusline.sh` writes `{account, five_hour,
   seven_day, resets_at, ts}` keyed by `CLAUDE_CONFIG_DIR`. While any session
   runs on an account, its numbers are seconds old (the herdr-grazr pattern).
2. **Limit events (instant):** a `StopFailure` / `rate_limit` hook marks the
   account exhausted until `resets_at` the moment a wall is hit (the
   agent-relay pattern). No poll needed to learn about a wall.
3. **Idle accounts:** `CLAUDE_CONFIG_DIR=<dir> claude -p "/usage"` (verified on
   2.1.310: 0 tokens, $0, 0 turns). The official binary does the fetch itself,
   with its own backoff, and writes `cachedUsageUtilization` (`five_hour` /
   `seven_day` utilization + `resets_at`, `accountUuid`, `fetchedAtMs`) into that
   dir's `.claude.json`; the picker reads it from there. It runs only when an
   account's newest sample is older than 10 minutes, at most once every 5 minutes
   per account. The endpoint budget is about 28–30 calls/h per account, and a 429
   can block for up to an hour (claude-swap, ClaudeBar), so the hand-rolled
   `fetch_usage.py` poll gets retired.

`fetch_usage.py` becomes a reader of this cache. It still writes
`/tmp/claude_sl/usage_api.json` (account `iu`, the old shape) for backward
compatibility, plus `usage_accounts.json` (all accounts).

**Rule v1:**

```
eligible(x) = enabled ∧ auth_ok ∧ not exhausted ∧ session% < 85 ∧ weekly% < 90 ∧ sample age < 6 h
              (sample > 10 min old: `pick` uses it and refreshes in the background, budgeted; `claude -p /usage`
               takes 27-40 s, limit 75 s. Only an account with no sample is refreshed synchronously.
               The pick log carries `stale: true`)
home(lane)  = iu for interactive, agent-gateway:review, headless
              me for wave, fan, agent-gateway:* (other tools)
pick(lane):
  1. bulk lane ∧ ∃ eligible x with weekly reset < 24 h ∧ weekly% < 70 → x   # use expiring capacity first
  2. eligible(home) → home
  3. eligible(other) → other
  4. interactive → iu (Claude Code shows the limit itself)
     bulk        → "spill": the caller spills to its IU path
                   (rd wave --kind opencode, agw's existing IU fallback)
```

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
| `c` / `cs` / `cf` (`claude.zsh:46-102`) | default dir | `eval "$(claude-account pick --lane interactive)"`; `--account iu\|me` override (strips the flag, runs in a subshell; a failing pick answers `iu`) |
| `rd wave` / `rd fan` (`remote-dev.sh:304-310, 603-711`) | pane exports `USAGE_LANE` only | pick before spawn and pass it with herdr's `--env CLAUDE_CONFIG_DIR=…` at pane creation (herdr's only spawn-time injection point; it has no account concept) instead of typing `export` into the pane. On `iu` it switches that spawn to `--kind opencode` |
| agent-gateway workers (`session-runner.ts:373 buildWorkerEnv`, spawn `:1308`) | inherited default dir; reactive IU fallback | set `CLAUDE_CONFIG_DIR` from pick (`lane = agent-gateway:<tool>`); on a quota error retry once on the *other* account, then IU |
| `claude-auth.zsh` fallback (mini) | one token `op://mini/claude/oauth-token` | `op://mini/claude/oauth-token` is injected **only** when `CLAUDE_CONFIG_DIR` is unset (`iu`) and its `claude auth status` fails. For any other dir the wrapper never injects a token: a dead login prints a `/login` hint on stderr and `claude` runs normally (the IU token on `me` ran the session on IU, verified live). Never export it otherwise (#37512: the env token deletes the Keychain entry on exit) |
| `herdr-reap.py`, `remote-dev.sh` `claude agents --json` | default dir | query once per enabled account and merge |
| warden | spawns no `claude` | none; it goes through agent-gateway |

Known gaps:

- **herdr restart:** panes come back via `claude --resume <id>`. If the pane
  `--env` isn't restored, a `me` session resumes on `iu`: it works because `projects/`
  is shared, but the cache is cold. Verify whether herdr persists `--env`;
  accepted for v1 if not.
- **`claude --bg` / `claude agents`:** the background supervisor is a long-lived
  daemon bound to one identity. caam defaults `CLAUDE_CODE_DISABLE_AGENT_VIEW=1`
  for non-default profiles for this reason. Keep `--bg` (herdr-upgrade) on `iu`
  only; `herdr-reap` queries `claude agents` once per account.

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
| `claude -p "/usage"` → `cachedUsageUtilization`, 0 tokens | n2ns/plan-swap | quota source 3 (verified) |
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
| W0 | now, B absent | registry (`me` disabled), `claude-accounts-setup`, `claude-account` with tests, quota cache with the three feeds (`iu` only), fetch_usage as a cache reader, session-env `account`, usage-tracker column + backfill, statusline badge, pick log | `make check` green; every pick returns `iu`; no behaviour change; no `api/oauth/usage` calls from our code |
| W1 | after the `me` login | enable `me`; `rd wave`/`fan` + agw workers pick; MCP registration per account; claude-auth token fallback `iu`-only | a wave lands on `me`, its rows say `account=me`, cache-read share on `me` > 90% |
| W2 | after W1 | `/api/usage` multi-account, overview pane, Tinycast, heartbeat, Argo split | both accounts visible on every surface |
| W3 | +2 weeks | read the pick log and usage rows; tune thresholds or move to v2 pace; decide on a 20x upgrade for `me` | written decision |
