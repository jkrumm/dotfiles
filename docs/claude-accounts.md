# Two Claude Max accounts — concept

Status: **concept, nothing built yet** (2026-10-24). Account B (Max 5x) is being
bought; account A is the existing Max 20x. Decision record and the numbers
behind it: `~/Reports/ai-subscription-2026-10/index.html`.

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
4. **Account A stays at the default path.** `CLAUDE_CONFIG_DIR` is *unset* for
   A. Setting it to `~/.claude` explicitly changes the Keychain service to
   `Claude Code-credentials-<hash>` and A would look logged out.

## Accounts and on-disk layout

| Id | Plan | Config dir | Keychain service | Capacity units (session / weekly) |
|-|-|-|-|-|
| `a` | Max 20x | `~/.claude` (env unset) | `Claude Code-credentials` | 4 / 2 |
| `b` | Max 5x | `~/.claude-b` | `Claude Code-credentials-<sha256("~/.claude-b" abs)[:8]>` | 1 / 1 |

The Keychain naming is verified in the 2.1.310 binary (`Jj()`: suffix =
first 8 hex of sha256 of the config dir). The capacity units come from measured
ratios: 20x/5x ≈ 3.7× per session and ≈ 2.0× per week (mulletiq regression).

Registry: `config/claude-accounts.json` is the single source (id, dir,
units, home lanes, enabled flag). `b.enabled=false` until the login exists, so
everything below can ship before B does, with no behaviour change.

`~/.claude-b` is created by `make claude-accounts-setup` (idempotent):

- **Symlinked to `~/.claude`:** `skills agents hooks rules output-styles commands
  plugins CLAUDE.md settings.json projects logs`.
  - **`projects/`:** shared, so `--resume` works across accounts and usage-tracker
    keeps one root. `cleanupPeriodDays` is safe because `settings.json` is shared,
    so both dirs sweep with the same value.
  - **`logs/`:** shared, so `session_env` lines land in one place.
- **Per account (never link):** `.claude.json` (oauthAccount, cached usage,
  trust, **user-scope MCP**), credentials, `history.jsonl` (symlinks rejected
  since 2.1.278), `file-history/`, `stats-cache.json`, `ide/`.
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
claude-account pick --lane <lane>   # prints "export CLAUDE_CONFIG_DIR=…" or "unset CLAUDE_CONFIG_DIR"
claude-account usage [--json]       # both accounts: 5h %, 7d %, resets, auth ok
claude-account env <id>             # force an account (c --account b)
```

**Quota source:** `GET api.anthropic.com/api/oauth/usage`, one call per enabled
account.
- **Request:** token from that account's Keychain service, `anthropic-beta:
  oauth-2025-04-20`, `User-Agent: claude-code/<installed version>`. Without the
  UA the endpoint returns persistent 429s.
- **Cache:** `~/.cache/claude-accounts/usage.json`, keyed by account, polled at
  most once a minute per account. On a 429 it keeps the last value and marks it
  stale.
- **fetch_usage.py** becomes a thin caller of this, so there is one fetch path.
  It still writes `/tmp/claude_sl/usage_api.json` (account A, the old shape)
  for backward compatibility, plus `usage_accounts.json` (all accounts).

**Rule v1:**

```
eligible(x) = enabled ∧ auth_ok ∧ session% < 85 ∧ weekly% < 90 ∧ cache age < 10 min
home(lane)  = a  for interactive, agent-gateway:review, headless
              b  for wave, fan, agent-gateway:* (other tools)
pick(lane):
  1. bulk lane ∧ ∃ eligible x with weekly reset < 24 h ∧ weekly% < 70 → x   # use expiring capacity first
  2. eligible(home) → home
  3. eligible(other) → other
  4. interactive → a (Claude Code shows the limit itself)
     bulk        → "iu": the caller spills to its IU path
                   (rd wave --kind opencode, agw's existing IU fallback)
```

Why these homes: the waves are steady, unattended and start a fresh context
per wave, so each wave is a free re-pick point. Together they are 63% of Max
spend, which fits B's small session window better than bursty interactive work
does. B cannot hold all of it (its weekly is about half of A's); rule 3 spills
the rest to A, which gains headroom because the waves left it.

Every decision is appended as JSONL (`ts, lane, picked, reason, a{s,w}, b{s,w}`)
to `~/.claude/logs/`. That pick log is the dataset for v2 tuning.

**v2 (later, from data):** replace the fixed thresholds with pace.
`projected_w(x) = weekly% + burn_rate(lane mix) × hours_to_reset`. Pick the
account with the most slack left at its own reset, which spends capacity before
it expires. Upgrade B to 20x if its weekly stays > 80% two weeks running.

## Spawn integration

| Spawner | Today | Change |
|-|-|-|
| `c` / `cs` / `cf` (`claude.zsh:46-102`) | default dir | `eval "$(claude-account pick --lane interactive)"`; `--account a\|b` override |
| `rd wave` / `rd fan` (`remote-dev.sh:304-310, 603-711`) | pane exports `USAGE_LANE` only | `agent_pane_setup` also runs `eval "$(claude-account pick --lane wave)"` in the pane before `herdr agent start`; on `iu` it switches that spawn to `--kind opencode` |
| agent-gateway workers (`session-runner.ts:373 buildWorkerEnv`, spawn `:1308`) | inherited default dir; reactive IU fallback | set `CLAUDE_CONFIG_DIR` from pick (`lane = agent-gateway:<tool>`); on a quota error retry once on the *other* account, then IU |
| `claude-auth.zsh` fallback (mini) | one token `op://mini/claude/oauth-token` | per account: `op://mini/claude/oauth-token` (a), `op://mini/claude-b/oauth-token` (b). Each is used only when *that* dir's `claude auth status` fails. Never export it otherwise (#37512: the env token deletes the Keychain entry on exit) |
| `herdr-reap.py`, `remote-dev.sh` `claude agents --json` | default dir | query once per enabled account and merge |
| warden | spawns no `claude` | none; it goes through agent-gateway |

Known gap: on a herdr restart, panes come back via `claude --resume <id>` in a
fresh shell, so the env is gone and a B session resumes on A (it works because
`projects/` is shared, but the cache is cold). Accepted for v1. Fix later if herdr
can persist pane env.

## Attribution (usage-tracker → Argo)

- `hooks/session-env.ts` adds `account` to its line: the registry id resolved
  from `CLAUDE_CONFIG_DIR` (unset → `a`). agent-gateway's `writeSessionEnv` does
  the same.
- usage-tracker gets a new `account` column on `session_env` and `usage_record`.
  `billing` keeps its meaning (`max` = sunk, `iu` = metered); account is a
  separate dimension. Backfill: all historical `max` rows → `a`. `billing-audit`
  learns the account.
- The claude-code collector needs no new root: `projects/` and `logs/` are shared.
- Argo: an account filter and split on the usage page (`apps/api/src/routes/usage.ts`,
  `lib/usage-query.ts`).

## Displays

| Surface | Change |
|-|-|
| Claude Code statusline | Native `rate_limits` already comes from the session's own account, so the numbers are correct for free. Add an `A`/`B` badge (from `CLAUDE_CONFIG_DIR`); the fallback fetch reads the right account's entry |
| agent-gateway `/api/usage` (`routes/usage.ts`) | from one `current` object to `{accounts: {a, b}}`; POSTs carry `account` |
| herdr overview pane (`/api/overview.txt`) | a two-line quota header (A and B: 5h/7d/reset) plus an account column per agent |
| Tinycast (MacBook, `extension/src/usage/quota.ts`) | read `https://agent-gateway.mini.jkrumm.com/api/usage` (the tailnet door exists via the Caddyfile vhost), local `fetch_usage.py` as fallback; show both accounts, each with 5h/7d and reset |
| Heartbeat (`devhost-health-check.sh:1133, 1148`) | `quota` shows both accounts (WARN never pages, as today). In `claude auth`, A dead = FAIL; B dead = WARN, because the picker routes around it |
| Hermes digests | inherit from the heartbeat; no change |

## Login logistics

- **Where to log in:** on the mini, inside a herdr pane (the login Keychain is
  only reachable from the GUI session; never `ssh mini 'claude …'`). Run
  `CLAUDE_CONFIG_DIR=~/.claude-b claude`, then `/login`, then press `c` to copy
  the URL.
- **Browser:** paste the URL into a second browser profile on the MacBook that
  stays signed in to account B; the first profile keeps account A and work. If
  the callback can't reach the mini, paste the code back into the pane.
- **How often:** the login refreshes itself; expect re-login only after a revoke
  or a long idle.
- **1Password:** an item for B's login email, plus `op://mini/claude-b/oauth-token`
  from `claude setup-token` (one-year token, fallback only) added to
  `dotfiles-private/headless.refs` and resealed with `make secrets-seed`.
- **MacBook:** no B login needed. Tinycast reads the mini.
- **Hygiene:** real identity, own card, no VPN hopping. Use B at normal intensity
  on day one; ban reports cluster right after a purchase or upgrade.

## Rollout

| Wave | When | Contents | Done when |
|-|-|-|-|
| W0 | now, B absent | registry (`b.enabled=false`), `claude-accounts-setup`, `claude-account` with tests, fetch_usage on the picker, session-env `account`, usage-tracker column + backfill, statusline badge | `make check` green; every pick returns `a`; no behaviour change |
| W1 | after B's login | enable B; `rd wave`/`fan` + agw workers pick; MCP registration for B; per-account claude-auth fallback | a wave lands on B, its rows say `account=b`, cache-read share on B > 90% |
| W2 | after W1 | `/api/usage` multi-account, overview pane, Tinycast, heartbeat, Argo split | both accounts visible on every surface |
| W3 | +2 weeks | read the pick log and usage rows; tune thresholds or move to v2 pace; decide on a 20x upgrade for B | written decision |
